# nanquim.nvim

Render Markdown inside the Neovim buffer. The file stays a normal, editable
buffer; it just looks formatted. The line under the cursor shows the raw
Markdown, so editing never fights the rendering.

nanquim never changes your text. Everything is drawn with extmarks:
concealing syntax (`##`, `**`, backticks, link URLs), highlights, and virtual
text and lines.

## Features

- **Headings**: icon per level, a color per level and a full-width background
  blended from that color into your editor background
- **Code blocks**: background, fences hidden, language name on its own line
- **Lists**: bullets per nesting level, task checkboxes (`- [ ]`, `- [x]`)
  with done items dimmed
- **Block quotes** drawn with `▎`, and **GitHub callouts**: `> [!NOTE]`,
  `TIP`, `IMPORTANT`, `WARNING`, `CAUTION`
- **Inline**: bold, italic, strikethrough, inline code, links, autolinks and
  images
- **Tables**: box-drawing borders, and columns that stay aligned when the
  markup inside cells is concealed
- **Horizontal rules** across the whole window
- **Images** previewed in a floating window with `catimg`, and optionally
  drawn right in the buffer under their line
- Colors come from your colorscheme and update on `:colorscheme`
- Only the visible part of the window is rendered, so large files stay fast

Parsing uses Treesitter, not regular expressions: a `# comment` inside a bash
code block is never mistaken for a heading.

## Requirements

- Neovim **0.11+**
- The `markdown` and `markdown_inline` Treesitter parsers (bundled with Neovim)
- `termguicolors` for the heading backgrounds
- Optional: a [Nerd Font](https://www.nerdfonts.com) for the `nerd` icon preset
- Optional: [catimg](https://github.com/posva/catimg) for images

## Installation

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "jimmynando/nanquim.nvim",
  opts = {},
}
```

Markdown files are rendered as soon as they open.

## Configuration

These are the defaults:

```lua
require("nanquim").setup({
  filetypes = { "markdown" }, -- rendered automatically when opened
  debounce = 50, -- ms after the last edit/cursor move before redrawing
  preset = "unicode", -- icon set: "unicode" (any font) or "nerd" (Nerd Font)
  icons = {}, -- overrides on top of the preset
  image = {
    inline = false, -- also draw images under their line (see below)
    max_width = 60, -- columns
    max_height = 15, -- rows
  },
})
```

`icons` changes only what you set. A list replaces the preset's list whole:

```lua
require("nanquim").setup({
  preset = "nerd",
  icons = {
    bullets = { "→" }, -- every level uses "→"
    checkbox = { done = "✓" },
  },
})
```

| Key | `unicode` | `nerd` |
|---|---|---|
| `headings` | `◆` for every level | `U+F0CA1` `U+F0CA3` `U+F0CA5` `U+F0CA7` `U+F0CA9` `U+F0CAB` |
| `bullets` | `● ○ ■ □` | `● ○ ■ □` |
| `checkbox` | `todo = "▢"`, `done = "▣"` | todo `U+F0131`, done `U+F0C52` |
| `image` | `▧` | `U+F0976` |
| `callouts` | `ℹ ▶ ◉ ▲ ‼` | `U+F02FD` `U+F0336` `U+F017E` `U+F002A` `U+F0CE6` |

The `nerd` column lists code points, since browsers usually lack Nerd Font
glyphs; look them up in the [Nerd Fonts cheat sheet](https://www.nerdfonts.com/cheat-sheet).
In Lua, write one as an escape, for example `"\u{F0131}"`.

Bullets are drawn over the `-`, `*` or `+` character, so they must be exactly
one cell wide. The other icons can be any width.

## Commands

| Command | Action |
|---|---|
| `:Nanquim` or `:Nanquim toggle` | Toggle rendering in the current buffer |
| `:Nanquim enable` | Turn rendering on |
| `:Nanquim disable` | Turn rendering off and restore the window options |
| `:Nanquim image` | Preview the image on the cursor line in a floating window (`q` or `<Esc>` closes it) |

The same actions are available from Lua: `require("nanquim").toggle()`,
`.enable()` and `.disable()`, which take an optional buffer number, and
`.preview_image()`.

nanquim sets no key mappings. To preview images with a key:

```lua
vim.keymap.set("n", "<leader>mi", "<cmd>Nanquim image<cr>", { desc = "Preview Markdown image" })
```

Image paths are relative to the Markdown file. Remote images (`https://...`)
are not supported. Images are drawn with colored half blocks, so each cell
holds two pixels: fine for logos, diagrams and photos, too coarse for
screenshots of text.

### Inline images

With `image = { inline = true }`, images are also drawn in the buffer, under
their line. This is off by default because it makes scrolling jump: Neovim
scrolls by buffer lines, so a line with a 15-row image below it moves as one
16-row block, and moving the cursor past it can shift the view by a whole
image at once. `'smoothscroll'` does not help, since it only splits wrapped
text, not virtual lines.

Inline images appear a moment after the rest, because `catimg` runs in the
background; the result is cached per file.

## Highlight groups

Every group is defined with `default = true`, so your config or colorscheme can
override it. Set your own after the colorscheme loads, for example:

```lua
vim.api.nvim_set_hl(0, "NanquimImportant", { fg = "#b16286" })
```

| Group | Default |
|---|---|
| `NanquimH1` … `NanquimH6` | Heading colors from the colorscheme; if every level has the same color, `Function`, `Constant`, `Type`, `Identifier`, `Special` and `Statement` |
| `NanquimH1Bg` … `NanquimH6Bg` | 15% of the heading color over the `Normal` background (none on a transparent background) |
| `NanquimCode` | `ColorColumn` |
| `NanquimCodeInfo` | `Special` |
| `NanquimCodeInline` | `NanquimCode` |
| `NanquimRule` | `LineNr` |
| `NanquimBullet` | `Special` |
| `NanquimTodo` | `Special` |
| `NanquimDone` | `DiagnosticOk` |
| `NanquimDoneText` | `Comment` |
| `NanquimQuote` | `Comment` |
| `NanquimNote` | `DiagnosticInfo` |
| `NanquimTip` | `DiagnosticOk` |
| `NanquimImportant` | `Constant` |
| `NanquimWarning` | `DiagnosticWarn` |
| `NanquimCaution` | `DiagnosticError` |
| `NanquimBold` | `@markup.strong` |
| `NanquimItalic` | `@markup.italic` |
| `NanquimStrike` | `@markup.strikethrough` |
| `NanquimLink` | `@markup.link.label` |
| `NanquimImage` | `Special` |
| `NanquimTable` | `LineNr` |
| `NanquimTableHead` | `@markup.strong` |

## Try it

Open [`demo.md`](demo.md) from this repository: it has one section per
rendered element, including the edge cases.

## Limitations

See also [`ROADMAP.md`](ROADMAP.md) for planned improvements.

- When a line's raw text would be wider than the window, Neovim may show an
  extra blank row under it, even if concealing makes it fit. Neovim sizes
  wrapped lines by the raw text.
- Table cells stay aligned only for the markup nanquim conceals. Things only
  Neovim's own highlighter hides, such as `&nbsp;` or reference links
  (`[text][ref]`), can still shift a column.
- Setext headings (text underlined with `===` or `---`) and indented code
  blocks are not rendered.
- If the same buffer is open in two windows, the raw cursor line follows the
  window that changed last.
