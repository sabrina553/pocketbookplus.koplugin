-- Run: luajit tests/metadata_test.lua
package.path = "pocketbookplus.koplugin/?.lua;" .. package.path
local Metadata = require("pocketbookplus/library/metadata")

local function check(cond, message)
    assert(type(cond) == "boolean", "check needs a boolean: " .. message)
    if not cond then error("FAIL: " .. message, 2) end
end

check(Metadata.rootfile([[<?xml version="1.0"?><container><rootfiles>
<rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>]])
    == "OEBPS/content.opf", "rootfile path")

-- EPUB 2, as Calibre writes it.
local epub2 = Metadata.fromOpf([[<?xml version="1.0"?>
<package xmlns="http://www.idpf.org/2007/opf" version="2.0">
<metadata xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:opf="http://www.idpf.org/2007/opf">
  <dc:title>The Hobbit</dc:title>
  <dc:creator opf:role="aut" opf:file-as="Tolkien, J. R. R.">J. R. R. Tolkien</dc:creator>
  <dc:creator opf:role="ill">Alan Lee</dc:creator>
  <dc:subject>Fantasy</dc:subject>
  <dc:subject>Classics</dc:subject>
  <meta name="calibre:series" content="Middle-earth"/>
  <meta name="calibre:series_index" content="1.0"/>
</metadata></package>]])
check(#epub2.authors == 1, "illustrator is not an author")
check(epub2.authors[1].name == "J. R. R. Tolkien", "EPUB 2 author name")
check(epub2.authors[1].sort == "Tolkien, J. R. R.", "EPUB 2 file-as")
check(epub2.genre == "Fantasy", "first subject is the genre")
check(epub2.series.name == "Middle-earth" and epub2.series.index == 1, "calibre series")

-- EPUB 3 with refinements.
local epub3 = Metadata.fromOpf([[<?xml version="1.0"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0">
<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
  <dc:creator id="c1">Shannon Chakraborty</dc:creator>
  <meta refines="#c1" property="file-as">Chakraborty, Shannon</meta>
  <meta refines="#c1" property="role" scheme="marc:relators">aut</meta>
  <dc:creator id="c2">Some Translator</dc:creator>
  <meta refines="#c2" property="role" scheme="marc:relators">trl</meta>
  <meta property="belongs-to-collection" id="s1">The Amina al-Sirafi Trilogy</meta>
  <meta refines="#s1" property="group-position">1</meta>
</metadata></package>]])
check(#epub3.authors == 1 and epub3.authors[1].sort == "Chakraborty, Shannon", "EPUB 3 refined author")
check(epub3.series.name == "The Amina al-Sirafi Trilogy" and epub3.series.index == 1, "EPUB 3 series")
check(epub3.genre == nil, "no subject, no genre")

-- Corrections.
local row = { author = "Tolkien", firstauthor = "Tolkien", first_author_letter = "T", series = "", genre = "" }
local c = Metadata.changes(row, epub2)
check(c.author == "J. R. R. Tolkien", "author fixed")
check(c.firstauthor == "Tolkien, J. R. R.", "sort author fixed")
check(c.first_author_letter == nil, "letter already right")
check(c.series == "Middle-earth" and c.numinseries == 1, "series added")
check(c.genre == "Fantasy", "genre added")

local ok_row = { author = "J. R. R. Tolkien", firstauthor = "Tolkien, J. R. R.", first_author_letter = "T",
    series = "Middle-earth", genre = "Fantasy" }
check(next(Metadata.changes(ok_row, epub2)) == nil, "a correct row needs nothing")

check(next(Metadata.changes(row, { authors = {}, series = {} })) == nil, "no authors in the EPUB: leave the row alone")

-- Two authors: names joined with ", ", sort forms sorted and joined with " & ".
local two = { authors = { { name = "B Writer", sort = "Writer, B" }, { name = "A Author", sort = "Author, A" } }, series = {} }
local c2 = Metadata.changes({ author = "", firstauthor = "", first_author_letter = "" }, two)
check(c2.author == "B Writer, A Author", "two author names")
check(c2.firstauthor == "Author, A & Writer, B", "two sort forms")
check(c2.first_author_letter == "A", "letter from the sorted form")

print("metadata_test: ok")
