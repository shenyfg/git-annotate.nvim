local M = {}
M.__index = M

local PAGE_SIZE = 200
local ns = vim.api.nvim_create_namespace("git_annotate_history")

--- @param opts {cwd: string, sha?: string, working: boolean, run: function, on_select: function, format: function}
function M.new(opts)
	local self = setmetatable({
		opts = opts,
		items = {},
		visible = {},
		filter = "",
		tokens = {},
		offset = 0,
		more = true,
		message = "Loading history…",
	}, M)
	if opts.working then
		self.items[1] = { working = true, subject = "Working Tree · Not committed yet" }
		self.index = 1
		self.visible[1] = 1
	end
	return self
end

function M:is_origin(item)
	if self.opts.working then
		return item.working == true
	end
	return item.sha == self.opts.sha
end

--- Match all space-separated terms literally, ignoring case.
function M:matches(item)
	local text = vim.fn.tolower((item.sha or "") .. " " .. item.subject .. " " .. (item.author or ""))
	for _, token in ipairs(self.tokens) do
		if not text:find(token, 1, true) then
			return false
		end
	end
	return true
end

function M:select_match()
	if self.filter ~= "" and self.visible[1] and not vim.tbl_contains(self.visible, self.index) then
		self.index = self.visible[1]
		self.opts.on_select(self.items[self.index])
	end
end

--- Update the visible history while retaining already loaded commits.
function M:set_filter(query, restore_index)
	if self.closed then
		return
	end
	self.filter = vim.trim(query)
	self.tokens = vim.split(vim.fn.tolower(query), "%s+", { trimempty = true })
	self.pending_move = nil
	self.visible = {}
	for index, item in ipairs(self.items) do
		if self:matches(item) then
			self.visible[#self.visible + 1] = index
		end
	end
	if restore_index and self.index ~= restore_index then
		self.index = restore_index
		self.opts.on_select(self.items[self.index])
	end
	self:select_match()
	self:render()
	if self.filter ~= "" then
		self:load()
	end
end

function M:render(win)
	win = win or self.win
	if not win or not win:buf_valid() then
		return
	end
	self.win = win
	local lines = {}
	if self.filter ~= "" then
		local count = #self.visible .. (self.more and "+ matches" or " matches")
		lines[1] = { { "Filter: " .. self.filter .. " · " .. count, "DiagnosticInfo" } }
	end
	local selected_row
	for _, index in ipairs(self.visible) do
		local item = self.items[index]
		if index == self.index then
			selected_row = #lines + 1
		end
		local line = { { self:is_origin(item) and "▶ " or "  ", "DiagnosticInfo" } }
		local content = item.working and { { item.subject, "SnacksPickerGitMsg" } } or self.opts.format(item)
		Snacks.picker.highlight.extend(line, content)
		lines[#lines + 1] = line
	end
	local message = self.message
		or (self.more and (self.filter ~= "" and "Filtering history…" or "… n: load older commits"))
	if self.filter ~= "" and #self.visible == 0 then
		lines[#lines + 1] = { { "No matching commits · diff unchanged", "Comment" } }
	end
	if message or #lines == 0 then
		lines[#lines + 1] = { { message or "No commits", "Comment" } }
	end
	Snacks.picker.highlight.render(win.buf, ns, lines)
	if selected_row and win:win_valid() then
		vim.api.nvim_buf_set_extmark(win.buf, ns, selected_row - 1, 0, { line_hl_group = "Visual" })
		vim.api.nvim_win_set_cursor(win.win, { selected_row, 0 })
		vim.api.nvim_win_call(win.win, function()
			vim.cmd("normal! zz")
		end)
	end
end

--- The layout owns this non-focusable history pane; p/n work in the file list and preview.
function M:layout(height)
	return {
		box = "vertical",
		height = height,
		border = "rounded",
		title = " Git Log · f: filter · p/n: newer/older ",
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
		"--format=%H%x00%h%x00%ch%x00%s%x00%an",
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
		local count = math.floor((#fields - 1) / 5)
		self.more = count > PAGE_SIZE or result.truncated
		local added = math.min(count, PAGE_SIZE)
		for i = 1, added do
			local offset = (i - 1) * 5
			local sha, subject = fields[offset + 1], fields[offset + 4]
			subject = subject ~= "" and subject or "(No commit message)"
			self.items[#self.items + 1] = {
				sha = sha,
				commit = fields[offset + 2],
				date = fields[offset + 3],
				subject = subject,
				msg = subject,
				author = fields[offset + 5],
			}
			if self:matches(self.items[#self.items]) then
				self.visible[#self.visible + 1] = #self.items
			end
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
		self:select_match()
		self:render()
		if not self.index and self.more then
			self:load()
		elseif self.pending_move then
			self.pending_move = nil
			self:move(1)
		end
		if self.filter ~= "" then
			self:load()
		end
	end, self.opts.cwd)
end

function M:move(delta)
	if self.closed or not self.index then
		return
	end
	self.pending_move = nil
	local position
	for row, index in ipairs(self.visible) do
		if index == self.index then
			position = row
			break
		end
	end
	if not position then
		return
	end
	position = position + delta
	if position > #self.visible and self.more then
		self.pending_move = true
		self:load()
		return
	end
	local index = self.visible[position]
	if not index then
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
