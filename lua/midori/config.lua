-- midori.nvim configuration
local M = {}

M.defaults = {
	-- reader window style: "vsplit" | "full" | "float"
	window = "vsplit",
	-- fraction of editor width/height for float windows
	width = 0.6,
	height = 0.85,
	heading = {
		-- prefix icon per heading level (1..6); empty string = no prefix.
		-- defaults: color-only (matches the leaf-style preview look). Set
		-- e.g. { "▌", "▍", "▎", "▏", "┃", "│" } to bring icons back.
		icons = { "", "", "", "", "", "" },
		-- horizontal-rule char per heading level. Set "" to disable for a level.
		rules = { "━", "─", "", "", "", "" },
	},
	code = {
		border = true,
		line_numbers = true,
		syntax = true,
	},
	mermaid = {
		enabled = true,
		-- override the binary; nil = use whatever is on $PATH ("mermaid-ascii")
		bin = nil,
	},
	watch = {
		enabled = true,
	},
	-- width of the horizontal rule rendering
	rule_width = 60,
}

M.options = vim.deepcopy(M.defaults)

function M.setup(opts)
	M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
	return M.options
end

return M
