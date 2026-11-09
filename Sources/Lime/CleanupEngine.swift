import AppKit
import Darwin
import Foundation

enum CleanupCategory: String, Codable, CaseIterable {
    case application = "应用程序"
    case cache = "缓存"
    case log = "日志"
    case savedState = "保存状态"
    case preference = "偏好设置"
    case support = "应用数据"
}

struct CleanupIssue: Identifiable, Hashable {
    let path: String
    let reason: String
    var id: String { path + ":" + reason }
}

struct InstalledApplication: Identifiable, Hashable {
    let url: URL
    let name: String
    let bundleIdentifier: String
    let sizeBytes: UInt64?
    let isRunning: Bool
    var id: String { url.path }
}

struct CleanupCandidate: Identifiable, Hashable {
    let url: URL
    let displayName: String
    let category: CleanupCategory
    let sizeBytes: UInt64?
    let bundleIdentifier: String
    let selectedByDefault: Bool
    fileprivate let identity: CleanupFileIdentity
    var id: String { url.path }
}

struct ApplicationScan {
    let applications: [InstalledApplication]
    let issues: [CleanupIssue]
}

struct CleanupScan {
    let candidates: [CleanupCandidate]
    let issues: [CleanupIssue]
}

struct MovedCleanupItem: Identifiable {
    let originalURL: URL
    let trashedURL: URL
    let sizeBytes: UInt64?
    let category: CleanupCategory
    var id: String { originalURL.path }
}

struct CleanupResult {
    let moved: [MovedCleanupItem]
    let failures: [CleanupIssue]
    let ledgerIssues: [CleanupIssue]
    var totalBytes: UInt64 { moved.reduce(0) { $0 &+ ($1.sizeBytes ?? 0) } }
}

private struct CleanupFileIdentity: Hashable {
    let device: UInt64
    let inode: UInt64
    let mode: UInt16
}

/// Lists exact app-owned paths and moves selected items to Finder's Trash.
/// Every move is checked again after the user has reviewed the scan result.
final class CleanupEngine {
    typealias TrashMover = (URL) throws -> URL

    private let fm: FileManager
    private let applicationRoots: [URL]
    private let libraryRoot: URL
    private let currentAppURL: URL?
    private let runningBundleIDs: () -> Set<String>
    private let trashMover: TrashMover
    private let ledgerURL: URL

    init(
        fileManager: FileManager = .default,
        applicationRoots: [URL] = [URL(fileURLWithPath: "/Applications"), FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")],
        libraryRoot: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library"),
        currentAppURL: URL? = Bundle.main.bundleURL,
        runningBundleIdentifiers: @escaping () -> Set<String> = { CleanupEngine.runningIDsFromWorkspace() },
        trashMover: TrashMover? = nil,
        ledgerURL: URL? = nil
    ) {
        self.fm = fileManager
        self.applicationRoots = applicationRoots.map { $0.resolvingSymlinksInPath().standardizedFileURL }
        self.libraryRoot = libraryRoot.resolvingSymlinksInPath().standardizedFileURL
        self.currentAppURL = currentAppURL?.resolvingSymlinksInPath().standardizedFileURL
        self.runningBundleIDs = runningBundleIdentifiers
        self.trashMover = trashMover ?? { url in
            var result: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &result)
            guard let result = result as URL? else { throw CleanupError.trashLocationMissing }
            return result
        }
        self.ledgerURL = ledgerURL ?? self.libraryRoot.appendingPathComponent("Application Support/Lime/operations.jsonl")
    }

    private static func runningIDsFromWorkspace() -> Set<String> {
        var ids = Set<String>()
        for app in NSWorkspace.shared.runningApplications where !app.isTerminated {
            if let id = app.bundleIdentifier { ids.insert(id) }
            if let url = app.bundleURL ?? app.executableURL {
                ids.formUnion(bundleIDs(forRunningBundleURL: url))
            }
        }
        return ids
    }

