-- This helper intentionally targets formatter-normalized, block-style YAML.
-- In this plugin, YAML buffers are assumed to be formatted consistently, so we
-- can rely on:
-- - stable indentation
-- - list children being indented two spaces deeper than the `-`
-- - Kubernetes-style manifests using mostly block mappings/lists
--
-- It is not a full YAML parser. It is optimized for common K8s navigation paths
-- in statuslines and intentionally ignores exotic YAML features.

local M = {}
local cache_by_buf = {}

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function indent_of(line)
  local indent = line:match("^(%s*)")
  return indent and #indent or 0
end

local function strip_inline_comment(text)
  local in_single = false
  local in_double = false
  local escaped = false

  for idx = 1, #text do
    local ch = text:sub(idx, idx)

    if in_double and ch == "\\" and not escaped then
      escaped = true
    else
      if not in_double and ch == "'" then
        in_single = not in_single
      elseif not in_single and ch == '"' and not escaped then
        in_double = not in_double
      elseif not in_single and not in_double and ch == "#" then
        local prev = idx > 1 and text:sub(idx - 1, idx - 1) or ""
        if idx == 1 or prev:match("%s") then
          return trim(text:sub(1, idx - 1))
        end
      end
      escaped = false
    end
  end

  return trim(text)
end

local function is_block_value(value)
  return value and value:match("^|[+-]?%d*$") ~= nil or value and value:match("^>[+-]?%d*$") ~= nil
end

local function block_scalar_child_indent(info)
  local value = info and (info.value or info.scalar_value) or nil
  if not value or not is_block_value(value) then
    return nil
  end
  return info.indent + 2
end

local function parse_mapping(text)
  text = strip_inline_comment(text)
  local key, value = text:match("^([^:]+):%s*(.-)%s*$")
  if not key then
    return nil
  end
  key = trim(key)
  if key == "" then
    return nil
  end
  return key, value
end

local function parse_line(line)
  if not line or line:match("^%s*$") or line:match("^%s*#") then
    return nil
  end

  local indent = indent_of(line)
  local text = trim(line)
  if text == "---" or text == "..." then
    return {
      indent = indent,
      text = text,
      is_document_marker = true,
    }
  end
  local is_list_item = text:match("^%-") ~= nil
  local mapping_text = is_list_item and trim(text:sub(2)) or text
  local key, value = parse_mapping(mapping_text)

  return {
    indent = indent,
    text = text,
    is_list_item = is_list_item,
    key = key,
    value = value,
    scalar_value = is_list_item and not key and mapping_text ~= "" and mapping_text or nil,
  }
end

local function clone_state(state)
  local stack = {}
  for idx, entry in ipairs(state.stack) do
    local copy = {}
    for key, value in pairs(entry) do
      copy[key] = value
    end
    stack[idx] = copy
  end
  return {
    stack = stack,
    kind = state.kind,
    block_scalar_indent = state.block_scalar_indent,
    root_next_item_index = state.root_next_item_index,
  }
end

