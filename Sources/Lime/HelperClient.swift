import Foundation
import Security
import ServiceManagement
import MacleanShared

struct HelperFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct HelperResponse {
    let code: Int
    let message: String
}

enum HelperRequest { case version, reclaim, remove }

/// Exactly-once completion, including timeout, XPC errors and interruption.
final class HelperRPC {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<HelperResponse, Error>?
    private var connection: NSXPCConnection?
    private var timeout: DispatchWorkItem?
    init(_ continuation: CheckedContinuation<HelperResponse, Error>) { self.continuation = continuation }
    func start(_ request: HelperRequest) {
        let connection = NSXPCConnection(machServiceName: HelperIdentity.label, options: .privileged)
        self.connection = connection
        connection.setCodeSigningRequirement(HelperIdentity.helperRequirement)
        connection.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)
        connection.invalidationHandler = { self.finish(.failure(HelperFailure(message: "清理助手连接已断开"))) }
        connection.interruptionHandler = { self.finish(.failure(HelperFailure(message: "清理助手已退出，请重试"))) }
        let deadline = DispatchWorkItem { self.finish(.failure(HelperFailure(message: "清理助手响应超时"))) }
        timeout = deadline
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + (request == .reclaim ? 55 : 5), execute: deadline)
        connection.resume()
        let proxy = connection.remoteObjectProxyWithErrorHandler { _ in
            self.finish(.failure(HelperFailure(message: "暂未连接清理助手，请检查设置")))
        }
        guard let helper = proxy as? HelperProtocol else {
            finish(.failure(HelperFailure(message: "清理助手接口不匹配"))); return
        }
        let reply: (Int, String) -> Void = { self.finish(.success(HelperResponse(code: $0, message: $1))) }
        switch request {
        case .version: helper.version(reply: reply)
        case .reclaim: helper.reclaim(reply: reply)
        case .remove: helper.remove(reply: reply)
        }
    }
    private func finish(_ result: Result<HelperResponse, Error>) {
        lock.lock()
        guard let continuation else { lock.unlock(); return }
        self.continuation = nil
        let connection = self.connection; self.connection = nil
        let deadline = timeout; timeout = nil
        lock.unlock()
        deadline?.cancel()
        connection?.invalidationHandler = nil
        connection?.interruptionHandler = nil
        connection?.invalidate()
        continuation.resume(with: result)
    }
    static func call(_ request: HelperRequest) async throws -> HelperResponse {
        try await withCheckedThrowingContinuation { continuation in HelperRPC(continuation).start(request) }
    }
}

enum HelperInstaller {
    static func validateSignature(at url: URL, requirement: String) throws {
        var code: SecStaticCode?
        var rule: SecRequirement?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess,
              SecRequirementCreateWithString(requirement as CFString, [], &rule) == errSecSuccess,
              let code, let rule,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures), rule) == errSecSuccess else {
            throw HelperFailure(message: "应用签名校验失败，请重新安装")
        }
    }
    static func install(bundleURL: URL) throws {
        guard HelperIdentity.isConfigured else {
            throw HelperFailure(message: "此构建未配置清理助手签名")
        }
        let embedded = bundleURL.appendingPathComponent("Contents/Library/LaunchServices/" + HelperIdentity.label)
        try validateSignature(at: bundleURL, requirement: HelperIdentity.clientRequirement)
        try validateSignature(at: embedded, requirement: HelperIdentity.helperRequirement)
        var authorization: AuthorizationRef?
        guard AuthorizationCreate(nil, nil, [], &authorization) == errAuthorizationSuccess, let authorization else {
            throw HelperFailure(message: "系统授权服务暂不可用")
        }
        defer { AuthorizationFree(authorization, [.destroyRights]) }
        let status = kSMRightBlessPrivilegedHelper.withCString { name in
            var item = AuthorizationItem(name: name, valueLength: 0, value: nil, flags: 0)
            return withUnsafeMutablePointer(to: &item) { item in
                var rights = AuthorizationRights(count: 1, items: item)
                return AuthorizationCopyRights(authorization, &rights, nil, [.interactionAllowed, .extendRights, .preAuthorize], nil)
            }
        }
        guard status == errAuthorizationSuccess else {
            throw HelperFailure(message: status == errAuthorizationCanceled ? "已取消启用助手" : "管理员授权未完成")
        }
        // Local Apple Development builds are not notarized. SMJobBless installs
        // a signed, root-owned helper with mutual designated requirements.
        // It is used only for initial installation / explicit repair, never reclaim.
        var error: Unmanaged<CFError>?
        guard SMJobBless(kSMDomainSystemLaunchd, HelperIdentity.label as CFString, authorization, &error) else {
            let detail = error?.takeRetainedValue()
            throw HelperFailure(message: "助手安装失败（\(detail.map { CFErrorGetCode($0) } ?? -1)）")
        }
    }
}

@MainActor
final class HelperClient: ObservableObject {
    enum State { case checking, notInstalled, ready, needsRepair, unavailable }
    @Published private(set) var state: State = .checking
    @Published private(set) var detail = "正在检查清理助手"
    var isReady: Bool { state == .ready }
    var hasInstalledFiles: Bool {
        FileManager.default.fileExists(atPath: HelperIdentity.installedPath)
            || FileManager.default.fileExists(atPath: HelperIdentity.plistPath)
    }
    func check() async {
        guard HelperIdentity.isConfigured else {
            state = .unavailable; detail = "此构建未配置清理助手签名"; return
        }
        guard hasInstalledFiles else { state = .notInstalled; detail = "首次启用需要管理员授权"; return }
        state = .checking
        do {
            let result = try await HelperRPC.call(.version)
            if result.code == HelperIdentity.protocolVersion { state = .ready; detail = "已启用，清理时无需重复授权" }
            else { state = .needsRepair; detail = "清理助手需要更新" }
        } catch { state = .unavailable; detail = error.localizedDescription }
    }
    func enable() async throws {
        state = .checking; detail = "等待管理员授权"
        let bundle = Bundle.main.bundleURL
        do { try await Task.detached(priority: .userInitiated) { try HelperInstaller.install(bundleURL: bundle) }.value }
        catch { await check(); throw error }
        await check()
        if !isReady {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            await check()
        }
        guard isReady else { throw HelperFailure(message: "助手已安装，请检查后台运行许可") }
    }
    func reclaim() async throws -> HelperResponse {
        do { return try await HelperRPC.call(.reclaim) }
        catch { state = .unavailable; detail = error.localizedDescription; throw error }
    }
    func remove() async throws {
        let result = try await HelperRPC.call(.remove)
        guard result.code == HelperReply.success else { throw HelperFailure(message: result.message) }
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        guard !hasInstalledFiles else { throw HelperFailure(message: "助手文件仍存在，请重试") }
        do {
            _ = try await HelperRPC.call(.version)
            throw HelperFailure(message: "助手尚未完全退出，请重试")
        } catch let error as HelperFailure where error.message == "助手尚未完全退出，请重试" { throw error }
        catch { state = .notInstalled; detail = "清理助手已移除" }
    }
}
