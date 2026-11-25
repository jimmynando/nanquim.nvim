# Roadmap

Future improvements, in no particular order. Nothing here is scheduled yet.

## Code

- [ ] **Split `lua/nanquim/init.lua` into modules.** It is one file of about
  1100 lines. Split it by topic (config, highlights, blocks, inline, tables,
  images) with the same behavior, so each part is easier to read and change.
- [ ] **Automated tests.** Turn the manual checks into a suite that runs with
  `nvim --headless`, and catch regressions on every change. Two techniques
  already worked during development:
  - reading extmarks back through the API (`nvim_buf_get_extmarks` with
    `details = true`) to check what was rendered;
  - running Neovim inside a terminal buffer (`jobstart(..., { term = true })`),
    sending keys, and reading the screen text. With `--listen` and
    `sockconnect`, the test can also query the child's state, such as
    `line('w0')` while scrolling.

## Markdown

- [ ] **Setext headings**: text underlined with `===` or `---`.
- [ ] **Indented code blocks**: four-space indented code, which gets no
  background today.
- [ ] **Reference links**: `[text][ref]` and the `[ref]: url` definitions.
  Neovim's highlighter conceals parts of them that nanquim does not track,
  which can misalign table cells.
- [ ] **Footnotes**: `[^1]` and their definitions.

## Images

- [ ] **Show or hide one image in the buffer on demand.** Inline images are off
  by default because they make scrolling jump (see the README). Expanding a
  single image with a command, like a fold, would keep scrolling smooth and
  only move the view when asked.
- [ ] **Support `chafa`** as an alternative to `catimg`. It can fit width and
  height in one call (`-s WxH`) and offers more symbol sets.
- [ ] **Real images with the Kitty graphics protocol** in terminals that
  support it (Kitty, Ghostty) when not inside tmux, falling back to half
  blocks elsewhere. It cannot be tested in Alacritty, which lacks the protocol.

## Repository

- [ ] **Add a `LICENSE`.** Without one, nobody may legally reuse the code.
  MIT is the most common choice for Neovim plugins.
- [ ] **Add a screenshot** of `demo.md` rendered at the top of the README.
