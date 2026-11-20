--[[--
EPUB metadata the PocketBook library often gets wrong, read from the OPF, and
the corrections it implies for a library row.

The rules follow PbDbFixer by Martin Brodbeck (MIT),
https://git.rustysoft.de/martin/PbDbFixer:
- authors are dc:creator elements with role "aut" (or no role); the sort
  form comes from opf:file-as (EPUB 2) or a refining file-as meta (EPUB 3);
- the series comes from calibre:series / calibre:series_index (EPUB 2) or
  belongs-to-collection with group-position (EPUB 3);
- the genre is the first dc:subject.

Plain Lua so it can be tested on a PC.
--]]--

local EpubCfi = require("pocketbookplus/sync/epubcfi")
local parseXml, attr = EpubCfi._parseXml, EpubCfi._attr

local Metadata = {}

local function text(node)
    local parts = {}
    for _i, ch in ipairs(node.children) do
        if type(ch) == "string" then table.insert(parts, ch) end
    end
    local t = table.concat(parts):gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s+", " ")
    t = t:gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&quot;", '"'):gsub("&apos;", "'"):gsub("&amp;", "&")
    return t
end

local function find(node, name, out)
    out = out or {}
    for _i, ch in ipairs(node.children) do
        if type(ch) == "table" then
            if ch.name == name then table.insert(out, ch) end
            find(ch, name, out)
        end
    end
    return out
end

-- Attributes may carry a namespace prefix ("opf:file-as").
local function attrAny(node, name)
    return attr(node.attrs, name) or node.attrs:match("[%s:]" .. name:gsub("%W", "%%%0") .. "%s*=%s*\"([^\"]*)\"")
end

--- Path of the OPF inside the EPUB, from META-INF/container.xml.
function Metadata.rootfile(container_xml)
    for _i, rf in ipairs(find(parseXml(container_xml or ""), "rootfile")) do
        local path = attr(rf.attrs, "full-path")
        if path then return path end
    end
    return nil
end

--- @return table { authors = { { name=, sort= } }, genre=, series = { name=, index= } }
function Metadata.fromOpf(opf_xml)
    -- The parser is shared with the XHTML code, where <meta> is a void
    -- element; in an OPF, EPUB 3 <meta> holds text, so give it another name.
    opf_xml = (opf_xml or ""):gsub("<(/?)([%w]*:?)meta([%s/>])", "<%1%2opfmeta%3")
    local root = parseXml(opf_xml)
    local meta = { authors = {}, genre = nil, series = { name = nil, index = nil } }
    local pkg = find(root, "package")[1]
    local epub3 = pkg ~= nil and (attr(pkg.attrs, "version") or ""):sub(1, 1) == "3"

    -- EPUB 3 refinements, keyed by "#id".
    local refines = {}
    for _i, m in ipairs(find(root, "opfmeta")) do
        local target = attr(m.attrs, "refines")
        local prop = attr(m.attrs, "property")
        if target and prop then
            refines[target] = refines[target] or {}
            refines[target][prop:match("[^:]+$")] = text(m)
        end
    end

    for _i, c in ipairs(find(root, "creator")) do
        local id = attr(c.attrs, "id")
        local ref = id and refines["#" .. id] or {}
        local role = attrAny(c, "role") or ref.role
        if role == nil or role == "aut" then
            local name = text(c)
            if name ~= "" then
                table.insert(meta.authors, { name = name, sort = attrAny(c, "file-as") or ref["file-as"] })
            end
        end
    end

    local subject = find(root, "subject")[1]
    if subject and text(subject) ~= "" then meta.genre = text(subject) end

    for _i, m in ipairs(find(root, "opfmeta")) do
        local name = attr(m.attrs, "name")
        if name == "calibre:series" then
            meta.series.name = attr(m.attrs, "content")
        elseif name == "calibre:series_index" then
            meta.series.index = tonumber(attr(m.attrs, "content") or "")
        elseif epub3 and attr(m.attrs, "property") == "belongs-to-collection" and not meta.series.name then
            meta.series.name = text(m)
            local id = attr(m.attrs, "id")
            local ref = id and refines["#" .. id] or {}
            meta.series.index = tonumber(ref["group-position"] or "")
        end
    end
    if meta.series.name == "" then meta.series.name = nil end
    return meta
end

-- First character, upper-cased, as the library's A-Z index wants it. UTF-8
-- aware; only ASCII letters change case (Lua's upper() is byte-wise).
local function firstLetter(s)
    local ch = s:match("^[%z\1-\127\194-\244][\128-\191]*")
    return ch and ch:upper() or nil
end

--- The corrections for one library row, as a table of column = value
--- (empty when the row is right). `row` has author, firstauthor,
--- first_author_letter, series, genre.
function Metadata.changes(row, meta)
    local out = {}
    if #meta.authors == 0 then return out end

    local names, sorts = {}, {}
    for _i, a in ipairs(meta.authors) do
        table.insert(names, a.name)
        if a.sort and a.sort ~= "" then table.insert(sorts, a.sort) end
    end
    table.sort(sorts)

    local author = table.concat(names, ", ")
    if (row.author or "") ~= author then out.author = author end

    if #sorts > 0 then
        local firstauthor = table.concat(sorts, " & ")
        local current = row.firstauthor or ""
        local all_in = true
        for _i, s in ipairs(sorts) do
            if not current:find(s, 1, true) then all_in = false end
        end
        if not all_in then out.firstauthor = firstauthor end
        local letter = firstLetter(firstauthor)
        if letter and (row.first_author_letter or "") ~= letter then out.first_author_letter = letter end
    end

    if meta.series.name and (row.series or "") == "" then
        out.series = meta.series.name
        out.numinseries = math.floor(meta.series.index or 0)
    end
    if meta.genre and (row.genre or "") == "" then out.genre = meta.genre end
    return out
end

return Metadata