    /// A login item can run after its parent app exits. Its enclosing app is still active.
    static func bundleIDs(forRunningBundleURL url: URL) -> Set<String> {
        var ids = Set<String>()
        var cursor = url.standardizedFileURL
        while cursor.path != "/" {
            if cursor.pathExtension.lowercased() == "app", let id = Bundle(url: cursor)?.bundleIdentifier {
                ids.insert(id)
            }
            let parent = cursor.deletingLastPathComponent()
            if parent.path == cursor.path { break }
            cursor = parent
        }
        return ids
    }

    func installedApplications() async -> ApplicationScan {
        scanInstalledApplications()
    }

    private func scanInstalledApplications() -> ApplicationScan {
        let running = runningBundleIDs()
        var apps: [InstalledApplication] = []
        var issues: [CleanupIssue] = []
        var visited = Set<String>()
        for root in applicationRoots {
            guard fm.fileExists(atPath: root.path) else { continue }
            guard let enumerator = fm.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants],
                errorHandler: { url, error in
                    issues.append(CleanupIssue(path: url.path, reason: error.localizedDescription))
                    return true
                }
            ) else {
                issues.append(CleanupIssue(path: root.path, reason: "无法读取应用目录"))
                continue
            }
            for case let url as URL in enumerator {
                if Task.isCancelled {
                    issues.append(CleanupIssue(path: root.path, reason: "扫描已取消"))
                    return ApplicationScan(applications: apps, issues: issues)
                }
                if apps.count >= 2_000 {
                    issues.append(CleanupIssue(path: root.path, reason: "应用数量超过扫描上限"))
                    return ApplicationScan(applications: apps, issues: issues)
                }
                if url.pathExtension.lowercased() != "app" { continue }
                enumerator.skipDescendants()
                guard visited.insert(url.standardizedFileURL.path).inserted else { continue }
                do {
                    try requireSafePath(url, inside: root)
                    guard let app = readApplication(url, running: running) else { continue }
                    apps.append(app)
                } catch {
                    issues.append(CleanupIssue(path: url.path, reason: error.localizedDescription))
                }
            }
        }
        apps.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return ApplicationScan(applications: apps, issues: issues)
    }

    /// Candidate cache and log folders belong to an installed, stopped bundle ID.
    /// Saved state is available for explicit selection. User documents are not scanned.
    func scanJunk() async -> CleanupScan {
        let inventory = await installedApplications()
        let running = runningBundleIDs()
        var candidates: [CleanupCandidate] = []
        var issues = inventory.issues
        var seen = Set<String>()
        for app in inventory.applications {
            if Task.isCancelled {
                issues.append(CleanupIssue(path: libraryRoot.path, reason: "扫描已取消"))
                break
            }
            if running.contains(app.bundleIdentifier) { continue }
            for category in [CleanupCategory.cache, .log, .savedState] {
                let url = relatedURL(for: app.bundleIdentifier, category: category)
                if fm.fileExists(atPath: url.path) {
                    do {
                        let candidate = try makeCandidate(url, category: category, bundleID: app.bundleIdentifier)
                        if seen.insert(candidate.id).inserted { candidates.append(candidate) }
                    }
                    catch { issues.append(CleanupIssue(path: url.path, reason: error.localizedDescription)) }
                }
            }
        }
        // Show recognizable leftovers from removed apps, without preselecting them.
        for category in [CleanupCategory.cache, .log] {
            let root = category == .cache ? libraryRoot.appendingPathComponent("Caches") : libraryRoot.appendingPathComponent("Logs")
            guard fm.fileExists(atPath: root.path) else { continue }
            do {
                let children = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
                if children.count > 5_000 {
                    issues.append(CleanupIssue(path: root.path, reason: "项目数量超过扫描上限"))
                    continue
                }
                for url in children {
                    if Task.isCancelled {
                        issues.append(CleanupIssue(path: root.path, reason: "扫描已取消"))
                        break
                    }
                    let id = url.lastPathComponent
                    if running.contains(id) || id.hasPrefix("com.apple.") || !looksLikeBundleID(id) { continue }
                    do {
                        let candidate = try makeCandidate(url, category: category, bundleID: id, selectedByDefault: false)
                        if seen.insert(candidate.id).inserted { candidates.append(candidate) }
                    } catch {
                        issues.append(CleanupIssue(path: url.path, reason: error.localizedDescription))
                    }
                }
            } catch {
                issues.append(CleanupIssue(path: root.path, reason: error.localizedDescription))
            }
        }
        candidates.sort { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        return CleanupScan(candidates: candidates, issues: issues)
    }

    /// For an uninstall review. Application Support is personal app data and defaults off.
    func relatedFiles(for app: InstalledApplication) async -> CleanupScan {
        var candidates: [CleanupCandidate] = []
        var issues: [CleanupIssue] = []
        let running = runningBundleIDs()
        if running.contains(app.bundleIdentifier) {
            issues.append(CleanupIssue(path: app.url.path, reason: "应用正在运行，请先退出"))
            return CleanupScan(candidates: [], issues: issues)
        }
        do { candidates.append(try makeCandidate(app.url, category: .application, bundleID: app.bundleIdentifier)) }
        catch { issues.append(CleanupIssue(path: app.url.path, reason: error.localizedDescription)) }
        for category in [CleanupCategory.cache, .log, .savedState, .preference, .support] {
            let url = relatedURL(for: app.bundleIdentifier, category: category)
            if fm.fileExists(atPath: url.path) {
                do { candidates.append(try makeCandidate(url, category: category, bundleID: app.bundleIdentifier)) }
                catch { issues.append(CleanupIssue(path: url.path, reason: error.localizedDescription)) }
            }
        }
        return CleanupScan(candidates: candidates, issues: issues)
    }

    /// Called only after the caller's explicit selection and confirmation UI.
    func moveToTrash(_ candidates: [CleanupCandidate]) async -> CleanupResult {
        var moved: [MovedCleanupItem] = []
        var failures: [CleanupIssue] = []
        var ledgerIssues: [CleanupIssue] = []
        var selected = Set<String>()
        for candidate in candidates {
            if Task.isCancelled {
                failures.append(CleanupIssue(path: candidate.url.path, reason: "操作已取消"))
                break
            }
            if !selected.insert(candidate.url.standardizedFileURL.path).inserted {
                failures.append(CleanupIssue(path: candidate.url.path, reason: "重复项目已跳过"))
                continue
            }
            do {
                try validate(candidate, running: runningBundleIDs())
                let trashedURL = try trashMover(candidate.url)
                let item = MovedCleanupItem(originalURL: candidate.url, trashedURL: trashedURL, sizeBytes: candidate.sizeBytes, category: candidate.category)
                moved.append(item)
                do { try appendLedger(item) }
                catch { ledgerIssues.append(CleanupIssue(path: candidate.url.path, reason: "已移入废纸篓，记录失败：\(error.localizedDescription)")) }
            } catch {
                failures.append(CleanupIssue(path: candidate.url.path, reason: error.localizedDescription))
            }
        }
        return CleanupResult(moved: moved, failures: failures, ledgerIssues: ledgerIssues)
    }

    private func readApplication(_ url: URL, running: Set<String>) -> InstalledApplication? {
        guard let bundle = Bundle(url: url),
              bundle.object(forInfoDictionaryKey: "CFBundlePackageType") as? String == "APPL",
              let id = bundle.bundleIdentifier, !id.isEmpty else { return nil }
        let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
        return InstalledApplication(url: url, name: name, bundleIdentifier: id, sizeBytes: measuredSize(url), isRunning: running.contains(id))
    }

    private func makeCandidate(_ url: URL, category: CleanupCategory, bundleID: String, selectedByDefault override: Bool? = nil) throws -> CleanupCandidate {
        try validateLocation(url, category: category, bundleID: bundleID)
        let identity = try fileIdentity(url)
        guard (identity.mode & UInt16(S_IFMT)) != UInt16(S_IFLNK) else { throw CleanupError.symbolicLink }
        let selected = override ?? (category == .application || category == .cache || category == .log)
        return CleanupCandidate(url: url.standardizedFileURL,
                                displayName: url.lastPathComponent,
                                category: category,
                                sizeBytes: measuredSize(url),
                                bundleIdentifier: bundleID,
                                selectedByDefault: selected,
                                identity: identity)
    }

    private func validate(_ candidate: CleanupCandidate, running: Set<String>) throws {
        try validateLocation(candidate.url, category: candidate.category, bundleID: candidate.bundleIdentifier)
        let current = try fileIdentity(candidate.url)
        guard current == candidate.identity else { throw CleanupError.changedSinceScan }
        guard !running.contains(candidate.bundleIdentifier) else { throw CleanupError.runningApplication }
        if candidate.category == .application {
            guard let bundle = Bundle(url: candidate.url), bundle.bundleIdentifier == candidate.bundleIdentifier else {
                throw CleanupError.changedSinceScan
            }
        }
    }

    private func validateLocation(_ url: URL, category: CleanupCategory, bundleID: String) throws {
        let normal = url.standardizedFileURL
        guard normal.isFileURL, !bundleID.isEmpty, !bundleID.contains("/"), bundleID != ".", bundleID != ".." else {
            throw CleanupError.unsafePath
        }
        if let own = currentAppURL,
           (normal.path == own.path || normal.path.hasPrefix(own.path + "/") || bundleID == Bundle.main.bundleIdentifier) {
            throw CleanupError.currentApplication
        }
        if category == .application {
            guard normal.pathExtension.lowercased() == "app",
                  let root = applicationRoots.first(where: { isChild(normal, of: $0) }) else { throw CleanupError.unsafePath }
            let relative = String(normal.path.dropFirst(root.path.count + 1))
            if relative.split(separator: "/").dropLast().contains(where: { $0.lowercased().hasSuffix(".app") }) {
                throw CleanupError.unsafePath
            }
            try requireSafePath(normal, inside: root)
        } else {
            let expected = relatedURL(for: bundleID, category: category).standardizedFileURL
            guard normal.path == expected.path else { throw CleanupError.unsafePath }
            try requireSafePath(normal, inside: libraryRoot)
        }
    }

    private func relatedURL(for id: String, category: CleanupCategory) -> URL {
        switch category {
        case .cache: return libraryRoot.appendingPathComponent("Caches").appendingPathComponent(id)
        case .log: return libraryRoot.appendingPathComponent("Logs").appendingPathComponent(id)
        case .savedState: return libraryRoot.appendingPathComponent("Saved Application State").appendingPathComponent(id + ".savedState")
        case .preference: return libraryRoot.appendingPathComponent("Preferences").appendingPathComponent(id + ".plist")
        case .support: return libraryRoot.appendingPathComponent("Application Support").appendingPathComponent(id)
        case .application: return libraryRoot
        }
    }

    private func looksLikeBundleID(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count >= 3 && parts.allSatisfy { part in
            !part.isEmpty && part.utf8.allSatisfy { byte in
                (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte) || byte == 45 || byte == 95
            }
        }
    }

    private func isChild(_ url: URL, of root: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let base = root.standardizedFileURL.path
        return path.hasPrefix(base + "/")
    }

    private func requireSafePath(_ url: URL, inside root: URL, allowMissingLeaf: Bool = false) throws {
        guard isChild(url, of: root) else { throw CleanupError.unsafePath }
        let suffix = String(url.standardizedFileURL.path.dropFirst(root.path.count + 1))
        var cursor = root
        for part in suffix.split(separator: "/") {
            guard part != ".", part != ".." else { throw CleanupError.unsafePath }
            cursor.appendPathComponent(String(part))
            let info: CleanupFileIdentity
            do { info = try fileIdentity(cursor) }
            catch let error as NSError where allowMissingLeaf && error.domain == NSPOSIXErrorDomain && error.code == ENOENT {
                continue
            }
            if (info.mode & UInt16(S_IFMT)) == UInt16(S_IFLNK) { throw CleanupError.symbolicLink }
        }
    }

    private func fileIdentity(_ url: URL) throws -> CleanupFileIdentity {
        var st = stat()
        if url.path.withCString({ lstat($0, &st) }) != 0 {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: url.path])
        }
        return CleanupFileIdentity(device: UInt64(st.st_dev), inode: UInt64(st.st_ino), mode: UInt16(st.st_mode))
    }

    /// Bounded walk. A nil size is displayed as unknown, never as zero bytes.
    private func measuredSize(_ url: URL) -> UInt64? {
        guard let identity = try? fileIdentity(url) else { return nil }
        if (identity.mode & UInt16(S_IFMT)) == UInt16(S_IFREG) {
            return (try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey]).totalFileAllocatedSize).map(UInt64.init)
                ?? (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(UInt64.init)
        }
        var hadError = false
        guard (identity.mode & UInt16(S_IFMT)) == UInt16(S_IFDIR),
              let enumerator = fm.enumerator(at: url,
                                             includingPropertiesForKeys: [.isSymbolicLinkKey, .totalFileAllocatedSizeKey, .fileSizeKey],
                                             errorHandler: { _, _ in hadError = true; return true }) else { return nil }
        var bytes: UInt64 = 0
        var entries = 0
        for case let member as URL in enumerator {
            entries += 1
            if entries > 100_000 || Task.isCancelled { return nil }
            guard let memberIdentity = try? fileIdentity(member) else { hadError = true; continue }
            if memberIdentity.device != identity.device {
                hadError = true
                enumerator.skipDescendants()
                continue
            }
            guard let values = try? member.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .totalFileAllocatedSizeKey, .fileSizeKey]) else { hadError = true; continue }
            if values.isSymbolicLink == true { enumerator.skipDescendants(); continue }
            if values.isRegularFile == true {
                bytes &+= UInt64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
            }
        }
        return hadError ? nil : bytes
    }

    private func appendLedger(_ item: MovedCleanupItem) throws {
        let directory = ledgerURL.deletingLastPathComponent()
        try requireSafePath(directory, inside: libraryRoot, allowMissingLeaf: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        if fm.fileExists(atPath: ledgerURL.path) {
            try requireSafePath(ledgerURL, inside: libraryRoot)
        }
        let row: [String: Any] = [
            "date": ISO8601DateFormatter().string(from: Date()),
            "original": item.originalURL.path,
            "trash": item.trashedURL.path,
            "category": item.category.rawValue,
            "bytes": item.sizeBytes as Any? ?? NSNull()
        ]
        var data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
        data.append(0x0A)
        if !fm.fileExists(atPath: ledgerURL.path) { fm.createFile(atPath: ledgerURL.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: ledgerURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }
}

private enum CleanupError: LocalizedError {
    case unsafePath, symbolicLink, changedSinceScan, runningApplication, currentApplication, trashLocationMissing
    var errorDescription: String? {
        switch self {
        case .unsafePath: return "路径超出安全范围"
        case .symbolicLink: return "符号链接已跳过"
        case .changedSinceScan: return "文件在扫描后发生变化，请重新扫描"
        case .runningApplication: return "应用正在运行，请先退出"
        case .currentApplication: return "当前应用已跳过"
        case .trashLocationMissing: return "废纸篓位置未知"
        }
    }
}
