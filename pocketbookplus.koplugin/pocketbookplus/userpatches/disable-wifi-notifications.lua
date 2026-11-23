-- PocketBook Plus: hides Wi-Fi progress pop-ups ("Connecting to …",
-- "Scanning for networks…", "Connected to …") and the SSH server's
-- started/stopped messages.
-- Installed and removed by the plugin's Patches menu; do not edit here.
-- Based on a community patch, original author unknown.
--
-- Only plain InfoMessage and Notification pop-ups are hidden, and never ones
-- reporting a failure: questions ("Turn on Wi-Fi?") and errors still show.

local InfoMessage = require("ui/widget/infomessage")
local Notification = require("ui/widget/notification")
local UIManager = require("ui/uimanager")
local logger = require("logger")

local PATTERNS = { "connecting to", "scanning for", "connected to", "obtaining ip",
    "turning on wi", "turning off wi", "associating", "waiting for network",
    "ssh server started", "ssh server stopped", "ssh server forcefully stopped" }
local FAILURES = { "fail", "could not", "couldn't", "unable", "error", "not connected" }

local function contains(s, list)
    for _i, p in ipairs(list) do
        if s:find(p, 1, true) then return true end
    end
    return false
end

local function isWifiProgress(widget)
    local cls = getmetatable(widget)
    if cls ~= InfoMessage and cls ~= Notification then return false end
    if type(widget.text) ~= "string" then return false end
    local s = widget.text:lower()
    return contains(s, PATTERNS) and not contains(s, FAILURES)
end

local orig_show = UIManager.show
UIManager.show = function(self, widget, ...)
    if type(widget) == "table" and isWifiProgress(widget) then
        logger.dbg("PocketBookPlus patch: hid Wi-Fi pop-up:", widget.text)
        return
    end
    return orig_show(self, widget, ...)
end
