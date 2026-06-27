-- midori.nvim file browser — glow-style picker.
-- Lists markdown files under a directory (recursive) and opens the selected
-- one in the midori reader. No external deps (no telescope/fzf).
local config = require("midori.config")
local view = require("midori.view")

local M = {}

local EXCLUDE_DIRS = {
	[".git"] = true,
	["node_modules"] = true,
	[".venv"] = true,
	["venv"] = true,
	[".direnv"] = true,
	[".cache"] = true,
	["__pycache__"] = true,
	["dist"] = true,
	["build"] = true,
	["target"] = true,
}

local function is_markdown(name)
	return name:sub(-3) == ".md" or name:sub(-9) == ".markdown"
end

local function walk(root, rel, results)
	local base = rel == "" and root or (root .. "/" .. rel)
	local handle = vim.uv.fs_scandir(base)
	if not handle then
		return
	end
	while true do
		local name, t = vim.uv.fs_scandir_next(handle)
		if not name then
			break
		end
		local sub_rel = rel == "" and name or (rel .. "/" .. name)
		if t == "directory" then
			if not EXCLUDE_DIRS[name] then
				walk(root, sub_rel, results)
			end
		elseif t == "file" or t == "link" then
			if is_markdown(name) then
				results[#results + 1] = sub_rel
			end
		end
	end
end

function M.list_files(dir)
	dir = vim.fn.fnamemodify(dir or vim.fn.getcwd(), ":p"):gsub("/+$", "")
	local results = {}
	walk(dir, "", results)
	table.sort(results)
	return results
end

local state = {
	buf = nil,
	win = nil,
	dir = nil,
	files = {},
}

local function close_window()
	if state.win and vim.api.nvim_win_is_valid(state.win) then
		pcall(vim.api.nvim_win_close, state.win, true)
	end
	state.win = nil
	state.buf = nil
end

local function set_lines(buf, lines)
	vim.bo[buf].modifiable = true
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].modifiable = false
end

local function display_lines(files)
	if #files == 0 then
		return { "(no markdown files found)" }
	end
	return files
end

function M._select(row)
	if not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then
		return
	end
	row = row or vim.api.nvim_win_get_cursor(0)[1]
	local rel = state.files[row]
	if not rel then
		return
	end
	local full = state.dir .. "/" .. rel
	close_window()
	local source_buf = vim.fn.bufadd(full)
	vim.fn.bufload(source_buf)
	if vim.bo[source_buf].filetype == "" then
		vim.bo[source_buf].filetype = "markdown"
	end
	view.open(source_buf)
end

function M._refresh()
	if not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then
		return
	end
	state.files = M.list_files(state.dir)
	set_lines(state.buf, display_lines(state.files))
end

local function open_window(buf, opts)
	local mode = opts.window or (config.options.browse and config.options.browse.window) or "float"
	if mode == "float" then
		local w =
			math.floor(vim.o.columns * (opts.width or (config.options.browse and config.options.browse.width) or 0.6))
		local h =
			math.floor(vim.o.lines * (opts.height or (config.options.browse and config.options.browse.height) or 0.7))
		return vim.api.nvim_open_win(buf, true, {
			relative = "editor",
			width = w,
			height = h,
			row = math.floor((vim.o.lines - h) / 2),
			col = math.floor((vim.o.columns - w) / 2),
			style = "minimal",
			border = "rounded",
		})
	elseif mode == "vsplit" then
		vim.cmd("vsplit")
		local win = vim.api.nvim_get_current_win()
		vim.api.nvim_win_set_buf(win, buf)
		return win
	elseif mode == "full" then
		vim.cmd("tabnew")
		local win = vim.api.nvim_get_current_win()
		vim.api.nvim_win_set_buf(win, buf)
		return win
	end
	error("midori: unknown browser window mode " .. tostring(mode))
end

function M.open(opts)
	opts = opts or {}
	local dir = vim.fn.fnamemodify(opts.dir or vim.fn.getcwd(), ":p"):gsub("/+$", "")

	close_window()

	local files = M.list_files(dir)
	local buf = vim.api.nvim_create_buf(false, true)
	set_lines(buf, display_lines(files))
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].swapfile = false
	vim.bo[buf].filetype = "midori-browse"

	local win = open_window(buf, opts)
	vim.wo[win].cursorline = true
	vim.wo[win].number = false
	vim.wo[win].relativenumber = false
	vim.wo[win].signcolumn = "no"
	vim.wo[win].wrap = false

	state.buf = buf
	state.win = win
	state.dir = dir
	state.files = files

	local km = function(lhs, fn, desc)
		vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, silent = true, desc = desc })
	end
	km("<CR>", function()
		M._select()
	end, "midori: open file under cursor")
	km("q", close_window, "midori: close browser")
	km("<Esc>", close_window, "midori: close browser")
	km("r", M._refresh, "midori: refresh file list")

	return buf, win
end

return M
