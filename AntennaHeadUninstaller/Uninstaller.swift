import Foundation
import AppKit

struct ActionResult: Identifiable, Equatable {
    enum Outcome: Equatable { case done, skipped(String), failed(String) }
    let id = UUID()
    let title: String
    /// The file or folder this step was about, when it has one.
    var url: URL? = nil
    let outcome: Outcome
}

/// Runs a plan. Continues past individual failures so one locked folder doesn't
/// leave the rest behind, and reports each step.
struct Uninstaller {
    /// For ordinary items (Finder can also ask for an administrator password when needed).
    var trasher: Trasher = FinderTrasher()
    /// For the system-managed Containers / Group Containers folders, which Finder won't move.
    var managedTrasher: Trasher = FileManagerTrasher()
    var removeCertificates: () throws -> Int = { try CertificateRemover().removeAll() }
    /// Used after a failed batch to tell items Finder already moved from ones still in place.
    var exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }

    func run(_ actions: [UninstallAction]) -> [ActionResult] {
        var results: [ActionResult] = []
        var index = 0
        while index < actions.count {
            // Consecutive plain trashes go to Finder as one request, so a password prompt
            // (for root-owned items, say) appears once instead of once per file.
            var batch: [(URL, String)] = []
            while index < actions.count, case .trash(let url, let title) = actions[index], !Planner.isSystemManaged(url) {
                batch.append((url, title)); index += 1
            }
            if !batch.isEmpty {
                results += runBatch(batch)
                continue
            }
            results.append(runOne(actions[index]))
            index += 1
        }
        return results
    }

    /// One Finder request for the whole batch; if it fails, retry item by item so the
    /// report says exactly which ones couldn't be moved and why.
    private func runBatch(_ batch: [(URL, String)]) -> [ActionResult] {
        if batch.count > 1, (try? trasher.trashAll(batch.map(\.0))) != nil {
            return batch.map { ActionResult(title: $0.1, url: $0.0, outcome: .done) }
        }
        return batch.map { url, title in
            // Finder may have moved some items before the batch as a whole failed.
            exists(url) ? runOne(.trash(url, title: title)) : ActionResult(title: title, url: url, outcome: .done)
        }
    }

    private func runOne(_ action: UninstallAction) -> ActionResult {
        let url: URL?
        switch action {
        case .trash(let u, _), .trashContents(let u, _, _): url = u
        case .removeCertificate: url = nil
        }
        do {
            switch action {
            case .trash(let u, _): try (Planner.isSystemManaged(u) ? managedTrasher : trasher).trash(u)
            case .trashContents(let folder, let except, _):
                try (Planner.isSystemManaged(folder) ? managedTrasher : trasher).trashContents(of: folder, except: except)
            case .removeCertificate: _ = try removeCertificates()
            }
            return ActionResult(title: action.title, url: url, outcome: .done)
        } catch TrashError.notPresent {
            return ActionResult(title: action.title, url: url, outcome: .skipped("Not present"))
        } catch {
            return ActionResult(title: action.title, url: url, outcome: .failed(error.localizedDescription))
        }
    }
}

/// Quits AntennaHead and ControlBooth (and so their helper processes) before their files are removed.
enum AppQuitter {
    static let bundleIDs = [AppIDs.antennaHead, AppIDs.controlBooth, AppIDs.gqrxForAntennaHead]

    static func runningApps() -> [NSRunningApplication] {
        bundleIDs.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0) }
    }

    /// Asks each to quit and waits up to `timeout` seconds. Returns the apps still running.
    @MainActor
    static func quitAll(timeout: TimeInterval = 15, force: Bool = false) async -> [NSRunningApplication] {
        let apps = runningApps()
        for app in apps {
            if force { _ = app.forceTerminate() } else { _ = app.terminate() }
        }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, apps.contains(where: { !$0.isTerminated }) {
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return apps.filter { !$0.isTerminated }
    }
}
