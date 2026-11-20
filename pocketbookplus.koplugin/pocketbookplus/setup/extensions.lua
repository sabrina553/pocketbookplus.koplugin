--[[--
File associations: which app the PocketBook opens a file type with.

The firmware's defaults are in /ebrmain/config/extensions.cfg (read-only);
lines in the user's /mnt/ext1/system/config/extensions.cfg override them per
extension. Line format (firmware 6.10):

    ext:@Type_name:category:app1.app,app2.app:ICON_NAME

The first app is the default; the others are offered under "Open with".
This file has no checksum.

Plain Lua so it can be tested on a PC.
--]]--

local Ext = {}

Ext.SYSTEM_PATH = "/ebrmain/config/extensions.cfg"
Ext.USER_PATH = "/mnt/ext1/system/config/extensions.cfg"
Ext.APP = "koreader.app"

-- Types KOReader opens that the firmware also lists. cbr is left out: the
-- firmware converts it with its own app, and KOReader has no RAR support.
Ext.SUPPORTED = { "epub", "epub3", "pdf", "fb2", "mobi", "azw", "azw3", "prc", "pdb", "djvu", "djv",
    "cbz", "txt", "rtf", "doc", "docx", "htm", "html", "xhtml", "chm" }

function Ext.parseLine(line)
    local ext, typ, cat, apps, icon = line:match("^([^:#][^:]*):([^:]*):([^:]*):([^:]*):(.*)$")
    if not ext then return nil end
    local list = {}
    for app in apps:gmatch("[^,]+") do table.insert(list, app) end
    return { ext = ext, type = typ, cat = cat, apps = list, icon = icon }
end

function Ext.formatLine(e)
    return table.concat({ e.ext, e.type, e.cat, table.concat(e.apps, ","), e.icon }, ":")
end

--- @return table entries by ext, table lines in order (strings)
function Ext.parse(text)
    local by_ext, lines = {}, {}
    for line in (text or ""):gmatch("[^\n]+") do
        table.insert(lines, line)
        local e = Ext.parseLine(line)
        if e then by_ext[e.ext] = e end
    end
    return by_ext, lines
end

local function without(list, item)
    local out = {}
    for _i, v in ipairs(list) do if v ~= item then table.insert(out, v) end end
    return out
end

--- True when `ext` opens in KOReader by default.
function Ext.opensInKOReader(user, system, ext)
    local e = user[ext] or system[ext]
    return e ~= nil and e.apps[1] == Ext.APP
end

--- Returns the new user file text with `ext` set to open in KOReader (on)
--- or back to the firmware's choice (off). Other lines are kept as they are.
function Ext.apply(user_text, system_text, ext, on)
    local system = Ext.parse(system_text)
    local user, lines = Ext.parse(user_text)
    local base = user[ext] or system[ext]
    local new_line
    if on then
        if not base then return user_text end
        local e = { ext = base.ext, type = base.type, cat = base.cat, icon = base.icon,
            apps = without(base.apps, Ext.APP) }
        table.insert(e.apps, 1, Ext.APP)
        new_line = Ext.formatLine(e)
    else
        if not user[ext] then return user_text end
        local sys = system[ext]
        local apps = without(user[ext].apps, Ext.APP)
        -- Back to the firmware's own entry: drop the override altogether.
        if not sys or table.concat(apps, ",") == table.concat(sys.apps, ",") or #apps == 0 then
            new_line = false
        else
            local e = user[ext]
            new_line = Ext.formatLine({ ext = e.ext, type = e.type, cat = e.cat, icon = e.icon, apps = apps })
        end
    end

    local out, replaced = {}, false
    for _i, line in ipairs(lines) do
        local e = Ext.parseLine(line)
        if e and e.ext == ext then
            if new_line then table.insert(out, new_line) end
            replaced = true
        else
            table.insert(out, line)
        end
    end
    if not replaced and new_line then table.insert(out, new_line) end
    return table.concat(out, "\n") .. "\n"
end

return Ext
