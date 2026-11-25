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
  (block_quote) @quote
  (pipe_table) @table
]])

-- Inline elements from the markdown_inline grammar (paragraphs, headings,
-- cells). "**", "*" and "~~" are all emphasis_delimiter nodes.
local inline_query = vim.treesitter.query.parse("markdown_inline", [[
  [(emphasis_delimiter) (code_span_delimiter)] @delimiter
  (emphasis) @italic
  (strong_emphasis) @bold
  (strikethrough) @strike
  (code_span) @code_inline
  (inline_link) @link
  (image) @image
  (uri_autolink) @autolink
]])

-- GitHub callouts ("> [!NOTE]"): icon, title and highlight group
local CALLOUTS = {
  NOTE = { "ℹ", "Note", "NanquimNote" },
  TIP = { "▶", "Tip", "NanquimTip" },
  IMPORTANT = { "◉", "Important", "NanquimImportant" },
  WARNING = { "▲", "Warning", "NanquimWarning" },
  CAUTION = { "‼", "Caution", "NanquimCaution" },
}

-- One bullet per nesting level, cycling after the last
local BULLETS = { "●", "○", "■", "□" }
local BULLET_TYPES = { list_marker_minus = true, list_marker_plus = true, list_marker_star = true }

-- Foreground color of a group (links followed), or nil
local function fg_of(name)
  return vim.api.nvim_get_hl(0, { name = name, link = false }).fg
end

-- Mix two 0xRRGGBB colors: alpha = 1 gives `fg`, alpha = 0 gives `bg`
local function blend(fg, bg, alpha)
  local result = 0
  for _, shift in ipairs({ 0x10000, 0x100, 1 }) do
    local a = math.floor(fg / shift) % 256
    local b = math.floor(bg / shift) % 256
    result = result + math.floor(a * alpha + b * (1 - alpha) + 0.5) * shift
  end
  return result
end

-- Used when the theme paints every heading level the same color
local HEADING_FALLBACK = { "Function", "Constant", "Type", "Identifier", "Special", "Statement" }

-- NanquimH1..6 (text) and NanquimH1Bg..6Bg (line background, the heading
-- color faded into the editor background). Recomputed on :colorscheme.
local function set_heading_highlights()
  local colors, distinct = {}, false
  for level = 1, 6 do
    colors[level] = fg_of("@markup.heading." .. level .. ".markdown")
    distinct = distinct or colors[level] ~= colors[1]
  end
  if not distinct then
    for level = 1, 6 do
      colors[level] = fg_of(HEADING_FALLBACK[level])
    end
  end

  local normal_bg = vim.api.nvim_get_hl(0, { name = "Normal" }).bg
  for level = 1, 6 do
    local fg = colors[level] or fg_of("Title")
    vim.api.nvim_set_hl(0, "NanquimH" .. level, { fg = fg, bold = true, default = true })
    -- A transparent terminal background has no color to mix with
    if fg and normal_bg then
      vim.api.nvim_set_hl(0, "NanquimH" .. level .. "Bg", { bg = blend(fg, normal_bg, 0.15), default = true })
    end
  end
end

