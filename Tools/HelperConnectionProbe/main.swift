// Development-only authentication probe. Never bundled or installed as a service.
// Exercises only version(), with an anonymous local listener, without root.
import Foundation
import MacleanShared
import MacleanHelperCore

guard geteuid() != 0 else { fatalError("Run this probe without elevated privileges") }
let expectRejection = CommandLine.arguments.contains("--expect-rejection")
let service = HelperService()
let listener = NSXPCListener.anonymous()
listener.delegate = service
listener.resume()
let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
connection.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)
let lock = NSLock()
var finished = false
func finish(accepted: Bool) {
    lock.lock()
    guard !finished else { lock.unlock(); return }
    finished = true; lock.unlock()
    let passed = accepted != expectRejection
    print(passed ? "PASS: \(accepted ? "signed client accepted" : "incorrect identity rejected")" : "FAIL: unexpected authentication outcome")
    exit(passed ? 0 : 1)
}
connection.invalidationHandler = { finish(accepted: false) }
connection.interruptionHandler = { finish(accepted: false) }
connection.resume()
let proxy = connection.remoteObjectProxyWithErrorHandler { _ in finish(accepted: false) } as! HelperProtocol
proxy.version { version, _ in
    guard version == HelperIdentity.protocolVersion else { exit(1) }
    finish(accepted: true)
}
DispatchQueue.global().asyncAfter(deadline: .now() + 8) { print("FAIL: timeout"); exit(2) }
dispatchMain()
