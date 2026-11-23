--[[--
Patches: KOReader user patches the plugin installs into koreader/patches/.

Each toggle copies a patch from pocketbookplus/userpatches/ to
patches/2-pbplus-<name>.lua, or renames it to .lua.disabled when turned off.
KOReader runs patches at startup, before plugins load, which is the only way
to reach things like the "Opening file" message of the book reopened at boot.
So every change takes effect at the next start.

The patches are based on community patches whose authors are unknown; see
the header of each file.
--]]--

local DataStorage = require("datastorage")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local _ = require("gettext")

local Patches = {
    id = "patches",
    name = _("Patches"),
    default_enabled = true,
}

-- Menu order. Off by default: a patch changes KOReader's behaviour, so it
-- should be a choice.
local PATCHES = {
    {
        name = "suppress-opening-dialog",
        text = _("Hide the \"Opening file\" message"),
        help = _("Hides the message that flashes while a book opens, including the book reopened at start-up."),
    },
    {
        name = "skip-first-repaint",
        text = _("Keep the screen while the first book loads"),
        help = _("After a reboot, KOReader's first refresh blanks the screen while the book loads. This skips that refresh so the previous screen stays until the page is ready."),
    },
    {
        name = "suppress-frontlight-notifications",
        text = _("Hide frontlight and warmth pop-ups"),
        help = _("No \"Frontlight intensity set to…\" or \"Warmth set to…\" message when changing them by gesture. The change itself still happens."),
    },
    {
        name = "disable-wifi-notifications",
        text = _("Hide Wi-Fi progress pop-ups"),
        help = _("Hides \"Connecting to…\", \"Scanning for networks…\" and similar messages. Questions and connection errors are still shown."),
    },
}

local settings

local function key(p) return "patches." .. p.name end
local function isOn(p) return settings:read(key(p)) == true end

local function exists(path) return lfs.attributes(path, "mode") == "file" end

local function readFile(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local data = f:read("*a")
    f:close()
    return data
end

local function pluginDir()
    local src = debug.getinfo(1, "S").source:gsub("^@", "")
    return src:match("^(.*)/pocketbookplus/modules/[^/]+$") or (DataStorage:getDataDir() .. "/plugins/pocketbookplus.koplugin")
end

local function patchDir() return DataStorage:getDataDir() .. "/patches" end
local function sourcePath(p) return pluginDir() .. "/pocketbookplus/userpatches/" .. p.name .. ".lua" end
local function installedPath(p) return patchDir() .. "/2-pbplus-" .. p.name .. ".lua" end

-- Temp file then rename, so an interrupted write never leaves KOReader a
-- half-written patch to run at start-up.
local function writeFile(path, data)
    local tmp = path .. ".tmp"
    local f = io.open(tmp, "wb")
    if not f then return false end
    f:write(data)
    f:close()
    if not os.rename(tmp, path) then
        os.remove(tmp)
        return false
    end
    return true
end

-- Brings one patch file in line with its toggle. Also refreshes an installed
-- copy that a plugin update has made stale. Returns false only on failure.
local function sync(p, on)
    local installed = installedPath(p)
    if not on then
        if not exists(installed) then return true end
        os.remove(installed .. ".disabled")
        local ok = os.rename(installed, installed .. ".disabled")
        logger.info("PocketBookPlus patches: disabled", p.name, ok and "ok" or "FAILED")
        return ok and true or false
    end
    local data = readFile(sourcePath(p))
    if not data then
        logger.warn("PocketBookPlus patches: missing source for", p.name)
        return false
    end
    if readFile(installed) == data then return true end
    if lfs.attributes(patchDir(), "mode") ~= "directory" then lfs.mkdir(patchDir()) end
    local ok = writeFile(installed, data)
    if ok then os.remove(installed .. ".disabled") end
    logger.info("PocketBookPlus patches: installed", p.name, ok and "ok" or "FAILED")
    return ok
end

local function syncAll(enabled)
    for _i, p in ipairs(PATCHES) do
        pcall(sync, p, enabled and isOn(p))
    end
end

local function restartNotice(ok)
    UIManager:show(InfoMessage:new{
        text = ok and _("Restart KOReader to apply.")
            or _("Could not change the patch file in koreader/patches."),
        timeout = 3,
    })
end

function Patches.init(ctx)
    settings = ctx.registry.settings
    syncAll(true)
end

function Patches.onToggle(ctx, on)
    settings = ctx.registry.settings
    syncAll(on)
    restartNotice(true)
end

function Patches.menuItems(ctx)
    settings = ctx.registry.settings
    local items = {}
    for _i, p in ipairs(PATCHES) do
        table.insert(items, {
            text = p.text,
            help_text = p.help .. "\n\n" .. _("Takes effect after restarting KOReader."),
            checked_func = function() return isOn(p) end,
            callback = function()
                local on = not isOn(p)
                settings:save(key(p), on)
                local ok, synced = pcall(sync, p, on and ctx.registry:isEnabled(Patches))
                restartNotice(ok and synced)
            end,
        })
    end
    return items
end

return Patches
