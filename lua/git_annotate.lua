local M = {}

local MAX_DIFF_PREVIEW_BYTES = 2 * 1024 * 1024
local preview_ns = vim.api.nvim_create_namespace("git_annotate_preview")

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

--- 判断 commit 是否为根提交
--- @param sha string
--- @param callback fun(root: boolean?, err: string?)
--- @param cwd? string
local function is_root_commit(sha, callback, cwd)
	vim.system(
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

--- 生成带大提交保护的 diff 命令
--- @param sha string
--- @param root boolean
--- @return string[]
local function diff_command(sha, root)
	if is_uncommitted(sha) then
		return { "git", "--no-pager", "diff", "HEAD" }
	end
	if root then
		return { "git", "--no-pager", "show", "--no-patch", "--format=fuller", sha }
	end
	return { "git", "--no-pager", "show", "--format=fuller", sha }
end

--- 有界收集命令输出，超过上限后终止子进程
--- @param command string[]
--- @param callback fun(result: {code: integer, signal: integer, stdout: string, stderr: string, truncated: boolean})
--- @param cwd? string
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

	process = vim.system(command, {
		text = true,
		cwd = cwd,
		stdout = collect_stdout,
		stderr = collect_stderr,
	}, vim.schedule_wrap(function(result)
		callback({
			code = result.code,
			signal = result.signal,
			stdout = table.concat(stdout_chunks),
			stderr = table.concat(stderr_chunks),
			truncated = truncated,
		})
	end))

	if kill_pending then
		pcall(process.kill, process, 15)
	end
end

--- 解析 diff 命令输出并添加保护提示
--- @param output string
--- @param root boolean
--- @param truncated boolean
--- @return string[]
local function diff_lines(output, root, truncated)
	local lines = vim.split(output, "\n", { plain = true })
	if #lines > 0 and lines[#lines] == "" then
		table.remove(lines)
	end
	if root then
		table.insert(lines, 1, "")
		table.insert(lines, 1, "[Git annotate: root commit diff omitted to avoid loading the entire repository.]")
	end
	if truncated then
		table.insert(lines, "")
		table.insert(lines, "[Git annotate: diff preview truncated at 2 MiB.]")
	end
	return lines
end

--- 解析 commit 对应的受保护 diff 命令
--- @param sha string
--- @param callback fun(command: string[]?, root: boolean?, err: string?)
--- @param cwd? string
local function resolve_diff_command(sha, callback, cwd)
	if is_uncommitted(sha) then
		callback(diff_command(sha, false), false)
		return
	end

	is_root_commit(sha, function(root, err)
		if root == nil then
			callback(nil, nil, err)
			return
		end
		callback(diff_command(sha, root), root)
	end, cwd)
end

--- 在主窗口右侧打开或复用 diff buffer
--- @param lines string[]
--- @param buf_name string
--- @param main_win integer
local function open_buffer_vsplit(lines, buf_name, main_win)
	if not vim.api.nvim_win_is_valid(main_win) then
		vim.notify("Git annotate: source window closed", vim.log.levels.WARN)
		return
	end

	local commit_buf
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_get_name(buf) == buf_name then
			commit_buf = buf
			break
		end
	end

	if not commit_buf then
		commit_buf = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_buf_set_name(commit_buf, buf_name)
	end

	local cbo = vim.bo[commit_buf]
	cbo.modifiable = true
	vim.api.nvim_buf_set_lines(commit_buf, 0, -1, false, lines)
	cbo.modifiable = false
	cbo.buftype = "nofile"
	cbo.bufhidden = "wipe"
	cbo.filetype = "git"

	vim.api.nvim_set_current_win(main_win)
	vim.cmd.vsplit({ mods = { keepalt = true } })
	vim.api.nvim_win_set_buf(0, commit_buf)
end

--- 在 vsplit 中异步打开受保护的 git show / git diff 内容
--- @param sha string
--- @param main_win integer
--- @param cwd? string
local function open_diff_vsplit(sha, main_win, cwd)
	if not vim.api.nvim_win_is_valid(main_win) then
		vim.notify("Git annotate: source window closed", vim.log.levels.WARN)
		return
	end

	resolve_diff_command(sha, function(command, root, err)
		if not command then
			vim.notify("Git annotate: " .. (err or "failed to build diff command"), vim.log.levels.ERROR)
			return
		end
		if not vim.api.nvim_win_is_valid(main_win) then
			vim.notify("Git annotate: source window closed", vim.log.levels.WARN)
			return
		end

		collect_bounded(command, function(result)
			if result.code ~= 0 and not result.truncated then
				local message = result.stderr ~= "" and result.stderr or "git diff failed"
				vim.notify("Git annotate: " .. message, vim.log.levels.ERROR)
				return
			end

			local buf_name = is_uncommitted(sha) and "git-annotate://diff (working tree)"
				or "git-annotate://show/" .. sha:sub(1, 8)
			open_buffer_vsplit(diff_lines(result.stdout, root == true, result.truncated), buf_name, main_win)
		end, cwd)
	end, cwd)
end

--- 在浮动窗口中展示简要 commit 信息
--- @param sha string
--- @param ann_win integer
--- @param ann_buf integer
local function show_commit_float(sha, ann_win, ann_buf)
	local lines
	if is_uncommitted(sha) then
		lines = { "Not committed yet" }
	else
		lines = vim.fn.systemlist({
			"git",
			"show",
			"--no-patch",
			"--format=commit %h%nauthor:  %an <%ae>%ndate:    %ad%n%n%s%n%b",
			"--date=format:%Y-%m-%d %H:%M",
			sha,
		})
		if vim.v.shell_error ~= 0 then
			vim.notify("Git annotate: " .. table.concat(lines, "\n"), vim.log.levels.ERROR)
			return
		end
		-- 去掉末尾空行
		while #lines > 0 and lines[#lines] == "" do
			table.remove(lines)
		end
	end

	local width = 0
	for _, l in ipairs(lines) do
		width = math.max(width, vim.fn.strdisplaywidth(l))
	end
	width = math.min(math.max(width, 20), math.floor(vim.o.columns * 0.7))

	local float_buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(float_buf, 0, -1, false, lines)
	vim.bo[float_buf].filetype = "git"
	vim.bo[float_buf].modifiable = false

	local cursor_row = vim.api.nvim_win_get_cursor(ann_win)[1] - vim.fn.line("w0", ann_win)
	local win_row = vim.api.nvim_win_get_position(ann_win)[1]
	local below_space = vim.o.lines - (win_row + cursor_row) - 3
	local height = math.min(#lines, math.max(3, below_space))
	local row = (below_space >= #lines) and (cursor_row + 1) or (cursor_row - #lines - 1)

	local float_win = vim.api.nvim_open_win(float_buf, false, {
		relative = "win",
		win = ann_win,
		row = row,
		col = 0,
		width = width,
		height = height,
		style = "minimal",
		border = "rounded",
		zindex = 50,
	})
	vim.wo[float_win].wrap = false

	-- 任意移动光标后自动关闭
	vim.api.nvim_create_autocmd({ "CursorMoved", "BufLeave", "WinLeave" }, {
		buffer = ann_buf,
		once = true,
		callback = function()
			if vim.api.nvim_win_is_valid(float_win) then
				vim.api.nvim_win_close(float_win, true)
			end
		end,
	})
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

--- 为 Snacks picker 异步预览选中文件，并限制最大输出
--- @param ctx snacks.picker.preview.ctx
--- @param state {working: boolean, sha?: string, root?: boolean, cwd: string}
local function preview_file_change(ctx, state)
	if not ctx.item.file then
		ctx.preview:notify("file is missing", "error", { item = false })
		return
	end

	local title = (state.working and "Working Tree · " or "Commit " .. state.sha:sub(1, 8) .. " · ")
		.. ctx.item.file
	ctx.preview:reset()
	ctx.preview:set_title(title)
	ctx.preview:set_lines({ "Loading diff…" })

	local function preview_is_valid()
		return ctx.preview.item == ctx.item and ctx.preview.win:buf_valid()
	end

	local function show_error(message)
		if not preview_is_valid() then
			return
		end
		ctx.preview:reset()
		ctx.preview:set_title(title)
		ctx.preview:set_lines({ "Git annotate: " .. message })
	end

	local command, allow_exit_one = file_diff_command(state, ctx.item)
	collect_bounded(command, function(result)
		if not preview_is_valid() then
			return
		end
		if not diff_succeeded(result, allow_exit_one) then
			show_error(result.stderr ~= "" and result.stderr or "git diff failed")
			return
		end

		render_commit_preview(ctx, diff_lines(result.stdout, false, result.truncated))
		ctx.preview:set_title(title .. (result.truncated and " [truncated]" or ""))
	end, state.cwd)
end

--- 在 vsplit 中打开选中文件的 diff
--- @param state {working: boolean, sha?: string, root?: boolean, cwd: string}
--- @param item table
--- @param main_win integer
local function open_file_diff_vsplit(state, item, main_win)
	if not item or not item.file then
		return
	end
	local command, allow_exit_one = file_diff_command(state, item)
	collect_bounded(command, function(result)
		if not diff_succeeded(result, allow_exit_one) then
			local message = result.stderr ~= "" and result.stderr or "git diff failed"
			vim.notify("Git annotate: " .. message, vim.log.levels.ERROR)
			return
		end

		local prefix = state.working and "git-annotate://diff (working tree)/"
			or "git-annotate://show/" .. state.sha:sub(1, 8) .. "/"
		open_buffer_vsplit(diff_lines(result.stdout, false, result.truncated), prefix .. item.file, main_win)
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
	is_root_commit(sha, function(root, err)
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

		collect_bounded(command, function(result)
			if result.code ~= 0 and not result.truncated then
				callback(nil, root, result.stderr ~= "" and result.stderr or "git diff failed")
				return
			end
			callback(parse_changed_files(result.stdout, cwd), root, nil, result.truncated)
		end, cwd)
	end, cwd)
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
local function focus_picker_file(picker, source_file, fallback_cwd, attempt)
	if picker.closed then
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
			focus_picker_file(picker, source_file, fallback_cwd, attempt + 1)
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
	local opening_vsplit = false

	local function open_selected(picker)
		local item = picker:current()
		if not item then
			return
		end
		opening_vsplit = true
		picker:close()
		open_file_diff_vsplit(state, item, main_win)
	end

	local function open_whole(picker)
		opening_vsplit = true
		picker:close()
		open_diff_vsplit(state.working and "" or state.sha, main_win, state.cwd)
	end

	local function keys()
		return {
			["s"] = {
				"git_annotate_open_selected",
				mode = "n",
				desc = "Open selected file diff in vsplit",
			},
			["S"] = { "git_annotate_open_whole", mode = "n", desc = "Open complete diff in vsplit" },
		}
	end

	return {
		title = state.working and "Working Tree Changes" or "Commit " .. state.sha:sub(1, 8) .. " Changes",
		cwd = state.cwd,
		focus = "list",
		format = "file",
		preview = function(ctx)
			preview_file_change(ctx, state)
		end,
		actions = {
			git_annotate_open_selected = open_selected,
			git_annotate_open_whole = open_whole,
		},
		confirm = "git_annotate_open_selected",
		on_show = function(picker)
			focus_picker_file(picker, source_file, state.cwd)
		end,
		on_close = function()
			if opening_vsplit then
				return
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
local function open_change_picker(sha, ann_win, main_win)
	if not vim.api.nvim_win_is_valid(ann_win) or not vim.api.nvim_win_is_valid(main_win) then
		vim.notify("Git annotate: annotate or source window closed", vim.log.levels.WARN)
		return
	end

	local source_file = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(main_win))
	local start_dir = vim.fn.fnamemodify(source_file, ":h")
	local cwd = Snacks.git.get_root(start_dir) or vim.fn.getcwd()
	local working = is_uncommitted(sha)
	local state = { working = working, sha = working and nil or sha, cwd = cwd }

	if working then
		vim.api.nvim_set_current_win(main_win)
		Snacks.picker.git_status(change_picker_opts(state, ann_win, main_win, source_file))
		return
	end

	load_commit_files(sha, cwd, function(items, root, err, truncated)
		if not vim.api.nvim_win_is_valid(ann_win) or not vim.api.nvim_win_is_valid(main_win) then
			return
		end
		if not items then
			vim.notify("Git annotate: " .. (err or "failed to load changed files"), vim.log.levels.ERROR)
			return
		end
		if #items == 0 then
			vim.notify("Git annotate: commit has no changed files", vim.log.levels.WARN)
			return
		end
		if truncated then
			vim.notify("Git annotate: changed file list truncated at 2 MiB", vim.log.levels.WARN)
		end

		state.root = root
		vim.api.nvim_set_current_win(main_win)
		local opts = change_picker_opts(state, ann_win, main_win, source_file)
		opts.items = items
		Snacks.picker.pick(opts)
	end)
end

--- 绑定侧边栏所有快捷键
--- @param ann_buf integer
--- @param ann_win integer
--- @param main_win integer
--- @param annotations table
local function setup_keymaps(ann_buf, ann_win, main_win, annotations)
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

	-- ]c / [c：跳转到下一个/上一个不同 commit 块的起始行
	vim.keymap.set("n", "]c", function()
		local lnum = vim.api.nvim_win_get_cursor(ann_win)[1]
		local sha = annotations[lnum] and annotations[lnum].sha
		local i = lnum + 1
		while i <= #annotations and annotations[i].sha == sha do
			i = i + 1
		end
		if i <= #annotations then
			jump_to(i)
		end
	end, { noremap = true, silent = true, buffer = ann_buf, desc = "Next commit block" })

	vim.keymap.set("n", "[c", function()
		local lnum = vim.api.nvim_win_get_cursor(ann_win)[1]
		local sha = annotations[lnum] and annotations[lnum].sha
		local i = lnum - 1
		while i >= 1 and annotations[i].sha == sha do
			i = i - 1
		end
		local prev_sha = i >= 1 and annotations[i].sha or nil
		while i > 1 and annotations[i - 1].sha == prev_sha do
			i = i - 1
		end
		if i >= 1 and prev_sha then
			jump_to(i)
		end
	end, { noremap = true, silent = true, buffer = ann_buf, desc = "Prev commit block" })

	-- K: 浮动窗口展示简要 commit 信息
	vim.keymap.set("n", "K", function()
		show_commit_float(cur_sha(), ann_win, ann_buf)
	end, { noremap = true, silent = true, buffer = ann_buf, desc = "Show commit info (float)" })

	-- s: 在 vsplit 中直接展示 git show 内容
	vim.keymap.set("n", "s", function()
		open_diff_vsplit(cur_sha(), main_win)
	end, { noremap = true, silent = true, buffer = ann_buf, desc = "Show commit diff (vsplit)" })

	-- d: 用 Snacks picker 展示变更文件列表与 diff
	vim.keymap.set("n", "d", function()
		open_change_picker(cur_sha(), ann_win, main_win)
	end, { noremap = true, silent = true, buffer = ann_buf, desc = "Show commit diff (picker)" })
end

--- 创建侧边栏并设置所有交互逻辑（从异步回调中调用）
--- @param annotations {text: string, author_time: integer, sha: string, uncommitted: boolean}[]
--- @param bufnr integer 主 buffer
--- @param main_win integer 主窗口
--- @param top integer 主窗口顶部行号
--- @param current_line integer 主窗口光标行号
function M._open_sidebar(annotations, bufnr, main_win, top, current_line)

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
	main_wlo.scrollbind = true
	main_wlo.wrap = false

	vim.cmd.redraw()
	vim.cmd.syncbind()

	setup_keymaps(ann_buf, ann_win, main_win, annotations)

	local group = vim.api.nvim_create_augroup("GitAnnotateSync", { clear = true })

	-- 主 buffer 关闭时同步关闭侧边栏
	vim.api.nvim_create_autocmd({ "BufHidden", "QuitPre" }, {
		buffer = bufnr,
		group = group,
		once = true,
		callback = function()
			if vim.api.nvim_win_is_valid(ann_win) then
				vim.api.nvim_win_close(ann_win, true)
			end
		end,
	})

	-- 侧边栏关闭时恢复主窗口选项
	vim.api.nvim_create_autocmd("WinClosed", {
		pattern = tostring(ann_win),
		group = group,
		callback = function()
			if vim.api.nvim_win_is_valid(main_win) then
				main_wlo.scrollbind = orig_scrollbind
				main_wlo.wrap = orig_wrap
			end
		end,
	})

	-- 打开后默认聚焦侧边栏，便于直接使用 annotate 快捷键
	vim.api.nvim_set_current_win(ann_win)
end

--- 打开/关闭 Git annotate 侧边栏
function M.annotate()
	-- 关闭已有的 annotate 侧边栏（toggle）
	for _, w in ipairs(vim.api.nvim_list_wins()) do
		local b = vim.api.nvim_win_get_buf(w)
		if vim.api.nvim_get_option_value("filetype", { buf = b }) == "gitannotate" then
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

	-- 记录主窗口状态（异步回调前快照，避免用户切换窗口后状态错乱）
	local main_win = vim.api.nvim_get_current_win()
	local top = vim.fn.line("w0") + vim.wo.scrolloff
	local current_line = vim.fn.line(".")

	vim.notify("Git annotate: loading…", vim.log.levels.INFO)

	-- 异步执行 git blame，避免大文件时阻塞 Neovim 事件循环
	vim.system(
		{ "git", "blame", "--line-porcelain", filename },
		{ text = true },
		vim.schedule_wrap(function(result)
			if result.code ~= 0 then
				vim.notify(
					"Git annotate: git blame failed\n" .. (result.stderr or ""),
					vim.log.levels.ERROR
				)
				return
			end

			local blame_output = vim.split(result.stdout, "\n", { plain = true })
			local annotations = parse_blame(blame_output)
			if #annotations == 0 then
				vim.notify("Git annotate: no blame data", vim.log.levels.WARN)
				return
			end

			-- 确认主窗口仍有效（异步期间用户可能已关闭）
			if not vim.api.nvim_win_is_valid(main_win) then
				vim.notify("Git annotate: source window closed", vim.log.levels.WARN)
				return
			end
			vim.api.nvim_set_current_win(main_win)

			M._open_sidebar(annotations, bufnr, main_win, top, current_line)
		end)
	)
end

return M
