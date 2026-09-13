"""Read-only Git integration tests. NVIM/SNACKS may override nvim and snacks.nvim paths."""

import json
import os
from pathlib import Path
import subprocess
import tempfile

REPO = Path(__file__).resolve().parents[1]
PREAMBLE = r'''
vim.opt.rtp:prepend(REPO)
vim.cmd.cd(REPO)
vim.cmd.edit(REPO .. '/README.md')
local M = require('git_annotate')
local notices = {}
vim.notify = function(msg, level)
  table.insert(notices, msg)
  if level == vim.log.levels.ERROR then error(msg) end
end
local function wait_for(predicate)
  assert(vim.wait(3000, predicate), vim.inspect(notices))
end
local function sidebar_open() return vim.bo.filetype == 'gitannotate' end
local function open()
  M.annotate()
  wait_for(sidebar_open)
end
local function key(lhs)
  for _, map in ipairs(vim.api.nvim_buf_get_keymap(0, 'n')) do
    if map.lhs == lhs then
      if map.callback then return map.callback() end
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(map.rhs, true, false, true), 'nx', false)
      return
    end
  end
  error('missing mapping: ' .. lhs)
end
local function windows() return #vim.api.nvim_list_wins() end
-- Hold real process completion callbacks to reproduce races deterministically.
local function hold_exits()
  local system, exits = vim.system, {}
  vim.system = function(command, opts, callback)
    return system(command, opts, function(result)
      vim.schedule(function()
        table.insert(exits, function() callback(result) end)
      end)
    end)
  end
  return function()
    wait_for(function() return #exits > 0 end)
    table.remove(exits, 1)()
    vim.wait(20)
  end
end
'''
CASES = {
    'repository cwd is retained for blame and K': r'''
vim.cmd.cd('/tmp')
open()
key('K')
wait_for(function() return windows() == 3 end)
vim.api.nvim_exec_autocmds('CursorMoved', {buffer=0})
assert(windows() == 2)
''',
    'double toggle cancels queued blame; newer request survives': r'''
local release = hold_exits()
M.annotate()
release() -- repository lookup starts blame
M.annotate() -- cancel blame
M.annotate() -- start a newer request
release() -- old blame result must not clear the new request
release() -- new repository lookup
release() -- new blame result
assert(sidebar_open() and windows() == 2)
M.annotate()
assert(windows() == 1)
assert(not vim.wo.scrollbind)
''',
    'buffer replacement during blame drops result': r'''
local release = hold_exits()
M.annotate()
release()
vim.cmd.enew()
release()
assert(windows() == 1 and not sidebar_open())
''',
    'editing during blame drops result': r'''
local release = hold_exits()
M.annotate()
release()
vim.api.nvim_buf_set_lines(0, 0, 0, false, {'unsaved'})
release()
assert(windows() == 1)
''',
    'closed source during blame drops result': r'''
vim.cmd.vsplit()
local main = vim.api.nvim_get_current_win()
local release = hold_exits()
M.annotate()
release()
vim.api.nvim_win_close(main, true)
release()
assert(windows() == 1)
''',
    'window options and closed folds are restored': r'''
local main = vim.api.nvim_get_current_win()
vim.wo.wrap = true
vim.wo.foldmethod = 'manual'
vim.cmd('2,10fold')
open()
assert(not vim.wo[main].foldenable and not vim.wo[main].wrap)
assert(vim.wo[main].scrollbind)
key('<Esc>')
assert(windows() == 1 and vim.wo.wrap and vim.wo.foldenable)
assert(not vim.wo.scrollbind and vim.fn.foldclosed(2) == 2)
-- Restore non-default originals too, across multiple sessions.
vim.wo.foldenable = false
vim.wo.wrap = false
vim.wo.scrollbind = true
open()
key('q')
assert(not vim.wo.foldenable and not vim.wo.wrap and vim.wo.scrollbind)
''',
    'source replacement closes sidebar': r'''
local main = vim.api.nvim_get_current_win()
vim.wo.wrap = true
open()
vim.api.nvim_set_current_win(main)
vim.cmd.enew()
assert(windows() == 1 and vim.wo.wrap and not vim.wo.scrollbind)
''',
    'source replacement closes sidebar even when file is visible elsewhere': r'''
vim.cmd.vsplit()
local main = vim.api.nvim_get_current_win()
open()
vim.api.nvim_set_current_win(main)
vim.cmd.enew()
assert(windows() == 2 and not vim.wo.scrollbind)
for _, win in ipairs(vim.api.nvim_list_wins()) do
  assert(vim.bo[vim.api.nvim_win_get_buf(win)].filetype ~= 'gitannotate')
end
''',
    'closing source also cleans sidebar when file remains visible elsewhere': r'''
vim.cmd.vsplit()
local main = vim.api.nvim_get_current_win()
open()
vim.api.nvim_win_close(main, true)
wait_for(function() return windows() == 1 end)
''',
    'closing the only source leaves an ordinary usable window': r'''
local main = vim.api.nvim_get_current_win()
vim.wo.number = true
vim.wo.wrap = true
open()
vim.api.nvim_win_close(main, true)
wait_for(function() return windows() == 1 and vim.bo.filetype ~= 'gitannotate' end)
assert(vim.bo.buftype == '' and vim.bo.modifiable)
assert(vim.wo.number and vim.wo.wrap and not vim.wo.scrollbind)
''',
    'second K focuses the hover and dismissal leaves no buffers or autocmds': r'''
open()
local before = #vim.api.nvim_list_bufs()
local sidebar = vim.api.nvim_get_current_win()
for i = 1, 3 do
  key('K')
  wait_for(function() return windows() == 3 end)
  assert(vim.api.nvim_get_current_win() == sidebar)
  key('K')
  assert(vim.bo.filetype == 'git' and vim.wo.wrap and not vim.bo.modifiable)
  vim.wait(30) -- deferred leave handlers must preserve the focused hover
  assert(windows() == 3)
  vim.cmd('normal! G')
  key(({ 'q', '<Esc>', 'K' })[i])
  assert(vim.api.nvim_get_current_win() == sidebar)
  assert(windows() == 2 and #vim.api.nvim_list_bufs() == before)
end
key('q')
for _, autocmd in ipairs(vim.api.nvim_get_autocmds({})) do
  assert(not (autocmd.group_name or ''):match('^GitAnnotate'))
end
''',
    'two quick K presses focus the hover after commit info finishes loading': r'''
open()
local release = hold_exits()
key('K')
key('K')
assert(sidebar_open() and windows() == 2)
release()
assert(vim.bo.filetype == 'git' and windows() == 3)
key('q')
assert(sidebar_open() and windows() == 2)
''',
    'leaving a focused commit hover closes it without stealing focus': r'''
local main = vim.api.nvim_get_current_win()
open()
key('K')
wait_for(function() return windows() == 3 end)
key('K')
local buf = vim.api.nvim_get_current_buf()
vim.api.nvim_set_current_win(main)
wait_for(function() return windows() == 2 end)
assert(vim.api.nvim_get_current_win() == main and not vim.api.nvim_buf_is_valid(buf))
''',
    'late hover result cannot reopen after cursor movement': r'''
open()
local before = #vim.api.nvim_list_bufs()
local release = hold_exits()
key('K')
vim.api.nvim_exec_autocmds('CursorMoved', {buffer=0})
release()
assert(windows() == 2 and #vim.api.nvim_list_bufs() == before)
''',
    'closing sidebar cancels a pending hover': r'''
open()
local release = hold_exits()
key('K')
key('q')
release()
assert(windows() == 1 and #vim.api.nvim_list_bufs() == 1)
''',
    'missing Snacks reports a warning': r'''
open()
key('d')
assert(notices[#notices]:find('requires snacks.nvim', 1, true))
key('O')
assert(notices[#notices] == 'Git annotate: O requires snacks.nvim')
assert(sidebar_open())
''',
}

