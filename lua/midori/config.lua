-- midori.nvim configuration
local M = {}

M.defaults = {
	-- reader window style:
	--   "vsplit" — open in a vertical split (default)
	--   "full"   — open in a new tabpage (true full-screen)
	--   "float"  — floating window sized by `width` / `height`
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
		-- Line numbers OFF by default — they add a left gutter that pushes the
		-- syntax-highlighted body and can clutter narrow reader windows.
		-- Set to true to bring back the "<n>   <code>" gutter.
		line_numbers = false,
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
