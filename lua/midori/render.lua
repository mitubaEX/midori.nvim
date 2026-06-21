-- midori.nvim renderer.
-- Input:  blocks (from parser)
-- Output: { lines = { string, ... }, marks = { mark, ... } }
--   mark = {
--     line = 0-indexed buffer line,
--     col_start = nil | 0-indexed byte,
--     col_end   = nil | 0-indexed byte (exclusive),
--     hl_group  = "MidoriBold"  -- column-range hl, when col_start set
--     line_hl   = "MidoriH1"    -- whole-line hl, when col_start nil
--   }
local config = require("midori.config")
local syntax = require("midori.syntax")
local mermaid = require("midori.mermaid")

local M = {}

local INLINE_PATTERNS = {
	{ name = "code", left = "`", right = "`", hl = "MidoriInlineCode" },
	{ name = "strong", left = "**", right = "**", hl = "MidoriBold" },
	{ name = "strong_us", left = "__", right = "__", hl = "MidoriBold" },
	{ name = "strike", left = "~~", right = "~~", hl = "MidoriStrike" },
	{ name = "em", left = "*", right = "*", hl = "MidoriItalic" },
	{ name = "em_us", left = "_", right = "_", hl = "MidoriItalic" },
}

-- Strip a single inline marker pair anywhere in `text` and emit a column-range
-- highlight span over the unwrapped inner content.
-- Returns: stripped_text, list_of_spans { {col_start, col_end, hl_group}, ... }
local function strip_inline(text)
	local spans = {}
	local out = text
	local guard = 0
	while guard < 64 do
		guard = guard + 1
		local hit = nil
		for _, p in ipairs(INLINE_PATTERNS) do
			local ls, le = out:find(p.left, 1, true)
			if ls then
				local rs, re = out:find(p.right, le + 1, true)
				if rs and rs > le + 1 then
					if hit == nil or ls < hit.ls then
						hit = { ls = ls, le = le, rs = rs, re = re, p = p }
					end
				end
			end
		end
		if not hit then
			break
		end
		local inner = out:sub(hit.le + 1, hit.rs - 1)
		local before = out:sub(1, hit.ls - 1)
		local after = out:sub(hit.re + 1)
		local col_start = #before
		local col_end = col_start + #inner
		spans[#spans + 1] = { col_start = col_start, col_end = col_end, hl_group = hit.p.hl }
		out = before .. inner .. after
	end
	return out, spans
end

local function add_inline_marks(marks, line_idx, text)
	local stripped, spans = strip_inline(text)
	for _, s in ipairs(spans) do
		marks[#marks + 1] = {
			line = line_idx,
			col_start = s.col_start,
			col_end = s.col_end,
			hl_group = s.hl_group,
		}
	end
	return stripped
end

local function emit_heading(lines, marks, block, opts)
	local icon = opts.heading.icons[block.level] or ""
	local stripped, spans = strip_inline(block.text)
	local prefix = icon .. " "
	local line = prefix .. stripped
	local idx = #lines
	lines[#lines + 1] = line
	marks[#marks + 1] = { line = idx, line_hl = "MidoriH" .. block.level }
	for _, s in ipairs(spans) do
		marks[#marks + 1] = {
			line = idx,
			col_start = s.col_start + #prefix,
			col_end = s.col_end + #prefix,
			hl_group = s.hl_group,
		}
	end
end

local function emit_para(lines, marks, block)
	local stripped = add_inline_marks(marks, #lines, block.text)
	lines[#lines + 1] = stripped
	-- patch the col offsets we just added — strip_inline returned 0-based
	-- offsets into `stripped`, which match the buffer column directly.
end

local function emit_list_item(lines, marks, block)
	local indent = string.rep("  ", math.floor(block.indent / 2))
	local bullet = block.ordered and (block.marker .. ".") or "•"
	local prefix = indent .. bullet .. " "
	local idx = #lines
	local stripped, spans = strip_inline(block.text)
	lines[#lines + 1] = prefix .. stripped
	marks[#marks + 1] = {
		line = idx,
		col_start = #indent,
		col_end = #indent + #bullet,
		hl_group = "MidoriBullet",
	}
	for _, s in ipairs(spans) do
		marks[#marks + 1] = {
			line = idx,
			col_start = s.col_start + #prefix,
			col_end = s.col_end + #prefix,
			hl_group = s.hl_group,
		}
	end
end

local function emit_quote(lines, marks, block)
	for _, qline in ipairs(block.lines) do
		local idx = #lines
		local stripped, spans = strip_inline(qline)
		local prefix = "▎ "
		lines[#lines + 1] = prefix .. stripped
		marks[#marks + 1] = {
			line = idx,
			col_start = 0,
			col_end = #prefix - 1,
			hl_group = "MidoriQuoteBar",
		}
		marks[#marks + 1] = { line = idx, line_hl = "MidoriQuote" }
		for _, s in ipairs(spans) do
			marks[#marks + 1] = {
				line = idx,
				col_start = s.col_start + #prefix,
				col_end = s.col_end + #prefix,
				hl_group = s.hl_group,
			}
		end
	end
end

local function emit_rule(lines, marks, opts)
	local w = opts.rule_width or 60
	local idx = #lines
	lines[#lines + 1] = string.rep("─", w)
	marks[#marks + 1] = { line = idx, line_hl = "MidoriRule" }
end

local function emit_framed_block(lines, marks, label, body_lines)
	local longest = #label + 4
	for _, l in ipairs(body_lines) do
		if #l > longest then
			longest = #l
		end
	end
	local inner = math.max(longest, 20)
	-- top border with embedded label
	local llabel = label ~= "" and (" " .. label .. " ") or ""
	local top = "╭─" .. llabel .. string.rep("─", inner - #llabel - 1) .. "╮"
	local idx = #lines
	lines[#lines + 1] = top
	marks[#marks + 1] = { line = idx, line_hl = "MidoriCodeBorder" }
	if llabel ~= "" then
		marks[#marks + 1] = {
			line = idx,
			col_start = 2,
			col_end = 2 + #llabel,
			hl_group = "MidoriCodeLang",
		}
	end
	for _, bl in ipairs(body_lines) do
		local pad = inner - #bl
		if pad < 0 then
			pad = 0
		end
		local li = #lines
		lines[#lines + 1] = "│ " .. bl .. string.rep(" ", pad) .. " │"
		marks[#marks + 1] = { line = li, line_hl = "MidoriCodeBlock" }
	end
	local bi = #lines
	lines[#lines + 1] = "╰" .. string.rep("─", inner + 2) .. "╯"
	marks[#marks + 1] = { line = bi, line_hl = "MidoriCodeBorder" }
end

local function emit_mermaid(lines, marks, block, opts)
	local enabled = (opts.mermaid or {}).enabled
	if enabled == false then
		return false
	end
	local result = mermaid.render(block.lines)
	if result.ok then
		emit_framed_block(lines, marks, "mermaid", result.lines)
		return true
	end
	-- placeholder: show a marker + the original source so it's still readable
	local body = { "[mermaid: not installed]", "" }
	for _, l in ipairs(block.lines) do
		body[#body + 1] = l
	end
	emit_framed_block(lines, marks, "mermaid", body)
	return true
end

local function emit_code(lines, marks, block, opts)
	local lang = block.lang or ""
	local body = block.lines or {}
	local nr_width = 0
	if opts.code.line_numbers then
		nr_width = #tostring(#body)
		if nr_width < 1 then
			nr_width = 1
		end
	end

	-- inner width: longest body line (after line number gutter)
	local longest = 0
	for _, l in ipairs(body) do
		if #l > longest then
			longest = #l
		end
	end
	local label = lang ~= "" and (" " .. lang .. " ") or ""
	local inner = math.max(longest + (nr_width > 0 and (nr_width + 3) or 0), #label + 4)
	inner = math.max(inner, 20)

	if opts.code.border then
		local top = "╭─" .. label .. string.rep("─", inner - #label - 1) .. "╮"
		local idx = #lines
		lines[#lines + 1] = top
		marks[#marks + 1] = { line = idx, line_hl = "MidoriCodeBorder" }
		if lang ~= "" then
			-- highlight the language label inside the top border
			local lstart = 2
			marks[#marks + 1] = {
				line = idx,
				col_start = lstart,
				col_end = lstart + #label,
				hl_group = "MidoriCodeLang",
			}
		end
	end

	local body_start_idx = #lines
	for i, bl in ipairs(body) do
		local prefix = ""
		if opts.code.line_numbers then
			prefix = string.format("%" .. nr_width .. "d │ ", i)
		end
		local content = prefix .. bl
		local pad = inner - #content
		if pad < 0 then
			pad = 0
		end
		local idx = #lines
		local line
		if opts.code.border then
			line = "│ " .. content .. string.rep(" ", pad) .. " │"
		else
			line = content
		end
		lines[#lines + 1] = line
		marks[#marks + 1] = { line = idx, line_hl = "MidoriCodeBlock" }
		if opts.code.line_numbers and opts.code.border then
			marks[#marks + 1] = {
				line = idx,
				col_start = 2,
				col_end = 2 + nr_width,
				hl_group = "MidoriCodeLineNr",
			}
		end
	end

	-- treesitter syntax overlay (optional, silently skipped if parser missing)
	if opts.code.syntax and lang ~= "" then
		local body_prefix_len = (opts.code.border and 2 or 0) + (opts.code.line_numbers and (nr_width + 3) or 0)
		local syntax_marks = syntax.highlights(lang, body)
		for _, m in ipairs(syntax_marks) do
			marks[#marks + 1] = {
				line = body_start_idx + m.line,
				col_start = m.col_start + body_prefix_len,
				col_end = m.col_end + body_prefix_len,
				hl_group = m.hl_group,
			}
		end
	end

	if opts.code.border then
		local bot = "╰" .. string.rep("─", inner + 2) .. "╯"
		local idx = #lines
		lines[#lines + 1] = bot
		marks[#marks + 1] = { line = idx, line_hl = "MidoriCodeBorder" }
	end
end

function M.render(blocks)
	local opts = config.options
	local lines, marks = {}, {}
	for _, block in ipairs(blocks) do
		if block.kind == "heading" then
			emit_heading(lines, marks, block, opts)
		elseif block.kind == "para" then
			emit_para(lines, marks, block)
		elseif block.kind == "list_item" then
			emit_list_item(lines, marks, block)
		elseif block.kind == "quote" then
			emit_quote(lines, marks, block)
		elseif block.kind == "rule" then
			emit_rule(lines, marks, opts)
		elseif block.kind == "code" then
			if block.lang == "mermaid" and emit_mermaid(lines, marks, block, opts) then
				-- handled
			else
				emit_code(lines, marks, block, opts)
			end
		elseif block.kind == "blank" then
			lines[#lines + 1] = ""
		end
	end
	return { lines = lines, marks = marks }
end

return M
