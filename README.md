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

Run `:lua require("git_annotate").log()` to open changed files, repository history
and per-file diff directly at `HEAD`. It uses the current file's repository, or cwd
for unnamed and special buffers. Closing the viewer returns to the original window.
The `f`, `p` / `n`, `K`, `O` and `<C-o>` controls below work in this view too.

For LazyVim, add this entry to the plugin's `keys`:

```lua
{ "<leader>gl", function() require("git_annotate").log() end, desc = "Git Log (Annotate)" },
```

### Sidebar Keymaps

| Key | Description |
|---|---|
| `q` / `<Esc>` | Close the sidebar |
| `K` | Show commit information; press again to focus the float, then `q` / `<Esc>` / `K` to close and return |
| `O` | Open the GitHub PR for the current line, falling back to the commit page (requires Snacks) |
| `d` | Show changed files, repository commit history and per-file diff in Snacks |
| `p` | Preview the current hunk with its commit subject in the float title. Uncommitted lines show the working-tree hunk. The preview follows `[[` / `]]` in the sidebar. Press `p` again to scroll it |
| `f` | List this commit’s hunks in the file, or working-tree hunks for an uncommitted line. The list opens on the current hunk in normal mode. Press `<Enter>` or `o` to jump to the selected change in the source buffer, or dismiss to return to the sidebar |
| `]]` | Jump to the next occurrence of the same commit in the file |
| `[[` | Jump to the previous occurrence of the same commit in the file |
| `]c` | Jump to the next commit's first occurrence (skip repeated commit blocks) |
| `[c` | Jump to the previous commit's first occurrence (skip repeated commit blocks) |

> `d` requires [snacks.nvim](https://github.com/folke/snacks.nvim). The picker starts on the current file when possible and previews the selected file's diff. Untracked files are also available through their per-file preview.

In the picker's file list, input or diff preview, press `O` in normal mode to browse the selected history entry and keep the picker open. For github.com remotes, `O` uses `gh` to open the first associated PR. If no PR is found or the lookup fails, it opens the commit page. Private repositories require `gh` to be authenticated with repository access. Uncommitted changes show a warning. Snacks offers a remote selector when the repository has multiple remotes.

In the detail view, press `<CR>` or normal-mode `o` to open the selected file's current working-tree version in the source window and close the viewer. If the file no longer exists, a message shows its path and the detail view stays open.

Press `f` in normal mode to filter commit history in place. Typing matches the SHA, subject and author, ignoring case; space-separated terms must all occur literally. The matching history and selected commit's diff update as you type. `<CR>` keeps the filter; `<Esc>` or `<C-c>` restores the previous filter and commit. Press `f` again to edit the filter, or clear the input and confirm to show all commits. `p` / `n` navigate matching commits. The history list shows the active filter and match count at the top. No matches leaves the previous diff visible with an explicit message. While a filter is active, older history pages load asynchronously until the full history has been searched.

Press `<C-o>` in the file list or search input to focus the diff preview, then press `<C-o>` to return to the originating pane. Returning to the search input restores insert mode if it was active.

The file list title shows the author and local time, using `shenyfg  Today 16:51` for today or `shenyfg  2026/8/25, 15:23` for other dates. The diff preview title shows the commit subject while you switch files or scroll. File paths appear in the diff content instead of being repeated in the title. Press `K` in the file list or diff preview to see the SHA, author, date and full commit message, scroll with Vim movement keys, and press `q` / `<Esc>` / `K` to return to the previous pane. Uncommitted changes show `Working Tree · Not committed yet`. The picker uses a dedicated layout, stacking the file list above the diff in narrow windows.

Repository history appears below the changed files, including commits reachable from branches and tags. Entries use the default Snacks Git log formatting: commit icon, abbreviated SHA, human-readable committer date, subject and author, with the same highlighting. Newest commits appear at the top. The current commit is highlighted and scrolled into view. A fixed `▶` before the commit icon identifies the commit originally opened; only the row highlight follows the commit being viewed. In the diff preview, `n` repeats the last search. In the file list or input, press `p` in normal mode to select a newer history entry, or `n` for an older one; changed files, diff and `K` information update together. Switching commits clears the file search and tries to select the original annotated file. The history pane follows the selection automatically. When opened from an uncommitted line, a `Working Tree` entry remains at the top so you can return to working tree changes.

## Large commit protection

- Per-file previews opened with `d` and commit file lists are limited to 2 MiB. Oversized output is truncated and clearly marked.
- Root commits also use per-file previews, loading only the selected file's diff.
- Commit information is limited to 2 MiB, with a truncation notice in the full view opened with `K`.
- History streams from one background Git process and locates the initial commit as records arrive. Parsing and filtering run in short slices; the history pane renders at most three screens while retaining loaded records for navigation and filtering. Individual history entries are limited to 2 MiB, and closing the picker cancels the stream.

## Requirements

- Neovim 0.10+
- Git available in `$PATH`
- [snacks.nvim](https://github.com/folke/snacks.nvim) (optional, required for `d`, `p`, `f` and `O`)
