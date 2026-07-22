import AppKit
import Foundation

/// A stack of images that flow through the clipboard, so a burst of screenshots
/// (⌃P) can be pasted one-by-one into a CLI (Claude Code / Copilot).
///
/// **Capture:** every image that lands on the clipboard is pushed onto the stack
/// (so repeated ⌃P builds it up). Copying **text** clears the stack — only a run
/// of *consecutive images* accumulates.
///
/// **Replay:** on ⌃V the paste is passed through untouched, then — after a slight
/// delay so the paste target reads the current clipboard first — the just-pasted
/// image is popped and the **next-older** image is placed on the clipboard, ready
/// for the next ⌃V. So `⌃V ⌃V ⌃V` pastes newest→oldest (LIFO, like a stack).
///
/// macOS has no clipboard-change event, so we poll `changeCount` (same pattern as
/// the audio poller). Our own writes — popping the next image onto the clipboard
/// — are tagged so the poller never re-captures them into a loop.
final class ClipboardStackManager {
    static let shared = ClipboardStackManager()

    private let queue = DispatchQueue(label: "ro.victorrentea.macos-addons.clip-stack", qos: .utility)
    private var timer: DispatchSourceTimer?

    /// PNG image data, oldest → newest. The last element is the top == what's on
    /// the clipboard while replaying.
    private var stack: [Data] = []
    private var lastChangeCount: Int = 0

    private let pollInterval: TimeInterval = 0.3
    /// Delay after ⌃V before swapping to the next image, so the paste target has
    /// already read the current clipboard.
    private let popDelay: TimeInterval = 0.35
    private let stackDir = URL(fileURLWithPath: "/tmp/victor-clip-stack")

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            self.lastChangeCount = PasteboardGate.sync { $0.changeCount }
            try? FileManager.default.createDirectory(at: self.stackDir, withIntermediateDirectories: true)
        }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + pollInterval, repeating: pollInterval)
        t.setEventHandler { [weak self] in self?.poll() }
        t.resume()
        timer = t
    }

    /// Called from the event tap on plain ⌃V. The event itself passes through
    /// (the terminal pastes); we just schedule the pop-to-next.
    func onCtrlVPaste() {
        queue.asyncAfter(deadline: .now() + popDelay) { [weak self] in self?.popAfterPaste() }
    }

    // MARK: - queue-only

    private func poll() {
        // All pasteboard touches happen in ONE gated critical section (see
        // PasteboardGate — polling here while the event tap read the clipboard
        // on ⌘V is what crashed the app 4× during the 2026-07-22 workshop).
        // The slow parts — PNG encoding, disk writes — run after, outside it.
        enum Change { case none, text, image(Data) }
        let change: Change = PasteboardGate.sync { pb in
            let cc = pb.changeCount
            guard cc != lastChangeCount else { return .none }   // no change (also skips our own writes)
            lastChangeCount = cc
            if pb.string(forType: .string) != nil { return .text }
            if let tiff = currentImageTIFF(pb) { return .image(tiff) }
            return .none
        }

        switch change {
        case .none:
            break
        case .text:
            // A text copy ends the image run.
            if !stack.isEmpty {
                stack.removeAll()
                clearDisk()
                NSLog("[ClipStack] cleared (text copied)")
            }
        case .image(let tiff):
            guard let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else { return }
            stack.append(png)
            persist()
            NSLog("[ClipStack] +image (\(stack.count) in stack)")
        }
    }

    private func popAfterPaste() {
        guard !stack.isEmpty else { return }
        stack.removeLast()          // the image just pasted
        persist()
        guard let next = stack.last else {
            NSLog("[ClipStack] stack exhausted")
            return
        }
        writeImage(next)
        NSLog("[ClipStack] popped → next image (\(stack.count) left)")
    }

    /// The clipboard image's TIFF bytes, or nil if there's no image. Must be
    /// called inside the PasteboardGate: `NSImage(pasteboard:)` is lazy, and
    /// `tiffRepresentation` is what actually pulls the bytes from the
    /// pasteboard daemon — both are pasteboard reads.
    private func currentImageTIFF(_ pb: NSPasteboard) -> Data? {
        guard pb.canReadObject(forClasses: [NSImage.self], options: nil),
              let img = NSImage(pasteboard: pb) else {
            return nil
        }
        return img.tiffRepresentation
    }

    private func writeImage(_ png: Data) {
        PasteboardGate.sync { pb in
            pb.clearContents()
            pb.setData(png, forType: .png)
            lastChangeCount = pb.changeCount   // tag our own write so poll() skips it
        }
    }

    // MARK: - disk mirror (Victor asked to keep the stack in a temp folder)

    private func persist() {
        clearDisk()
        for (i, d) in stack.enumerated() {
            try? d.write(to: stackDir.appendingPathComponent(String(format: "%03d.png", i)))
        }
    }

    private func clearDisk() {
        let fm = FileManager.default
        if let files = try? fm.contentsOfDirectory(at: stackDir, includingPropertiesForKeys: nil) {
            for f in files where f.pathExtension == "png" { try? fm.removeItem(at: f) }
        }
    }
}