CASES['history pagination locates an older initial commit and ignores results after close'] = r'''
local History = require('git_annotate.history')
local requests, selected, kills = {}, {}, 0
local function sha(i) return string.format('%040x', i) end
local function output(first, last)
  local fields = {}
  for i = first, last do
    fields[#fields + 1] = sha(i)
    fields[#fields + 1] = i == 205 and '' or 'Commit ' .. i
  end
  return table.concat(fields, '\0') .. '\0'
end
local history = History.new({cwd = REPO, sha = sha(205), working = false,
  on_select = function(item) selected[#selected + 1] = item.sha end,
  run = function(command, callback)
    requests[#requests + 1] = {command = command, callback = callback}
    return {kill = function() kills = kills + 1 end}
  end,
})
history:load()
assert(vim.tbl_contains(requests[1].command, '--all'))
assert(vim.tbl_contains(requests[1].command, sha(205)))
assert(vim.tbl_contains(requests[1].command, '--skip=0'))
requests[1].callback({code = 0, stdout = output(1, 201), stderr = '', truncated = false})
assert(#history.items == 200 and not history.index and #requests == 2)
assert(vim.tbl_contains(requests[2].command, '--skip=200'))
requests[2].callback({code = 0, stdout = output(201, 205), stderr = '', truncated = false})
assert(history.index == 205 and not history.more and #selected == 0)
assert(history.items[205].subject == '(No commit message)')
history:move(-1)
assert(selected[1] == sha(204))
history:move(1)
history:move(1)
assert(#selected == 2 and history.index == 205)
history.more = true
history:load()
history:close()
requests[3].callback({code = 0, stdout = output(206, 210), stderr = '', truncated = false})
assert(#history.items == 205 and kills == 1)
'''

