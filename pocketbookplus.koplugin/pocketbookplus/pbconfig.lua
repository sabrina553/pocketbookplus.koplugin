--[[--
Reads and writes the PocketBook firmware's settings file,
/mnt/ext1/system/config/global.cfg.

Format (firmware 6.10, Verse Pro): `key=value` lines, a blank line, then
`#` and the CRC-32 of everything before that last line, as 8 lowercase hex
digits. A file whose checksum does not match may be discarded by the
firmware, so every write recomputes it.

Plain Lua (LuaJIT's `bit`), no KOReader requires, so it can be tested on a PC.
--]]--

local bit = require("bit")

local PBConfig = {}
PBConfig.PATH = "/mnt/ext1/system/config/global.cfg"
PBConfig.BACKUP_SUFFIX = ".before-pocketbookplus"

local crc_table
local function crc32(s)
    if not crc_table then
        crc_table = {}
        for i = 0, 255 do
            local c = i
            for _j = 1, 8 do
                if bit.band(c, 1) == 1 then
                    c = bit.bxor(0xEDB88320, bit.rshift(c, 1))
                else
                    c = bit.rshift(c, 1)
                end
            end
            crc_table[i] = c
        end
    end
    local c = 0xFFFFFFFF
    for i = 1, #s do
        c = bit.bxor(crc_table[bit.band(bit.bxor(c, s:byte(i)), 0xFF)], bit.rshift(c, 8))
    end
    return bit.tohex(bit.bnot(c), 8)
end
PBConfig.crc32 = crc32

local function readFile(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local data = f:read("*a")
    f:close()
    return data
end

-- Splits the file into the checksummed body and the checksum.
local function split(data)
    local body, sum = data:match("^(.*)\n#(%x%x%x%x%x%x%x%x)\n?$")
    return body, sum
end

-- Returns the value of `key`, or nil. Also nil when the file is missing or
-- its checksum does not match, so callers never act on a file we would not
-- write back.
function PBConfig.get(key, path)
    local data = readFile(path or PBConfig.PATH)
    if not data then return nil end
    local body, sum = split(data)
    if not body or crc32(body) ~= sum then return nil end
    return body:match("\n" .. key:gsub("%p", "%%%0") .. "=([^\n]*)")
        or body:match("^" .. key:gsub("%p", "%%%0") .. "=([^\n]*)")
end

local function replaceKey(body, key, value)
    local escaped = key:gsub("%p", "%%%0")
    local line = key .. "=" .. value
    local n
    body, n = body:gsub("^" .. escaped .. "=[^\n]*", function() return line end)
    if n == 0 then
        body, n = body:gsub("\n" .. escaped .. "=[^\n]*", function() return "\n" .. line end)
    end
    if n == 0 then
        -- New key: before the trailing blank line, keeping the layout.
        local head, blank = body:match("^(.-)(\n*)$")
        body = head .. "\n" .. line .. blank
    end
    return body
end

--- Sets `key` to `value` in place, keeping every other line as it was.
--- @return boolean ok, string|nil error
function PBConfig.set(key, value, path)
    path = path or PBConfig.PATH
    local data = readFile(path)
    if not data then return false, "cannot read " .. path end
    local body, sum = split(data)
    if not body then return false, "unexpected format" end
    if crc32(body) ~= sum then return false, "checksum mismatch, not touching it" end
    local new_body = replaceKey(body, key, value)
    if new_body == body then return true end

    local backup = path .. PBConfig.BACKUP_SUFFIX
    if not readFile(backup) then
        local b = io.open(backup, "wb")
        if not b then return false, "cannot write backup" end
        b:write(data)
        b:close()
    end
    local tmp = path .. ".tmp"
    local f = io.open(tmp, "wb")
    if not f then return false, "cannot write " .. tmp end
    f:write(new_body, "\n#", crc32(new_body), "\n")
    f:close()
    if not os.rename(tmp, path) then
        os.remove(tmp)
        return false, "cannot replace " .. path
    end
    return true
end

-- Fixed text, run in the background so a slow iv2sh never stalls the reader.
-- Never call while going to sleep: it leaves the device half asleep.
local RELOAD_CMD =
    [[(sync; p=$(ps | grep '[t]askmgr\.app' | grep -v visualizer | awk '{print $1}' | head -n 1); ]] ..
    [[[ -n "$p" ] && /ebrmain/bin/iv2sh SendEventTo "$p" 154 0) >/dev/null 2>&1 &]]

--- Asks the firmware's task manager to reload its settings and lock images.
function PBConfig.reloadTaskmgr()
    os.execute(RELOAD_CMD)
end

return PBConfig
