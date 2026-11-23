-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Copyright (C) 2026 tadeasf <tadeasfort@proton.me>
-- Adapted from chartingsleepscreen_koplugin by tadeasf,
-- https://github.com/tadeasf/chartingsleepscreen_koplugin
--[[--
Data layer: reads KOReader's statistics.sqlite3 and returns plain Lua tables.
Every accessor is pcall-guarded — collect() never throws; missing data comes
back as nil fields, empty lists, or zeros.

Notes on the schema (statistics.koplugin, DB schema 20221111):
- book(id, title, authors, pages, last_open, total_read_time, ...)
- page_stat is a VIEW over page_stat_data that rescales historical page
  numbers to the current book.pages — always query the view.
- start_time is unix epoch seconds UTC; duration is seconds.
]]

local SQ3 = require("lua-ljsqlite3/init")
local lfs = require("libs/libkoreader-lfs")

local chartstats = {}

-- A reading pause longer than this starts a new session.
local SESSION_GAP_S = 300

local function openDB(db_path)
    if lfs.attributes(db_path, "mode") ~= "file" then return nil end
    -- The statistics plugin owns all writes to this DB; we only ever read.
    local ok, conn = pcall(SQ3.open, db_path, "ro")
    if ok and conn then return conn end
    ok, conn = pcall(SQ3.open, db_path)
    if ok and conn then return conn end
    return nil
end

local function getCurrentBook(conn)
    local id, title, authors, pages, md5 = conn:rowexec(
        "SELECT id, title, authors, pages, md5 FROM book ORDER BY last_open DESC LIMIT 1;")
    if id == nil then return nil end
    id = tonumber(id)
    pages = tonumber(pages) or 0
    local pages_read, read_seconds = conn:rowexec(string.format(
        "SELECT count(DISTINCT page), coalesce(sum(duration), 0) FROM page_stat WHERE id_book = %d;", id))
    pages_read = tonumber(pages_read) or 0
    read_seconds = tonumber(read_seconds) or 0
    local current = {
        id = id,
        title = type(title) == "string" and title or nil,
        authors = type(authors) == "string" and authors or nil,
        md5 = type(md5) == "string" and md5 or nil,
        pages = pages,
        pages_read = pages_read,
        read_seconds = read_seconds,
    }
    if pages > 0 then
        current.percent = math.min(1, pages_read / pages)
    end
    if pages_read > 0 then
        current.avg_sec_per_page = read_seconds / pages_read
        if pages > 0 then
            current.eta_seconds = math.max(0, pages - pages_read) * current.avg_sec_per_page
        end
    end
    return current
end

local function getRecentBooks(conn, count, exclude_id)
    if not count or count <= 0 then return {} end
    -- HAVING filters out barely-touched books (opened once, read a minute).
    local sql = string.format([[
        SELECT b.id, b.title, b.authors, b.pages, b.md5,
               ps.read_seconds, ps.distinct_pages, ps.span_days
        FROM book b
        JOIN (
            SELECT id_book,
                   sum(duration) AS read_seconds,
                   count(DISTINCT page) AS distinct_pages,
                   cast(julianday(strftime('%%Y-%%m-%%d', max(start_time), 'unixepoch', 'localtime'))
                      - julianday(strftime('%%Y-%%m-%%d', min(start_time), 'unixepoch', 'localtime'))
                      AS integer) + 1 AS span_days
            FROM page_stat
            GROUP BY id_book
            HAVING sum(duration) >= 300
        ) ps ON ps.id_book = b.id
        WHERE b.id != %d
          -- A book renamed in its metadata keeps its file, so it can have a
          -- second record with the same md5: that's still the current book.
          AND b.md5 IS NOT (SELECT md5 FROM book WHERE id = %d)
        ORDER BY b.last_open DESC
        LIMIT %d;
    ]], exclude_id or -1, exclude_id or -1, count * 2) -- spare rows for the md5 dedupe below
    local res = conn:exec(sql)
    local books = {}
    local seen_md5 = {}
    if res and res[1] then
        for i = 1, #res[1] do
            local md5 = type(res.md5[i]) == "string" and res.md5[i] or nil
            if #books >= count then break end
            if md5 and seen_md5[md5] then goto continue end
            if md5 then seen_md5[md5] = true end
            local pages = tonumber(res.pages[i]) or 0
            local distinct_pages = tonumber(res.distinct_pages[i]) or 0
            table.insert(books, {
                title = type(res.title[i]) == "string" and res.title[i] or nil,
                authors = type(res.authors[i]) == "string" and res.authors[i] or nil,
                md5 = md5,
                read_seconds = tonumber(res.read_seconds[i]) or 0,
                span_days = math.floor(tonumber(res.span_days[i]) or 0),
                finished = pages > 0 and distinct_pages >= pages * 0.95,
            })
            ::continue::
        end
    end
    return books
