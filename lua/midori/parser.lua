-- midori.nvim line-based markdown parser (dependency-free).
-- Input:  list of raw lines (strings)
-- Output: list of blocks, each a table with a `kind` field:
--   { kind = "heading", level = 1..6, text = "..." }
--   { kind = "code", lang = "lua"|nil, lines = { ... } }
--   { kind = "quote", lines = { ...inner text... } }
--   { kind = "list_item", ordered = bool, marker = "-"|"3",
--                         indent = N, text = "...", checkbox = nil|"open"|"done" }
--   { kind = "table", headers = {"H1",...}, aligns = {"left"|"right"|"center",...},
--                     rows = { {"c1","c2",...}, ... } }
--   { kind = "frontmatter", fields = { title = "...", date = "...", ... } }
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

local function detect_checkbox(text)
	local box, rest = text:match("^%[([ xX])%]%s+(.*)$")
	if not box then
		return nil, text
	end
	if box == "x" or box == "X" then
		return "done", rest
	end
	return "open", rest
end

local function list_item(line)
	local indent, marker, text = line:match("^(%s*)([-*+])%s+(.*)$")
	if marker then
		local checkbox, body = detect_checkbox(text)
		return {
			kind = "list_item",
			ordered = false,
			marker = marker,
			indent = #indent,
			text = body,
			checkbox = checkbox,
		}
	end
	local oindent, num, otext = line:match("^(%s*)(%d+)[.)]%s+(.*)$")
	if num then
		local checkbox, body = detect_checkbox(otext)
		return {
			kind = "list_item",
			ordered = true,
			marker = num,
			indent = #oindent,
			text = body,
			checkbox = checkbox,
		}
	end
end

local function fence(line)
	local f, lang = line:match("^%s*(```+)%s*(%S*)")
	if not f then
		f, lang = line:match("^%s*(~~~+)%s*(%S*)")
	end
	return f, lang
end

local function is_close_fence(line, opener)
	local ch = opener:sub(1, 1)
	local run = line:match("^%s*(" .. ch .. "+)%s*$")
	return run ~= nil and #run >= #opener
end

-- "| a | b | c |" → {"a","b","c"}; strips edge pipes and surrounding spaces.
local function split_pipes(line)
	local s = line:match("^%s*(.-)%s*$") or ""
	s = s:gsub("^|", ""):gsub("|$", "")
	local cells = {}
	for cell in (s .. "|"):gmatch("([^|]*)|") do
		cells[#cells + 1] = cell:match("^%s*(.-)%s*$")
	end
	return cells
end

local function is_table_separator_row(line)
	if not line:match("^%s*|") then
		return false
	end
	local cells = split_pipes(line)
	if #cells == 0 then
		return false
	end
	for _, c in ipairs(cells) do
		if not c:match("^:?%-+:?$") then
			return false
		end
	end
	return true
end

local function align_of(cell)
	local l = cell:sub(1, 1) == ":"
	local r = cell:sub(-1) == ":"
	if l and r then
		return "center"
	end
	if r then
		return "right"
	end
	return "left"
end

-- Try to consume a table starting at `i`. Returns (block, next_i) or nil.
local function try_table(lines, i, n)
	local first = lines[i]
	if not first:match("^%s*|") then
		return nil
	end
	local sep = lines[i + 1]
	if not sep or not is_table_separator_row(sep) then
		return nil
	end
	local headers = split_pipes(first)
	local seps = split_pipes(sep)
	local aligns = {}
	for _, c in ipairs(seps) do
		aligns[#aligns + 1] = align_of(c)
	end
	local rows = {}
	local j = i + 2
	while j <= n and lines[j]:match("^%s*|") do
		rows[#rows + 1] = split_pipes(lines[j])
		j = j + 1
	end
	return { kind = "table", headers = headers, aligns = aligns, rows = rows }, j
end

-- Try to consume a YAML frontmatter block starting at line 1.
local function try_frontmatter(lines, n)
	if lines[1] ~= "---" then
		return nil
	end
	for j = 2, n do
		if lines[j] == "---" then
			local fields = {}
			for k = 2, j - 1 do
				local key, val = lines[k]:match("^([%w_%-]+)%s*:%s*(.-)%s*$")
				if key then
					-- strip surrounding quotes if any
					val = val:gsub("^[\"']", ""):gsub("[\"']$", "")
					fields[key] = val
				end
			end
			return { kind = "frontmatter", fields = fields }, j + 1
		end
	end
	return nil
end

function M.parse(lines)
	local blocks = {}
	local i, n = 1, #lines

	local fm, fm_next = try_frontmatter(lines, n)
	if fm then
		blocks[#blocks + 1] = fm
		i = fm_next
	end

	while i <= n do
		local line = lines[i]
		local f, lang = fence(line)
		if f then
			local body = {}
			i = i + 1
			while i <= n and not is_close_fence(lines[i], f) do
				body[#body + 1] = lines[i]
				i = i + 1
			end
			i = i + 1
			blocks[#blocks + 1] = { kind = "code", lang = (lang ~= "" and lang) or nil, lines = body }
		elseif line:match("^%s*>") then
			local qlines = {}
			while i <= n and lines[i]:match("^%s*>") do
				qlines[#qlines + 1] = (lines[i]:gsub("^%s*>%s?", ""))
				i = i + 1
			end
			blocks[#blocks + 1] = { kind = "quote", lines = qlines }
		else
			local tbl, after = try_table(lines, i, n)
			if tbl then
				blocks[#blocks + 1] = tbl
				i = after
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
	end
	return blocks
end

return M