local function pop_to_line(state, indent)
  while #state.stack > 0 do
    local top = state.stack[#state.stack]
    if top.type == "block" and top.child_indent > indent then
      table.remove(state.stack)
    elseif top.type == "item" and top.child_indent > indent then
      table.remove(state.stack)
    else
      break
    end
  end
end

local function current_item(state)
  for idx = #state.stack, 1, -1 do
    if state.stack[idx].type == "item" then
      return state.stack[idx]
    end
  end
  return nil
end

local function item_label_keys(parent_key)
  local candidates = {
    containers = { "name" },
    initContainers = { "name" },
    env = { "name" },
    ports = { "name", "containerPort", "port" },
    volumeMounts = { "name", "mountPath" },
    volumes = { "name" },
    imagePullSecrets = { "name" },
    rules = { "name", "host" },
  }
  return candidates[parent_key] or { "name" }
end

local function is_item_label_key(parent_key, key)
  for _, candidate in ipairs(item_label_keys(parent_key)) do
    if key == candidate then
      return true
    end
  end
  return false
end

local function label_priority(parent_key, key)
  for idx, candidate in ipairs(item_label_keys(parent_key)) do
    if key == candidate then
      return idx
    end
  end
  return math.huge
end

local function item_cache_key(item)
  return table.concat({
    item.parent_key or "",
    tostring(item.start_line or 0),
    tostring(item.index or 0),
  }, ":")
end

local function process_line(state, info, lnum)
  if not info then
    return
  end

  if info.is_document_marker then
    state.stack = {}
    state.kind = nil
    state.root_next_item_index = 0
    return
  end

  if info.indent == 0 and info.key == "kind" and info.value and info.value ~= "" then
    state.kind = info.value:lower()
  end

  if info.is_list_item then
    pop_to_line(state, info.indent)

    local parent = state.stack[#state.stack]
    if (parent and parent.type == "block") or (not parent and info.indent == 0) then
      local parent_key = parent and parent.key or nil
      if parent then
        parent.next_item_index = (parent.next_item_index or 0) + 1
      else
        state.root_next_item_index = (state.root_next_item_index or 0) + 1
      end
      table.insert(state.stack, {
        type = "item",
        indent = info.indent,
        child_indent = info.indent + 2,
        parent_key = parent_key,
        index = parent and parent.next_item_index or state.root_next_item_index,
        inline_key = info.key,
        scalar_value = info.scalar_value,
        start_line = lnum,
        opened_block = info.key and (info.value == "" or is_block_value(info.value)) or false,
        scalar_block = not info.key and is_block_value(info.scalar_value),
      })
    end

    if info.key and (info.value == "" or is_block_value(info.value)) then
      table.insert(state.stack, {
        type = "block",
        indent = info.indent + 2,
        child_indent = info.indent + 4,
        key = info.key,
        next_item_index = 0,
      })
      state.block_scalar_indent = block_scalar_child_indent(info)
    elseif is_block_value(info.scalar_value) then
      state.block_scalar_indent = block_scalar_child_indent(info)
    elseif info.key and info.value and info.value ~= "" then
      local item = current_item(state)
      if
        item
        and item.child_indent == info.indent + 2
        and is_item_label_key(item.parent_key, info.key)
        and label_priority(item.parent_key, info.key)
          < label_priority(item.parent_key, item.label_key)
      then
        item.label = info.value
        item.label_key = info.key
      end
    end
    return
  end

  if not info.key then
    return
  end

  pop_to_line(state, info.indent)

  local item = current_item(state)
  if
    item
    and info.key
    and info.value
    and info.value ~= ""
    and item.child_indent == info.indent
    and state.stack[#state.stack] == item
    and is_item_label_key(item.parent_key, info.key)
    and label_priority(item.parent_key, info.key)
      < label_priority(item.parent_key, item.label_key)
  then
    item.label = info.value
    item.label_key = info.key
  end

  if info.value == "" or is_block_value(info.value) then
    table.insert(state.stack, {
      type = "block",
      indent = info.indent,
      child_indent = info.indent + 2,
      key = info.key,
      next_item_index = 0,
    })
    state.block_scalar_indent = block_scalar_child_indent(info)
  end
end

local function find_envfrom_label(lines, item)
  local active_ref = (item.inline_key == "secretRef" or item.inline_key == "configMapRef")
      and item.inline_key
    or nil

  for lnum = item.start_line + 1, #lines do
    local info = parse_line(lines[lnum])
    if info then
      if info.indent < item.child_indent then
        break
      end
      if info.is_list_item and info.indent == item.indent then
        break
      end

      if info.indent == item.child_indent and (info.key == "secretRef" or info.key == "configMapRef") then
        active_ref = info.key
      elseif info.indent == item.child_indent and info.key then
        active_ref = nil
      elseif
        active_ref
        and info.indent == item.child_indent + 2
        and info.key == "name"
        and info.value
        and info.value ~= ""
      then
        return string.format("%s:%s", active_ref, info.value)
      elseif active_ref and info.indent <= item.child_indent then
        active_ref = nil
      end
    end
  end

  return nil
end

local function find_item_label(lines, item, label_cache)
  if not item.start_line then
    return item.label
  end

  local cache_key = item_cache_key(item)
  if label_cache[cache_key] ~= nil then
    return label_cache[cache_key]
  end

  if item.parent_key == "envFrom" then
    local envfrom_label = find_envfrom_label(lines, item)
    if envfrom_label then
      label_cache[cache_key] = envfrom_label
      return envfrom_label
    end
  end

  local best_label = item.label
  local best_priority = label_priority(item.parent_key, item.label_key)
  local block_stack = {}
  local scalar_indent = nil
  if item.opened_block then
    table.insert(block_stack, item.indent + 4)
  end

  for lnum = item.start_line + 1, #lines do
    local line = lines[lnum]
    local line_indent = indent_of(line or "")
    local is_blank = line == nil or line:match("^%s*$") ~= nil

    if scalar_indent and (is_blank or line_indent >= scalar_indent) then
      goto continue
    end
    if scalar_indent and not is_blank and line_indent < scalar_indent then
      scalar_indent = nil
    end

    local info = parse_line(line)
    if info then
      if info.indent < item.child_indent then
        break
      end
      if info.is_list_item and info.indent == item.indent then
        break
      end

      while #block_stack > 0 and block_stack[#block_stack] > info.indent do
        table.remove(block_stack)
      end

      if
        info.value
        and info.value ~= ""
        and info.indent == item.child_indent
        and #block_stack == 0
      then
        local priority = label_priority(item.parent_key, info.key)
        if priority < best_priority then
          best_label = info.value
          best_priority = priority
          if priority == 1 then
            return best_label
          end
        end
      end

      if info.is_list_item and info.key and info.value == "" then
        table.insert(block_stack, info.indent + 4)
      elseif not info.is_list_item and info.key and info.value == "" then
        table.insert(block_stack, info.indent + 2)
      end

      scalar_indent = block_scalar_child_indent(info) or scalar_indent
    end
    ::continue::
  end

  label_cache[cache_key] = best_label
  return best_label
end

local function current_line_key(info)
  return info and info.key or nil
end

local function is_block_key(info)
  return info and info.key ~= nil and (info.value == "" or is_block_value(info.value))
end

local function render_parts(kind, stack, lines, label_cache)
  local parts = {}
  if kind then
    table.insert(parts, kind)
  end

  for _, entry in ipairs(stack) do
    if entry.type == "block" then
      table.insert(parts, entry.key)
    elseif entry.type == "item" then
      local label = find_item_label(lines, entry, label_cache)
      if entry.parent_key == nil then
        table.insert(parts, string.format("[%s]", label or entry.index))
      elseif parts[#parts] == entry.parent_key then
        local suffix = label or entry.index
        if suffix then
          parts[#parts] = string.format("%s[%s]", entry.parent_key, suffix)
        end
      end
    end
  end

  return parts
end

local function step_line(state, line, lnum)
  local line_indent = indent_of(line or "")
  local is_blank = line == nil or line:match("^%s*$") ~= nil

  if state.block_scalar_indent and (is_blank or line_indent >= state.block_scalar_indent) then
    return true
  end

  if state.block_scalar_indent and not is_blank and line_indent < state.block_scalar_indent then
    state.block_scalar_indent = nil
  end

  process_line(state, parse_line(line), lnum)
  return false
end

local function get_buffer_cache(bufnr)
  local changedtick = 0
  if vim.b and vim.b[bufnr] and vim.b[bufnr].changedtick then
    changedtick = vim.b[bufnr].changedtick
  end
  local cached = cache_by_buf[bufnr]
  if cached and cached.changedtick == changedtick then
    return cached
  end

  local fresh = {
    changedtick = changedtick,
    lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false),
    snapshots = {
      [0] = {
        stack = {},
        kind = nil,
        block_scalar_indent = nil,
        root_next_item_index = 0,
      },
    },
    opaque_lines = {},
    label_cache = {},
    built_until = 0,
  }
  cache_by_buf[bufnr] = fresh
  return fresh
end

local function build_to_line(buf_cache, target_line)
  local last = math.min(target_line, #buf_cache.lines)
  for lnum = buf_cache.built_until + 1, last do
    local state = clone_state(buf_cache.snapshots[lnum - 1])
    buf_cache.opaque_lines[lnum] = step_line(state, buf_cache.lines[lnum], lnum)
    buf_cache.snapshots[lnum] = state
    buf_cache.built_until = lnum
  end
end

function M.current_path(bufnr, cursor_line)
  bufnr = bufnr or 0
  if bufnr == 0 then
    bufnr = (vim.api and vim.api.nvim_get_current_buf and vim.api.nvim_get_current_buf()) or 0
  end
  cursor_line = cursor_line or vim.api.nvim_win_get_cursor(0)[1]

  if vim.bo[bufnr].filetype ~= "yaml" then
    return ""
  end

  local buf_cache = get_buffer_cache(bufnr)
  build_to_line(buf_cache, cursor_line)

  local state = buf_cache.snapshots[math.min(cursor_line, #buf_cache.lines)] or buf_cache.snapshots[0]
  local parts = render_parts(state.kind, state.stack, buf_cache.lines, buf_cache.label_cache)
  local current = nil
  if not buf_cache.opaque_lines[cursor_line] then
    current = parse_line(buf_cache.lines[cursor_line])
  end
  local key = current_line_key(current)

  if
    key
    and (
      not is_block_key(current)
      or state.stack[#state.stack] == nil
      or state.stack[#state.stack].key ~= key
    )
  then
    table.insert(parts, key)
  end

  return table.concat(parts, ".")
end

function M.clear_cache(bufnr)
  if bufnr == nil then
    cache_by_buf = {}
    return
  end
  cache_by_buf[bufnr] = nil
end

return M
