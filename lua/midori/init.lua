-- midori.nvim — public API.
-- A reader-only markdown viewer inspired by leaf (https://leaf.rivolink.mg).
local config = require("midori.config")
local highlights = require("midori.highlights")
local view = require("midori.view")

local M = {}

function M.setup(opts)
	config.setup(opts)
	highlights.setup()
end

function M.open()
	view.open()
end

function M.close()
	view.close()
end

function M.toggle()
	view.toggle()
end

function M.toc()
	view.open_toc()
end

function M.refresh()
	view.refresh()
end

function M.browse(opts)
	require("midori.browser").open(opts)
end

return M
