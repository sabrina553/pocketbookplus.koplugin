# pocketbookplus.koplugin

One KOReader plugin for PocketBook that brings together several community
plugins: lock-screen covers, library progress sync, boot last-page and
hardware fixes, each behind its own toggle under **Tools → PocketBook Plus**.

**Status:** early development.

## Planned modules
- **Lock screen:** cover, cover + progress, reading stats, or your own images
  from a `lockscreens` folder at the top of the device's storage (fixed, or a
  new one after each wake). Drawn from the book file, so KOReader's night mode
  no longer inverts it.
- **Sync:** library progress and two-way position with PBReader.
- **Boot:** show the last page on start-up.
- **Fixes:** Home as Back, page-turn keys follow rotation, upside-down start.
- **Appearance:** PocketBook-style dialogs (experimental).

Do not run it alongside the plugins it replaces: they write the same files.

## Install
Copy `pocketbookplus.koplugin/` to `applications/koreader/plugins/` on the device.

## Credits
Built on code and ideas from these AGPL-3.0 / GPL-3.0 plugins:
- [pbfixes](https://github.com/glaucon1984/pbfixes.koplugin),
  [pbposition](https://github.com/glaucon1984/pbposition.koplugin) and
  [standbycover](https://github.com/glaucon1984/standbycover.koplugin) by glaucon1984
- [coverprogresspocketbook](https://github.com/apastuszak/coverprogresspocketbook.koplugin) by apastuszak
- [chartingsleepscreen](https://github.com/tadeasf/chartingsleepscreen_koplugin) by tadeasf
- [pocketbooktools](https://github.com/reuerendo/pocketbooktools.koplugin) by reuerendo

pocketbookcover and pocketbooksync (ckilb) inspired the idea; no code is taken
from them as they carry no licence.

## Licence
AGPL-3.0, see [LICENSE](LICENSE).
