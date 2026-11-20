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
Device.screen = { native_rotation_mode = 0,
    getScreenWidth = function() return 1072 end, getScreenHeight = function() return 1448 end }
stub("pocketbookplus/pbconfig", { get = function() return nil end, set = function() return true end })
stub("libs/libkoreader-lfs", { attributes = function() return nil end, mkdir = function() return nil end, dir = function() return function() end end })
stub("gettext", function(s) return s end)
stub("ui/uimanager", { show = function() end, unschedule = function() end, nextTick = function() end, scheduleIn = function() end })
stub("ui/widget/container/widgetcontainer", { extend = function(_, t) return t end })
stub("pocketbookplus/settings", { new = function()
    return { read = function(_, k) return store[k] end, save = function(_, k, v) store[k] = v end }
end })
for _i, name in ipairs({ "ui/widget/confirmbox", "docsettings", "ui/event", "util",
        "ffi/blitbuffer", "apps/filemanager/filemanagerbookinfo", "ui/font", "ui/renderimage",
        "ui/widget/textboxwidget" }) do
    stub(name, {})
end
stub("ui/widget/inputdialog", { new = function(_, t) t.onShowKeyboard = function() end; t.getInputText = function() return "" end; return t end })
stub("ui/widget/infomessage", { new = function(_, t) return t end })
stub("ffi/util", { template = function(s) return s end, copyFile = function() return "stubbed" end })
stub("datastorage", { getDataDir = function() return "/nonexistent" end })
stub("pocketbookplus/sync/librarydb", { new = function() return { disabled = function() return false end } end, POSITION_PREFIX = "" })
-- Menu taps must never touch the real filesystem or run firmware tools.
local shell_calls = 0
os.execute = function() shell_calls = shell_calls + 1 return 0 end
os.remove = function() return true end
os.rename = function() error("test must not rename files") end
G_reader_settings = { isTrue = function() return false end }
io.open = function() return nil end -- no reads or writes of real files

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
        if it.sub_item_table_func then walk(it.sub_item_table_func()) end
    end
end
walk(top.sub_item_table)

assert(Device.input.event_map[1] == "Back", "Home is remapped to Back by default")
print("main_menu_test: ok")
