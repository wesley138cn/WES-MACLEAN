import AppKit

/// Two-line monochrome template matching the supplied status-bar reference.
enum StatusBarRenderer {
    struct Column { let title: String; let value: String; let width: CGFloat }
    static func columns(_ s: SystemSnapshot, defaults d: UserDefaults) -> [Column] {
        var fields: [Column] = []
        func shown(_ key: String) -> Bool { d.object(forKey: key) as? Bool ?? true }
        if shown("showCPU") { fields.append(.init(title: "CPU", value: pct(s.cpuPercent), width: 34)) }
        if shown("showGPU") { fields.append(.init(title: "GPU", value: pct(s.gpuPercent), width: 34)) }
        if shown("showMemory") { fields.append(.init(title: "MEM", value: pct(s.memoryTotalBytes > 0 ? Double(s.memoryUsedBytes) / Double(s.memoryTotalBytes) * 100 : nil), width: 34)) }
        if shown("showDisk") { fields.append(.init(title: "SSD", value: pct(diskUsedPercent(s)), width: 34)) }
        if shown("showSensor") { fields.append(.init(title: "SEN", value: s.sensorTemperatureCelsius.map { String(format: "%.0f°C", $0) } ?? "—", width: 34)) }
        if shown("showFans") {
            let value: String
            if s.fans.count == 0 { value = "0" }
            else { value = s.fans.readings.compactMap(\.rpm).max().map { String(format: "%.0f", $0) } ?? "—" }
            fields.append(.init(title: "FANS", value: value, width: 34))
        }
        return fields
    }
    static func image(_ s: SystemSnapshot, defaults d: UserDefaults = .standard) -> NSImage {
        let fields = columns(s, defaults: d)
        let network = d.object(forKey: "showNetwork") as? Bool ?? true
        let gap: CGFloat = 4
        let count = fields.count + (network ? 1 : 0)
        if count == 0 { let icon = NSImage(systemSymbolName: "desktopcomputer", accessibilityDescription: "WES·MACLEAN")!; icon.isTemplate = true; return icon }
        let width = fields.reduce(CGFloat(0)) { $0 + $1.width } + (network ? 66 : 0) + CGFloat(max(0, count - 1)) * gap
        let height: CGFloat = 24
        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        let top: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.black]
        let small: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 7.5, weight: .medium), .foregroundColor: NSColor.black.withAlphaComponent(0.65)]
        func centered(_ string: String, at x: CGFloat, y: CGFloat, width: CGFloat, attributes: [NSAttributedString.Key: Any]) {
            let text = NSString(string: string)
            let size = text.size(withAttributes: attributes)
            text.draw(at: NSPoint(x: x + (width - size.width) / 2, y: y), withAttributes: attributes)
        }
        func separator(_ x: CGFloat) {
            NSColor.black.withAlphaComponent(0.32).setStroke()
            let path = NSBezierPath(); path.move(to: NSPoint(x: x, y: 2)); path.line(to: NSPoint(x: x, y: height - 2)); path.lineWidth = 0.5; path.stroke()
        }
        var x: CGFloat = 0
        for (i, field) in fields.enumerated() {
            if i > 0 { separator(x + gap / 2); x += gap }
            centered(field.value, at: x, y: 9, width: field.width, attributes: top)
            centered(field.title, at: x, y: 0, width: field.width, attributes: small)
            x += field.width
        }
        if network {
            if !fields.isEmpty { separator(x + gap / 2); x += gap }
            let font: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium), .foregroundColor: NSColor.black]
            NSString(string: "↑ " + compactRate(s.networkUploadBytesPerSecond)).draw(at: NSPoint(x: x + 2, y: 12), withAttributes: font)
            NSString(string: "↓ " + compactRate(s.networkDownloadBytesPerSecond)).draw(at: NSPoint(x: x + 2, y: 0), withAttributes: font)
        }
        image.unlockFocus(); image.isTemplate = true
        return image
    }
    static func compactRate(_ value: Double?) -> String {
        guard let value else { return "—" }
        if value >= 1_000_000_000 { return String(format: "%.1f G/s", value / 1_000_000_000) }
        if value >= 1_000_000 { return String(format: "%.1f M/s", value / 1_000_000) }
        if value >= 1_000 { return String(format: "%.1f K/s", value / 1_000) }
        return String(format: "%.0f B/s", max(0, value))
    }
}
func diskUsedPercent(_ s: SystemSnapshot) -> Double? {
    guard let total = s.diskTotalBytes, let available = s.diskAvailableBytes, total > 0 else { return nil }
    return 100 * (1 - Double(min(available, total)) / Double(total))
}
