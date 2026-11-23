--[[--
Reader: cover pages. Enlarges the images in the first two files of a
reflowable book (in EPUBs almost always the cover and the inside cover or
title page) by adding CSS to the book's style tweaks.

It works inside the page margins and above the status bar: the page frame is
outside the book's CSS. Cropping to fill is not possible, as crengine has no
object-fit.
--]]--

local _ = require("gettext")

local Reader = {
    id = "reader",
    name = _("Reader"),
    default_enabled = true,
}

local MODE_KEY = "reader.cover_pages"
local MODE_OFF, MODE_FIT, MODE_STRETCH = "off", "fit", "stretch"

local SCOPE = "DocFragment:first-child %s, DocFragment:first-child + DocFragment %s"
local function scoped(sel) return SCOPE:format(sel, sel) end

-- Covers are taller than the text area, so Fit sets the full height and lets
-- the width follow. Margins and padding are dropped around the image so a page-high image does
-- not spill onto a second page. 99vh leaves room for rounding. Covers are
-- often wrapped in a link (<a><img/></a>); crengine ignores a block image's
-- size inside an inline, so the link is made a block too.
local FRAME = scoped("*") .. [[ {
    margin: 0 !important;
    padding: 0 !important;
    text-indent: 0 !important;
}
]] .. scoped("a") .. [[ {
    display: block !important;
}
]]

local CSS = {
    [MODE_FIT] = FRAME .. scoped("img") .. [[ {
    display: block !important;
    width: auto !important;
    height: 99vh !important;
    max-width: 100% !important;
    margin: 0 auto !important;
}
]],
    [MODE_STRETCH] = FRAME .. scoped("img") .. [[ {
    display: block !important;
    width: 100% !important;
    height: 99vh !important;
}
]],
}

local settings

local function mode()
    local m = settings and settings:read(MODE_KEY)
    if m == MODE_FIT or m == MODE_STRETCH then return m end
    return MODE_OFF
end

local enabled = false

local function extraCss()
    if not enabled then return nil end
    return CSS[mode()]
end
Reader._extraCss = extraCss

-- Hooked on the class once per process, so every reader instance gets it.
local function hookStyleTweak()
    local ok, ReaderStyleTweak = pcall(require, "apps/reader/modules/readerstyletweak")
    if not ok or ReaderStyleTweak._pbplus_cover_hook then return end
    local orig = ReaderStyleTweak.updateCssText
    ReaderStyleTweak.updateCssText = function(self, apply)
        -- Built without applying, so ours is in place before the one re-render.
        orig(self, false)
        local css = extraCss()
        if css then
            self.css_text = (self.css_text and self.css_text .. "\n" or "") .. css
        end
        if apply then
            self.ui:handleEvent(require("ui/event"):new("ApplyStyleSheet"))
        end
    end
    ReaderStyleTweak._pbplus_cover_hook = true
end

local function reapply(ctx)
    local st = ctx.ui and ctx.ui.document and ctx.ui.styletweak
    if st then st:updateCssText(true) end
end

function Reader.init(ctx)
    settings = ctx.registry.settings
    enabled = true
    hookStyleTweak()
end

function Reader.onToggle(ctx, on)
    settings = ctx.registry.settings
    enabled = on
    if on then hookStyleTweak() end
    reapply(ctx)
end

function Reader.menuItems(ctx)
    settings = ctx.registry.settings
    local function modeItem(m, text, help)
        return {
            text = text,
            help_text = help,
            radio = true,
            checked_func = function() return mode() == m end,
            callback = function()
                settings:save(MODE_KEY, m)
                reapply(ctx)
            end,
        }
    end
    return {
        {
            text = _("Cover pages"),
            help_text = _("Enlarges the images in the book's first two sections, usually the cover and the inside cover. Works inside the page margins. Reflowable books (such as EPUB) only."),
            sub_item_table = {
                modeItem(MODE_OFF, _("Off")),
                modeItem(MODE_FIT, _("Fit (keep proportions)"), _("Scales the image up or down to the largest size that fits the page, keeping its proportions.")),
                modeItem(MODE_STRETCH, _("Stretch (ignore aspect ratio)"), _("Stretches the image to the full width and height of the page.")),
            },
        },
    }
end

return Reader
