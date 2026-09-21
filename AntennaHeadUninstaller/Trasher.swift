import Foundation
import AppKit

/// Moves things to the Trash.
protocol Trasher {
    func trash(_ url: URL) throws
    /// Trashes several items with one request, so Finder asks for authorization at most once.
    func trashAll(_ urls: [URL]) throws
    func trashContents(of folder: URL, except names: [String]) throws
}

extension Trasher {
    func trashAll(_ urls: [URL]) throws { for u in urls { try trash(u) } }
}

enum TrashError: LocalizedError, Equatable {
    case notPresent
    case notAuthorized
    /// macOS blocked access to another app's protected data (Containers / Group Containers).
    case needsDataAccess
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notPresent: "Not present (already removed)."
        case .notAuthorized:
            "macOS didn’t allow this app to control Finder. Open System Settings ▸ Privacy & Security ▸ Automation, turn on Finder under AntennaHead Uninstaller, then try again."
        case .needsDataAccess:
            "macOS blocked access to this protected folder. Give AntennaHead Uninstaller Full Disk Access (System Settings ▸ Privacy & Security ▸ Full Disk Access), quit and reopen it, then try again."
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

    func trashAll(_ urls: [URL]) throws {
        guard !urls.isEmpty else { return }
        let paths = urls.map { Self.literal($0.path) }.joined(separator: ", ")
        // Items that have vanished since the scan are skipped; anything else is a real error.
        try run("""
        tell application "Finder"
            set theItems to {}
            repeat with p in {\(paths)}
                try
                    set end of theItems to (POSIX file (contents of p) as alias)
                end try
            end repeat
            if (count of theItems) > 0 then delete theItems
        end tell
        """)
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
        default: throw TrashError.failed("\(message) [Finder error \(code)]")
        }
    }
}


/// Trashes in-process with FileManager. Unlike Finder scripting, this can move the system-managed
/// Containers / Group Containers folders (Finder answers those with error -5000), and the moves
/// still support Finder's Put Back. It needs macOS's consent to touch other apps' data, which
/// shows up as TrashError.needsDataAccess when it hasn't been given.
struct FileManagerTrasher: Trasher {
    var fileManager: FileManager = .default

    func trash(_ url: URL) throws {
        do {
            try fileManager.trashItem(at: url, resultingItemURL: nil)
        } catch {
            throw Self.translate(error)
        }
    }

    func trashContents(of folder: URL, except names: [String]) throws {
        let kids: [URL]
        do {
            kids = try fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [])
        } catch {
            throw Self.translate(error)
        }
        for kid in kids where !names.contains(kid.lastPathComponent) {
            try trash(kid)
        }
    }

    static func translate(_ error: Error) -> TrashError {
        let ns = error as NSError
        let posix = (ns.userInfo[NSUnderlyingErrorKey] as? NSError).flatMap { $0.domain == NSPOSIXErrorDomain ? Int32($0.code) : nil }
            ?? (ns.domain == NSPOSIXErrorDomain ? Int32(ns.code) : nil)
        if ns.domain == NSCocoaErrorDomain {
            switch ns.code {
            case NSFileNoSuchFileError, NSFileReadNoSuchFileError: return .notPresent
            case NSFileWriteNoPermissionError, NSFileReadNoPermissionError: return .needsDataAccess
            default: break
            }
        }
        if posix == EPERM || posix == EACCES { return .needsDataAccess }
        if posix == ENOENT { return .notPresent }
        return .failed("\(ns.localizedDescription) [\(ns.domain) \(ns.code)\(posix.map { ", errno \($0)" } ?? "")]")
    }
}
