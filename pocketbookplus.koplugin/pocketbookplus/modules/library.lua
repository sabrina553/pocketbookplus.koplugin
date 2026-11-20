--[[--
Library metadata: corrects authors, author sorting, series and genres in the
PocketBook library from each EPUB's own metadata, and optionally removes
entries whose file is gone. Adapted from PbDbFixer by Martin Brodbeck (MIT),
https://git.rustysoft.de/martin/PbDbFixer

Runs only when chosen from the menu: a check shows what would change, and
nothing is written until that is confirmed. All changes go in one
transaction, after the library database backup sync also uses.
--]]--

local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

local LibraryDB = require("pocketbookplus/sync/librarydb")
local Metadata = require("pocketbookplus/library/metadata")

local db = LibraryDB.new()

-- storages.type 1 is the internal storage; files.ext exists from database
-- version 38 (PbDbFixer checks the same).
local EPUBS_SQL = [[
    SELECT b.id, folders.name, files.filename, b.author, b.firstauthor, b.first_author_letter, b.series,
      (SELECT g.name FROM booktogenre bg JOIN genres g ON g.id = bg.genreid WHERE bg.bookid = b.id LIMIT 1),
      b.numinseries
    FROM books_impl b
      JOIN files ON b.id = files.book_id
      JOIN folders ON folders.id = files.folder_id
    WHERE files.storageid IN (SELECT id FROM storages WHERE type = 1) AND lower(files.ext) = 'epub'
]]

-- An entry without a file *and* without a resource_id. Entries with a
-- resource_id belong to a connected account (cloud, store, lending
-- service) and are listed without a local file on purpose: on the device
-- this was written on, 779 of 1373 entries were such, none of them ghosts.
local GHOSTS_WHERE = [[
    id IN (SELECT b.id FROM books_impl b LEFT JOIN files f ON b.id = f.book_id
           WHERE f.filename IS NULL AND b.resource_id IS NULL)
]]
local ORPHAN_TABLES = { "books_settings", "bookshelfs_books", "booktogenre", "social" }

local function query(sql, ...)
    local conn = db:open()
    if not conn then return nil end
    local rows = {}
    local args = { ... }
    local ok, err = pcall(function()
        local stmt = conn:prepare(sql)
        if #args > 0 then stmt:bind(unpack(args)) end
        local row = stmt:step()
        while row do
            local copy = {}
            for i = 1, #row do copy[i] = row[i] end
            table.insert(rows, copy)
            row = stmt:step()
        end
        stmt:close()
    end)
    if not ok then
        logger.warn("PocketBookPlus library: query failed:", err)
        return nil
    end
    return rows
end

local function readOpf(path)
    local Archiver = require("ffi/archiver")
    local reader = Archiver.Reader:new()
    if not reader:open(path) then return nil end
    -- The entry list is built by walking the archive; extractToMemory only
    -- looks entries up in it (base/ffi/archiver.lua).
    for _entry in reader:iterate() do end
    local opf
    local container = reader:extractToMemory("META-INF/container.xml")
    local root = container and Metadata.rootfile(container)
    if root then opf = reader:extractToMemory(root) end
    reader:close()
    return opf
end

