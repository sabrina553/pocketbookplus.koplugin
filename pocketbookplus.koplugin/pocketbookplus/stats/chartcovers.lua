-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Copyright (C) 2026 tadeasf <tadeasfort@proton.me>
-- Adapted from chartingsleepscreen_koplugin by tadeasf,
-- https://github.com/tadeasf/chartingsleepscreen_koplugin
--[[--
Book-cover lookup: matches books from the statistics DB to real files and
returns cover Blitbuffers, aspect-fitted to a requested box.

Matching is exact, not fuzzy: the statistics plugin stores the same
partial_md5_checksum in each book's DocSettings sidecar and in the stats DB
(book.md5), so we walk the reading history, read sidecar checksums, and join.

Extracted covers are cached as PNGs (keyed by that md5) so the expensive
document-open happens once per book; subsequent renders load from cache.
Everything is pcall-guarded — cover failures degrade to "no cover" silently.
]]

local DataStorage = require("datastorage")
local DocSettings = require("docsettings")
local FileManagerBookInfo = require("apps/filemanager/filemanagerbookinfo")
local ReadHistory = require("readhistory")
local RenderImage = require("ui/renderimage")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")

local chartcovers = {}

local HISTORY_SCAN_LIMIT = 30
local CACHE_MAX_DIM = 420 -- cached covers are pre-shrunk to fit this square

local function cacheDir()
    local base = DataStorage:getDataDir() .. "/cache"
    if lfs.attributes(base, "mode") ~= "directory" then
        lfs.mkdir(base)
    end
    local dir = base .. "/pocketbookplus-stats"
    if lfs.attributes(dir, "mode") ~= "directory" then
        lfs.mkdir(dir)
    end
    return dir
end

-- Builds md5 -> file for the wanted set by scanning recent history sidecars.
local function md5FileMap(wanted)
    local map = {}
    local remaining = 0
    for _ in pairs(wanted) do remaining = remaining + 1 end
    if remaining == 0 then return map end
    for i, entry in ipairs(ReadHistory.hist or {}) do
        if i > HISTORY_SCAN_LIMIT or remaining == 0 then break end
        local file = entry.file
        if file and lfs.attributes(file, "mode") == "file"
            and DocSettings:hasSidecarFile(file) then
            local ok, doc_settings = pcall(DocSettings.open, DocSettings, file)
            if ok and doc_settings then
                local md5 = doc_settings:readSetting("partial_md5_checksum")
                if md5 and wanted[md5] and not map[md5] then
                    map[md5] = file
                    remaining = remaining - 1
                end
            end
        end
    end
    return map
end

-- Downscale bb to fit max_w×max_h keeping aspect; never upscales.
-- Frees the original when it scales.
local function fitTo(bb, max_w, max_h)
    if not bb then return nil end
    local w, h = bb:getWidth(), bb:getHeight()
    if w <= 0 or h <= 0 then
        pcall(bb.free, bb)
        return nil
    end
    local scale = math.min(max_w / w, max_h / h)
    if scale >= 1 then return bb end
    local new_w = math.max(1, math.floor(w * scale + 0.5))
    local new_h = math.max(1, math.floor(h * scale + 0.5))
    return RenderImage:scaleBlitBuffer(bb, new_w, new_h, true)
end

-- Returns a cover bb fitted into box_w×box_h, or nil. `document` may be the
-- already-open document for this file (avoids re-opening it).
local function getCover(md5, file, document, box_w, box_h)
    local cache_file = cacheDir() .. "/" .. md5 .. ".png"
    local bb
    if lfs.attributes(cache_file, "mode") == "file" then
        local ok, cached = pcall(RenderImage.renderImageFile, RenderImage, cache_file, false)
        if ok then bb = cached end
    end
    if not bb then
        -- getCoverImage never touches self, so a class call is fine; it uses
        -- `document` directly when file == document.file, else opens the file
        -- (CreDocuments load metadata only — cheap-ish, and we cache after).
        local ok, cover = pcall(FileManagerBookInfo.getCoverImage, FileManagerBookInfo, document, file)
        if not ok or not cover then return nil end
        bb = fitTo(cover, CACHE_MAX_DIM, CACHE_MAX_DIM)
        if not bb then return nil end
        pcall(bb.writePNG, bb, cache_file)
    end
    return fitTo(bb, box_w, box_h)
end

--- Attaches cover_bb fields to data.current and data.recent entries.
-- opts = { document = <open doc or nil>, current_box = {w,h}, thumb_box = {w,h} }
-- Caller must free the covers afterwards via chartcovers.release(data).
function chartcovers.attach(data, opts)
    local ok, err = pcall(function()
        if not data then return end
        local cur = data.current
        local wanted = {}
        if cur and cur.md5 then wanted[cur.md5] = true end
        for _, book in ipairs(data.recent or {}) do
            if book.md5 then wanted[book.md5] = true end
        end
        local map = md5FileMap(wanted)
        if cur and cur.md5 then
            local file = map[cur.md5]
            local document
            if opts.document and opts.document.file then
                if not file or opts.document.file == file then
                    document = opts.document
                    file = file or opts.document.file
                end
            end
            if file then
                cur.cover_bb = getCover(cur.md5, file, document,
                    opts.current_box.w, opts.current_box.h)
            end
        end
        for _, book in ipairs(data.recent or {}) do
            local file = book.md5 and map[book.md5]
            if file then
                book.cover_bb = getCover(book.md5, file, nil,
                    opts.thumb_box.w, opts.thumb_box.h)
            end
        end
    end)
    if not ok then
        logger.warn("PocketBookPlus stats: cover attach failed:", err)
    end
end

--- Frees any cover buffers attached by attach(); safe to call repeatedly.
function chartcovers.release(data)
    if not data then return end
    if data.current and data.current.cover_bb then
        pcall(data.current.cover_bb.free, data.current.cover_bb)
        data.current.cover_bb = nil
    end
    for _, book in ipairs(data.recent or {}) do
        if book.cover_bb then
            pcall(book.cover_bb.free, book.cover_bb)
            book.cover_bb = nil
        end
    end
end

return chartcovers
