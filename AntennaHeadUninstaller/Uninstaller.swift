import Foundation
import AppKit

struct ActionResult: Identifiable, Equatable {
    enum Outcome: Equatable { case done, skipped(String), failed(String) }
    let id = UUID()
    let title: String
    let outcome: Outcome
}

/// Runs a plan. Continues past individual failures so one locked folder doesn't
/// leave the rest behind, and reports each step.
struct Uninstaller {
    var trasher: Trasher = FinderTrasher()
    var removeCertificates: () throws -> Int = { try CertificateRemover().removeAll() }

    func run(_ actions: [UninstallAction]) -> [ActionResult] {
        actions.map { action in
            do {
                switch action {
                case .trash(let url, _): try trasher.trash(url)
                case .trashContents(let folder, let except, _): try trasher.trashContents(of: folder, except: except)
                case .removeCertificate: _ = try removeCertificates()
                }
                return ActionResult(title: action.title, outcome: .done)
            } catch TrashError.notPresent {
                return ActionResult(title: action.title, outcome: .skipped("Not present"))
            } catch {
                return ActionResult(title: action.title, outcome: .failed(error.localizedDescription))
            }
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
