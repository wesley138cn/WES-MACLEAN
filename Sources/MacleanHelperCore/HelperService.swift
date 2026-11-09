import Foundation
import SystemConfiguration
import MacleanShared

public final class HelperService: NSObject, NSXPCListenerDelegate, HelperProtocol {
    private let gate = PurgeGate()
    private let worker = DispatchQueue(label: "local.wesp.MacleanHelper.worker", qos: .utility)
    private let activityLock = NSLock()
    private var lastActivity = ProcessInfo.processInfo.systemUptime
    private var idleTimer: DispatchSourceTimer?

    public override init() { super.init() }
    public func startIdleTimer() {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 120, repeating: 30)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.activityLock.lock()
            let idle = ProcessInfo.processInfo.systemUptime - self.lastActivity
            self.activityLock.unlock()
            if idle >= 120 && !self.gate.isBusy { exit(EXIT_SUCCESS) }
        }
        idleTimer = timer; timer.resume()
    }
    private func touch() {
        activityLock.lock(); lastActivity = ProcessInfo.processInfo.systemUptime; activityLock.unlock()
    }
    public func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        var uid: uid_t = 0
        guard SCDynamicStoreCopyConsoleUser(nil, &uid, nil) != nil,
              uid != 0, connection.effectiveUserIdentifier == uid else { return false }
        // The OS checks each message against the live peer's signature.
        // This avoids PID lookup / PID reuse authentication races.
        connection.setCodeSigningRequirement(HelperIdentity.clientRequirement)
        connection.exportedInterface = NSXPCInterface(with: HelperProtocol.self)
        connection.exportedObject = self
        connection.resume()
        return true
    }
    public func version(reply: @escaping (Int, String) -> Void) {
        touch(); reply(HelperIdentity.protocolVersion, "WES·MACLEAN 清理助手")
    }
    public func reclaim(reply: @escaping (Int, String) -> Void) {
        touch()
        if let denied = gate.begin(now: ProcessInfo.processInfo.systemUptime) { reply(denied.0, denied.1); return }
        worker.async {
            let result = FixedPurge.run()
            self.gate.finish(success: result.0 == HelperReply.success, now: ProcessInfo.processInfo.systemUptime)
            self.touch()
            reply(result.0, result.1)
        }
    }
    public func remove(reply: @escaping (Int, String) -> Void) {
        touch()
        guard geteuid() == 0 else { reply(HelperReply.unavailable, "助手权限异常"); return }
        guard gate.beginRemoval() else { reply(HelperReply.busy, "清理结束后再移除助手"); return }
        worker.async {
            // Only this product's two fixed installation paths. Never follow links.
            for path in [HelperIdentity.plistPath, HelperIdentity.installedPath] {
                if unlink(path) != 0 && errno != ENOENT {
                    self.gate.removalFailed()
                    reply(HelperReply.failed, "助手文件移除失败，请重试")
                    return
                }
            }
            reply(HelperReply.success, "正在退出清理助手")
            self.worker.asyncAfter(deadline: .now() + 0.5) {
                let task = Process()
                task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
                task.arguments = ["bootout", "system/" + HelperIdentity.label]
                task.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
                task.currentDirectoryURL = URL(fileURLWithPath: "/")
                task.standardInput = FileHandle.nullDevice
                task.standardOutput = FileHandle.nullDevice
                task.standardError = FileHandle.nullDevice
                do { try task.run() } catch { exit(EXIT_FAILURE) }
                // launchd normally terminates this helper during bootout.
                self.worker.asyncAfter(deadline: .now() + 5) { exit(EXIT_SUCCESS) }
            }
        }
    }
}
