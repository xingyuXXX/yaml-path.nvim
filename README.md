# yaml-path.nvim

Fast YAML path resolution for Neovim statuslines, optimized for formatter-normalized Kubernetes manifests.

## What It Does

`yaml-path.nvim` returns a dotted path for the current cursor position in a YAML buffer, with readable labels for common Kubernetes list items:

```sh
pod.spec.containers[app].image
pod.spec.containers[app].ports[http].containerPort
pod.spec.containers[app].envFrom[configMapRef:app-config].configMapRef
```

It is designed for statusline components such as `lualine`.

## Scope

This is not a full YAML parser. It uses Tree-sitter's YAML parser to resolve the current position into a dotted path.

The resolver is intentionally tuned for:

- formatter-normalized, block-style YAML
- Kubernetes-style manifests
- readable labels for common list items such as containers, ports, and envFrom

It intentionally does not try to support every YAML feature or invent labels for every possible sequence shape.

Recommended `yamlfmt` config:

```yaml
formatter:
  indent: 2
  indentless_arrays: true
  include_document_start: false
  eof_newline: true
  retain_line_breaks: true
  pad_line_comments: 1
```

## Installation

With `lazy.nvim`:

```lua
{
  "xingyuXXX/yaml-path.nvim",
  dependencies = { "nvim-treesitter/nvim-treesitter" },
}
```

Make sure the `yaml` Tree-sitter parser is installed.

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

`require("yaml_path").copy_current_path(opts?)`

- copies the current YAML path into the clipboard register by default
- returns the copied string, or `""` when no YAML path is available
- `opts.register`: optional register name, defaults to `"+"`
- `opts.notify`: set to `false` to skip `vim.notify`

`require("yaml_path").clear_cache(bufnr?)`

- clears cached parse state for one buffer
- clears all cached buffers when called without arguments

With LazyVim, the native place for the hotkey is the plugin spec `keys` table. `<leader>yp` is a good default: it follows the mnemonic "yank path" and does not fight LazyVim's built-in groups.

```lua
{
  "xingyuXXX/yaml-path.nvim",
  keys = {
    {
      "<leader>yp",
      function()
        require("yaml_path").copy_current_path()
      end,
      desc = "Yank YAML Path",
    },
  },
}
```

## Testing

Run the headless Neovim test harness from the repo root:

```bash
nvim --headless -u NONE -i NONE -l tests/check.lua
```

## License

MIT
