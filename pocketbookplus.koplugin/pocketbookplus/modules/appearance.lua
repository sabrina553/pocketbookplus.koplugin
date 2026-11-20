--[[--
Appearance: PocketBook-style dialogs. Off by default: it replaces parts of
KOReader's widgets at runtime, which is the kind of change most likely to
break with a KOReader update. Turning it off restores the originals.
--]]--

local _ = require("gettext")

local Appearance = {
    id = "appearance",
    name = _("PocketBook-style dialogs"),
    default_enabled = false,
}

-- The theme patches process-wide classes, so one instance serves the file
-- browser and the reader alike.
local theme
local function getTheme()
    if not theme then
        theme = require("pocketbookplus/appearance/theme")
        theme:init(false)
    end
    return theme
end

function Appearance.init()
    getTheme():enable()
end

function Appearance.onToggle(_ctx, on)
    if on then getTheme():enable() else getTheme():disable() end
end

function Appearance.menuItems()
    return {
        {
            text = _("About"),
            keep_menu_open = true,
            callback = function()
                local UIManager = require("ui/uimanager")
                local InfoMessage = require("ui/widget/infomessage")
                UIManager:show(InfoMessage:new{
                    text = _("Restyles KOReader's messages, confirmations, dialogs and the front-light panel to match the PocketBook firmware, with Roboto as the interface font. Experimental: if something looks wrong after a KOReader update, turn it off here."),
                })
            end,
        },
    }
end

return Appearance
