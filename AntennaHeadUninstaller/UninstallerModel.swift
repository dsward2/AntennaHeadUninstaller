import Foundation
import AppKit
import Observation

@MainActor
@Observable
final class UninstallerModel {
    enum Phase: Equatable { case scanning, ready, running, finished }

    var items: [UninstallItem] = []
    var phase: Phase = .scanning
    var results: [ActionResult] = []
    var stillRunning: [String] = []
    var notice: String?

    private let catalog: Catalog

    init(catalog: Catalog = .live()) { self.catalog = catalog }

    var selectedCount: Int { items.filter(\.selected).count }
    var runningAppNames: [String] { AppQuitter.runningApps().compactMap(\.localizedName) }

    func scan() {
        phase = .scanning
        results = []; notice = nil
        // Keep a user-chosen text-to-speech folder across rescans.
        let ttsItems = items.filter { $0.kind == .textToSpeech }
        items = catalog.items() + ttsItems
        phase = .ready
        // Sizes are best-effort (protected folders can't be measured), computed off the main thread.
        Task.detached { [items] in
            var sizes: [String: Int64] = [:]
            for item in items { if let url = item.url, item.kind != .recordings, let n = Self.size(of: url) { sizes[item.id] = n } }
            await MainActor.run { [sizes] in
                for i in self.items.indices { self.items[i].sizeBytes = sizes[self.items[i].id] }
            }
        }
    }

    func toggle(_ id: String, to value: Bool) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].selected = value
    }

    func chooseTextToSpeechFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.message = "Choose the text-to-speech folder you selected in AntennaHead. Only the folder you pick is moved to the Trash."
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard Planner.isSafeToTrashAsTextToSpeechFolder(url, home: FileManager.default.homeDirectoryForCurrentUser) else {
            notice = "“\(url.lastPathComponent)” is too broad to remove safely. Choose the specific text-to-speech folder (at least two levels below your home folder)."
            return
        }
        items.removeAll { $0.kind == .textToSpeech }
        var item = UninstallItem(id: "tts", group: .optional, kind: .textToSpeech, title: "Text-to-speech folder",
                                 detail: url.path, url: url, selected: true)
        item.sizeBytes = Self.size(of: url)
        items.append(item)
        notice = nil
    }

    /// Quits the apps, then runs the plan.
    func run(forceQuit: Bool = false) async {
        phase = .running
        let remaining = await AppQuitter.quitAll(force: forceQuit)
        guard remaining.isEmpty else {
            stillRunning = remaining.compactMap(\.localizedName)
            phase = .ready
            return
        }
        stillRunning = []
        let plan = Planner.plan(items)
        results = Uninstaller().run(plan)
        // The apps are gone, so drop cached preferences that could otherwise be written back.
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/killall"); p.arguments = ["cfprefsd"]
        try? p.run(); p.waitUntilExit()
        phase = .finished
    }

    /// Plain-text report of the last run, for pasting into a bug report.
    var reportText: String {
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        var lines = ["AntennaHead Uninstaller \(version) — macOS \(os)", ""]
        for r in results {
            let path = r.url.map { "\n    path: \($0.path)" } ?? ""
            switch r.outcome {
            case .done: lines.append("OK       \(r.title)")
            case .skipped(let m): lines.append("SKIPPED  \(r.title) — \(m)\(path)")
            case .failed(let m): lines.append("FAILED   \(r.title) — \(m)\(path)")
            }
        }
        return lines.joined(separator: "\n")
    }

    func copyReport() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(reportText, forType: .string)
    }

    func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }

    func openTrash() {
        NSAppleScript(source: "tell application \"Finder\" to open trash\ntell application \"Finder\" to activate")?.executeAndReturnError(nil)
    }

    nonisolated static func size(of url: URL) -> Int64? {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return nil }
        if !isDir.boolValue { return (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? nil }
        guard let e = fm.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey], options: [], errorHandler: { _, _ in true })
        else { return nil }
        var total: Int64 = 0, sawAny = false
        for case let u as URL in e {
            sawAny = true
            total += Int64((try? u.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
        }
        return sawAny ? total : nil
    }
}
