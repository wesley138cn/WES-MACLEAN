import SwiftUI
import AppKit
import ServiceManagement

private let lime = Color.accentColor
private let canvas = Color(nsColor: .windowBackgroundColor)

struct MainView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                Text("WES·MACLEAN").font(.system(size: 15, weight: .semibold)).padding(.horizontal, 18).padding(.top, 23)
                List(selection: Binding<Page?>(get: { model.page }, set: { if let page = $0, !model.busy { model.page = page } })) {
                    ForEach(Page.allCases, id: \.self) { page in
                        Label(page.rawValue, systemImage: page.icon).tag(page).padding(.vertical, 5)
                    }
                }.listStyle(.sidebar).disabled(model.busy)
            }.frame(width: 184).background(.ultraThinMaterial)
            Divider()
            VStack(spacing: 0) {
                HStack {
                    Text(model.page.rawValue).font(.system(size: 23, weight: .semibold))
                    Spacer()
                    Button { model.showMemoryPanel?() } label: { Image(systemName: "menubar.rectangle") }
                        .buttonStyle(.plain).help("状态栏内存速览").accessibilityLabel("状态栏内存速览")
                    if model.busy {
                        ProgressView().controlSize(.small)
                        if model.page == .junk || model.page == .uninstall { Button("停止扫描") { model.cancel() } }
                    }
                }.padding(.horizontal, 28).padding(.vertical, 24)
                Group {
                    switch model.page {
                    case .overview: Overview(monitor: model.monitor)
                    case .uninstall: UninstallView(model: model)
                    case .junk: JunkView(model: model)
                    case .memory: MemoryView(model: model, monitor: model.monitor)
                    case .settings: SettingsView(model: model)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                if !model.status.isEmpty && model.page != .overview && model.page != .settings {
                    Divider()
                    Text(model.status).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(14).textSelection(.enabled)
                }
            }.background(canvas)
        }.tint(.accentColor)
        .onChange(of: model.page) { _ in
            guard !model.busy else { return }
            model.status = ""; model.search = ""
            if model.page == .uninstall { model.scanApps() }
            if model.page == .junk { model.candidates = []; model.selection = []; model.issues = [] }
            if model.page == .memory { model.refreshProcesses() }
        }
    }
}

struct Overview: View {
    @ObservedObject var monitor: SystemMonitor
    var s: SystemSnapshot { monitor.snapshot }
    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                VStack(spacing: 0) {
                    reading("CPU", icon: "cpu", value: pct(s.cpuPercent))
                    line
                    reading("GPU", icon: "square.stack.3d.up", value: pct(s.gpuPercent))
                    line
                    reading("内存", icon: "memorychip", value: bytes(s.memoryUsedBytes), detail: "/ " + bytes(s.memoryTotalBytes))
                    line
                    reading("硬盘", icon: "internaldrive", value: pct(diskUsedPercent(s)), detail: "可用 " + bytes(s.diskAvailableBytes))
                    line
                    reading("温度", icon: "thermometer.medium", value: s.sensorTemperatureCelsius.map { String(format: "%.0f°C", $0) } ?? "—")
                        .help("芯片传感器 SEN；并非整机平均温度")
                    line
                    reading("风扇", icon: "fan", value: s.fans.display, detail: s.fans.count == 0 ? "RPM —" : "")
                    line
                    reading("网络", icon: "network", value: "↑ " + StatusBarRenderer.compactRate(s.networkUploadBytesPerSecond), detail: "↓ " + StatusBarRenderer.compactRate(s.networkDownloadBytesPerSecond))
                }.card()
                HStack {
                    Text("内存压力 · \(pressure(s.memoryPressureLevel))")
                    Spacer()
                    Text("每 2 秒更新")
                }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 4)
            }.padding(.horizontal, 28).padding(.bottom, 24)
        }
    }
    private var line: some View { Divider().padding(.leading, 54) }
    private func reading(_ title: String, icon: String, value: String, detail: String = "") -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 17, weight: .regular)).foregroundStyle(.secondary).frame(width: 22)
            Text(title).font(.system(size: 13, weight: .medium))
            Spacer()
            Text(value).font(.system(size: 19, weight: .medium)).monospacedDigit()
            if !detail.isEmpty { Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit() }
        }.padding(.horizontal, 18).frame(height: 58)
    }
}