CASES['history page boundary honors a newer selection while older commits load'] = r'''
local History = require('git_annotate.history')
local requests, selected = {}, {}
local function sha(i) return string.format('%040x', i) end
local function output(first, last)
  local fields = {}
  for i = first, last do
    fields[#fields + 1] = sha(i)
    fields[#fields + 1] = 'Commit ' .. i
  end
  return table.concat(fields, '\0') .. '\0'
end
local history = History.new({cwd = REPO, sha = sha(1), working = false,
  on_select = function(item) selected[#selected + 1] = item.sha end,
  run = function(command, callback)
    requests[#requests + 1] = callback
    return {kill = function() end}
  end,
})
history:load()
requests[1]({code = 0, stdout = output(1, 201), stderr = '', truncated = false})
for _ = 1, 200 do history:move(1) end
assert(history.index == 200 and history.pending_move and #requests == 2)
history:move(-1)
requests[2]({code = 0, stdout = output(201, 210), stderr = '', truncated = false})
assert(history.index == 199 and selected[#selected] == sha(199))
history:move(1)
history:move(1)
assert(history.index == 201 and selected[#selected] == sha(201))
history:close()
'''

SNACKS_PREAMBLE = r'''
vim.o.columns = 160
vim.o.lines = 50
vim.opt.rtp:append(SNACKS)
require('snacks').setup({picker = {enabled = true}, image = {enabled = false}})
local function git(args)
  local command = {'git'}
  vim.list_extend(command, args)
  local result = vim.system(command, {cwd = REPO, text = true}):wait()
  assert(result.code == 0, result.stderr)
  return vim.trim(result.stdout)
end
local function preview_title(picker)
  return picker.preview.title or ''
end
local function expected_files_title(ref)
  local fields = vim.split(git({'show', '--no-patch', '--format=%an%x00%at', ref}), '\0')
  local timestamp = tonumber(fields[2])
  local date = os.date('*t', timestamp)
  local time = os.date('%H:%M', timestamp)
  if os.date('%Y-%m-%d', timestamp) == os.date('%Y-%m-%d') then
    return fields[1] .. '  Today ' .. time
  end
  return string.format('%s  %d/%d/%d, %s', fields[1], date.year, date.month, date.day, time)
end
local function history_win(picker)
  for _, win in pairs(picker.layout.box_wins) do
    if win:buf_valid() and vim.b[win.buf].git_annotate_history then return win end
  end
  error('missing commit history')
end
local function selected_commit(picker)
  local win = history_win(picker)
  local row = vim.api.nvim_win_get_cursor(win.win)[1]
  local line = vim.api.nvim_buf_get_lines(win.buf, row - 1, row, false)[1]
  return line:match('^▶ (%x+)') or line:match('^  (%x+)')
end
local function history_loaded(picker)
  wait_for(function() return selected_commit(picker) or
    history_win(picker):text():find('▶ Working Tree', 1, true) end)
end
local function diff_loaded(picker)
  wait_for(function() return not picker:is_active() and picker.preview.win:buf_valid() and
    picker.preview.win:text() ~= '' and not picker.preview.win:text():find('Loading', 1, true) end)
end
local function open_picker(sha)
  sha = sha or git({'rev-parse', 'HEAD'})
  M._open_sidebar({{sha = sha, text = 'Test commit', author_time = os.time()}},
    vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win(), 1, 1, REPO)
  key('d')
  local picker
  wait_for(function()
    picker = Snacks.picker.get()[1]
    return picker and picker.list.win:win_valid()
  end)
  return picker
end
local function loaded(picker)
  wait_for(function() return preview_title(picker) ~= '' and
    not preview_title(picker):find('Loading', 1, true) end)
end
local function close_picker(picker)
  picker:close()
  wait_for(function() return sidebar_open() and windows() == 2 end)
end
local function capture_browser()
  local urls, system = {}, vim.fn.system
  vim.ui.open = function(url) table.insert(urls, url) end
  vim.fn.system = function(command)
    if type(command) == 'table' and command[1] == 'git' and command[2] == '-C' then
      assert(command[3] == REPO, 'browser resolved the wrong repository')
      if command[4] == 'remote' then
        return 'origin\tgit@github.com:example/project.git (fetch)\n'
      end
    end
    return system(command)
  end
  return urls
end
'''

