--[[--
Device fixes: Home button as Back, page-turn buttons that follow the screen
rotation, and no upside-down start.

Adapted from pbfixes.koplugin v0.4.1 by glaucon1984 (AGPL-3.0),
https://github.com/glaucon1984/pbfixes.koplugin

All done at runtime (KOReader's input tables, InkView calls) so no KOReader
file is patched and the changes survive updates.
--]]--

local Device = require("device")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local _ = require("gettext")

local HOME_KEY = "fixes.home_back"
local ROTATION_KEY = "fixes.rotation_map"
local ORIENTATION_KEY = "fixes.orientation_mode"
local BATTERY_TITLE_KEY = "fixes.battery_title_closes"
local DARK_LINK_KEY = "fixes.link_dark_mode"

local Fixes = {
    id = "fixes",
    name = _("Device fixes"),
    default_enabled = true,
}

-- Set in init; module functions below read toggles through it.
local settings
local active = false

local function readBool(key, default)
    local v = settings:read(key)
    if v == nil then return default end
    return v == true
end

-------------------------------------------------------------------------------
-- Home -> Back
-------------------------------------------------------------------------------

-- Raw key codes the device maps to "Home". Stashed on the process-wide input
-- object the first time, so later instances still find them after renaming.
local function getHomeCodes()
    local input = Device.input
    if not input or not input.event_map then return {} end
    if input._pbplus_home_codes then return input._pbplus_home_codes end
    local codes = {}
    -- pairs() walks only the device's own table, which is where "Home" lives.
    for code, name in pairs(input.event_map) do
        if name == "Home" then table.insert(codes, code) end
    end
    input._pbplus_home_codes = codes
    return codes
end

local function isHomeEnabled() return readBool(HOME_KEY, true) end

local function applyHome(enabled)
    local codes = getHomeCodes()
    if #codes == 0 then
        logger.warn("PocketBookPlus fixes: no Home key in the event map")
        return
    end
    local target = enabled and "Back" or "Home"
    for _i, code in ipairs(codes) do
        Device.input.event_map[code] = target
    end
    logger.info("PocketBookPlus fixes: Home key(s)", codes, "now send", target)
end

-------------------------------------------------------------------------------
-- Page-turn buttons follow the screen rotation
-------------------------------------------------------------------------------

-- Same table Input:init() builds when the device does not call
-- Input:disableRotationMap() (frontend/device/input.lua).
local function standardRotationMap()
    local fb = require("ffi/framebuffer")
    return {
        [fb.DEVICE_ROTATED_UPRIGHT]           = {},
        [fb.DEVICE_ROTATED_CLOCKWISE]         = { Up = "Right", Right = "Down", Down = "Left",  Left = "Up",    LPgBack = "LPgFwd",  LPgFwd  = "LPgBack", RPgBack = "RPgFwd",  RPgFwd  = "RPgBack" },
        [fb.DEVICE_ROTATED_UPSIDE_DOWN]       = { Up = "Down",  Right = "Left", Down = "Up",    Left = "Right", LPgFwd  = "LPgBack", LPgBack = "LPgFwd",  RPgFwd  = "RPgBack", RPgBack = "RPgFwd" },
        [fb.DEVICE_ROTATED_COUNTER_CLOCKWISE] = { Up = "Left",  Right = "Up",   Down = "Right", Left = "Down" },
    }
end

-- The firmware itself swaps the buttons when its own app orientation is not
-- upright (KOReader started upside down), so only swap for the rotation
-- KOReader does in software: current mode relative to that offset.
local function relativeRotationMap()
    local map = standardRotationMap()
    return setmetatable({}, {
        __index = function(_, rota)
            local fb = Device.screen
            local native = fb.native_rotation_mode or 0
            local offset = native - (fb._pbplus_orig_native or native)
            return map[(4 + rota - offset) % 4] or map[0]
        end,
    })
end

-- The Era Lite's firmware does not swap the buttons although KOReader's
-- PocketBook layer disables its own map: koreader/koreader#15909.
local function isRotationEnabled()
    return readBool(ROTATION_KEY, Device.model == "PB710")
end

local function applyRotation(enabled)
    local input = Device.input
    if not input or not input.rotation_map then return end
    if not input._pbplus_rotation_map then
        input._pbplus_rotation_map = input.rotation_map
    end
    input.rotation_map = enabled and relativeRotationMap() or input._pbplus_rotation_map
    logger.info("PocketBookPlus fixes: rotation map", enabled and "follows the screen" or "is the device's own")
end

-------------------------------------------------------------------------------
-- Screen not upside down when KOReader is started upside down
-------------------------------------------------------------------------------

-- KOReader draws into InkView's task framebuffer and rotates in software, so
-- it relies on that buffer being shown upright. Started while held upside
-- down, the firmware shows the task turned 180° (app orientation 3) and every
-- later flip lands on top of that offset. Neither iv_update_orientation() nor
-- SetOrientation(0) removes it (tested on Era Lite FW 6.11), so the default
-- mode folds the offset into KOReader's native rotation instead.
-- See koreader/koreader#15370 and #16074.
local ORIENTATION_MODES = { "compensate", "inkview0", "off" }

-- Public InkView API missing from KOReader's ffi/inkview_h.lua.
-- (0 portrait, 1 landscape 90, 2 landscape 270, 3 portrait 180.)
local function declareInkViewOrientationApi(ffi)
    pcall(ffi.cdef, [[
int GetOrientation();
void SetOrientation(int);
int GetGlobalOrientation();
]])
end

local function inkviewCall(inkview, name, ...)
    local ok, result = pcall(function(...) return inkview[name](...) end, ...)
    if ok then return result end
    logger.warn("PocketBookPlus fixes: InkView", name, "not available:", result)
    return nil
end

local function orientationSupported()
    return Device:hasGSensor()
        and Device.input ~= nil and Device.input.input ~= nil
        and type(Device.input.input.translateInkViewOrientation) == "function"
end

local function orientationMode()
    local value = settings:read(ORIENTATION_KEY)
    if value == nil then
        -- Devices KOReader itself re-syncs after resume are the ones whose
        -- orientation baseline is known to drift.
        return Device.needs_orientation_sync_after_resume == true and "compensate" or "off"
    end
    for _i, mode in ipairs(ORIENTATION_MODES) do
        if value == mode then return mode end
    end
    return "off"
end

local function getInkView()
    local ok, inkview = pcall(require, "ffi/inkview")
    if not ok then return nil end
    declareInkViewOrientationApi(require("ffi"))
    return inkview
end

local function inkviewState(inkview)
    return inkviewCall(inkview, "GetOrientation"),
           inkviewCall(inkview, "GetGlobalOrientation"),
           inkviewCall(inkview, "GetGSensorOrientation")
end

local function toRotation(inkview_orientation)
    if type(inkview_orientation) ~= "number" or inkview_orientation < 0 or inkview_orientation > 3 then
        return nil
    end
    return Device.input.input.translateInkViewOrientation(inkview_orientation)
end

-- Only the 180° case is handled: a landscape native rotation would need a
-- full re-layout, and the affected devices are portrait-only.
local function compensateInkViewOrientation(inkview, why)
    local fb = Device.screen
    if fb._pbplus_orig_native == nil then
        fb._pbplus_orig_native = fb.native_rotation_mode
    end
    local app = inkviewCall(inkview, "GetOrientation")
    local native = fb._pbplus_orig_native
    if app == 3 then
        native = fb.DEVICE_ROTATED_UPSIDE_DOWN
    elseif app ~= 0 then
        logger.warn("PocketBookPlus fixes: app orientation", app, "not compensated")
    end
    if fb.native_rotation_mode == native then return false end
    logger.info("PocketBookPlus fixes:", why, "app orientation", app,
        "native rotation", fb.native_rotation_mode, "->", native)
    fb.native_rotation_mode = native
    -- InkView has already translated touches for its own orientation, so
    -- KOReader must only translate by the remainder.
    if not fb._pbplus_orig_getTouchRotation then
        fb._pbplus_orig_getTouchRotation = fb.getTouchRotation
    end
    if native == fb._pbplus_orig_native then
        fb.getTouchRotation = fb._pbplus_orig_getTouchRotation
    else
        fb.getTouchRotation = function(self)
            return (4 + self:getRotationMode() - self.native_rotation_mode) % 4
        end
    end
    fb:setRotationMode(fb:getRotationMode())
    return true
end

-- handleMiscGyroEv rather than handleGyroEv: the latter is voided while input
-- is inhibited, which is the case while a document opens, exactly when this
-- runs. So "Ignore accelerometer rotation events" is checked by hand.
local function syncKOReaderWithSensor(sensor)
    local gyro_value = toRotation(sensor)
    if gyro_value == nil then return end
    if G_reader_settings:isTrue("input_ignore_gsensor") then return end
    local ev = Device.input:handleMiscGyroEv({ value = gyro_value })
    if ev then UIManager:sendEvent(ev) end
end

local function syncOrientation(why)
    local inkview = getInkView()
    if not inkview then return end
    local mode = orientationMode()
    local app, global, sensor = inkviewState(inkview)
    logger.info("PocketBookPlus fixes:", why, "mode", mode, "app", app, "global", global, "sensor", sensor)
    if mode == "off" then return end

    local repaint = false
    if mode == "compensate" then
        repaint = compensateInkViewOrientation(inkview, why)
    elseif mode == "inkview0" and app ~= nil and app ~= 0 then
        inkviewCall(inkview, "SetOrientation", 0)
        repaint = true
    end
    syncKOReaderWithSensor(sensor)
    if repaint then UIManager:setDirty("all", "full") end
end

-- Started by the firmware to open a book, KOReader gets no orientation
-- events; the firmware turns the task itself. Poll InkView's app orientation
-- (one FFI call every two seconds, paused while suspended).
local POLL_SECONDS = 2
local pollInkViewOrientation

local function stopInkViewPoll()
    if Device._pbplus_poll_running then
        UIManager:unschedule(pollInkViewOrientation)
        Device._pbplus_poll_running = false
    end
end

pollInkViewOrientation = function()
    if not active or orientationMode() ~= "compensate" then
        Device._pbplus_poll_running = false
        return
    end
    local inkview = getInkView()
    local app = inkview and inkviewCall(inkview, "GetOrientation")
    if app ~= nil and app ~= Device._pbplus_last_app_orientation then
        Device._pbplus_last_app_orientation = app
        local repaint = compensateInkViewOrientation(inkview, "app orientation changed:")
        syncKOReaderWithSensor(app)
        if repaint then UIManager:setDirty("all", "full") end
    end
    UIManager:scheduleIn(POLL_SECONDS, pollInkViewOrientation)
end

local function startInkViewPoll()
    if Device._pbplus_poll_running or orientationMode() ~= "compensate" then return end
    local inkview = getInkView()
    Device._pbplus_last_app_orientation = inkview and inkviewCall(inkview, "GetOrientation")
    Device._pbplus_poll_running = true
    UIManager:scheduleIn(POLL_SECONDS, pollInkViewOrientation)
end

-------------------------------------------------------------------------------
-- Module hooks
-------------------------------------------------------------------------------

-------------------------------------------------------------------------------
-- Battery statistics: redraw on close; tapping the title closes it
-------------------------------------------------------------------------------

local function isBatteryTitleEnabled() return readBool(BATTERY_TITLE_KEY, true) end

-- The batterystat plugin keeps its window in a local, so the shared
-- KeyValuePage is wrapped once and only pages titled like it get the tap.
local kv_patched = false
local function patchBatteryStatTitle()
    if kv_patched then return end
    local ok, KeyValuePage = pcall(require, "ui/widget/keyvaluepage")
    if not ok then return end
    local GestureRange = require("ui/gesturerange")
    local battery_title = _("Battery statistics")
    local orig_init = KeyValuePage.init
    KeyValuePage.init = function(page, ...)
        orig_init(page, ...)
        if not active then return end
        if type(page.title) ~= "string" or page.title:sub(1, #battery_title) ~= battery_title then return end
        -- Closing only redraws the corner the close button sat in, leaving the
        -- window's image on screen over whatever is underneath.
        local orig_close = page.onClose
        page.onClose = function(...)
            local result = orig_close(...)
            UIManager:setDirty("all", "ui")
            return result
        end
        if not (isBatteryTitleEnabled() and page.title_bar and Device:isTouchDevice()) then return end
        page.ges_events = page.ges_events or {}
        page.ges_events.PBPTapTitleClose = {
            GestureRange:new{ ges = "tap", range = function() return page.title_bar.dimen end },
        }
        page.onPBPTapTitleClose = function() page:onClose() return true end
    end
    kv_patched = true
end

local function applyAll(on)
    active = on
    if Device:hasKeys() then
        applyHome(on and isHomeEnabled())
        applyRotation(on and isRotationEnabled())
    end
    if not on then stopInkViewPoll() end
end

-------------------------------------------------------------------------------
-- PocketBook dark mode follows KOReader's night mode
-------------------------------------------------------------------------------

-- The firmware's dark mode sets both keys together.
local DARK_KEYS = { "night_mode", "screen_mode_inverted" }

local function isDarkLinkEnabled() return readBool(DARK_LINK_KEY, true) end

-- The firmware reads global.cfg only at start-up, so the running system is
-- switched through InkView as well (iv2sh can read this mode but not set it).
local function inkview()
    local ffi = require("ffi")
    pcall(ffi.cdef, "void IvSetScreenModeInversion(int); int IvGetScreenModeInversion(void);")
    return ffi.load("inkview")
end

local function setFirmwareInversion(on)
    local ok, err = pcall(function()
        local iv = inkview()
        iv.IvSetScreenModeInversion(on and 1 or 0)
        return iv.IvGetScreenModeInversion()
    end)
    logger.info("PocketBookPlus fixes: InkView screen inversion ->", on, ok and "now " .. tostring(err) or err)
end

local function firmwareDark()
    local ok, v = pcall(function() return inkview().IvGetScreenModeInversion() end)
    if ok then return v ~= 0 end
    return require("pocketbookplus/pbconfig").get("screen_mode_inverted") == "1"
end

local function syncDarkMode(reason)
    if not (active and isDarkLinkEnabled()) then return end
    local PBConfig = require("pocketbookplus/pbconfig")
    local night = Device.screen.night_mode and true or false
    local want = night and "1" or "0"
    local changed = false
    for _i, k in ipairs(DARK_KEYS) do
        if PBConfig.get(k) ~= want then
            local ok, err = PBConfig.set(k, want)
            logger.info("PocketBookPlus fixes: firmware", k, "->", want, ok and "ok" or err)
            changed = changed or ok
        end
    end
    if changed then
        setFirmwareInversion(night)
        PBConfig.reloadTaskmgr()
        logger.info("PocketBookPlus fixes: dark mode synced (" .. reason .. ")")
    end
end

-- The firmware is the source of truth: when KOReader starts, wakes or comes
-- back to the front, it takes the firmware's dark mode. The toggle hook below
-- then finds both sides equal and writes nothing.
local function adoptFirmwareDarkMode(reason)
    if not (active and isDarkLinkEnabled()) then return end
    local dark = firmwareDark()
    if dark == (Device.screen.night_mode and true or false) then return end
    logger.info("PocketBookPlus fixes: night mode follows firmware (" .. reason .. ") ->", dark)
    UIManager:broadcastEvent(require("ui/event"):new("SetNightMode", dark))
end

-- Hooked on the screen rather than the ToggleNightMode event, because other
-- plugins (zenos' quick menu and schedule) call Screen:toggleNightMode()
-- directly. Installed once per process; the screen outlives plugin instances.
local function hookScreenNightMode()
    local screen = Device.screen
    if not screen or screen._pbplus_night_hook or type(screen.toggleNightMode) ~= "function" then return end
    local orig = screen.toggleNightMode
    screen.toggleNightMode = function(...)
        local result = orig(...)
        UIManager:nextTick(syncDarkMode, "night mode")
        return result
    end
    screen._pbplus_night_hook = true
end

function Fixes.init(ctx)
    settings = ctx.registry.settings
    applyAll(true)
    patchBatteryStatTitle()
    hookScreenNightMode()
    UIManager:nextTick(adoptFirmwareDarkMode, "start")
    if orientationSupported() then
        startInkViewPoll()
        -- Plugins are created before the reader restores the document's own
        -- rotation, so sync once the current step is done.
        UIManager:nextTick(syncOrientation, ctx.ui.document and "reader open" or "file browser open")
    end
end

function Fixes.onToggle(ctx, on)
    settings = ctx.registry.settings
    applyAll(on)
end

-- PocketBookPowerD's own orientation sync runs after the Resume broadcast.
-- Not deferred: switching before KOReader's own wake repaint avoids drawing
-- the page twice. Returning from the firmware's panel or settings
-- (EVT_FOREGROUND) also arrives as Resume.
function Fixes.onResume()
    adoptFirmwareDarkMode("resume")
    if orientationSupported() and orientationMode() ~= "off" then
        UIManager:nextTick(syncOrientation, "resume")
        startInkViewPoll()
    end
end

function Fixes.onSuspend()
    stopInkViewPoll()
end

function Fixes.menuItems(ctx)
    settings = ctx.registry.settings
    local items = {}
    if Device:hasKeys() and #getHomeCodes() > 0 then
        table.insert(items, {
            text = _("Home button acts as Back"),
            help_text = _([[The physical Home button sends Back instead: up one folder in the file browser, closes menus and dialogs, and in the reader does whatever "Back in reader" is set to.

On PocketBook, set the firmware's Home short-press action to "none" so the press reaches KOReader.]]),
            checked_func = isHomeEnabled,
            callback = function()
                settings:save(HOME_KEY, not isHomeEnabled())
                if active then applyHome(isHomeEnabled()) end
            end,
        })
    end
    if Device:hasKeys() and Device.input and Device.input.rotation_map then
        table.insert(items, {
            text = _("Page-turn buttons follow rotation"),
            help_text = _([[Uses KOReader's own rotation map so the page-turn buttons follow the screen. If your device already swaps them, this swaps them twice: turn it off then.]]),
            checked_func = isRotationEnabled,
            callback = function()
                settings:save(ROTATION_KEY, not isRotationEnabled())
                if active then applyRotation(isRotationEnabled()) end
            end,
        })
    end
    if Device:isTouchDevice() then
        table.insert(items, {
            text = _("Tap the battery statistics title to close it"),
            help_text = _([[KOReader's battery statistics window only closes from the small ✕ in its corner. With this on, tapping anywhere on its title bar closes it too.]]),
            checked_func = isBatteryTitleEnabled,
            callback = function() settings:save(BATTERY_TITLE_KEY, not isBatteryTitleEnabled()) end,
        })
    end
    table.insert(items, {
        text = _("Link night mode with PocketBook dark mode"),
        help_text = _([[Switching KOReader's night mode also switches the PocketBook's own dark mode, so the lock screen and firmware screens match. The PocketBook's setting wins: when KOReader starts or wakes, it takes the firmware's dark mode.]]),
        checked_func = isDarkLinkEnabled,
        callback = function()
            settings:save(DARK_LINK_KEY, not isDarkLinkEnabled())
            adoptFirmwareDarkMode("setting")
        end,
    })
    if orientationSupported() then
        local function modeItem(mode, text)
            return {
                text = text,
                radio = true,
                checked_func = function() return orientationMode() == mode end,
                callback = function() settings:save(ORIENTATION_KEY, mode) end,
            }
        end
        table.insert(items, {
            text = _("Fix orientation when started upside down"),
            help_text = _([["Compensate" folds the firmware's 180° offset into KOReader's rotation. "Reset InkView" asks the firmware to show the screen upright. "Off" only logs. Takes effect at the next start.]]),
            sub_item_table = {
                modeItem("compensate", _("Compensate the firmware's offset")),
                modeItem("inkview0", _("Reset InkView to upright")),
                modeItem("off", _("Off (log only)")),
            },
        })
    end
    return items
end

return Fixes
