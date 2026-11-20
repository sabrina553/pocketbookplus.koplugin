--[[--
Library sync: keep the PocketBook library row of the open EPUB in step with
KOReader (home-screen progress, finished flag, and the place PBReader opens
at), and offer PBReader's position when it is newer.

Adapted from pbposition.koplugin by glaucon1984 (AGPL-3.0),
https://github.com/glaucon1984/pbposition.koplugin

Writes happen on book close, suspend and KOReader's settings save, never per
page turn: each write touches the firmware's database, and the flash wear and
lock contention are not worth it for a value only read when PBReader or the
home screen opens.
--]]--

local ConfirmBox = require("ui/widget/confirmbox")
local DocSettings = require("docsettings")
local Event = require("ui/event")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local util = require("util")
local _ = require("gettext")
local T = require("ffi/util").template

local EpubCfi = require("pocketbookplus/sync/epubcfi")
local LibraryDB = require("pocketbookplus/sync/librarydb")

local LAST_KEY = "pocketbookplus_sync_last" -- doc_settings: { ts=, position= } last written or acknowledged
local OFFER_KEY = "sync.offer_newer"

local function currentProfileName()
    local ffi = require("ffi")
    local inkview = ffi.load("inkview")
    local name = inkview.GetCurrentProfile()
    if name ~= nil then return ffi.string(name) end
    return nil
end

-- One connection for the whole process (file manager and reader instances).
local db = LibraryDB.new{ profile_name_func = currentProfileName }

-- Per-document state; one per plugin instance, kept on ctx.
local State = {}
State.__index = State

function State.new(ctx)
    local s = setmetatable({ ctx = ctx, ui = ctx.ui, settings = ctx.registry.settings }, State)
    s:reset()
    return s
end

function State:reset()
    self.ready = false
    self.codec = nil
    self.book = nil       -- { id=, profile= } or false when the library has no row
    self.last = nil
    self.status = nil
    self.offered_ts = nil
end

function State:offersNewer()
    local v = self.settings:read(OFFER_KEY)
    return v == nil or v == true
end

function State:isEpub()
    local doc = self.ui.document
    if not doc or not self.ui.rolling or not doc.file then return false end
    return doc.file:lower():match("%.epub$") ~= nil
end

function State:isActive()
    -- Scheduled callbacks can fire after the module was switched off.
    return self.ready and self:isEpub() and not db:disabled()
        and self.settings:read("sync.enabled") ~= false
end

function State:bookRow()
    if self.book ~= nil then return self.book or nil end
    local folder, file = util.splitFilePathName(self.ui.document.file)
    folder = folder:gsub("/+$", "")
    local id = db:bookId(folder, file)
    if not id then
        logger.info("PocketBookPlus sync: not in the PocketBook library:", folder .. "/" .. file)
        self.book = false
        return nil
    end
    self.book = { id = id, profile = db:profileId() }
    return self.book
end

function State:getCodec()
    if not self.codec then
        local doc = self.ui.document
        self.codec = EpubCfi.new(function(path) return doc:getDocumentFileContent(path) end)
    end
    return self.codec
end

function State:positionFromXPointer(xp)
    local doc = self.ui.document
    local cfi, exact, note = self:getCodec():fromXPointer(xp)
    if not exact and type(doc.getEPubCFIFromXPointer) == "function" then
        -- Newer KOReader can express the location itself. Keep our spine and
        -- body steps (the engine assumes /6 and /4) and drop its id assertions.
        local ok, builtin = pcall(doc.getEPubCFIFromXPointer, doc, xp)
        local bare = ok and EpubCfi.barePath(builtin)
        local after = bare and bare:match("!/%d+(.*)$")
        if cfi and after then
            local head = EpubCfi.barePath(cfi):match("^(/%d+/%d+!/%d+)")
            if head then
                cfi, exact, note = "epubcfi(" .. head .. after .. ")", true, "engine CFI"
            end
        end
    end
    if not cfi then return nil, false, note end
    return LibraryDB.POSITION_PREFIX .. cfi, exact, note
end

