-- midori.nvim mermaid block renderer.
-- Pipes the source through `mermaid-ascii` (https://github.com/AlexanderGrooff/mermaid-ascii)
-- and returns the ASCII diagram lines, or a placeholder when the binary is
-- missing or the call errored. We warn at most once per binary per session.
local config = require("midori.config")

local M = {}

local warned = {}
local cache = {}

local function bin()
	local b = (config.options.mermaid or {}).bin
	if b and b ~= "" then
		return b
	end
	return "mermaid-ascii"
end

local function warn_once(b, msg)
	if warned[b] then
		return
	end
	warned[b] = true
	if vim and vim.schedule and vim.notify then
		vim.schedule(function()
			vim.notify("midori.nvim: " .. msg, vim.log.levels.WARN)
		end)
	end
end

function M.is_available()
	if not (vim and vim.fn and vim.fn.executable) then
		return false
	end
	return vim.fn.executable(bin()) == 1
end

-- mermaid-ascii lays out columns by counting RUNES, not display columns. Each
-- 2-col wide char (e.g. CJK) on a label line therefore leaks one extra space
-- into the buffer to "catch up" to the next anchor — shifting that line right
-- of the borders above/below it. We compensate by removing one space from the
-- next ≥2-space run for every leaked column, preserving 1-space box padding.
local function realign_line(line)
	if not (vim and vim.fn and vim.fn.strdisplaywidth) then
		return line
	end
	local dw = vim.fn.strdisplaywidth
	local out = {}
	local owed = 0
	local i = 1
	local n = #line
	while i <= n do
		local b = line:byte(i)
		local clen
		if b < 0x80 then
			clen = 1
		elseif b < 0xc0 then
			clen = 1
		elseif b < 0xe0 then
			clen = 2
		elseif b < 0xf0 then
			clen = 3
		else
			clen = 4
		end
		if b == 0x20 then
			local j = i
			while j <= n and line:byte(j) == 0x20 do
				j = j + 1
			end
			local run = j - i
			if owed > 0 and run >= 2 then
				local rm = math.min(run - 1, owed)
				run = run - rm
				owed = owed - rm
			end
			out[#out + 1] = string.rep(" ", run)
			i = j
		else
			local ch = line:sub(i, i + clen - 1)
			local cw = dw(ch)
			if cw > 1 then
				owed = owed + (cw - 1)
			end
			out[#out + 1] = ch
			i = i + clen
		end
	end
	return table.concat(out)
end

function M._realign_widths(lines)
	local out = {}
	for k, l in ipairs(lines) do
		out[k] = realign_line(l)
	end
	return out
end

-- Synchronously render `lines` (a list of strings, the mermaid source) into
-- a list of ASCII lines via mermaid-ascii. Returns:
--   { ok = true,  lines = { ... } }
--   { ok = false, reason = "missing" | "error", message = "..." }
function M.render(lines)
	local b = bin()
	local src = table.concat(lines, "\n")
	if cache[src] then
		return cache[src]
	end
	if not M.is_available() then
		warn_once(b, ("'%s' not found on $PATH — mermaid blocks shown as placeholder"):format(b))
		local r = { ok = false, reason = "missing", message = b .. " not found" }
		cache[src] = r
		return r
	end
	-- mermaid-ascii reads file path via -f -; pass via stdin using vim.fn.system
	local out = vim.fn.system({ b, "-f", "/dev/stdin" }, src)
	if vim.v.shell_error ~= 0 then
		local r = { ok = false, reason = "error", message = (out or ""):gsub("\n+$", "") }
		cache[src] = r
		return r
	end
	local rlines = {}
	for line in (out .. "\n"):gmatch("([^\n]*)\n") do
		rlines[#rlines + 1] = line
	end
	-- drop a single trailing empty line that gmatch tends to leave behind
	if #rlines > 0 and rlines[#rlines] == "" then
		rlines[#rlines] = nil
	end
	local r = { ok = true, lines = M._realign_widths(rlines) }
	cache[src] = r
	return r
end

-- Test/setup hook: clear caches (used between tests).
function M._reset()
	warned = {}
	cache = {}
end

return M
