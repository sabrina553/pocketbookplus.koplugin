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

## Writes and wear
Lock-screen images are ~9 MB per update (portrait and landscape). They are
written at most once per whole percent read (after page turns pause), once
per wake in random-image mode, and when night mode is switched with "Keep
normal colours" on. That is far inside the internal storage's rated
lifetime. The firmware is never asked to reload the image while the device
is going to sleep, which can leave some models half asleep.

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

- The line icon in `icons/line/` is the KOReader icon from
  [Arcticons](https://github.com/Donnnno/Arcticons) by Donnnno (GPL-3.0),
  rendered as a PocketBook icon. `icons/koreader/` is KOReader's own logo (AGPL-3.0).
- Quick setup follows
  [PocketBook Desktop and App Customizations](https://github.com/jjrrw174/PocketBook-Desktop-and-App-Customizations)
  by jjrrw174 and the MobileRead thread it summarises.

pocketbookcover and pocketbooksync (ckilb) inspired the idea; no code is taken
from them as they carry no licence.

## Licence
AGPL-3.0, see [LICENSE](LICENSE).
