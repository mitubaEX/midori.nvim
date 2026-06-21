# midori.nvim

Reader-only markdown viewer for Neovim, inspired by [leaf](https://leaf.rivolink.mg).

Open the current markdown buffer in a dedicated read-only window where headings,
inline decorations and fenced code blocks are rendered "nicely" — no conceal hacks,
no rewriting of the source buffer.

## Features

- Line-based parser, zero runtime dependencies
- Decoration via extmarks (markers like `**bold**` and `` `code` `` are stripped from the visible text)
- Headings H1–H6 with per-level prefix glyph and highlight
- Lists, blockquotes, horizontal rules
- Fenced code blocks with frame, language label and line numbers
- **Optional syntax highlighting** inside code blocks via Neovim treesitter
- **Optional mermaid graph rendering** via [`mermaid-ascii`](https://github.com/AlexanderGrooff/mermaid-ascii)
- Reader window mode: `vsplit` (default) / `full` / `float`
- `q` to close the reader

## Requirements

- Neovim 0.10+
- For code syntax highlighting (optional): the relevant treesitter parsers
  installed in your runtimepath (e.g. via `nvim-treesitter`)
- For mermaid (optional): `mermaid-ascii` on `$PATH`

## Install (lazy.nvim)

```lua
{
  "mitubaEX/midori.nvim",
  ft = "markdown",
  cmd = { "MidoriView", "MidoriToggle", "MidoriClose" },
  opts = {},
}
```

Or as a local clone:

```lua
{ dir = "~/ghq/github.com/mitubaEX/midori.nvim", ft = "markdown", opts = {} }
```

## Usage

| Command           | Description                                |
| ----------------- | ------------------------------------------ |
| `:MidoriView`     | Open the reader for the current buffer     |
| `:MidoriClose`    | Close the reader                           |
| `:MidoriToggle`   | Toggle the reader                          |

Inside the reader buffer:

- `q` — close

## Configuration

`setup()` is called with the defaults below; pass an override table to change any of them.

```lua
require("midori").setup({
  -- "vsplit" | "full" | "float"
  window = "vsplit",
  -- only used when window = "float"
  width = 0.6,
  height = 0.85,

  heading = {
    -- prefix glyph per level (1..6)
    icons = { "▌", "▍", "▎", "▏", "┃", "│" },
  },

  code = {
    border       = true,
    line_numbers = true,
    -- treesitter syntax highlighting inside fenced code blocks
    syntax       = true,
  },

  mermaid = {
    -- enable mermaid-ascii rendering for ```mermaid blocks
    enabled = true,
    -- override the binary; nil = use the one found on $PATH
    bin     = nil,
  },

  rule_width = 60,
})
```

## Highlight groups

All groups are defined with `default = true` and linked to common groups so your
colorscheme applies automatically. Override with `vim.api.nvim_set_hl(0, ...)`.

| Group               | Default link |
| ------------------- | ------------ |
| `MidoriH1`–`MidoriH2` | `Title`    |
| `MidoriH3`–`MidoriH4` | `Function` |
| `MidoriH5`–`MidoriH6` | `Identifier` |
| `MidoriBold`        | `(bold)`     |
| `MidoriItalic`      | `(italic)`   |
| `MidoriStrike`      | `(strikethrough)` |
| `MidoriInlineCode`  | `String`     |
| `MidoriCodeBlock`   | `CursorLine` |
| `MidoriCodeBorder`  | `Comment`    |
| `MidoriCodeLang`    | `Special`    |
| `MidoriCodeLineNr`  | `LineNr`     |
| `MidoriBullet`      | `Special`    |
| `MidoriQuote`       | `Comment`    |
| `MidoriQuoteBar`    | `Special`    |
| `MidoriRule`        | `NonText`    |

## Mermaid

When a fence is tagged `mermaid` and `mermaid-ascii` is installed, the block is
rendered as ASCII art:

````markdown
```mermaid
graph TD
  A --> B
  B --> C
```
````

If the binary is missing, midori emits a one-shot `vim.notify` warning and shows
a placeholder block instead of erroring.

Install `mermaid-ascii`:

```sh
go install github.com/AlexanderGrooff/mermaid-ascii@latest
```

## Development

```sh
bash tests/run.sh   # luac -p + stylua --check + nvim --headless behavior
```

The behavior suite intentionally avoids Lua test frameworks; it shells out to
`nvim --headless -l tests/behavior.lua` and exits non-zero on any failed assert.

## License

MIT (see `LICENSE` once added).
