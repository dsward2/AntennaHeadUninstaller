import XCTest
@testable import AntennaHeadUninstaller

final class UninstallerTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/Users/tester")

    /// A catalog over a pretend file system containing exactly `present` paths.
    private func catalog(present: Set<String>, bundleIDs: [String: String] = [:], certificate: Bool = false) -> Catalog {
        Catalog(home: home,
                applicationDirectories: [URL(fileURLWithPath: "/Applications")],
                exists: { present.contains($0.path) },
                bundleIdentifier: { bundleIDs[$0.path] },
                certificatePresent: { certificate })
    }

    private let everything: Set<String> = [
        "/Applications/AntennaHead.app", "/Applications/ControlBooth.app",
        "/Users/tester/Library/Containers/com.dsward.AntennaHead",
        "/Users/tester/Library/Containers/com.dsward.ControlBooth",
        "/Users/tester/Library/Application Support/AntennaHead",
        "/Users/tester/Library/Application Support/ControlBooth",
        "/Users/tester/Library/Preferences/com.dsward.AntennaHead.plist",
        "/Users/tester/Library/Group Containers/group.com.dsward.antennahead",
        "/Users/tester/Library/Application Scripts/group.com.dsward.antennahead",
    ]

    // MARK: Catalog

    func testFindsOnlyWhatExists() {
        let items = catalog(present: ["/Users/tester/Library/Application Support/ControlBooth"]).items()
        XCTAssertEqual(items.map(\.id), ["com.dsward.ControlBooth:support"])
    }

    func testAppBundlesNeedTheRightBundleIdentifier() {
        let ids = ["/Applications/AntennaHead.app": "com.dsward.AntennaHead", "/Applications/ControlBooth.app": "com.example.Imposter"]
        let items = catalog(present: ["/Applications/AntennaHead.app", "/Applications/ControlBooth.app"], bundleIDs: ids).items()
        XCTAssertEqual(items.map(\.title), ["AntennaHead.app"])
    }

    func testEverythingDefaultsOnExceptRecordingsAndGqrx() {
        let ids = ["/Applications/AntennaHead.app": AppIDs.antennaHead, "/Applications/ControlBooth.app": AppIDs.controlBooth,
                   "/Applications/Gqrx-for-AntennaHead.app": AppIDs.gqrxForAntennaHead]
        let items = catalog(present: everything.union(["/Applications/Gqrx-for-AntennaHead.app"]), bundleIDs: ids, certificate: true).items()
        for item in items {
            switch item.kind {
            case .recordings: XCTAssertFalse(item.selected, "recordings must be opt-in")
            case .file where item.title.hasPrefix("Gqrx"): XCTAssertFalse(item.selected, "Gqrx must be opt-in")
            default: XCTAssertTrue(item.selected, item.title)
            }
        }
        XCTAssertTrue(items.contains { $0.kind == .certificate })
    }

    func testRecordingsOfferedOnlyWithTheGroupContainer() {
        XCTAssertFalse(catalog(present: []).items().contains { $0.kind == .recordings })
        XCTAssertTrue(catalog(present: everything).items().contains { $0.kind == .recordings })
    }

    func testGqrxNeverOffersItsSharedConfigFolder() {
        let ids = ["/Applications/Gqrx-for-AntennaHead.app": AppIDs.gqrxForAntennaHead]
        let items = catalog(present: ["/Applications/Gqrx-for-AntennaHead.app", "/Users/tester/.config/gqrx"], bundleIDs: ids).items()
        XCTAssertEqual(items.count, 1)
        XCTAssertFalse(items.contains { ($0.url?.path ?? "").contains(".config") })
    }

    func testOriginalGqrxIsNeverOffered() {
        let ids = ["/Applications/Gqrx-for-AntennaHead.app": "dk.gqrx.gqrx"]   // wrong bundle id
        XCTAssertTrue(catalog(present: ["/Applications/Gqrx-for-AntennaHead.app"], bundleIDs: ids).items().isEmpty)
    }

    // MARK: Plan

    private func plan(recordings: Bool, container: Bool = true) -> [UninstallAction] {
        var items = catalog(present: everything).items()
        for i in items.indices {
            if items[i].kind == .recordings { items[i].selected = recordings }
            if items[i].kind == .groupContainer { items[i].selected = container }
        }
        return Planner.plan(items)
    }

    func testKeepingRecordingsTrashesTheContainerContentsExceptRecordings() {
        let actions = plan(recordings: false)
        XCTAssertTrue(actions.contains { if case .trashContents(_, let keep, _) = $0 { keep == ["Recordings"] } else { false } })
        XCTAssertFalse(actions.contains { if case .trash(let u, _) = $0 { u.path.contains("/Group Containers/") && u.lastPathComponent == "group.com.dsward.antennahead" } else { false } })
    }

    func testDeletingRecordingsTrashesTheWholeContainerOnce() {
        let actions = plan(recordings: true)
        let whole = actions.filter { if case .trash(let u, _) = $0 { u.path.contains("/Group Containers/") && u.lastPathComponent == "group.com.dsward.antennahead" } else { false } }
        XCTAssertEqual(whole.count, 1)
        XCTAssertFalse(actions.contains { if case .trashContents = $0 { true } else { false } })
        XCTAssertFalse(actions.contains { if case .trash(let u, _) = $0 { u.lastPathComponent == "Recordings" } else { false } })
    }

    func testRecordingsAloneTrashesJustThatFolder() {
        let actions = plan(recordings: true, container: false)
        XCTAssertTrue(actions.contains { if case .trash(let u, _) = $0 { u.lastPathComponent == "Recordings" } else { false } })
    }

    func testAppsComeFirstAndTheCertificateLast() {
        var items = catalog(present: everything, bundleIDs: ["/Applications/AntennaHead.app": AppIDs.antennaHead], certificate: true).items()
        items.append(UninstallItem(id: "tts", group: .optional, kind: .textToSpeech, title: "TTS", detail: "", url: home.appendingPathComponent("Documents/tts"), selected: true))
        let actions = Planner.plan(items)
        if case .trash(let first, _) = actions.first { XCTAssertEqual(first.pathExtension, "app") } else { XCTFail() }
        if case .removeCertificate = actions.last { } else { XCTFail("certificate should be last") }
    }

    func testUntickedItemsProduceNoActions() {
        var items = catalog(present: everything).items()
        for i in items.indices { items[i].selected = false }
        XCTAssertTrue(Planner.plan(items).isEmpty)
    }

    // MARK: Text-to-speech folder safety

    func testTextToSpeechFolderSafety() {
        func ok(_ p: String) -> Bool { Planner.isSafeToTrashAsTextToSpeechFolder(URL(fileURLWithPath: p), home: home) }
        XCTAssertTrue(ok("/Users/tester/Documents/AntennaHead-text-to-speech"))
        XCTAssertTrue(ok("/Users/tester/Documents/Work/tts"))
        XCTAssertFalse(ok("/Users/tester"), "the home folder itself")
        XCTAssertFalse(ok("/Users/tester/Documents"), "a top-level folder in home")
        XCTAssertFalse(ok("/Users/tester/Library"))
        XCTAssertFalse(ok("/Users/tester/Library/Application Support"))
        XCTAssertFalse(ok("/Users"))
        XCTAssertFalse(ok("/Applications/Something"))
        XCTAssertFalse(ok("/Users/tester/../other/tts"))
    }

    // MARK: Running a plan

    private final class SpyTrasher: Trasher {
        var trashed: [URL] = []; var contents: [(URL, [String])] = []
        var batches: [[URL]] = []; var failBatch = false
        var failOn: String?; var missing: String?
        func trashAll(_ urls: [URL]) throws {
            batches.append(urls)
            if failBatch { throw TrashError.failed("batch refused") }
            for u in urls { try trash(u) }
        }
        func trash(_ url: URL) throws {
            if url.lastPathComponent == missing { throw TrashError.notPresent }
            if url.lastPathComponent == failOn { throw TrashError.failed("locked") }
            trashed.append(url)
        }
        func trashContents(of folder: URL, except names: [String]) throws { contents.append((folder, names)) }
    }

    func testRunContinuesPastFailuresAndReportsEach() {
        let spy = SpyTrasher(); spy.failOn = "b"; spy.missing = "c"
        let u = Uninstaller(trasher: spy, removeCertificates: { 1 }, exists: { _ in true })
        let results = u.run([.trash(URL(fileURLWithPath: "/x/a"), title: "a"), .trash(URL(fileURLWithPath: "/x/b"), title: "b"),
                             .trash(URL(fileURLWithPath: "/x/c"), title: "c"), .removeCertificate(title: "cert")])
        XCTAssertEqual(results.map(\.outcome), [.done, .failed("locked"), .skipped("Not present"), .done])
        XCTAssertEqual(Set(spy.trashed.map(\.lastPathComponent)), ["a"])
    }

    func testConsecutiveTrashesGoToFinderAsOneRequest() {
        let spy = SpyTrasher()
        let u = Uninstaller(trasher: spy, removeCertificates: { 1 })
        let r = u.run([.trash(URL(fileURLWithPath: "/x/a"), title: "a"), .trash(URL(fileURLWithPath: "/x/b"), title: "b"),
                       .trash(URL(fileURLWithPath: "/x/c"), title: "c")])
        XCTAssertEqual(spy.batches.count, 1, "one Finder request, so one authorization prompt")
        XCTAssertEqual(spy.batches[0].map(\.lastPathComponent), ["a", "b", "c"])
        XCTAssertEqual(r.map(\.outcome), [.done, .done, .done])
    }

    func testFailedBatchFallsBackToPerItemSoTheReportNamesTheCulprit() {
        let spy = SpyTrasher(); spy.failBatch = true; spy.failOn = "b"
        let u = Uninstaller(trasher: spy, removeCertificates: { 1 }, exists: { _ in true })
        let r = u.run([.trash(URL(fileURLWithPath: "/x/a"), title: "a"), .trash(URL(fileURLWithPath: "/x/b"), title: "b")])
        XCTAssertEqual(r.map(\.outcome), [.done, .failed("locked")])
        XCTAssertEqual(r[1].url?.path, "/x/b", "failures carry the path for the report")
    }

    func testItemsAlreadyMovedByAFailedBatchAreReportedDoneNotMissing() {
        let spy = SpyTrasher(); spy.failBatch = true
        let gone: Set<String> = ["a"]
        let u = Uninstaller(trasher: spy, removeCertificates: { 1 }, exists: { !gone.contains($0.lastPathComponent) })
        let r = u.run([.trash(URL(fileURLWithPath: "/x/a"), title: "a"), .trash(URL(fileURLWithPath: "/x/b"), title: "b")])
        XCTAssertEqual(r.map(\.outcome), [.done, .done])
        XCTAssertEqual(spy.trashed.map(\.lastPathComponent), ["b"], "only the item still in place is retried")
    }

    func testGroupContainerResultNamesTheFolder() {
        let actions = plan(recordings: false)
        let titles = actions.map(\.title)
        XCTAssertTrue(titles.contains { $0.contains("group.com.dsward.antennahead") && $0.contains("keeping Recordings") }, "\(titles)")
    }

    func testAppleScriptLiteralEscaping() {
        XCTAssertEqual(FinderTrasher.literal(#"/a/b "c"\d"#), #""/a/b \"c\"\\d""#)
    }
}
