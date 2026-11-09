import Foundation
import IOKit

struct FanReading: Equatable {
    let index: Int
    let rpm: Double?
}
struct FanSnapshot {
    /// nil: count unavailable; zero: SMC or a verified hardware model reports no fans.
    let count: Int?
    let readings: [FanReading]
    static let unavailable = FanSnapshot(count: nil, readings: [])
    var display: String {
        guard let count else { return "未提供" }
        if count == 0 { return "无风扇" }
        return readings.map { $0.rpm.map { String(format: "%.0f RPM", $0) } ?? "— RPM" }.joined(separator: " / ")
    }
}

/// Read-only AppleSMC transport. Only key-info (9) and read-bytes (5)
/// commands are admitted. No fan mode, minimum, target or write commands.
final class FanSensor {
    private var connection: io_connect_t = 0
    // Explicitly verified fanless MacBook Air models (M1 and M4).
    // https://support.apple.com/102869 and Apple Newsroom 2025-03-05.
    static func isKnownFanless(_ model: String) -> Bool { ["MacBookAir10,1", "Mac16,12", "Mac16,13"].contains(model) }
    private let model = FanSensor.modelIdentifier()
    private static func modelIdentifier() -> String {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0 else { return "" }
        var data = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &data, &size, nil, 0) == 0 else { return "" }
        return String(cString: data)
    }
    static func temperatureKeys(for model: String) -> [String] {
        // TCHP was read on M1 Air hardware. Keep this mapping model-specific.
        // SEN is one SMC sensor, not a CPU package or whole-machine average.
        model == "MacBookAir10,1" ? ["TCHP", "TC0P"] : ["Tp09", "TC0P"]
    }
    static func temperature(model: String, readValue: (String) -> Double?) -> Double? {
        for key in temperatureKeys(for: model) {
            if let value = readValue(key), value.isFinite, (0...125).contains(value) { return value }
        }
        return nil
    }
    func temperature() -> Double? {
        Self.temperature(model: model) { key in
            guard let value = read(key) else { return nil }
            return Self.decode(value.bytes, type: value.type)
        }
    }
    init() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }
        if IOServiceOpen(service, mach_task_self_, 0, &connection) != KERN_SUCCESS { connection = 0 }
    }
    deinit { if connection != 0 { IOServiceClose(connection) } }
    func sample() -> FanSnapshot {
        if Self.isKnownFanless(model) { return FanSnapshot(count: 0, readings: []) }
        guard let countValue = read("FNum"), let value = Self.decode(countValue.bytes, type: countValue.type), value >= 0, value <= 16, value.rounded() == value else { return .unavailable }
        let count = Int(value)
        let fans = (0..<count).map { i -> FanReading in
            guard let data = read("F\(String(i, radix: 16, uppercase: true))Ac"), let rpm = Self.decode(data.bytes, type: data.type), rpm.isFinite, (0...30_000).contains(rpm) else { return FanReading(index: i, rpm: nil) }
            return FanReading(index: i, rpm: rpm)
        }
        return FanSnapshot(count: count, readings: fans)
    }
    private func read(_ key: String) -> (bytes: [UInt8], type: String)? {
        guard connection != 0, key.utf8.count == 4 else { return nil }
        let keyValue = key.utf8.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard let info = call(key: keyValue, command: 9, size: 0) else { return nil }
        let size = Self.word(info, at: 28)
        let typeValue = Self.word(info, at: 32)
        let type = String(bytes: [UInt8((typeValue >> 24) & 255), UInt8((typeValue >> 16) & 255), UInt8((typeValue >> 8) & 255), UInt8(typeValue & 255)], encoding: .ascii) ?? ""
        guard (1...32).contains(size), let value = call(key: keyValue, command: 5, size: size) else { return nil }
        return (Array(value[48..<(48 + Int(size))]), type)
    }
    private func call(key: UInt32, command: UInt8, size: UInt32) -> [UInt8]? {
        guard command == 9 || command == 5 else { return nil }
        // Fixed AppleSMC user-client ABI: 80-byte SMCKeyData_t.
        var input = [UInt8](repeating: 0, count: 80)
        Self.put(key, in: &input, at: 0); Self.put(size, in: &input, at: 28)
        input[42] = command
        var output = [UInt8](repeating: 0, count: 80)
        var outputSize = output.count
        let result = input.withUnsafeBytes { source in
            output.withUnsafeMutableBytes { destination in
                IOConnectCallStructMethod(connection, 2, source.baseAddress, source.count, destination.baseAddress, &outputSize)
            }
        }
        guard result == KERN_SUCCESS, outputSize == 80, output[40] == 0 else { return nil }
        return output
    }
    private static func put(_ value: UInt32, in data: inout [UInt8], at offset: Int) {
        for i in 0..<4 { data[offset + i] = UInt8((value >> (i * 8)) & 255) }
    }
    private static func word(_ data: [UInt8], at offset: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 | (UInt32(data[offset + $1]) << ($1 * 8)) }
    }
    static func decode(_ data: [UInt8], type: String) -> Double? {
        switch type {
        case "ui8 ": return data.first.map(Double.init)
        case "ui16": guard data.count >= 2 else { return nil }; return Double(UInt16(data[0]) << 8 | UInt16(data[1]))
        case "ui32": guard data.count >= 4 else { return nil }; return Double(data.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
        case "sp78": guard data.count >= 2 else { return nil }; return Double(Int16(bitPattern: UInt16(data[0]) << 8 | UInt16(data[1]))) / 256
        case "fpe2": guard data.count >= 2 else { return nil }; return Double(UInt16(data[0]) << 8 | UInt16(data[1])) / 4
        case "flt ":
            guard data.count >= 4 else { return nil }
            let f = Float(bitPattern: word(data, at: 0))
            return f.isFinite ? Double(f) : nil
        default: return nil
        }
    }
}
