import CoreServices
import Foundation

/// 🗂️ Finder sidebar icons that survive Google Drive.
///
/// Each Favourites row can carry `com.apple.LSSharedFileList.OverrideIcon.OSType`,
/// a 4-char code that `~/Library/Application Support/VictorSidebarIcons/VictorSidebarIcons.app`
/// turns into a symbol (its Info.plist exports one UTI per code; see the README
/// next to it — that helper app and its `sidebar-icon list | set` CLI stay where
/// they are, this class only took over the *restamp*). A folder that has its own
/// icon file (`Icon\r` + kHasCustomIcon — Google Drive puts one on My Drive,
/// Conta, Acte, ###sesiuni) loses the sidebar drawing on **any mtime change** of
/// that folder; the code stays on the row, and re-inserting the row with the same
/// code redraws it, with no Finder restart.
///
/// Until 2026-10-25 that re-insert was a LaunchAgent
/// (`ro.victorrentea.sidebar-icons.restamp`, WatchPaths on the four folders, a
/// compiled `sidebar-icon restamp` at the end). It moved in here with the Mac
/// migration: one less agent to install by hand, and the app is up whenever Finder
/// is. Same shape — watch the folders, wait 2 s for Drive to finish writing, then
/// restamp every row that has a code — plus one pass at launch, as `RunAtLoad` did.
///
/// Why a `DispatchSource` per folder and not FSEvents: launchd's WatchPaths fires
/// on the directory's own vnode (its mtime), which is exactly `O_EVTONLY` +
/// `.write/.attrib` on the directory fd. A folder that does not exist yet (Drive
/// not mounted, a new Mac before the first sync) is retried on the next launch —
/// there is nothing to watch on a path that is not there.
@MainActor
final class SidebarIconsRestamp {

    /// The folders whose own icon file makes Finder forget the sidebar symbol.
    /// Same four as the retired LaunchAgent's WatchPaths.
    static let watched: [String] = [
        "My Drive",
        "My Drive/Conta",
        "My Drive/Acte",
        "My Drive/Cursuri/###sesiuni",
    ].map { NSHomeDirectory() + "/" + $0 }

    static let key = "com.apple.LSSharedFileList.OverrideIcon.OSType" as CFString
    static let settle: TimeInterval = 2

    private var sources: [DispatchSourceFileSystemObject] = []
    private var pending: DispatchWorkItem?

    func start() {
        for path in Self.watched {
            let fd = open(path, O_EVTONLY)
            guard fd >= 0 else { overlayInfo("SidebarIcons: not watching \(path) (absent)"); continue }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd, eventMask: [.write, .attrib, .extend, .rename], queue: .main)
            source.setEventHandler { [weak self] in self?.schedule() }
            source.setCancelHandler { close(fd) }
            source.resume()
            sources.append(source)
        }
        overlayInfo("SidebarIcons: watching \(sources.count) of \(Self.watched.count) folders")
        schedule()
    }

    /// Coalesces a burst of changes (Drive writes several files) into one restamp.
    private func schedule() {
        pending?.cancel()
        let work = DispatchWorkItem { Self.restamp() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settle, execute: work)
    }

    /// Re-inserts, in place, every Favourites row that carries a code. The insert
    /// goes right after the previous row (or before the first), with the same
    /// display name and the same code, so nothing moves and nothing is renamed.
    static func restamp() {
        guard let listRef = LSSharedFileListCreate(nil, kLSSharedFileListFavoriteItems.takeUnretainedValue(), nil) else {
            overlayInfo("SidebarIcons: no Favourites list"); return
        }
        let list = listRef.takeRetainedValue()
        guard let snapshot = LSSharedFileListCopySnapshot(list, nil)?.takeRetainedValue() as? [LSSharedFileListItem] else {
            overlayInfo("SidebarIcons: empty snapshot"); return
        }
        var done: [String] = []
        var refused: [String] = []
        for (i, item) in snapshot.enumerated() {
            guard let code = LSSharedFileListItemCopyProperty(item, key)?.takeRetainedValue() as? String, !code.isEmpty else { continue }
            let name = LSSharedFileListItemCopyDisplayName(item).takeRetainedValue() as String
            guard let url = LSSharedFileListItemCopyResolvedURL(
                item, UInt32(kLSSharedFileListNoUserInteraction | kLSSharedFileListDoNotMountVolumes), nil
            )?.takeRetainedValue() as URL? else { refused.append(name); continue }
            let after: LSSharedFileListItem = i == 0 ? kLSSharedFileListItemBeforeFirst.takeUnretainedValue() : snapshot[i - 1]
            let props = [key: code as CFString] as CFDictionary
            if LSSharedFileListInsertItemURL(list, after, name as CFString, nil, url as CFURL, props, nil) != nil {
                done.append("\(name)=\(code)")
            } else {
                refused.append(name)
            }
        }
        overlayInfo("SidebarIcons: restamped \(done.joined(separator: " "))\(refused.isEmpty ? "" : " REFUSED \(refused.joined(separator: " "))")")
    }
}
