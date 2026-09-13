local M = {}

local MAX_DIFF_PREVIEW_BYTES = 2 * 1024 * 1024
local DIFF_LOADING_DELAY_MS = 3000
local preview_ns = vim.api.nvim_create_namespace("git_annotate_preview")
local pending_request
local hover_requests = {}

--- 解析 git blame --line-porcelain 输出
--- 每个 commit 块格式：
---   <sha> <orig_line> <final_line> [<num_lines>]
---   author <name>
---   author-mail <email>
---   author-time <unix_ts>
---   author-tz <tz>
---   committer ...
---   summary <msg>
---   filename <path>   ← 块的最后一行
---   \t<line_content>  ← 实际代码行
--- @param blame_output string[]
--- @return {text: string, author_time: integer, sha: string}[]
local function parse_blame(blame_output)
	local annotations = {}
	local current = {}

	for _, line in ipairs(blame_output) do
		-- commit 块首行：40位 sha + 行号信息
		local sha = line:match("^(%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x) ")
		if sha then
			current.sha = sha
		end

		local a = line:match("^author (.+)")
		if a then
			current.author = a
		end

		local t = line:match("^author%-time (%d+)")
		if t then
			current.author_time = tonumber(t)
		end

		-- filename 是每个 commit 块的最后一个字段行，之后紧跟代码行
		-- 以 filename 为触发点记录一条 annotation
		if line:match("^filename ") then
			local author = current.author or "Unknown"
			local author_time = current.author_time or 0
			local text
			if author == "Not Committed Yet" then
				text = "Not Committed"
			else
				local today = os.date("*t")
				local commit = os.date("*t", author_time)
				local date
				if commit.year == today.year and commit.month == today.month and commit.day == today.day then
					date = "Today    "
				else
					local yesterday = os.date("*t", os.time() - 86400)
					if
						commit.year == yesterday.year
						and commit.month == yesterday.month
						and commit.day == yesterday.day
					then
						date = "Yesterday"
					else
						date = os.date("%y/%m/%d ", author_time)
					end
				end
				text = string.format("%s %s", date, author)
			end
			table.insert(annotations, {
				text = text,
				author_time = author_time,
				sha = current.sha or "",
				uncommitted = (author == "Not Committed Yet"),
			})
			current = {}
		end
	end

	return annotations
end

--- 根据时间戳计算渐变高亮
--- @param annotations {text: string, author_time: integer}[]
--- @param buf integer
local function apply_highlights(annotations, buf)
	local N = 12 -- 渐变色阶数

	-- 计算时间范围（忽略未提交行 time=0）
	local min_t, max_t
	for _, ann in ipairs(annotations) do
		local t = ann.author_time
		if t > 0 then
			if not min_t or t < min_t then
				min_t = t
			end
			if not max_t or t > max_t then
				max_t = t
			end
		end
	end
	min_t = min_t or 0
	max_t = max_t or min_t

	-- 配色方案：新提交暖橙色，越旧越冷越暗（IntelliJ 风格）
	-- 新 (ratio=1): #7a4a1a fg=#f0c080  暖橙棕，高饱和
	-- 旧 (ratio=0): #252830 fg=#606878  冷灰蓝，低饱和暗淡
	for i = 1, N do
		local ratio = (i - 1) / math.max(N - 1, 1)
		-- bg: 冷灰蓝 #252830 → 暖橙棕 #7a4a1a
		local bg_r = math.floor(0x25 + ratio * (0x7a - 0x25))
		local bg_g = math.floor(0x28 + ratio * (0x4a - 0x28))
		local bg_b = math.floor(0x30 + ratio * (0x1a - 0x30))
		-- fg: 暗灰 #606878 → 亮橙 #f0c080，保持可读性
		local fg_r = math.floor(0x60 + ratio * (0xf0 - 0x60))
		local fg_g = math.floor(0x68 + ratio * (0xc0 - 0x68))
		local fg_b = math.floor(0x78 + ratio * (0x80 - 0x78))
		vim.api.nvim_set_hl(0, "GitAnnotateAge" .. i, {
			bg = string.format("#%02x%02x%02x", bg_r, bg_g, bg_b),
			fg = string.format("#%02x%02x%02x", fg_r, fg_g, fg_b),
		})
	end
	-- 未提交行：继承 DiffAdd 配色，加斜体
	local diffadd = vim.api.nvim_get_hl(0, { name = "DiffAdd", link = false })
	vim.api.nvim_set_hl(0, "GitAnnotateUncommitted", {
		default = true,
		bg = diffadd.bg,
		fg = diffadd.fg,
		italic = true,
	})

	local ns = vim.api.nvim_create_namespace("git_annotate")
	for idx, ann in ipairs(annotations) do
		local hl_group
		if ann.uncommitted then
			hl_group = "GitAnnotateUncommitted"
		else
			local t = ann.author_time
			local ratio = (max_t == min_t) and 1 or (t - min_t) / (max_t - min_t)
			local bucket = math.min(N, math.floor(ratio * (N - 1)) + 1)
			hl_group = "GitAnnotateAge" .. bucket
		end
		vim.api.nvim_buf_set_extmark(buf, ns, idx - 1, 0, {
			end_row = idx,
			end_col = 0,
			hl_group = hl_group,
			hl_eol = true,
		})
	end
end

--- 判断是否为未提交行
--- @param sha string
--- @return boolean
local function is_uncommitted(sha)
	return not sha or sha == "" or sha:match("^0+$")
end

