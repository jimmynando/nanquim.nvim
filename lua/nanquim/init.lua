local M = {}
local ns = vim.api.nvim_create_namespace("nanquim")

-- ATX headings ("# ..." to "###### ...") from the block grammar.
-- Fenced code is a separate node type, so "# comment" inside it never matches.
local heading_query = vim.treesitter.query.parse("markdown", "(atx_heading) @heading")

local function render_heading(buf, node)
  local marker = node:child(0) -- atx_h1_marker .. atx_h6_marker, e.g. "##"
  local content = node:field("heading_content")[1] -- nil for a bare "#"
  local row, marker_col, _, text_col = marker:range()
  if content then
    _, text_col = content:start() -- skip the space after the marker too
  end

  -- Hide "## " and show a marker in its place
  vim.api.nvim_buf_set_extmark(buf, ns, row, marker_col, {
    end_col = text_col,
    conceal = "",
    virt_text = { { "◆ ", "Title" } },
    virt_text_pos = "inline",
  })

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

function M.render(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)

  local ok, parser = pcall(vim.treesitter.get_parser, buf, "markdown")
  if not ok or not parser then
    return
  end

  -- Parse only this row range (the whole buffer for now; step 3 narrows it)
  local first, last = 0, vim.api.nvim_buf_line_count(buf)
  parser:parse({ first, last })

  -- trees() on the root parser = block grammar only. for_each_tree would also
  -- visit markdown injected into ```markdown fences and render headings there.
  for _, tree in ipairs(parser:trees()) do
    for _, node in heading_query:iter_captures(tree:root(), buf, first, last) do
      render_heading(buf, node)
    end
  end
end

function M.setup()
  vim.api.nvim_create_user_command("Nanquim", function()
    -- Conceal only works with conceallevel >= 2 (step 3 moves this to a set/restore per window)
    vim.opt_local.conceallevel = 2
    M.render()
  end, {})
end

return M
