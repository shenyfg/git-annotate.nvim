local M = {}

--- Opens a Git blame sidebar showing commit information for each line
--- Toggles the sidebar if it's already open
function M.annotate()
  -- Clean up previous sync autocmds (for toggle functionality)
  pcall(vim.api.nvim_del_augroup_by_name, "GitAnnotateSync")

  -- Toggle: Close existing annotate sidebar if found
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    local buf = vim.api.nvim_win_get_buf(w)
    if vim.api.nvim_buf_get_option(buf, "filetype") == "gitannotate" then
      pcall(vim.api.nvim_del_augroup_by_name, "GitAnnotateSync")
      vim.api.nvim_win_close(w, true)
      return
    end
  end

  -- Get current file path
  local bufnr = vim.api.nvim_get_current_buf()
  local filename = vim.api.nvim_buf_get_name(bufnr)
  if filename == "" then
    print("Git annotate: No file associated with current buffer")
    return
  end

  -- Execute git blame with line-porcelain format for detailed info
  local blame = vim.fn.systemlist({ "git", "blame", "--line-porcelain", filename })
  if vim.v.shell_error ~= 0 then
    print("Git annotate: git blame failed\n" .. table.concat(blame, "\n"))
    return
  end

  -- Parse git blame output to extract author and timestamp info
  local annotations = {}
  local times = {} -- Store timestamps for color gradient calculation
  local author, author_time, author_mail

  for _, line in ipairs(blame) do
    -- Extract author name
    local a = line:match("^author (.+)")
    if a then
      author = a
    end

    -- Extract commit timestamp
    local t = line:match("^author%-time (%d+)")
    if t then
      author_time = tonumber(t)
    end

    -- Note: author-mail parsing is commented out but preserved
    -- local am = line:match("^author%-mail <(.+)>")
    -- if am then
    --   author_mail = am
    -- end

    -- Build annotation line when we have required info
    if author and author_time and author_mail then
      local date = os.date("%y/%m/%d", author_time)
      table.insert(annotations, string.format("%s %s <%s>", date, author, author_mail))
      table.insert(times, author_time)
    elseif author and author_time then
      local date = os.date("%y/%m/%d", author_time)
      table.insert(annotations, string.format("%s %s", date, author))
      table.insert(times, author_time)
    else
      goto continue
    end

    -- Reset variables for next line
    author = nil
    author_time = nil
    author_mail = nil
    ::continue::
  end

  -- Store main window ID for scroll synchronization
  local main_win = vim.api.nvim_get_current_win()

  -- Create left sidebar split
  vim.cmd("topleft vsplit")
  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(win, buf)

  -- Populate buffer with annotation lines
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, annotations)

  -- Setup color gradient based on commit age
  local N = 10 -- Number of gradient levels

  -- Find min/max timestamps (excluding uncommitted lines with time=0)
  local min_t, max_t
  for _, t in ipairs(times) do
    if t > 0 then
      if not min_t or t < min_t then min_t = t end
      if not max_t or t > max_t then max_t = t end
    end
  end
  min_t = min_t or 0
  max_t = max_t or min_t

  -- Create gradient highlight groups (dark blue to bright blue)
  for i = 1, N do
    local ratio = (i - 1) / (N - 1)
    -- Blue gradient: from dark blue #20304f to brighter blue #3050af
    local r = math.floor(0x20 + ratio * (0x30 - 0x20))
    local g = math.floor(0x30 + ratio * (0x50 - 0x30))
    local b = math.floor(0x4f + ratio * (0xaf - 0x4f))
    local hex = string.format("#%02x%02x%02x", r, g, b)
    vim.api.nvim_set_hl(0, "GitAnnotateAge" .. i, { bg = hex })
  end

  -- Apply color highlighting to each line based on commit age
  local ns = vim.api.nvim_create_namespace("git_annotate")
  for idx, t in ipairs(times) do
    if t > 0 then
      -- Calculate relative age (0 = oldest, 1 = newest)
      local r = (max_t == min_t) and 1 or (t - min_t) / (max_t - min_t)
      local bucket = math.floor(r * (N - 1)) + 1
      vim.api.nvim_buf_add_highlight(buf, ns, "GitAnnotateAge" .. bucket, idx - 1, 0, -1)
    end
  end

  -- Configure sidebar buffer properties
  vim.api.nvim_set_option_value("buftype", "nofile", {buf=buf})
  vim.api.nvim_set_option_value("bufhidden", "wipe", {buf=buf})
  vim.api.nvim_set_option_value("modifiable", false, {buf=buf})
  vim.api.nvim_set_option_value("filetype", "gitannotate", {buf=buf})

  -- Set fixed sidebar width (prevents resizing with C-w =)
  vim.api.nvim_win_set_width(win, 30)
  vim.api.nvim_set_option_value("winfixwidth", true, {win = win})

  -- Setup synchronized scrolling between main and sidebar windows
  local function sync_annotate()
    if not (vim.api.nvim_win_is_valid(main_win) and vim.api.nvim_win_is_valid(win)) then
      pcall(vim.api.nvim_del_augroup_by_name, "GitAnnotateSync")
      return
    end

    -- Get main window's top line
    local top_line = vim.api.nvim_win_call(main_win, function()
      return vim.fn.line('w0')
    end)

    -- Sync sidebar's top line to match main window
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_call(win, function()
        vim.fn.winrestview({topline = top_line})
      end)
    end
  end

  -- Create autocmd group for scroll synchronization
  local sync_group = vim.api.nvim_create_augroup("GitAnnotateSync", { clear = true })
  vim.api.nvim_create_autocmd({ "WinScrolled" }, {
    group = sync_group,
    callback = function()
      if vim.api.nvim_get_current_win() == main_win then
        sync_annotate()
      end
    end,
  })

  -- Initial sync after opening
  sync_annotate()

  -- Setup keymaps for closing sidebar
  vim.api.nvim_buf_set_keymap(buf, 'n', 'q', '<cmd>close<CR>', {noremap=true, silent=true})
  vim.api.nvim_buf_set_keymap(buf, 'n', '<Esc>', '<cmd>close<CR>', {noremap=true, silent=true})

  -- Return focus to main window
  vim.api.nvim_set_current_win(main_win)
end

return M
