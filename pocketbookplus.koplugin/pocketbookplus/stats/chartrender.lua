-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Copyright (C) 2026 tadeasf <tadeasfort@proton.me>
-- Adapted from chartingsleepscreen_koplugin by tadeasf,
-- https://github.com/tadeasf/chartingsleepscreen_koplugin
--[[--
Pure renderer: takes the table from chartstats.collect() and produces a
grayscale (BB8) Blitbuffer sized w×h — terminal/dotfiles aesthetic: ASCII
signature, mono section rules, boxes and bars, no bitmap dependencies.
No I/O and no device state; callers own the returned buffer and must :free() it.
]]

local Blitbuffer = require("ffi/blitbuffer")
local Font = require("ui/font")
local RenderText = require("ui/rendertext")
local util = require("util")

local chartrender = {}

-- "infont" maps to DroidSansMono, which ships with KOReader.
local MONO = "infont"

local function mkFace(name, size, leading)
    local face = Font:getFace(name, size)
    local m = RenderText:sizeUtf8Text(0, math.huge, face, "Ãjgqp|", true)
    local f = { face = face, ascent = m.y_top, descent = m.y_bottom }
    f.height = f.ascent + f.descent
    f.line_h = math.ceil(f.height * (leading or 1.25))
    return f
end

local function textWidth(f, text, bold, kerning)
    return RenderText:sizeUtf8Text(0, math.huge, f.face, text, kerning ~= false, bold).x
end

-- y is the TOP of the line; renderUtf8Text wants the baseline.
local function drawText(bb, f, x, y, text, color, bold, kerning)
    RenderText:renderUtf8Text(bb, x, y + f.ascent, f.face, text, kerning ~= false, bold, color)
end

