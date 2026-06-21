-- midori.nvim highlight groups. Linked to standard groups so user themes apply.
local M = {}

-- name -> default link target
M.links = {
	MidoriH1 = "Title",
	MidoriH2 = "Title",
	MidoriH3 = "Function",
	MidoriH4 = "Function",
	MidoriH5 = "Identifier",
	MidoriH6 = "Identifier",
	MidoriInlineCode = "String",
	MidoriCodeBorder = "Comment",
	MidoriCodeLang = "Special",
	MidoriCodeLineNr = "LineNr",
	MidoriCodeBlock = "CursorLine",
	MidoriBullet = "Special",
	MidoriQuote = "Comment",
	MidoriQuoteBar = "Special",
	MidoriRule = "NonText",
	MidoriH1Rule = "Title",
	MidoriH2Rule = "Comment",
	MidoriTableBorder = "Comment",
	MidoriTableHeader = "Title",
	MidoriTableCell = "Normal",
	MidoriTaskOpen = "Special",
	MidoriTaskDone = "Comment",
	MidoriTaskDoneText = "Comment",
	MidoriLink = "Underlined",
	MidoriLinkIcon = "Special",
	MidoriFrontmatter = "Comment",
	MidoriFrontmatterKey = "Identifier",
	MidoriTocHeading = "Special",
}

function M.setup()
	for name, link in pairs(M.links) do
		vim.api.nvim_set_hl(0, name, { link = link, default = true })
	end
	-- attribute-based groups (do not depend on a theme defining Bold/Italic)
	vim.api.nvim_set_hl(0, "MidoriBold", { bold = true, default = true })
	vim.api.nvim_set_hl(0, "MidoriItalic", { italic = true, default = true })
	vim.api.nvim_set_hl(0, "MidoriStrike", { strikethrough = true, default = true })
end

return M
