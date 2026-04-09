# git-annotate.nvim

Annotate your code like PyCharm/IntelliJ — in Neovim.

在左侧侧边栏展示 `git blame` 信息，按提交时间新旧渐变着色，支持快速跳转与查看 diff。

## 效果

侧边栏显示每行的提交日期和作者，颜色从冷灰蓝（旧提交）到暖橙色（新提交）渐变，视觉上一眼看出哪些代码是最近改动的。

## 安装

使用 [lazy.nvim](https://github.com/folke/lazy.nvim)：

```lua
{
  "shenyfg/git-annotate.nvim",
  config = function()
    vim.keymap.set("n", "<leader>gb", require("git_annotate").annotate, { desc = "Git Annotate" })
  end,
}
```

## 使用

执行 `:lua require("git_annotate").annotate()` 或绑定快捷键后，在当前文件左侧打开侧边栏。再次执行则关闭（toggle）。

### 侧边栏快捷键

| 键 | 说明 |
|---|---|
| `q` / `<Esc>` | 关闭侧边栏 |
| `s` | 在右侧 vsplit 中查看当前行所在 commit 的 `git show` |
| `d` | 用 Snacks picker 展示 diff（未提交行展示工作区 diff） |
| `]]` | 跳到下一个不同 commit 块的起始行 |
| `[[` | 跳到上一个不同 commit 块的起始行 |
| `]c` | 跳到当前 commit 在文件中的下一个块 |
| `[c` | 跳到当前 commit 在文件中的上一个块 |

> `d` 键依赖 [snacks.nvim](https://github.com/folke/snacks.nvim)，若未安装请使用 `s` 键。

## 依赖

- Neovim 0.10+
- Git（在 `$PATH` 中可用）
- [snacks.nvim](https://github.com/folke/snacks.nvim)（可选，仅 `d` 键需要）
