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
	local r = { ok = true, lines = rlines }
	cache[src] = r
	return r
end

-- Test/setup hook: clear caches (used between tests).
function M._reset()
	warned = {}
	cache = {}
end

return M
