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
check(joined:find("╭") ~= nil and joined:find("╰") ~= nil, "render: code block frame drawn")
check(joined:find("lua") ~= nil, "render: code language label present")

-- ---- render: tables ----
local tout = render.render(table_blocks)
local tjoined = table.concat(tout.lines, "\n")
check(tjoined:find("┌") ~= nil and tjoined:find("┐") ~= nil, "render: table top border drawn")
check(tjoined:find("├") ~= nil and tjoined:find("┤") ~= nil, "render: table separator drawn")
check(tjoined:find("└") ~= nil and tjoined:find("┘") ~= nil, "render: table bottom border drawn")
check(tjoined:find("midori") and tjoined:find("Lua"), "render: table cell content preserved")

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

-- ---- mermaid ----
local mermaid = require("midori.mermaid")
local available = mermaid.is_available()
check(type(available) == "boolean", "mermaid: is_available() returns bool")
local mblocks = parser.parse({ "```mermaid", "graph TD", "A-->B", "```" })
local mout = render.render(mblocks)
local mjoined = table.concat(mout.lines, "\n")
if available then
	check(mjoined:find("placeholder") == nil, "mermaid: when installed, no placeholder marker")
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

-- ---- summary ----
if #failures > 0 then
	io.stderr:write(("\n%d test(s) FAILED\n"):format(#failures))
	os.exit(1)
end
print("\nALL PASS")
os.exit(0)
