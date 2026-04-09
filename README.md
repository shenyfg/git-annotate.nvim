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

Run `:lua require("git_annotate").annotate()` or use your keymap to toggle the sidebar on the left of the current file.

### Sidebar Keymaps

| Key | Description |
|---|---|
| `q` / `<Esc>` | Close the sidebar |
| `s` | Open `git show` for the commit under cursor in a vsplit |
| `d` | Show diff in Snacks picker (working tree diff for uncommitted lines) |
| `]]` | Jump to the start of the next commit block |
| `[[` | Jump to the start of the previous commit block |
| `]c` | Jump to the next occurrence of the same commit in the file |
| `[c` | Jump to the previous occurrence of the same commit in the file |

> `d` requires [snacks.nvim](https://github.com/folke/snacks.nvim). Use `s` if it's not installed.

## Requirements

- Neovim 0.10+
- Git available in `$PATH`
- [snacks.nvim](https://github.com/folke/snacks.nvim) (optional, only for `d`)