SNACKS_CASES = {
    'O browses the sidebar line commit from the source repository and rejects uncommitted lines': r'''
local urls = capture_browser()
local older, head = git({'rev-parse', 'HEAD~1'}), git({'rev-parse', 'HEAD'})
M._open_sidebar({
  {sha = older, text = 'Older commit', author_time = os.time()},
  {sha = head, text = 'Head commit', author_time = os.time()},
  {sha = string.rep('0', 40), text = 'Uncommitted', author_time = 0, uncommitted = true},
}, vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win(), 1, 1, REPO)
vim.cmd.cd('/tmp')
local cwd = vim.fn.getcwd()
local sidebar = vim.api.nvim_get_current_win()
for row, sha in ipairs({older, head}) do
  vim.api.nvim_win_set_cursor(sidebar, {row, 0})
  key('O')
  assert(urls[row] == 'https://github.com/example/project/commit/' .. sha)
  assert(vim.api.nvim_get_current_win() == sidebar and sidebar_open())
end
vim.api.nvim_win_set_cursor(sidebar, {3, 0})
key('O')
assert(#urls == 2 and notices[#notices]:find('uncommitted changes', 1, true))
assert(vim.fn.getcwd() == cwd, vim.fn.getcwd())
''',
    'O in picker panes follows the selected history commit and preserves the picker': r'''
local urls = capture_browser()
local picker = open_picker(string.rep('0', 40))
history_loaded(picker)
key('O')
assert(#urls == 0 and notices[#notices]:find('uncommitted changes', 1, true))
key('h')
diff_loaded(picker)
local initial = selected_commit(picker)
local sha = git({'rev-parse', initial})
vim.cmd.cd('/tmp')
local cwd = vim.fn.getcwd()
for i, pane in ipairs({'list', 'input', 'preview'}) do
  picker:focus(pane)
  vim.cmd.stopinsert()
  key('O')
  assert(urls[i] == 'https://github.com/example/project/commit/' .. sha)
  assert(not picker.closed and picker:current_win() == pane)
end
assert(vim.fn.getcwd() == cwd, vim.fn.getcwd())
key('h')
wait_for(function() return selected_commit(picker) ~= initial end)
diff_loaded(picker)
key('O')
assert(urls[4] == 'https://github.com/example/project/commit/' .. git({'rev-parse', selected_commit(picker)}))
close_picker(picker)
''',
    'diff loading waits three seconds and ignores completed, superseded and closed previews': r'''
local picker = open_picker()
history_loaded(picker)
diff_loaded(picker)
local system, defer = vim.system, vim.defer_fn
local releases, timers = {}, {}
vim.system = function(command, opts, callback)
  if command[3] == 'diff' and vim.tbl_contains(command, '--no-ext-diff') then
    return system(command, opts, function(result)
      vim.schedule(function()
        table.insert(releases, function(fail)
          if fail then result.code, result.stderr = 128, 'test diff failure' end
          callback(result)
        end)
      end)
    end)
  end
  return system(command, opts, callback)
end
-- Advance only the loading timers explicitly, without making the suite sleep.
vim.defer_fn = function(callback, ms)
  if ms == 3000 then
    table.insert(timers, callback)
    return
  end
  return defer(callback, ms)
end
local function start_preview()
  local count = #releases
  picker.preview:show(picker, {force = true})
  wait_for(function() return #releases > count end)
  assert(#timers == #releases, 'loading threshold must be 3000 ms')
  assert(not picker.preview.win:text():find('Loading diff', 1, true))
  return #releases
end
local function finish(index, fail)
  releases[index](fail)
  wait_for(function() return picker.preview.win:text() ~= '' and
    not picker.preview.win:text():find('Loading diff', 1, true) end)
  local content = picker.preview.win:text()
  timers[index]()
  assert(picker.preview.win:text() == content, 'completed request showed loading')
  return content
end

local fast = start_preview()
finish(fast)
local slow = start_preview()
timers[slow]()
assert(picker.preview.win:text() == 'Loading diff…')
finish(slow)

-- Navigate away and back to the same item while its first diff is pending.
local original = picker:current()
local stale = start_preview()
picker.list:move(1)
assert(picker:current() ~= original)
local away = start_preview()
picker.list:move(-1)
assert(picker:current() == original)
local current = start_preview()
timers[stale]()
timers[away]()
assert(picker.preview.win:text() == '', 'obsolete request showed loading')
releases[stale]()
releases[away]()
vim.wait(50)
assert(picker.preview.win:text() == '', 'obsolete result replaced current preview')
finish(current)

local failed = start_preview()
assert(finish(failed, true):find('Git annotate:', 1, true))
local closed = start_preview()
close_picker(picker)
local buffers = #vim.api.nvim_list_bufs()
timers[closed]()
releases[closed]()
vim.wait(50)
assert(windows() == 2 and #vim.api.nvim_list_bufs() == buffers)
''',
    'history locates and highlights the initial commit below changed files': r'''
local sha = git({'rev-parse', 'HEAD~2'})
local picker = open_picker(sha)
history_loaded(picker)
assert(selected_commit(picker) == sha:sub(1, 8))
local win = history_win(picker)
local row = vim.api.nvim_win_get_cursor(win.win)[1]
local marks = vim.api.nvim_buf_get_extmarks(win.buf, vim.api.nvim_get_namespaces().git_annotate_history,
  {row - 1, 0}, {row - 1, -1}, {details = true})
assert(#marks == 2 and marks[1][4].line_hl_group == 'Visual')
assert(marks[2][4].hl_group == 'DiagnosticInfo')
assert(win:text():find('▶ ' .. sha:sub(1, 8), 1, true))
local hp = vim.api.nvim_win_get_position(win.win)
local lp = vim.api.nvim_win_get_position(picker.list.win.win)
assert(hp[1] > lp[1] and hp[2] + 1 == lp[2])
assert(win:text():find(git({'rev-parse', '--short=8', 'HEAD'}), 1, true))
local expected = vim.split(git({'log', '--all', '--date-order', '--format=%H', 'HEAD', sha, '--'}), '\n')
local displayed = vim.api.nvim_buf_get_lines(win.buf, 0, -1, false)
assert(#displayed == #expected)
for i, commit in ipairs(expected) do
  assert(displayed[#displayed - i + 1]:find(commit:sub(1, 8), 1, true))
end
local buf = win.buf
vim.o.columns, vim.o.lines = 80, 28
vim.api.nvim_exec_autocmds('VimResized', {})
vim.wait(150)
win = history_win(picker)
assert(selected_commit(picker) == sha:sub(1, 8))
local pos = vim.api.nvim_win_get_position(win.win)
assert(pos[1] + vim.api.nvim_win_get_height(win.win) < vim.o.lines)
assert(pos[2] + vim.api.nvim_win_get_width(win.win) < vim.o.columns)
close_picker(picker)
assert(not vim.api.nvim_buf_is_valid(buf))
''',
    'h and l update the selected commit, changed files, diff title and K details': r'''
local picker = open_picker()
history_loaded(picker)
local commits = vim.split(git({'log', '--all', '--date-order', '--format=%H', 'HEAD', '--'}), '\n')
local index
for i, sha in ipairs(commits) do if sha == git({'rev-parse', 'HEAD'}) then index = i end end
local older = commits[index + 1]
local subject = git({'show', '--no-patch', '--format=%s', older})
key('h')
local title = expected_files_title(older)
wait_for(function() return picker.title == title end)
diff_loaded(picker)
assert(selected_commit(picker) == older:sub(1, 8))
assert(history_win(picker):text():find('▶ ' .. commits[index]:sub(1, 8), 1, true))
assert(not history_win(picker):text():find('▶ ' .. older:sub(1, 8), 1, true))
assert(preview_title(picker) == subject)
local expected = vim.split(git({'diff-tree', '--no-commit-id', '--name-only', '-r', older}), '\n')
local files = vim.tbl_map(function(item) return item.file end, picker:items())
table.sort(expected)
table.sort(files)
assert(vim.deep_equal(files, expected), vim.inspect(files))
assert(picker:current().file == 'README.md')
key('K')
wait_for(function() return vim.api.nvim_buf_get_lines(0, 0, -1, false)[1]:find(older:sub(1, 7), 1, true) end)
assert(vim.api.nvim_buf_get_lines(0, 0, -1, false)[5] == subject)
key('q')
picker:focus('preview')
key('l')
diff_loaded(picker)
assert(selected_commit(picker) == commits[index]:sub(1, 8))
assert(preview_title(picker) == git({'show', '--no-patch', '--format=%s', 'HEAD'}))
close_picker(picker)
''',
    'root commit is reachable and moving past the oldest entry is a no-op': r'''
local root = git({'rev-list', '--max-parents=0', 'HEAD'}):match('%S+')
local picker = open_picker(root)
history_loaded(picker)
diff_loaded(picker)
local text = picker.preview.win:text()
key('h')
vim.wait(50)
assert(selected_commit(picker) == root:sub(1, 8) and picker.preview.win:text() == text)
key('l')
diff_loaded(picker)
assert(selected_commit(picker) ~= root:sub(1, 8))
close_picker(picker)
''',
    'working tree remains available after browsing repository commits': r'''
local picker = open_picker(string.rep('0', 40))
history_loaded(picker)
key('h')
wait_for(function() return selected_commit(picker) end)
diff_loaded(picker)
assert(selected_commit(picker))
key('l')
diff_loaded(picker)
assert(history_win(picker):text():find('▶ Working Tree', 1, true))
local lines = vim.api.nvim_buf_get_lines(history_win(picker).buf, 0, -1, false)
assert(lines[#lines] == '▶ Working Tree · Not committed yet')
assert(preview_title(picker) == 'Working Tree · Not committed yet')
key('K')
assert(vim.api.nvim_buf_get_lines(0, 0, -1, false)[2] == 'Not committed yet')
key('q')
close_picker(picker)
''',
    'rapid history navigation ignores obsolete file lists, metadata and diff callbacks': r'''
local picker = open_picker()
history_loaded(picker)
diff_loaded(picker)
local title = preview_title(picker)
local system, releases = vim.system, {}
vim.system = function(command, opts, callback)
  return system(command, opts, callback and function(result)
    vim.schedule(function() table.insert(releases, function() callback(result) end) end)
  end)
end
key('h')
wait_for(function() return #releases >= 2 end)
key('l')
-- Release newer requests first, then all results from the older selection.
wait_for(function() return #releases >= 4 end)
for _ = 1, 10 do
  while #releases > 0 do table.remove(releases)() end
  vim.wait(40)
end
diff_loaded(picker)
assert(selected_commit(picker) == git({'rev-parse', '--short=8', 'HEAD'}))
assert(preview_title(picker) == title)
key('K')
assert(vim.api.nvim_buf_get_lines(0, 0, -1, false)[5] == title)
key('q')
close_picker(picker)
''',
    'late per-file diff cannot overwrite a newer history selection': r'''
local picker = open_picker()
history_loaded(picker)
diff_loaded(picker)
local subject = preview_title(picker)
local system, release = vim.system
local hold_diff = true
vim.system = function(command, opts, callback)
  if hold_diff and command[3] == 'diff' and vim.tbl_contains(command, '--no-ext-diff') then
    return system(command, opts, function(result) release = function() callback(result) end end)
  end
  return system(command, opts, callback)
end
key('h')
wait_for(function() return release ~= nil end)
hold_diff = false
key('l')
diff_loaded(picker)
local content = picker.preview.win:text()
release()
vim.wait(100)
assert(preview_title(picker) == subject and picker.preview.win:text() == content)
close_picker(picker)
''',
    'an empty commit file list still allows history navigation': r'''
local system = vim.system
local empty_files = true
vim.system = function(command, opts, callback)
  if empty_files and vim.tbl_contains(command, '--name-status') then
    command = {'git', 'diff', '--name-status', '-z', 'HEAD', 'HEAD'}
  end
  return system(command, opts, callback)
end
local picker = open_picker()
history_loaded(picker)
assert(picker.list:count() == 0 and not picker.closed)
empty_files = false
key('h')
diff_loaded(picker)
assert(picker.list:count() > 0)
close_picker(picker)
''',
    'commit info and diff can finish independently without overwriting the subject': r'''
local system, releases = vim.system, {}
vim.system = function(command, opts, callback)
  local kind
  if command[2] == 'show' and command[4] and command[4]:find('--format=commit', 1, true) then
    kind = 'info'
  elseif (command[3] == 'diff' and vim.tbl_contains(command, '--no-ext-diff')) or
    (command[3] == 'diff-tree' and vim.tbl_contains(command, '-p')) then
    kind = 'diff'
  end
  if kind then
    return system(command, opts, function(result)
      releases[kind] = function() callback(result) end
    end)
  end
  return system(command, opts, callback)
end
local picker = open_picker()
wait_for(function() return releases.info and releases.diff end)
key('K')
local info_buf = vim.api.nvim_get_current_buf()
assert(vim.api.nvim_buf_get_lines(info_buf, 0, -1, false)[1] == 'Loading commit info…')
releases.info()
loaded(picker)
local subject = git({'show', '--no-patch', '--format=%s', 'HEAD'})
assert(preview_title(picker) == subject)
assert(picker.title == expected_files_title('HEAD'))
assert(vim.api.nvim_buf_get_lines(info_buf, 0, -1, false)[5] == subject)
key('q')
releases.diff()
diff_loaded(picker)
assert(preview_title(picker) == subject)
close_picker(picker)
''',
    'commit subject is the preview title across file changes, scrolling and resize': r'''
local picker = open_picker()
loaded(picker)
local subject = git({'show', '--no-patch', '--format=%s', 'HEAD'})
assert(preview_title(picker) == subject)
for _, win in pairs(picker.layout.box_wins) do
  assert(not win.opts.text, 'unexpected commit info pane')
end
diff_loaded(picker)
if picker.list:count() > 1 then
  local previous = picker:current()
  picker.list:move(1)
  picker:show_preview()
  wait_for(function() return picker.preview.item == picker:current() end)
  assert(picker:current() ~= previous)
end
picker:focus('preview')
vim.cmd('normal! G')
assert(preview_title(picker) == subject)
for _, size in ipairs({{80, 28}, {160, 50}}) do
  vim.o.columns, vim.o.lines = size[1], size[2]
  vim.api.nvim_exec_autocmds('VimResized', {})
  vim.wait(150)
  assert(preview_title(picker) == subject)
  local title = vim.api.nvim_win_get_config(picker.preview.win.win).title
  assert(table.concat(vim.tbl_map(function(chunk) return chunk[1] end, title)):find(subject, 1, true))
  local lp = vim.api.nvim_win_get_position(picker.list.win.win)
  local pp = vim.api.nvim_win_get_position(picker.preview.win.win)
  if size[1] < 100 then assert(pp[1] > lp[1]) else assert(pp[2] > lp[2]) end
  for _, win in ipairs({picker.list.win, picker.preview.win}) do
    local p = vim.api.nvim_win_get_position(win.win)
    assert(p[1] + vim.api.nvim_win_get_height(win.win) < vim.o.lines)
    assert(p[2] + vim.api.nvim_win_get_width(win.win) < vim.o.columns)
  end
end
close_picker(picker)
''',
    'long commit info is cached, scrollable and returns to the originating pane': r'''
local system, calls = vim.system, 0
vim.system = function(command, opts, callback)
  if command[2] == 'show' and command[4] and command[4]:find('--format=commit', 1, true) then
    calls = calls + 1
    command = vim.deepcopy(command)
    for i = 1, 60 do command[4] = command[4] .. '%n正文 body ' .. i end
  end
  return system(command, opts, callback)
end
local picker = open_picker()
loaded(picker)
assert(preview_title(picker) == git({'show', '--no-patch', '--format=%s', 'HEAD'}))
assert(not picker.preview.win:text():find('正文 body', 1, true))
for _, pane in ipairs({'list', 'input'}) do
  picker:focus(pane)
  local item = picker:current()
  key('<C-O>')
  assert(picker:current_win() == 'preview')
  key('<C-O>')
  assert(picker:current_win() == pane and picker:current() == item)
end
for _, pane in ipairs({'list', 'preview'}) do
  picker:focus(pane)
  local origin = vim.api.nvim_get_current_win()
  key('K')
  assert(vim.bo.filetype == 'git' and not vim.bo.modifiable and vim.wo.wrap)
  assert(table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n'):find('正文 body 60', 1, true))
  local buf = vim.api.nvim_get_current_buf()
  vim.cmd('normal! G')
  assert(vim.api.nvim_win_get_cursor(0)[1] > 50)
  key('<Esc>')
  assert(vim.api.nvim_get_current_win() == origin and not picker.closed)
  assert(not vim.api.nvim_buf_is_valid(buf))
end
assert(calls == 1)
key('K')
local detail = vim.api.nvim_get_current_buf()
close_picker(picker)
assert(not vim.api.nvim_buf_is_valid(detail))
''',
    'working tree title does not request commit metadata': r'''
local system, calls = vim.system, 0
vim.system = function(command, opts, callback)
  if command[2] == 'show' then calls = calls + 1 end
  return system(command, opts, callback)
end
local picker = open_picker(string.rep('0', 40))
loaded(picker)
assert(preview_title(picker) == 'Working Tree · Not committed yet')
key('K')
assert(vim.api.nvim_buf_get_lines(0, 0, -1, false)[2] == 'Not committed yet')
key('q')
assert(calls == 0)
close_picker(picker)
''',
    'late commit metadata cannot recreate a closed picker': r'''
local system, release = vim.system
vim.system = function(command, opts, callback)
  if command[2] == 'show' and command[4] and command[4]:find('--format=commit', 1, true) then
    return system(command, opts, function(result)
      release = function() callback(result) end
    end)
  end
  return system(command, opts, callback)
end
local picker = open_picker()
wait_for(function() return release ~= nil end)
assert(preview_title(picker):find('Loading', 1, true))
close_picker(picker)
local buffers = #vim.api.nvim_list_bufs()
release()
vim.wait(100)
assert(sidebar_open() and windows() == 2 and #vim.api.nvim_list_bufs() == buffers)
''',
    'metadata failure is shown without blocking diff preview': r'''
local system = vim.system
vim.system = function(command, opts, callback)
  if command[2] == 'show' and command[4] and command[4]:find('--format=commit', 1, true) then
    command = {'git', 'show', '--invalid-git-annotate-test-option'}
  end
  return system(command, opts, callback)
end
local picker = open_picker()
loaded(picker)
assert(preview_title(picker) == 'Commit info unavailable · K: details')
key('K')
assert(vim.api.nvim_buf_get_lines(0, 0, -1, false)[1]:find('Git annotate:', 1, true))
key('q')
diff_loaded(picker)
assert(picker.preview.win:text() ~= '')
close_picker(picker)
''',
    'root commit shows metadata and Enter focuses its per-file preview': r'''
local root = git({'rev-list', '--max-parents=0', 'HEAD'}):match('%S+')
local picker = open_picker(root)
loaded(picker)
assert(preview_title(picker) == git({'show', '--no-patch', '--format=%s', root}))
diff_loaded(picker)
local count = windows()
local content = picker.preview.win:text()
key('<CR>')
assert(not picker.closed and picker:current_win() == 'preview')
assert(windows() == count and picker.preview.win:text() == content)
close_picker(picker)
''',
}


