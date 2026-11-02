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

执行 `:lua require("git_annotate").log()`，直接从 `HEAD` 打开变更文件、提交历史和单文件 diff 界面。使用当前文件所在仓库；无文件名或特殊 buffer 使用 cwd。退出后返回原编辑窗口。下面的 `f`、`p` / `n`、`K`、`O` 和 `<C-o>` 操作在这个界面同样可用。

LazyVim 可在插件的 `keys` 中加入：

```lua
{ "<leader>gl", function() require("git_annotate").log() end, desc = "Git Log (Annotate)" },
```

### 侧边栏快捷键

| 键 | 说明 |
|---|---|
| `q` / `<Esc>` | 关闭侧边栏 |
| `K` | 显示当前行的提交信息；再按一次进入浮窗，按 `q` / `<Esc>` / `K` 关闭并返回侧边栏 |
| `O` | 在默认浏览器打开当前行对应的提交（依赖 Snacks） |
| `d` | 用 Snacks 展示变更文件、仓库提交历史和单文件 diff |
| `]]` | 跳到当前 commit 在文件中的下一个块 |
| `[[` | 跳到当前 commit 在文件中的上一个块 |
| `]c` | 跳到后方最近的 commit 首次出现行（跳过重复 commit 块） |
| `[c` | 跳到前方最近的 commit 首次出现行（跳过重复 commit 块） |

> `d` 键依赖 [snacks.nvim](https://github.com/folke/snacks.nvim)。picker 会尽量默认选中当前文件，并预览选中文件的 diff；未跟踪文件也可通过单文件预览查看。

在 picker 的文件列表、搜索框或 diff 预览区，普通模式下按 `O` 可在默认浏览器打开当前选中的提交；通过 `p`/`n` 切换后会打开切换后的提交。此操作保留当前窗口。未提交修改会提示没有对应的提交页面；仓库有多个 remote 时由 Snacks 提供选择。

在详情界面按 `<CR>` 或普通模式 `o`，会关闭详情并在原编辑窗口打开当前选中文件的工作区版本。文件已不存在时提示其路径，并保留详情界面。

普通模式按 `f`，可在当前界面实时筛选 commit 历史。匹配 SHA、提交标题和作者，忽略大小写；空格分隔的多个词需全部按字面匹配。输入时历史列表和选中提交的 diff 同步更新。按 `<CR>` 保留筛选，`<Esc>` 或 `<C-c>` 恢复打开筛选前的条件与提交。再次按 `f` 可修改条件，清空输入并确认可恢复全部历史。`p` / `n` 在匹配提交之间切换，历史列表顶部显示筛选条件和匹配数量。无匹配时明确提示并保留之前的 diff。筛选期间会异步加载较早的历史批次，直至搜索完整历史。

在文件列表或搜索框按 `<C-o>` 可切换到 diff 预览，再按 `<C-o>` 返回原来的列表或搜索框；从搜索框插入模式进入时，返回后会恢复插入模式。

文件列表标题显示作者与本地时间：当天为 `shenyfg  Today 16:51`，其他日期为 `shenyfg  2026/8/25, 15:23`。diff 预览窗口的顶部标题显示提交说明的第一行，例如 `docs: 添加中英文 README 并完善插件文档`，切换文件或滚动 diff 时保持可见。文件路径显示在 diff 内容中，不再重复出现在标题里。在文件列表或 diff 预览区按 `K`，才展示 SHA、作者、时间与完整提交说明；可用 Vim 移动键滚动，按 `q` / `<Esc>` / `K` 关闭并返回原位置。未提交修改显示 `Working Tree · Not committed yet`。picker 使用专用布局，窄窗口下文件列表与 diff 改为上下排列。

变更文件列表下方显示仓库提交历史（包含各分支与标签可达的提交），复用 Snacks 默认 Git log 的显示格式与高亮：提交图标、短 SHA、易读的提交时间、标题和作者，最新提交在上方。当前查看的 commit 自动定位并高亮。最初打开的提交，其图标前固定显示 `▶`；切换历史时三角保持不动，行高亮跟随正在查看的提交。在文件列表或 diff 预览区按 `p` 查看历史列表中的较新提交，按 `n` 查看较旧提交；文件列表、diff 和 `K` 信息会同步更新。切换提交会清空文件搜索，并尽量选中打开 annotate 的原文件。历史窗格自动跟随当前选择滚动。若从未提交行打开，历史顶部会保留 `Working Tree` 项，便于切回工作区修改。

## 大提交保护

- 通过 `d` 打开的单文件预览和 commit 文件列表最多读取 2 MiB；超出后会终止读取并明确标记已截断。
- 根提交也按文件预览，仅加载选中文件的 diff。
- 提交信息最多读取 2 MiB，超出后会在 `K` 打开的完整信息中提示截断。
- 提交历史每批加载 200 条，每次读取最多 2 MiB；向较旧提交切换时按需加载后续批次。打开较早的提交时，会继续加载直到找到它。

## 依赖

- Neovim 0.10+
- Git（在 `$PATH` 中可用）
- [snacks.nvim](https://github.com/folke/snacks.nvim)（可选，`d` 和 `O` 键需要）
