import Foundation

/// One connected display as the arrangement policy sees it — pure data, no Quartz.
struct DisplayFacts: Equatable {
    let id: UInt32
    let isBuiltin: Bool
    /// `NSScreen.localizedName`, or the name recovered from `DisplayNameCache`.
    /// **`nil` means the display is anonymous** — the case that used to break
    /// role resolution (see `DisplayRolePolicy`).
    let name: String?
    /// True when Quartz reports the display inside a mirror set. An *unnamed*
    /// member of one is necessarily a slave (the master keeps its `NSScreen`).
    let isMirrored: Bool
}

/// Pure role resolution for `DisplayArrangementManager`: which connected display
/// is the Retina, which is the ASUS travel monitor, which is the venue projector
/// / room TV, and which ones we cannot yet tell apart.
///
/// Split out of the manager because the failure it exists to prevent has nothing
/// to do with Quartz and everything to do with **names**: a display that macOS
/// has swept into a mirror set has **no `NSScreen`, therefore no
/// `localizedName`**. Until 2026-08-28 the manager classified any unnamed
/// external as "the projector" and kept only the *first* one — so when the room
/// TV's hot-plug pulled the ASUS into the mirror set too (routine with HDMI + a
/// USB-C travel monitor), the ASUS was either mistaken for the projector or
/// dropped on the floor entirely. The applied layout then came out as "Retina
/// main, ASUS left mirroring" instead of "ASUS primary, TV mirroring the
/// Retina" — the 2026-08-27 room-TV incident, fixed by hand on the spot.
///
/// Anonymous displays are therefore reported separately (`unidentified`): the
/// caller breaks the mirror set, every display gets its name back, and asks
/// again. Extra externals are reported too (`extraExternals`) instead of being
/// silently discarded, so nothing is ever left mirroring by omission.
enum DisplayRolePolicy {
    struct Resolution: Equatable {
        var retina: UInt32?
        var asus: UInt32?
        /// The venue projector / room TV: the first *named* unknown external.
        var projector: UInt32?
        /// Victor's own named externals (home monitors) — never mirrored, never moved.
        var knownExternals: [UInt32] = []
        /// Unknown externals beyond the projector. Un-mirrored and parked, never left alone.
        var extraExternals: [UInt32] = []
        /// Anonymous mirror slaves — unclassifiable until the mirror set is broken.
        var unidentified: [UInt32] = []

        var hasKnownExternal: Bool { !knownExternals.isEmpty }
        /// The caller must break every mirror and re-resolve before applying.
        var needsUnmirrorProbe: Bool { !unidentified.isEmpty }
    }

    /// - Parameters:
    ///   - displays: every *online* display, in Quartz order.
    ///   - isKnown: does this `localizedName` belong to one of Victor's own displays?
    static func resolve(_ displays: [DisplayFacts], isKnown: (String) -> Bool) -> Resolution {
        var r = Resolution()
        for d in displays {
            if d.isBuiltin {
                if r.retina == nil { r.retina = d.id }
                continue
            }
            guard let name = d.name else {
                // Anonymous. A mirror slave has no NSScreen and no name, so it
                // could be anything — including the ASUS. Never guess.
                if d.isMirrored {
                    r.unidentified.append(d.id)
                } else if r.projector == nil {
                    r.projector = d.id          // nameless yet extended: a projector
                } else {
                    r.extraExternals.append(d.id)
                }
                continue
            }
            if name.uppercased().contains("ASUS") {
                if r.asus == nil { r.asus = d.id } else { r.extraExternals.append(d.id) }
            } else if isKnown(name) {
                r.knownExternals.append(d.id)
            } else if r.projector == nil {
                r.projector = d.id
            } else {
                r.extraExternals.append(d.id)
            }
        }
        return r
    }
}
