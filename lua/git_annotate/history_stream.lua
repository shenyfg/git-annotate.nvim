local M = {}
local uv = vim.uv
local SLICE_NS = 3 * 1000 * 1000
local MAX_RECORD_BYTES = 2 * 1024 * 1024
local MAX_ERROR_BYTES = 16 * 1024

--- Read one Git history traversal with bounded buffering and cooperative parsing.
--- @param opts {cwd: string, sha?: string, on_record: function, on_batch: function, on_exit: function}
--- @return function cancel
function M.start(opts)
	local stdout, stderr = uv.new_pipe(false), uv.new_pipe(false)
	local process, timer, stopped, finished, cancelled
	local output_done, error_done, exit_code, exit_signal
	local error_text = ""
	local chunk, cursor, field, fields, record_bytes = nil, 1, "", {}, 0

	local function close_pipe(pipe)
		if not pipe:is_closing() then
			pipe:read_stop()
			pipe:close()
		end
	end

	local function stop()
		stopped = true
		if timer and not timer:is_closing() then
			timer:stop()
			timer:close()
		end
		close_pipe(stdout)
		close_pipe(stderr)
		if process and not process:is_closing() then
			process:kill(15)
		end
		chunk, field, fields = nil, "", {}
	end

	local function cancel()
		cancelled = true
		stop()
	end

	local function finish(err)
		if stopped or finished then
			return
		end
		finished = true
		vim.schedule(function()
			if not cancelled then
				opts.on_exit(err)
			end
		end)
	end

	local function fail(err)
		if stopped then
			return
		end
		stop()
		-- Cancellation suppresses callbacks; an I/O or parsing failure must be reported.
		vim.schedule(function()
			if not cancelled then
				opts.on_exit(tostring(err))
			end
		end)
	end

	local function check_exit()
		if not output_done or not error_done or exit_code == nil then
			return
		end
		if exit_signal ~= 0 then
			finish("git log terminated by signal " .. exit_signal)
		elseif exit_code ~= 0 then
			finish(error_text ~= "" and error_text or "git log exited with code " .. exit_code)
		elseif field ~= "" or #fields > 0 then
			finish("Incomplete Git history record")
		else
			finish()
		end
	end

	local read_stdout, drain
	local function consume()
		local deadline, added = uv.hrtime() + SLICE_NS, false
		while cursor <= #chunk and uv.hrtime() < deadline do
			local ending = chunk:find("\0", cursor, true)
			local part = chunk:sub(cursor, ending and ending - 1 or -1)
			record_bytes = record_bytes + #part + (ending and 1 or 0)
			if record_bytes > MAX_RECORD_BYTES then
				error("History entry exceeds the 2 MiB limit")
			end
			field = field .. part
			cursor = ending and ending + 1 or #chunk + 1
			if ending then
				fields[#fields + 1], field = field, ""
				if #fields == 5 then
					opts.on_record(fields)
					if stopped then
						return
					end
					fields, record_bytes, added = {}, 0, true
				end
			end
		end
		if added then
			opts.on_batch()
		end
		if stopped then
			return
		end
		if cursor <= #chunk then
			timer = vim.defer_fn(drain, 1)
		else
			chunk = nil
			assert(stdout:read_start(read_stdout))
		end
	end

	drain = function()
		timer = nil
		if stopped then
			return
		end
		local ok, err = pcall(consume)
		if not ok then
			fail(err)
		end
	end
	read_stdout = function(err, data)
		if stopped then
			return
		end
		if err then
			fail(err)
		elseif data then
			-- Keep at most one pipe chunk pending. Git waits when its pipe fills.
			stdout:read_stop()
			chunk, cursor = data, 1
			vim.schedule(drain)
		else
			output_done = true
			close_pipe(stdout)
			check_exit()
		end
	end

	local args = {
		"--no-pager",
		"log",
		"--all",
		"--date-order",
		"--no-decorate",
		"--no-color",
		"-z",
		"--format=%H%x00%h%x00%ch%x00%s%x00%an",
		"HEAD",
	}
	if opts.sha then
		args[#args + 1] = opts.sha
	end
	args[#args + 1] = "--"
	local spawn_error
	process, spawn_error = uv.spawn(
		"git",
		{ args = args, cwd = opts.cwd, stdio = { nil, stdout, stderr } },
		function(code, signal)
			exit_code, exit_signal = code, signal
			process:close()
			check_exit()
		end
	)
	if not process then
		close_pipe(stdout)
		close_pipe(stderr)
		finish("Unable to start git log: " .. tostring(spawn_error))
		return cancel
	end
	local ok, read_error = stdout:read_start(read_stdout)
	if not ok then
		fail(read_error)
		return cancel
	end
	ok, read_error = stderr:read_start(function(err, data)
		if stopped then
			return
		end
		if err then
			fail(err)
		elseif data then
			error_text = error_text .. data:sub(1, math.max(0, MAX_ERROR_BYTES - #error_text))
		else
			error_done = true
			close_pipe(stderr)
			check_exit()
		end
	end)
	if not ok then
		fail(read_error)
	end
	return cancel
end

return M