def main():
    failed = 0
    cases = dict(CASES)
    snacks = Path(os.environ.get('SNACKS', '~/.local/share/nvim/lazy/snacks.nvim')).expanduser()
    if (snacks / 'lua/snacks/init.lua').is_file():
        for name, case in SNACKS_CASES.items():
            cases[name] = 'local SNACKS = ' + json.dumps(str(snacks)) + '\n' + SNACKS_PREAMBLE + case
    else:
        print('SKIP: Snacks integration tests (set SNACKS to your snacks.nvim directory)')
    with tempfile.TemporaryDirectory(prefix='git-annotate-tests-') as temp:
        for index, (name, case) in enumerate(cases.items()):
            script = Path(temp) / f'case_{index}.lua'
            script.write_text(
                'local REPO = ' + json.dumps(str(REPO)) + '\n'
                + PREAMBLE + '\n' + case + '\nvim.cmd("qa!")\n'
            )
            result = subprocess.run(
                [os.environ.get('NVIM', 'nvim'), '--headless', '-u', 'NONE', '-l', str(script)],
                cwd=REPO, capture_output=True, text=True, timeout=15,
            )
            # Scheduled Lua errors can be reported without a nonzero process exit.
            output = result.stdout + result.stderr
            passed = result.returncode == 0 and 'Error' not in output and 'stack traceback' not in output
            print(('PASS' if passed else 'FAIL') + ': ' + name)
            if not passed:
                failed += 1
                print(output)
    print(f'{len(cases) - failed}/{len(cases)} passed')
    raise SystemExit(bool(failed))


if __name__ == '__main__':
    main()
