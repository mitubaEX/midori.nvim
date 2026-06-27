-- midori.nvim plugin entry — registers :MidoriView (and friends).
if vim.g.loaded_midori == 1 then
	return
end
vim.g.loaded_midori = 1

vim.api.nvim_create_user_command("MidoriView", function()
	require("midori").open()
end, { desc = "Open midori reader for the current buffer" })

vim.api.nvim_create_user_command("MidoriClose", function()
	require("midori").close()
end, { desc = "Close midori reader" })

vim.api.nvim_create_user_command("MidoriToggle", function()
	require("midori").toggle()
end, { desc = "Toggle midori reader" })

vim.api.nvim_create_user_command("MidoriToc", function()
	require("midori").toc()
end, { desc = "Open midori TOC sidebar" })

vim.api.nvim_create_user_command("MidoriRefresh", function()
	require("midori").refresh()
end, { desc = "Re-render the midori reader" })

vim.api.nvim_create_user_command("MidoriBrowse", function(o)
	local dir = o.args ~= "" and o.args or nil
	require("midori").browse({ dir = dir })
end, {
	nargs = "?",
	complete = "dir",
	desc = "Browse markdown files under [dir] (default: cwd)",
})
