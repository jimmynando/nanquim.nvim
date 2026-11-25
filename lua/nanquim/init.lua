local M = {}
local ns = vim.api.nvim_create_namespace("nanquim")

local DEBOUNCE_MS = 50
-- Window options while rendering; the user's values are saved and restored
local WIN_OPTS = { conceallevel = 2, concealcursor = "" }

-- buf -> true/false once the user toggles it; nil means "on if markdown"
local enabled = {}
-- buf -> uv timer used to debounce renders
local timers = {}

-- ATX headings ("# ..." to "###### ...") from the block grammar.
-- Fenced code is a separate node type, so "# comment" inside it never matches.
local heading_query = vim.treesitter.query.parse("markdown", "(atx_heading) @heading")

local function is_enabled(buf)
  if enabled[buf] ~= nil then
    return enabled[buf]
  end
  return vim.bo[buf].filetype == "markdown"
end

local function render_heading(buf, node, cursor_row)
  local marker = node:child(0) -- atx_h1_marker .. atx_h6_marker, e.g. "##"
  local content = node:field("heading_content")[1] -- nil for a bare "#"
  local row, marker_col, _, text_col = marker:range()
  if content then
    _, text_col = content:start() -- skip the space after the marker too
  end

  -- Hide "## " and show a marker in its place. Anti-conceal: on the cursor
  -- line Neovim already shows the concealed text, but not our virt_text,
  -- so skip this mark there and the raw "## " shows alone.
  if row ~= cursor_row then
    vim.api.nvim_buf_set_extmark(buf, ns, row, marker_col, {
      end_col = text_col,
      conceal = "",
      virt_text = { { "◆ ", "Title" } },
      virt_text_pos = "inline",
    })
  end

  -- Paint the heading text
  if content then
    local _, _, end_row, end_col = content:range()
    vim.api.nvim_buf_set_extmark(buf, ns, row, text_col, {
      end_row = end_row,
      end_col = end_col,
      hl_group = "Title",
    })
  end
end

-- Rows to render: what the window shows, plus one screen above and below
local function visible_range(win)
  local margin = vim.api.nvim_win_get_height(win)
  local top = vim.fn.line("w0", win) - 1
  local bottom = vim.fn.line("w$", win)
  return math.max(top - margin, 0), bottom + margin
end

-- Render the buffer shown in `win`, only around the visible area
function M.render(win)
  win = win or vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_win_get_buf(win)
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)

  local ok, parser = pcall(vim.treesitter.get_parser, buf, "markdown")
  if not ok or not parser then
    return
  end

  local first, last = visible_range(win)
  local cursor_row = vim.api.nvim_win_get_cursor(win)[1] - 1
  parser:parse({ first, last })

  -- trees() on the root parser = block grammar only. for_each_tree would also
  -- visit markdown injected into ```markdown fences and render headings there.
  for _, tree in ipairs(parser:trees()) do
    for _, node in heading_query:iter_captures(tree:root(), buf, first, last) do
      render_heading(buf, node, cursor_row)
    end
  end
end

-- vim.wo[win][0] is the Lua form of :setlocal for that window
local function set_win_opts(win)
  if not vim.w[win].nanquim_saved then
    local saved = {}
    for name in pairs(WIN_OPTS) do
      saved[name] = vim.wo[win][name]
    end
    vim.w[win].nanquim_saved = saved
  end
  for name, value in pairs(WIN_OPTS) do
    vim.wo[win][0][name] = value
  end
end

local function restore_win_opts(win)
  local saved = vim.w[win].nanquim_saved
  if not saved then
    return
  end
  for name, value in pairs(saved) do
    vim.wo[win][0][name] = value
  end
  vim.w[win].nanquim_saved = nil
end

-- Bring `win` in line with whether its buffer is enabled: render or undo
local function refresh(win)
  local buf = vim.api.nvim_win_get_buf(win)
  if is_enabled(buf) then
    set_win_opts(win)
    M.render(win)
  else
    restore_win_opts(win)
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  end
end

-- Debounce: each call restarts the timer, so a burst of events (typing,
-- holding j) renders once, DEBOUNCE_MS after the last one.
local function render_later(win)
  local buf = vim.api.nvim_win_get_buf(win)
  if not is_enabled(buf) then
    return
  end
  timers[buf] = timers[buf] or vim.uv.new_timer()
  timers[buf]:stop()
  -- Timer callbacks run outside the main loop, where most of the API is
  -- off-limits; schedule_wrap moves the call back onto it.
  timers[buf]:start(DEBOUNCE_MS, 0, vim.schedule_wrap(function()
    if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == buf then
      M.render(win)
    end
  end))
end

function M.toggle(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  enabled[buf] = not is_enabled(buf)
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    refresh(win)
  end
end

function M.setup()
  vim.api.nvim_create_user_command("Nanquim", function() M.toggle() end, {})

  local group = vim.api.nvim_create_augroup("nanquim", { clear = true })

  -- A buffer appeared in a window, or its filetype was (re)detected
  vim.api.nvim_create_autocmd({ "BufWinEnter", "FileType" }, {
    group = group,
    callback = function(args)
      local win = vim.api.nvim_get_current_win()
      if vim.api.nvim_win_get_buf(win) == args.buf then
        refresh(win)
      end
    end,
  })

  -- Text or cursor changed: re-render (moves the anti-conceal line too)
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "CursorMoved", "CursorMovedI" }, {
    group = group,
    callback = function()
      render_later(vim.api.nvim_get_current_win())
    end,
  })

  -- Scrolled: new lines entered the visible area. <amatch> is the window id.
  vim.api.nvim_create_autocmd("WinScrolled", {
    group = group,
    callback = function(args)
      local win = tonumber(args.match)
      if win and vim.api.nvim_win_is_valid(win) then
        render_later(win)
      end
    end,
  })

  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    callback = function(args)
      if timers[args.buf] then
        timers[args.buf]:close()
        timers[args.buf] = nil
      end
      enabled[args.buf] = nil
    end,
  })
end

return M