-- Reads every EPUB and works out the corrections. Pure reading.
local function scan()
    local rows = query(EPUBS_SQL)
    if not rows then return nil end
    local plan, counts = {}, { books = #rows, author = 0, firstauthor = 0, first_author_letter = 0, series = 0, genre = 0, unreadable = 0 }
    for _i, r in ipairs(rows) do
        local path = tostring(r[2]):gsub("/+$", "") .. "/" .. tostring(r[3])
        local ok, opf = pcall(readOpf, path)
        if ok and opf then
            local changes = Metadata.changes({
                author = r[4], firstauthor = r[5], first_author_letter = r[6], series = r[7], genre = r[8],
            }, Metadata.fromOpf(opf))
            if next(changes) then
                table.insert(plan, { id = tonumber(r[1]), changes = changes, path = path, old = {
                    author = r[4], firstauthor = r[5], first_author_letter = r[6], series = r[7],
                    numinseries = r[9] and tonumber(r[9]) or nil,
                } })
                for k in pairs(changes) do
                    if counts[k] then counts[k] = counts[k] + 1 end
                end
            end
        else
            counts.unreadable = counts.unreadable + 1
        end
    end
    return plan, counts
end

local function ghostCount()
    local rows = query("SELECT count(*) FROM books_impl WHERE " .. GHOSTS_WHERE)
    return rows and tonumber(rows[1][1]) or nil
end

-- Runs `fn(conn)` in one transaction; rolls back on any error.
local function transaction(fn)
    local conn = db:open()
    if not conn then return false, "no database" end
    if not db:backupOnce() then return false, "could not back up the library database" end
    local ok, err = pcall(function()
        conn:exec("BEGIN IMMEDIATE")
        fn(conn)
        conn:exec("COMMIT")
    end)
    if not ok then
        pcall(function() conn:exec("ROLLBACK") end)
        logger.warn("PocketBookPlus library: rolled back:", err)
        return false, tostring(err)
    end
    return true
end

local function exec(conn, sql, ...)
    local stmt = conn:prepare(sql)
    if select("#", ...) > 0 then stmt:bind(...) end
    stmt:step()
    stmt:close()
end

local COLUMN_SQL = {
    author = "UPDATE books_impl SET author = ? WHERE id = ?",
    firstauthor = "UPDATE books_impl SET firstauthor = ? WHERE id = ?",
    first_author_letter = "UPDATE books_impl SET first_author_letter = ? WHERE id = ?",
}

local function applyPlan(plan)
    local ffi = require("ffi")
    local function I(n) return ffi.new("int64_t", n) end
    return transaction(function(conn)
        for _i, item in ipairs(plan) do
            local c = item.changes
            for col, sql in pairs(COLUMN_SQL) do
                if c[col] then exec(conn, sql, c[col], I(item.id)) end
            end
            if c.series then
                exec(conn, "UPDATE books_impl SET series = ?, numinseries = ? WHERE id = ?", c.series, I(c.numinseries or 0), I(item.id))
            end
            if c.genre then
                exec(conn, "INSERT INTO genres (name) VALUES (?) ON CONFLICT DO NOTHING", c.genre)
                exec(conn, "INSERT INTO booktogenre (bookid, genreid) VALUES (?, (SELECT id FROM genres WHERE name = ?)) ON CONFLICT DO NOTHING",
                    I(item.id), c.genre)
            end
        end
    end)
end

-------------------------------------------------------------------------------
-- Undo
-------------------------------------------------------------------------------

-- Each fix records the old values of exactly what it changed, so an undo
-- puts back only those and leaves everything that happened since (new
-- books, progress, collections) alone. A whole-database snapshot could not.
local MAX_UNDO = 3

local function undoStore()
    local DataStorage = require("datastorage")
    local LuaSettings = require("luasettings")
    return LuaSettings:open(DataStorage:getSettingsDir() .. "/pocketbookplus_undo.lua")
end

local function undoRecords()
    return undoStore():readSetting("metadata") or {}
end

local function recordUndo(plan)
    local items = {}
    for _i, item in ipairs(plan) do
        local old = {}
        for col in pairs(item.changes) do
            if col ~= "genre" then old[col] = item.old[col] or false end -- false: was NULL
        end
        table.insert(items, { id = item.id, old = old, genre_added = item.changes.genre })
    end
    local store = undoStore()
    local records = store:readSetting("metadata") or {}
    table.insert(records, 1, { time = os.time(), items = items })
    while #records > MAX_UNDO do table.remove(records) end
    store:saveSetting("metadata", records)
    store:flush()
end

local UNDO_COLUMNS = { "author", "firstauthor", "first_author_letter", "series", "numinseries" }

local function revert(index)
    local records = undoRecords()
    local record = records[index]
    if not record then return false, "no such fix" end
    local ffi = require("ffi")
    local function I(n) return ffi.new("int64_t", n) end
    local ok, err = transaction(function(conn)
        for _i, item in ipairs(record.items) do
            for _j, col in ipairs(UNDO_COLUMNS) do
                local v = item.old[col]
                if v ~= nil then
                    if v == false then
                        exec(conn, "UPDATE books_impl SET " .. col .. " = NULL WHERE id = ?", I(item.id))
                    elseif col == "numinseries" then
                        exec(conn, "UPDATE books_impl SET numinseries = ? WHERE id = ?", I(v), I(item.id))
                    else
                        exec(conn, "UPDATE books_impl SET " .. col .. " = ? WHERE id = ?", v, I(item.id))
                    end
                end
            end
            if item.genre_added then
                exec(conn, "DELETE FROM booktogenre WHERE bookid = ? AND genreid = (SELECT id FROM genres WHERE name = ?)",
                    I(item.id), item.genre_added)
            end
        end
    end)
    if ok then
        table.remove(records, index)
        local store = undoStore()
        store:saveSetting("metadata", records)
        store:flush()
    end
    return ok, err
end

local function removeGhosts()
    return transaction(function(conn)
        conn:exec("DELETE FROM books_impl WHERE " .. GHOSTS_WHERE)
        for _i, t in ipairs(ORPHAN_TABLES) do
            conn:exec("DELETE FROM " .. t .. " WHERE bookid NOT IN (SELECT id FROM books_impl)")
        end
        -- Database version 37 and later keep file hashes here.
        conn:exec("DELETE FROM books_fast_hashes WHERE book_id NOT IN (SELECT id FROM books_impl)")
    end)
end

-------------------------------------------------------------------------------
-- Module
-------------------------------------------------------------------------------

local Library = {
    id = "library",
    name = _("Library metadata"),
    default_enabled = true,
}

local function checkAndOffer()
    local busy = InfoMessage:new{ text = _("Reading the metadata of every EPUB…") }
    UIManager:show(busy)
    UIManager:forceRePaint()
    local plan, counts = scan()
    UIManager:close(busy)
    if not plan then
        UIManager:show(InfoMessage:new{ text = _("Could not read the library database; see crash.log.") })
        return
    end
    local summary = T(_([[EPUBs checked: %1
Authors to fix: %2
Author sorting to fix: %3
A–Z letters to fix: %4
Series to add: %5
Genres to add: %6
Unreadable EPUBs (skipped): %7]]), counts.books, counts.author, counts.firstauthor,
        counts.first_author_letter, counts.series, counts.genre, counts.unreadable)
    logger.info("PocketBookPlus library: check found", #plan, "books to fix")
    if #plan == 0 then
        UIManager:show(InfoMessage:new{ text = summary .. "\n\n" .. _("Nothing to fix.") })
        return
    end
    UIManager:show(ConfirmBox:new{
        text = summary .. "\n\n" .. _("Apply these fixes? The library database is backed up first."),
        ok_text = _("Fix"),
        ok_callback = function()
            local ok, err = applyPlan(plan)
            logger.info("PocketBookPlus library: fixes applied", ok and "ok" or err)
            if ok then recordUndo(plan) end
            UIManager:show(InfoMessage:new{
                text = ok and T(_("Fixed %1 books. The PocketBook Library shows the changes when it is next opened.\n\nTo put them back: Library metadata → Undo a fix."), #plan)
                    or T(_("Nothing was changed: %1"), err),
            })
        end,
    })
end

local function ghostsOffer()
    local n = ghostCount()
    if not n then
        UIManager:show(InfoMessage:new{ text = _("Could not read the library database; see crash.log.") })
        return
    end
    if n == 0 then
        UIManager:show(InfoMessage:new{ text = _("No entries without a file. Books from connected accounts are never counted.") })
        return
    end
    UIManager:show(ConfirmBox:new{
        text = T(_("%1 library entries have no file on the device and no connected account. Remove them (and their progress and collection entries)? Files are not touched."), n),
        ok_text = _("Remove"),
        ok_callback = function()
            local ok, err = removeGhosts()
            logger.info("PocketBookPlus library: removed", n, "ghost entries", ok and "ok" or err)
            UIManager:show(InfoMessage:new{ text = ok and T(_("Removed %1 entries."), n) or T(_("Nothing was changed: %1"), err) })
        end,
    })
end

function Library.menuItems()
    return {
        {
            text = _("Check and fix metadata…"),
            help_text = _("Reads each EPUB's own metadata and shows how many authors, author sort names, A–Z letters, series and genres the PocketBook library has wrong or missing. Nothing is written until you confirm."),
            keep_menu_open = true,
            callback = checkAndOffer,
        },
        {
            text = _("Undo a fix"),
            help_text = T(_("Puts back the values a metadata fix changed, and nothing else. The last %1 fixes are kept."), MAX_UNDO),
            sub_item_table_func = function()
                local items = {}
                for i, rec in ipairs(undoRecords()) do
                    table.insert(items, {
                        text = T(_("%1 (%2 books)"), os.date("%Y-%m-%d %H:%M", rec.time), #rec.items),
                        keep_menu_open = true,
                        callback = function(touchmenu)
                            UIManager:show(ConfirmBox:new{
                                text = T(_("Undo the fix of %1? The library database is backed up first."), os.date("%Y-%m-%d %H:%M", rec.time)),
                                ok_text = _("Undo"),
                                ok_callback = function()
                                    local ok, err = revert(i)
                                    logger.info("PocketBookPlus library: undo", ok and "ok" or err)
                                    UIManager:show(InfoMessage:new{ text = ok and _("Fix undone.") or T(_("Nothing was changed: %1"), err) })
                                    if touchmenu then touchmenu:backToUpperMenu() end
                                end,
                            })
                        end,
                    })
                end
                if #items == 0 then table.insert(items, { text = _("No fixes to undo"), enabled = false }) end
                return items
            end,
            separator = true,
        },
        {
            text = _("Remove entries without a file…"),
            help_text = _("Finds library entries whose book file no longer exists. Books listed from a connected account (cloud, store, lending service) are never included. Asks before removing anything; book files are never touched."),
            keep_menu_open = true,
            callback = ghostsOffer,
        },
    }
end

return Library
