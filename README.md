# git-annotate.nvim

Annotate your code like PyCharm/IntelliJ — in Neovim.

Opens a sidebar showing `git blame` info with time-based gradient coloring: warm orange for recent commits, cold gray-blue for older ones — so you can spot recent changes at a glance.

> 中文文档：[README_ZH.md](README_ZH.md)

## Installation

Using [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "shenyfg/git-annotate.nvim",
  config = function()
    vim.keymap.set("n", "<leader>gb", require("git_annotate").annotate, { desc = "Git Annotate" })
  end,
}
```

## Usage

Run `:lua require("git_annotate").annotate()` or use your keymap to toggle and automatically focus the sidebar on the left of the current file.

### Sidebar Keymaps

| Key | Description |
|---|---|
| `q` / `<Esc>` | Close the sidebar |
| `s` | Open `git show` for the commit under cursor in a vsplit |
| `d` | List changed files in Snacks and preview the selected file diff |
| `]]` | Jump to the next occurrence of the same commit in the file |
| `[[` | Jump to the previous occurrence of the same commit in the file |
| `]c` | Jump to the start of the next commit block |
| `[c` | Jump to the start of the previous commit block |

> `d` requires [snacks.nvim](https://github.com/folke/snacks.nvim). The picker starts on the current file when possible; press `s` to open the selected file diff in a vsplit, or `S` to open the complete commit/tracked working tree diff. Untracked files are available through their per-file preview. Use the sidebar `s` key if Snacks isn't installed.

## Large commit protection

- Diff output opened with `s`/`S`, per-file previews opened with `d`, and commit file lists are limited to 2 MiB. Oversized output is truncated and clearly marked.
- Whole root-commit views show metadata only and omit the complete patch. The `d` picker still lists root-commit files and safely previews only the selected file.

## Requirements

- Neovim 0.10+
- Git available in `$PATH`
- [snacks.nvim](https://github.com/folke/snacks.nvim) (optional, only for `d`)
