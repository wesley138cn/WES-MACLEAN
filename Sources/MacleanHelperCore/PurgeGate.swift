import Foundation
import MacleanShared

/// One operation at a time, shared across every XPC connection.
public final class PurgeGate {
    private let lock = NSLock()
    private var running = false
    private var lastSuccess: TimeInterval?
    private var removing = false
    private let cooldown: TimeInterval
    public init(cooldown: TimeInterval = 30) { self.cooldown = cooldown }

    public func begin(now: TimeInterval) -> (Int, String)? {
        lock.lock(); defer { lock.unlock() }
        guard !removing else { return (HelperReply.unavailable, "助手正在移除") }
        guard !running else { return (HelperReply.busy, "正在清理，请稍候") }
        if let lastSuccess, now - lastSuccess < cooldown {
            return (HelperReply.cooldown, "刚完成清理，请稍后再试")
        }
        running = true
        return nil
    }
    public func finish(success: Bool, now: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        running = false
        if success { lastSuccess = now }
    }
    public func beginRemoval() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !running, !removing else { return false }
        removing = true
        return true
    }
    public func removalFailed() { lock.lock(); removing = false; lock.unlock() }
    public var isBusy: Bool { lock.lock(); defer { lock.unlock() }; return running || removing }
}

public enum FixedPurge {
    /// No caller-supplied command, path, arguments, environment or shell.
    public static func run() -> (Int, String) {
        guard geteuid() == 0 else { return (HelperReply.unavailable, "清理助手尚未获得系统权限") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/purge")
        process.arguments = []
        process.currentDirectoryURL = URL(fileURLWithPath: "/")
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() }
        catch { return (HelperReply.failed, "缓存回收启动失败") }
        if exited.wait(timeout: .now() + 45) == .timedOut {
            if process.isRunning { process.terminate() }
            if exited.wait(timeout: .now() + 2) == .timedOut, process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            return (HelperReply.timedOut, "缓存回收超时，请稍后重试")
        }
        return process.terminationStatus == 0
            ? (HelperReply.success, "系统已执行缓存回收")
            : (HelperReply.failed, "缓存回收失败，请稍后重试")
    }
}
