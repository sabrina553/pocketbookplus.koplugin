# PocketBook Plus for KOReader

Makes KOReader feel at home on a PocketBook. One plugin brings together the
best of several community plugins: book covers and reading stats on the lock
screen, progress synced with the PocketBook library, hardware fixes, and a
handful of quality-of-life tweaks. Each part has its own toggle under
**Tools → PocketBook Plus**, so you only turn on what you want.

Tested on a PocketBook Verse Pro (PB634, firmware U634.6.10) with KOReader
v2026.07.2. The plugin stays switched off on non-PocketBook devices.

## Features

### Lock screen
- Shows the **book cover** (optionally with a progress bar), your **reading
  stats**, or **your own images** from a `lockscreens` folder at the top of
  the device's storage (a fixed one, or a new one after each wake).
- Covers can **fit, fill (crop) or stretch** to the screen.
- **Power-off screen:** the cover of the book you're reading.
- **Boot screen:** the last page you read, without menus or pop-ups.
- In dark mode the firmware inverts the lock screen, just like its own.

### Library sync
- Keeps the PocketBook library in step with KOReader: home-screen progress,
  the finished flag, and the place PBReader opens at.
- Offers PBReader's position when it's newer than KOReader's.
- Optionally hides finished books from the home screen, or takes them out of
  a collection such as a to-read list.

### Library metadata
- Fixes authors, author sorting, series and genres in the PocketBook library
  from each EPUB's own metadata. It shows what it would change first, and
  the last three fixes can be undone.
- Removes library entries whose book file is gone (never those that belong
  to a connected account).

### Device fixes
- The **Home button** works as Back.
- **Page-turn buttons** follow the screen rotation.
- **Upside-down start:** KOReader starts the right way up.
- **Night mode** is linked with PocketBook's dark mode: switching one
  switches the other, and the PocketBook's setting wins on start and wake.
- Tapping the **battery statistics** title closes it.

### Quick setup
The PocketBook-side changes a KOReader install usually needs, done from
KOReader: open chosen file types in KOReader, give the app its proper name on
the home screen, and pick a home-screen icon.

### Reader
- **Cover pages:** the images in a book's first two sections (usually the
  cover and inside cover) fit or stretch to the page, inside the margins.

### Patches
Installs KOReader user patches, each with its own toggle: hide the "Opening
file" message, keep the screen while the first book loads, and hide the
frontlight, Wi-Fi and SSH pop-ups. Patches take effect after restarting
KOReader.

### PocketBook-style dialogs
Restyles KOReader's messages and dialogs to match the PocketBook firmware.
Experimental and off by default.

## Install
1. Download `pocketbookplus.koplugin-<version>.zip` from the
   [latest release](https://github.com/sabrina553/pocketbookplus.koplugin/releases/latest).
2. Unzip it into `applications/koreader/plugins/` on the device.
3. Restart KOReader and open **Tools → PocketBook Plus**.

Don't run it alongside the plugins it replaces (listed under Credits): they
write the same files.

## Safe by design
- **Firmware files are backed up** before the first change, next to the
  original with a `.before-pocketbookplus` suffix. `global.cfg` keeps its
  checksum, and every file is written to a temporary copy first and then
  swapped in.
- **The library database** is only ever updated in place, never replaced.
- **Flash wear:** lock-screen images (about 9 MB per update) are written at
  most once per whole percent read, or once per wake in random-image mode,
  far inside the storage's rated lifetime.
- The firmware is never asked to reload while the device is going to sleep,
  which can leave some models half asleep.

## Uninstall
Before deleting the plugin, turn off the lock screen, the power-off and boot
screens and any Quick setup changes: the plugin then puts back the firmware's
own settings and images where it can. The backups with a
`.before-pocketbookplus` suffix stay in place as a fallback. Then delete
`applications/koreader/plugins/pocketbookplus.koplugin/`. Installed patches stay in
`koreader/patches/`: delete the `2-pbplus-*.lua` files there.

## Credits
Built on code and ideas from these AGPL-3.0 / GPL-3.0 plugins:
- [pbfixes](https://github.com/glaucon1984/pbfixes.koplugin),
  [pbposition](https://github.com/glaucon1984/pbposition.koplugin) and
  [standbycover](https://github.com/glaucon1984/standbycover.koplugin) by glaucon1984
- [coverprogresspocketbook](https://github.com/apastuszak/coverprogresspocketbook.koplugin) by apastuszak
- [chartingsleepscreen](https://github.com/tadeasf/chartingsleepscreen_koplugin) by tadeasf
- [pocketbooktools](https://github.com/reuerendo/pocketbooktools.koplugin) by reuerendo

Also:
- The line icon in `icons/line/` is the KOReader icon from
  [Arcticons](https://github.com/Donnnno/Arcticons) by Donnnno (GPL-3.0),
  rendered as a PocketBook icon. `icons/koreader/` is KOReader's own logo (AGPL-3.0).
- Library metadata fixing follows [PbDbFixer](https://git.rustysoft.de/martin/PbDbFixer)
  by Martin Brodbeck (MIT).
- PocketBook-style dialogs are adapted from pocketbooktools' theme by reuerendo (GPL-3.0).
- Quick setup follows
  [PocketBook Desktop and App Customizations](https://github.com/jjrrw174/PocketBook-Desktop-and-App-Customizations)
  by jjrrw174 and the MobileRead thread it summarises.
- The patches are rewrites of community KOReader user patches whose original
  authors are unknown; credit will be added once found.

pocketbookcover and pocketbooksync (ckilb) inspired the idea; no code is taken
from them as they carry no licence.

## Licence
AGPL-3.0, see [LICENSE](LICENSE).