-- Shorten text to fit max_w; mode "middle" keeps the start and end of the string.
local function truncate(f, text, max_w, mode, bold)
    local full_w = textWidth(f, text, bold)
    if full_w <= max_w then return text end
    local chars = util.splitToChars(text)
    local keep = math.min(#chars - 1, math.floor(#chars * max_w / full_w) + 2)
    while keep > 0 do
        local candidate
        if mode == "middle" then
            local head = math.ceil(keep * 0.6)
            local tail = keep - head
            candidate = table.concat(chars, "", 1, head) .. "…"
                .. table.concat(chars, "", #chars - tail + 1)
        else
            candidate = table.concat(chars, "", 1, keep) .. "…"
        end
        if textWidth(f, candidate, bold) <= max_w then return candidate end
        keep = keep - 1
    end
    return "…"
end

local function oneLine(text)
    return (text or ""):gsub("%s+", " ")
end

local function fmtHours(seconds)
    seconds = tonumber(seconds) or 0
    if seconds < 60 then return "0m" end
    if seconds < 3600 then return string.format("%dm", math.floor(seconds / 60 + 0.5)) end
    return string.format("%.1fh", seconds / 3600)
end

local function fmtDuration(seconds)
    seconds = math.floor(tonumber(seconds) or 0)
    local hours = math.floor(seconds / 3600)
    local mins = math.floor((seconds % 3600) / 60)
    if hours > 0 then return string.format("%dh %02dm", hours, mins) end
    return string.format("%dm", mins)
end

function chartrender.build(data, w, h, theme)
    theme = theme or {}
    data = data or {}
    local recent = data.recent or {}
    local cur = data.current

    local C
    if theme.invert then
        C = {
            bg = Blitbuffer.COLOR_BLACK,
            fg = Blitbuffer.COLOR_WHITE,
            dim = Blitbuffer.Color8(0x99),
            faint = Blitbuffer.Color8(0x44),
        }
    else
        C = {
            bg = Blitbuffer.COLOR_WHITE,
            fg = Blitbuffer.COLOR_BLACK,
            dim = Blitbuffer.Color8(0x66),
            faint = Blitbuffer.COLOR_LIGHT_GRAY,
        }
    end

    local F = {
        header = mkFace(MONO, 15, 1.2),
        title = mkFace("tfont", 18, 1.25), -- tfont is already bold; draw with bold=false
        big = mkFace("tfont", 22, 1.25),
        meta = mkFace(MONO, 13, 1.35),
        tile = mkFace(MONO, 24, 1.1),
        small = mkFace(MONO, 11, 1.25),
    }

    local bb = Blitbuffer.new(w, h, Blitbuffer.TYPE_BB8)
    bb:fill(C.bg)

    local margin = math.floor(0.06 * w)
    local content_w = w - 2 * margin
    local section_gap = math.floor(0.018 * h)
    local bar_h = 34

    -- Thin terminal-style frame.
    local inset = math.floor(margin / 2)
    bb:paintBorder(inset, inset, w - 2 * inset, h - 2 * inset, 2, C.fg)

    local tile_gap = 24
    local tile_w = math.floor((content_w - 3 * tile_gap) / 4)
    local tile_h = math.floor(tile_w * 0.75)

    local y = margin

    local function signature()
        local sig = theme.signature
        if not sig or sig == "" then return end
        local lines = {}
        for line in (sig .. "\n"):gmatch("(.-)\n") do
            table.insert(lines, line)
        end
        while #lines > 0 and lines[#lines]:match("^%s*$") do table.remove(lines) end
        while #lines > 0 and lines[1]:match("^%s*$") do table.remove(lines, 1) end
        if #lines == 0 then return end
        -- Auto-shrink the mono face until the widest art line fits.
        local size = 20
        local f, max_w
        while true do
            f = mkFace(MONO, size, 1.15)
            max_w = 0
            for _, line in ipairs(lines) do
                local lw = textWidth(f, line, false, false)
                if lw > max_w then max_w = lw end
            end
            if max_w <= content_w or size <= 10 then break end
            size = size - 1
        end
        local x0 = margin + math.floor((content_w - max_w) / 2)
        for _, line in ipairs(lines) do
            drawText(bb, f, x0, y, line, C.fg, false, false)
            y = y + f.line_h
        end
    end

    local function sectionHeader(label)
        local f = F.header
        local text = label:upper()
        local rule_y = y + math.floor(f.height / 2) - 1
        local stub_w = 24
        local text_x = margin + stub_w + 14
        bb:paintRect(margin, rule_y, stub_w, 3, C.fg)
        drawText(bb, f, text_x, y, text, C.fg, false, false)
        local rule_x = text_x + textWidth(f, text, false, false) + 14
        bb:paintRect(rule_x, rule_y, margin + content_w - rule_x, 3, C.fg)
        y = y + f.line_h + 10
    end

    local function recentBooks(max_y)
        local thumb_w, thumb_h = 0, 0
        for _, book in ipairs(recent) do
            if book.cover_bb then
                thumb_w = math.max(thumb_w, book.cover_bb:getWidth())
                thumb_h = math.max(thumb_h, book.cover_bb:getHeight())
            end
        end
        local has_covers = thumb_w > 0
        for i, book in ipairs(recent) do
            local author = nil
            if book.authors and book.authors ~= "" and book.authors ~= "N/A" then
                author = oneLine((book.authors:gsub("\n", ", ")))
                if author == "" then author = nil end
            end
            local meta_lines = author and 2 or 1
            local text_h = F.title.line_h + meta_lines * F.meta.line_h
            local row_h = math.max(text_h, thumb_h)
            if y + row_h > max_y then break end
            local text_x = margin
            if has_covers then
                if book.cover_bb then
                    local cw, ch = book.cover_bb:getWidth(), book.cover_bb:getHeight()
                    local cx = margin + math.floor((thumb_w - cw) / 2)
                    local cy = y + math.floor((row_h - ch) / 2)
                    bb:paintBorder(cx - 2, cy - 2, cw + 4, ch + 4, 2, C.fg)
                    bb:blitFrom(book.cover_bb, cx, cy, 0, 0, cw, ch)
                else
                    bb:paintBorder(margin, y + math.floor((row_h - thumb_h) / 2),
                        thumb_w, thumb_h, 2, C.faint)
                end
                text_x = margin + thumb_w + 22
            end
            local avail_w = margin + content_w - text_x
            local ty = y
            if has_covers and thumb_h > text_h then
                ty = y + math.floor((row_h - text_h) / 2)
            end
            local m_size = 14
            local m_y = ty + math.floor((F.title.height - m_size) / 2)
            if book.finished then
                bb:paintRect(text_x, m_y, m_size, m_size, C.fg)
            else
                bb:paintBorder(text_x, m_y, m_size, m_size, 2, C.fg)
            end
            local title_x = text_x + m_size + 16
            local text_avail = avail_w - m_size - 16
            local title = truncate(F.title, oneLine(book.title) ~= "" and oneLine(book.title) or "Untitled",
                text_avail, "middle")
            drawText(bb, F.title, title_x, ty, title, C.fg)
            ty = ty + F.title.line_h
            if author then
                drawText(bb, F.meta, title_x, ty,
                    truncate(F.meta, author, text_avail, "middle"), C.dim, false, false)
                ty = ty + F.meta.line_h
            end
            local meta = string.format("%s · %d %s · %s",
                fmtHours(book.read_seconds),
                book.span_days,
                book.span_days == 1 and "day" or "days",
                book.finished and "finished" or "in progress")
            drawText(bb, F.meta, title_x, ty, meta, C.dim, false, false)
            y = y + row_h
            if i < #recent then
                y = y + 10
                bb:paintRect(margin, y, content_w, 1, C.faint)
                y = y + 14
            end
        end
    end

    local function currentBook()
        local cover = cur.cover_bb
        local text_x, text_w = margin, content_w
        local cover_bottom = y
        if cover then
            local cw, ch = cover:getWidth(), cover:getHeight()
            bb:paintBorder(margin - 2, y - 2, cw + 4, ch + 4, 2, C.fg)
            bb:blitFrom(cover, margin, y, 0, 0, cw, ch)
            text_x = margin + cw + 28
            text_w = content_w - cw - 28
            cover_bottom = y + ch
        end
        local ty = y
        local title = truncate(F.big, oneLine(cur.title) ~= "" and oneLine(cur.title) or "Untitled",
            text_w, "end")
        drawText(bb, F.big, text_x, ty, title, C.fg)
        ty = ty + F.big.line_h
        local authors = cur.authors
        if authors and authors ~= "" and authors ~= "N/A" then
            authors = truncate(F.meta, oneLine((authors:gsub("\n", ", "))), text_w, "middle")
            drawText(bb, F.meta, text_x, ty, authors, C.dim, false, false)
            ty = ty + F.meta.line_h
        end
        ty = ty + 10
        if cur.percent then
            local ptext = string.format("%d%% · %d/%d pages",
                math.floor(cur.percent * 100 + 0.5), cur.pages_read, cur.pages)
            local ptw = textWidth(F.meta, ptext, false, false)
            drawText(bb, F.meta, text_x + math.max(0, text_w - ptw), ty, ptext, C.fg, false, false)
            ty = ty + F.meta.line_h + 6
            bb:paintBorder(text_x, ty, text_w, bar_h, 2, C.fg, 4)
            local fill_w = math.floor((text_w - 12) * math.min(cur.percent, 1))
            if fill_w > 0 then
                bb:paintRect(text_x + 6, ty + 6, fill_w, bar_h - 12, C.fg)
            end
            ty = ty + bar_h + 10
        end
        local line = fmtDuration(cur.read_seconds) .. " read"
        if cur.eta_seconds and cur.eta_seconds > 0 then
            line = line .. " · ~" .. fmtDuration(cur.eta_seconds) .. " to finish"
        end
        drawText(bb, F.meta, text_x, ty, line, C.dim, false, false)
        ty = ty + F.meta.line_h
        y = math.max(ty, cover_bottom + 6)
    end

    local function statTiles()
        local tiles = {
            { value = tostring(math.floor(tonumber(data.streak_days) or 0)), label = "day streak" },
            { value = fmtHours(data.month_seconds), label = "this month" },
            { value = fmtHours(data.year_seconds), label = "this year" },
            { value = (tonumber(data.avg_session_seconds) or 0) > 0
                and fmtDuration(data.avg_session_seconds) or "—", label = "avg session" },
        }
        for i, tile in ipairs(tiles) do
            local x = margin + (i - 1) * (tile_w + tile_gap)
            bb:paintBorder(x, y, tile_w, tile_h, 2, C.fg, 6)
            local value = tile.value
            local vw = textWidth(F.tile, value, true, false)
            if vw > tile_w - 16 then
                value = truncate(F.tile, value, tile_w - 16, "end", true)
                vw = textWidth(F.tile, value, true, false)
            end
            local v_y = y + math.floor(tile_h * 0.45 - F.tile.height / 2)
            drawText(bb, F.tile, x + math.floor((tile_w - vw) / 2), v_y, value, C.fg, true, false)
            local lw = textWidth(F.small, tile.label, false, false)
            local l_y = y + tile_h - math.floor(tile_h * 0.14) - F.small.height
            drawText(bb, F.small, x + math.floor((tile_w - lw) / 2), l_y, tile.label, C.dim, false, false)
        end
        y = y + tile_h
    end

    local function footer()
        local text = os.date("generated %Y-%m-%d %H:%M")
        local tw = textWidth(F.small, text, false, false)
        local fy = h - margin - F.small.height
        drawText(bb, F.small, margin + math.floor((content_w - tw) / 2), fy, text, C.dim, false, false)
    end

    -- ── flow: signature → now reading → recent books → stats ───────────────
    signature()
    y = y + section_gap

    -- theme.footer = false drops the "generated" timestamp and its space.
    local show_footer = theme.footer ~= false
    local footer_block = show_footer and (F.small.line_h + 12) or 0
    local header_block = F.header.line_h + 10
    local tiles_block = header_block + tile_h

    if cur then
        sectionHeader("now reading")
        currentBook()
        y = y + section_gap
    end

    if #recent > 0 then
        sectionHeader("recent books")
        recentBooks(h - margin - footer_block - tiles_block - section_gap)
    end

    if not cur and #recent == 0 then
        drawText(bb, F.meta, margin, y, "no reading data yet", C.dim, false, false)
        y = y + F.meta.line_h
    end

    -- Pin the stats tiles just above the footer; the gap above absorbs slack.
    local tiles_top = h - margin - footer_block - tile_h
    local header_top = tiles_top - header_block
    if header_top > y + section_gap then
        y = header_top
    else
        y = y + section_gap
    end
    sectionHeader("stats")
    statTiles()

    if show_footer then footer() end

    return bb
end

return chartrender
