# Changelog

## Before 2026-04-22

- YAML paths were resolved by a line-by-line indentation-based parser introduced in the initial commit.
- The parser assumed formatter-normalized YAML with stable indentation and list children indented two spaces deeper than the `-`.

## 2026-04-22

- Switched YAML path resolution to Tree-sitter-based parsing for buffer-aware path construction.
- Added support for `yamlfmt` output with `indentless_arrays: true`.
- Updated the test harness to run inside headless Neovim so Tree-sitter-backed parsing is covered in tests.
- Added documentation for the recommended `yamlfmt` configuration and the Tree-sitter dependency.
