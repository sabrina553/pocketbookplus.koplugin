--[[--
Quick setup: the PocketBook-side changes a KOReader install usually needs,
done from KOReader. Status, file types, the app's name and its home-screen
icon. Steps from the guide at
https://github.com/jjrrw174/PocketBook-Desktop-and-App-Customizations
(and the MobileRead thread it summarises, t=355521).

Every firmware file is backed up once before the first change, next to it
with a ".before-pocketbookplus" suffix (icons in a folder of that name).
--]]--

local DataStorage = require("datastorage")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local ffiutil = require("ffi/util")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local _ = require("gettext")
local T = ffiutil.template

local Ext = require("pocketbookplus/setup/extensions")
local PBConfig = require("pocketbookplus/pbconfig")

local BACKUP = ".before-pocketbookplus"
local LANG_DIR = "/mnt/ext1/system/language"
local VIEW_JSON = "/mnt/ext1/system/config/desktop/view.json"
local ICON_DIR = "/mnt/ext1/applications/icons"
local ICON_FILES = { "desktop_app_koreader.bmp", "desktop_app_koreader_f.bmp" }
local APP_KEY = "@koreader"

local function readFile(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local data = f:read("*a")
    f:close()
    return data
end

local function exists(path) return lfs.attributes(path, "mode") ~= nil end

local function backupOnce(path)
    if exists(path) and not exists(path .. BACKUP) then
        ffiutil.copyFile(path, path .. BACKUP)
    end
end

local function writeFile(path, data)
    backupOnce(path)
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

local function notify(text)
    UIManager:show(InfoMessage:new{ text = text, timeout = 4 })
end

-------------------------------------------------------------------------------
-- App name
-------------------------------------------------------------------------------

local function langFile()
    return LANG_DIR .. "/" .. (PBConfig.get("language") or "en") .. ".txt"
end

local function hasName()
    local data = readFile(langFile())
    return data ~= nil and data:find("\n" .. APP_KEY .. "=", 1, true) ~= nil
        or (data ~= nil and data:sub(1, #APP_KEY + 1) == APP_KEY .. "=")
end

local function setName()
    local path = langFile()
    local data = readFile(path)
    if data and hasName() then return true end
    -- A new file starts with the language's name, as the firmware's own do.
    data = data or "English\n"
    if data:sub(-1) ~= "\n" then data = data .. "\n" end
    return writeFile(path, data .. APP_KEY .. "=KOReader\n")
end

-------------------------------------------------------------------------------
-- Icon
-------------------------------------------------------------------------------

local function inView()
    local data = readFile(VIEW_JSON)
    return data ~= nil and data:find('"U_koreader"', 1, true) ~= nil
end

local function iconsPresent()
    for _i, f in ipairs(ICON_FILES) do
        if not exists(ICON_DIR .. "/" .. f) then return false end
    end
    return true
end

local function pluginDir()
    local src = debug.getinfo(1, "S").source:gsub("^@", "")
    return src:match("^(.*)/pocketbookplus/modules/[^/]+$") or (DataStorage:getDataDir() .. "/plugins/pocketbookplus.koplugin")
end

-- Keeps the icons that were there before any change, once, so "My previous
-- icon" can always put them back.
local function backupIcons()
    local dir = ICON_DIR .. "/" .. BACKUP
    if exists(dir) then return end
    lfs.mkdir(dir)
    for _i, f in ipairs(ICON_FILES) do
        if exists(ICON_DIR .. "/" .. f) then ffiutil.copyFile(ICON_DIR .. "/" .. f, dir .. "/" .. f) end
    end
end

local function installIcons(src_dir)
    lfs.mkdir(ICON_DIR)
    backupIcons()
    for _i, f in ipairs(ICON_FILES) do
        if not exists(src_dir .. "/" .. f) then return false end
        if ffiutil.copyFile(src_dir .. "/" .. f, ICON_DIR .. "/" .. f) then return false end
    end
    return true
end

-------------------------------------------------------------------------------
-- Module
-------------------------------------------------------------------------------

local Setup = {
    id = "setup",
    name = _("Quick setup"),
    default_enabled = true,
}

local function fileTypes()
    local system = Ext.parse(readFile(Ext.SYSTEM_PATH))
    local user = Ext.parse(readFile(Ext.USER_PATH))
    return user, system
end

local function statusText()
    local user, system = fileTypes()
    local on, off = {}, {}
    for _i, ext in ipairs(Ext.SUPPORTED) do
        if system[ext] or user[ext] then
            table.insert(Ext.opensInKOReader(user, system, ext) and on or off, ext)
        end
    end
    local function mark(ok) return ok and "✓" or "✗" end
    return table.concat({
        T(_("%1 App name in %2"), mark(hasName()), langFile()),
        T(_("%1 Home-screen entry in view.json"), mark(inView())),
        T(_("%1 Icon files in %2"), mark(iconsPresent()), ICON_DIR),
        T(_("Opens in KOReader: %1"), #on > 0 and table.concat(on, ", ") or "-"),
        T(_("Opens in the PocketBook reader: %1"), #off > 0 and table.concat(off, ", ") or "-"),
        "",
        _("PocketBook reads these at start-up: restart the device after a change."),
    }, "\n")
end

local function fileTypeItems()
    local items = {}
    for _i, ext in ipairs(Ext.SUPPORTED) do
        local _user, system = fileTypes()
        if system[ext] then
            table.insert(items, {
                text = ext,
                checked_func = function()
                    local u, s = fileTypes()
                    return Ext.opensInKOReader(u, s, ext)
                end,
                callback = function()
                    local u, s = fileTypes()
                    local text = Ext.apply(readFile(Ext.USER_PATH) or "", readFile(Ext.SYSTEM_PATH) or "",
                        ext, not Ext.opensInKOReader(u, s, ext))
                    if not writeFile(Ext.USER_PATH, text) then
                        notify(_("Could not write the file associations; see crash.log."))
                    end
                    logger.info("PocketBookPlus setup: file type", ext, "now opens in KOReader:", not Ext.opensInKOReader(u, s, ext))
                end,
            })
        end
    end
    table.insert(items, 1, {
        text = _("All of them"),
        keep_menu_open = true,
        separator = true,
        callback = function(touchmenu)
            local text = readFile(Ext.USER_PATH) or ""
            local system_text = readFile(Ext.SYSTEM_PATH) or ""
            for _i, ext in ipairs(Ext.SUPPORTED) do
                text = Ext.apply(text, system_text, ext, true)
            end
            if writeFile(Ext.USER_PATH, text) then
                notify(_("All supported file types now open in KOReader. Restart the device to apply."))
            end
            if touchmenu then touchmenu:updateItems() end
        end,
    })
    return items
end

local function iconItems()
    local function choice(text, dir_func)
        return {
            text = text,
            callback = function()
                if not inView() then
                    notify(_("KOReader has no home-screen entry in view.json yet; adding one is not supported here yet. See the guide linked in the plugin's README."))
                    return
                end
                local ok = installIcons(dir_func())
                logger.info("PocketBookPlus setup: icon set", text, ok and "ok" or "FAILED")
                notify(ok and _("Icon installed. Restart the device to see it.") or _("Could not install the icon; see crash.log."))
            end,
        }
    end
    return {
        choice(_("Line icon (Arcticons)"), function() return pluginDir() .. "/icons/line" end),
        choice(_("KOReader logo"), function() return pluginDir() .. "/icons/koreader" end),
        {
            text = _("My previous icon"),
            enabled_func = function() return exists(ICON_DIR .. "/" .. BACKUP) end,
            callback = function()
                local ok = installIcons(ICON_DIR .. "/" .. BACKUP)
                notify(ok and _("Previous icon restored. Restart the device to see it.") or _("Could not restore the icon."))
            end,
        },
    }
end

function Setup.menuItems()
    return {
        {
            text = _("Status"),
            keep_menu_open = true,
            callback = function() UIManager:show(InfoMessage:new{ text = statusText() }) end,
            separator = true,
        },
        {
            text = _("Open these file types in KOReader"),
            help_text = _("Makes KOReader the default app for the ticked types. The PocketBook reader stays available under Open with. Restart the device to apply."),
            sub_item_table_func = fileTypeItems,
        },
        {
            text = _("Show the app as \"KOReader\""),
            help_text = _("Adds @koreader=KOReader to the firmware's language file, so the app is not listed as @koreader."),
            checked_func = hasName,
            callback = function()
                if hasName() then return end
                notify(setName() and _("Name set. Restart the device to see it.") or _("Could not write the language file."))
            end,
        },
        {
            text = _("Home-screen icon"),
            sub_item_table_func = iconItems,
        },
    }
end

return Setup
