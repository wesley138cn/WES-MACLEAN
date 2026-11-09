import Foundation

@objc(MacleanHelperProtocol)
public protocol HelperProtocol {
    func version(reply: @escaping (Int, String) -> Void)
    func reclaim(reply: @escaping (Int, String) -> Void)
    func remove(reply: @escaping (Int, String) -> Void)
}

public enum HelperIdentity {
    public static let label = "local.wesp.MacleanHelper"
    public static let clientIdentifier = "local.wesp.Lime"
    public static var isConfigured: Bool { SignerIdentity.sha1 != String(repeating: "0", count: 40) }
    public static let protocolVersion = 1
    public static let installedPath = "/Library/PrivilegedHelperTools/" + label
    public static let plistPath = "/Library/LaunchDaemons/" + label + ".plist"
    public static func requirement(identifier: String) -> String {
        "anchor apple generic and identifier \"\(identifier)\" and certificate leaf = H\"\(SignerIdentity.sha1)\""
    }
    public static var clientRequirement: String { requirement(identifier: clientIdentifier) }
    public static var helperRequirement: String { requirement(identifier: label) }
}

public enum HelperReply {
    public static let success = 0
    public static let busy = 1
    public static let cooldown = 2
    public static let failed = 3
    public static let timedOut = 4
    public static let unavailable = 5
}
