-- This helper intentionally targets Tree-sitter-parsed, block-style YAML.
-- It is optimized for common Kubernetes navigation paths in statuslines rather
-- than trying to expose every YAML construct.

local M = {}
local cache_by_buf = {}

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function changedtick_for(bufnr)
  if vim.b and vim.b[bufnr] and vim.b[bufnr].changedtick then
    return vim.b[bufnr].changedtick
  end
  return 0
end

local function node_text(bufnr, node)
  if not node then
    return nil
  end

  local ok, text = pcall(vim.treesitter.get_node_text, node, bufnr)
  if not ok or not text then
    return nil
  end

  text = trim(text)
  if text == "" then
    return nil
  end

  local quote = text:match([[^(["']).*%1$]])
  if quote and #text >= 2 then
    return text:sub(2, -2)
  end

  return text
end

local function named_children(node)
  local out = {}
  if not node then
    return out
  end

  for idx = 0, node:named_child_count() - 1 do
    out[#out + 1] = node:named_child(idx)
  end

  return out
end

local function first_named_child(node, expected_type)
  for _, child in ipairs(named_children(node)) do
    if expected_type == nil or child:type() == expected_type then
      return child
    end
  end
  return nil
end

local function mapping_pairs(mapping_node)
  local out = {}
  if not mapping_node or mapping_node:type() ~= "block_mapping" then
    return out
  end

  for _, child in ipairs(named_children(mapping_node)) do
    if child:type() == "block_mapping_pair" then
      out[#out + 1] = child
    end
  end

  return out
end

local function sequence_items(sequence_node)
  local out = {}
  if not sequence_node or sequence_node:type() ~= "block_sequence" then
    return out
  end

  for _, child in ipairs(named_children(sequence_node)) do
    if child:type() == "block_sequence_item" then
      out[#out + 1] = child
    end
  end

  return out
end

local function pair_key_text(bufnr, pair_node)
  return node_text(bufnr, pair_node and pair_node:named_child(0) or nil)
end

local function pair_value_node(pair_node)
  if not pair_node or pair_node:named_child_count() < 2 then
    return nil
  end
  return pair_node:named_child(1)
end

local function scalar_text(bufnr, node)
  if not node then
    return nil
  end

  if node:type() == "flow_node" then
    return node_text(bufnr, node)
  end

  return nil
end

local function block_content_node(block_node)
  if not block_node or block_node:type() ~= "block_node" then
    return nil
  end
  return block_node:named_child(0)
end

local function top_level_item_pairs(item_node)
  local payload = first_named_child(item_node)
  if not payload then
    return {}
  end

  if payload:type() == "block_node" then
    return mapping_pairs(block_content_node(payload))
  end

  return {}
end

local function nested_mapping_pairs(pair_node)
  local value = pair_value_node(pair_node)
  if not value or value:type() ~= "block_node" then
    return {}
  end

  return mapping_pairs(block_content_node(value))
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

local function label_priority(parent_key, key)
  if not key then
    return math.huge
  end

  for idx, candidate in ipairs(item_label_keys(parent_key)) do
    if key == candidate then
      return idx
    end
  end

  return math.huge
end

local function item_index(item_node)
  local parent = item_node and item_node:parent() or nil
  if not parent then
    return 1
  end

  local index = 0
  for _, child in ipairs(sequence_items(parent)) do
    index = index + 1
    if child:id() == item_node:id() then
      return index
    end
  end

  return 1
end

local function find_envfrom_label(bufnr, item_node)
  for _, pair in ipairs(top_level_item_pairs(item_node)) do
    local key = pair_key_text(bufnr, pair)
    if key == "configMapRef" or key == "secretRef" then
      for _, nested_pair in ipairs(nested_mapping_pairs(pair)) do
        if pair_key_text(bufnr, nested_pair) == "name" then
          local value = scalar_text(bufnr, pair_value_node(nested_pair))
          if value and value ~= "" then
            return string.format("%s:%s", key, value)
          end
        end
      end
    end
  end

  return nil
end

local function find_item_label(bufnr, item_node, parent_key, label_cache)
  local cache_key = tostring(item_node:id())
  if label_cache[cache_key] ~= nil then
    return label_cache[cache_key]
  end

  if parent_key == "envFrom" then
    local envfrom_label = find_envfrom_label(bufnr, item_node)
    if envfrom_label then
      label_cache[cache_key] = envfrom_label
      return envfrom_label
    end
  end

  local best_label = nil
  local best_priority = math.huge

  for _, pair in ipairs(top_level_item_pairs(item_node)) do
    local key = pair_key_text(bufnr, pair)
    local priority = label_priority(parent_key, key)
    if priority < best_priority then
      local value = scalar_text(bufnr, pair_value_node(pair))
      if value and value ~= "" then
        best_label = value
        best_priority = priority
      end
    end
  end

  label_cache[cache_key] = best_label
  return best_label
end

local function buffer_cache(bufnr)
  local changedtick = changedtick_for(bufnr)
  local cached = cache_by_buf[bufnr]
  if cached and cached.changedtick == changedtick then
    return cached
  end

  local ok, parser = pcall(vim.treesitter.get_parser, bufnr, "yaml")
  if not ok or not parser then
    return nil
  end

  local trees = parser:parse()
  local tree = trees and trees[1] or nil
  if not tree then
    return nil
  end

  local fresh = {
    changedtick = changedtick,
    lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false),
    root = tree:root(),
    label_cache = {},
    kind_cache = {},
  }
  cache_by_buf[bufnr] = fresh
  return fresh
end

local function node_for_cursor(root, row, line_text)
  local text = line_text or ""
  local first_non_space = text:find("%S") or 1
  local col = math.max(first_non_space - 1, 0)

  if text:sub(first_non_space):match("^%-%s+") then
    local payload_start = text:find("%S", first_non_space + 1)
    if payload_start then
      col = payload_start - 1
    end
  end

  local node = root:named_descendant_for_range(row, col, row, col)
  if node then
    return node
  end
  return root:named_descendant_for_range(row, 0, row, 0)
end

local function ancestors_from_root(node)
  local out = {}
  while node do
    table.insert(out, 1, node)
    node = node:parent()
  end
  return out
end

local function document_kind(bufnr, document_node, kind_cache)
  local cache_key = tostring(document_node:id())
  if kind_cache[cache_key] ~= nil then
    return kind_cache[cache_key]
  end

  local doc_block = first_named_child(document_node, "block_node")
  local doc_content = block_content_node(doc_block)
  local kind = nil

  if doc_content and doc_content:type() == "block_mapping" then
    for _, pair in ipairs(mapping_pairs(doc_content)) do
      if pair_key_text(bufnr, pair) == "kind" then
        local value = scalar_text(bufnr, pair_value_node(pair))
        if value and value ~= "" then
          kind = value:lower()
          break
        end
      end
    end
  end

  kind_cache[cache_key] = kind
  return kind
end

local function render_path(bufnr, cache, target_node)
  local parts = {}
  local parent_key = nil
  local document_node = nil

  for _, node in ipairs(ancestors_from_root(target_node)) do
    local node_type = node:type()

    if node_type == "document" then
      document_node = node
      local kind = document_kind(bufnr, node, cache.kind_cache)
      if kind then
        parts[#parts + 1] = kind
      end
      parent_key = nil
    elseif node_type == "block_mapping_pair" then
      local key = pair_key_text(bufnr, node)
      if key then
        parts[#parts + 1] = key
        parent_key = key
      end
    elseif node_type == "block_sequence_item" then
      local suffix = find_item_label(bufnr, node, parent_key, cache.label_cache) or item_index(node)
      if parent_key == nil then
        parts[#parts + 1] = string.format("[%s]", suffix)
      elseif parts[#parts] == parent_key then
        parts[#parts] = string.format("%s[%s]", parent_key, suffix)
      end
    end
  end

  if not document_node then
    return ""
  end

  return table.concat(parts, ".")
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

  if not vim.treesitter or not vim.treesitter.get_parser then
    return ""
  end

  local cache = buffer_cache(bufnr)
  if not cache then
    return ""
  end

  local row = math.max(cursor_line - 1, 0)
  local line_text = cache.lines[cursor_line] or ""
  local target = node_for_cursor(cache.root, row, line_text)
  if not target then
    return ""
  end

  return render_path(bufnr, cache, target)
end

function M.copy_current_path(opts)
  opts = opts or {}

  local value = M.current_path(opts.bufnr, opts.cursor_line)
  if value == "" then
    if opts.notify ~= false and vim.notify then
      vim.notify("No YAML path available", vim.log and vim.log.levels and vim.log.levels.WARN or nil)
    end
    return ""
  end

  local register = opts.register or "+"
  if vim.fn and vim.fn.setreg then
    vim.fn.setreg(register, value)
    if register ~= '"' then
      vim.fn.setreg('"', value)
    end
  end

  if opts.notify ~= false and vim.notify then
    vim.notify(string.format("Copied YAML path to %s", register))
  end

  return value
end

function M.clear_cache(bufnr)
  if bufnr == nil then
    cache_by_buf = {}
    return
  end
  cache_by_buf[bufnr] = nil
end

return M
