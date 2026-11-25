local M = {}
local ns = vim.api.nvim_create_namespace("nanquim")

local DEBOUNCE_MS = 50
-- Window options while rendering; the user's values are saved and restored
local WIN_OPTS = { conceallevel = 2, concealcursor = "" }

-- buf -> true/false once the user toggles it; nil means "on if markdown"
local enabled = {}
-- buf -> uv timer used to debounce renders
local timers = {}

-- Block-level elements from the markdown grammar. Each capture name maps to
-- a function in `renderers` below. Code is its own node type, so "# comment"
-- inside a fence never matches @heading.
local block_query = vim.treesitter.query.parse("markdown", [[
  (atx_heading) @heading
  (fenced_code_block) @code
  (thematic_break) @rule
  [(list_marker_minus) (list_marker_plus) (list_marker_star)] @bullet
  [(task_list_marker_unchecked) (task_list_marker_checked)] @checkbox
]])

-- One bullet per nesting level, cycling after the last
local BULLETS = { "●", "○", "■", "□" }
local BULLET_TYPES = { list_marker_minus = true, list_marker_plus = true, list_marker_star = true }

-- `default = true` lets a colorscheme define these groups itself
local function set_highlights()
  local function link(name, target)
    vim.api.nvim_set_hl(0, name, { link = target, default = true })
  end
  link("NanquimCode", "ColorColumn")
  link("NanquimCodeInfo", "Special")
  link("NanquimRule", "LineNr")
  link("NanquimBullet", "Special")
  link("NanquimTodo", "Special")
  link("NanquimDone", "DiagnosticOk")
  link("NanquimDoneText", "Comment")
end

local function is_enabled(buf)
  if enabled[buf] ~= nil then
    return enabled[buf]
  end
  return vim.bo[buf].filetype == "markdown"
end

-- Last row a node covers. Nodes that end with a newline end at {next_row, 0}.
local function last_row(node)
  local _, _, end_row, end_col = node:range()
  return end_col == 0 and end_row - 1 or end_row
end

-- ctx = { buf, win, cursor_row, first, last } for the render in progress
local renderers = {}

function renderers.heading(ctx, node)
  local marker = node:child(0) -- atx_h1_marker .. atx_h6_marker, e.g. "##"
  local content = node:field("heading_content")[1] -- nil for a bare "#"
  local row, marker_col, _, text_col = marker:range()
  if content then
    _, text_col = content:start() -- skip the space after the marker too
  end

  -- Hide "## " and show a marker in its place. Anti-conceal: on the cursor
  -- line Neovim already shows the concealed text, but not our virt_text,
  -- so skip this mark there and the raw "## " shows alone.
  if row ~= ctx.cursor_row then
    vim.api.nvim_buf_set_extmark(ctx.buf, ns, row, marker_col, {
      end_col = text_col,
      conceal = "",
      virt_text = { { "◆ ", "Title" } },
      virt_text_pos = "inline",
    })
  end

  -- Paint the heading text
  if content then
    local _, _, end_row, end_col = content:range()
    vim.api.nvim_buf_set_extmark(ctx.buf, ns, row, text_col, {
      end_row = end_row,
      end_col = end_col,
      hl_group = "Title",
    })
  end
end

-- Width of the text area: window width minus number/sign/fold columns
local function text_width(win)
  return vim.api.nvim_win_get_width(win) - vim.fn.getwininfo(win)[1].textoff
end

-- Background on every line, fence lines hidden whole, and the language name
-- on a fake line (virt_lines) where the opening fence was.
function renderers.code(ctx, node)
  local start_row, col = node:start()
  local end_row = last_row(node)

  -- A huge block may start far above the screen; only mark the visible part
  for row = math.max(start_row, ctx.first), math.min(end_row, ctx.last - 1) do
    vim.api.nvim_buf_set_extmark(ctx.buf, ns, row, 0, { line_hl_group = "NanquimCode" })
  end

  local language
  for child in node:iter_children() do
    if child:type() == "fenced_code_block_delimiter" then
      -- conceal_lines (Neovim 0.11+) hides the whole line, not just the
      -- characters. Like conceal, the cursor line still shows raw.
      local row = child:start()
      vim.api.nvim_buf_set_extmark(ctx.buf, ns, row, 0, { conceal_lines = "" })
    elseif child:type() == "info_string" and child:child(0) then
      language = vim.treesitter.get_node_text(child:child(0), ctx.buf)
    end
  end

  -- The fake line hangs above the first code line. Anti-conceal: skip it when
  -- the cursor is on the opening fence, which then shows raw ("```lua").
  if language and start_row < end_row and start_row ~= ctx.cursor_row then
    local label = " " .. language
    local fill = text_width(ctx.win) - col - vim.fn.strdisplaywidth(label)
    vim.api.nvim_buf_set_extmark(ctx.buf, ns, start_row + 1, 0, {
      virt_lines = { {
        { string.rep(" ", col) }, -- block indent (e.g. inside a list)
        -- A list of groups is combined: code background + label color
        { label, { "NanquimCode", "NanquimCodeInfo" } },
        -- virt_lines get no line_hl_group, so pad the background by hand
        { string.rep(" ", fill), "NanquimCode" },
      } },
      virt_lines_above = true,
    })
  end
