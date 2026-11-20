-- Thin wrapper over KOReader's LuaSettings, kept in its own file
-- (settings/pocketbookplus.lua) so removing the plugin leaves
-- settings.reader.lua untouched.

local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")

local Settings = {}
Settings.__index = Settings

function Settings.new()
    local path = DataStorage:getSettingsDir() .. "/pocketbookplus.lua"
    return setmetatable({ store = LuaSettings:open(path) }, Settings)
end

function Settings:read(key) return self.store:readSetting(key) end

function Settings:save(key, value)
    self.store:saveSetting(key, value)
    self.store:flush()
end

return Settings
