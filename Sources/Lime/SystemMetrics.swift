import Combine
import Darwin
import Foundation
import IOKit
import IOKit.ps

struct SystemSnapshot {
    let timestamp: Date
    /// Percentage of all logical CPU capacity used since the preceding sample.
    let cpuPercent: Double?
    let memoryTotalBytes: UInt64
    /// Active, wired and compressed physical pages. These are distinct VM counters.
    let memoryUsedBytes: UInt64
    let memoryAvailableBytes: UInt64
    /// An estimate based on available memory; this is not macOS's pressure graph.
    let memoryPressureEstimate: MemoryPressureEstimate
    /// The kernel's current memorystatus pressure level, when readable.
    let memoryPressureLevel: MemoryPressureLevel
    let diskTotalBytes: UInt64?
    let diskAvailableBytes: UInt64?
    let networkDownloadBytesPerSecond: Double?
    let networkUploadBytesPerSecond: Double?
    let batteryPercent: Double?
    let batteryIsCharging: Bool?
    let thermalState: ProcessInfo.ThermalState
    /// IOAccelerator's Device Utilization %, when published by the GPU driver.
    let gpuPercent: Double?
    let fans: FanSnapshot
    let sensorTemperatureCelsius: Double?

    static var empty: Self {
        .init(timestamp: Date(), cpuPercent: nil, memoryTotalBytes: 0,
              memoryUsedBytes: 0, memoryAvailableBytes: 0,
              memoryPressureEstimate: .unknown, memoryPressureLevel: .unknown,
              diskTotalBytes: nil,
              diskAvailableBytes: nil, networkDownloadBytesPerSecond: nil,
              networkUploadBytesPerSecond: nil, batteryPercent: nil,
              batteryIsCharging: nil, thermalState: .nominal, gpuPercent: nil, fans: .unavailable, sensorTemperatureCelsius: nil)
    }
}

enum MemoryPressureEstimate: String {
    case normal
    case elevated
    case critical
    case unknown
}

enum MemoryPressureLevel: String {
    case normal
    case warning
    case critical
    case unknown
}

@MainActor
final class SystemMonitor: ObservableObject {
    @Published private(set) var snapshot = SystemSnapshot.empty
    @Published private(set) var cpuHistory: [Double] = []
    @Published private(set) var memoryHistory: [Double] = []

    private let fanSensor = FanSensor()
    private let interval: TimeInterval
    private var timer: Timer?
    private var priorCPU: CPUTicks?
    private var priorNetwork: [String: NetworkCounters] = [:]
    private var priorNetworkUptime: TimeInterval?

    init(interval: TimeInterval = 2) {
        self.interval = max(1, interval)
    }

    func start() {
        guard timer == nil else { return }
        refresh()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        priorCPU = nil
        priorNetwork = [:]
        priorNetworkUptime = nil
    }

    func refresh() {
        let now = Date()
        let uptime = ProcessInfo.processInfo.systemUptime
        let ticks = readCPUTicks()
        let cpu = ticks.flatMap { current -> Double? in
            defer { priorCPU = current }
            guard let priorCPU else { return nil }
            let user = current.user &- priorCPU.user
            let system = current.system &- priorCPU.system
            let nice = current.nice &- priorCPU.nice
            let idle = current.idle &- priorCPU.idle
            let total = UInt64(user) + UInt64(system) + UInt64(nice) + UInt64(idle)
            guard total > 0 else { return nil }
            return min(100, max(0, 100 * Double(total - UInt64(idle)) / Double(total)))
        }

        let memory = readMemory()
        let disk = readDisk()
        let currentNetwork = readNetwork()
        var download: Double?
        var upload: Double?
        if let priorNetworkUptime {
            let elapsed = uptime - priorNetworkUptime
            if elapsed > 0 {
                var received: UInt64 = 0
                var sent: UInt64 = 0
                var matched = false
                for (name, current) in currentNetwork {
                    guard let previous = priorNetwork[name] else { continue }
                    matched = true
                    if let delta = counterDelta(from: previous.received, to: current.received) {
                        received += UInt64(delta)
                    }
                    if let delta = counterDelta(from: previous.sent, to: current.sent) {
                        sent += UInt64(delta)
                    }
                }
                if matched {
                    download = Double(received) / elapsed
                    upload = Double(sent) / elapsed
                }
            }
        }
        priorNetwork = currentNetwork
        priorNetworkUptime = uptime

        let battery = readBattery()
        snapshot = .init(timestamp: now, cpuPercent: cpu,
                         memoryTotalBytes: memory.total,
                         memoryUsedBytes: memory.used,
                         memoryAvailableBytes: memory.available,
                         memoryPressureEstimate: memory.pressure,
                         memoryPressureLevel: readKernelMemoryPressure(),
                         diskTotalBytes: disk.total,
                         diskAvailableBytes: disk.available,
                         networkDownloadBytesPerSecond: download,
                         networkUploadBytesPerSecond: upload,
                         batteryPercent: battery.percent,
                         batteryIsCharging: battery.charging,
                         thermalState: ProcessInfo.processInfo.thermalState,
                         gpuPercent: readGPUUtilization(), fans: fanSensor.sample(), sensorTemperatureCelsius: fanSensor.temperature())

        if let cpu { append(cpu, to: &cpuHistory) }
        if memory.total > 0 {
            append(100 * Double(memory.used) / Double(memory.total), to: &memoryHistory)
        }
    }

    private func append(_ value: Double, to values: inout [Double]) {
        values.append(value)
        if values.count > 30 { values.removeFirst(values.count - 30) }
    }
}

