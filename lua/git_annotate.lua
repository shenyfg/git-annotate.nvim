local M = {}

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

--- 在 vsplit 中打开 git show / git diff 内容
--- @param sha string
--- @param main_win integer
local function open_diff_vsplit(sha, main_win)
	local output, buf_name
	if is_uncommitted(sha) then
		output = vim.fn.systemlist({ "git", "diff" })
		buf_name = "git-annotate://diff (working tree)"
	else
		output = vim.fn.systemlist({ "git", "show", "--format=fuller", sha })
		buf_name = "git-annotate://show/" .. sha:sub(1, 8)
	end
	if vim.v.shell_error ~= 0 then
		vim.notify("Git annotate: " .. table.concat(output, "\n"), vim.log.levels.ERROR)
		return
	end

	-- 复用同名 buffer（避免重复打开同一 commit）
	local commit_buf = nil
	for _, b in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_get_name(b) == buf_name then
			commit_buf = b
			break
		end
	end
	if not commit_buf then
		commit_buf = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_buf_set_name(commit_buf, buf_name)
		vim.api.nvim_buf_set_lines(commit_buf, 0, -1, false, output)
		local cbo = vim.bo[commit_buf]
		cbo.modifiable = false
		cbo.buftype = "nofile"
		cbo.bufhidden = "wipe"
		cbo.filetype = "git"
	end

	-- 在主窗口右侧打开 vsplit
	vim.api.nvim_set_current_win(main_win)
	vim.cmd.vsplit({ mods = { keepalt = true } })
	vim.api.nvim_win_set_buf(0, commit_buf)
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

	-- ]c / [c：跳转到当前 commit 在文件中的下一个/上一个块边界
	vim.keymap.set("n", "]c", function()
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

	vim.keymap.set("n", "[c", function()
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

	-- ]] / [[：跳转到下一个/上一个不同 commit 块的起始行
	vim.keymap.set("n", "]]", function()
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

	vim.keymap.set("n", "[[", function()
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

	-- d: 用 Snacks picker 展示 diff（可搜索/跳转）
	vim.keymap.set("n", "d", function()
		local sha = cur_sha()
		vim.api.nvim_set_current_win(main_win)

		local function picker_opts(sha_for_vsplit)
			return {
				on_show = function(picker)
					picker.input:stopinsert()
					vim.api.nvim_input("<Esc>")
				end,
				win = {
					input = {
						keys = {
							["s"] = {
								function(picker)
									picker:close()
									open_diff_vsplit(sha_for_vsplit, main_win)
								end,
								mode = "n",
								desc = "Open diff in vsplit",
							},
						},
					},
				},
			}
		end

		if is_uncommitted(sha) then
			Snacks.picker.git_diff(picker_opts(sha))
		else
			Snacks.picker.git_log(vim.tbl_deep_extend("force", picker_opts(sha), {
				cmd_args = { sha, "-n", "1" },
				title = "Commit " .. sha:sub(1, 8),
			}))
		end
	end, { noremap = true, silent = true, buffer = ann_buf, desc = "Show commit diff (picker)" })
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

	-- 执行 git blame
	local blame_output = vim.fn.systemlist({ "git", "blame", "--line-porcelain", filename })
	if vim.v.shell_error ~= 0 then
		vim.notify("Git annotate: git blame failed\n" .. table.concat(blame_output, "\n"), vim.log.levels.ERROR)
		return
	end

	local annotations = parse_blame(blame_output)
	if #annotations == 0 then
		vim.notify("Git annotate: no blame data", vim.log.levels.WARN)
		return
	end

	-- 记录主窗口，用于 scrollbind 对齐
	local main_win = vim.api.nvim_get_current_win()
	local top = vim.fn.line("w0") + vim.wo.scrolloff
	local current_line = vim.fn.line(".")

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

	-- 焦点回到主窗口
	vim.api.nvim_set_current_win(main_win)
end

return M
