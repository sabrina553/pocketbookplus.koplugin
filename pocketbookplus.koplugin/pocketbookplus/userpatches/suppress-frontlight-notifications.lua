-- PocketBook Plus: no "Frontlight intensity set to …" / "Warmth set to …"
-- pop-ups when changing them by gesture. The change itself still happens.
-- Installed and removed by the plugin's Patches menu; do not edit here.
-- Based on a community patch, original author unknown.

local Device = require("device")

if Device:hasFrontlight() then
    local DeviceListener = require("device/devicelistener")
    function DeviceListener:onShowIntensity() return true end
    if Device:hasNaturalLight() then
        function DeviceListener:onShowWarmth() return true end
    end
end