private func counterDelta(from previous: UInt32, to current: UInt32) -> UInt32? {
    if current >= previous { return current - previous }
    // A falling counter usually means an interface was reset. Treat only a
    // near-boundary change as 32-bit rollover, and suppress other spikes.
    let margin: UInt32 = 268_435_456
    guard previous > UInt32.max - margin, current < margin else { return nil }
    return current &- previous
}

private func readKernelMemoryPressure() -> MemoryPressureLevel {
    var value: Int32 = 0
    var size = MemoryLayout<Int32>.size
    guard sysctlbyname("kern.memorystatus_vm_pressure_level", &value, &size, nil, 0) == 0,
          size == MemoryLayout<Int32>.size else { return .unknown }
    switch value {
    case 1: return .normal
    case 2: return .warning
    case 4: return .critical
    default: return .unknown
    }
}

private struct CPUTicks {
    let user: UInt32
    let system: UInt32
    let idle: UInt32
    let nice: UInt32
}

private func readCPUTicks() -> CPUTicks? {
    var info = host_cpu_load_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
    let host = mach_host_self()
    defer { mach_port_deallocate(mach_task_self_, host) }
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
        }
    }
    guard result == KERN_SUCCESS else { return nil }
    return .init(user: info.cpu_ticks.0, system: info.cpu_ticks.1,
                 idle: info.cpu_ticks.2, nice: info.cpu_ticks.3)
}

private struct MemoryReading {
    let total: UInt64
    let used: UInt64
    let available: UInt64
    let pressure: MemoryPressureEstimate
}

private func readMemory() -> MemoryReading {
    let total = ProcessInfo.processInfo.physicalMemory
    var stats = vm_statistics64_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
    let host = mach_host_self()
    defer { mach_port_deallocate(mach_task_self_, host) }
    let result = withUnsafeMutablePointer(to: &stats) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            host_statistics64(host, HOST_VM_INFO64, $0, &count)
        }
    }
    guard result == KERN_SUCCESS, total > 0 else {
        return .init(total: total, used: 0, available: 0, pressure: .unknown)
    }
    let pageSize = UInt64(vm_kernel_page_size)
    let usedPages = UInt64(stats.active_count) + UInt64(stats.wire_count)
        + UInt64(stats.compressor_page_count)
    let used = min(total, usedPages * pageSize)
    let available = total - used
    let ratio = Double(available) / Double(total)
    let pressure: MemoryPressureEstimate = ratio < 0.1 ? .critical : ratio < 0.25 ? .elevated : .normal
    return .init(total: total, used: used, available: available, pressure: pressure)
}

private func readDisk() -> (total: UInt64?, available: UInt64?) {
    guard let values = try? URL(fileURLWithPath: "/", isDirectory: true)
        .resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]) else {
        return (nil, nil)
    }
    return (values.volumeTotalCapacity.map(UInt64.init),
            values.volumeAvailableCapacityForImportantUsage.map(UInt64.init))
}

private struct NetworkCounters {
    let received: UInt32
    let sent: UInt32
}

private func readNetwork() -> [String: NetworkCounters] {
    var first: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&first) == 0, let first else { return [:] }
    defer { freeifaddrs(first) }
    var result: [String: NetworkCounters] = [:]
    var pointer: UnsafeMutablePointer<ifaddrs>? = first
    while let current = pointer {
        let value = current.pointee
        pointer = value.ifa_next
        guard let address = value.ifa_addr, address.pointee.sa_family == UInt8(AF_LINK),
              value.ifa_flags & UInt32(IFF_UP) != 0,
              value.ifa_flags & UInt32(IFF_LOOPBACK) == 0,
              let data = value.ifa_data else { continue }
        let name = String(cString: value.ifa_name)
        // Hardware-facing interfaces use enN. Summing utun/bridge alongside
        // enN counts the same VPN or bridged traffic twice.
        let suffix = name.dropFirst(2)
        guard name.hasPrefix("en"), !suffix.isEmpty, suffix.allSatisfy(\.isNumber) else { continue }
        let counters = data.assumingMemoryBound(to: if_data.self).pointee
        result[name] = .init(received: counters.ifi_ibytes, sent: counters.ifi_obytes)
    }
    return result
}

private func readBattery() -> (percent: Double?, charging: Bool?) {
    guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
          let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else {
        return (nil, nil)
    }
    for source in sources {
        guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
              let current = description[kIOPSCurrentCapacityKey] as? Int,
              let maximum = description[kIOPSMaxCapacityKey] as? Int,
              maximum > 0 else { continue }
        let charging = description[kIOPSIsChargingKey] as? Bool
        return (min(100, max(0, 100 * Double(current) / Double(maximum))), charging)
    }
    return (nil, nil)
}

private func readGPUUtilization() -> Double? {
    guard let matching = IOServiceMatching("IOAccelerator") else { return nil }
    var iterator: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
        return nil
    }
    defer { IOObjectRelease(iterator) }
    var readings: [Double] = []
    while case let service = IOIteratorNext(iterator), service != 0 {
        defer { IOObjectRelease(service) }
        guard let property = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString,
                                                             kCFAllocatorDefault, 0)?.takeRetainedValue(),
              let statistics = property as? [String: Any],
              let number = statistics["Device Utilization %"] as? NSNumber else { continue }
        let value = number.doubleValue
        if value.isFinite, (0...100).contains(value) { readings.append(value) }
    }
    return readings.max()
}
