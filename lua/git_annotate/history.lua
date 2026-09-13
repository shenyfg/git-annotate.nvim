local M = {}
M.__index = M

local PAGE_SIZE = 200
local ns = vim.api.nvim_create_namespace("git_annotate_history")

--- @param opts {cwd: string, sha?: string, working: boolean, run: function, on_select: function}
function M.new(opts)
	local self = setmetatable({
		opts = opts,
		items = {},
		offset = 0,
		more = true,
		message = "Loading history…",
	}, M)
	if opts.working then
		self.items[1] = { working = true, subject = "Working Tree · Not committed yet" }
		self.index = 1
	end
	return self
end

function M:is_origin(item)
	if self.opts.working then
		return item.working == true
	end
	return item.sha == self.opts.sha
end

function M:render(win)
	win = win or self.win
	if not win or not win:buf_valid() then
		return
	end
	self.win = win
	local lines = {}
	if self.message then
		lines[1] = self.message
	elseif self.more then
		lines[1] = "… h: load older commits"
	end
	local offset = #lines
	-- Keep newest-first pagination internally, but display oldest-first.
	for i = #self.items, 1, -1 do
		local item = self.items[i]
		lines[#lines + 1] = (self:is_origin(item) and "▶ " or "  ")
			.. (item.sha and item.sha:sub(1, 8) .. " " or "")
			.. item.subject
	end
	vim.bo[win.buf].modifiable = true
	vim.api.nvim_buf_set_lines(win.buf, 0, -1, false, #lines > 0 and lines or { "No commits" })
	vim.api.nvim_buf_clear_namespace(win.buf, ns, 0, -1)
	for i, item in ipairs(self.items) do
		local row = offset + #self.items - i
		if i == self.index then
			vim.api.nvim_buf_set_extmark(win.buf, ns, row, 0, {
				line_hl_group = "Visual",
			})
		elseif item.sha then
			local col = self:is_origin(item) and #"▶ " or 2
			vim.api.nvim_buf_set_extmark(win.buf, ns, row, col, {
				end_col = col + 8,
				hl_group = "Comment",
			})
		end
		if self:is_origin(item) then
			vim.api.nvim_buf_set_extmark(win.buf, ns, row, 0, {
				end_col = #"▶",
				hl_group = "DiagnosticInfo",
			})
		end
	end
	vim.bo[win.buf].modifiable = false
	if self.index and win:win_valid() then
		vim.api.nvim_win_set_cursor(win.win, { offset + #self.items - self.index + 1, 0 })
		vim.api.nvim_win_call(win.win, function()
			vim.cmd("normal! zz")
		end)
	end
end

--- The layout owns this non-focusable history pane; h/l work in the file list and preview.
function M:layout(height)
	return {
		box = "vertical",
		height = height,
		border = "rounded",
		title = " Commits · h: older / l: newer ",
		title_pos = "left",
		wo = { wrap = false },
		bo = { modifiable = false },
		b = { git_annotate_history = true },
		on_win = function(win)
			self:render(win)
		end,
	}
end

function M:load()
	if self.closed or self.process or not self.more then
		return
	end
	local command = {
		"git",
		"--no-pager",
		"log",
		"--all",
		"--date-order",
		"--no-decorate",
		"--no-color",
		"-z",
		"--format=%H%x00%s",
		"--max-count=" .. (PAGE_SIZE + 1),
		"--skip=" .. self.offset,
		"HEAD",
	}
	if self.opts.sha then
		command[#command + 1] = self.opts.sha
	end
	command[#command + 1] = "--"
	self.request = (self.request or 0) + 1
	local request = self.request
	self.process = self.opts.run(command, function(result)
		if self.closed or request ~= self.request then
			return
		end
		self.process = nil
		if result.code ~= 0 and not result.truncated then
			self.message = "History unavailable: " .. vim.trim(result.stderr):gsub("[\r\n]+", " ")
			self.more = false
			self:render()
			return
		end
		local fields = vim.split(result.stdout, "\0", { plain = true })
		local count = math.floor((#fields - 1) / 2)
		self.more = count > PAGE_SIZE or result.truncated
		local added = math.min(count, PAGE_SIZE)
		for i = 1, added do
			local sha, subject = fields[i * 2 - 1], fields[i * 2]
			self.items[#self.items + 1] = { sha = sha, subject = subject ~= "" and subject or "(No commit message)" }
			if not self.index and sha == self.opts.sha then
				self.index = #self.items
			end
		end
		self.offset = self.offset + added
		self.message = nil
		if added == 0 and self.more then
			self.more = false
			self.message = "History entry exceeds the 2 MiB limit"
		end
		if not self.index then
			self.message = self.more and "Locating current commit…" or "Current commit not found"
		end
		self:render()
		if not self.index and self.more then
			self:load()
		elseif self.pending_move then
			self.pending_move = nil
			self:move(1)
		end
	end, self.opts.cwd)
end

function M:move(delta)
	if self.closed or not self.index then
		return
	end
	self.pending_move = nil
	local index = self.index + delta
	if index > #self.items and self.more then
		self.pending_move = true
		self:load()
		return
	end
	if index < 1 or index > #self.items then
		return
	end
	self.index = index
	self:render()
	self.opts.on_select(self.items[index])
end

function M:close()
	self.closed = true
	self.request = (self.request or 0) + 1
	if self.process then
		pcall(self.process.kill, self.process, 15)
		self.process = nil
	end
end

return M