end

local function getStreak(conn)
    local res = conn:exec([[
        SELECT DISTINCT strftime('%Y-%m-%d', start_time, 'unixepoch', 'localtime') AS day
        FROM page_stat
        WHERE start_time >= strftime('%s', 'now') - 400 * 86400
        ORDER BY day DESC;
    ]])
    if not res or not res.day or #res.day == 0 then return 0 end
    local days = res.day
    local function dayTime(d)
        local yy, mm, dd = d:match("^(%d+)-(%d+)-(%d+)$")
        if not yy then return nil end
        -- Noon timestamps so DST shifts can't make days look non-consecutive.
        return os.time({ year = tonumber(yy), month = tonumber(mm), day = tonumber(dd), hour = 12 })
    end
    local DAY = 24 * 3600
    local SLACK = 3600
    local latest = dayTime(days[1])
    if not latest then return 0 end
    local today = dayTime(os.date("%Y-%m-%d"))
    -- The streak survives if the latest reading day is today or yesterday.
    if today - latest > DAY + SLACK then return 0 end
    local streak = 1
    local prev = latest
    for i = 2, #days do
        local t = dayTime(days[i])
        if not t or prev - t > DAY + SLACK then break end
        streak = streak + 1
        prev = t
    end
    return streak
end

local function getTotals(conn)
    local month = conn:rowexec([[
        SELECT coalesce(sum(duration), 0) FROM page_stat
        WHERE strftime('%Y-%m', start_time, 'unixepoch', 'localtime') = strftime('%Y-%m', 'now', 'localtime');
    ]])
    local year = conn:rowexec([[
        SELECT coalesce(sum(duration), 0) FROM page_stat
        WHERE strftime('%Y', start_time, 'unixepoch', 'localtime') = strftime('%Y', 'now', 'localtime');
    ]])
    return tonumber(month) or 0, tonumber(year) or 0
end

local function getAvgSession(conn)
    local res = conn:exec([[
        SELECT start_time, duration FROM page_stat
        WHERE start_time >= strftime('%s', 'now') - 30 * 86400
        ORDER BY start_time;
    ]])
    if not res or not res.start_time or #res.start_time == 0 then return 0 end
    local n_sessions, total = 0, 0
    local prev_end
    for i = 1, #res.start_time do
        local st = tonumber(res.start_time[i]) or 0
        local du = tonumber(res.duration[i]) or 0
        if not prev_end or st > prev_end + SESSION_GAP_S then
            n_sessions = n_sessions + 1
        end
        total = total + du
        local this_end = st + du
        if not prev_end or this_end > prev_end then prev_end = this_end end
    end
    if n_sessions == 0 then return 0 end
    return total / n_sessions
end

--- Collects everything the renderer needs. Returns nil when the DB is
-- missing/unreadable; otherwise a table with best-effort fields.
function chartstats.collect(db_path, opts)
    opts = opts or {}
    local conn = openDB(db_path)
    if not conn then return nil end
    local data = {
        recent = {},
        streak_days = 0,
        month_seconds = 0,
        year_seconds = 0,
        avg_session_seconds = 0,
    }
    local ok, current = pcall(getCurrentBook, conn)
    if ok then data.current = current end
    local exclude = data.current and data.current.id or -1
    local ok_recent, recent = pcall(getRecentBooks, conn, opts.recent_count or 4, exclude)
    if ok_recent and recent then data.recent = recent end
    local ok_streak, streak = pcall(getStreak, conn)
    if ok_streak then data.streak_days = streak end
    local ok_totals, month, year = pcall(getTotals, conn)
    if ok_totals then
        data.month_seconds = month
        data.year_seconds = year
    end
    local ok_avg, avg = pcall(getAvgSession, conn)
    if ok_avg then data.avg_session_seconds = avg end
    pcall(conn.close, conn)
    return data
end

return chartstats
