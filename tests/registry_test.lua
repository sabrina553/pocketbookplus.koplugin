-- Run: luajit tests/registry_test.lua
package.path = "pocketbookplus.koplugin/?.lua;" .. package.path
local Registry = require("pocketbookplus/registry")

local function check(cond, message)
    assert(type(cond) == "boolean", "check needs a boolean: " .. message)
    if not cond then error("FAIL: " .. message, 2) end
end

local function fakeSettings()
    local t = {}
    return { read = function(_, k) return t[k] end, save = function(_, k, v) t[k] = v end }
end

local r = Registry.new(fakeSettings())
local calls = {}
r:add({ id = "a", default_enabled = true, onSuspend = function() table.insert(calls, "a") end })
r:add({ id = "b", default_enabled = false, onSuspend = function() table.insert(calls, "b") end })
r:add({ id = "c", default_enabled = true, onSuspend = function() error("boom") end })

check(r:isEnabled(r.modules[1]), "default on is respected")
check(not r:isEnabled(r.modules[2]), "default off is respected")

local errors = {}
r:dispatch("onSuspend", {}, function(id) table.insert(errors, id) end)
check(#calls == 1 and calls[1] == "a", "only enabled modules run")
check(#errors == 1 and errors[1] == "c", "a failing module is reported, not fatal")

r:setEnabled(r.modules[2], true)
check(r:isEnabled(r.modules[2]), "setEnabled overrides the default")

check(not pcall(r.add, r, { id = "a" }), "duplicate ids are rejected")

print("registry_test: ok")
