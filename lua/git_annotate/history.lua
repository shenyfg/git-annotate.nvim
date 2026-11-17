local M = {}
M.__index = M

local SLICE_NS = 3 * 1000 * 1000
local REFRESH_MS = 33
local ns = vim.api.nvim_create_namespace("git_annotate_history")
local selection_ns = vim.api.nvim_create_namespace("git_annotate_history_selection")

local function cancel_timer(timer)
	if timer and not timer:is_closing() then
		timer:stop()
		timer:close()
	end
end

--- @param opts {cwd: string, sha?: string, working: boolean, on_select: function, format: function}
function M.new(opts)
	local self = setmetatable({
		opts = opts,
		items = {},
		visible = {},
		positions = {},
		filter = "",
		tokens = {},
		more = true,
	}, M)
	if opts.working then
		self.items[1] = { working = true, subject = "Working Tree · Not committed yet" }
		self.index = 1
		self.visible[1], self.positions[1] = 1, 1
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
	if #self.tokens == 0 then
		return true
	end
	item.search = item.search or vim.fn.tolower((item.sha or "") .. " " .. item.subject .. " " .. (item.author or ""))
	for _, token in ipairs(self.tokens) do
		if not item.search:find(token, 1, true) then
			return false
		end
	end
	return true
end

function M:add_match(index)
	if self:matches(self.items[index]) then
		self.visible[#self.visible + 1] = index
		self.positions[index] = #self.visible
	end
end

function M:select_match()
	if self.restore_selection and not self.index then
		return
	end
	-- Wait until the current selection has been checked before choosing a replacement.
	if self.filter_next and self.index and self.filter_next <= self.index then
		return
	end
	if self.filter ~= "" and self.visible[1] and not self.positions[self.index] then
		self.index = self.visible[1]
		self.opts.on_select(self.items[self.index])
	end
end

function M:refresh()
	if self.closed then
		return
	end
	self:select_match()
	local position = self.positions[self.index]
	if self.pending_move and position and self.visible[position + 1] then
		self:move(1)
	elseif not self.more and not self.filter_next then
		self.pending_move = nil
	end
	if not self.render_timer and not self.closed then
		self.render_timer = vim.defer_fn(function()
			self.render_timer = nil
			self:render()
		end, REFRESH_MS)
	end
end

--- Scan loaded records in short slices; arriving records join the same scan.
function M:scan_filter()
	if self.closed then
		return
	end
	local deadline = vim.uv.hrtime() + SLICE_NS
	while self.filter_next <= #self.items and vim.uv.hrtime() < deadline do
		self:add_match(self.filter_next)
		self.filter_next = self.filter_next + 1
	end
	if self.filter_next > #self.items then
		self.filter_next = nil
	else
		self.filter_timer = vim.defer_fn(function()
			self.filter_timer = nil
			self:scan_filter()
		end, 1)
	end
	self:refresh()
end

--- Update the visible history while retaining already loaded commits.
function M:set_filter(query, restore_index)
	if self.closed then
		return
	end
	cancel_timer(self.filter_timer)
	self.filter_timer = nil
	self.filter = vim.trim(query)
	self.tokens = vim.split(vim.fn.tolower(query), "%s+", { trimempty = true })
	self.pending_move, self.first, self.render_key = nil, nil, nil
	self.restore_selection = nil
	self.visible, self.positions = {}, {}
	if restore_index and self.index ~= restore_index then
		self.index = restore_index
		self.opts.on_select(self.items[self.index])
	end
	self.filter_next = 1
	self:scan_filter()
	self:render()
end

--- Draw at most three screens, keeping logical indices independent of buffer rows.
function M:render(win)
	win = win or self.win
	self.win = win
	if self.closed or not win or not win:buf_valid() then
		return
	end
	local height = win:win_valid() and vim.api.nvim_win_get_height(win.win) or 10
	local capacity = math.max(3, height * 3)
	local count = #self.visible
	local position = self.positions[self.index]
	local first = self.first or 1
	if position and (position < first + height or position > first + capacity - height) then
		first = math.max(1, position - math.floor(capacity / 2))
	end
	first = math.max(1, math.min(first, count - capacity + 1))
	local last = math.min(count, first + capacity - 1)
	local loading = self.more or self.filter_next ~= nil
	local message = self.message or (loading and "Loading history…" or nil)
	if not self.index and self.filter == "" then
		last = 0
		message = self.message or (loading and "Locating current commit…" or "Current commit not found")
	elseif self.filter ~= "" and count == 0 then
		message = self.message or (loading and "Filtering history…" or "No matching commits · diff unchanged")
	elseif self.filter ~= "" and loading then
		message = self.message or "Filtering history…"
	end
	local key = table.concat({
		self.filter,
		self.visible[first] or 0,
		self.visible[last] or 0,
		self.filter ~= "" and count or 0,
		message or "",
	}, "\0")
	self.first = first
	if self.render_key ~= key or self.render_buf ~= win.buf then
		local lines = {}
		if self.filter ~= "" then
			lines[1] = {
				{
					"Filter: " .. self.filter .. " · " .. count .. (loading and "+ matches" or " matches"),
					"DiagnosticInfo",
				},
			}
		end
		self.rows = {}
		for row = first, last do
			local index = self.visible[row]
			local item = self.items[index]
			self.rows[index] = #lines + 1
			local line = { { self:is_origin(item) and "▶ " or "  ", "DiagnosticInfo" } }
			local content = item.working and { { item.subject, "SnacksPickerGitMsg" } } or self.opts.format(item)
			Snacks.picker.highlight.extend(line, content)
			lines[#lines + 1] = line
		end
		if message or #lines == 0 then
			lines[#lines + 1] = { { message or "No commits", "Comment" } }
		end
		Snacks.picker.highlight.render(win.buf, ns, lines)
		self.render_key, self.render_buf = key, win.buf
	end
	self:show_selection()
end

--- Move only the selection mark while browsing already rendered history.
function M:show_selection()
	local win = self.win
	if not win or not win:buf_valid() then
		return
	end
	vim.api.nvim_buf_clear_namespace(win.buf, selection_ns, 0, -1)
	local selected_row = self.rows and self.rows[self.index]
	if selected_row and win:win_valid() then
		vim.api.nvim_buf_set_extmark(win.buf, selection_ns, selected_row - 1, 0, { line_hl_group = "Visual" })
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
			vim.api.nvim_create_autocmd({ "VimResized", "WinResized" }, {
				group = win.augroup,
				callback = function()
					self:refresh()
				end,
			})
		end,
	}
end

function M:load()
	if self.closed then
		return
	end
	if self.started then
		if self.filter_next and not self.filter_timer then
			self:scan_filter()
		end
		self:refresh()
		return
	end
	if self.restart then
		local selected = self.items[self.index]
		self.locate_sha = selected and selected.sha or self.opts.sha
		self.restore_selection = selected and not selected.working
		self.items, self.visible, self.positions, self.index = {}, {}, {}, nil
		if self.opts.working then
			self.items[1] = { working = true, subject = "Working Tree · Not committed yet" }
			self:add_match(1)
			self.index = not self.restore_selection and 1 or nil
		end
		self.filter_next, self.first, self.render_key, self.message, self.restart = nil, nil, nil, nil, nil
	end
	self.started = true
	self.request = (self.request or 0) + 1
	local request = self.request
	local function valid()
		return not self.closed and self.request == request
	end
	self.cancel = require("git_annotate.history_stream").start({
		cwd = self.opts.cwd,
		sha = self.opts.sha,
		on_record = function(fields)
			if not valid() then
				return
			end
			local subject = fields[4] ~= "" and fields[4] or "(No commit message)"
			self.items[#self.items + 1] = {
				sha = fields[1],
				commit = fields[2],
				date = fields[3],
				subject = subject,
				msg = subject,
				author = fields[5],
			}
			if not self.filter_next then
				self:add_match(#self.items)
			end
			if not self.index and fields[1] == (self.locate_sha or self.opts.sha) then
				self.index = #self.items
			end
		end,
		on_batch = function()
			if valid() then
				self:refresh()
			end
		end,
		on_exit = function(err)
			if not valid() then
				return
			end
			self.cancel, self.more = nil, false
			self.restore_selection = nil
			self.message = err and "History unavailable: " .. vim.trim(err):gsub("[\r\n]+", " ") or nil
			self:refresh()
		end,
	})
end

function M:move(delta)
	if self.closed or not self.index then
		return
	end
	self.pending_move = nil
	local position = self.positions[self.index]
	if not position then
		return
	end
	position = position + delta
	if position > #self.visible and (self.more or self.filter_next) then
		self.pending_move = true
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
	cancel_timer(self.render_timer)
	cancel_timer(self.filter_timer)
	self.render_timer, self.filter_timer = nil, nil
	if self.cancel then
		self.cancel()
		self.cancel = nil
		self.started, self.restart = false, true
	end
end

return M
