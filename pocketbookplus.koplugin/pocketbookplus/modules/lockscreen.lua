--[[--
Lock screen: the book cover (optionally with a progress bar) or an image of
your own on the PocketBook's standby screen, the cover on the power-off
screen, and optionally the last page read as the boot screen.

Adapted from standbycover.koplugin by glaucon1984 (AGPL-3.0),
https://github.com/glaucon1984/standbycover.koplugin

How the firmware side works (Line theme, firmware 6.x):
- The standby screen is drawn from system/resources/Line/
  taskmgr_lock_background.bmp (plus a _landscape twin). The task manager
  keeps a copy loaded at start, so after each write it is asked to reload
  with EVT_CONFIGCHANGED (154) through iv2sh, a method found by the author of
  coverprogresspocketbook.koplugin. Never while going to sleep: on the Era
  Lite that leaves the device half asleep.
- The power-off screen is system/logo/bookcover when "Power-off logo" is set
  to the book cover.
- The boot screen is a flash partition only `iv2sh WriteStartupLogo` writes.

The cover is drawn from the book file, never captured from the screen, so
KOReader's night mode cannot invert it.
--]]--

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local FileManagerBookInfo = require("apps/filemanager/filemanagerbookinfo")
local Font = require("ui/font")
local InfoMessage = require("ui/widget/infomessage")
local RenderImage = require("ui/renderimage")
local TextBoxWidget = require("ui/widget/textboxwidget")
local UIManager = require("ui/uimanager")
local ffi = require("ffi")
local ffiutil = require("ffi/util")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local util = require("util")
local _ = require("gettext")
local T = ffiutil.template
local PBConfig = require("pocketbookplus/pbconfig")

local LINE_DIR = "/mnt/ext1/system/resources/Line"
local LOCK_PORTRAIT = LINE_DIR .. "/taskmgr_lock_background.bmp"
local LOCK_LANDSCAPE = LINE_DIR .. "/taskmgr_lock_background_landscape.bmp"
local POWEROFF_COVER = "/mnt/ext1/system/logo/bookcover"
local BACKUP_SUFFIX = ".orig"
-- Outside the plugin folder so updating the plugin keeps the user's images.
local CUSTOM_DIR = "/mnt/ext1/lockscreens"
local IMAGE_EXTS = { bmp = true, png = true, jpg = true, jpeg = true, gif = true, webp = true }

local BOOT_IMAGE = "/tmp/pocketbookplus_boot.bmp"
local BOOT_TOOL = "/ebrmain/bin/iv2sh"

-- Modes for the standby screen.
local MODE_COVER, MODE_CUSTOM_FIXED, MODE_CUSTOM_RANDOM = "cover", "custom_fixed", "custom_random"
local MODE_STATS = "stats"
-- Statistics change slowly and the dashboard is costlier to draw (database
-- reads, cover thumbnails), so it is redrawn at most this often while reading.
local STATS_MIN_INTERVAL_S = 300

-- Shared by the reader's and file manager's instances (the process keeps it).
local State = {
    cover = nil, title = nil, authors = nil,
    percent = nil,          -- 0..1 of the open book, or nil
    written_percent = nil,  -- whole percent last drawn into the lock image
    pending_reload = false,
    boot_hash = nil,
}

local settings

local function setting(key, default)
    local v = settings:read("lockscreen." .. key)
    if v == nil then return default end
    return v
end
local function save(key, v) settings:save("lockscreen." .. key, v) end

local function mode() return setting("mode", MODE_COVER) end
local function progressBar() return setting("progress_bar", true) end
local function powerOff() return setting("poweroff", true) end
local function bootLogo() return setting("bootlogo", false) end
-- "fit", "fill" or "stretch". The boolean `lockscreen.fill` is still read so
-- settings saved before `scaling` existed keep their look.
local SCALINGS = { fit = true, fill = true, stretch = true }
local function scalingFrom(scaling, fill)
    if SCALINGS[scaling] then return scaling end
    if fill == false then return "fit" end
    return "fill"
