package.path = table.concat({
  "./lua/?.lua",
  "./lua/?/init.lua",
  package.path,
}, ";")

local yaml_path = require("yaml_path")

vim = vim or {}
vim.bo = setmetatable({}, {
  __index = function()
    return { filetype = "yaml" }
  end,
})
vim.b = vim.b
  or setmetatable({}, {
    __index = function(t, k)
      local v = { changedtick = 0 }
      rawset(t, k, v)
      return v
    end,
  })
vim.api = vim.api or {}
vim.fn = vim.fn or {}
local changedtick = 0
local registers = {}

vim.fn.setreg = function(name, value)
  registers[name] = value
end

local function set_lines(lines)
  changedtick = changedtick + 1
  yaml_path.clear_cache(0)
  vim.b[0].changedtick = changedtick
  registers = {}
  vim.api.nvim_buf_get_lines = function(_, start_, end_, _)
    local last = end_ == -1 and #lines or end_
    local out = {}
    for i = start_ + 1, last do
      out[#out + 1] = lines[i]
    end
    return out
  end
end

local function current_path(lines, line)
  set_lines(lines)
  vim.api.nvim_win_get_cursor = function()
    return { line, 1 }
  end
  return yaml_path.current_path(0, line)
end

local function copy_current_path(lines, line, opts)
  set_lines(lines)
  vim.api.nvim_win_get_cursor = function()
    return { line, 1 }
  end
  return yaml_path.copy_current_path(opts)
end

local cases = {
  {
    name = "container image",
    line = 13,
    expected = "pod.spec.containers[app].image",
    lines = {
      "apiVersion: v1",
      "kind: Pod",
      "spec:",
      "  containers:",
      "    - env:",
      "        - name: KUBERNETES_SERVICE_HOST",
      "          value: api.example",
      "      envFrom:",
      "        - configMapRef:",
      "            name: app-config",
      "        - secretRef:",
      "            name: app-secret",
      "      image: repo/app:1",
      "      name: app",
      "      ports:",
      "        - containerPort: 8080",
      "          name: http",
    },
  },
  {
    name = "envFrom entries use referenced names",
    line = 6,
    expected = "pod.spec.containers[app].envFrom[configMapRef:app-config].configMapRef",
    lines = {
      "kind: Pod",
      "spec:",
      "  containers:",
      "    - name: app",
      "      envFrom:",
      "        - configMapRef:",
      "            name: app-config",
      "        - secretRef:",
      "            name: app-secret",
    },
  },
  {
    name = "port label fallback",
    line = 7,
    expected = "pod.spec.containers[app].ports[8080].containerPort",
    lines = {
      "apiVersion: v1",
      "kind: Pod",
      "spec:",
      "  containers:",
      "    - name: app",
      "      ports:",
      "        - containerPort: 8080",
    },
  },
  {
    name = "port label prefers later name",
    line = 7,
    expected = "pod.spec.containers[app].ports[http].containerPort",
    lines = {
      "apiVersion: v1",
      "kind: Pod",
      "spec:",
      "  containers:",
      "    - name: app",
      "      ports:",
      "        - containerPort: 8080",
      "          name: http",
    },
  },
  {
    name = "nested metadata stays nested",
    line = 3,
    expected = "items[1].metadata.name",
    lines = {
      "items:",
      "  - metadata:",
      "      name: foo",
    },
  },
  {
    name = "inline comment on opened mapping",
    line = 3,
    expected = "pod.metadata.name",
    lines = {
      "kind: Pod",
      "metadata: # comment",
      "  name: foo",
      "  namespace: default",
    },
  },
  {
    name = "inline comment stripped from label",
    line = 5,
    expected = "pod.spec.containers[app].image",
    lines = {
      "kind: Pod",
      "spec:",
      "  containers:",
      "    - name: app # main",
      "      image: nginx",
    },
  },
  {
    name = "scalar args entries are distinct",
    line = 8,
    expected = "pod.spec.containers[app].args[2]",
    lines = {
      "apiVersion: v1",
      "kind: Pod",
      "spec:",
      "  containers:",
      "    - name: app",
      "      args:",
      "        - --foo",
      "        - bar",
    },
  },
  {
    name = "block scalar header stays in path",
    line = 5,
    expected = "configmap.data.script",
    lines = {
      "kind: ConfigMap",
      "data:",
      "  script: |",
      "    echo hello",
      "    exit 0",
    },
  },
  {
    name = "block scalar content is opaque",
    line = 5,
    expected = "configmap.data.script",
    lines = {
      "kind: ConfigMap",
      "data:",
      "  script: |",
      "    echo name: foo",
      "    - bar",
    },
  },
  {
    name = "list item block scalar content is opaque",
    line = 7,
    expected = "pod.spec.containers[app].args[1]",
    lines = {
      "kind: Pod",
      "spec:",
      "  containers:",
      "    - name: app",
      "      args:",
      "        - |",
      "          echo name: foo",
      "          - bar",
    },
  },
  {
    name = "nested metadata does not label item",
    line = 4,
    expected = "rules[1].value",
    lines = {
      "rules:",
      "  - metadata:",
      "      name: foo",
      "    value: bar",
    },
  },
  {
    name = "unlabeled mapping items keep indices",
    line = 6,
    expected = "pod.spec.tolerations[2].key",
    lines = {
      "kind: Pod",
      "spec:",
      "  tolerations:",
      "    - key: dedicated",
      "      operator: Equal",
      "    - key: gpu",
      "      operator: Exists",
    },
  },
  {
    name = "root sequence items are tracked",
    line = 2,
    expected = "[app].image",
    lines = {
      "- name: app",
      "  image: nginx",
      "- name: sidecar",
      "  image: busybox",
    },
  },
  {
    name = "root sequence numbering resets per document",
    line = 4,
    expected = "[third].name",
    lines = {
      "- name: first",
      "- name: second",
      "---",
      "- name: third",
      "  value: ok",
    },
  },
  {
    name = "multi document reset",
    line = 9,
    expected = "pod.spec.containers[web].image",
    lines = {
      "kind: ConfigMap",
      "metadata:",
      "  name: one",
      "---",
      "kind: Pod",
      "spec:",
      "  containers:",
      "    - name: web",
      "      image: nginx",
    },
  },
}

local failed = false

for _, case in ipairs(cases) do
  local got = current_path(case.lines, case.line)
  if got ~= case.expected then
    failed = true
    io.stderr:write(
      string.format("%s\n  expected: %s\n  got:      %s\n", case.name, case.expected, got)
    )
  end
end

local copy_cases = {
  {
    name = "copy stores path in clipboard and unnamed registers",
    line = 5,
    expected = "pod.spec.containers[app].image",
    expected_registers = {
      ['"'] = "pod.spec.containers[app].image",
      ["+"] = "pod.spec.containers[app].image",
    },
    lines = {
      "kind: Pod",
      "spec:",
      "  containers:",
      "    - name: app",
      "      image: nginx",
    },
  },
  {
    name = "copy supports explicit register",
    line = 3,
    expected = "pod.metadata.name",
    opts = { register = "a", notify = false },
    expected_registers = {
      ['"'] = "pod.metadata.name",
      a = "pod.metadata.name",
    },
    lines = {
      "kind: Pod",
      "metadata:",
      "  name: demo",
    },
  },
  {
    name = "copy returns empty string for non yaml buffers",
    line = 1,
    expected = "",
    opts = { notify = false },
    expected_registers = {},
    before = function()
      vim.bo[0] = { filetype = "lua" }
    end,
    after = function()
      vim.bo[0] = { filetype = "yaml" }
    end,
    lines = { 'print("hi")' },
  },
}

for _, case in ipairs(copy_cases) do
  if case.before then
    case.before()
  end

  local got = copy_current_path(case.lines, case.line, case.opts)
  if got ~= case.expected then
    failed = true
    io.stderr:write(
      string.format("%s\n  expected: %s\n  got:      %s\n", case.name, case.expected, got)
    )
  end

  for register, expected in pairs(case.expected_registers) do
    local actual = registers[register]
    if actual ~= expected then
      failed = true
      io.stderr:write(
        string.format(
          "%s register %s\n  expected: %s\n  got:      %s\n",
          case.name,
          register,
          expected,
          tostring(actual)
        )
      )
    end
  end

  for register, actual in pairs(registers) do
    if case.expected_registers[register] == nil then
      failed = true
      io.stderr:write(
        string.format("%s unexpected register %s\n  got:      %s\n", case.name, register, tostring(actual))
      )
    end
  end

  if case.after then
    case.after()
  end
end

if failed then
  os.exit(1)
end

print(string.format("yaml_path: %d cases passed", #cases + #copy_cases))
