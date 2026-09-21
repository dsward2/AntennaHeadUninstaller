import Foundation
import AppKit

/// Moves things to the Trash.
protocol Trasher {
    func trash(_ url: URL) throws
    func trashContents(of folder: URL, except names: [String]) throws
}

enum TrashError: LocalizedError {
    case notPresent
    case notAuthorized
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notPresent: "Not present (already removed)."
        case .notAuthorized:
            "macOS didn’t allow this app to control Finder. Open System Settings ▸ Privacy & Security ▸ Automation, turn on Finder under AntennaHead Uninstaller, then try again."
        case .failed(let m): m
        }
    }
}

/// Trashes through Finder. Finder is the only route that both records the original
/// location (so Finder's Put Back works) and is allowed to remove another app's
/// protected folders (Containers, Group Containers) without Full Disk Access.
struct FinderTrasher: Trasher {
    func trash(_ url: URL) throws {
        try run("tell application \"Finder\" to delete (POSIX file \(Self.literal(url.path)) as alias)")
    }

    func trashContents(of folder: URL, except names: [String]) throws {
        let keep = names.map(Self.literal).joined(separator: ", ")
        try run("""
        tell application "Finder"
            set theFolder to (POSIX file \(Self.literal(folder.path)) as alias)
            set kids to (every item of theFolder whose name is not in {\(keep)})
            if (count of kids) > 0 then delete kids
        end tell
        """)
    }

    /// A string literal for AppleScript source.
    static func literal(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private func run(_ source: String) throws {
        var errorInfo: NSDictionary?
        guard let script = NSAppleScript(source: source) else { throw TrashError.failed("Couldn’t build the Finder request.") }
        script.executeAndReturnError(&errorInfo)
        guard let info = errorInfo else { return }
        let code = info[NSAppleScript.errorNumber] as? Int ?? 0
        let message = info[NSAppleScript.errorMessage] as? String ?? "Unknown error"
        switch code {
        case -1743: throw TrashError.notAuthorized
        case -1728, -43, -10006: throw TrashError.notPresent   // can't get / file not found
        default: throw TrashError.failed("\(message) (\(code))")
        }
    }
}