end
local function scaling()
    return scalingFrom(settings:read("lockscreen.scaling"), settings:read("lockscreen.fill"))
end

-- Images are always stored in normal colours: the firmware inverts the lock
-- screen itself when PocketBook dark mode (screen_mode_inverted) is on.

-------------------------------------------------------------------------------
-- Custom images
-------------------------------------------------------------------------------

local function listCustomImages()
    local files = {}
    if lfs.attributes(CUSTOM_DIR, "mode") ~= "directory" then return files end
    for name in lfs.dir(CUSTOM_DIR) do
        local ext = name:match("%.([^.]+)$")
        if ext and IMAGE_EXTS[ext:lower()] and not name:match("^%.") then
            table.insert(files, name)
        end
    end
    table.sort(files)
    return files
end

-- The image for this write: the chosen one, or a random one different from
-- the last when there is a choice.
local function pickCustomImage()
    local files = listCustomImages()
    if #files == 0 then return nil end
    if mode() == MODE_CUSTOM_FIXED then
        local chosen = setting("custom_file", nil)
        for _i, f in ipairs(files) do
            if f == chosen then return CUSTOM_DIR .. "/" .. f end
        end
        return CUSTOM_DIR .. "/" .. files[1]
    end
    local last = setting("last_random", nil)
    local pick
    repeat
        pick = files[math.random(#files)]
    until #files == 1 or pick ~= last
    save("last_random", pick)
    return CUSTOM_DIR .. "/" .. pick
end

-------------------------------------------------------------------------------
-- Drawing
-------------------------------------------------------------------------------

local function fitInto(img, w, h)
    local iw, ih = img:getWidth(), img:getHeight()
    local scale = math.min(w / iw, h / ih)
    local sw = math.max(1, math.floor(iw * scale + 0.5))
    local sh = math.max(1, math.floor(ih * scale + 0.5))
    -- `false`: keep `img`; scaleBlitBuffer frees its input by default.
    return RenderImage:scaleBlitBuffer(img, sw, sh, false), sw, sh
end

local function blitCentred(bb, img, w, h)
    local scaled, sw, sh = fitInto(img, w, h)
    bb:blitFrom(scaled, math.floor((w - sw) / 2), math.floor((h - sh) / 2), 0, 0, sw, sh)
    if scaled ~= img then scaled:free() end
end

-- Covers are usually ~2:3 and the panel ~3:4, so fitting leaves bands at the
-- sides. Filling scales up until both sides are covered and crops the
-- overflow evenly.
local function blitFilled(bb, img, w, h)
    local iw, ih = img:getWidth(), img:getHeight()
    local scale = math.max(w / iw, h / ih)
    local sw = math.max(w, math.floor(iw * scale + 0.5))
    local sh = math.max(h, math.floor(ih * scale + 0.5))
    local scaled = RenderImage:scaleBlitBuffer(img, sw, sh, false)
    bb:blitFrom(scaled, 0, 0, math.floor((sw - w) / 2), math.floor((sh - h) / 2), w, h)
    if scaled ~= img then scaled:free() end
end

-- Scales each axis independently to the screen size, ignoring the aspect
-- ratio: nothing is cropped and there are no bands, at the cost of a slightly
-- wider image (~12% for a 2:3 cover on a 3:4 panel).
local function blitStretched(bb, img, w, h)
    local scaled = RenderImage:scaleBlitBuffer(img, w, h, false)
    bb:blitFrom(scaled, 0, 0, 0, 0, w, h)
    if scaled ~= img then scaled:free() end
end

local function blitImage(bb, img, w, h)
    local s = scaling()
    if s == "fill" then blitFilled(bb, img, w, h)
    elseif s == "stretch" then blitStretched(bb, img, w, h)
    else blitCentred(bb, img, w, h) end
end

local function paintTitle(bb, w, h)
    local width = math.floor(w * 0.8)
    local y = math.floor(h * 0.35)
    for i, line in ipairs({ { State.title or _("Untitled"), 32 }, { State.authors, 22 } }) do
        local text, size = line[1], line[2]
        if text and text ~= "" then
            local box = TextBoxWidget:new{
                text = text,
                face = Font:getFace("NotoSerif-Regular.ttf", size) or Font:getFace("tfont", size),
                width = width,
                alignment = "center",
            }
            local bh = box:getSize().h
            box:paintTo(bb, math.floor((w - width) / 2), y)
            box:free()
            y = y + bh + (i == 1 and Device.screen:scaleBySize(24) or 0)
        end
    end
end

-- Overlaid on the cover near the bottom: a white rounded pill holding the
-- bar and percentage, so it reads over dark and light covers alike.
local function paintProgress(bb, w, h)
    if not State.percent then return end
    local S = Device.screen
    local margin = S:scaleBySize(32)
    local pad = S:scaleBySize(10)
    local bar_h = S:scaleBySize(8)
    local label = string.format("%d%%", math.floor(State.percent * 100))
    local box = TextBoxWidget:new{ text = label, face = Font:getFace("cfont", 16), width = S:scaleBySize(64), alignment = "right" }
    local text_h = box:getSize().h
    local pill_h = text_h + 2 * pad
    local pill_y = h - margin - pill_h
    local pill_w = w - 2 * margin
    bb:paintRoundedRect(margin, pill_y, pill_w, pill_h, Blitbuffer.COLOR_WHITE, math.floor(pill_h / 2))
    bb:paintBorder(margin, pill_y, pill_w, pill_h, 1, Blitbuffer.COLOR_BLACK, math.floor(pill_h / 2))
    local bx = margin + pill_h / 2
    local bw = pill_w - pill_h - box:getSize().w - pad
    local by = pill_y + math.floor((pill_h - bar_h) / 2)
    bx, bw = math.floor(bx), math.floor(bw)
    bb:paintBorder(bx, by, bw, bar_h, 1, Blitbuffer.COLOR_BLACK)
    bb:paintRect(bx, by, math.floor(bw * State.percent), bar_h, Blitbuffer.COLOR_BLACK)
    box:paintTo(bb, bx + bw + pad, pill_y + pad)
    box:free()
end

local function composeCover(w, h, with_progress)
    local bb = Blitbuffer.new(w, h, Blitbuffer.TYPE_BB8)
    bb:fill(Blitbuffer.COLOR_WHITE)
    if State.cover then
        blitImage(bb, State.cover, w, h)
    else
        paintTitle(bb, w, h)
    end
    if with_progress then paintProgress(bb, w, h) end
    return bb
end

-- Collected once per write and drawn in both orientations.
local function collectStats()
    local ok, data = pcall(function()
        local DataStorage = require("datastorage")
        local ChartStats = require("pocketbookplus/stats/chartstats")
        -- Without a heading there is room for two more recent books.
        return ChartStats.collect(DataStorage:getSettingsDir() .. "/statistics.sqlite3",
            { recent_count = setting("stats_signature", "") ~= "" and 4 or 6 })
    end)
    if not ok then
        logger.warn("PocketBookPlus lockscreen: stats collect failed:", data)
        return nil
    end
    return data
end

local function composeStats(w, h, ctx, data)
    local ok, bb = pcall(function()
        local ChartCovers = require("pocketbookplus/stats/chartcovers")
        local ChartRender = require("pocketbookplus/stats/chartrender")
        local signature = setting("stats_signature", "")
        if data then
            local cur_w, thumb_w = math.floor(w * 0.18), math.floor(w * 0.07)
            ChartCovers.attach(data, {
                document = ctx and ctx.ui and ctx.ui.document or nil,
                current_box = { w = cur_w, h = math.floor(cur_w * 1.5) },
                thumb_box = { w = thumb_w, h = math.floor(thumb_w * 1.5) },
            })
        end
        local out = ChartRender.build(data, w, h, {
            signature = signature ~= "" and signature or nil,
            footer = false,
        })
        ChartCovers.release(data)
        return out
    end)
    if not ok then
        logger.warn("PocketBookPlus lockscreen: stats render failed:", bb)
        return nil
    end
    return bb
end

local function composeCustom(w, h, path)
    local img = RenderImage:renderImageFile(path, false)
    if not img then
        logger.warn("PocketBookPlus lockscreen: could not read", path)
        return nil
    end
    local bb = Blitbuffer.new(w, h, Blitbuffer.TYPE_BB8)
    bb:fill(Blitbuffer.COLOR_WHITE)
    blitImage(bb, img, w, h)
    img:free()
    return bb
end

-- The firmware turns the lock image itself but draws the power-off image in
-- the panel's own orientation.
local function orientForPanel(bb)
    local S = Device.screen
    local m = S:getRotationMode()
    if m == S.DEVICE_ROTATED_UPSIDE_DOWN or m == S.DEVICE_ROTATED_CLOCKWISE then
        local turned = bb:rotatedCopy(180)
        bb:free()
        return turned
    end
    return bb
end

local function writeImage(bb, path, orient)
    if not bb then return false end
    if orient then bb = orientForPanel(bb) end
    -- Written aside and renamed, so the firmware never reads a half-written file.
    local tmp = path .. ".tmp"
    local ok = bb:writeToFile(tmp, "bmp", 100, true)
    bb:free()
    if not ok or not os.rename(tmp, path) then
        os.remove(tmp)
        return false
    end
    return true
end

-- The firmware's own image is kept once, so it can be put back.
local function backupOnce(path)
    if lfs.attributes(path, "mode") ~= "file" then return end
    if lfs.attributes(path .. BACKUP_SUFFIX, "mode") == "file" then return end
    ffiutil.copyFile(path, path .. BACKUP_SUFFIX)
end

local function restoreFile(path)
    if lfs.attributes(path .. BACKUP_SUFFIX, "mode") == "file" then
        ffiutil.copyFile(path .. BACKUP_SUFFIX, path)
        os.remove(path .. BACKUP_SUFFIX)
    else
        os.remove(path)
    end
end

-- Width and height from a BMP header (BITMAPINFOHEADER), or nil.
local function bmpSize(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local head = f:read(26)
    f:close()
    if not head or #head < 26 or head:sub(1, 2) ~= "BM" then return nil end
    local function le32(i)
        local a, b, c, d = head:byte(i, i + 3)
        local v = a + b * 256 + c * 65536 + d * 16777216
        if v >= 2147483648 then v = v - 4294967296 end
        return v
    end
    return le32(19), math.abs(le32(23)) -- height is negative for top-down rows
end

local function copyFile(src, dst)
    local tmp = dst .. ".tmp"
    if ffiutil.copyFile(src, tmp) then -- returns an error message on failure
        os.remove(tmp)
        return false
    end
    if not os.rename(tmp, dst) then
        os.remove(tmp)
        return false
    end
    return true
end

local function panelSize()
    local S = Device.screen
    local w, h = S:getScreenWidth(), S:getScreenHeight()
    if w > h then w, h = h, w end
    return w, h
end

-------------------------------------------------------------------------------
-- Writing
-------------------------------------------------------------------------------

local function requestReload(reason)
    if reason == "suspend" then
        State.pending_reload = true
        return
    end
    State.pending_reload = false
    PBConfig.reloadTaskmgr()
    logger.info("PocketBookPlus lockscreen: asked taskmgr to reload (" .. tostring(reason) .. ")")
end

local function writeLockImages(reason, ctx)
    local w, h = panelSize()
    local portrait, landscape
    if mode() == MODE_STATS then
        local data = collectStats()
        portrait, landscape = composeStats(w, h, ctx, data), composeStats(h, w, ctx, data)
        State.stats_written_at = os.time()
        if not portrait then return false end
    elseif mode() == MODE_COVER then
        portrait, landscape = composeCover(w, h, progressBar()), composeCover(h, w, progressBar())
        State.written_percent = State.percent and math.floor(State.percent * 100)
    else
        local path = pickCustomImage()
        if not path then
            logger.info("PocketBookPlus lockscreen: no images in", CUSTOM_DIR)
            return false
        end
        -- A BMP already at panel size goes across byte for byte: the
        -- firmware's own images rely on their exact colours, which a
        -- greyscale redraw would flatten.
        local bw, bh = bmpSize(path)
        if bw == w and bh == h then
            util.makePath(LINE_DIR)
            backupOnce(LOCK_PORTRAIT)
            backupOnce(LOCK_LANDSCAPE)
            local ok = copyFile(path, LOCK_PORTRAIT)
                and writeImage(composeCustom(h, w, path), LOCK_LANDSCAPE, false)
            logger.info("PocketBookPlus lockscreen: custom image copied (" .. tostring(reason) .. ")", ok and "ok" or "FAILED")
            if ok then requestReload(reason) end
            return ok
        end
        portrait, landscape = composeCustom(w, h, path), composeCustom(h, w, path)
    end
    util.makePath(LINE_DIR)
    backupOnce(LOCK_PORTRAIT)
    backupOnce(LOCK_LANDSCAPE)
    local ok = writeImage(portrait, LOCK_PORTRAIT, false) and writeImage(landscape, LOCK_LANDSCAPE, false)
    logger.info("PocketBookPlus lockscreen: lock images written (" .. tostring(reason) .. ")", ok and "ok" or "FAILED")
    if ok then requestReload(reason) end
    return ok
end

local function writePowerOff(reason)
    if not powerOff() then return true end
    local w, h = panelSize()
    local ok = writeImage(composeCover(w, h, false), POWEROFF_COVER, true)
    logger.info("PocketBookPlus lockscreen: power-off cover written (" .. tostring(reason) .. ")", ok and "ok" or "FAILED")
    return ok
end

-------------------------------------------------------------------------------
-- Boot screen: a capture of the panel
-------------------------------------------------------------------------------

-- Only the reader's page view is drawn, so menus and pop-ups open on top of
-- it are left out. The canvas takes the screen's rotation and inverse while
-- drawing, then both are cleared so the result is what the panel would show.
local function capturePage(ctx)
    local fb = Device.screen.bb
    local rotation, inverse = fb:getRotation(), fb:getInverse()
    fb:setRotation(0)
    local w, h = fb:getWidth(), fb:getHeight()
    fb:setRotation(rotation)
    local page = Blitbuffer.new(w, h, Blitbuffer.TYPE_BB8)
    page:setRotation(rotation)
    page:setInverse(inverse)
    page:fill(Blitbuffer.COLOR_WHITE)
    ctx.ui.view:paintTo(page, 0, 0)
    page:setRotation(0)
    page:setInverse(0)
    return page
end

-- Sparse fingerprint, enough to skip rewriting the flash for the same page.
local function quickHash(bb)
    local data = ffi.cast("uint8_t*", bb.data)
    local w, h, stride = bb:getWidth(), bb:getHeight(), tonumber(bb.stride)
    local a, b = 1, 0
    for y = 0, h - 1, 7 do
        local row = data + y * stride
        for x = 0, w - 1, 61 do
            a = (a + row[x]) % 65521
            b = (b + a) % 65521
        end
    end
    return b * 65536 + a
end

-- The firmware suspends the CPU a few seconds after the last input whatever
-- runs, and the tool takes seconds, so auto-standby is held off meanwhile.
local function writeBootImage(ctx, reason)
    if not bootLogo() then return end
    local ok, err = pcall(function()
        local dump = capturePage(ctx)
        local hash = quickHash(dump)
        if hash == State.boot_hash then dump:free() return end
        local written = dump:writeToFile(BOOT_IMAGE, "bmp", 100, true)
        dump:free()
        if not written then return end
        pcall(Device.setAutoStandby, Device, false)
        local rc = os.execute("sync; " .. BOOT_TOOL .. " WriteStartupLogo " .. util.shell_escape({ BOOT_IMAGE }))
        pcall(Device.setAutoStandby, Device, true)
        os.remove(BOOT_IMAGE)
        if rc == 0 then State.boot_hash = hash end
        logger.info("PocketBookPlus lockscreen: boot screen written (" .. tostring(reason) .. "), rc", rc)
    end)
    if not ok then
        pcall(Device.setAutoStandby, Device, true)
        logger.warn("PocketBookPlus lockscreen: boot screen failed:", err)
    end
end

-------------------------------------------------------------------------------
-- The current book
-------------------------------------------------------------------------------

-- The firmware only shows our boot and power-off images when its own logo
-- options are set to "Book cover" (@cover_logo in global.cfg). Switching a
-- toggle on sets that and remembers the previous value; off puts it back.
local COVER_LOGO = "@cover_logo"

local function setFirmwareLogo(key, on)
    local saved_key = "firmware_" .. key
    if on then
        local current = PBConfig.get(key)
        if current == COVER_LOGO then return end
        if current then save(saved_key, current) end
        local ok, err = PBConfig.set(key, COVER_LOGO)
        logger.info("PocketBookPlus lockscreen: firmware", key, "->", COVER_LOGO, ok and "ok" or err)
        if not ok then
            UIManager:show(InfoMessage:new{
                text = T(_("Could not change the PocketBook setting (%1). Set it to Book cover under Settings → Personalise → Logos."), err),
            })
        end
    else
        local previous = setting(saved_key, nil)
        if previous and PBConfig.get(key) == COVER_LOGO then
            local ok, err = PBConfig.set(key, previous)
            logger.info("PocketBookPlus lockscreen: firmware", key, "restored to", previous, ok and "ok" or err)
        end
        save(saved_key, nil)
    end
end

local function inReader(ctx) return ctx.ui and ctx.ui.document ~= nil end

local function currentPercent(ctx)
    local doc = ctx.ui.document
    local page = ctx.ui.getCurrentPage and ctx.ui:getCurrentPage()
    local total = doc and doc:getPageCount()
    if not page or not total or total < 1 then return nil end
    return math.min(1, page / total)
end

local function loadBook(ctx)
    if State.cover then State.cover:free() end
    local doc = ctx.ui.document
    local props = ctx.ui.doc_props or {}
    State.title = props.display_title or (doc.file and doc.file:match("([^/]+)$"))
    State.authors = props.authors
    State.cover = FileManagerBookInfo:getCoverImage(doc) or nil
    State.percent = currentPercent(ctx)
end

-------------------------------------------------------------------------------
-- Module hooks
-------------------------------------------------------------------------------

local LockScreen = {
    id = "lockscreen",
    name = _("Lock screen"),
    default_enabled = true,
}

function LockScreen.init(ctx)
    settings = ctx.registry.settings
    math.randomseed(os.time())
end

function LockScreen.onReaderReady(ctx)
    settings = ctx.registry.settings
    loadBook(ctx)
    if mode() == MODE_STATS then
        -- Drawn a moment later so opening the book stays quick.
        UIManager:scheduleIn(5, function() writeLockImages("open", ctx) end)
    else
        writeLockImages("open")
    end
    if mode() == MODE_COVER then writePowerOff("open") end
end

-- Each lock image is ~4.6 MB, so the progress bar is redrawn only once page
-- turns pause and the whole percent has changed: page turns stay fast and
-- the flash is not rewritten per page.
local DEBOUNCE_S = 8
local function writeProgressIfChanged(reason)
    local whole = State.percent and math.floor(State.percent * 100)
    if whole and whole ~= State.written_percent then
        writeLockImages(reason or "progress")
    end
end

local function writeStatsIfDue(ctx, reason)
    if os.time() - (State.stats_written_at or 0) >= STATS_MIN_INTERVAL_S then
        writeLockImages(reason or "stats", ctx)
    end
end

function LockScreen.onPageUpdate(ctx)
    if mode() == MODE_STATS and inReader(ctx) then
        if State.stats_job then UIManager:unschedule(State.stats_job) end
        State.stats_job = function() writeStatsIfDue(ctx) end
        UIManager:scheduleIn(DEBOUNCE_S, State.stats_job)
        return
    end
    if mode() ~= MODE_COVER or not progressBar() or not inReader(ctx) then return end
    State.percent = currentPercent(ctx)
    UIManager:unschedule(writeProgressIfChanged)
    UIManager:scheduleIn(DEBOUNCE_S, writeProgressIfChanged)
end

function LockScreen.onCloseDocument(ctx)
    UIManager:unschedule(writeProgressIfChanged)
    if State.stats_job then UIManager:unschedule(State.stats_job) end
    if mode() == MODE_STATS then
        -- The statistics plugin saves the session while handling this same
        -- event, so draw once it is done.
        UIManager:nextTick(function() writeLockImages("close", ctx) end)
        return
    end
    if mode() == MODE_COVER and progressBar() and inReader(ctx) then
        State.percent = currentPercent(ctx)
        writeProgressIfChanged()
    end
end

-- A new random image is chosen after each wake, so the next standby shows it.
function LockScreen.onResume()
    if mode() == MODE_CUSTOM_RANDOM then
        writeLockImages("resume")
    elseif State.pending_reload then
        requestReload("resume")
    end
end

-- KOReader draws no sleep screen on PocketBook, so the page is still on the
-- panel here: this is the capture for the boot screen. A pending progress
-- write goes now too, ready for the next standby.
function LockScreen.onSuspend(ctx)
    if not inReader(ctx) then return end
    -- "suspend" defers the firmware reload: reloading while going to sleep
    -- leaves the device half asleep.
    if UIManager:unschedule(writeProgressIfChanged) then
        writeProgressIfChanged("suspend")
    end
    -- Left pending it would fire on wake and stall the reader while it draws.
    if State.stats_job and UIManager:unschedule(State.stats_job) then
        State.stats_job = nil
        writeStatsIfDue(ctx, "suspend")
    end
    writeBootImage(ctx, "suspend")
end

function LockScreen.onPowerOff(ctx)
    if inReader(ctx) then writeBootImage(ctx, "power off") end
end
LockScreen.onReboot = LockScreen.onPowerOff

function LockScreen.onToggle(ctx, on)
    settings = ctx.registry.settings
    if on then
        if inReader(ctx) then loadBook(ctx) end
        writeLockImages("enable")
    else
        restoreFile(LOCK_PORTRAIT)
        restoreFile(LOCK_LANDSCAPE)
        requestReload("disable")
    end
end

local function refresh(ctx, reason)
    if inReader(ctx) then loadBook(ctx) end
    if mode() == MODE_COVER and not State.cover and not State.title then return false end
    return writeLockImages(reason, ctx)
end

function LockScreen.menuItems(ctx)
    settings = ctx.registry.settings
    local function scalingItem(s, text, help)
        return {
            text = text,
            help_text = help,
            radio = true,
            checked_func = function() return scaling() == s end,
            callback = function()
                save("scaling", s)
                refresh(ctx, "setting")
                if mode() == MODE_COVER and inReader(ctx) then writePowerOff("setting") end
            end,
        }
    end

    local function modeItem(m, text, help)
        return {
            text = text,
            help_text = help,
            radio = true,
            checked_func = function() return mode() == m end,
            callback = function()
                save("mode", m)
                refresh(ctx, "mode")
            end,
        }
    end
    local function chooseImageItems()
        local items = {}
        for _i, f in ipairs(listCustomImages()) do
            table.insert(items, {
                text = f,
                radio = true,
                checked_func = function() return setting("custom_file", nil) == f end,
                callback = function()
                    save("custom_file", f)
                    if mode() == MODE_CUSTOM_FIXED then refresh(ctx, "image") end
                end,
            })
        end
        if #items == 0 then
            table.insert(items, { text = T(_("No images in %1"), CUSTOM_DIR), enabled = false })
        end
        return items
    end
    return {
        modeItem(MODE_COVER, _("Book cover")),
        modeItem(MODE_STATS, _("Reading stats"),
            _("A dashboard from KOReader's reading statistics: the current book with its progress, recent books, day streak and reading time. Redrawn when a book opens or closes, and at most every five minutes while reading.")),
        modeItem(MODE_CUSTOM_FIXED, _("My image"),
            T(_("Shows the image chosen below. Put BMP, PNG or JPG files in %1 (the lockscreens folder at the top of the device's storage over USB)."), CUSTOM_DIR)),
        modeItem(MODE_CUSTOM_RANDOM, _("Random image each wake"),
            T(_("Picks a different image from %1 after every wake, so the next standby shows a new one."), CUSTOM_DIR)),
        {
            text = _("Stats heading text"),
            help_text = _("Optional text at the top of the reading-stats screen (ASCII art works). Empty shows two more recent books instead."),
            enabled_func = function() return mode() == MODE_STATS end,
            keep_menu_open = true,
            callback = function()
                local InputDialog = require("ui/widget/inputdialog")
                local dialog
                dialog = InputDialog:new{
                    title = _("Stats heading text"),
                    input = setting("stats_signature", ""),
                    allow_newline = true,
                    buttons = { {
                        { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
                        { text = _("Save"), is_enter_default = true, callback = function()
                            save("stats_signature", dialog:getInputText())
                            UIManager:close(dialog)
                            refresh(ctx, "setting")
                        end },
                    } },
                }
                UIManager:show(dialog)
                dialog:onShowKeyboard()
            end,
        },
        {
            text = _("Choose image"),
            enabled_func = function() return mode() == MODE_CUSTOM_FIXED end,
            sub_item_table_func = chooseImageItems,
            separator = true,
        },
        {
            text = _("Cover scaling"),
            help_text = _("How the image is fitted to the screen when its shape differs. Applies to the lock and power-off screens."),
            sub_item_table = {
                scalingItem("fit", _("Fit (white bands)"),
                    _("Keeps the whole image and its proportions, leaving white bands at the sides or top and bottom.")),
                scalingItem("fill", _("Fill (crop edges)"),
                    _("Scales the image until it covers the whole screen and trims what overflows.")),
                scalingItem("stretch", _("Stretch (ignore aspect ratio)"),
                    _("Stretches the image to the screen's exact size. Nothing is cut off, but the image is slightly distorted.")),
            },
        },
        {
            text = _("Progress bar on the cover"),
            enabled_func = function() return mode() == MODE_COVER end,
            checked_func = progressBar,
            callback = function()
                save("progress_bar", not progressBar())
                refresh(ctx, "setting")
            end,
        },
        {
            text = _("Cover as the power-off image"),
            help_text = _([[Writes the cover to system/logo/bookcover and sets the PocketBook's "Power-off logo" to Book cover. Turning it off puts the previous logo setting back.]]),
            checked_func = powerOff,
            callback = function()
                save("poweroff", not powerOff())
                setFirmwareLogo("offlogo", powerOff())
                if powerOff() and inReader(ctx) then loadBook(ctx) writePowerOff("setting") end
            end,
        },
        {
            text = _("Boot screen: the last page read"),
            help_text = _([[At each standby, a capture of the page is stored as the boot screen, and the PocketBook's "Boot logo" is set to Book cover so it is shown. Turning it off puts the previous logo setting back. The firmware's tool takes a few seconds, during which the device is kept awake. Nothing is written when the page has not changed.]]),
            checked_func = bootLogo,
            callback = function()
                save("bootlogo", not bootLogo())
                setFirmwareLogo("bootlogo", bootLogo())
                State.boot_hash = nil
            end,
            separator = true,
        },
        {
            text = _("Update now"),
            keep_menu_open = true,
            callback = function()
                local ok = refresh(ctx, "manual")
                UIManager:show(InfoMessage:new{
                    text = ok and _("Lock screen updated.") or _("Nothing to write; see crash.log."),
                    timeout = 3,
                })
            end,
        },
        {
            text = _("Restore the firmware's image"),
            keep_menu_open = true,
            callback = function()
                restoreFile(LOCK_PORTRAIT)
                restoreFile(LOCK_LANDSCAPE)
                requestReload("restore")
                UIManager:show(InfoMessage:new{ text = _("The firmware's own lock image is back."), timeout = 3 })
            end,
        },
    }
end

-- Exposed for tests.
LockScreen._scalingFrom = scalingFrom

return LockScreen
