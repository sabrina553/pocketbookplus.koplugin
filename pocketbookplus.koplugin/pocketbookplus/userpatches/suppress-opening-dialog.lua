-- PocketBook Plus: hides the "Opening file …" message shown while a book opens.
-- Installed and removed by the plugin's Patches menu; do not edit here.
-- Based on a community patch, original author unknown.
--
-- Instead of copying ReaderUI:showReaderCoroutine (which goes stale when
-- KOReader changes it), this only marks the zero-timeout InfoMessage that
-- function creates as invisible. KOReader still shows and repaints it, so the
-- opening flow is unchanged, but nothing is drawn.

local InfoMessage = require("ui/widget/infomessage")
local ReaderUI = require("apps/reader/readerui")

local orig_showReaderCoroutine = ReaderUI.showReaderCoroutine

function ReaderUI:showReaderCoroutine(...)
    local orig_new = InfoMessage.new
    InfoMessage.new = function(cls, o)
        if cls == InfoMessage and type(o) == "table" and o.timeout == 0 then
            o.invisible = true
        end
        return orig_new(cls, o)
    end
    -- Restore before re-raising, so a failure cannot leave every later
    -- message invisible.
    local ok, err = pcall(orig_showReaderCoroutine, self, ...)
    InfoMessage.new = orig_new
    if not ok then error(err, 0) end
end
