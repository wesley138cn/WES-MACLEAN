import Foundation
import XCTest
@testable import Lime

final class CleanupEngineTests: XCTestCase {
    private func fixture() throws -> (root: URL, apps: URL, library: URL, app: URL, cache: URL) {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("LimeCleanupTests-\(UUID().uuidString)")
        let apps = root.appendingPathComponent("Applications")
        let library = root.appendingPathComponent("Library")
        let app = apps.appendingPathComponent("Fixture.app")
        let cache = library.appendingPathComponent("Caches/com.example.fixture")
        try fm.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try fm.createDirectory(at: cache, withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": "com.example.fixture", "CFBundleName": "Fixture", "CFBundlePackageType": "APPL"]
        let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try plist.write(to: app.appendingPathComponent("Contents/Info.plist"))
        try Data(repeating: 7, count: 1_024).write(to: cache.appendingPathComponent("cache.data"))
        return (root, apps, library, app, cache)
    }

    private func engine(_ f: (root: URL, apps: URL, library: URL, app: URL, cache: URL),
                        running: @escaping () -> Set<String> = { [] }) -> CleanupEngine {
        let trash = f.root.appendingPathComponent("SimulatedTrash")
        return CleanupEngine(applicationRoots: [f.apps], libraryRoot: f.library,
                             currentAppURL: nil, runningBundleIdentifiers: running,
                             trashMover: { url in
                                 try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
                                 let target = trash.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
                                 try FileManager.default.moveItem(at: url, to: target)
                                 return target
                             })
    }

    func testExactBundlePathsAndOptionalUserData() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let support = f.library.appendingPathComponent("Application Support/com.example.fixture")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let unrelated = f.library.appendingPathComponent("Caches/com.example.other")
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
        let e = engine(f)
        let inventory = await e.installedApplications()
        XCTAssertEqual(inventory.applications.map(\.bundleIdentifier), ["com.example.fixture"])
        let app = try XCTUnwrap(inventory.applications.first)
        let related = await e.relatedFiles(for: app)
        XCTAssertEqual(Set(related.candidates.map(\.category)), [.application, .cache, .support])
        XCTAssertEqual(related.candidates.first(where: { $0.category == .support })?.selectedByDefault, false)
        XCTAssertFalse(related.candidates.contains { $0.url.path == unrelated.path })
        let junk = await e.scanJunk()
        XCTAssertEqual(Set(junk.candidates.map { $0.url.path }), [f.cache.path, unrelated.path])
        XCTAssertEqual(junk.candidates.first(where: { $0.url.path == unrelated.path })?.selectedByDefault, false)
    }

    func testRunningAppSkippedAndRecheckedBeforeTrash() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        var running = Set<String>()
        let e = engine(f, running: { running })
        let inventory = await e.installedApplications()
        let app = try XCTUnwrap(inventory.applications.first)
        let selected = await e.relatedFiles(for: app)
        XCTAssertEqual(selected.candidates.count, 2)
        running.insert("com.example.fixture")
        let result = await e.moveToTrash(selected.candidates)
        XCTAssertTrue(result.moved.isEmpty)
        XCTAssertEqual(result.failures.count, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.app.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.cache.path))
    }

    func testNestedLoginItemMarksParentAppRunning() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let helper = f.app.appendingPathComponent("Contents/Library/LoginItems/FixtureMonitor.app")
        try FileManager.default.createDirectory(at: helper.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": "com.example.fixture.monitor", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: helper.appendingPathComponent("Contents/Info.plist"))
        let ids = CleanupEngine.bundleIDs(forRunningBundleURL: helper)
        XCTAssertEqual(ids, ["com.example.fixture", "com.example.fixture.monitor"])
        let e = engine(f, running: { ids })
        let inventory = await e.installedApplications()
        XCTAssertEqual(inventory.applications.first?.isRunning, true)
        let junk = await e.scanJunk()
        XCTAssertFalse(junk.candidates.contains { $0.bundleIdentifier == "com.example.fixture" })
        let related = await e.relatedFiles(for: try XCTUnwrap(inventory.applications.first))
        XCTAssertTrue(related.candidates.isEmpty)
        XCTAssertFalse(related.issues.isEmpty)
    }

    func testChangedFileIsRejected() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let e = engine(f)
        let candidates = await e.scanJunk()
        let candidate = try XCTUnwrap(candidates.candidates.first)
        try FileManager.default.removeItem(at: f.cache)
        try FileManager.default.createDirectory(at: f.cache, withIntermediateDirectories: true)
        let result = await e.moveToTrash([candidate])
        XCTAssertTrue(result.moved.isEmpty)
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.cache.path))
    }

    func testSymlinkAndOutsidePathAreNeverSelected() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let outside = f.root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.removeItem(at: f.cache)
        try FileManager.default.createSymbolicLink(at: f.cache, withDestinationURL: outside)
        let e = engine(f)
        let junk = await e.scanJunk()
        XCTAssertTrue(junk.candidates.isEmpty)
        XCTAssertFalse(junk.issues.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
    }

    func testSuccessfulMoveRecordsOriginalAndTrashPaths() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let e = engine(f)
        let selected = await e.scanJunk()
        let result = await e.moveToTrash(selected.candidates)
        XCTAssertEqual(result.moved.count, 1)
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertTrue(result.ledgerIssues.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(result.moved.first).trashedURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.cache.path))
        let ledger = f.library.appendingPathComponent("Application Support/Lime/operations.jsonl")
        let row = try JSONSerialization.jsonObject(with: Data(contentsOf: ledger)) as? [String: Any]
        XCTAssertEqual(row?["original"] as? String, f.cache.path)
        XCTAssertTrue((row?["trash"] as? String)?.contains("SimulatedTrash") == true)
    }
}