-- Falls back to the chapter start when the exact place does not resolve in
-- this rendering.
function State:xpointerFromPosition(position)
    if not EpubCfi.isCfi(position) then return nil end
    local doc = self.ui.document
    local codec = self:getCodec()
    local xp = codec:toXPointer(position)
    if not xp then return nil end
    local count = codec:spineCount()
    local k = tonumber(xp:match("^/body/DocFragment%[(%d+)%]"))
    if not k or (count and k > count) then return nil end
    if xp:find("/text()", 1, true) or xp:match("%]/[%w]+%[%d+%]$") then
        local ok, text = pcall(doc.getTextFromXPointer, doc, xp)
        if not ok or text == nil then
            xp = string.format("/body/DocFragment[%d]", k)
        end
    end
    return xp
end

function State:collect()
    local doc = self.ui.document
    local xp = doc:getXPointer()
    if not xp or xp == "" then return nil end
    local page = self.ui:getCurrentPage()
    local total
    if doc:getPageFlow(page) == 0 then
        total = doc:getTotalPagesInFlow(0)
        page = doc:getPageNumberInFlow(page)
    else
        total = doc:getPageCount()
    end
    if not total or total < 1 then return nil end
    local summary = self.ui.doc_settings:readSetting("summary")
    local completed = (summary and summary.status == "complete") or page >= total
    local now = os.time()
    local position, exact, note = self:positionFromXPointer(xp)
    return {
        xpointer = xp,
        cpage = math.max(page - 1, 0), -- the column is 0-based
        npage = total,
        completed = completed and 1 or 0,
        opentime = now,
        position = position,
        position_ts = position and now or nil,
        exact = exact,
        note = note,
    }
end

function State:sync(source, force)
    if not self:isActive() then return false, _("Library sync is off or not applicable.") end
    local data = self:collect()
    if not data then return false, _("No position to write.") end
    if not force and self.last and self.last.xpointer == data.xpointer
        and self.last.completed == data.completed then
        return true, _("Nothing changed since the last write.")
    end
    local book = self:bookRow()
    if not book then return false, _("This book is not in the PocketBook library.") end
    if not self.backup_checked then
        self.backup_checked = true
        if not db:backupOnce() then
            logger.warn("PocketBookPlus sync: could not back up the library database; writing anyway")
        end
    end
    if not db:writeRow(book.id, book.profile, data) then
        self.status = _("Last write failed; see crash.log.")
        return false, _("Database write failed.")
    end
    self.last = data
    if data.position then
        self.ui.doc_settings:saveSetting(LAST_KEY, { ts = data.position_ts, position = data.position })
    end
    logger.info(string.format("PocketBookPlus sync: wrote book %d page %d/%d completed %d position %s%s (%s)",
        book.id, data.cpage + 1, data.npage, data.completed, tostring(data.position),
        data.exact and "" or (" [" .. tostring(data.note) .. "]"), source))
    self.status = T(_("Last write: %1."), source)
    return true, T(_("Written: page %1 of %2%3"), data.cpage + 1, data.npage,
        data.position and "" or _(", position not mapped"))
end

-- Our last write, else the sidecar's mtime (read in KOReader before this
-- plugin), else 0 (first opening in KOReader).
function State:baselineTimestamp()
    local last = self.ui.doc_settings:readSetting(LAST_KEY)
    if last and last.ts then return last.ts, last.position end
    local sidecar = DocSettings:findSidecarFile(self.ui.document.file)
    if sidecar then
        local mtime = require("libs/libkoreader-lfs").attributes(sidecar, "modification")
        if mtime then return mtime, nil end
    end
    return 0, nil
end

