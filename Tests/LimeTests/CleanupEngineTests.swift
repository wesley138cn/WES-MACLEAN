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

    func testFrameworkLinksDoNotHideBundlePayloadOrFollowExternalData() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let fm = FileManager.default
        let framework = f.app.appendingPathComponent("Contents/Helpers/Doubao Browser.app/Contents/Frameworks/Doubao Browser Framework.framework")
        try fm.createDirectory(at: framework, withIntermediateDirectories: true)
        // Real app frameworks expose aliases before their versioned payload.
        try fm.createSymbolicLink(atPath: framework.appendingPathComponent("Doubao Browser Framework").path,
                                  withDestinationPath: "Versions/Current/Doubao Browser Framework")
        for name in ["Resources", "Libraries", "Helpers"] {
            try fm.createSymbolicLink(atPath: framework.appendingPathComponent(name).path,
                                      withDestinationPath: "Versions/Current/" + name)
        }
        let versions = framework.appendingPathComponent("Versions")
        try fm.createDirectory(at: versions, withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: versions.appendingPathComponent("Current").path, withDestinationPath: "147.0.7727.149")
        let payload = versions.appendingPathComponent("147.0.7727.149/Doubao Browser Framework")
        try fm.createDirectory(at: payload.deletingLastPathComponent(), withIntermediateDirectories: true)
        for name in ["Resources", "Libraries", "Helpers"] {
            try fm.createDirectory(at: payload.deletingLastPathComponent().appendingPathComponent(name), withIntermediateDirectories: true)
        }
        try Data(repeating: 7, count: 2 * 1024 * 1024).write(to: payload)
        let outside = f.root.appendingPathComponent("External.data")
        try Data(repeating: 9, count: 8 * 1024 * 1024).write(to: outside)
        try fm.createSymbolicLink(at: framework.appendingPathComponent("External"), withDestinationURL: outside)
        let e = engine(f)
        let inventory = await e.installedApplications()
        let app = try XCTUnwrap(inventory.applications.first)
        let related = await e.relatedFiles(for: app)
        let reviewBytes = try XCTUnwrap(related.candidates.first { $0.category == .application }?.sizeBytes)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(app.sizeBytes), 2 * 1024 * 1024)
        XCTAssertEqual(app.sizeBytes, reviewBytes)
        XCTAssertLessThan(reviewBytes, 3 * 1024 * 1024, "Aliases and external targets must not be counted")
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

    func testProtectedAppFailureOffersSystemRecoveryAndPreservesUserData() async throws {
        let f = try fixture()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.app.path)
            try? FileManager.default.removeItem(at: f.root)
        }
        // A read-only app reproduces Cocoa 513 without changing a real app.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: f.app.path)
        let e = CleanupEngine(applicationRoots: [f.apps], libraryRoot: f.library,
                              currentAppURL: nil, runningBundleIdentifiers: { [] })
        let inventory = await e.installedApplications()
        let review = await e.relatedFiles(for: try XCTUnwrap(inventory.applications.first))
        let app = try XCTUnwrap(review.candidates.first { $0.category == .application })
        let result = await e.moveToTrash([app])
        XCTAssertTrue(result.moved.isEmpty)
        XCTAssertEqual(result.failures.first?.recoveryURL?.path, f.app.path)
        XCTAssertEqual(result.failures.first?.reason, "需要系统授权，请在 Finder 中继续卸载")
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.app.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.cache.path))
    }

    func testFailedAppUninstallKeepsAssociatedFilesEvenWhenSelectedFirst() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let e = CleanupEngine(applicationRoots: [f.apps], libraryRoot: f.library,
                              currentAppURL: nil, runningBundleIdentifiers: { [] }, trashMover: { url in
            if url.pathExtension == "app" { throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError) }
            let target = f.root.appendingPathComponent("moved-cache")
            try FileManager.default.moveItem(at: url, to: target)
            return target
        })
        let inventory = await e.installedApplications()
        let review = await e.relatedFiles(for: try XCTUnwrap(inventory.applications.first))
        let result = await e.moveToTrash(Array(review.candidates.reversed()))
        XCTAssertTrue(result.moved.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.cache.path))
        XCTAssertTrue(result.failures.contains { $0.reason == "应用卸载未完成，关联文件已保留" })
    }

    func testSystemUninstallRequiresExactAppInTrash() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let fm = FileManager.default
        let e = engine(f)
        let inventory = await e.installedApplications()
        let review = await e.relatedFiles(for: try XCTUnwrap(inventory.applications.first))
        let app = try XCTUnwrap(review.candidates.first { $0.category == .application })
        let trash = f.root.appendingPathComponent("SystemTrash")
        try fm.createDirectory(at: trash, withIntermediateDirectories: true)
        let elsewhere = f.root.appendingPathComponent("Renamed.app")
        try fm.moveItem(at: f.app, to: elsewhere)
        XCTAssertNil(e.systemTrashDestination(for: app, trashDirectory: trash))
        let impostor = trash.appendingPathComponent("Fixture.app")
        try fm.copyItem(at: elsewhere, to: impostor)
        XCTAssertNil(e.systemTrashDestination(for: app, trashDirectory: trash))
        let real = trash.appendingPathComponent("Fixture 2.app")
        try fm.moveItem(at: elsewhere, to: real)
        XCTAssertEqual(e.systemTrashDestination(for: app, trashDirectory: trash)?.resolvingSymlinksInPath().path, real.resolvingSymlinksInPath().path)
        try fm.moveItem(at: real, to: f.app)
        XCTAssertNil(e.systemTrashDestination(for: app, trashDirectory: trash))
    }

    func testSystemUninstallWorksWhenTrashListingIsDenied() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let trash = f.root.appendingPathComponent("PrivateTrash")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let restricted = TrashListingDeniedFileManager()
        restricted.deniedPath = trash.path
        let e = CleanupEngine(fileManager: restricted, applicationRoots: [f.apps], libraryRoot: f.library,
                              currentAppURL: nil, runningBundleIdentifiers: { [] })
        let inventory = await e.installedApplications()
        let review = await e.relatedFiles(for: try XCTUnwrap(inventory.applications.first))
        let app = try XCTUnwrap(review.candidates.first { $0.category == .application })
        // Finder renames collisions. Resolve the scanned object, without listing Trash.
        let renamed = trash.appendingPathComponent("Fixture 2.app")
        try FileManager.default.moveItem(at: f.app, to: renamed)
        XCTAssertEqual(e.systemTrashDestination(for: app, trashDirectory: trash)?.resolvingSymlinksInPath().path,
                       renamed.resolvingSymlinksInPath().path)
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

private final class TrashListingDeniedFileManager: FileManager, @unchecked Sendable {
    var deniedPath = ""
    override func contentsOfDirectory(at url: URL, includingPropertiesForKeys keys: [URLResourceKey]?,
                                      options mask: FileManager.DirectoryEnumerationOptions = []) throws -> [URL] {
        if url.path == deniedPath { throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError) }
        return try super.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: mask)
    }
}
