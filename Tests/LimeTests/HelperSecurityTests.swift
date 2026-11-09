import XCTest
import Foundation
import Security
import MacleanShared
import MacleanHelperCore
@testable import Lime

final class HelperSecurityTests: XCTestCase {
    func testDevelopmentBuildRejectsHelperBeforeAuthorization() throws {
        guard !HelperIdentity.isConfigured else { throw XCTSkip("Signed configuration") }
        XCTAssertThrowsError(try HelperInstaller.install(bundleURL: URL(fileURLWithPath: "/missing.app"))) { error in
            XCTAssertEqual(error.localizedDescription, "此构建未配置清理助手签名")
        }
    }
    func testOverlappingPurgeAndRemovalAreRejected() {
        let gate = PurgeGate()
        XCTAssertNil(gate.begin(now: 10))
        XCTAssertEqual(gate.begin(now: 11)?.0, HelperReply.busy)
        XCTAssertFalse(gate.beginRemoval())
        gate.finish(success: true, now: 12)
        XCTAssertEqual(gate.begin(now: 13)?.0, HelperReply.cooldown)
        XCTAssertNil(gate.begin(now: 42))
        gate.finish(success: false, now: 43)
        XCTAssertTrue(gate.beginRemoval())
        XCTAssertEqual(gate.begin(now: 100)?.0, HelperReply.unavailable)
    }
    func testFailureDoesNotStartCooldown() {
        let gate = PurgeGate()
        XCTAssertNil(gate.begin(now: 0))
        gate.finish(success: false, now: 1)
        XCTAssertNil(gate.begin(now: 1))
    }
    func testConcurrentClientsGetOnePurgeSlot() {
        let gate = PurgeGate()
        let lock = NSLock()
        var accepted = 0
        DispatchQueue.concurrentPerform(iterations: 32) { _ in
            if gate.begin(now: 0) == nil { lock.lock(); accepted += 1; lock.unlock() }
        }
        XCTAssertEqual(accepted, 1)
    }
    func testFailedRemovalCanBeRetried() {
        let gate = PurgeGate()
        XCTAssertTrue(gate.beginRemoval())
        XCTAssertFalse(gate.beginRemoval())
        gate.removalFailed()
        XCTAssertTrue(gate.beginRemoval())
    }
    func testUnprivilegedProcessNeverRunsPurge() throws {
        guard geteuid() != 0 else { throw XCTSkip("Do not run helper tests as root") }
        XCTAssertEqual(FixedPurge.run().0, HelperReply.unavailable)
    }
    func testRequirementsAreValidAndPinnedToDifferentIdentities() {
        for requirement in [HelperIdentity.clientRequirement, HelperIdentity.helperRequirement] {
            var rule: SecRequirement?
            XCTAssertEqual(SecRequirementCreateWithString(requirement as CFString, [], &rule), errSecSuccess)
            XCTAssertNotNil(rule)
            XCTAssertTrue(requirement.contains("certificate leaf = H\"" + SignerIdentity.sha1))
            XCTAssertTrue(requirement.contains("anchor apple generic"))
        }
        XCTAssertNotEqual(HelperIdentity.clientRequirement, HelperIdentity.helperRequirement)
    }
    func testUntrustedSignedClientIsRejectedOverRealXPC() {
        let service = HelperService()
        let listener = NSXPCListener.anonymous()
        listener.delegate = service
        listener.resume()
        defer { listener.invalidate() }
        let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        connection.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)
        let denied = expectation(description: "Untrusted caller receives an XPC error")
        denied.assertForOverFulfill = false
        connection.invalidationHandler = { denied.fulfill() }
        connection.interruptionHandler = { denied.fulfill() }
        connection.resume()
        defer { connection.invalidate() }
        let proxy = connection.remoteObjectProxyWithErrorHandler { _ in denied.fulfill() } as! HelperProtocol
        proxy.version { _, _ in XCTFail("Unsigned test caller was accepted") }
        wait(for: [denied], timeout: 5)
        withExtendedLifetime(service) {}
    }
    func testSystemBinaryFailsOurClientAndHelperRequirements() {
        let binary = URL(fileURLWithPath: "/usr/bin/true")
        XCTAssertThrowsError(try HelperInstaller.validateSignature(at: binary, requirement: HelperIdentity.clientRequirement))
        XCTAssertThrowsError(try HelperInstaller.validateSignature(at: binary, requirement: HelperIdentity.helperRequirement))
    }
}
