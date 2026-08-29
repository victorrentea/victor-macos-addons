import Foundation

/// 🎧 The focus playlist (⌘⌃F) — YouTube's radio mix seeded from one track,
/// opened on a **random** entry so the same key doesn't start the same song
/// every single time.
///
/// The random start is the whole feature, and it has to be done by us: YouTube
/// ignores `&index=` on an `RD…` radio list (verified — `watch?list=RD…&index=12`
/// resolves to the same video as `index=1`) and ignores `&shuffle=1` entirely,
/// while a `v=` in the URL always wins. So the only lever that moves is `v`, and
/// to move it we need to know what is *in* the mix: the watch page ships the
/// whole panel inline, one `playlistPanelVideoRenderer` per track, which is what
/// `videoIds(inMixPage:)` reads. Picking one of those and keeping `list=RD<seed>`
/// leaves the playlist itself untouched — it is still the focus mix, just entered
/// at a different door.
enum FocusPlaylist {
    /// The track the mix is seeded from — `RD<id>` *is* the playlist's identity,
    /// so this constant, not the list id, is the thing to change to move the
    /// shortcut to different music.
    static let seedVideoId = "LEEx_UkHmBU"

    static var listId: String { "RD" + seedVideoId }

    /// The playlist as Victor gave it — the fallback whenever the mix can't be
    /// read (offline, YouTube changed its markup, a consent wall): a shortcut
    /// that opens the right music on the first track beats one that opens
    /// nothing at all.
    static var seedUrl: String { watchUrl(videoId: seedVideoId) }

    static func watchUrl(videoId: String) -> String {
        "https://www.youtube.com/watch?v=\(videoId)&list=\(listId)&start_radio=1"
    }

    /// The mix's tracks, in panel order, deduplicated. Parsed by scanning rather
    /// than with a regex over the whole page: the watch HTML is ~1.3 MB and the
    /// ids sit in a known spot a few hundred bytes past each renderer marker.
    static func videoIds(inMixPage html: String) -> [String] {
        let marker = "\"playlistPanelVideoRenderer\":{"
        let idKey = "\"videoId\":\""
        var ids: [String] = []
        var seen = Set<String>()
        var cursor = html.startIndex
        while let markerRange = html.range(of: marker, range: cursor..<html.endIndex) {
            cursor = markerRange.upperBound
            // Stay inside this renderer's own JSON: an id further away belongs to
            // the next track, and a truncated/odd page must not smear them.
            let window = html.index(cursor, offsetBy: 3000, limitedBy: html.endIndex) ?? html.endIndex
            guard let idRange = html.range(of: idKey, range: cursor..<window) else { continue }
            let rest = html[idRange.upperBound..<window]
            guard let closing = rest.firstIndex(of: "\"") else { continue }
            let id = String(rest[rest.startIndex..<closing])
            guard isValidVideoId(id), seen.insert(id).inserted else { continue }
            ids.append(id)
        }
        return ids
    }

    /// YouTube ids are 11 characters of the URL-safe base64 alphabet. Anything
    /// else in that slot means the markup moved, and we'd rather fall back to the
    /// seed than build a watch URL out of whatever was there.
    static func isValidVideoId(_ id: String) -> Bool {
        id.count == 11 && id.allSatisfy { $0.isLetter && $0.isASCII || $0.isNumber && $0.isASCII || $0 == "-" || $0 == "_" }
    }

    /// A watch URL for a random track of the mix page, falling back to the seed
    /// when the page yields nothing. `pick` is injected so the choice is testable.
    static func randomWatchUrl(fromMixPage html: String,
                               pick: ([String]) -> String? = { $0.randomElement() }) -> String {
        guard let id = pick(videoIds(inMixPage: html)) else { return seedUrl }
        return watchUrl(videoId: id)
    }

    /// Fetch the mix page and hand back the URL to open. Always calls back — with
    /// `seedUrl` on any failure — so the caller has exactly one path.
    ///
    /// The request carries a desktop browser User-Agent because YouTube serves a
    /// different, panel-less page to anything that doesn't look like a browser,
    /// and it goes out on an **ephemeral** session: this is a read of a public
    /// page, and it must not touch, or be shaped by, any cookie jar.
    static func resolveRandomUrl(timeout: TimeInterval = 4.0,
                                 completion: @escaping (String) -> Void) {
        guard let url = URL(string: seedUrl) else { completion(seedUrl); return }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                         + "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36",
                         forHTTPHeaderField: "User-Agent")
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        let session = URLSession(configuration: config)
        session.dataTask(with: request) { data, _, _ in
            guard let data, let html = String(data: data, encoding: .utf8) else {
                completion(seedUrl); return
            }
            completion(randomWatchUrl(fromMixPage: html))
        }.resume()
    }
}
