local M = {}
local sessions = {}
local next_id = 0
local ns = vim.api.nvim_create_namespace("git_annotate_preview")
local FRAME_NS = 4 * 1000 * 1000

--- Format with the installed Snacks implementation in the worker process.
function M._format(id, token, lines, opts, icon)
	local function send(rows, done, err)
		vim.rpcnotify(1, "nvim_exec_lua", "require('git_annotate.preview')._receive(...)", {
			id,
			token,
			rows,
			done,
			err or false,
		})
	end
	local ok, err = pcall(function()
		Snacks.util.icon = function()
			return unpack(icon)
		end
		local formatted = require("snacks.picker.util.diff").format(lines, opts)
		local batch = {}
		for _, line in ipairs(formatted) do
			local text, marks, meta = Snacks.picker.highlight.to_text(line)
			for _, mark in ipairs(marks) do
				mark.field, mark.row = nil, nil
			end
			batch[#batch + 1] = { text, marks, meta or false }
			if #batch == 32 then
				send(batch, false)
				batch = {}
			end
		end
		send(batch, true)
	end)
	if not ok then
		send({}, true, tostring(err))
	end
end

local function valid(session, request)
	return not session.closed and session.request == request and request.valid()
end

local function apply_mark(request, batch)
	local row = batch[request.row]
	local mark = row[2][request.mark]
	if mark then
		local col = mark.col
		mark.col = nil
		vim.api.nvim_buf_set_extmark(request.buf, ns, request.written + request.row - 1, col, mark)
		request.mark = request.mark + 1
	else
		if row[3] then
			request.meta[request.written + request.row] = row[3]
		end
		request.row, request.mark = request.row + 1, 1
		if request.row > #batch then
			request.written = request.written + #batch
			request.queue[request.head] = nil
			request.head = request.head + 1
			request.row = nil
		end
	end
end

local function apply(session, request)
	if not valid(session, request) then
		return
	end
	local ctx = request.ctx
	if not request.buf then
		request.buf = ctx.preview:scratch()
		ctx.preview.win:map()
		Snacks.util.wo(ctx.win, ctx.picker.opts.previewers.diff.wo or {})
		vim.b[request.buf].git_annotate_rendering = true
	end
	local buf = request.buf
	local deadline = vim.uv.hrtime() + FRAME_NS
	vim.bo[buf].modifiable = true
	while vim.uv.hrtime() < deadline do
		local batch = request.queue[request.head]
		if not batch then
			break
		end
		if not request.row then
			local lines = {}
			for _, row in ipairs(batch) do
				lines[#lines + 1] = row[1]
			end
			vim.api.nvim_buf_set_lines(buf, request.written == 0 and 0 or -1, -1, false, lines)
			request.row, request.mark = 1, 1
		end
		apply_mark(request, batch)
	end
	vim.bo[buf].modifiable = false
	if request.done and not request.queue[request.head] then
		vim.b[buf].snacks_meta = request.meta
		vim.b[buf].git_annotate_rendering = false
		request.finish()
		return
	end
	if request.queue[request.head] then
		request.timer = vim.defer_fn(function()
			request.timer = nil
			M._apply(session, request)
		end, 1)
	end
end

--- Apply prepared extmarks in short slices so input can run between frames.
function M._apply(session, request)
	local ok, err = pcall(apply, session, request)
	if not ok and valid(session, request) then
		M.cancel(session)
		request.finish(tostring(err))
	end
end

local function dispatch(session)
	local request = session.request
	if session.busy or not request or request.sent or not valid(session, request) then
		return
	end
	request.sent = true
	session.busy = request.token
	local ok, err =
		pcall(vim.rpcnotify, session.channel, "nvim_exec_lua", "require('git_annotate.preview')._format(...)", {
			session.id,
			request.token,
			request.lines,
			request.opts,
			request.icon,
		})
	request.lines = nil
	if not ok then
		M.close(session)
		request.finish(tostring(err))
	end
end

--- Receive bounded batches; only the latest selection may update its buffer.
function M._receive(id, token, rows, done, err)
	local session = sessions[id]
	if not session or session.closed then
		return
	end
	local request = session.request
	if request and request.token == token and valid(session, request) then
		if err then
			M.cancel(session)
			request.finish(err)
		else
			if #rows > 0 then
				request.tail = request.tail + 1
				request.queue[request.tail] = rows
			end
			request.done = done
			if not request.timer then
				request.timer = vim.defer_fn(function()
					request.timer = nil
					M._apply(session, request)
				end, 1)
			end
		end
	end
	if done and session.busy == token then
		session.busy = nil
		dispatch(session)
	end
end

--- Start one persistent formatter for a picker, using its installed runtime files.
function M.new()
	require("snacks.picker.util.diff") -- Define the same highlight groups in the UI.
	next_id = next_id + 1
	local session = { id = next_id, token = 0 }
	sessions[session.id] = session
	session.channel = vim.fn.jobstart({ vim.v.progpath, "--embed", "--headless", "-u", "NONE", "-i", "NONE" }, {
		rpc = true,
		on_exit = function(_, code)
			if not session.closed then
				local request = session.request
				M.close(session)
				if request and request.valid() then
					request.finish("Diff formatter exited: " .. code)
				end
			end
		end,
	})
	if session.channel <= 0 then
		M.close(session)
		error("Unable to start the diff formatter")
	end
	local ok, err = pcall(
		vim.rpcnotify,
		session.channel,
		"nvim_exec_lua",
		[[
		local paths, background = ...
		vim.opt.runtimepath = paths
		vim.o.background = background
		require('snacks').setup({picker = {enabled = true}, image = {enabled = false}})
	]],
		{ vim.api.nvim_list_runtime_paths(), vim.o.background }
	)
	if not ok then
		M.close(session)
		error(err)
	end
	return session
end

function M.cancel(session)
	local request = session.request
	session.request = nil
	if request and request.timer and not request.timer:is_closing() then
		request.timer:stop()
		request.timer:close()
	end
end

--- Queue the latest preview without waiting for the formatter's current job.
function M.render(session, ctx, lines, is_valid, finish)
	M.cancel(session)
	session.token = session.token + 1
	session.request = {
		token = session.token,
		ctx = ctx,
		lines = lines,
		opts = { annotations = ctx.item.annotations or ctx.picker.opts.annotations },
		icon = { Snacks.util.icon(ctx.item.file) },
		valid = is_valid,
		finish = finish,
		queue = {},
		head = 1,
		tail = 0,
		written = 0,
		meta = {},
	}
	dispatch(session)
end

function M.close(session)
	M.cancel(session)
	session.closed = true
	sessions[session.id] = nil
	if session.channel and session.channel > 0 then
		pcall(vim.fn.jobstop, session.channel)
	end
end

return M
