-- midori.nvim renderer.
-- Input:  blocks (from parser)
-- Output: { lines = { string, ... }, marks = { mark, ... }, links = { link, ... } }
--   mark = {
--     line = 0-indexed buffer line,
--     col_start = nil | 0-indexed byte,
--     col_end   = nil | 0-indexed byte (exclusive),
--     hl_group  = "MidoriBold"  -- column-range hl, when col_start set
--     line_hl   = "MidoriH1"    -- whole-line hl, when col_start nil
--   }
--   link = { line, col_start, col_end, url }
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

local LINK_ARROW = " ↗"

-- Find inline markdown links [text](url) and inline images ![alt](path), and
-- rewrite them in the source string. Returns: (rewritten_text, link_specs)
-- link_spec = { col_start, col_end, hl_group, url=string|nil }
local function extract_links(text)
	local out = {}
	local specs = {}
	local i, n = 1, #text
	while i <= n do
		local image = text:sub(i, i + 1) == "!["
		local lbracket = image and text:sub(i, i + 1) or text:sub(i, i)
		if (image and lbracket == "![") or (not image and lbracket == "[") then
			local search_from = image and (i + 2) or (i + 1)
			local close = text:find("]", search_from, true)
			if close and text:sub(close + 1, close + 1) == "(" then
				local rparen = text:find(")", close + 2, true)
				if rparen then
					local inner_text = text:sub(search_from, close - 1)
					local url = text:sub(close + 2, rparen - 1)
					if image then
						local replacement = "[image: " .. inner_text .. " — " .. url .. "]"
						local cs = #table.concat(out)
						out[#out + 1] = replacement
						specs[#specs + 1] = {
							col_start = cs,
							col_end = cs + #replacement,
							hl_group = "MidoriLink",
						}
					else
						local replacement = inner_text .. LINK_ARROW
						local cs = #table.concat(out)
						out[#out + 1] = replacement
						specs[#specs + 1] = {
							col_start = cs,
							col_end = cs + #inner_text,
							hl_group = "MidoriLink",
							url = url,
						}
						specs[#specs + 1] = {
							col_start = cs + #inner_text,
							col_end = cs + #replacement,
							hl_group = "MidoriLinkIcon",
						}
					end
					i = rparen + 1
				else
					out[#out + 1] = text:sub(i, i)
					i = i + 1
				end
			else
				out[#out + 1] = text:sub(i, i)
				i = i + 1
			end
		else
			out[#out + 1] = text:sub(i, i)
			i = i + 1
		end
	end
	return table.concat(out), specs
end

-- Strip a single inline marker pair anywhere in `text` and emit a column-range
-- highlight span over the unwrapped inner content. Skips ranges that overlap
-- protected spans (e.g. link text already processed).
local function strip_inline(text, protected)
	protected = protected or {}
	local function in_protected(pos)
		for _, r in ipairs(protected) do
			if pos >= r.col_start and pos < r.col_end then
				return true
			end
		end
		return false
	end
	local spans = {}
	local out = text
	local guard = 0
	while guard < 64 do
		guard = guard + 1
		local hit = nil
		for _, p in ipairs(INLINE_PATTERNS) do
			local from = 1
			while true do
				local ls, le = out:find(p.left, from, true)
				if not ls then
					break
				end
				if not in_protected(ls - 1) then
					local rs, re = out:find(p.right, le + 1, true)
					if rs and rs > le + 1 and not in_protected(rs - 1) then
						if hit == nil or ls < hit.ls then
							hit = { ls = ls, le = le, rs = rs, re = re, p = p }
						end
					end
					break
				end
				from = le + 1
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
		-- shift protected ranges past the removed marker characters
		local removed = (hit.le - hit.ls + 1) + (hit.re - hit.rs + 1)
		for _, r in ipairs(protected) do
			if r.col_start >= hit.re then
				r.col_start = r.col_start - removed
				r.col_end = r.col_end - removed
			elseif r.col_start >= hit.le then
				r.col_start = r.col_start - (hit.le - hit.ls + 1)
				r.col_end = r.col_end - (hit.le - hit.ls + 1)
			end
		end
		out = before .. inner .. after
	end
	return out, spans
end

-- Process a single inline string for both links and markers, append marks and
-- links to the accumulators, and return the final visible text.
local function process_inline(text, line_idx, col_offset, marks, links)
	local after_links, link_specs = extract_links(text)
	-- copy specs into a mutable list strip_inline can adjust
	local protected = {}
	for _, s in ipairs(link_specs) do
		protected[#protected + 1] = { col_start = s.col_start, col_end = s.col_end, _spec = s }
	end
	local final, marker_spans = strip_inline(after_links, protected)
	-- emit link spans (with adjusted positions) and url records
	for i, s in ipairs(link_specs) do
		local r = protected[i]
		marks[#marks + 1] = {
			line = line_idx,
			col_start = r.col_start + col_offset,
			col_end = r.col_end + col_offset,
			hl_group = s.hl_group,
		}
		if s.url and links then
			links[#links + 1] = {
				line = line_idx,
				col_start = r.col_start + col_offset,
				col_end = r.col_end + col_offset,
				url = s.url,
			}
		end
	end
	for _, s in ipairs(marker_spans) do
		marks[#marks + 1] = {
			line = line_idx,
			col_start = s.col_start + col_offset,
			col_end = s.col_end + col_offset,
			hl_group = s.hl_group,
		}
	end
	return final
end

local function emit_heading(lines, marks, links, block, opts)
	local icon = opts.heading.icons[block.level] or ""
	local prefix = icon == "" and "" or (icon .. " ")
	local idx = #lines
	local visible = process_inline(block.text, idx, #prefix, marks, links)
	lines[#lines + 1] = prefix .. visible
	marks[#marks + 1] = { line = idx, line_hl = "MidoriH" .. block.level }

	-- H1 / H2 get an underline rule. H3..H6 are color-only.
	local rule_width = math.max(#prefix + #visible, opts.rule_width or 60)
	local rule_chars = opts.heading.rules or { "━", "─" }
	local rule_char = rule_chars[block.level]
	if rule_char and rule_char ~= "" then
		local ridx = #lines
		lines[#lines + 1] = string.rep(rule_char, rule_width)
		marks[#marks + 1] = { line = ridx, line_hl = "MidoriH" .. block.level .. "Rule" }
	end
end

local function emit_para(lines, marks, links, block)
	local idx = #lines
	local visible = process_inline(block.text, idx, 0, marks, links)
	lines[#lines + 1] = visible
end

local function emit_list_item(lines, marks, links, block)
	local indent = string.rep("  ", math.floor(block.indent / 2))
	local bullet
	local bullet_hl = "MidoriBullet"
	if block.checkbox == "open" then
		bullet = "☐"
		bullet_hl = "MidoriTaskOpen"
	elseif block.checkbox == "done" then
		bullet = "☑"
		bullet_hl = "MidoriTaskDone"
	else
		bullet = block.ordered and (block.marker .. ".") or "•"
	end
	local prefix = indent .. bullet .. " "
	local idx = #lines
	local visible = process_inline(block.text, idx, #prefix, marks, links)
	lines[#lines + 1] = prefix .. visible
	marks[#marks + 1] = {
		line = idx,
		col_start = #indent,
		col_end = #indent + #bullet,
		hl_group = bullet_hl,
	}
	if block.checkbox == "done" then
		marks[#marks + 1] = { line = idx, line_hl = "MidoriTaskDoneText" }
	end
end

local function emit_quote(lines, marks, links, block)
	for _, qline in ipairs(block.lines) do
		local prefix = "▎ "
		local idx = #lines
		local visible = process_inline(qline, idx, #prefix, marks, links)
		lines[#lines + 1] = prefix .. visible
		marks[#marks + 1] = {
			line = idx,
			col_start = 0,
			col_end = #prefix - 1,
			hl_group = "MidoriQuoteBar",
		}
		marks[#marks + 1] = { line = idx, line_hl = "MidoriQuote" }
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

local function pad_cell(text, width, align)
	local space = width - #text
	if space <= 0 then
		return text
	end
	if align == "right" then
		return string.rep(" ", space) .. text
	elseif align == "center" then
		local left = math.floor(space / 2)
		local right = space - left
		return string.rep(" ", left) .. text .. string.rep(" ", right)
	end
	return text .. string.rep(" ", space)
end

local function emit_table(lines, marks, block)
	local headers = block.headers or {}
	local aligns = block.aligns or {}
	local rows = block.rows or {}
	local ncols = #headers
	if ncols == 0 then
		return
	end

	local widths = {}
	for c = 1, ncols do
		widths[c] = #(headers[c] or "")
	end
	for _, row in ipairs(rows) do
		for c = 1, ncols do
			local cell = row[c] or ""
			if #cell > widths[c] then
				widths[c] = #cell
			end
		end
	end

	local function rule(left, mid, right, fill)
		local parts = { left }
		for c = 1, ncols do
			parts[#parts + 1] = string.rep(fill, widths[c] + 2)
			parts[#parts + 1] = (c == ncols) and right or mid
		end
		return table.concat(parts)
	end

	local function row_line(cells)
		local parts = { "│" }
		for c = 1, ncols do
			local cell = cells[c] or ""
			parts[#parts + 1] = " " .. pad_cell(cell, widths[c], aligns[c] or "left") .. " "
			parts[#parts + 1] = "│"
		end
		return table.concat(parts)
	end

	local top_idx = #lines
	lines[#lines + 1] = rule("┌", "┬", "┐", "─")
	marks[#marks + 1] = { line = top_idx, line_hl = "MidoriTableBorder" }

	local hdr_idx = #lines
	lines[#lines + 1] = row_line(headers)
	marks[#marks + 1] = { line = hdr_idx, line_hl = "MidoriTableHeader" }

	local sep_idx = #lines
	lines[#lines + 1] = rule("├", "┼", "┤", "─")
	marks[#marks + 1] = { line = sep_idx, line_hl = "MidoriTableBorder" }

	for _, row in ipairs(rows) do
		local idx = #lines
		lines[#lines + 1] = row_line(row)
		marks[#marks + 1] = { line = idx, line_hl = "MidoriTableCell" }
	end

	local bot_idx = #lines
	lines[#lines + 1] = rule("└", "┴", "┘", "─")
	marks[#marks + 1] = { line = bot_idx, line_hl = "MidoriTableBorder" }
end

local FRONTMATTER_KEYS = { "title", "date", "tags", "author" }

local function emit_frontmatter(lines, marks, block)
	local fields = block.fields or {}
	local rendered = {}
	for _, key in ipairs(FRONTMATTER_KEYS) do
		local v = fields[key]
		if v and v ~= "" then
			rendered[#rendered + 1] = { key = key, value = v }
		end
	end
	if #rendered == 0 then
		return
	end
	local longest = 0
	for _, r in ipairs(rendered) do
		local len = #r.key + 2 + #r.value
		if len > longest then
			longest = len
		end
	end
	local inner = math.max(longest, 24)
	local top_idx = #lines
	lines[#lines + 1] = "╭" .. string.rep("─", inner + 2) .. "╮"
	marks[#marks + 1] = { line = top_idx, line_hl = "MidoriFrontmatter" }
	for _, r in ipairs(rendered) do
		local body = r.key .. ": " .. r.value
		local pad = inner - #body
		if pad < 0 then
			pad = 0
		end
		local idx = #lines
		lines[#lines + 1] = "│ " .. body .. string.rep(" ", pad) .. " │"
		marks[#marks + 1] = { line = idx, line_hl = "MidoriFrontmatter" }
		marks[#marks + 1] = {
			line = idx,
			col_start = 2,
			col_end = 2 + #r.key,
			hl_group = "MidoriFrontmatterKey",
		}
	end
	local bot_idx = #lines
	lines[#lines + 1] = "╰" .. string.rep("─", inner + 2) .. "╯"
	marks[#marks + 1] = { line = bot_idx, line_hl = "MidoriFrontmatter" }
end

function M.render(blocks)
	local opts = config.options
	local lines, marks, links, headings = {}, {}, {}, {}
	for _, block in ipairs(blocks) do
		if block.kind == "frontmatter" then
			emit_frontmatter(lines, marks, block)
		elseif block.kind == "heading" then
			headings[#headings + 1] = { level = block.level, text = block.text, line = #lines }
			emit_heading(lines, marks, links, block, opts)
		elseif block.kind == "para" then
			emit_para(lines, marks, links, block)
		elseif block.kind == "list_item" then
			emit_list_item(lines, marks, links, block)
		elseif block.kind == "quote" then
			emit_quote(lines, marks, links, block)
		elseif block.kind == "rule" then
			emit_rule(lines, marks, opts)
		elseif block.kind == "code" then
			if block.lang == "mermaid" and emit_mermaid(lines, marks, block, opts) then
				-- handled
			else
				emit_code(lines, marks, block, opts)
			end
		elseif block.kind == "table" then
			emit_table(lines, marks, block)
		elseif block.kind == "blank" then
			lines[#lines + 1] = ""
		end
	end
	return { lines = lines, marks = marks, links = links, headings = headings }
end

return M
