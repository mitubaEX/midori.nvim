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

-- Truncate `text` so its DISPLAY width <= max_w, appending "…" (width 1) when
-- truncation actually happened. Returns (truncated_text, original_bytes_kept)
-- so callers (syntax highlight) can clip byte-offset ranges to the kept
-- prefix of the original line.
local function fit(text, max_w)
	local dw = vim.fn.strdisplaywidth
	if max_w <= 0 then
		return "", 0
	end
	if dw(text) <= max_w then
		return text, #text
	end
	local kept_dw, kept_bytes = 0, 0
	local i = 1
	while i <= #text do
		local b = text:byte(i)
		local len
		if b < 0x80 then
			len = 1
		elseif b < 0xC0 then
			len = 1 -- defensive: mid-utf8 byte, treat as 1
		elseif b < 0xE0 then
			len = 2
		elseif b < 0xF0 then
			len = 3
		else
			len = 4
		end
		local char = text:sub(i, i + len - 1)
		local cw = dw(char)
		if kept_dw + cw > max_w - 1 then
			break
		end
		kept_dw = kept_dw + cw
		kept_bytes = kept_bytes + len
		i = i + len
	end
	return text:sub(1, kept_bytes) .. "…", kept_bytes
end

-- Split `text` into chunks whose DISPLAY width <= max_w. Each chunk is
-- { text = "...", byte_start = 1-indexed byte offset in the original `text`,
--   byte_len = #text }. Empty `text` yields one empty chunk so wrap callers
-- still emit a single body line. Multibyte-safe via the same per-codepoint
-- walk as fit().
local function split_by_width(text, max_w)
	if max_w <= 0 or text == "" then
		return { { text = "", byte_start = 1, byte_len = 0 } }
	end
	local dw = vim.fn.strdisplaywidth
	if dw(text) <= max_w then
		return { { text = text, byte_start = 1, byte_len = #text } }
	end
	local chunks = {}
	local chunk_start = 1
	local cur_dw, cur_bytes = 0, 0
	local i = 1
	while i <= #text do
		local b = text:byte(i)
		local len
		if b < 0x80 then
			len = 1
		elseif b < 0xC0 then
			len = 1
		elseif b < 0xE0 then
			len = 2
		elseif b < 0xF0 then
			len = 3
		else
			len = 4
		end
		local char = text:sub(i, i + len - 1)
		local cw = dw(char)
		if cur_dw + cw > max_w then
			chunks[#chunks + 1] = {
				text = text:sub(chunk_start, chunk_start + cur_bytes - 1),
				byte_start = chunk_start,
				byte_len = cur_bytes,
			}
			chunk_start = i
			cur_dw, cur_bytes = 0, 0
		end
		cur_dw = cur_dw + cw
		cur_bytes = cur_bytes + len
		i = i + len
	end
	if cur_bytes > 0 then
		chunks[#chunks + 1] = {
			text = text:sub(chunk_start, chunk_start + cur_bytes - 1),
			byte_start = chunk_start,
			byte_len = cur_bytes,
		}
	end
	return chunks
end

local INLINE_PATTERNS = {
	{ name = "code", left = "`", right = "`", hl = "MidoriInlineCode" },
	{ name = "strong", left = "**", right = "**", hl = "MidoriBold" },
	{ name = "strong_us", left = "__", right = "__", hl = "MidoriBold", word_boundary = true },
	{ name = "strike", left = "~~", right = "~~", hl = "MidoriStrike" },
	{ name = "em", left = "*", right = "*", hl = "MidoriItalic" },
	{ name = "em_us", left = "_", right = "_", hl = "MidoriItalic", word_boundary = true },
}

-- CommonMark-ish word boundary: a `_` marker only opens / closes when it sits
-- next to a non-alphanumeric character (or string edge). Prevents
-- intra-word underscores ("nvim_lua_config") from being read as emphasis.
local function is_word_char(ch)
	return ch ~= nil and ch:match("[%w]") ~= nil
end

local function ok_left_boundary(text, ls)
	local before = ls > 1 and text:sub(ls - 1, ls - 1) or nil
	return not is_word_char(before)
end

local function ok_right_boundary(text, re)
	local after = re < #text and text:sub(re + 1, re + 1) or nil
	return not is_word_char(after)
end

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
						local ok = true
						if p.word_boundary then
							ok = ok_left_boundary(out, ls) and ok_right_boundary(out, re)
						end
						if ok and (hit == nil or ls < hit.ls) then
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
	if opts._viewport then
		rule_width = math.min(rule_width, opts._viewport)
	end
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
	if opts._viewport then
		w = math.min(w, opts._viewport)
	end
	local idx = #lines
	lines[#lines + 1] = string.rep("─", w)
	marks[#marks + 1] = { line = idx, line_hl = "MidoriRule" }
end

local function emit_framed_block(lines, marks, label, body_lines, opts)
	-- Width math is in DISPLAY columns, not bytes — mermaid output uses
	-- box-drawing chars (3 bytes / 1 col in UTF-8) so #s overstates width
	-- and the right border drifts left of ╮/╯.
	local dw = vim.fn.strdisplaywidth
	local longest = #label + 4
	for _, l in ipairs(body_lines) do
		local w = dw(l)
		if w > longest then
			longest = w
		end
	end
	local max_inner = opts and opts._viewport and (opts._viewport - 4) or nil
	if max_inner and longest > max_inner then
		longest = math.max(4, max_inner)
	end
	local inner = math.max(longest, 20)
	local llabel = label ~= "" and (" " .. label .. " ") or ""
	local top = "╭─" .. llabel .. string.rep("─", inner + 1 - #llabel) .. "╮"
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
		local fitted = fit(bl, inner)
		local pad = inner - dw(fitted)
		if pad < 0 then
			pad = 0
		end
		local li = #lines
		lines[#lines + 1] = "│ " .. fitted .. string.rep(" ", pad) .. " │"
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
		emit_framed_block(lines, marks, "mermaid", result.lines, opts)
		return true
	end
	local body = { "[mermaid: not installed]", "" }
	for _, l in ipairs(block.lines) do
		body[#body + 1] = l
	end
	emit_framed_block(lines, marks, "mermaid", body, opts)
	return true
end

local function emit_code(lines, marks, block, opts)
	-- Width math is in DISPLAY columns, not bytes — body may contain
	-- multibyte chars (Japanese, em dash, box-drawing) whose byte length
	-- overstates the displayed width, drifting the right '│' left.
	local dw = vim.fn.strdisplaywidth
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
		local w = dw(l)
		if w > longest then
			longest = w
		end
	end
	local label = lang ~= "" and (" " .. lang .. " ") or ""
	local inner = math.max(longest + (nr_width > 0 and (nr_width + 3) or 0), #label + 4)
	inner = math.max(inner, 20)
	-- Viewport cap: the rendered frame ("│ <inner> │" = inner + 4 cols) must
	-- fit the reader window, otherwise the right '│' soft-wraps and the box
	-- visually breaks. Truncation of body lines happens below.
	if opts._viewport then
		local max_inner = opts._viewport - 4
		if max_inner < #label + 4 then
			max_inner = math.max(4, #label + 4)
		end
		if inner > max_inner then
			inner = max_inner
		end
	end

	if opts.code.border then
		local top = "╭─" .. label .. string.rep("─", inner + 1 - #label) .. "╮"
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
	-- Per-original-body-line list of emitted chunks. Each chunk records its
	-- emitted buffer-line index and its (byte_start, byte_len) slice of the
	-- ORIGINAL body line, so syntax highlight col offsets can be mapped per
	-- chunk (only marks whose [col_start, col_end) intersects the chunk byte
	-- range are emitted, shifted to chunk-local coords).
	local body_chunks = {}
	local wrap_mode = (opts.code.wrap or "wrap") == "wrap"
	for i, bl in ipairs(body) do
		local prefix = ""
		if opts.code.line_numbers then
			prefix = string.format("%" .. nr_width .. "d   ", i)
		end
		local blank_prefix = opts.code.line_numbers and string.rep(" ", #prefix) or ""
		local body_avail = inner - dw(prefix)
		if body_avail < 0 then
			body_avail = 0
		end

		local chunks
		if wrap_mode then
			chunks = split_by_width(bl, body_avail)
		else
			local fitted_body, kept = fit(bl, body_avail)
			chunks = { { text = fitted_body, byte_start = 1, byte_len = kept } }
		end

		local line_chunks = {}
		for ci, ch in ipairs(chunks) do
			local cur_prefix = (ci == 1) and prefix or blank_prefix
			local content = cur_prefix .. ch.text
			local pad = inner - dw(content)
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
			if ci == 1 and opts.code.line_numbers and opts.code.border then
				marks[#marks + 1] = {
					line = idx,
					col_start = 2,
					col_end = 2 + nr_width,
					hl_group = "MidoriCodeLineNr",
				}
			end
			line_chunks[#line_chunks + 1] = { buf_line = idx, byte_start = ch.byte_start, byte_len = ch.byte_len }
		end
		body_chunks[i] = line_chunks
	end

	if opts.code.syntax and lang ~= "" then
		-- Byte-length of "│ " — │ (U+2502) is 3 bytes in UTF-8, not 1.
		-- Using a literal 2 here mis-aligns every syntax mark by 2 bytes:
		-- token colors bleed into the trailing │ bytes and shift one char
		-- left, so each identifier appears split between two highlight groups.
		local border_prefix = opts.code.border and #"│ " or 0
		local body_prefix_len = border_prefix + (opts.code.line_numbers and (nr_width + 3) or 0)
		local syntax_marks = syntax.highlights(lang, body)
		for _, m in ipairs(syntax_marks) do
			local chunks = body_chunks[m.line + 1] or {}
			for _, ch in ipairs(chunks) do
				-- mark byte range in original body line: [m.col_start, m.col_end)
				-- chunk byte range:                     [ch.byte_start-1, ch.byte_start-1 + ch.byte_len)
				local ch_lo = ch.byte_start - 1
				local ch_hi = ch_lo + ch.byte_len
				local lo = math.max(m.col_start, ch_lo)
				local hi = math.min(m.col_end, ch_hi)
				if lo < hi then
					marks[#marks + 1] = {
						line = ch.buf_line,
						col_start = (lo - ch_lo) + body_prefix_len,
						col_end = (hi - ch_lo) + body_prefix_len,
						hl_group = m.hl_group,
					}
				end
			end
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
	-- width is in DISPLAY columns; `#text` is bytes and overcounts multibyte
	-- (Japanese, en dash, box-drawing) so multibyte cells would be
	-- under-padded and the right '│' would drift left.
	local space = width - vim.fn.strdisplaywidth(text)
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

local function emit_table(lines, marks, block, opts)
	local headers = block.headers or {}
	local aligns = block.aligns or {}
	local rows = block.rows or {}
	local ncols = #headers
	if ncols == 0 then
		return
	end

	-- Column widths are in DISPLAY columns, not bytes — same multibyte
	-- alignment fix as emit_code / emit_framed_block (see PR #12). Byte length
	-- of e.g. `–` is 3 but its display width is 1, so byte-based widths leave
	-- ASCII rows over-padded relative to multibyte rows in the same column.
	local dw = vim.fn.strdisplaywidth
	local widths = {}
	for c = 1, ncols do
		widths[c] = dw(headers[c] or "")
	end
	for _, row in ipairs(rows) do
		for c = 1, ncols do
			local w = dw(row[c] or "")
			if w > widths[c] then
				widths[c] = w
			end
		end
	end

	-- Viewport fit: total line width = 1 (left │) + Σ(widths[c] + 2 + 1).
	-- If it exceeds the viewport, shrink the widest column 1-col-at-a-time
	-- until it fits or every column is at the minimum (1). Truncation of
	-- overflowing cells happens at row_line time via fit().
	if opts and opts._viewport then
		local function total()
			local t = 1
			for c = 1, ncols do
				t = t + widths[c] + 3
			end
			return t
		end
		while total() > opts._viewport do
			local widest, idx = 0, 1
			for c = 1, ncols do
				if widths[c] > widest then
					widest, idx = widths[c], c
				end
			end
			if widest <= 1 then
				break
			end
			widths[idx] = widths[idx] - 1
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
			local fitted = fit(cell, widths[c])
			parts[#parts + 1] = " " .. pad_cell(fitted, widths[c], aligns[c] or "left") .. " "
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

local function emit_doc_header(lines, marks, meta, opts)
	local title = (meta and meta.title) or ""
	if title == "" then
		return
	end
	local ft = (meta and meta.ft) or ""
	local width = math.max(opts.rule_width or 60, #title + #ft + 6)
	if opts._viewport then
		width = math.min(width, opts._viewport)
	end
	local idx = #lines
	local right = ft ~= "" and ("[" .. ft .. "]") or ""
	local pad = width - #title - #right
	if pad < 1 then
		pad = 1
	end
	lines[#lines + 1] = title .. string.rep(" ", pad) .. right
	marks[#marks + 1] = { line = idx, line_hl = "MidoriDocTitle" }
	-- title col-range and ft col-range
	if title ~= "" then
		marks[#marks + 1] = {
			line = idx,
			col_start = 0,
			col_end = #title,
			hl_group = "MidoriH1",
		}
	end
	if right ~= "" then
		marks[#marks + 1] = {
			line = idx,
			col_start = #title + pad,
			col_end = #title + pad + #right,
			hl_group = "MidoriDocFt",
		}
	end
	local ridx = #lines
	lines[#lines + 1] = string.rep("━", width)
	marks[#marks + 1] = { line = ridx, line_hl = "MidoriH1Rule" }
end

function M.render(blocks, meta, render_opts)
	-- Shadow `config.options` with an _viewport overlay so we don't mutate
	-- shared state. Nested tables (opts.code, opts.heading) still resolve
	-- through __index, so emit_*'s `opts.code.border` etc. keep working.
	local base = config.options
	local opts = setmetatable({
		_viewport = render_opts and render_opts.viewport or nil,
	}, { __index = base })
	local lines, marks, links, headings = {}, {}, {}, {}
	emit_doc_header(lines, marks, meta, opts)
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
			emit_table(lines, marks, block, opts)
		elseif block.kind == "blank" then
			lines[#lines + 1] = ""
		end
	end
	return { lines = lines, marks = marks, links = links, headings = headings }
end

return M
