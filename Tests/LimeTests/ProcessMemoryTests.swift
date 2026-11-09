import XCTest
import AppKit
@testable import Lime

final class ProcessMemoryTests: XCTestCase {
    func testParsePreservesPathsWithSpacesAndRejectsInvalidMemory() {
        let result = ProcessMemory.parse(" 12 1 123 /Applications/My App.app/Contents/MacOS/My App\n13 1 -1 /bad\n14 1 18446744073709551615 /overflow\ninvalid")
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.residentBytes, 123 * 1024)
        XCTAssertEqual(result.first?.executable, "/Applications/My App.app/Contents/MacOS/My App")
    }

    func testHelpersChildrenAndMultipleInstancesCountOnce() {
        let apps = [AppProcessGroup(pid: 10, name: "A", url: URL(fileURLWithPath: "/Apps/A.app")),
                    AppProcessGroup(pid: 20, name: "B", url: URL(fileURLWithPath: "/Apps/B.app")),
                    AppProcessGroup(pid: 11, name: "A", url: URL(fileURLWithPath: "/Apps/A.app"))]
        let processes = ProcessMemory.parse("""
        10 1 10 /Apps/A.app/Contents/MacOS/A
        11 1 11 /Apps/A.app/Contents/MacOS/A
        12 1 12 /Apps/A.app/Contents/Frameworks/Helper
        13 10 13 /usr/bin/helper
        14 13 14 /usr/bin/child
        20 10 20 /Apps/B.app/Contents/MacOS/B
        21 20 21 /usr/bin/bchild
        30 1 30 /Apps/A.app.extra/Other
        31 32 31 /cycle
        32 31 32 /cycle
        """)
        let usage = ProcessMemory.aggregate(processes, apps: apps)
        XCTAssertEqual(usage["/Apps/A.app"]?.bytes, 60 * 1024)
        XCTAssertEqual(usage["/Apps/A.app"]?.count, 5)
        XCTAssertEqual(usage["/Apps/B.app"]?.bytes, 41 * 1024)
        XCTAssertEqual(usage.count, 2)
    }

    func testMissingProcessRemainsUnknown() {
        let app = AppProcessGroup(pid: 100, name: "Exited", url: URL(fileURLWithPath: "/Apps/Exited.app"))
        XCTAssertNil(ProcessMemory.aggregate([], apps: [app])[app.url.path])
    }

    func testLiveProcessSamplingReadsOurProcess() throws {
        let app = AppProcessGroup(pid: getpid(), name: "Test", url: URL(fileURLWithPath: "/Test.app"))
        let usage = try ProcessMemory.sample(apps: [app])
        XCTAssertGreaterThan(usage[app.url.path]?.bytes ?? 0, 0)
        XCTAssertGreaterThanOrEqual(usage[app.url.path]?.count ?? 0, 1)
    }

    @MainActor func testStatusKeepsEveryMetricWithinCompactWidth() {
        let name = "WESMACLEAN.StatusTest.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let s = SystemMonitor().snapshot
        XCTAssertEqual(StatusBarRenderer.columns(s, defaults: defaults).map(\.title), ["CPU", "GPU", "MEM", "SSD", "SEN", "FANS"])
        XCTAssertLessThanOrEqual(StatusBarRenderer.image(s, defaults: defaults).size.width, 300)
        XCTAssertEqual(StatusBarRenderer.image(s, defaults: defaults).size.height, 24)
    }
}
