import AppKit
import Combine
import SwiftUI
import ServiceManagement
import MacleanShared

@main
struct LimeMain {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--diagnose") {
            let monitor = SystemMonitor()
            monitor.refresh()
            RunLoop.current.run(until: Date().addingTimeInterval(1.1))
            monitor.refresh()
            let s = monitor.snapshot
            let result: [String: Any] = ["cpuPercent": s.cpuPercent as Any? ?? NSNull(), "memoryTotalBytes": s.memoryTotalBytes, "memoryUsedBytes": s.memoryUsedBytes, "diskTotalBytes": s.diskTotalBytes as Any? ?? NSNull(), "networkDownload": s.networkDownloadBytesPerSecond as Any? ?? NSNull(), "batteryPercent": s.batteryPercent as Any? ?? NSNull(), "gpuPercent": s.gpuPercent as Any? ?? NSNull(), "memoryPressure": s.memoryPressureLevel.rawValue, "fans": s.fans.display, "fanCount": s.fans.count as Any? ?? NSNull(), "sensorCelsius": s.sensorTemperatureCelsius as Any? ?? NSNull(), "networkRequests": "none"]
            if let d = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) { print(String(decoding: d, as: UTF8.self)) }
            if let i = CommandLine.arguments.firstIndex(of: "--status-preview"), CommandLine.arguments.indices.contains(i + 1) {
                let image = StatusBarRenderer.image(s)
                if let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
                }
            }
            return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
        withExtendedLifetime(delegate) {}
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    let model = AppModel()
    var status: NSStatusItem!
    var window: NSWindow!
    var popover: NSPopover!
    var cancellables: Set<AnyCancellable> = []
    var processTimer: Timer?
    var afterPopoverClose: (() -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if UserDefaults.standard.integer(forKey: "statusLayoutVersion") < 2 {
            for key in ["showCPU", "showGPU", "showMemory", "showDisk", "showSensor", "showFans", "showNetwork"] { UserDefaults.standard.set(true, forKey: key) }
            UserDefaults.standard.set(2, forKey: "statusLayoutVersion")
        }
        // Seed our own saved position once, near the system controls.
        // macOS remains responsible for layout; later user moves are preserved.
        let statusName = "WESMACLEAN.Metrics"
        if UserDefaults.standard.object(forKey: "NSStatusItem Preferred Position " + statusName) == nil {
            UserDefaults.standard.set(0, forKey: "NSStatusItem Preferred Position " + statusName)
        }
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.autosaveName = statusName
        status.behavior = []
        status.isVisible = true
        status.button?.target = self
        status.button?.action = #selector(togglePopover)
        status.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        status.button?.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        status.button?.image = NSImage(systemSymbolName: "desktopcomputer", accessibilityDescription: "WES·MACLEAN")
        status.button?.imagePosition = .imageOnly
        status.button?.imageScaling = .scaleNone
        popover = NSPopover()
        popover.behavior = .transient
        popover.delegate = self
        popover.contentSize = NSSize(width: 360, height: 544)
        popover.contentViewController = NSHostingController(rootView: QuickPanel(model: model, clean: { [weak self] in
            guard let self else { return }
            self.afterPopoverClose = { [weak self] in
                guard let self else { return }
                NSApp.activate(ignoringOtherApps: true)
                self.model.reclaimCache { [weak self] in self?.showPopover() }
            }
            self.popover.performClose(nil)
        }, open: { [weak self] page in
            self?.popover.performClose(nil)
            self?.model.page = page
            self?.showWindow()
        }))
        model.showMemoryPanel = { [weak self] in self?.showPopover() }
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 880, height: 640), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "WES·MACLEAN"
        window.minSize = NSSize(width: 800, height: 580)
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: MainView(model: model))
        window.center()
        model.monitor.$snapshot.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateTitle() }
        }.store(in: &cancellables)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification).sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateTitle() }
        }.store(in: &cancellables)
        model.monitor.start()
        Task { await model.helper.check() }
        if !CommandLine.arguments.contains("--background") { showWindow() }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showWindow(); return true }
    func applicationWillTerminate(_ notification: Notification) { model.monitor.stop(); processTimer?.invalidate() }
    func showWindow() { NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil) }
    @objc func togglePopover() {
        guard let button = status.button else { return }
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            let open = menu.addItem(withTitle: "打开WES·MACLEAN", action: #selector(openWindow), keyEquivalent: "")
            open.target = self
            menu.addItem(.separator())
            menu.addItem(withTitle: "退出WES·MACLEAN", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            status.menu = menu; button.performClick(nil); status.menu = nil
        } else if popover.isShown { popover.performClose(nil) }
        else { showPopover() }
    }
    func showPopover() {
        guard let button = status.button else { return }
        model.refreshProcesses()
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }
    func popoverDidShow(_ notification: Notification) {
        model.refreshProcesses()
        processTimer?.invalidate()
        processTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.popover.isShown else { return }
                self.model.refreshProcesses()
            }
        }
    }
    func popoverDidClose(_ notification: Notification) {
        processTimer?.invalidate(); processTimer = nil
        if let action = afterPopoverClose {
            afterPopoverClose = nil
            DispatchQueue.main.async { action() }
        }
    }
    @objc func openWindow() { showWindow() }
    func updateTitle() {
        let s = model.monitor.snapshot
        status.isVisible = true
        status.button?.title = ""
        status.button?.image = StatusBarRenderer.image(s)
        let fans = s.fans.count == 0 ? "无风扇，无 RPM 读数" : s.fans.display
        status.button?.toolTip = "WES·MACLEAN\nCPU \(pct(s.cpuPercent)) · GPU \(pct(s.gpuPercent))\n硬盘已用 \(pct(diskUsedPercent(s)))\n风扇：\(fans)\nSEN：芯片传感器\n网络：字节/秒"
        status.button?.setAccessibilityLabel("WES·MACLEAN 系统状态")
        status.button?.setAccessibilityValue("CPU \(pct(s.cpuPercent))，GPU \(pct(s.gpuPercent))，内存 \(bytes(s.memoryUsedBytes))，风扇 \(fans)")
    }
}

