import Foundation

/// A single step of an uninstall run.
enum UninstallAction: Equatable {
    case trash(URL, title: String)
    /// Trash everything inside `folder` except the named children (used to keep Recordings).
    case trashContents(of: URL, except: [String], title: String)
    case removeCertificate(title: String)

    var title: String {
        switch self {
        case .trash(_, let t), .trashContents(_, _, let t), .removeCertificate(let t): t
        }
    }
}

enum Planner {
    /// Turns the ticked items into actions. Apps first, then data, then keychain.
    ///
    /// The Recordings folder lives inside the App Group container, so:
    /// - container ticked, Recordings ticked → trash the whole container;
    /// - container ticked, Recordings not ticked → trash everything in the container *except* Recordings;
    /// - only Recordings ticked → trash just that folder.
    static func plan(_ items: [UninstallItem]) -> [UninstallAction] {
        let selected = items.filter(\.selected)
        var apps: [UninstallAction] = [], data: [UninstallAction] = [], keychain: [UninstallAction] = []

        let container = selected.first { $0.kind == .groupContainer }
        let recordings = selected.first { $0.kind == .recordings }

        for item in selected {
            switch item.kind {
            case .groupContainer:
                guard let url = item.url else { continue }
                if recordings != nil {
                    data.append(.trash(url, title: item.title + " — " + url.lastPathComponent + " (including Recordings)"))
                } else {
                    data.append(.trashContents(of: url, except: ["Recordings"], title: item.title + " — " + url.lastPathComponent + " (keeping Recordings)"))
                }
            case .recordings:
                if container == nil, let url = item.url { data.append(.trash(url, title: item.title + " — " + url.lastPathComponent)) }
            case .certificate:
                keychain.append(.removeCertificate(title: item.title))
            case .file, .textToSpeech:
                guard let url = item.url else { continue }
                let action = UninstallAction.trash(url, title: item.title + " — " + url.lastPathComponent)
                if url.pathExtension == "app" { apps.append(action) } else { data.append(action) }
            }
        }
        return apps + data + keychain
    }

    /// Folders the user may pick as their text-to-speech folder. Refuses anything broad
    /// enough that trashing it would take far more than AntennaHead's own files.
    static func isSafeToTrashAsTextToSpeechFolder(_ url: URL, home: URL) -> Bool {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        let homePath = home.standardizedFileURL.resolvingSymlinksInPath().path
        guard path.hasPrefix(homePath + "/") else { return false }          // inside the home folder only
        let relative = path.dropFirst(homePath.count + 1).split(separator: "/")
        guard relative.count >= 2 else { return false }                     // not ~/Documents, ~/Library, …
        if relative.first == "Library" && relative.count < 3 { return false }
        return true
    }
}
