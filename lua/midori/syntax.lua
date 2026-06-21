-- midori.nvim treesitter-based code-block syntax highlighter.
-- Given (lang, body_lines), produce a list of column-range hl marks relative
-- to the body. Silently returns {} when the treesitter parser is unavailable
-- so the reader degrades gracefully.
local M = {}

local ALIAS = {
	js = "javascript",
	ts = "typescript",
	tsx = "tsx",
	jsx = "javascript",
	sh = "bash",
	shell = "bash",
	zsh = "bash",
	rs = "rust",
	py = "python",
	rb = "ruby",
	yml = "yaml",
	md = "markdown",
}

function M.resolve_lang(lang)
	if lang == nil or lang == "" then
		return nil
	end
	return ALIAS[lang] or lang
end

local function has_treesitter()
	return vim ~= nil and vim.treesitter ~= nil and vim.treesitter.get_string_parser ~= nil
end

local function lang_available(lang)
	if not has_treesitter() then
		return false
	end
	local ok, lang_mod = pcall(require, "vim.treesitter.language")
	if not ok then
		return false
	end
	local has_add = type(lang_mod.add) == "function"
	if has_add then
		local added = pcall(lang_mod.add, lang)
		if not added then
			return false
		end
	end
	-- highlights query must exist for us to do anything useful
	local q_ok, q = pcall(vim.treesitter.query.get, lang, "highlights")
	if not q_ok or q == nil then
		return false
	end
	return true
end

-- Return a list of marks {line, col_start, col_end, hl_group} relative to
-- the body (line 0-indexed, cols byte-indexed). Empty list on any failure.
function M.highlights(lang, body_lines)
	lang = M.resolve_lang(lang)
	if not lang or #body_lines == 0 then
		return {}
	end
	if not lang_available(lang) then
		return {}
	end
	local text = table.concat(body_lines, "\n")
	local ok, parser = pcall(vim.treesitter.get_string_parser, text, lang)
	if not ok or parser == nil then
		return {}
	end
	local trees = parser:parse()
	if not trees or not trees[1] then
		return {}
	end
	local root = trees[1]:root()
	local query = vim.treesitter.query.get(lang, "highlights")
	if not query then
		return {}
	end
	local marks = {}
	for id, node, _metadata in query:iter_captures(root, text, 0, -1) do
		local name = query.captures[id]
		local sr, sc, er, ec = node:range()
		if sr == er then
			marks[#marks + 1] = {
				line = sr,
				col_start = sc,
				col_end = ec,
				hl_group = "@" .. name,
			}
		else
			-- multi-line capture → emit per-line slices
			marks[#marks + 1] = {
				line = sr,
				col_start = sc,
				col_end = #body_lines[sr + 1],
				hl_group = "@" .. name,
			}
			for ln = sr + 1, er - 1 do
				marks[#marks + 1] = {
					line = ln,
					col_start = 0,
					col_end = #(body_lines[ln + 1] or ""),
					hl_group = "@" .. name,
				}
			end
			if ec > 0 then
				marks[#marks + 1] = {
					line = er,
					col_start = 0,
					col_end = ec,
					hl_group = "@" .. name,
				}
			end
		end
	end
	return marks
end

return M