func bytes(_ value: UInt64?) -> String {
    guard let value else { return "—" }
    if value == 0 { return "0 KB" }
    return ByteCountFormatter.string(fromByteCount: Int64(min(value, UInt64(Int64.max))), countStyle: .binary)
}
func pct(_ value: Double?) -> String { value.map { String(format: "%.0f%%", $0) } ?? "—" }
func rate(_ value: Double?) -> String { value.map { bytes(UInt64(max(0, min($0, Double(Int64.max))))) + "/s" } ?? "—" }

struct RunningApp: Identifiable {
    let pid: pid_t
    let name: String
    let url: URL
    let memory: UInt64?
    let processCount: Int
    var id: pid_t { pid }
}

@MainActor
final class AppModel: ObservableObject {
    let monitor = SystemMonitor(interval: 2)
    let cleaner = CleanupEngine()
    let helper = HelperClient()
    private var helperChanges: AnyCancellable?
    init() {
        helperChanges = helper.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }
    var showMemoryPanel: (() -> Void)?
    @Published var page = Page.overview
    @Published var busy = false
    @Published var status = ""
    @Published var apps: [InstalledApplication] = []
    @Published var candidates: [CleanupCandidate] = []
    @Published var selection: Set<String> = []
    @Published var issues: [CleanupIssue] = []
    @Published var selectedApp: InstalledApplication?
    @Published var runningApps: [RunningApp] = []
    @Published var processesLoading = false
    @Published var processError = ""
    @Published var memoryActionStatus = ""
    @Published var search = ""
    private var processWork: Task<Void, Never>?
    private var work: Task<Void, Never>?
    var selectedBytes: UInt64 { candidates.filter { selection.contains($0.id) }.reduce(0) { $0 + ($1.sizeBytes ?? 0) } }
    var selectedCandidates: [CleanupCandidate] { candidates.filter { selection.contains($0.id) } }
    func scanApps() {
        guard !busy else { return }
        busy = true; status = "正在读取应用列表…"; selectedApp = nil; candidates = []; issues = []
        work = Task {
            let result = await cleaner.installedApplications()
            apps = result.applications; issues = result.issues
            busy = false; status = "找到 \(apps.count) 个应用"
        }
    }
    func inspect(_ app: InstalledApplication) {
        guard !busy else { return }
        selectedApp = app; busy = true; status = "正在查找关联文件…"
        work = Task {
            let result = await cleaner.relatedFiles(for: app)
            install(result); busy = false; status = "请核对待移入废纸篓的项目"
        }
    }
    func scanJunk() {
        guard !busy else { return }
        selectedApp = nil; busy = true; status = "正在扫描缓存与日志…"; candidates = []; issues = []
        work = Task {
            let result = await cleaner.scanJunk()
            install(result); busy = false; status = candidates.isEmpty ? "扫描范围内暂无可清理项目" : "找到 \(candidates.count) 项，可逐项核对"
        }
    }
    private func install(_ scan: CleanupScan) {
        candidates = scan.candidates; issues = scan.issues
        selection = Set(candidates.filter(\.selectedByDefault).map(\.id))
    }
    func cancel() { work?.cancel(); status = "正在停止扫描…" }
    func trashSelected() {
        let items = selectedCandidates
        guard !busy, !items.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "移入废纸篓？"
        alert.informativeText = "已选 \(items.count) 项，约 \(bytes(selectedBytes))。\n包含应用数据时，设置和本地资料也会移走。\n可在 Finder 废纸篓中放回。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "移入废纸篓"); alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        busy = true; status = "正在移入废纸篓…"
        work = Task {
            let result = await cleaner.moveToTrash(items)
            let done = Set(result.moved.map { $0.originalURL.path })
            candidates.removeAll { done.contains($0.id) }; selection.subtract(done)
            apps.removeAll { done.contains($0.id) }
            issues = result.failures + result.ledgerIssues
            status = "已移走 \(result.moved.count) 项（\(bytes(result.totalBytes))）"
            if !result.failures.isEmpty { status += "，\(result.failures.count) 项未移动" }
            status += "。清空废纸篓后释放磁盘空间。"
            busy = false; monitor.refresh()
        }
    }
    func refreshProcesses() {
        guard !processesLoading else { return }
        processesLoading = true
        let running = NSWorkspace.shared.runningApplications.filter { app in
            guard !app.isTerminated, let url = app.bundleURL else { return false }
            if app.activationPolicy == .regular { return true }
            // Include menu-bar apps, while keeping OS service bundles out of the app list.
            return app.activationPolicy == .accessory && url.pathExtension == "app"
                && !url.path.hasPrefix("/System/") && !url.path.hasPrefix("/usr/")
        }
        let discovered = running.compactMap { app -> AppProcessGroup? in
            guard let url = app.bundleURL else { return nil }
            return AppProcessGroup(pid: app.processIdentifier, name: app.localizedName ?? url.deletingPathExtension().lastPathComponent, url: url)
        }
        // Embedded helper .app bundles stay under their outer application.
        let metadata = discovered.filter { candidate in
            !discovered.contains { other in
                candidate.url.path.hasPrefix(other.url.path + "/")
            }
        }
        processWork = Task {
            let result = await Task.detached(priority: .utility) {
                Result { try ProcessMemory.sample(apps: metadata) }
            }.value
            defer { processesLoading = false }
            switch result {
            case .success(let usage):
                var seen = Set<String>()
                runningApps = metadata.compactMap { item in
                    guard let app = NSRunningApplication(processIdentifier: item.pid),
                          !app.isTerminated, app.bundleURL == item.url,
                          seen.insert(item.url.path).inserted else { return nil }
                    let sample = usage[item.url.path]
                    return RunningApp(pid: item.pid, name: item.name, url: item.url, memory: sample?.bytes, processCount: sample?.count ?? 0)
                }.sorted {
                    if $0.memory == $1.memory { return $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                    return ($0.memory ?? 0) > ($1.memory ?? 0)
                }
                processError = ""
            case .failure(let error):
                processError = error.localizedDescription
            }
        }
    }
    func quit(_ item: RunningApp) {
        guard let app = NSRunningApplication(processIdentifier: item.pid), app.bundleURL == item.url else { status = "应用状态已变化，请刷新"; return }
        let alert = NSAlert(); alert.messageText = "退出 \(item.name)？"
        alert.informativeText = "应用可能提示保存文档。\n退出后由系统回收内存。"
        alert.addButton(withTitle: "正常退出"); alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn {
            status = app.terminate() ? "已发送退出请求，等待应用结束" : "应用未接受退出请求"
            Task { try? await Task.sleep(nanoseconds: 1_000_000_000); refreshProcesses(); monitor.refresh() }
        }
    }
    func enableHelper() {
        guard HelperIdentity.isConfigured else { status = "此构建未配置清理助手签名"; return }
        guard !busy else { return }
        busy = true; status = "等待首次授权…"
        work = Task {
            defer { busy = false }
            do { try await helper.enable(); status = "清理助手已启用" }
            catch { status = error.localizedDescription }
            memoryActionStatus = status
        }
    }
    func removeHelper() {
        guard !busy else { return }
        let alert = NSAlert()
        alert.messageText = "移除清理助手？"
        alert.informativeText = "移除后停止后台服务。\n再次启用时需要管理员授权。"
        alert.addButton(withTitle: "移除助手"); alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        busy = true; status = "正在移除清理助手…"
        work = Task {
            defer { busy = false }
            do { try await helper.remove(); status = "清理助手已移除" }
            catch { status = error.localizedDescription }
            memoryActionStatus = status
        }
    }
    func reclaimCache(completion: @escaping () -> Void = {}) {
        guard HelperIdentity.isConfigured else {
            memoryActionStatus = "此构建未配置清理助手签名"
            status = memoryActionStatus; completion(); return
        }
        guard !busy else { return }
        if !helper.isReady {
            let alert = NSAlert()
            alert.messageText = helper.hasInstalledFiles ? "修复清理助手？" : "启用清理助手？"
            alert.informativeText = "首次需要管理员授权。\n之后清理无需重复输入密码。\n助手只回收文件缓存。\n可在设置中移除。"
            alert.addButton(withTitle: "启用并清理"); alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { completion(); return }
        }
        busy = true; status = helper.isReady ? "正在回收文件缓存…" : "等待管理员授权…"
        memoryActionStatus = status
        work = Task {
            defer { busy = false; completion() }
            do {
                if !helper.isReady { try await helper.enable() }
                status = "正在回收文件缓存…"; memoryActionStatus = status
                let result = try await helper.reclaim()
                status = result.message
                if result.code == HelperReply.success { monitor.refresh(); refreshProcesses() }
            } catch { status = error.localizedDescription }
            memoryActionStatus = status
        }
    }

}

enum Page: String, CaseIterable {
    case overview = "系统概览", uninstall = "卸载应用", junk = "清理垃圾", memory = "内存管理", settings = "设置"
    var icon: String { switch self { case .overview: return "chart.xyaxis.line"; case .uninstall: return "square.stack.3d.up"; case .junk: return "sparkles"; case .memory: return "memorychip"; case .settings: return "slider.horizontal.3" } }
}