--- 在默认浏览器中打开提交，复用 Snacks 的远程地址与托管平台适配
--- @param sha? string
--- @param main_win integer
local function open_commit_browser(sha, main_win)
	if is_uncommitted(sha) then
		vim.notify("Git annotate: uncommitted changes have no commit page", vim.log.levels.WARN)
		return
	end
	if not vim.api.nvim_win_is_valid(main_win) then
		vim.notify("Git annotate: source window closed", vim.log.levels.WARN)
		return
	end
	local ok, snacks = pcall(require, "snacks")
	if not ok or not snacks.gitbrowse then
		vim.notify("Git annotate: O requires snacks.nvim", vim.log.levels.WARN)
		return
	end
	-- 侧栏和 picker 都是临时 buffer；从源文件窗口解析仓库，避免使用错误的 cwd。
	vim.api.nvim_win_call(main_win, function()
		snacks.gitbrowse({ what = "commit", commit = sha })
	end)
end

--- 判断 commit 是否为根提交
--- @param sha string
--- @param callback fun(root: boolean?, err: string?)
--- @param cwd? string
local function is_root_commit(sha, callback, cwd)
	return vim.system(
		{ "git", "rev-list", "--parents", "-n", "1", sha },
		{ text = true, cwd = cwd },
		vim.schedule_wrap(function(result)
			if result.code ~= 0 then
				local message = vim.trim(result.stderr or "")
				callback(nil, message ~= "" and message or "git rev-list failed")
				return
			end

			local commits = {}
			for commit in (result.stdout or ""):gmatch("%S+") do
				table.insert(commits, commit)
			end
			if #commits == 0 then
				callback(nil, "git rev-list returned no commit")
				return
			end
			callback(#commits == 1)
		end)
	)
end

--- 有界收集命令输出，超过上限后终止子进程
--- @param command string[]
--- @param callback fun(result: {code: integer, signal: integer, stdout: string, stderr: string, truncated: boolean})
--- @param cwd? string
--- @return vim.SystemObj
local function collect_bounded(command, callback, cwd)
	local stdout_chunks = {}
	local stderr_chunks = {}
	local stdout_bytes = 0
	local stderr_bytes = 0
	local truncated = false
	local stopped = false
	local kill_pending = false
	local process

	local function stop_process()
		if stopped then
			return
		end
		stopped = true
		if process then
			pcall(process.kill, process, 15)
		else
			kill_pending = true
		end
	end

	local function collect_stdout(err, data)
		if err then
			table.insert(stderr_chunks, tostring(err))
		end
		if not data or truncated then
			return
		end

		local remaining = MAX_DIFF_PREVIEW_BYTES - stdout_bytes
		if #data > remaining then
			if remaining > 0 then
				table.insert(stdout_chunks, data:sub(1, remaining))
				stdout_bytes = stdout_bytes + remaining
			end
			truncated = true
			stop_process()
			return
		end

		table.insert(stdout_chunks, data)
		stdout_bytes = stdout_bytes + #data
	end

	local function collect_stderr(err, data)
		if err then
			data = tostring(err) .. (data or "")
		end
		if not data or stderr_bytes >= MAX_DIFF_PREVIEW_BYTES then
			return
		end
		local remaining = MAX_DIFF_PREVIEW_BYTES - stderr_bytes
		data = data:sub(1, remaining)
		table.insert(stderr_chunks, data)
		stderr_bytes = stderr_bytes + #data
	end

	process = vim.system(
		command,
		{
			text = true,
			cwd = cwd,
			stdout = collect_stdout,
			stderr = collect_stderr,
		},
		vim.schedule_wrap(function(result)
			callback({
				code = result.code,
				signal = result.signal,
				stdout = table.concat(stdout_chunks),
				stderr = table.concat(stderr_chunks),
				truncated = truncated,
			})
		end)
	)

	if kill_pending then
		pcall(process.kill, process, 15)
	end
	return process
end

--- 解析 diff 命令输出并添加保护提示
--- @param output string
--- @param truncated boolean
--- @return string[]
local function diff_lines(output, truncated)
	local lines = vim.split(output, "\n", { plain = true })
	if #lines > 0 and lines[#lines] == "" then
		table.remove(lines)
	end
	if truncated then
		table.insert(lines, "")
		table.insert(lines, "[Git annotate: diff preview truncated at 2 MiB.]")
	end
	return lines
end

--- 读取提交信息，供侧边栏与 picker 共用
--- @param sha string
--- @param cwd string
--- @param callback fun(lines: string[]?, err?: string)
--- @return vim.SystemObj?
local function load_commit_info(sha, cwd, callback)
	if is_uncommitted(sha) then
		callback({ "Not committed yet" })
		return
	end
	return collect_bounded({
		"git",
		"show",
		"--no-patch",
		"--format=commit %h%nauthor:  %an <%ae>%ndate:    %ad%n%n%s%n%b",
		"--date=format-local:%Y-%m-%d %H:%M",
		sha,
	}, function(result)
		if result.code ~= 0 and not result.truncated then
			callback(nil, result.stderr ~= "" and result.stderr or "failed to load commit info")
			return
		end
		local lines = vim.split(result.stdout, "\n", { plain = true })
		while #lines > 1 and lines[#lines] == "" do
			table.remove(lines)
		end
		if result.truncated then
			table.insert(lines, "[Git annotate: commit info truncated at 2 MiB.]")
		end
		callback(lines)
	end, cwd)
end

--- 文件列表标题使用作者与本地时间；完整信息仍通过 K 查看
local function commit_files_title(lines)
	local author = lines and lines[2] and lines[2]:match("^author:%s*(.*)")
	local date, time
	if lines and lines[3] then
		date, time = lines[3]:match("^date:%s*(%d%d%d%d%-%d%d%-%d%d) (%d%d:%d%d)$")
	end
	if not author or not date then
		return "Commit info unavailable"
	end
	-- Omit the email address in the compact title.
	author = author:gsub("%s*<[^<>]*>$", "")
	if date == os.date("%Y-%m-%d") then
		return author .. "  Today " .. time
	end
	local year, month, day = date:match("(%d+)%-(%d+)%-(%d+)")
	return string.format("%s  %d/%d/%d, %s", author, tonumber(year), tonumber(month), tonumber(day), time)
end

--- 在浮动窗口中展示简要 commit 信息
--- @param sha string
--- @param ann_win integer
--- @param ann_buf integer
--- @param cwd string
local function show_commit_float(sha, ann_win, ann_buf, cwd)
	local cursor = vim.api.nvim_win_get_cursor(ann_win)
	local active = hover_requests[ann_buf]
	if active then
		if active.sha == sha and vim.deep_equal(active.cursor, cursor) then
			active.focus()
			return
		end
		active.close()
	end

	local closed = false
	local float_win, process
	local focus_requested = false
	local group = vim.api.nvim_create_augroup("GitAnnotateHover" .. ann_buf, { clear = true })
	local function close()
		if closed then
			return
		end
		closed = true
		hover_requests[ann_buf] = nil
		vim.api.nvim_del_augroup_by_id(group)
		if process then
			pcall(process.kill, process, 15)
		end
		if float_win and vim.api.nvim_win_is_valid(float_win) then
			vim.api.nvim_win_close(float_win, true)
		end
	end
	local function focus()
		focus_requested = true
		if float_win and vim.api.nvim_win_is_valid(float_win) then
			vim.api.nvim_set_current_win(float_win)
		end
	end
	hover_requests[ann_buf] = { close = close, focus = focus, sha = sha, cursor = cursor }
	local function close_after_leave()
		-- Wait until the destination window is known, allowing sidebar -> hover focus.
		vim.schedule(function()
			if not closed and vim.api.nvim_get_current_win() ~= float_win then
				close()
			end
		end)
	end
	vim.api.nvim_create_autocmd({ "CursorMoved", "BufWipeout" }, {
		buffer = ann_buf,
		group = group,
		callback = close,
	})
	vim.api.nvim_create_autocmd({ "BufLeave", "WinLeave" }, {
		buffer = ann_buf,
		group = group,
		callback = close_after_leave,
	})
	vim.api.nvim_create_autocmd("WinClosed", {
		pattern = tostring(ann_win),
		group = group,
		callback = close,
	})

	local function show(lines)
		if closed then
			return
		end
		if
			not vim.api.nvim_win_is_valid(ann_win)
			or vim.api.nvim_get_current_win() ~= ann_win
			or vim.api.nvim_win_get_buf(ann_win) ~= ann_buf
			or not vim.deep_equal(vim.api.nvim_win_get_cursor(ann_win), cursor)
		then
			close()
			return
		end
		while #lines > 1 and lines[#lines] == "" do
			table.remove(lines)
		end
		local width = 0
		for _, line in ipairs(lines) do
			width = math.max(width, vim.fn.strdisplaywidth(line))
		end
		width = math.max(1, math.min(math.max(width, 20), math.floor(vim.o.columns * 0.7)))
		local height = math.max(1, math.min(#lines, vim.o.lines - 4))
		local float_buf = vim.api.nvim_create_buf(false, true)
		vim.bo[float_buf].bufhidden = "wipe"
		vim.api.nvim_buf_set_lines(float_buf, 0, -1, false, lines)
		vim.bo[float_buf].filetype = "git"
		vim.bo[float_buf].modifiable = false
		float_win = vim.api.nvim_open_win(float_buf, false, {
			relative = "cursor",
			row = 1,
			col = 0,
			width = width,
			height = height,
			style = "minimal",
			border = "rounded",
			zindex = 50,
		})
		vim.wo[float_win].wrap = true
		local function dismiss()
			close()
			if vim.api.nvim_win_is_valid(ann_win) and vim.api.nvim_win_get_buf(ann_win) == ann_buf then
				vim.api.nvim_set_current_win(ann_win)
			end
		end
		for _, key in ipairs({ "q", "<Esc>", "K" }) do
			vim.keymap.set("n", key, dismiss, { buffer = float_buf, silent = true, desc = "Close commit info" })
		end
		vim.api.nvim_create_autocmd({ "BufLeave", "WinLeave" }, {
			buffer = float_buf,
			group = group,
			callback = close_after_leave,
		})
		vim.api.nvim_create_autocmd("WinClosed", {
			pattern = tostring(float_win),
			group = group,
			callback = function()
				float_win = nil
				close()
			end,
		})
		if focus_requested then
			focus()
		end
	end

	process = load_commit_info(sha, cwd, function(lines, err)
		process = nil
		if closed then
			return
		end
		if not lines then
			close()
			vim.notify("Git annotate: " .. err, vim.log.levels.ERROR)
			return
		end
		show(lines)
	end)
end

--- 使用 Snacks 与 git status 相同的 diff 风格渲染已收集的内容
--- @param ctx snacks.picker.preview.ctx
--- @param lines string[]
local function render_commit_preview(ctx, lines)
	local style = ctx.picker.opts.previewers.diff.style
	if style == "fancy" then
		local buf = ctx.preview:scratch()
		ctx.preview.win:map()
		require("snacks.picker.util.diff").render(buf, preview_ns, lines, {
			annotations = ctx.item.annotations or ctx.picker.opts.annotations,
		})
		Snacks.util.wo(ctx.win, ctx.picker.opts.previewers.diff.wo or {})
		return
	end

	ctx.preview:reset()
	ctx.preview:set_lines(lines)
	ctx.preview:highlight({ ft = "git" })
end

--- 获取文件变更的路径（rename/copy 同时包含旧新路径）
--- @param item table
--- @return string[]
local function change_paths(item)
	local paths = {}
	if item.rename then
		table.insert(paths, item.rename)
	end
	if item.file then
		table.insert(paths, item.file)
	end
	return paths
end

--- 生成单文件 diff 命令
--- @param state {working: boolean, sha?: string, root?: boolean, cwd: string}
--- @param item table
--- @return string[], boolean allow_exit_one
local function file_diff_command(state, item)
	local paths = change_paths(item)
	if state.working then
		if item.status == "??" then
			return { "git", "--no-pager", "diff", "--no-index", "--", "/dev/null", item.file }, true
		end
		local command = { "git", "--no-pager", "diff", "--no-ext-diff", "HEAD", "--" }
		vim.list_extend(command, paths)
		return command, false
	end

	if state.root then
		local command = { "git", "--no-pager", "diff-tree", "--root", "--no-commit-id", "-p", state.sha, "--" }
		vim.list_extend(command, paths)
		return command, false
	end

	local command = { "git", "--no-pager", "diff", "--no-ext-diff", state.sha .. "^", state.sha, "--" }
	vim.list_extend(command, paths)
	return command, false
end

--- @param result {code: integer, truncated: boolean}
--- @param allow_exit_one boolean
--- @return boolean
local function diff_succeeded(result, allow_exit_one)
	return result.code == 0 or result.truncated or (allow_exit_one and result.code == 1)
end

--- diff 标题仅展示提交主题，文件路径由 diff 内容展示
local function commit_preview_title(state)
	local title = state.working and "Working Tree · Not committed yet" or state.subject or "Loading commit info…"
	return title .. (state.preview_truncated and " [truncated]" or "")
end

--- 为 Snacks picker 异步预览选中文件，并限制最大输出
--- @param ctx snacks.picker.preview.ctx
--- @param state {working: boolean, sha?: string, root?: boolean, cwd: string}
local function preview_file_change(ctx, state)
	local request = {}
	state.preview_request = request
	if state.loading then
		ctx.preview:reset()
		ctx.preview:set_title(commit_preview_title(state))
		ctx.preview:set_lines({ "Loading changed files…" })
		return
	end
	if not ctx.item.file then
		ctx.preview:notify("file is missing", "error", { item = false })
		return
	end

	local revision = state.revision
	state.preview_truncated = false
	ctx.preview:reset()
	ctx.preview:set_title(commit_preview_title(state))

	local function preview_is_valid()
		return not ctx.picker.closed
			and state.revision == revision
			and state.preview_request == request
			and ctx.preview.item == ctx.item
			and ctx.preview.win:buf_valid()
	end

	-- 快速切换时不显示加载提示；过期或已完成的请求不能覆盖当前预览。
	local completed = false
	vim.defer_fn(function()
		if not completed and preview_is_valid() then
			ctx.preview:set_lines({ "Loading diff…" })
		end
	end, DIFF_LOADING_DELAY_MS)

	local function show_error(message)
		if not preview_is_valid() then
			return
		end
		ctx.preview:reset()
		ctx.preview:set_title(commit_preview_title(state))
		ctx.preview:set_lines({ "Git annotate: " .. message })
	end

	local command, allow_exit_one = file_diff_command(state, ctx.item)
	collect_bounded(command, function(result)
		completed = true
		if not preview_is_valid() then
			return
		end
		if not diff_succeeded(result, allow_exit_one) then
			show_error(result.stderr ~= "" and result.stderr or "git diff failed")
			return
		end

		render_commit_preview(ctx, diff_lines(result.stdout, result.truncated))
		state.preview_truncated = result.truncated
		ctx.preview:set_title(commit_preview_title(state))
		ctx.picker:update_titles()
	end, state.cwd)
end

--- 解析 git diff --name-status -z 输出
--- @param output string
--- @param cwd string
--- @return table[]
local function parse_changed_files(output, cwd)
	local fields = vim.split(output, "\0", { plain = true, trimempty = true })
	local items = {}
	local i = 1
	while i <= #fields do
		local raw_status = fields[i]
		i = i + 1
		local status = raw_status and raw_status:sub(1, 1) or ""
		local old_file, file
		if status == "R" or status == "C" then
			old_file, file = fields[i], fields[i + 1]
			i = i + 2
		else
			file = fields[i]
			i = i + 1
		end

		if file and file ~= "" and status:match("[AMDRCT]") then
			table.insert(items, {
				text = old_file and (old_file .. " " .. file) or file,
				file = file,
				rename = old_file,
				status = (status == "T" and "M" or status) .. " ",
				change_status = raw_status,
				cwd = cwd,
			})
		end
	end
	return items
end

--- 异步加载 commit 与第一父提交之间的文件列表
--- @param sha string
--- @param cwd string
--- @param callback fun(items: table[]?, root: boolean?, err: string?, truncated: boolean?)
local function load_commit_files(sha, cwd, callback)
	local cancelled = false
	local process
	process = is_root_commit(sha, function(root, err)
		if cancelled then
			return
		end
		if root == nil then
			callback(nil, nil, err)
			return
		end

		local command
		if root then
			command = {
				"git",
				"--no-pager",
				"diff-tree",
				"--root",
				"--no-commit-id",
				"--name-status",
				"-r",
				"-z",
				"-M",
				sha,
			}
		else
			command = { "git", "--no-pager", "diff", "--name-status", "-z", "-M", sha .. "^", sha }
		end

		process = collect_bounded(command, function(result)
			if cancelled then
				return
			end
			if result.code ~= 0 and not result.truncated then
				callback(nil, root, result.stderr ~= "" and result.stderr or "git diff failed")
				return
			end
			callback(parse_changed_files(result.stdout, cwd), root, nil, result.truncated)
		end, cwd)
	end, cwd)
	return function()
		cancelled = true
		if process then
			pcall(process.kill, process, 15)
		end
	end
end

--- @param cwd string
--- @param file string
--- @return string
local function absolute_path(cwd, file)
	if file:sub(1, 1) == "/" then
		return vim.fs.normalize(file)
	end
	return vim.fs.normalize(cwd .. "/" .. file)
end

--- 打开 picker 后定位到 annotate 对应的当前文件
--- @param picker snacks.Picker
--- @param source_file string
--- @param fallback_cwd string
--- @param attempt? integer
local function focus_picker_file(picker, source_file, fallback_cwd, attempt, valid)
	if picker.closed then
		return
	end
	if valid and not valid() then
		return
	end
	attempt = attempt or 1
	local source_path = vim.fs.normalize(source_file)
	for index, item in ipairs(picker:items()) do
		local cwd = item.cwd or fallback_cwd
		local file_matches = item.file and absolute_path(cwd, item.file) == source_path
		local rename_matches = item.rename and absolute_path(cwd, item.rename) == source_path
		if file_matches or rename_matches then
			picker.list:view(index)
			Snacks.picker.actions.list_scroll_center(picker)
			return
		end
	end

	if attempt < 50 then
		vim.defer_fn(function()
			focus_picker_file(picker, source_file, fallback_cwd, attempt + 1, valid)
		end, 20)
	end
end

--- 构建 commit/working tree 共用的文件 + diff picker 配置
--- @param state {working: boolean, sha?: string, root?: boolean, cwd: string}
--- @param ann_win integer
--- @param main_win integer
--- @param source_file string
--- @return table
local function change_picker_opts(state, ann_win, main_win, source_file)
	local info_lines, info_process, info_float
	local info_request = 0
	local files_cancel, active_picker
	local switch_commit
	state.revision = 0
	local history = require("git_annotate.history").new({
		cwd = state.cwd,
		sha = state.sha,
		working = state.working,
		run = collect_bounded,
		on_select = function(item)
			if active_picker and not active_picker.closed then
				switch_commit(active_picker, item)
			end
		end,
	})
	if state.working then
		info_lines = { "Working Tree", "Not committed yet" }
	end

	local function set_info_lines(win, lines)
		if win and win:buf_valid() then
			vim.bo[win.buf].modifiable = true
			vim.api.nvim_buf_set_lines(win.buf, 0, -1, false, lines)
			vim.bo[win.buf].modifiable = false
		end
	end

	local function load_info(picker)
		info_request = info_request + 1
		local request = info_request
		if info_process then
			pcall(info_process.kill, info_process, 15)
			info_process = nil
		end
		if info_lines then
			picker.title = state.working and "Working Tree Changes" or commit_files_title(info_lines)
			picker:update_titles()
			set_info_lines(info_float, info_lines)
			return
		end
		set_info_lines(info_float, { "Loading commit info…" })
		info_process = load_commit_info(state.sha, state.cwd, function(lines, err)
			if picker.closed or request ~= info_request then
				return
			end
			info_process = nil
			info_lines = lines or vim.split("Git annotate: " .. err, "\n", { plain = true, trimempty = true })
			picker.title = commit_files_title(lines)
			state.subject = lines and (lines[5] and lines[5] ~= "" and lines[5] or "(No commit message)")
				or state.subject
				or "Commit info unavailable · K: details"
			picker.preview:set_title(commit_preview_title(state))
			picker:update_titles()
			set_info_lines(info_float, info_lines)
		end)
	end

	switch_commit = function(picker, item)
		state.revision = state.revision + 1
		local revision = state.revision
		local function valid()
			return not picker.closed and state.revision == revision
		end
		if files_cancel then
			files_cancel()
			files_cancel = nil
		end
		state.sha, state.working, state.root = item.sha, item.working == true, nil
		state.subject, state.preview_truncated = item.subject, false
		state.items, state.loading = {}, not state.working
		info_lines = state.working and { "Working Tree", "Not committed yet" } or nil
		picker.title = state.working and "Working Tree Changes" or "Loading commit info…"
		picker.preview.item = nil
		picker.preview:reset()
		picker.input:set("", "")
		picker.list:set_selected()
		picker.list:clear()
		local function refresh(message)
			picker:find({
				on_done = function()
					if not valid() then
						return
					end
					picker.list:view(1)
					if picker.list:count() > 0 then
						focus_picker_file(picker, source_file, state.cwd, nil, valid)
						picker:show_preview()
					else
						picker.preview:reset()
						picker.preview:set_title(commit_preview_title(state))
						picker.preview:set_lines(vim.split(message or "No changed files", "\n", { plain = true }))
						picker:update_titles()
					end
				end,
			})
		end
		refresh(state.loading and "Loading changed files…" or nil)
		load_info(picker)
		if state.working then
			return
		end
		files_cancel = load_commit_files(state.sha, state.cwd, function(items, root, err, truncated)
			if not valid() then
				return
			end
			files_cancel = nil
			state.loading, state.root, state.items = false, root, items or {}
			if truncated then
				vim.notify("Git annotate: changed file list truncated at 2 MiB", vim.log.levels.WARN)
			end
			refresh(err and "Git annotate: " .. err or nil)
		end)
	end

	local function show_info(picker)
		if info_float and info_float:win_valid() then
			info_float:focus()
			return
		end
		local origin = vim.api.nvim_get_current_win()
		info_float = Snacks.win({
			text = info_lines or { "Loading commit info…" },
			enter = true,
			width = 0.75,
			height = 0.6,
			border = "rounded",
			title = " Commit Info ",
			zindex = picker.layout.root.opts.zindex + 10,
			bo = { filetype = "git", modifiable = false, bufhidden = "wipe" },
			wo = { wrap = true },
			keys = { q = "close", ["<Esc>"] = "close", K = "close" },
			on_close = function()
				if not picker.closed and vim.api.nvim_win_is_valid(origin) then
					vim.api.nvim_set_current_win(origin)
				end
			end,
		})
	end

	local preview_origin, preview_origin_mode = "list", "n"
	local function toggle_diff_focus(picker)
		local current = picker:current_win()
		if current ~= "preview" then
			preview_origin = current == "input" and "input" or "list"
			preview_origin_mode = vim.fn.mode():sub(1, 1)
			vim.cmd.stopinsert()
			picker:focus("preview", { show = true })
			return
		end
		local origin, mode = preview_origin, preview_origin_mode
		picker:focus(origin, { show = true })
		vim.schedule(function()
			if picker.closed or picker:current_win() ~= origin then
				return
			end
			if origin == "input" and mode == "i" then
				vim.cmd.startinsert({ bang = true })
			else
				vim.cmd.stopinsert()
			end
		end)
	end

	local function keys()
		return {
			["<C-o>"] = {
				"git_annotate_toggle_diff",
				mode = { "i", "n" },
				desc = "Toggle files/input and diff preview",
			},
			["h"] = { "git_annotate_older", mode = "n", desc = "Show older commit" },
			["l"] = { "git_annotate_newer", mode = "n", desc = "Show newer commit" },
			["K"] = { "git_annotate_info", mode = "n", desc = "Show complete commit info" },
			["O"] = { "git_annotate_browse", mode = "n", desc = "Open commit in browser" },
		}
	end

	return {
		title = state.working and "Working Tree Changes" or "Loading commit info…",
		cwd = state.cwd,
		focus = "list",
		format = "file",
		show_empty = true,
		finder = function(opts, ctx)
			if state.working then
				return require("snacks.picker.source.git").status(opts, ctx)
			end
			return state.items or {}
		end,
		layout = function()
			local wide = vim.o.columns >= 100
			return {
				preview = true,
				layout = {
					box = wide and "horizontal" or "vertical",
					width = 0.9,
					height = 0.85,
					{
						box = "vertical",
						{
							box = "vertical",
							border = "rounded",
							title = "{title}",
							{ win = "input", height = 1, border = "bottom" },
							{ win = "list", border = "none" },
						},
						history:layout(wide and 0.45 or 0.5),
					},
					{
						win = "preview",
						title = "{preview}",
						border = "rounded",
						width = wide and 0.6 or nil,
						height = not wide and 0.6 or nil,
					},
				},
			}
		end,
		preview = function(ctx)
			preview_file_change(ctx, state)
		end,
		actions = {
			git_annotate_toggle_diff = toggle_diff_focus,
			git_annotate_older = function()
				history:move(1)
			end,
			git_annotate_newer = function()
				history:move(-1)
			end,
			git_annotate_info = show_info,
			git_annotate_browse = function()
				open_commit_browser(state.working and "" or state.sha, main_win)
			end,
		},
		confirm = "git_annotate_toggle_diff",
		on_show = function(picker)
			active_picker = picker
			local revision = state.revision
			focus_picker_file(picker, source_file, state.cwd, nil, function()
				return state.revision == revision
			end)
			if state.loading then
				switch_commit(picker, { sha = state.sha, working = state.working, subject = state.subject })
			else
				load_info(picker)
			end
			history.closed = false
			history:load()
		end,
		on_close = function()
			state.revision = state.revision + 1
			history:close()
			if files_cancel then
				files_cancel()
				files_cancel = nil
			end
			info_request = info_request + 1
			if info_process then
				pcall(info_process.kill, info_process, 15)
				info_process = nil
			end
			if info_float then
				info_float:close()
				info_float = nil
			end
			vim.schedule(function()
				if vim.api.nvim_win_is_valid(ann_win) then
					vim.api.nvim_set_current_win(ann_win)
				end
			end)
		end,
		win = {
			input = { keys = keys() },
			list = { keys = keys() },
			preview = { keys = keys() },
		},
	}
end

--- 打开 commit/working tree 文件列表与 diff preview
--- @param sha string
--- @param ann_win integer
--- @param main_win integer
--- @param cwd string
local function open_change_picker(sha, ann_win, main_win, cwd)
	if not vim.api.nvim_win_is_valid(ann_win) or not vim.api.nvim_win_is_valid(main_win) then
		vim.notify("Git annotate: annotate or source window closed", vim.log.levels.WARN)
		return
	end

	local ok, snacks = pcall(require, "snacks")
	if not ok or not snacks.picker then
		vim.notify("Git annotate: d requires snacks.nvim", vim.log.levels.WARN)
		return
	end
	local source_buf = vim.api.nvim_win_get_buf(main_win)
	local source_file = vim.api.nvim_buf_get_name(source_buf)
	local working = is_uncommitted(sha)
	local state = { working = working, sha = not working and sha or nil, cwd = cwd }

	if working then
		vim.api.nvim_set_current_win(main_win)
		snacks.picker.pick(change_picker_opts(state, ann_win, main_win, source_file))
		return
	end

	load_commit_files(sha, cwd, function(items, root, err, truncated)
		if not vim.api.nvim_win_is_valid(ann_win) or not vim.api.nvim_win_is_valid(main_win) then
			return
		end
		if vim.api.nvim_win_get_buf(main_win) ~= source_buf then
			return
		end
		if not items then
			vim.notify("Git annotate: " .. (err or "failed to load changed files"), vim.log.levels.ERROR)
			return
		end
		if truncated then
			vim.notify("Git annotate: changed file list truncated at 2 MiB", vim.log.levels.WARN)
		end

		state.root, state.items = root, items
		vim.api.nvim_set_current_win(main_win)
		local opts = change_picker_opts(state, ann_win, main_win, source_file)
		opts.items = items
		snacks.picker.pick(opts)
	end)
end

--- 绑定侧边栏所有快捷键
--- @param ann_buf integer
--- @param ann_win integer
--- @param main_win integer
--- @param annotations table
--- @param cwd string
local function setup_keymaps(ann_buf, ann_win, main_win, annotations, cwd)
	-- 同步跳转两个窗口光标
	local function jump_to(lnum)
		lnum = math.max(1, math.min(#annotations, lnum))
		vim.api.nvim_win_set_cursor(ann_win, { lnum, 0 })
		vim.api.nvim_win_set_cursor(main_win, { lnum, 0 })
	end

	local function cur_sha()
		local lnum = vim.api.nvim_win_get_cursor(ann_win)[1]
		return annotations[lnum] and annotations[lnum].sha
	end

	-- q: 关闭侧边栏
	vim.keymap.set("n", "q", "<cmd>close<CR>", { noremap = true, silent = true, buffer = ann_buf })
	vim.keymap.set("n", "<Esc>", "<cmd>close<CR>", { noremap = true, silent = true, buffer = ann_buf })

	-- ]] / [[：跳转到当前 commit 在文件中的下一个/上一个块边界
	vim.keymap.set("n", "]]", function()
		local lnum = vim.api.nvim_win_get_cursor(ann_win)[1]
		local sha = annotations[lnum] and annotations[lnum].sha
		local i = lnum + 1
		while i <= #annotations and annotations[i].sha == sha do
			i = i + 1
		end
		while i <= #annotations and annotations[i].sha ~= sha do
			i = i + 1
		end
		if i <= #annotations then
			jump_to(i)
		end
	end, { noremap = true, silent = true, buffer = ann_buf, desc = "Next hunk of same commit" })

	vim.keymap.set("n", "[[", function()
		local lnum = vim.api.nvim_win_get_cursor(ann_win)[1]
		local sha = annotations[lnum] and annotations[lnum].sha
		local i = lnum - 1
		while i >= 1 and annotations[i].sha == sha do
			i = i - 1
		end
		while i >= 1 and annotations[i].sha ~= sha do
			i = i - 1
		end
		while i > 1 and annotations[i - 1].sha == sha do
			i = i - 1
		end
		if i >= 1 and annotations[i].sha == sha then
			jump_to(i)
		end
	end, { noremap = true, silent = true, buffer = ann_buf, desc = "Prev hunk of same commit" })

	-- 每个 commit 只保留在文件中首次出现的行，按行号顺序跳转。
	local commit_starts, seen = {}, {}
	for lnum, annotation in ipairs(annotations) do
		if not seen[annotation.sha] then
			seen[annotation.sha] = true
			commit_starts[#commit_starts + 1] = lnum
		end
	end

	-- ]c / [c：在各个 commit 首次出现的行之间跳转
	vim.keymap.set("n", "]c", function()
		local lnum = vim.api.nvim_win_get_cursor(ann_win)[1]
		for _, start in ipairs(commit_starts) do
			if start > lnum then
				jump_to(start)
				return
			end
		end
	end, { noremap = true, silent = true, buffer = ann_buf, desc = "Next unique commit start" })

	vim.keymap.set("n", "[c", function()
		local lnum = vim.api.nvim_win_get_cursor(ann_win)[1]
		for i = #commit_starts, 1, -1 do
			if commit_starts[i] < lnum then
				jump_to(commit_starts[i])
				return
			end
		end
	end, { noremap = true, silent = true, buffer = ann_buf, desc = "Prev unique commit start" })

	-- K: 浮动窗口展示简要 commit 信息
	vim.keymap.set("n", "K", function()
		show_commit_float(cur_sha(), ann_win, ann_buf, cwd)
	end, { noremap = true, silent = true, buffer = ann_buf, desc = "Show commit info (float)" })

	vim.keymap.set("n", "O", function()
		open_commit_browser(cur_sha(), main_win)
	end, { noremap = true, silent = true, buffer = ann_buf, desc = "Open commit in browser" })

	-- d: 用 Snacks picker 展示变更文件列表与 diff
	vim.keymap.set("n", "d", function()
		open_change_picker(cur_sha(), ann_win, main_win, cwd)
	end, { noremap = true, silent = true, buffer = ann_buf, desc = "Show commit diff (picker)" })
end

--- 创建侧边栏并设置所有交互逻辑（从异步回调中调用）
--- @param annotations {text: string, author_time: integer, sha: string, uncommitted: boolean}[]
--- @param bufnr integer 主 buffer
--- @param main_win integer 主窗口
--- @param top integer 主窗口顶部行号
--- @param current_line integer 主窗口光标行号
--- @param cwd string 仓库根目录
function M._open_sidebar(annotations, bufnr, main_win, top, current_line, cwd)
	-- 在左侧创建侧边栏
	vim.cmd.vsplit({ mods = { keepalt = true, split = "aboveleft" } })
	local ann_win = vim.api.nvim_get_current_win()
	local ann_buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_win_set_buf(ann_win, ann_buf)

	-- 填充内容
	local lines = vim.tbl_map(function(a)
		return a.text
	end, annotations)
	vim.api.nvim_buf_set_lines(ann_buf, 0, -1, false, lines)

	-- 自动宽度：取最长行宽，+1 留右边距
	local max_width = 0
	for _, l in ipairs(lines) do
		max_width = math.max(max_width, vim.fn.strdisplaywidth(l))
	end
	vim.api.nvim_win_set_width(ann_win, max_width + 1)

	apply_highlights(annotations, ann_buf)

	-- buffer 属性
	local bo = vim.bo[ann_buf]
	bo.buftype = "nofile"
	bo.bufhidden = "wipe"
	bo.modifiable = false
	bo.filetype = "gitannotate"

	-- 窗口属性
	local wlo = vim.wo[ann_win][0]
	local original_options = {}
	for _, name in ipairs({
		"number",
		"relativenumber",
		"signcolumn",
		"foldcolumn",
		"foldenable",
		"wrap",
		"list",
		"spell",
		"statuscolumn",
		"winfixwidth",
		"scrollbind",
	}) do
		original_options[name] = wlo[name]
	end
	wlo.number = false
	wlo.relativenumber = false
	wlo.signcolumn = "no"
	wlo.foldcolumn = "0"
	wlo.foldenable = false
	wlo.wrap = false
	wlo.list = false
	wlo.spell = false
	wlo.statuscolumn = ""
	wlo.winfixwidth = true
	wlo.scrollbind = true

	-- 对齐滚动位置
	vim.cmd(tostring(top))
	vim.cmd("normal! zt")
	vim.cmd(tostring(current_line))
	vim.cmd("normal! 0")

	-- 主窗口也开启 scrollbind
	local main_wlo = vim.wo[main_win][0]
	local orig_scrollbind = main_wlo.scrollbind
	local orig_wrap = main_wlo.wrap
	local orig_foldenable = main_wlo.foldenable
	main_wlo.scrollbind = true
	main_wlo.wrap = false
	main_wlo.foldenable = false

	vim.cmd.redraw()
	vim.cmd.syncbind()

	setup_keymaps(ann_buf, ann_win, main_win, annotations, cwd)

	local group = vim.api.nvim_create_augroup("GitAnnotateSync" .. ann_win, { clear = true })
	local cleaned = false
	local function cleanup()
		if cleaned then
			return
		end
		cleaned = true
		vim.api.nvim_del_augroup_by_id(group)
		if hover_requests[ann_buf] then
			hover_requests[ann_buf].close()
		end
		if vim.api.nvim_win_is_valid(main_win) then
			main_wlo.scrollbind = orig_scrollbind
			main_wlo.wrap = orig_wrap
			main_wlo.foldenable = orig_foldenable
		end
	end
	local function close_sidebar()
		cleanup()
		if vim.api.nvim_win_is_valid(ann_win) then
			local normal_windows = 0
			for _, win in ipairs(vim.api.nvim_list_wins()) do
				if vim.api.nvim_win_get_config(win).relative == "" then
					normal_windows = normal_windows + 1
				end
			end
			if normal_windows == 1 then
				-- Neovim must retain one normal window after the source closes.
				vim.api.nvim_win_set_buf(ann_win, vim.api.nvim_create_buf(true, false))
				for name, value in pairs(original_options) do
					wlo[name] = value
				end
			else
				vim.api.nvim_win_close(ann_win, true)
			end
		end
	end

	vim.api.nvim_create_autocmd({ "BufEnter", "BufWinEnter" }, {
		group = group,
		callback = function()
			if vim.api.nvim_win_is_valid(main_win) and vim.api.nvim_win_get_buf(main_win) ~= bufnr then
				close_sidebar()
			end
		end,
	})
	vim.api.nvim_create_autocmd("WinClosed", {
		pattern = tostring(main_win),
		group = group,
		callback = function()
			cleanup()
			-- Wait until the source has actually been removed before counting windows.
			vim.schedule(close_sidebar)
		end,
	})
	vim.api.nvim_create_autocmd("WinClosed", {
		pattern = tostring(ann_win),
		group = group,
		callback = cleanup,
	})

	-- 打开后默认聚焦侧边栏，便于直接使用 annotate 快捷键
	vim.api.nvim_set_current_win(ann_win)
end

--- 打开/关闭 Git annotate 侧边栏
function M.annotate()
	-- A second toggle cancels loading, including callbacks already queued.
	if pending_request then
		local request = pending_request
		pending_request = nil
		if request.process then
			pcall(request.process.kill, request.process, 15)
		end
		return
	end
	for _, w in ipairs(vim.api.nvim_list_wins()) do
		local b = vim.api.nvim_win_get_buf(w)
		if vim.bo[b].filetype == "gitannotate" then
			vim.api.nvim_win_close(w, true)
			return
		end
	end

	local bufnr = vim.api.nvim_get_current_buf()
	local filename = vim.api.nvim_buf_get_name(bufnr)
	if filename == "" then
		vim.notify("Git annotate: No file associated with current buffer", vim.log.levels.WARN)
		return
	end
	local main_win = vim.api.nvim_get_current_win()
	local changedtick = vim.api.nvim_buf_get_changedtick(bufnr)
	local request = {}
	pending_request = request
	local function request_is_valid()
		return pending_request == request
			and vim.api.nvim_win_is_valid(main_win)
			and vim.api.nvim_buf_is_valid(bufnr)
			and vim.api.nvim_win_get_buf(main_win) == bufnr
			and vim.api.nvim_buf_get_name(bufnr) == filename
			and vim.api.nvim_buf_get_changedtick(bufnr) == changedtick
			and vim.api.nvim_get_current_win() == main_win
	end
	local function finish()
		if pending_request == request then
			pending_request = nil
		end
	end

	vim.notify("Git annotate: loading…", vim.log.levels.INFO)
	request.process = vim.system(
		{ "git", "rev-parse", "--show-toplevel" },
		{
			text = true,
			cwd = vim.fn.fnamemodify(filename, ":h"),
		},
		vim.schedule_wrap(function(root_result)
			if not request_is_valid() then
				finish()
				return
			end
			if root_result.code ~= 0 then
				finish()
				vim.notify(
					"Git annotate: " .. (root_result.stderr or "failed to find repository"),
					vim.log.levels.ERROR
				)
				return
			end
			local cwd = root_result.stdout:gsub("\n$", "")
			request.process = vim.system(
				{ "git", "blame", "--line-porcelain", "--", filename },
				{
					text = true,
					cwd = cwd,
				},
				vim.schedule_wrap(function(result)
					if not request_is_valid() then
						finish()
						return
					end
					finish()
					if result.code ~= 0 then
						vim.notify("Git annotate: git blame failed\n" .. (result.stderr or ""), vim.log.levels.ERROR)
						return
					end
					local annotations = parse_blame(vim.split(result.stdout, "\n", { plain = true }))
					if #annotations == 0 then
						vim.notify("Git annotate: no blame data", vim.log.levels.WARN)
						return
					end
					local top = vim.fn.line("w0") + vim.wo.scrolloff
					local current_line = math.min(vim.fn.line("."), #annotations)
					M._open_sidebar(annotations, bufnr, main_win, top, current_line, cwd)
				end)
			)
		end)
	)
end

return M
