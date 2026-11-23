local Device = require("device")
local logger = require("logger")
local _ = require("gettext")

-- Everything here writes PocketBook firmware files or calls InkView, so on
-- any other device the plugin does not load at all (pluginloader skips a
-- main.lua that returns { disabled = true }).
if not Device:isPocketBook() then
    return { disabled = true }
end

local WidgetContainer = require("ui/widget/container/widgetcontainer")
local Registry = require("pocketbookplus/registry")
local Settings = require("pocketbookplus/settings")

-- Order here is menu order.
local MODULES = {
    "pocketbookplus/modules/lockscreen",
    "pocketbookplus/modules/sync",
    "pocketbookplus/modules/library",
    "pocketbookplus/modules/fixes",
    "pocketbookplus/modules/setup",
    "pocketbookplus/modules/appearance",
    "pocketbookplus/modules/patches",
    "pocketbookplus/modules/reader",
}

local PocketBookPlus = WidgetContainer:extend {
    name = "pocketbookplus",
    is_doc_only = false,
}

local function logError(id, handler, err)
    logger.warn("PocketBookPlus:", id, handler, "failed:", err)
end

function PocketBookPlus:init()
    self.registry = Registry.new(Settings.new())
    for _i, path in ipairs(MODULES) do
        self.registry:add(require(path))
    end
    self.registry:dispatch("init", self, logError)
    self.ui.menu:registerToMainMenu(self)
end

function PocketBookPlus:addToMainMenu(menu_items)
    local items = {}
    for _i, mod in ipairs(self.registry.modules) do
        local sub = {
            {
                text = _("Enabled"),
                checked_func = function() return self.registry:isEnabled(mod) end,
                callback = function()
                    local on = not self.registry:isEnabled(mod)
                    self.registry:setEnabled(mod, on)
                    if mod.onToggle then
                        local ok, err = pcall(mod.onToggle, self, on)
                        if not ok then logError(mod.id, "onToggle", err) end
                    end
                end,
                separator = true,
            },
        }
        if mod.menuItems then
            local ok, extra = pcall(mod.menuItems, self)
            if ok then
                for _i, it in ipairs(extra) do table.insert(sub, it) end
            else
                logError(mod.id, "menuItems", extra)
            end
        end
        table.insert(items, { text = mod.name, sub_item_table = sub })
    end
    if #items == 0 then
        table.insert(items, { text = _("No modules yet"), enabled = false })
    end
    menu_items.pocketbookplus = {
        text = _("PocketBook Plus"),
        sorting_hint = "tools",
        sub_item_table = items,
    }
end

-- KOReader events forwarded to modules.
for _i, ev in ipairs({ "onSuspend", "onResume", "onPageUpdate", "onReaderReady", "onCloseDocument", "onSaveSettings", "onPowerOff", "onReboot",
        "onToggleNightMode", "onSetNightMode" }) do
    PocketBookPlus[ev] = function(self, ...)
        self.registry:dispatch(ev, self, logError, ...)
    end
end

return PocketBookPlus
