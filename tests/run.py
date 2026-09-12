"""Read-only Git integration tests. Run: python3 tests/run.py (NVIM may override nvim)."""

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
    'repository cwd is retained for blame, K and s': r'''
vim.cmd.cd('/tmp')
open()
key('K')
wait_for(function() return windows() == 3 end)
vim.api.nvim_exec_autocmds('CursorMoved', {buffer=0})
assert(windows() == 2)
key('s')
wait_for(function() return vim.bo.filetype == 'git' end)
assert(vim.api.nvim_buf_get_lines(0, 0, -1, false)[1]:find('commit'))
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
    'repeated hover leaves no buffers or autocmds': r'''
open()
local before = #vim.api.nvim_list_bufs()
for i = 1, 3 do
  key('K')
  wait_for(function() return windows() == 3 end)
  key('K') -- replace an already visible hover
  wait_for(function() return windows() == 3 end)
  vim.api.nvim_exec_autocmds('CursorMoved', {buffer=0})
  assert(windows() == 2 and #vim.api.nvim_list_bufs() == before)
end
key('q')
for _, autocmd in ipairs(vim.api.nvim_get_autocmds({})) do
  assert(not (autocmd.group_name or ''):match('^GitAnnotate'))
end
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
assert(sidebar_open())
''',
    'late diff cannot open on a replaced source buffer': r'''
local main = vim.api.nvim_get_current_win()
open()
local release = hold_exits()
key('s')
release() -- root check starts diff collection
vim.api.nvim_set_current_win(main)
vim.cmd.enew()
release()
assert(windows() == 1 and vim.bo.filetype ~= 'git')
''',
}


def main():
    failed = 0
    with tempfile.TemporaryDirectory(prefix='git-annotate-tests-') as temp:
        for index, (name, case) in enumerate(CASES.items()):
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
    print(f'{len(CASES) - failed}/{len(CASES)} passed')
    raise SystemExit(bool(failed))


if __name__ == '__main__':
    main()
