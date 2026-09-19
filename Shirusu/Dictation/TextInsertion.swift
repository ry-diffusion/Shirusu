import AppKit
import ApplicationServices
import OSLog

/// Puts dictated text where the cursor already is.
///
/// This is the half of dictation that makes it dictation rather than a
/// transcript viewer: you hold the key in whatever app you were typing in, and
/// the words land there.
///
/// It goes through the pasteboard and a synthesised Command-V rather than
/// typing the text out one key at a time. Synthesised keystrokes have to be
/// mapped to a layout — the same event means a different letter on ABNT2 than
/// on US QWERTY, and dead keys for á and ç make it worse — while a paste is one
/// event whatever the keyboard is. It is also instant instead of a visible
/// crawl, and it survives autocomplete, which reacts to every keystroke.
enum TextInsertion {
    enum Failure: LocalizedError {
        case notTrusted

        var errorDescription: String? {
            switch self {
            case .notTrusted:
                return String(
                    localized: "Shirusu needs Accessibility permission to type where your cursor is.",
                    comment: "Shown when dictation cannot paste into the focused app")
            }
        }
    }

    private static let log = Logger(subsystem: "br.com.zesmoi.Shirusu", category: "dictation")

    /// Pastes `text` into whatever has keyboard focus.
    @MainActor
    static func insert(_ text: String) throws {
        guard !text.isEmpty else { return }
        guard AXIsProcessTrusted() else { throw Failure.notTrusted }

        let pasteboard = NSPasteboard.general
        // Everything on the pasteboard, not just the string: whoever owns it
        // may have put a file, an image and a string on there together, and
        // handing back only the string would quietly destroy the rest.
        let saved = pasteboard.pasteboardItems?.map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        paste()

        // The paste is asynchronous — it is an event another process has to
        // receive and act on — so the pasteboard has to stay ours until it has
        // been read. Restoring immediately puts the old contents back in time
        // for the paste to collect them instead.
        guard let saved, !saved.isEmpty else { return }
        Task {
            try? await Task.sleep(for: .milliseconds(600))
            pasteboard.clearContents()
            pasteboard.writeObjects(saved)
        }
    }

    private static func paste() {
        let source = CGEventSource(stateID: .combinedSessionState)
        // 0x09 is "v" by position, which is what a synthesised key code means:
        // the physical key, before any layout is applied.
        let key: CGKeyCode = 0x09
        guard
            let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
            let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        else {
            log.error("Could not synthesise the paste")
            return
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cgAnnotatedSessionEventTap)
        up.post(tap: .cgAnnotatedSessionEventTap)
    }
}
