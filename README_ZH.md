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

执行 `:lua require("git_annotate").annotate()` 或绑定快捷键后，在当前文件左侧打开侧边栏并自动聚焦。再次执行则关闭（toggle）。

### 侧边栏快捷键

| 键 | 说明 |
|---|---|
| `q` / `<Esc>` | 关闭侧边栏 |
| `s` | 在右侧 vsplit 中查看当前行所在 commit 的 `git show` |
| `d` | 用 Snacks 列出变更文件，并预览选中文件的 diff |
| `]]` | 跳到当前 commit 在文件中的下一个块 |
| `[[` | 跳到当前 commit 在文件中的上一个块 |
| `]c` | 跳到下一个不同 commit 块的起始行 |
| `[c` | 跳到上一个不同 commit 块的起始行 |

> `d` 键依赖 [snacks.nvim](https://github.com/folke/snacks.nvim)。picker 会尽量默认选中当前文件；按 `s` 在 vsplit 打开选中文件的 diff，按 `S` 打开完整 commit/已跟踪工作区 diff；未跟踪文件可通过单文件预览查看。若未安装 Snacks，请使用侧边栏的 `s` 键。

## 大提交保护

- 通过 `s`/`S` 打开的 diff、通过 `d` 打开的单文件预览和 commit 文件列表最多读取 2 MiB；超出后会终止读取并明确标记已截断。
- 根提交的完整视图只展示 metadata，不加载整个 patch；`d` picker 仍会列出文件，并仅安全预览选中文件。

## 依赖

- Neovim 0.10+
- Git（在 `$PATH` 中可用）
- [snacks.nvim](https://github.com/folke/snacks.nvim)（可选，仅 `d` 键需要）
