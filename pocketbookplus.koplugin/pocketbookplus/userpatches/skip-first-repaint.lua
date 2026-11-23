-- PocketBook Plus: keeps the previous screen visible while the first book
-- loads after boot, instead of a blank flash.
-- Installed and removed by the plugin's Patches menu; do not edit here.
-- Based on a community patch, original author unknown.
--
-- Only needed on the first start after boot: that first refresh clears the
-- panel even when partial. A flag in /tmp (cleared at reboot) marks later
-- starts, which are left alone.

local UIManager = require("ui/uimanager")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")

local FLAG = "/tmp/pbplus_first_repaint_done"
if lfs.attributes(FLAG, "mode") == "file" then return end
local f = io.open(FLAG, "w")
if f then f:write("1") f:close() end

-- Drops the first forceRePaint (the one in ReaderUI:showReaderCoroutine);
-- UIManager repaints on its own shortly after.
local orig_forceRePaint = UIManager.forceRePaint
local skipped = false
UIManager.forceRePaint = function(...)
    if not skipped then
        skipped = true
        logger.info("PocketBookPlus patch: skipped first repaint")
        return
    end
    return orig_forceRePaint(...)
end