-- `default = true` lets a colorscheme define these groups itself
local function set_highlights()
  set_heading_highlights()
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
  link("NanquimQuote", "Comment")
  link("NanquimNote", "DiagnosticInfo")
  link("NanquimTip", "DiagnosticOk")
  link("NanquimImportant", "Constant") -- purple in many themes; DiagnosticHint is often teal
  -- @markup.* have built-in defaults (bold, italic...), so they always exist
  link("NanquimBold", "@markup.strong")
  link("NanquimItalic", "@markup.italic")
  link("NanquimStrike", "@markup.strikethrough")
  link("NanquimCodeInline", "NanquimCode")
  link("NanquimLink", "@markup.link.label")
  link("NanquimImage", "Special")
  link("NanquimTable", "LineNr")
  link("NanquimTableHead", "@markup.strong")
  link("NanquimWarning", "DiagnosticWarn")
  link("NanquimCaution", "DiagnosticError")
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
  local hl = "NanquimH" .. marker:type():match("atx_h(%d)_marker")

  -- Background across the whole line, the cursor line included
  vim.api.nvim_buf_set_extmark(ctx.buf, ns, row, 0, { line_hl_group = hl .. "Bg" })

  -- Hide "## " and show a marker in its place. Anti-conceal: on the cursor
  -- line Neovim already shows the concealed text, but not our virt_text,
  -- so skip this mark there and the raw "## " shows alone.
  if row ~= ctx.cursor_row then
    vim.api.nvim_buf_set_extmark(ctx.buf, ns, row, marker_col, {
      end_col = text_col,
      conceal = "",
      virt_text = { { "◆ ", hl } },
      virt_text_pos = "inline",
    })
  end

  -- Paint the heading text
  if content then
    local _, _, end_row, end_col = content:range()
    vim.api.nvim_buf_set_extmark(ctx.buf, ns, row, text_col, {
      end_row = end_row,
      end_col = end_col,
      hl_group = hl,
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

-- How many nodes of `type` sit above `node` (list nesting level, etc.)
local function count_ancestors(node, type)
  local count = 0
  local parent = node:parent()
  while parent do
    if parent:type() == type then
      count = count + 1
    end
    parent = parent:parent()
  end
  return count
end

-- "-", "*" or "+" replaced by a symbol per level. Overlay swaps characters
-- one for one, so the symbol must be 1 cell wide like the marker.
function renderers.bullet(ctx, node)
  local row, col = node:start()
  local sibling = node:next_named_sibling()
  if row == ctx.cursor_row or (sibling and sibling:type():match("^task_list_marker")) then
    return -- cursor line shows raw; task items are drawn by renderers.checkbox
  end
  local level = count_ancestors(node, "list")
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

-- Every ">" becomes "▎". The tree only marks the first ">" clearly (later ones
-- are scattered block_continuation nodes), so each line's prefix is scanned
-- instead. "> [!NOTE]" on the first line turns the quote into a callout.
function renderers.quote(ctx, node)
  local start_row, start_col = node:start()
  local function line(row)
    return vim.api.nvim_buf_get_lines(ctx.buf, row, row + 1, false)[1]
  end

  local hl = "NanquimQuote"
  -- "()" captures a position, so this gives where "[!NOTE]" starts and ends
  local from, kind, to = line(start_row):match("^[%s>]*()%[!(%a+)%]()", start_col + 1)
  local callout = kind and CALLOUTS[kind:upper()]
  if callout then
    hl = callout[3]
    if start_row ~= ctx.cursor_row then
      vim.api.nvim_buf_set_extmark(ctx.buf, ns, start_row, from - 1, {
        end_col = to - 1,
        conceal = "",
        virt_text = { { callout[1] .. " " .. callout[2], hl } },
        virt_text_pos = "inline",
      })
    end
  end

  -- A nested quote's ">" are on the same lines as the outer one's; the
  -- outermost quote draws them all, in its own color.
  if count_ancestors(node, "block_quote") > 0 then
    return
  end
  for row = math.max(start_row, ctx.first), math.min(last_row(node), ctx.last - 1) do
    if row ~= ctx.cursor_row then
      local prefix = line(row):match("^[%s>]*", start_col + 1)
      for pos in prefix:gmatch("()>") do
        vim.api.nvim_buf_set_extmark(ctx.buf, ns, row, start_col + pos - 1, {
          virt_text = { { "▎", hl } },
          virt_text_pos = "overlay",
        })
      end
    end
  end
end

-- Inline helpers: hide a range, or paint a node with a highlight group
local function conceal(ctx, row, col, end_row, end_col)
  vim.api.nvim_buf_set_extmark(ctx.buf, ns, row, col, { end_row = end_row, end_col = end_col, conceal = "" })
end

local function paint(ctx, node, hl)
  local row, col, end_row, end_col = node:range()
  vim.api.nvim_buf_set_extmark(ctx.buf, ns, row, col, { end_row = end_row, end_col = end_col, hl_group = hl })
end

local function find_child(node, type)
  for child in node:iter_children() do
    if child:type() == type then
      return child
    end
  end
end

-- Only conceal and color below (no virt_text), so the cursor line needs no
-- special case: Neovim shows the raw markers there by itself.
function renderers.delimiter(ctx, node)
  conceal(ctx, node:range())
end

function renderers.italic(ctx, node)
  paint(ctx, node, "NanquimItalic")
end

function renderers.bold(ctx, node)
  paint(ctx, node, "NanquimBold")
end

function renderers.strike(ctx, node)
  paint(ctx, node, "NanquimStrike")
end

function renderers.code_inline(ctx, node)
  paint(ctx, node, "NanquimCodeInline")
end

-- [text](url "title"): hide everything around the text
function renderers.link(ctx, node)
  local text = find_child(node, "link_text")
  if not text then
    return
  end
  local row, col, end_row, end_col = node:range()
  local text_row, text_col, text_end_row, text_end_col = text:range()
  conceal(ctx, row, col, text_row, text_col)
  conceal(ctx, text_end_row, text_end_col, end_row, end_col)
  paint(ctx, text, "NanquimLink")
end

-- <https://...>: hide the angle brackets
function renderers.autolink(ctx, node)
  local row, col, end_row, end_col = node:range()
  conceal(ctx, row, col, row, col + 1)
  conceal(ctx, end_row, end_col - 1, end_row, end_col)
  paint(ctx, node, "NanquimLink")
end

-- ![alt](path) becomes "▧ alt". The alt text stays real text and only the
-- icon is inserted: Neovim sizes wrapped lines by raw text + virt_text, so
-- long inserted text can add a blank screen row.
function renderers.image(ctx, node)
  local row, col, end_row, end_col = node:range()
  local desc = find_child(node, "image_description")
  local dest = find_child(node, "link_destination")
  local on_cursor = row == ctx.cursor_row -- anti-conceal: no virt_text there

  if desc then
    local desc_row, desc_col, desc_end_row, desc_end_col = desc:range()
    vim.api.nvim_buf_set_extmark(ctx.buf, ns, row, col, {
      end_row = desc_row,
      end_col = desc_col,
      conceal = "",
      virt_text = not on_cursor and { { "▧ ", "NanquimImage" } } or nil,
      virt_text_pos = "inline",
    })
    conceal(ctx, desc_end_row, desc_end_col, end_row, end_col)
    paint(ctx, desc, "NanquimImage")
  elseif dest and not on_cursor then
    -- ![](path): Neovim's own highlighter conceals the path, so it can't
    -- stay real text; show "▧ path" as virt_text instead
    vim.api.nvim_buf_set_extmark(ctx.buf, ns, row, col, {
      end_row = end_row,
      end_col = end_col,
      conceal = "",
      virt_text = { { "▧ " .. vim.treesitter.get_node_text(dest, ctx.buf), "NanquimImage" } },
      virt_text_pos = "inline",
    })
  end
end

-- Display cells our marks took away from [col, end_col) on `row`: concealed
-- text minus inserted inline virt_text. It reads back the extmarks that the
-- inline pass already placed, so it matches what is on screen.
local function hidden_width(ctx, row, line, col, end_col)
  local hidden = 0
  local marks = vim.api.nvim_buf_get_extmarks(ctx.buf, ns, { row, col }, { row, end_col - 1 }, { details = true })
  for _, mark in ipairs(marks) do
    local start, details = mark[3], mark[4]
    if details.conceal and (details.end_row or row) == row then
      local text = line:sub(start + 1, math.min(details.end_col, end_col))
      hidden = hidden + vim.fn.strdisplaywidth(text) - vim.fn.strdisplaywidth(details.conceal)
    end
    if details.virt_text and details.virt_text_pos == "inline" then
      for _, chunk in ipairs(details.virt_text) do
        hidden = hidden - vim.fn.strdisplaywidth(chunk[1])
      end
    end
  end
  return hidden
end

-- Delimiter row text drawn with box characters, one for one:
-- "|---|:--:|" -> "├───┼────┤" (or "┌───┬────┐" for a border line)
local function box_line(text, left, mid, right)
  local out = {}
  for i = 1, #text do
    local char = text:sub(i, i)
    if char ~= "|" then
      out[i] = "─"
    elseif i == 1 then
      out[i] = left
    elseif i == #text then
      out[i] = right
    else
      out[i] = mid
    end
  end
  return table.concat(out)
end

-- Tables: "|" -> "│", the delimiter row -> "├──┼──┤", and, when every row
-- has its pipes in the same columns, borders above and below.
function renderers.table(ctx, node)
  local rows = {}
  for child in node:iter_children() do
    if child:type():match("^pipe_table") then
      local row = child:start()
      local info = {
        row = row,
        line = vim.api.nvim_buf_get_lines(ctx.buf, row, row + 1, false)[1],
        delimiter = child:type() == "pipe_table_delimiter_row",
        pipes = {}, -- byte columns, for extmarks
        cols = {}, -- display columns, for alignment ("ç" is 2 bytes, 1 cell)
      }
      for pipe in child:iter_children() do
        if pipe:type() == "|" then
          local _, col = pipe:start()
          table.insert(info.pipes, col)
          table.insert(info.cols, vim.fn.strdisplaywidth(info.line:sub(1, col)))
        end
      end
      if child:type() == "pipe_table_header" then
        for cell in child:iter_children() do
          if cell:type() == "pipe_table_cell" then
            paint(ctx, cell, "NanquimTableHead")
          end
        end
      end
      table.insert(rows, info)
    end
  end

  local delimiter = rows[2] -- always the second row in a valid table
  if not delimiter then
    return
  end
  local aligned = true
  for _, info in ipairs(rows) do
    aligned = aligned and vim.deep_equal(info.cols, delimiter.cols)
  end

  -- The delimiter row without its indent and trailing spaces
  local indent, body = delimiter.line:match("^(%s*)(.-)%s*$")

  for _, info in ipairs(rows) do
    if info.row ~= ctx.cursor_row then -- anti-conceal: raw on the cursor line
      if info.delimiter then
        vim.api.nvim_buf_set_extmark(ctx.buf, ns, info.row, #indent, {
          virt_text = { { box_line(body, "├", "┼", "┤"), "NanquimTable" } },
          virt_text_pos = "overlay",
        })
      else
        for _, col in ipairs(info.pipes) do
          vim.api.nvim_buf_set_extmark(ctx.buf, ns, info.row, col, {
            virt_text = { { "│", "NanquimTable" } },
            virt_text_pos = "overlay",
          })
        end
      end
    end
  end

  if not aligned then
    return -- borders and padding only make sense when the columns line up
  end

  -- Borders need pipes on both edges ("| a | b |", not "a | b")
  if body:match("^|.*|$") then
    vim.api.nvim_buf_set_extmark(ctx.buf, ns, rows[1].row, 0, {
      virt_lines = { { { indent .. box_line(body, "┌", "┬", "┐"), "NanquimTable" } } },
      virt_lines_above = true,
    })
    vim.api.nvim_buf_set_extmark(ctx.buf, ns, rows[#rows].row, 0, {
      virt_lines = { { { indent .. box_line(body, "└", "┴", "┘"), "NanquimTable" } } },
    })
  end

  -- Concealed markup ("**", "`", link URLs) makes cells shorter and pulls the
  -- next "|" left. Pad each cell back with spaces before its closing pipe.
  -- Runs after the inline pass (ctx.deferred), once those marks exist.
  table.insert(ctx.deferred, function()
    for _, info in ipairs(rows) do
      if not info.delimiter and info.row ~= ctx.cursor_row then
        local cell_start = 0
        for _, col in ipairs(info.pipes) do
          local pad = col > cell_start and hidden_width(ctx, info.row, info.line, cell_start, col) or 0
          if pad > 0 then
            -- One column before the pipe: at the pipe itself, the "│" overlay
            -- would land on the inserted spaces instead of on the "|"
            vim.api.nvim_buf_set_extmark(ctx.buf, ns, info.row, col - 1, {
              virt_text = { { string.rep(" ", pad) } },
              virt_text_pos = "inline",
            })
          end
          cell_start = col + 1
        end
      end
    end
  end)
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
    deferred = {}, -- functions that need the inline marks in place first
  }
  parser:parse({ first, last })

  local function run(query, ltree)
    for _, tree in ipairs(ltree:trees()) do
      for id, node in query:iter_captures(tree:root(), buf, first, last) do
        renderers[query.captures[id]](ctx, node)
      end
    end
  end

  -- The root parser holds the block grammar. Inline text is injected as
  -- separate markdown_inline trees; children() gives only the root's own
  -- injections. for_each_tree would also visit markdown injected into
  -- ```markdown fences and render it as if it were real markdown.
  run(block_query, parser)
  local inline = parser:children().markdown_inline
  if inline then
    run(inline_query, inline)
  end
  for _, fn in ipairs(ctx.deferred) do
    fn()
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
