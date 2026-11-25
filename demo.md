# nanquim demo

A plain paragraph: nothing changes here.

## Headings

### Level 3

#### Level 4

##### Level 5

###### Level 6

#no space after the hash, so this is not a heading

> # Heading inside a quote

## Inline text

Text with **bold**, *italic*, ***both***, `code` and ~~strikethrough~~.

A [link to Neovim](https://neovim.io "official site") and a bare link:
<https://github.com>.

Image with alt text: ![nanquim logo](images/logo.png)

Image without alt text: ![](images/landscape.png)

### Heading with `code` and **bold**

## Tables

Aligned: it gets borders, and the cells with bold, code and a link stay
aligned even with their markup hidden.

| Element | Example                     | Status |
|---------|-----------------------------|--------|
| Bold    | **strong**                  | ok     |
| Code    | `vim.api`                   | ok     |
| Link    | [Neovim](https://neovim.io) | ok     |
| Accents | café, naïve, ação           | ok     |

Not aligned: only the `|` and the middle row change, no borders.

| a | b |
|---|---|
| a long cell | x |

No `|` on the edges:

x | y
--|--
1 | 2

## Code blocks

```lua
local function hello(name)
  return "hello, " .. name
end
```

~~~
block with no language
~~~

```bash
# a bash comment, not a heading
```

```markdown
# a markdown example, not a heading
```

## Lists

- level 1
  - level 2
    - level 3
      - level 4
        - level 5 cycles back to the level 1 symbol
* an asterisk is a bullet too
+ and so is a plus

1. a numbered list
2. keeps its numbers

- [ ] pending task
- [x] done task
  - [X] done subtask, with an uppercase X
1. [ ] a numbered task keeps its number

## Quotes and callouts

> A plain quote: the `>` becomes a bar.
> Second line of the same quote.
>
> > Nested quote: two bars.

> [!NOTE]
> Information worth noticing.

> [!TIP]
> A tip for doing it better.

> [!IMPORTANT]
> Something essential to the goal.

> [!WARNING]
> Calls for attention to avoid problems.

> [!CAUTION]
> Risk of a negative outcome.

> [!INFO]
> An unknown type stays a plain quote.

## Horizontal rule

---

***

Underlined heading (the --- below is not a horizontal rule)
---
