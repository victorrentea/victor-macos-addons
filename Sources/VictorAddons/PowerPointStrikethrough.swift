import Foundation

/// ⌘⇧X in PowerPoint — toggle strikethrough on whatever is selected.
///
/// Driven through PowerPoint's own AppleScript dictionary (`strike type` on the
/// selection's font), NOT by clicking the ribbon's Strikethrough checkbox. The
/// ribbon route would first have to switch the ribbon to the Home tab — PowerPoint
/// swings it to "Shape Format" the moment a shape is selected — and that tab
/// change is visible to the room mid-talk. The scripting route touches no UI.
///
/// Two selection shapes have to be handled: a text range (caret inside a text
/// box, the usual case) and a shape range (the whole box selected, in which case
/// the strike applies to all of its text). `text range of selection` only answers
/// for the first, so the second is reached through the shape's text frame.
enum PowerPointStrikethrough {

    static func toggle() {
        let script = """
        tell application "Microsoft PowerPoint"
            set theWindow to document window 1
            set sel to selection of theWindow
            try
                set theRange to text range of sel
            on error
                set theRange to text range of text frame of shape range of sel
            end try
            set theFont to font of theRange
            if (strike type of theFont) is single strike then
                set strike type of theFont to no strike
            else
                set strike type of theFont to single strike
            end if
        end tell
        """
        _ = AppleScriptRunner.run(script)
    }
}
