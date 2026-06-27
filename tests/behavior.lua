-- Behavior tests for midori.nvim
-- Run from repo root: nvim --headless -u NONE -l tests/behavior.lua
-- Exits nonzero on any failure (red/green driver, no test framework).

local repo = vim.fn.getcwd()
vim.opt.runtimepath:append(repo)

local failures = {}
local function check(cond, msg)
	if cond then
		print("  ok  - " .. msg)
	else
		failures[#failures + 1] = msg
		print("  FAIL- " .. msg)
	end
end

local sample = {
	"# Title",
	"",
	"Some **bold** and `code` text.",
	"",
	"- item one",
	"- item two",
	"",
	"> a quote line",
	"",
	"```lua",
	'print("hi")',
	"```",
	"",
	"---",
}

-- ---- parser ----
local parser = require("midori.parser")
local blocks = parser.parse(sample)
local function find(kind)
	for _, b in ipairs(blocks) do
		if b.kind == kind then
			return b
		end
	end
end

local h = find("heading")
check(h and h.level == 1 and h.text == "Title", "heading: level 1, text 'Title'")
local code = find("code")
check(code and code.lang == "lua", "code: fence language is 'lua'")
check(code and #code.lines == 1 and code.lines[1] == 'print("hi")', "code: body line captured")

-- ---- parser: fence nesting (CommonMark: closer must match opener char & length) ----
do
	-- 4-backtick opener with an inner 3-backtick line — inner line is body, not closer.
	local nested = parser.parse({
		"````markdown",
		"```mermaid",
		"graph TD",
		"```",
		"````",
		"after",
	})
	local first_code, after_para
	for _, b in ipairs(nested) do
		if not first_code and b.kind == "code" then
			first_code = b
		elseif first_code and b.kind == "para" then
			after_para = after_para or b
		end
	end
	check(first_code and first_code.lang == "markdown", "code: 4-backtick fence keeps 'markdown' lang")
	check(
		first_code and #first_code.lines == 3 and first_code.lines[3] == "```",
		"code: 4-backtick fence captures inner 3-backtick lines as body"
	)
	check(after_para ~= nil, "code: 4-backtick fence closes on matching ```` and yields trailing paragraph")
end

do
	-- Backtick opener must NOT be closed by a tilde line (and vice versa).
	local mixed = parser.parse({ "```", "body", "~~~", "still body", "```" })
	local c
	for _, b in ipairs(mixed) do
		if b.kind == "code" then
			c = b
			break
		end
	end
	check(c and #c.lines == 3, "code: backtick fence not closed by ~~~ line")
end

check(find("rule") ~= nil, "rule: horizontal rule parsed")
check(find("quote") ~= nil, "quote: blockquote parsed")
local li = find("list_item")
check(li and li.text == "item one" and li.ordered == false, "list: unordered item parsed")

-- ---- parser: tables ----
local table_blocks = parser.parse({
	"| Name | Lang |",
	"|------|:----:|",
	"| midori | Lua |",
	"| leaf   | Rust |",
})
local tbl = nil
for _, b in ipairs(table_blocks) do
	if b.kind == "table" then
		tbl = b
		break
	end
end
check(tbl ~= nil, "parser: table block detected")
check(tbl and #tbl.headers == 2 and tbl.headers[1] == "Name", "parser: table headers parsed")
check(tbl and #tbl.rows == 2 and tbl.rows[1][1] == "midori", "parser: table rows parsed")
check(tbl and tbl.aligns and tbl.aligns[2] == "center", "parser: table align ':---:' = center")

-- ---- parser: task checkbox ----
local task_blocks = parser.parse({ "- [ ] todo one", "- [x] done one" })
local opens, dones = 0, 0
for _, b in ipairs(task_blocks) do
	if b.kind == "list_item" and b.checkbox == "open" then
		opens = opens + 1
	elseif b.kind == "list_item" and b.checkbox == "done" then
		dones = dones + 1
	end
end
check(opens == 1 and dones == 1, "parser: task checkboxes (open/done)")

-- ---- parser: frontmatter ----
local fm_blocks = parser.parse({
	"---",
	"title: My Doc",
	"date: 2026-06-21",
	"---",
	"# Body",
})
local fm = nil
for _, b in ipairs(fm_blocks) do
	if b.kind == "frontmatter" then
		fm = b
		break
	end
end
check(fm ~= nil, "parser: frontmatter block captured")
check(fm and fm.fields and fm.fields.title == "My Doc", "parser: frontmatter title field")
-- frontmatter must consume the --- lines (no spurious rule before # Body)
local first_after = fm_blocks[2] -- index 1 is frontmatter, 2 should be heading
check(first_after and first_after.kind == "heading", "parser: frontmatter consumes both --- delimiters")

-- ---- render ----
local render = require("midori.render")
-- The shared `blocks` sample includes a fenced code block whose inner-gutter
-- checks below assume line numbers are ON. Default is OFF, so opt in here.
require("midori.config").setup({ code = { line_numbers = true } })
local out = render.render(blocks)
local joined = table.concat(out.lines, "\n")
check(not joined:find("%*%*bold%*%*"), "render: bold markers '**' stripped")
check(joined:find("bold") ~= nil, "render: bold text retained")
check(not joined:find("`code`"), "render: inline code backticks stripped")
local has_h1 = false
for _, m in ipairs(out.marks) do
	if m.line_hl == "MidoriH1" then
		has_h1 = true
	end
end
check(has_h1, "render: H1 line highlight emitted")
check(joined:find("^▌") == nil, "render: default heading uses no icon prefix")
local has_h1_rule = false
local has_h2_rule = false
for _, m in ipairs(out.marks) do
	if m.line_hl == "MidoriH1Rule" then
		has_h1_rule = true
	elseif m.line_hl == "MidoriH2Rule" then
		has_h2_rule = true
	end
end
check(has_h1_rule, "render: H1 underline (━) emitted")
-- add an H2 sample to test rule emission for H2 too
local h2_blocks = parser.parse({ "## Section", "body" })
local h2_out = render.render(h2_blocks)
for _, m in ipairs(h2_out.marks) do
	if m.line_hl == "MidoriH2Rule" then
		has_h2_rule = true
	end
end
check(has_h2_rule, "render: H2 underline (─) emitted")
check(joined:find("╭") ~= nil and joined:find("╰") ~= nil, "render: code block frame drawn")
check(joined:find("lua") ~= nil, "render: code language label present")
-- the inner '│' between line number and code body should be gone (now whitespace gutter)
check(joined:find("1 │ print") == nil, "render: code body no inner '│' separator")
check(joined:find("1   print") ~= nil, "render: code body uses whitespace gutter '<n>   <code>'")

-- ---- render: tables ----
local tout = render.render(table_blocks)
local tjoined = table.concat(tout.lines, "\n")
check(tjoined:find("┌") ~= nil and tjoined:find("┐") ~= nil, "render: table top border drawn")
check(tjoined:find("├") ~= nil and tjoined:find("┤") ~= nil, "render: table separator drawn")
check(tjoined:find("└") ~= nil and tjoined:find("┘") ~= nil, "render: table bottom border drawn")
check(tjoined:find("midori") and tjoined:find("Lua"), "render: table cell content preserved")

-- ---- render: tasks ----
local task_out = render.render(task_blocks)
local task_joined = table.concat(task_out.lines, "\n")
check(task_joined:find("☐") ~= nil, "render: open task uses ☐")
check(task_joined:find("☑") ~= nil, "render: done task uses ☑")
local has_done_dim = false
for _, m in ipairs(task_out.marks) do
	if m.line_hl == "MidoriTaskDoneText" then
		has_done_dim = true
	end
end
check(has_done_dim, "render: done task line gets MidoriTaskDoneText line_hl")

-- ---- render: links ----
local link_blocks = parser.parse({ "See [docs](https://example.com/d) and [api](http://e.com/a) okay." })
local lout = render.render(link_blocks)
local ljoined = table.concat(lout.lines, "\n")
check(ljoined:find("docs") ~= nil and ljoined:find("api") ~= nil, "render: link text preserved")
check(ljoined:find("↗") ~= nil, "render: link arrow icon shown")
check(ljoined:find("https://example.com") == nil, "render: link URL hidden from display")
check(type(lout.links) == "table" and #lout.links == 2, "render: link table captured (2 entries)")
check(lout.links[1] and lout.links[1].url == "https://example.com/d", "render: first link URL recorded as user_data")

-- image: ![alt](path)
local img_blocks = parser.parse({ "An ![logo](./logo.png) here." })
local iout = render.render(img_blocks)
local ijoined = table.concat(iout.lines, "\n")
check(ijoined:find("image:") ~= nil, "render: image becomes [image: …]")
check(ijoined:find("logo") ~= nil, "render: image alt text preserved")
check(ijoined:find("!%[") == nil, "render: image '![' syntax stripped")

-- ---- render: frontmatter ----
local fm_out = render.render(fm_blocks)
local fm_joined = table.concat(fm_out.lines, "\n")
check(fm_joined:find("My Doc") ~= nil, "render: frontmatter title shown in card")
check(fm_joined:find("title") ~= nil, "render: frontmatter shows the 'title' key label")
local has_fm_hl = false
for _, m in ipairs(fm_out.marks) do
	if m.line_hl == "MidoriFrontmatter" then
		has_fm_hl = true
	end
end
check(has_fm_hl, "render: frontmatter card line_hl emitted")

-- ---- render: document header ----
local hb = render.render({ { kind = "para", text = "body" } }, { title = "foo", ft = "markdown" })
local hb_joined = table.concat(hb.lines, "\n")
check(hb_joined:find("foo") ~= nil, "render: doc header includes title 'foo'")
check(hb_joined:find("markdown") ~= nil, "render: doc header includes filetype tag")
-- unnamed (no title) skips the header entirely
local hb_skip = render.render({ { kind = "para", text = "body" } }, { title = "", ft = "markdown" })
check(hb_skip.lines[1] == "body", "render: doc header skipped when title is empty")

-- ---- regression: word-boundary underscore in headings/text ----
local ub = render.render(parser.parse({ "# nvim_lua_config" }))
local ub_joined = table.concat(ub.lines, "\n")
check(ub_joined:find("nvim_lua_config") ~= nil, "render: intra-word '_' is NOT eaten as italic marker")

-- ---- regression: code block top border width matches body / bottom ----
local cw = render.render(parser.parse({ "```text", "sh setup.sh", "```" }))
local top_w = vim.fn.strdisplaywidth(cw.lines[1])
local bot_w = vim.fn.strdisplaywidth(cw.lines[#cw.lines])
check(top_w == bot_w, ("render: code block top width == bottom width (%d == %d)"):format(top_w, bot_w))

-- ---- regression: code block right border aligned for multibyte body lines ----
-- Body contains Japanese / en-dash / box-drawing — bytes(>cols), so byte-based
-- width math leaves the right '│' drifting left on those lines. Every frame
-- line MUST have the same DISPLAY width.
do
	local mb = render.render(parser.parse({
		"```text",
		"ascii only line",
		"日本語 を含む行 — em dash も",
		"▌▍▎ box drawing chars",
		"```",
	}))
	local w0 = vim.fn.strdisplaywidth(mb.lines[1])
	local all_equal = true
	local bad
	for _, l in ipairs(mb.lines) do
		if vim.fn.strdisplaywidth(l) ~= w0 then
			all_equal = false
			bad = l
			break
		end
	end
	check(
		all_equal,
		("render: code block frame lines share display width (got %s ≠ %d)"):format(
			bad and tostring(vim.fn.strdisplaywidth(bad)) or "?",
			w0
		)
	)
end

-- ---- regression: table right border aligned for multibyte cells ----
-- Same byte-vs-display-width bug class as the code block. Cells containing
-- en-dash / Japanese / fullwidth chars overshoot in bytes, so byte-based
-- widths[c] + byte-based pad_cell leaves the right '│' drifting left on
-- multibyte rows. Every rendered table line MUST share the same display width.
do
	local tb = render.render(parser.parse({
		"| Group | Default |",
		"|-------|---------|",
		"| `H1`–`H2` | `Title` |",
		"| `Bold`    | `(bold)` |",
		"| 日本語見出し | `Normal` |",
	}))
	local table_lines = {}
	for _, l in ipairs(tb.lines) do
		if l:find("[┌├└│]") then
			table_lines[#table_lines + 1] = l
		end
	end
	local w0 = vim.fn.strdisplaywidth(table_lines[1])
	local all_equal, bad = true, nil
	for _, l in ipairs(table_lines) do
		if vim.fn.strdisplaywidth(l) ~= w0 then
			all_equal = false
			bad = l
			break
		end
	end
	check(
		all_equal,
		("render: table frame lines share display width (got %s ≠ %d)"):format(
			bad and tostring(vim.fn.strdisplaywidth(bad)) or "?",
			w0
		)
	)
end

-- ---- regression: viewport fit (narrow vsplit) ----
-- When the reader window is narrow, the rendered frame (code/table/rule/doc
-- header) must fit within the viewport. Otherwise Neovim soft-wraps the line
-- and the trailing '│' drops to a new visual line — boxes break visually.
do
	local long_body = "this is a very very very very long line that overflows narrow windows"
	local out = render.render(
		parser.parse({
			"```text",
			long_body,
			"short",
			"```",
		}),
		nil,
		{ viewport = 30 }
	)
	local max_w = 0
	for _, l in ipairs(out.lines) do
		local w = vim.fn.strdisplaywidth(l)
		if w > max_w then
			max_w = w
		end
	end
	check(max_w <= 30, ("render: viewport=30 caps every line width (got %d)"):format(max_w))
	-- the long body line must end with '… │' (truncation marker + right border)
	local has_ellipsis_line = false
	for _, l in ipairs(out.lines) do
		if l:sub(-#"… │") == "… │" then
			has_ellipsis_line = true
			break
		end
	end
	check(has_ellipsis_line, "render: truncated code body ends with '… │'")
end

-- viewport caps doc header / rule width too
do
	local out = render.render(
		parser.parse({ "para", "", "---" }),
		{ title = "longtitle", ft = "markdown" },
		{ viewport = 20 }
	)
	local max_w = 0
	for _, l in ipairs(out.lines) do
		local w = vim.fn.strdisplaywidth(l)
		if w > max_w then
			max_w = w
		end
	end
	check(max_w <= 20, ("render: viewport=20 caps doc header / rule width (got %d)"):format(max_w))
end

-- viewport caps table width
do
	local out = render.render(
		parser.parse({
			"| Group | Default |",
			"|-------|---------|",
			"| Very long heading name | Very long default value |",
		}),
		nil,
		{ viewport = 28 }
	)
	local max_w = 0
	for _, l in ipairs(out.lines) do
		local w = vim.fn.strdisplaywidth(l)
		if w > max_w then
			max_w = w
		end
	end
	check(max_w <= 28, ("render: viewport=28 caps table width (got %d)"):format(max_w))
end

-- backward compat: no viewport => same output as before
do
	local a = render.render(parser.parse({ "```text", "hello", "```" }))
	local b = render.render(parser.parse({ "```text", "hello", "```" }), nil, {})
	check(#a.lines == #b.lines, "render: omitting render_opts is equivalent to {}")
	local same = true
	for i, l in ipairs(a.lines) do
		if l ~= b.lines[i] then
			same = false
			break
		end
	end
	check(same, "render: omitting render_opts produces identical lines")
end

-- ---- syntax (treesitter) ----
local syntax = require("midori.syntax")
-- module loads even without parsers; missing parser → returns empty list, no throw
local ok, marks = pcall(syntax.highlights, "lua", { 'print("hi")' })
check(ok, "syntax: highlights() does not throw when parser is missing")
check(type(marks) == "table", "syntax: highlights() returns a table")
-- alias resolution
check(syntax.resolve_lang("ts") == "typescript", "syntax: alias 'ts' resolves to 'typescript'")
check(syntax.resolve_lang("sh") == "bash", "syntax: alias 'sh' resolves to 'bash'")
check(syntax.resolve_lang("lua") == "lua", "syntax: unknown alias falls through")

-- resolve_lang must prefer vim.treesitter.language.get_lang() (so users can
-- register custom aliases via vim.treesitter.language.register())
do
	local orig = vim.treesitter.language.get_lang
	vim.treesitter.language.get_lang = function(name)
		if name == "totally-fake-lang" then
			return "lua"
		end
	end
	local resolved = syntax.resolve_lang("totally-fake-lang")
	vim.treesitter.language.get_lang = orig
	check(resolved == "lua", "syntax: resolve_lang() honors vim.treesitter.language.get_lang()")
end

-- when a parser IS available (lua is bundled with nvim), marks should use the
-- namespaced @<capture>.<lang> highlight-group form and stay within line bounds.
do
	local body = { "local x = 1", "short" }
	local m = syntax.highlights("lua", body)
	if #m > 0 then
		local has_ns = false
		local within_bounds = true
		for _, mark in ipairs(m) do
			if type(mark.hl_group) == "string" and mark.hl_group:match("^@.+%.lua$") then
				has_ns = true
			end
			local line_len = #(body[mark.line + 1] or "")
			if mark.col_end > line_len or mark.col_start < 0 then
				within_bounds = false
			end
		end
		check(has_ns, "syntax: marks use @<capture>.<lang> namespaced group")
		check(within_bounds, "syntax: marks stay within body line bounds")
	else
		print("  skip - syntax: namespaced groups (no lua parser available)")
	end
end

-- ---- config: code.line_numbers default is OFF ----
do
	-- isolate from earlier tests that may have mutated the default config
	require("midori.config").setup({})
	local cb = parser.parse({ "```bash", "echo hi", "```" })
	local cout = render.render(cb)
	local cjoined = table.concat(cout.lines, "\n")
	check(cjoined:find("1   echo") == nil, "config: code.line_numbers default OFF — no '1   ' gutter")
	check(cjoined:find("echo hi") ~= nil, "config: body content still rendered when line numbers are off")
end

-- ---- syntax: vim-runtime fallback (bash etc. have no bundled TS parser) ----
do
	local bash_marks = syntax.highlights("bash", { "echo hi", "ls -l" })
	check(
		type(bash_marks) == "table" and #bash_marks > 0,
		"syntax: bash fallback emits marks via vim builtin syntax (no TS parser)"
	)
	local sh_marks = syntax.highlights("sh", { 'if [ -z "$x" ]; then echo "x"; fi' })
	check(#sh_marks > 0, "syntax: 'sh' alias also resolves through fallback")
	-- fallback marks must stay within their source-line byte bounds
	local body = { "echo hi", "ls -l" }
	local within = true
	for _, m in ipairs(bash_marks) do
		local llen = #(body[m.line + 1] or "")
		if m.col_start < 0 or m.col_end > llen or m.col_end <= m.col_start then
			within = false
		end
	end
	check(within, "syntax: fallback marks stay within line bounds")
end

-- ---- render: bash code block ends up with col-range marks (real reader path) ----
do
	local rblocks = parser.parse({ "```bash", "echo hi", "```" })
	local rout = render.render(rblocks)
	local has_color = false
	for _, m in ipairs(rout.marks) do
		if m.hl_group and m.col_start and m.hl_group ~= "MidoriCodeLang" and m.hl_group ~= "MidoriCodeLineNr" then
			has_color = true
		end
	end
	check(has_color, "render: bash code block emits col-range syntax marks")

	-- regression: syntax marks must align with the actual token bytes inside
	-- the bordered body line. The border prefix is "│ " which is 4 bytes in
	-- UTF-8 (│ = U+2502 = 3 bytes), not 2 — earlier code mis-offset marks by
	-- 2 bytes and painted the trailing byte of │ + bled colors across tokens.
	local body_line
	for _, l in ipairs(rout.lines) do
		if l:find("echo") then
			body_line = l
			break
		end
	end
	check(body_line ~= nil, "render: bordered body line containing 'echo' exists")
	local body_idx
	for i, l in ipairs(rout.lines) do
		if l == body_line then
			body_idx = i - 1
			break
		end
	end
	local first
	for _, m in ipairs(rout.marks) do
		if
			m.line == body_idx
			and m.col_start
			and m.hl_group
			and m.hl_group ~= "MidoriCodeLang"
			and m.hl_group ~= "MidoriCodeLineNr"
			and m.hl_group ~= "MidoriCodeBlock"
		then
			first = m
			break
		end
	end
	check(first ~= nil, "render: at least one syntax mark on the body line")
	if first then
		local seg = body_line:sub(first.col_start + 1, first.col_end)
		-- The very first byte of the highlighted slice must NOT be a border
		-- byte (│ = 0xE2 0x94 0x82). A trailing 0x82 here means we mis-aligned
		-- the prefix length and started inside the box-drawing char.
		local first_byte = string.byte(seg, 1)
		check(first_byte ~= 0x82, "render: first syntax mark doesn't start inside the │ border bytes")
		-- And the slice should be ASCII (the bash token), not contain box chars.
		check(not seg:find("│"), "render: first syntax mark doesn't span the │ border")
	end
end

-- ---- mermaid ----
local mermaid = require("midori.mermaid")
local available = mermaid.is_available()
check(type(available) == "boolean", "mermaid: is_available() returns bool")
local mblocks = parser.parse({ "```mermaid", "graph TD", "A-->B", "```" })
local mout = render.render(mblocks)
local mjoined = table.concat(mout.lines, "\n")
if available then
	check(mjoined:find("placeholder") == nil, "mermaid: when installed, no placeholder marker")
	-- regression: every rendered frame line must have the same display width,
	-- so the right border aligns with ╮/╯ even when the body contains
	-- box-drawing chars (multi-byte UTF-8 wider in bytes than columns).
	local widths_equal = true
	local first_w = vim.fn.strdisplaywidth(mout.lines[1])
	for _, l in ipairs(mout.lines) do
		if vim.fn.strdisplaywidth(l) ~= first_w then
			widths_equal = false
			break
		end
	end
	check(widths_equal, "mermaid: every frame line has equal display width (right border aligned)")
else
	check(
		mjoined:find("%[mermaid: not installed%]") ~= nil,
		"mermaid: placeholder marker shown when mermaid-ascii missing"
	)
	-- source is preserved inside the placeholder block so the user can still read it
	check(mjoined:find("graph TD") ~= nil, "mermaid: original source preserved in placeholder")
end

-- ---- view / :MidoriView command ----
vim.cmd("runtime plugin/midori.lua")
vim.api.nvim_buf_set_lines(0, 0, -1, false, sample)
vim.cmd("MidoriView")
local rbuf = vim.api.nvim_get_current_buf()
check(vim.bo[rbuf].filetype == "midori", "view: reader buffer filetype=midori")
check(vim.bo[rbuf].modifiable == false, "view: reader buffer is read-only")
check(#vim.api.nvim_buf_get_lines(rbuf, 0, -1, false) > 1, "view: reader buffer populated")

-- ---- view: url_at_cursor ----
require("midori").close()
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "See [docs](https://example.com/d) here." })
vim.cmd("MidoriView")
local view = require("midori.view")
-- cursor on "docs" (position around col 5) should return the URL
vim.api.nvim_win_set_cursor(0, { 1, 6 })
check(view.url_at_cursor() == "https://example.com/d", "view: gx (url_at_cursor) finds URL on link text")
-- cursor on "here" should return nil
vim.api.nvim_win_set_cursor(0, { 1, 28 })
check(view.url_at_cursor() == nil, "view: url_at_cursor returns nil outside any link")

-- ---- view: refresh re-renders from current source ----
require("midori").close()
local src_buf = vim.api.nvim_create_buf(false, false)
vim.api.nvim_buf_set_lines(src_buf, 0, -1, false, { "# First" })
vim.api.nvim_set_current_buf(src_buf)
vim.cmd("MidoriView")
local reader_before = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
check(reader_before:find("First") ~= nil, "view: initial render shows 'First'")
-- mutate source then refresh
vim.api.nvim_buf_set_lines(src_buf, 0, -1, false, { "# Second" })
view.refresh()
local reader_after = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
check(reader_after:find("Second") ~= nil, "view: refresh() re-renders updated source")
check(reader_after:find("First") == nil, "view: refresh() clears stale content")

-- ---- view: full window mode opens reader in a new tab ----
require("midori").close()
require("midori.config").setup({ window = "full" })
local src_full = vim.api.nvim_create_buf(false, false)
vim.api.nvim_buf_set_lines(src_full, 0, -1, false, { "# full mode" })
vim.api.nvim_set_current_buf(src_full)
local src_tab = vim.api.nvim_get_current_tabpage()
vim.cmd("MidoriView")
local reader_tab = vim.api.nvim_get_current_tabpage()
check(reader_tab ~= src_tab, "view: full mode opens reader in a NEW tabpage")
check(vim.bo[vim.api.nvim_get_current_buf()].filetype == "midori", "view: full-mode reader buffer ft=midori")
check(#vim.api.nvim_tabpage_list_wins(reader_tab) == 1, "view: full-mode tab contains only the reader window")
require("midori").close()
check(not vim.tbl_contains(vim.api.nvim_list_tabpages(), reader_tab), "view: closing full-mode reader removes its tab")
-- restore default window mode for any later tests
require("midori.config").setup({ window = "vsplit" })

-- ---- view: TOC ----
require("midori").close()
local toc_buf = vim.api.nvim_create_buf(false, false)
vim.api.nvim_buf_set_lines(toc_buf, 0, -1, false, { "# Alpha", "para", "## Beta", "more", "### Gamma" })
vim.api.nvim_set_current_buf(toc_buf)
vim.cmd("MidoriView")
local items = view.toc_items()
check(type(items) == "table" and #items == 3, "view: toc_items returns 3 headings")
check(items[1].text == "Alpha" and items[1].level == 1, "view: first TOC item is 'Alpha' (H1)")
check(items[3].level == 3, "view: third TOC item is H3")
vim.cmd("MidoriToc")
local tbuf = vim.api.nvim_get_current_buf()
check(vim.bo[tbuf].filetype == "midori-toc", "view: TOC buffer filetype=midori-toc")
local toc_lines = vim.api.nvim_buf_get_lines(tbuf, 0, -1, false)
check(#toc_lines >= 3 and table.concat(toc_lines, "\n"):find("Alpha"), "view: TOC buffer lists headings")

-- ---- highlights: MidoriCodeBlock must not define fg ----
-- Code block bodies receive `line_hl_group = "MidoriCodeBlock"`. If that group
-- carries an explicit fg (e.g. via `link = "Normal"`), it wins over the
-- per-token col-range hl_groups emitted by syntax.highlights() and every byte
-- in the block ends up the same color. The group must stay fg-less so token
-- color shines through.
do
	require("midori.highlights").setup()
	local hl = vim.api.nvim_get_hl(0, { name = "MidoriCodeBlock", link = false })
	check(
		hl.fg == nil and hl.ctermfg == nil,
		"highlights: MidoriCodeBlock does not define fg (keeps token color visible)"
	)
end

-- ---- browser / :MidoriBrowse ----
-- File picker that lists markdown files under a directory (glow-style) and
-- opens the selected one in the midori reader. v1: flat recursive list,
-- excludes common heavy dirs (.git, node_modules, …), no incremental filter.
do
	require("midori").close()
	local tmp = vim.fn.tempname()
	vim.fn.mkdir(tmp .. "/nested", "p")
	vim.fn.mkdir(tmp .. "/.git", "p")
	vim.fn.mkdir(tmp .. "/node_modules", "p")
	vim.fn.writefile({ "# Alpha", "body a" }, tmp .. "/a.md")
	vim.fn.writefile({ "# Beta", "body b" }, tmp .. "/nested/b.md")
	vim.fn.writefile({ "# Hidden" }, tmp .. "/.git/c.md")
	vim.fn.writefile({ "# Ignored" }, tmp .. "/node_modules/d.md")
	vim.fn.writefile({ "not md" }, tmp .. "/e.txt")

	local browser = require("midori.browser")
	local files = browser.list_files(tmp)
	local has = {}
	for _, f in ipairs(files) do
		has[f] = true
	end
	check(has["a.md"], "browser: list_files returns top-level a.md")
	check(has["nested/b.md"], "browser: list_files recurses into nested/b.md")
	check(not has[".git/c.md"], "browser: list_files excludes .git/")
	check(not has["node_modules/d.md"], "browser: list_files excludes node_modules/")
	check(not has["e.txt"], "browser: list_files excludes non-markdown files")

	check(type(require("midori").browse) == "function", "browser: midori.browse is a function")

	-- :MidoriBrowse opens a picker buffer in a float and lists the files
	vim.cmd("MidoriBrowse " .. tmp)
	local bbuf = vim.api.nvim_get_current_buf()
	check(vim.bo[bbuf].filetype == "midori-browse", "browser: picker buffer filetype=midori-browse")
	local blines = vim.api.nvim_buf_get_lines(bbuf, 0, -1, false)
	local found_a, row_a = false, nil
	for i, l in ipairs(blines) do
		if l == "a.md" then
			found_a = true
			row_a = i
		end
	end
	check(found_a, "browser: picker shows a.md in the list")

	-- _select(row) opens that file in the reader (proxy for <CR>)
	if row_a then
		browser._select(row_a)
		local cur = vim.api.nvim_get_current_buf()
		check(vim.bo[cur].filetype == "midori", "browser: _select(row) opens reader for that file")
		local body = table.concat(vim.api.nvim_buf_get_lines(cur, 0, -1, false), "\n")
		check(body:find("Alpha") ~= nil, "browser: reader shows content of selected file")
	end
	require("midori").close()
end

-- gitignore-aware listing: files matching .gitignore (incl. global ignore /
-- .git/info/exclude) must NOT appear in the picker even if no name-based
-- EXCLUDE_DIRS entry covers them. Implemented via `git ls-files`.
do
	if vim.fn.executable("git") == 1 then
		require("midori").close()
		local tmp = vim.fn.tempname()
		vim.fn.mkdir(tmp .. "/ignored", "p")
		vim.fn.mkdir(tmp .. "/.worktrees/wt", "p")
		vim.fn.writefile({ "# Top" }, tmp .. "/a.md")
		vim.fn.writefile({ "# Hidden" }, tmp .. "/ignored/x.md")
		vim.fn.writefile({ "# Worktree" }, tmp .. "/.worktrees/wt/y.md")
		vim.fn.writefile({ "ignored/", ".worktrees/" }, tmp .. "/.gitignore")
		vim.fn.system({ "git", "-C", tmp, "init", "-q" })
		local browser = require("midori.browser")
		-- bust the require cache so the new implementation is loaded fresh
		local files = browser.list_files(tmp)
		local has = {}
		for _, f in ipairs(files) do
			has[f] = true
		end
		check(has["a.md"], "browser: gitignore — non-ignored a.md included")
		check(not has["ignored/x.md"], "browser: gitignore — ignored/ contents excluded")
		check(not has[".worktrees/wt/y.md"], "browser: gitignore — .worktrees/ contents excluded")
	end
end

-- ---- summary ----
if #failures > 0 then
	io.stderr:write(("\n%d test(s) FAILED\n"):format(#failures))
	os.exit(1)
end
print("\nALL PASS")
os.exit(0)
