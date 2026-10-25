# 🗂️ Finder sidebar icons (`SidebarIconsRestamp`)

The Favourites rows in Finder's sidebar carry a 4-char override-icon code
(`com.apple.LSSharedFileList.OverrideIcon.OSType`). The symbol behind each code is served by
the helper app `~/Library/Application Support/VictorSidebarIcons/VictorSidebarIcons.app`
(one exported UTI per code, custom symbols in its `Assets.car`); the artwork, `codes.tsv`
and the `sidebar-icon list | set <row> <CODE>` CLI live next to it, with their own README.
Those stay there — they are the *drawing*. This app owns only the *keeping*.

**The wipe.** A folder that has its own icon file (`Icon\r` + kHasCustomIcon — Google Drive
puts one on My Drive, Conta, Acte, ###sesiuni) loses the sidebar drawing on **any mtime
change** of that folder. The code survives on the row; re-inserting the row in place with
the same code redraws it, no Finder restart.

**Since 2026-10-25 the re-insert runs inside this app** (`SidebarIconsRestamp`, started 4 s
after launch, off the launch path like the other stages). Before that it was the LaunchAgent
`ro.victorrentea.sidebar-icons.restamp` (WatchPaths on the four folders, `sidebar-icon restamp`
at the end), retired with the move to the new Mac — one less agent to install by hand, and the
app is up whenever Finder is.

- One `DispatchSource` (`O_EVTONLY`, `.write/.attrib/.extend/.rename`) per folder in
  `SidebarIconsRestamp.watched` — the same vnode-mtime trigger launchd's WatchPaths used.
- A burst of changes (Drive writes several files) collapses into **one** restamp, 2 s after
  the last event (`settle`). One pass at launch too, as `RunAtLoad` did.
- A folder that is absent at launch (Drive not mounted yet, a fresh Mac before the first
  sync) is logged and skipped; the next launch picks it up.
- Log lines: `SidebarIcons: watching N of 4 folders`, `SidebarIcons: restamped My Drive=V00C …`,
  `REFUSED <row>` when `LSSharedFileListInsertItemURL` returns nil (sharedfilelistd answers
  only a process with a bundle id — the .app has one; a bare `swift run` would not).
- A **new row** on a folder that wipes must be added to `watched`. Rows on folders without
  `Icon\r` (workspace, Clients, Cursuri) never wipe and need nothing.
