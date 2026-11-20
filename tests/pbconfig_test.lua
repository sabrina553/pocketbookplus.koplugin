-- Run: luajit tests/pbconfig_test.lua
package.path = "pocketbookplus.koplugin/?.lua;" .. package.path
local PBConfig = require("pocketbookplus/pbconfig")

local function check(cond, message)
    assert(type(cond) == "boolean", "check needs a boolean: " .. message)
    if not cond then error("FAIL: " .. message, 2) end
end

-- Known CRC-32 values (zlib.crc32).
check(PBConfig.crc32("") == "00000000", "crc of empty string")
check(PBConfig.crc32("hello") == "3610a686", "crc of hello")
check(PBConfig.crc32("123456789") == "cbf43926", "crc check value")

local dir = os.getenv("TMPDIR") or "/tmp"
local path = dir .. "/pbconfig_test_" .. os.time() .. ".cfg"
local function write(s) local f = assert(io.open(path, "wb")); f:write(s); f:close() end
local function read(p) local f = assert(io.open(p or path, "rb")); local s = f:read("*a"); f:close(); return s end
local function cleanup()
    os.remove(path)
    os.remove(path .. PBConfig.BACKUP_SUFFIX)
end

local body = "ask4lang=0\nbootlogo=@snapshot\nofflogo=@cover_logo\nusbmode=0\n"
local original = body .. "\n#" .. PBConfig.crc32(body) .. "\n"
write(original)

check(PBConfig.get("bootlogo", path) == "@snapshot", "reads a value")
check(PBConfig.get("missing", path) == nil, "missing key is nil")

check(PBConfig.set("bootlogo", "@cover_logo", path), "set succeeds")
check(PBConfig.get("bootlogo", path) == "@cover_logo", "value changed")
check(PBConfig.get("offlogo", path) == "@cover_logo", "other keys kept")
check(read(path .. PBConfig.BACKUP_SUFFIX) == original, "backup is the original")
local new_body = read():match("^(.*)\n#%x+\n$")
check(new_body == "ask4lang=0\nbootlogo=@cover_logo\nofflogo=@cover_logo\nusbmode=0\n", "layout kept, only one line changed")

check(PBConfig.set("ask4lang", "1", path) and PBConfig.get("ask4lang", path) == "1", "first line can change")
check(PBConfig.set("newkey", "x", path) and PBConfig.get("newkey", path) == "x", "new key added")
check(read():match("usbmode=0\nnewkey=x\n\n#%x+\n$") ~= nil, "new key goes before the blank line")

-- A file with a wrong checksum is never rewritten.
write(body .. "\n#00000000\n")
local ok = PBConfig.set("bootlogo", "@cover_logo", path)
check(ok == false, "refuses a file with a bad checksum")
check(PBConfig.get("bootlogo", path) == nil, "does not read a file with a bad checksum")

cleanup()
print("pbconfig_test: ok")
