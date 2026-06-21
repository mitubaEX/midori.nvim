-- midori.nvim treesitter-based code-block syntax highlighter.
-- Given (lang, body_lines), produce a list of column-range hl marks relative
-- to the body. Silently returns {} when the treesitter parser is unavailable
-- so the reader degrades gracefully.
local M = {}

-- Fallback info-string aliases for when neovim's own language registry
-- (vim.treesitter.language.get_lang) doesn't know about them.
local ALIAS = {
	js = "javascript",
	ts = "typescript",
	tsx = "tsx",
	jsx = "javascript",
	sh = "bash",
	shell = "bash",
	shellscript = "bash",
	zsh = "bash",
	rs = "rust",
	py = "python",
	rb = "ruby",
	yml = "yaml",
	md = "markdown",
	ps1 = "powershell",
}

function M.resolve_lang(lang)
	if lang == nil or lang == "" then
		return nil
	end
	local lower = lang:lower()
	-- Honor neovim's language registry only when it actually maps to a
	-- different identifier (e.g. user-registered alias). It echoes the input
	-- back for unknown names, which would shadow our ALIAS table.
	local ok, ts_lang = pcall(function()
		return vim.treesitter.language.get_lang(lower)
	end)
	if ok and type(ts_lang) == "string" and ts_lang ~= "" and ts_lang ~= lower then
		return ts_lang
	end
	return ALIAS[lower] or lower
end

local function has_treesitter()
	return vim ~= nil and vim.treesitter ~= nil and vim.treesitter.get_string_parser ~= nil
end

-- Return a list of marks {line, col_start, col_end, hl_group} relative to
-- the body (line 0-indexed, cols byte-indexed). Empty list on any failure.
function M.highlights(lang, body_lines)
	lang = M.resolve_lang(lang)
	if not lang or #body_lines == 0 then
		return {}
	end
	if not has_treesitter() then
		return {}
	end
	local text = table.concat(body_lines, "\n")
	local ok, parser = pcall(vim.treesitter.get_string_parser, text, lang)
	if not ok or parser == nil then
		return {}
	end
	local ok_parse, trees = pcall(function()
		return parser:parse()
	end)
	if not ok_parse or not trees or not trees[1] then
		return {}
	end
	local root = trees[1]:root()
	local query = vim.treesitter.query.get(lang, "highlights")
	if not query then
		return {}
	end

	local function line_len(idx) -- idx is 0-based
		return #(body_lines[idx + 1] or "")
	end

	-- Clamp a (line, col_start, col_end) tuple to the actual line bytes.
	-- Returns nil when the slice degenerates to empty after clamping.
	local function clamp(line, col_start, col_end)
		local len = line_len(line)
		if col_start >= len then
			return nil
		end
		if col_end > len then
			col_end = len
		end
		if col_end <= col_start then
			return nil
		end
		return col_start, col_end
	end

	local marks = {}
	for id, node, _metadata in query:iter_captures(root, text, 0, -1) do
		local name = query.captures[id]
		local hl_group = "@" .. name .. "." .. lang
		local sr, sc, er, ec = node:range()
		if sr == er then
			local cs, ce = clamp(sr, sc, ec)
			if cs then
				marks[#marks + 1] = { line = sr, col_start = cs, col_end = ce, hl_group = hl_group }
			end
		else
			-- multi-line capture → emit per-line slices, each clamped to its line
			local cs, ce = clamp(sr, sc, line_len(sr))
			if cs then
				marks[#marks + 1] = { line = sr, col_start = cs, col_end = ce, hl_group = hl_group }
			end
			for ln = sr + 1, er - 1 do
				local mcs, mce = clamp(ln, 0, line_len(ln))
				if mcs then
					marks[#marks + 1] = { line = ln, col_start = mcs, col_end = mce, hl_group = hl_group }
				end
			end
			if ec > 0 then
				local ecs, ece = clamp(er, 0, ec)
				if ecs then
					marks[#marks + 1] = { line = er, col_start = ecs, col_end = ece, hl_group = hl_group }
				end
			end
		end
	end
	return marks
end

return M
