import Foundation
import MacleanShared
import MacleanHelperCore

guard geteuid() == 0 else {
    fputs("WES·MACLEAN helper must be started by the system service manager.\n", stderr)
    exit(EXIT_FAILURE)
}
let service = HelperService()
let listener = NSXPCListener(machServiceName: HelperIdentity.label)
listener.delegate = service
service.startIdleTimer()
listener.resume()
dispatchMain()
