import AppKit
import Foundation

/// Fixed strings Victor types over and over in front of a room — his Zoom room
/// and his email address — put one keystroke away (⌘⌃Z / ⌘⌃E). Typing either by
/// hand while sharing a screen is slow and, in the Zoom link's case, unreadable
/// enough that a typo isn't noticed until nobody can join.
enum PasteSnippets {
    static let zoomLink = "https://us02web.zoom.us/j/8206573499?pwd=L1RsS3l2NXc2SGJ5TitWd082NEhpQT09"
    static let email = "victorrentea@gmail.com"

    /// The company's invoicing block (⌘⌃R) — the three lines every client's
    /// finance department asks for, always in the same order and always
    /// verbatim: a mistyped VAT code bounces an invoice days later.
    static let companyDetails = """
        Victor Rentea Consulting SRL
        VAT Code (CUI): RO41987600
        Address: Dristorului 91-95, Ap. 1106, Bucharest 031538, Romania
        """

    /// Puts `text` on the pasteboard, pastes it into the focused app, then puts
    /// back whatever was on the pasteboard before — a shortcut that helps with
    /// one line must not cost you the clipboard you were carrying. The restore
    /// waits long enough for the receiving app to have read the paste; 0.05 s
    /// (what `repasteLast` uses) is enough for a native field but not for a
    /// slow Electron one, so this leans generous.
    static func paste(_ text: String) {
        let previous = ClipboardManager.read()
        ClipboardManager.write(text)
        Thread.sleep(forTimeInterval: 0.08)
        KeySimulator.cmdV()
        Thread.sleep(forTimeInterval: 0.35)
        ClipboardManager.write(previous)
    }
}
