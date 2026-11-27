import AppKit
import Carbon.HIToolbox
import Foundation

/// Inserts text at the cursor of the frontmost app: puts it on the
/// clipboard, synthesizes ⌘V, then restores the previous clipboard.
enum TextInserter {

    typealias SavedClipboard = [[String: Data]]

    static func insert(_ text: String) {
        let saved = saveClipboard()

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        sendKeystroke(kVK_ANSI_V, flags: .maskCommand)

        // Restore the user's clipboard once the paste has been consumed.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            restoreClipboard(saved)
        }
    }

    static func saveClipboard() -> SavedClipboard {
        NSPasteboard.general.pasteboardItems?.compactMap { item -> [String: Data]? in
            var copy: [String: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy[type.rawValue] = data
                }
            }
            return copy.isEmpty ? nil : copy
        } ?? []
    }

    static func restoreClipboard(_ saved: SavedClipboard) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let items = saved.map { entry -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in entry {
                item.setData(data, forType: NSPasteboard.PasteboardType(type))
            }
            return item
        }
        if !items.isEmpty {
            pasteboard.writeObjects(items)
        }
    }

    static func sendKeystroke(_ key: Int, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let keyDown = CGEvent(
            keyboardEventSource: source, virtualKey: CGKeyCode(key), keyDown: true)
        let keyUp = CGEvent(
            keyboardEventSource: source, virtualKey: CGKeyCode(key), keyDown: false)
        keyDown?.flags = flags
        keyUp?.flags = flags
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }
}
