-- midori.nvim line-based markdown parser (dependency-free).
-- Input:  list of raw lines (strings)
-- Output: list of blocks, each a table with a `kind` field:
--   { kind = "heading", level = 1..6, text = "..." }
--   { kind = "code", lang = "lua"|nil, lines = { ... } }
--   { kind = "quote", lines = { ...inner text... } }
--   { kind = "list_item", ordered = bool, marker = "-"|"3", indent = N, text = "..." }
--   { kind = "rule" }
--   { kind = "blank" }
--   { kind = "para", text = "..." }
local M = {}

local function heading(line)
	local hashes, rest = line:match("^(#+)%s+(.*)$")
	if hashes and #hashes <= 6 then
		return { kind = "heading", level = #hashes, text = rest }
	end
end

local function is_rule(line)
	local s = line:gsub("%s", "")
	if #s < 3 then
		return false
	end
	local c = s:sub(1, 1)
	if c ~= "-" and c ~= "*" and c ~= "_" then
		return false
	end
	return s == string.rep(c, #s)
end

local function list_item(line)
	local indent, marker, text = line:match("^(%s*)([-*+])%s+(.*)$")
	if marker then
		return { kind = "list_item", ordered = false, marker = marker, indent = #indent, text = text }
	end
	local oindent, num, otext = line:match("^(%s*)(%d+)[.)]%s+(.*)$")
	if num then
		return { kind = "list_item", ordered = true, marker = num, indent = #oindent, text = otext }
	end
end

local function fence(line)
	local f, lang = line:match("^%s*(```+)%s*(%S*)")
	if not f then
		f, lang = line:match("^%s*(~~~+)%s*(%S*)")
	end
	return f, lang
end

local function is_close_fence(line)
	return line:match("^%s*```+%s*$") ~= nil or line:match("^%s*~~~+%s*$") ~= nil
end

function M.parse(lines)
	local blocks = {}
	local i, n = 1, #lines
	while i <= n do
		local line = lines[i]
		local f, lang = fence(line)
		if f then
			local body = {}
			i = i + 1
			while i <= n and not is_close_fence(lines[i]) do
				body[#body + 1] = lines[i]
				i = i + 1
			end
			i = i + 1 -- consume closing fence (or run past EOF)
			blocks[#blocks + 1] = { kind = "code", lang = (lang ~= "" and lang) or nil, lines = body }
		elseif line:match("^%s*>") then
			local qlines = {}
			while i <= n and lines[i]:match("^%s*>") do
				qlines[#qlines + 1] = (lines[i]:gsub("^%s*>%s?", ""))
				i = i + 1
			end
			blocks[#blocks + 1] = { kind = "quote", lines = qlines }
		else
			local block = heading(line)
			if not block and is_rule(line) then
				block = { kind = "rule" }
			end
			if not block then
				block = list_item(line)
			end
			if not block then
				if line:match("^%s*$") then
					block = { kind = "blank" }
				else
					block = { kind = "para", text = line }
				end
			end
			blocks[#blocks + 1] = block
			i = i + 1
		end
	end
	return blocks
end

return M