function State:offerNewerPosition(trigger)
    if not self:isActive() or not self:offersNewer() then return end
    local book = self:bookRow()
    if not book then return end
    local row = db:readRow(book.id, book.profile)
    if not row or not row.position or not row.position_ts then return end
    if not EpubCfi.isCfi(row.position) then return end
    local baseline_ts, baseline_position = self:baselineTimestamp()
    if row.position_ts <= baseline_ts or row.position == baseline_position then return end
    if self.offered_ts == row.position_ts then return end
    self.offered_ts = row.position_ts

    local function acknowledge()
        self.ui.doc_settings:saveSetting(LAST_KEY, { ts = row.position_ts, position = row.position })
    end
    local xp = self:xpointerFromPosition(row.position)
    if not xp then
        logger.info("PocketBookPlus sync: PBReader position not mappable, ignoring:", row.position)
        acknowledge()
        return
    end
    local doc = self.ui.document
    local page = doc:getPageFromXPointer(xp)
    if page == self.ui:getCurrentPage() then
        acknowledge()
        return
    end
    local chapter = self.ui.toc and self.ui.toc:getTocTitleByPage(xp) or ""
    local where = chapter ~= "" and T(_("%1, page %2 of %3"), chapter, page, doc:getPageCount())
        or T(_("page %1 of %2"), page, doc:getPageCount())
    logger.info("PocketBookPlus sync: PBReader has a newer position", row.position, "page", page, "(" .. trigger .. ")")
    UIManager:show(ConfirmBox:new{
        text = T(_("PBReader has a newer reading position for this book:\n%1 (%2).\n\nGo there?"),
            where, os.date("%Y-%m-%d %H:%M", row.position_ts)),
        ok_text = _("Go there"),
        cancel_text = _("Stay here"),
        ok_callback = function()
            acknowledge()
            self.ui:handleEvent(Event:new("GotoXPointer", xp))
        end,
        cancel_callback = acknowledge,
    })
end

function State:statusText()
    local lines = { T(_("Library database: %1"), db.db_path) }
    if db:disabled() then
        table.insert(lines, _("Database access disabled for this session after repeated errors."))
    end
    if not self.ui.document then
        table.insert(lines, _("No book open."))
    elseif not self:isEpub() then
        table.insert(lines, _("Not an EPUB: positions are written for EPUBs only."))
    elseif self.book == false then
        table.insert(lines, _("This book is not in the PocketBook library."))
    elseif self.book then
        table.insert(lines, T(_("Library book id %1, profile %2."), self.book.id, self.book.profile))
    end
    if self.last then
        table.insert(lines, T(_("Last write: page %1 of %2, %3"), self.last.cpage + 1, self.last.npage,
            self.last.position or _("no position (chapter could not be mapped)")))
    end
    if self.status then table.insert(lines, self.status) end
    return table.concat(lines, "\n")
end

-------------------------------------------------------------------------------
-- Module hooks
-------------------------------------------------------------------------------

local Sync = {
    id = "sync",
    name = _("Library sync"),
    default_enabled = true,
}

local function state(ctx)
    if not ctx._pbplus_sync then ctx._pbplus_sync = State.new(ctx) end
    return ctx._pbplus_sync
end

function Sync.onReaderReady(ctx)
    local s = state(ctx)
    s:reset()
    if not s:isEpub() then return end
    s.ready = true
    -- Let the reader settle before possibly showing a dialog.
    UIManager:scheduleIn(0.5, function()
        if s.ready then s:offerNewerPosition("open") end
    end)
end

function Sync.onSaveSettings(ctx)
    state(ctx):sync("save")
end

function Sync.onSuspend(ctx)
    state(ctx):sync("suspend")
end

function Sync.onResume(ctx)
    local s = state(ctx)
    if s:isActive() then
        UIManager:scheduleIn(1, function()
            if s.ready then s:offerNewerPosition("resume") end
        end)
    end
end

function Sync.onCloseDocument(ctx)
    local s = state(ctx)
    s:sync("close")
    s.ready = false
    s.codec = nil
end

function Sync.menuItems(ctx)
    local s = state(ctx)
    return {
        {
            text = _("Offer a newer PBReader position when opening"),
            help_text = _("When PBReader saved a position after this plugin's last write, ask whether to go there."),
            checked_func = function() return s:offersNewer() end,
            callback = function() s.settings:save(OFFER_KEY, not s:offersNewer()) end,
            separator = true,
        },
        {
            text = _("Write now"),
            enabled_func = function() return s.ready end,
            callback = function()
                local ok, msg = s:sync("manual", true)
                UIManager:show(InfoMessage:new{ text = msg, timeout = ok and 2 or 5 })
            end,
        },
        {
            text = _("Status"),
            keep_menu_open = true,
            callback = function() UIManager:show(InfoMessage:new{ text = s:statusText() }) end,
        },
    }
end

return Sync
