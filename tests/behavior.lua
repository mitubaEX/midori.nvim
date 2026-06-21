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