end

-- "---", "***" or "___" drawn over as a line across the whole window
function renderers.rule(ctx, node)
  local row, col = node:start()
  if row == ctx.cursor_row then
    return -- anti-conceal: overlay virt_text would hide the raw text
  end
  local width = text_width(ctx.win) - col
  vim.api.nvim_buf_set_extmark(ctx.buf, ns, row, col, {
    virt_text = { { string.rep("─", width), "NanquimRule" } },
    virt_text_pos = "overlay",
  })
end

-- Nesting level of a list marker: how many `list` nodes sit above it
local function list_level(node)
  local level = 0
  local parent = node:parent()
  while parent do
    if parent:type() == "list" then
      level = level + 1
    end
    parent = parent:parent()
  end
  return level
end

-- "-", "*" or "+" replaced by a symbol per level. Overlay swaps characters
-- one for one, so the symbol must be 1 cell wide like the marker.
function renderers.bullet(ctx, node)
  local row, col = node:start()
  local sibling = node:next_named_sibling()
  if row == ctx.cursor_row or (sibling and sibling:type():match("^task_list_marker")) then
    return -- cursor line shows raw; task items are drawn by renderers.checkbox
  end
  local level = list_level(node)
  vim.api.nvim_buf_set_extmark(ctx.buf, ns, row, col, {
    virt_text = { { BULLETS[(level - 1) % #BULLETS + 1], "NanquimBullet" } },
    virt_text_pos = "overlay",
  })
end

-- "- [ ]" becomes "▢" and "- [x]" becomes "▣" with the text dimmed. The box
-- takes the bullet's place; in "1. [ ]" the number stays.
function renderers.checkbox(ctx, node)
  local row, col, _, end_col = node:range()
  local done = node:type() == "task_list_marker_checked"
  local marker = node:prev_named_sibling()
  if marker and BULLET_TYPES[marker:type()] then
    _, col = marker:start()
  end

  if row ~= ctx.cursor_row then
    vim.api.nvim_buf_set_extmark(ctx.buf, ns, row, col, {
      end_col = end_col,
      conceal = "",
      virt_text = { done and { "▣", "NanquimDone" } or { "▢", "NanquimTodo" } },
      virt_text_pos = "inline",
    })
  end

  local paragraph = node:next_named_sibling()
  local text = paragraph and paragraph:named_child(0)
  if done and text and text:type() == "inline" then
    local start_row, start_col, end_row, text_end = text:range()
    vim.api.nvim_buf_set_extmark(ctx.buf, ns, start_row, start_col, {
      end_row = end_row,
      end_col = text_end,
      hl_group = "NanquimDoneText",
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
  local ctx = {
    buf = buf,
    win = win,
    cursor_row = vim.api.nvim_win_get_cursor(win)[1] - 1,
    first = first,
    last = last,
  }
  parser:parse({ first, last })

  -- trees() on the root parser = block grammar only. for_each_tree would also
  -- visit markdown injected into ```markdown fences and render headings there.
  for _, tree in ipairs(parser:trees()) do
    for id, node in block_query:iter_captures(tree:root(), buf, first, last) do
      renderers[block_query.captures[id]](ctx, node)
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

  set_highlights()
  local group = vim.api.nvim_create_augroup("nanquim", { clear = true })

  -- :colorscheme clears every highlight group, ours included
  vim.api.nvim_create_autocmd("ColorScheme", { group = group, callback = set_highlights })

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

  -- Resized: the horizontal rule width changed
  vim.api.nvim_create_autocmd("WinResized", {
    group = group,
    callback = function()
      for _, win in ipairs(vim.v.event.windows) do
        if vim.api.nvim_win_is_valid(win) then
          render_later(win)
        end
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
