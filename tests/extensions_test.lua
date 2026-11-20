-- Run: luajit tests/extensions_test.lua
package.path = "pocketbookplus.koplugin/?.lua;" .. package.path
local Ext = require("pocketbookplus/setup/extensions")

local function check(cond, message)
    assert(type(cond) == "boolean", "check needs a boolean: " .. message)
    if not cond then error("FAIL: " .. message, 2) end
end

local system = table.concat({
    "fb2:@FB2_file:1:eink-reader.app:ICON_FB2",
    "epub:@EPUB_file:1:eink-reader_with_blink.app,eink-reader_with_epub2.app:ICON_EPUB",
    "cbz:@CBZ_file:1:eink-reader.app:ICON_CBZ",
}, "\n") .. "\n"
local user = "#koreader\nepub:@EPUB_file:1:koreader.app,eink-reader_with_blink.app,eink-reader_with_epub2.app:ICON_EPUB\n"

local S = Ext.parse(system)
local U = Ext.parse(user)
check(Ext.opensInKOReader(U, S, "epub"), "epub already set")
check(not Ext.opensInKOReader(U, S, "fb2"), "fb2 not set")

local after = Ext.apply(user, system, "fb2", true)
check(after:find("\nfb2:@FB2_file:1:koreader.app,eink-reader.app:ICON_FB2\n", 1, true) ~= nil, "fb2 added with firmware app kept second")
check(after:sub(1, 10) == "#koreader\n", "comment line kept")
check(Ext.apply(after, system, "fb2", true) == after, "applying twice changes nothing")

local back = Ext.apply(after, system, "fb2", false)
check(back == user, "turning off removes the override again")

local no_epub = Ext.apply(user, system, "epub", false)
check(no_epub == "#koreader\n", "epub override removed when it matches the firmware")

check(Ext.apply(user, system, "unknown", true) == user, "unknown type left alone")

print("extensions_test: ok")
