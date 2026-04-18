# yaml-path.nvim

Fast YAML path resolution for Neovim statuslines, optimized for formatter-normalized Kubernetes manifests.

## What It Does

`yaml-path.nvim` returns a dotted path for the current cursor position in a YAML buffer, with readable labels for common Kubernetes list items:

- `pod.spec.containers[app].image`
- `pod.spec.containers[app].ports[http].containerPort`
- `pod.spec.containers[app].envFrom[configMapRef:app-config].configMapRef`

It is designed for statusline components such as `lualine`.

## Scope

This is not a full YAML parser.

The resolver is intentionally tuned for:

- formatter-normalized, block-style YAML
- stable indentation
- Kubernetes-style manifests

It intentionally does not try to support every YAML feature or ambiguous formatting style.

## Installation

With `lazy.nvim`:

```lua
{
  "xingyuXXX/yaml-path.nvim",
}
```

## Usage

Basic usage:

```lua
local yaml_path = require("yaml_path")

print(yaml_path.current_path())
```

With `lualine.nvim`:

```lua
require("lualine").setup({
  sections = {
    lualine_c = {
      function()
        return require("yaml_path").current_path()
      end,
    },
  },
})
```

The function returns `""` for non-YAML buffers.

## API

`require("yaml_path").current_path(bufnr?, cursor_line?)`

- `bufnr`: optional buffer number, defaults to current buffer
- `cursor_line`: optional 1-based cursor line, defaults to current cursor line

`require("yaml_path").clear_cache(bufnr?)`

- clears cached parse state for one buffer
- clears all cached buffers when called without arguments

## Testing

Run the standalone Lua test harness from the repo root:

```bash
lua tests/check.lua
```

## License

MIT
