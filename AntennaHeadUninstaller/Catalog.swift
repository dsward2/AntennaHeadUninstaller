import Foundation

/// Identifiers of everything the AntennaHead family installs or leaves behind.
enum AppIDs {
    static let antennaHead = "com.dsward.AntennaHead"
    static let controlBooth = "com.dsward.ControlBooth"
    static let appGroup = "group.com.dsward.antennahead"
    static let gqrxForAntennaHead = "com.dsward.gqrx-for-antennahead"
    /// Label of the TLS certificate AntennaHead generates for its HTTPS server.
    static let certificateName = "AntennaHead Self-Signed"
}

/// One thing the uninstaller can remove.
struct UninstallItem: Identifiable, Equatable {
    enum Group: String, CaseIterable {
        case antennaHead = "AntennaHead"
        case controlBooth = "ControlBooth"
        case shared = "Shared by both apps"
        case optional = "Optional"
    }

    enum Kind: Equatable {
        case file                 // a file or folder that goes to the Trash
        case groupContainer       // the shared App Group container (recordings live inside it)
        case recordings           // <group container>/Recordings
        case textToSpeech         // folder the user picked in AntennaHead
        case certificate          // keychain certificate; not a file, can't be trashed
    }

    let id: String
    let group: Group
    let kind: Kind
    let title: String
    let detail: String
    /// nil only for the keychain certificate.
    let url: URL?
    var selected: Bool
    var sizeBytes: Int64? = nil
}

/// Builds the list of items present on this Mac. Pure apart from the injected
/// probes, so it can be tested without touching the real file system.
struct Catalog {
    var home: URL
    var applicationDirectories: [URL]
    var exists: (URL) -> Bool
    var bundleIdentifier: (URL) -> String?
    var certificatePresent: () -> Bool

    static func live(fm: FileManager = .default) -> Catalog {
        Catalog(home: fm.homeDirectoryForCurrentUser,
                applicationDirectories: [URL(fileURLWithPath: "/Applications"),
                                         fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications")],
                exists: { (try? $0.checkResourceIsReachable()) == true || fm.fileExists(atPath: $0.path) },
                bundleIdentifier: { Bundle(url: $0)?.bundleIdentifier },
                certificatePresent: { CertificateRemover().certificateCount() > 0 })
    }

    var library: URL { home.appendingPathComponent("Library", isDirectory: true) }
    var groupContainer: URL { library.appendingPathComponent("Group Containers/\(AppIDs.appGroup)", isDirectory: true) }

    func items() -> [UninstallItem] {
        var out: [UninstallItem] = []

        func add(_ id: String, _ group: UninstallItem.Group, _ title: String, _ detail: String, _ url: URL,
                 kind: UninstallItem.Kind = .file, selected: Bool = true) {
            guard exists(url) else { return }
            out.append(UninstallItem(id: id, group: group, kind: kind, title: title, detail: detail, url: url, selected: selected))
        }

        // App bundles, in /Applications or ~/Applications.
        for (name, bundleID, group) in [("AntennaHead", AppIDs.antennaHead, UninstallItem.Group.antennaHead),
                                        ("ControlBooth", AppIDs.controlBooth, .controlBooth)] {
            for dir in applicationDirectories {
                let app = dir.appendingPathComponent("\(name).app")
                if exists(app), bundleIdentifier(app) == bundleID {
                    add("app:\(app.path)", group, "\(name).app", "The application (\(dir.path))", app)
                }
            }
        }

        // Per-app data.
        func appData(_ name: String, _ bundleID: String, _ group: UninstallItem.Group) {
            let lib = library
            add("\(bundleID):container", group, "App container", "Database, settings and identity files (sandbox)", lib.appendingPathComponent("Containers/\(bundleID)"))
            add("\(bundleID):support", group, "Application Support", "Database and identity files", lib.appendingPathComponent("Application Support/\(name)"))
            add("\(bundleID):caches", group, "Caches", "Cached data", lib.appendingPathComponent("Caches/\(bundleID)"))
            add("\(bundleID):webkit", group, "WebKit data", "Web view storage", lib.appendingPathComponent("WebKit/\(bundleID)"))
            add("\(bundleID):http", group, "HTTP storage", "Cookies and URL cache", lib.appendingPathComponent("HTTPStorages/\(bundleID)"))
            add("\(bundleID):prefs", group, "Preferences", "\(bundleID).plist", lib.appendingPathComponent("Preferences/\(bundleID).plist"))
            add("\(bundleID):scripts", group, "Application Scripts", "Sandbox script folder", lib.appendingPathComponent("Application Scripts/\(bundleID)"))
            add("\(bundleID):state", group, "Saved window state", "Window positions", lib.appendingPathComponent("Saved Application State/\(bundleID).savedState"))
            add("\(bundleID):logs", group, "Logs", "Log files", lib.appendingPathComponent("Logs/\(name)"))
        }
        appData("AntennaHead", AppIDs.antennaHead, .antennaHead)
        appData("ControlBooth", AppIDs.controlBooth, .controlBooth)

        // Shared by both apps.
        add("groupContainer", .shared, "App Group container", "Shared data (\(AppIDs.appGroup)). Your recordings are kept unless you also tick Recordings below.",
            groupContainer, kind: .groupContainer)
        add("groupScripts", .shared, "Application Scripts (group)", AppIDs.appGroup,
            library.appendingPathComponent("Application Scripts/\(AppIDs.appGroup)"))

        // Optional. The Recordings folder sits inside the protected group container, so its
        // existence can't be probed directly; it is offered whenever the container exists.
        if exists(groupContainer) {
            out.append(UninstallItem(id: "recordings", group: .optional, kind: .recordings, title: "Recordings",
                                     detail: "Audio recordings saved by AntennaHead and ControlBooth (Group Container ▸ Recordings)",
                                     url: groupContainer.appendingPathComponent("Recordings", isDirectory: true), selected: false))
        }
        if certificatePresent() {
            out.append(UninstallItem(id: "certificate", group: .optional, kind: .certificate,
                                     title: "Self-signed TLS certificate",
                                     detail: "“\(AppIDs.certificateName)” in your login keychain. This can’t be restored with Put Back.",
                                     url: nil, selected: true))
        }
        for dir in applicationDirectories {
            let gqrx = dir.appendingPathComponent("Gqrx-for-AntennaHead.app")
            if exists(gqrx), bundleIdentifier(gqrx) == AppIDs.gqrxForAntennaHead {
                out.append(UninstallItem(id: "gqrx:\(gqrx.path)", group: .optional, kind: .file, title: "Gqrx for AntennaHead.app",
                                         detail: "Only this app. Its settings in ~/.config/gqrx are shared with the original Gqrx and are never touched.",
                                         url: gqrx, selected: false))
            }
        }
        return out
    }
}
