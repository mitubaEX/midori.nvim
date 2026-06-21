-- midori.nvim reader window/buffer manager.
local config = require("midori.config")
local parser = require("midori.parser")
local render = require("midori.render")
local highlights = require("midori.highlights")

local M = {}

local NS = vim.api.nvim_create_namespace("midori")

-- The reader buffer currently open (one at a time).
local state = { buf = nil, win = nil, source = nil, links = {} }

local function open_window(opts)
	local mode = opts.window or "vsplit"
	local buf = vim.api.nvim_create_buf(false, true)
	local win
	if mode == "vsplit" then
		vim.cmd("vsplit")
		win = vim.api.nvim_get_current_win()
		vim.api.nvim_win_set_buf(win, buf)
	elseif mode == "full" then
		win = vim.api.nvim_get_current_win()
		vim.api.nvim_win_set_buf(win, buf)
	elseif mode == "float" then
		local w = math.floor(vim.o.columns * (opts.width or 0.6))
		local h = math.floor(vim.o.lines * (opts.height or 0.85))
		win = vim.api.nvim_open_win(buf, true, {
			relative = "editor",
			width = w,
			height = h,
			row = math.floor((vim.o.lines - h) / 2),
			col = math.floor((vim.o.columns - w) / 2),
			style = "minimal",
			border = "rounded",
		})
	else
		error("midori: unknown window mode " .. tostring(mode))
	end
	return buf, win
end

local function apply_marks(buf, marks)
	for _, m in ipairs(marks) do
		if m.line_hl then
			vim.api.nvim_buf_set_extmark(buf, NS, m.line, 0, {
				line_hl_group = m.line_hl,
			})
		elseif m.col_start then
			vim.api.nvim_buf_set_extmark(buf, NS, m.line, m.col_start, {
				end_col = m.col_end,
				hl_group = m.hl_group,
			})
		end
	end
end

function M.open(source_buf)
	highlights.setup()
	source_buf = source_buf or vim.api.nvim_get_current_buf()
	local lines = vim.api.nvim_buf_get_lines(source_buf, 0, -1, false)
	local blocks = parser.parse(lines)
	local out = render.render(blocks)

	if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
		M.close()
	end

	local buf, win = open_window(config.options)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, out.lines)
	apply_marks(buf, out.marks)
	state.links = out.links or {}

	vim.bo[buf].filetype = "midori"
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].swapfile = false
	vim.bo[buf].modifiable = false
	vim.bo[buf].readonly = true
	vim.wo[win].wrap = true
	vim.wo[win].linebreak = true
	vim.wo[win].number = false
	vim.wo[win].relativenumber = false
	vim.wo[win].signcolumn = "no"
	vim.wo[win].cursorline = false
	vim.wo[win].foldcolumn = "0"

	vim.keymap.set("n", "q", function()
		M.close()
	end, { buffer = buf, nowait = true, silent = true, desc = "midori: close reader" })

	vim.keymap.set("n", "gx", function()
		local url = M.url_at_cursor()
		if url then
			if vim.ui and vim.ui.open then
				vim.ui.open(url)
			else
				vim.fn.system({ "open", url })
			end
		else
			vim.notify("midori: no link under cursor", vim.log.levels.INFO)
		end
	end, { buffer = buf, nowait = true, silent = true, desc = "midori: open URL under cursor" })

	state.buf = buf
	state.win = win
	state.source = source_buf
end

function M.close()
	if state.win and vim.api.nvim_win_is_valid(state.win) then
		pcall(vim.api.nvim_win_close, state.win, true)
	end
	if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
		pcall(vim.api.nvim_buf_delete, state.buf, { force = true })
	end
	state.buf, state.win, state.source, state.links = nil, nil, nil, {}
end

-- Return the URL covering the cursor in the reader buffer, or nil.
function M.url_at_cursor()
	if not state.win or not vim.api.nvim_win_is_valid(state.win) then
		return nil
	end
	local cur = vim.api.nvim_win_get_cursor(state.win)
	local row = cur[1] - 1
	local col = cur[2]
	for _, l in ipairs(state.links or {}) do
		if l.line == row and col >= l.col_start and col < l.col_end then
			return l.url
		end
	end
	return nil
end

function M.toggle()
	if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
		M.close()
	else
		M.open()
	end
end

return M
