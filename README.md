# Mac Space Finder

A small native macOS app (SwiftUI) that shows disk space, folder sizes, finds the biggest
folders, and copies / moves / migrates folders to an external disk.

## Build & run

```bash
./build.sh
open "build/Mac Space Finder.app"
```

Requires macOS 14+ and Xcode (or the Swift toolchain). Drag the app to `/Applications` if you
want to keep it.

## What it does

| Area | Details |
|---|---|
| **Disks** (sidebar) | Every mounted disk with a used/free bar. Updates when disks are plugged in or ejected. |
| **Folder Contents** | Items in the current folder sorted by size, with a share-of-folder bar. Double-click a folder to go into it, use **Up** (toolbar) to go back. Sizes fill in live while the scan runs; going into a folder that was already scanned is instant. |
| **Find Biggest Folders** | Scans the current folder and everything inside it and lists the top 100 folders. A folder is left out when one subfolder holds ≥ 80% of its space, so the list points at where the space really is. App bundles and libraries (`.app`, `.photoslibrary`) are listed whole, never their insides. |
| **Copy To…** | Copies the selected items to a disk or folder; the originals stay. |
| **Move To…** | Copies, verifies every file arrived with the same size (and links with the same target), then removes the originals. Originals go to the **Trash** by default (empty it to free the space), or can be deleted permanently. |
| **Migrate…** | Like Move, then leaves a link at the old location pointing to the new one, so apps still find the files. The external disk must be connected for the link to work. |

Sizes are *allocated* sizes (what the files actually take on disk), the same figure `du` reports.

## Scanning speed

Each folder is read with `getattrlistbulk` (one system call returns a whole batch of entries with
their sizes) on up to 8 threads at once; SSDs answer parallel reads much faster than one-at-a-time
ones. Folders are kept as a compact tree (parent/child links) rather than one text path per folder.

Measured on an M4 Max (internal SSD, repeat runs):

| Folder | Files / folders | Before | Now |
|---|---|---|---|
| /Applications | 838k / 126k | 17.3 s | 1.7–2.1 s |
| ~/PROJECTS | 3.08M / 357k | 65.4 s | 8.6–9.0 s |

Peak memory for the 3M-file scan went from 91 MB to ~70 MB. The new scanner is checked against the
previous one in the tests: every folder size and the whole "biggest folders" list must match
exactly (verified on both folders above). External USB disks have not been timed.

## Remembered between launches

Finished scans are saved to `~/Library/Caches/local.macspacefinder/Scans` (a folder only your user
can read; about 11 MB for a 357k-folder scan, saved or loaded in a few hundredths of a second).
Reopening the app shows those sizes immediately, without scanning, and **Find Biggest Folders**
lists from them too.

- **Internal disk:** macOS keeps a history of which folders changed (FSEvents). At launch the app
  replays the changes made since the scan was saved and re-reads only those folders, so the
  remembered sizes are current. The status bar says "updated with every change since".
- **External disks:** that history can't be trusted (exFAT keeps none, and changes made on another
  computer are never recorded), so remembered sizes are shown with "this disk may have changed
  since then" and a **Rescan** link.
- **While the app is open:** every remembered or scanned folder is kept up to date as files change,
  on internal and external disks alike.

To forget everything, quit the app and delete that folder.

## Safety rules built in

- An original is removed **only** when the copy finished with zero errors **and** verification
  passed. Any skipped or unreadable file means the original is kept, and the problems are listed.
- Cancelling removes the partial copy and never touches the original.
- Existing items at the destination are never overwritten: a clash becomes "Movies 2", "clip 2.mov".
- Move/Migrate is refused for macOS system folders (`/System`, `/usr`, `/private`, `/Library`,
  `/Applications`, your home folder, `~/Library`, disk roots…). Copy is always allowed.
- Warns when the destination is too small, is FAT32 (4 GB file limit), is the same disk (moving
  won't free space), or when moving out of iCloud Drive (that removes the files from iCloud on
  all devices).

## Permissions

macOS will ask for access to Desktop, Documents, Downloads, and other apps' data the first
time they are scanned. For complete sizes everywhere (Mail, Messages, Safari data…), add the app
under **System Settings › Privacy & Security › Full Disk Access**. The app shows a link to that
setting when some folders couldn't be read. Because the app is signed locally (ad hoc), macOS
may ask again after a rebuild.

## Tests

```bash
swift test
```

`MSF_COMPARE_ROOT=/Applications swift test --filter testMatchesPreviousScannerExactly` also
compares the new and previous scanners folder by folder on a folder of your choice.

The exFAT tests (most external drives use exFAT) run when `MSF_EXFAT_DEST` points to a folder on
an exFAT disk. A throwaway disk image works:

```bash
hdiutil create -size 64m -fs ExFAT -volname MSFTEST -o /tmp/msf-exfat.dmg
hdiutil attach /tmp/msf-exfat.dmg -mountpoint /tmp/msf-exfat -nobrowse
MSF_EXFAT_DEST=/tmp/msf-exfat swift test
hdiutil detach /tmp/msf-exfat
```

## Known limitations

- Hard-linked files are counted once per link, so totals can be a little high for folders full
  of hard links (e.g. some developer caches).
- Starting at the startup disk (`/`) scans the whole Mac and can take a few minutes.
- `-StartPath /some/folder` on the command line opens that folder instead of Home
  (`open "build/Mac Space Finder.app" --args -StartPath ~/Movies`).

## Layout

```
Sources/MacSpaceFinder/
  App.swift            app entry point
  AppModel.swift       state: navigation, scan cache, transfers
  Scanner.swift        parallel getattrlistbulk scanner (FolderTree) + "biggest folders" picker
  SizeStore.swift      all scans so far; keeps them consistent, current and remembered
  ChangeWatcher.swift  FSEvents folder-change notices (live and replayed history)
  ScanCache.swift      saves / loads scans between launches
  Transfer.swift       copy / move / migrate engine (system copyfile + verification)
  Volumes.swift        mounted disks and free space
  ContentView.swift    sidebar, tables, toolbar, status bars
  TransferSheet.swift  destination picker, progress, results
  Util.swift           formatting and path helpers, move safety rules
Tests/                 scanner (incl. comparison with the previous scanner), incremental
                       updates, cache, live and replayed change notices, size store,
                       transfer, exFAT and model tests
build.sh               builds build/Mac Space Finder.app
```