struct Sparkline: Shape {
    var values: [Double]
    func path(in rect: CGRect) -> Path {
        var p = Path(); guard values.count > 1 else { return p }
        for (i, value) in values.enumerated() {
            let point = CGPoint(x: rect.width * Double(i) / Double(values.count - 1), y: rect.height * (1 - min(100, max(0, value)) / 100))
            if i == 0 { p.move(to: point) } else { p.addLine(to: point) }
        }
        return p
    }
}

extension View {
    func card() -> some View { background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14)).overlay(RoundedRectangle(cornerRadius: 14).stroke(.primary.opacity(0.06), lineWidth: 1)) }
}
func thermal(_ state: ProcessInfo.ThermalState) -> String { switch state { case .nominal: return "正常"; case .fair: return "温热"; case .serious: return "偏热"; case .critical: return "过热"; @unknown default: return "未知" } }

struct UninstallView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                TextField("搜索应用", text: $model.search).textFieldStyle(.roundedBorder)
                Button("刷新") { model.scanApps() }.disabled(model.busy)
                if model.selectedApp != nil { Button("返回列表") { model.selectedApp = nil; model.candidates = []; model.issues = [] }.disabled(model.busy) }
            }
            if let app = model.selectedApp {
                HStack { Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path)).resizable().frame(width: 40, height: 40); VStack(alignment: .leading) { Text(app.name).font(.headline); Text(app.bundleIdentifier).font(.caption).foregroundStyle(.secondary) }; Spacer() }.padding(14).card()
                CandidateList(model: model)
            } else {
                ScrollView {
                    LazyVStack(spacing: 7) {
                        ForEach(model.apps.filter { model.search.isEmpty || $0.name.localizedCaseInsensitiveContains(model.search) }) { app in
                            Button { model.inspect(app) } label: {
                                HStack(spacing: 12) {
                                    Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path)).resizable().frame(width: 34, height: 34)
                                    VStack(alignment: .leading, spacing: 3) { Text(app.name).font(.system(size: 13, weight: .medium)); Text(app.url.path).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
                                    Spacer()
                                    if app.isRunning { Text("运行中").font(.caption).foregroundStyle(.secondary) }
                                    Text(bytes(app.sizeBytes)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                                }.padding(12).card()
                            }.buttonStyle(.plain).disabled(model.busy)
                        }
                        IssuesView(issues: model.issues)
                    }
                }
            }
        }.padding(.horizontal, 28).padding(.bottom, 18)
    }
}
struct JunkView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("缓存与日志").font(.headline)
                    Text("应用数据默认不选；系统文件不列入扫描。") .font(.caption).foregroundStyle(.secondary)
                }; Spacer()
                Button(model.candidates.isEmpty ? "开始扫描" : "重新扫描") { model.scanJunk() }.buttonStyle(.borderedProminent).disabled(model.busy)
            }.padding(20).card()
            if model.candidates.isEmpty && !model.busy {
                Spacer(); Image(systemName: "sparkles").font(.system(size: 42, weight: .ultraLight)).foregroundStyle(lime)
                Text("扫描待清理项目").font(.title3)
                Text("缓存会随应用使用再次生成").font(.caption).foregroundStyle(.secondary); Spacer()
                IssuesView(issues: model.issues)
            } else { CandidateList(model: model) }
        }.padding(.horizontal, 28).padding(.bottom, 18)
    }
}
struct CandidateList: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(spacing: 10) {
            ScrollView {
                LazyVStack(spacing: 7) {
                    ForEach(model.candidates) { item in
                        HStack(spacing: 10) {
                            Toggle("选择 \(item.displayName)", isOn: Binding(get: { model.selection.contains(item.id) }, set: { if $0 { model.selection.insert(item.id) } else { model.selection.remove(item.id) } })).labelsHidden().toggleStyle(.checkbox).disabled(model.busy)
                            VStack(alignment: .leading, spacing: 4) { Text(item.displayName).font(.system(size: 12, weight: .medium)); Text(item.url.path).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
                            Spacer()
                            Text(item.category.rawValue).font(.caption2).foregroundStyle(item.category == .support ? .orange : .secondary)
                            Text(bytes(item.sizeBytes)).font(.caption).monospacedDigit().frame(minWidth: 58, alignment: .trailing)
                            Button { NSWorkspace.shared.activateFileViewerSelecting([item.url]) } label: { Image(systemName: "magnifyingglass") }.buttonStyle(.borderless).help("在 Finder 查看")
                        }.padding(12).card()
                    }
                    IssuesView(issues: model.issues)
                }
            }
            HStack {
                Button("取消全选") { model.selection = [] }.disabled(model.busy)
                Spacer()
                Text("\(model.selection.count) 项 · \(bytes(model.selectedBytes))").font(.caption).monospacedDigit()
                Button("移入废纸篓") { model.trashSelected() }.buttonStyle(.borderedProminent).disabled(model.busy || model.selection.isEmpty)
            }.padding(.top, 8)
        }
    }
}
struct IssuesView: View {
    let issues: [CleanupIssue]
    var body: some View {
        if !issues.isEmpty {
            DisclosureGroup("\(issues.count) 项提示") {
                ForEach(issues) { issue in VStack(alignment: .leading, spacing: 3) { Text(issue.reason); Text(issue.path).foregroundStyle(.secondary).textSelection(.enabled) }.font(.caption).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4) }
            }.font(.caption).padding(12)
        }
    }
}
struct MemoryView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var monitor: SystemMonitor
    var body: some View {
        VStack(spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 7) { Text(bytes(monitor.snapshot.memoryUsedBytes)).font(.system(size: 30, weight: .medium, design: .rounded)); Text("活跃 / 有线 / 压缩 · 共 \(bytes(monitor.snapshot.memoryTotalBytes))").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                VStack(alignment: .trailing, spacing: 8) { Button("清理内存") { model.reclaimCache() }.disabled(model.busy || model.helper.state == .checking); Text(model.helper.isReady ? "清理助手已启用" : "首次启用需授权").font(.caption2).foregroundStyle(.secondary) }
            }.padding(20).card()
            HStack { Text("运行中的应用").font(.headline); Text("内存压力：\(pressure(monitor.snapshot.memoryPressureLevel))").font(.caption).foregroundStyle(.secondary); Spacer(); Button("刷新") { model.refreshProcesses() }.disabled(model.processesLoading) }
            ScrollView {
                LazyVStack(spacing: 7) {
                    ForEach(model.runningApps) { app in
                        HStack(spacing: 12) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path)).resizable().frame(width: 28, height: 28)
                            Text(app.name).font(.system(size: 13)); Spacer(); Text(bytes(app.memory)).font(.caption).monospacedDigit(); Button("退出") { model.quit(app) }.disabled(model.busy || app.pid == getpid() || app.url.lastPathComponent == "Finder.app")
                        }.padding(12).card()
                    }
                }
            }
            Text(model.processError.isEmpty ? "含辅助进程的驻留内存；共享页可能重复计入。" : model.processError) .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
        }.padding(.horizontal, 28).padding(.bottom, 18)
    }
}
@MainActor
final class SettingsState: ObservableObject {
    @Published var login = SMAppService.mainApp.status == .enabled
    @Published var message = ""
    func setLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            message = SMAppService.mainApp.status == .requiresApproval ? "请在系统设置中允许登录项" : "已更新登录设置"
        } catch { message = error.localizedDescription }
        login = SMAppService.mainApp.status == .enabled
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @AppStorage("showCPU") var cpu = true
    @AppStorage("showMemory") var memory = true
    @AppStorage("showGPU") var gpu = true
    @AppStorage("showSensor") var sensor = true
    @AppStorage("showFans") var fans = true
    @AppStorage("showNetwork") var network = true
    @AppStorage("showDisk") var disk = true
    @StateObject private var prefs = SettingsState()
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 16) {
                    Text("状态栏显示").font(.headline)
                    Toggle("CPU 使用率", isOn: $cpu); Toggle("GPU 使用率", isOn: $gpu); Toggle("内存使用率", isOn: $memory); Toggle("实时网速", isOn: $network); Toggle("硬盘使用率", isOn: $disk); Toggle("温度 · SEN", isOn: $sensor); Toggle("风扇 · RPM", isOn: $fans)
                    Text("状态栏保持展开。按住 ⌘ 可拖动位置。").font(.caption).foregroundStyle(.secondary)
                }.toggleStyle(.checkbox).padding(22).frame(maxWidth: .infinity, alignment: .leading).card()
                VStack(alignment: .leading, spacing: 12) {
                    Text("清理助手").font(.headline)
                    Text(model.helper.detail).font(.caption).foregroundStyle(.secondary)
                    HStack {
                        if !model.helper.isReady {
                            Button(model.helper.hasInstalledFiles ? "修复助手" : "启用清理助手") { model.enableHelper() }
                        }
                        if model.helper.hasInstalledFiles {
                            Button("检查连接") { Task { await model.helper.check() } }
                            Button("移除助手") { model.removeHelper() }
                            Button("后台运行设置") { SMAppService.openSystemSettingsLoginItems() }
                        }
                    }.disabled(model.busy || model.helper.state == .checking)
                    if !model.status.isEmpty { Text(model.status).font(.caption).foregroundStyle(.secondary) }
                }.padding(22).frame(maxWidth: .infinity, alignment: .leading).card()
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("登录时启动", isOn: Binding(get: { prefs.login }, set: { prefs.setLogin($0) })).toggleStyle(.switch)
                    if !prefs.message.isEmpty { Text(prefs.message).font(.caption).foregroundStyle(.secondary) }
                }.padding(22).card()
                VStack(alignment: .leading, spacing: 10) {
                    Text("本地运行").font(.headline)
                    Text("系统数据只在内存中显示。\n清理记录保存在本机。\n应用不包含统计上报或自动更新。").font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(5)
                    HStack { Button("查看操作记录") { let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Lime"); if FileManager.default.fileExists(atPath: url.path) { NSWorkspace.shared.open(url) } else { prefs.message = "暂无清理记录" } }; Button("退出WES·MACLEAN") { NSApp.terminate(nil) } }
                }.padding(22).frame(maxWidth: .infinity, alignment: .leading).card()
            }.padding(.horizontal, 28).padding(.bottom, 22)
        }
    }
}
struct QuickPanel: View {
    @ObservedObject var model: AppModel
    @ObservedObject var monitor: SystemMonitor
    let clean: () -> Void
    let open: (Page) -> Void
    init(model: AppModel, clean: @escaping () -> Void, open: @escaping (Page) -> Void) {
        self.model = model; self.monitor = model.monitor; self.clean = clean; self.open = open
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("WES·MACLEAN").font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("内存").font(.caption).foregroundStyle(.secondary)
            }
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(bytes(monitor.snapshot.memoryUsedBytes)).font(.system(size: 28, weight: .medium)).monospacedDigit()
                    Text("共 " + bytes(monitor.snapshot.memoryTotalBytes)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("清理内存", action: clean).buttonStyle(.borderedProminent).disabled(model.busy || model.helper.state == .checking)
                    .help(model.helper.isReady ? "回收文件缓存" : "首次启用清理助手需要授权")
            }
            ProgressView(value: Double(monitor.snapshot.memoryUsedBytes), total: Double(max(1, monitor.snapshot.memoryTotalBytes))).tint(pressureColor)
            HStack {
                Text("内存压力 · " + pressure(monitor.snapshot.memoryPressureLevel))
                Spacer()
                Text("每 3 秒更新")
            }.font(.caption).foregroundStyle(.secondary)
            Divider()
            HStack {
                Text("应用内存").font(.system(size: 12, weight: .semibold))
                Spacer()
                if model.processesLoading { ProgressView().controlSize(.mini) }
                Button { model.refreshProcesses() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).disabled(model.processesLoading).help("刷新应用内存")
                    .accessibilityLabel("刷新应用内存")
            }
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.runningApps) { app in
                        HStack(spacing: 9) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path)).resizable().frame(width: 23, height: 23)
                            Text(app.name).lineLimit(1).truncationMode(.tail)
                            Spacer(minLength: 8)
                            Text(bytes(app.memory)).monospacedDigit().foregroundStyle(.secondary)
                        }.font(.system(size: 12)).frame(height: 35)
                            .help("\(app.processCount) 个进程 · 驻留内存")
                    }
                    if model.runningApps.isEmpty && !model.processesLoading {
                        Text(model.processError.isEmpty ? "暂无运行中的应用" : "读取失败，请刷新")
                            .font(.caption).foregroundStyle(.secondary).padding(.vertical, 30)
                    }
                }
            }.frame(maxHeight: .infinity)
            Text(model.processError.isEmpty ? "含辅助进程；共享内存可能重复计入。" : model.processError)
                .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
            if !model.memoryActionStatus.isEmpty {
                Text(model.memoryActionStatus).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Divider()
            HStack {
                Button("清理垃圾") { open(.junk) }
                Button("卸载应用") { open(.uninstall) }
                Spacer()
                Button("打开") { open(.memory) }
            }.controlSize(.small)
        }.padding(18).frame(width: 360, height: 544)
    }
    private var pressureColor: Color {
        switch monitor.snapshot.memoryPressureLevel {
        case .normal: return .green
        case .warning: return .orange
        case .critical: return .red
        case .unknown: return .accentColor
        }
    }
}

func pressure(_ level: MemoryPressureLevel) -> String {
    switch level { case .normal: return "正常"; case .warning: return "偏高"; case .critical: return "紧张"; case .unknown: return "未提供" }
}
