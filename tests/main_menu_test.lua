-- Builds the whole menu with KOReader stubbed, so runtime errors in menu code
-- (such as a loop variable shadowing gettext's `_`) fail here, not on the reader.
-- Run: luajit tests/main_menu_test.lua
package.path = "pocketbookplus.koplugin/?.lua;" .. package.path

local function stub(name, value) package.preload[name] = function() return value end end

local store = {}
local Device = {
    isPocketBook = function() return true end,
    hasKeys = function() return true end,
    hasGSensor = function() return false end,
    model = "PB634",
    input = { event_map = { [1] = "Home" }, rotation_map = {} },
}
stub("device", Device)
stub("logger", { info = function() end, warn = function() end, dbg = function() end })
stub("ffi/framebuffer", { DEVICE_ROTATED_UPRIGHT = 0, DEVICE_ROTATED_CLOCKWISE = 1, DEVICE_ROTATED_UPSIDE_DOWN = 2, DEVICE_ROTATED_COUNTER_CLOCKWISE = 3 })
Device.screen = { native_rotation_mode = 0 }
stub("gettext", function(s) return s end)
stub("ui/uimanager", { nextTick = function() end, scheduleIn = function() end, unschedule = function() end })
stub("ui/widget/container/widgetcontainer", { extend = function(_, t) return t end })
stub("pocketbookplus/settings", { new = function()
    return { read = function(_, k) return store[k] end, save = function(_, k, v) store[k] = v end }
end })
G_reader_settings = { isTrue = function() return false end }

local Plugin = require("main")
local ui = { menu = { registerToMainMenu = function() end } }
local p = setmetatable({ ui = ui }, { __index = Plugin })
p:init()

local menu = {}
p:addToMainMenu(menu)
local top = menu.pocketbookplus
assert(top and #top.sub_item_table >= 1, "top menu built")

-- Walk every item and flip every toggle, as a user tapping through would.
local function walk(items)
    for _i, it in ipairs(items) do
        assert(type(it.text) == "string", "item has text")
        if it.checked_func then it.checked_func() end
        if it.callback then it.callback(); it.callback() end
        if it.sub_item_table then walk(it.sub_item_table) end
    end
end
walk(top.sub_item_table)

assert(Device.input.event_map[1] == "Back", "Home is remapped to Back by default")
print("main_menu_test: ok")
