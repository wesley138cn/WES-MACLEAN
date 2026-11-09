import Foundation

struct ProcessSample {
    let pid: Int32
    let parent: Int32
    let residentBytes: UInt64
    let executable: String
}

struct AppProcessGroup {
    let pid: Int32
    let name: String
    let url: URL
}

struct AppMemoryUsage {
    var bytes: UInt64 = 0
    var count = 0
}

enum ProcessMemory {
    static func parse(_ text: String) -> [ProcessSample] {
        text.split(separator: "\n").compactMap { line in
            let fields = line.split(maxSplits: 3, whereSeparator: \.isWhitespace)
            guard fields.count == 4, let pid = Int32(fields[0]), pid > 0,
                  let parent = Int32(fields[1]), let kb = UInt64(fields[2]),
                  kb <= UInt64.max / 1024 else { return nil }
            return ProcessSample(pid: pid, parent: parent, residentBytes: kb * 1024, executable: String(fields[3]))
        }
    }

    /// Each PID belongs to at most one app. Bundle paths also catch reparented helpers.
    static func aggregate(_ processes: [ProcessSample], apps: [AppProcessGroup]) -> [String: AppMemoryUsage] {
        let roots = Dictionary(apps.map { ($0.pid, $0.url.path) }, uniquingKeysWith: { a, _ in a })
        let byPID = Dictionary(processes.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        let paths = Set(apps.map { $0.url.path }).sorted { $0.count > $1.count }
        var result: [String: AppMemoryUsage] = [:]
        for process in byPID.values {
            var owner = roots[process.pid]
            if owner == nil { owner = paths.first { process.executable.hasPrefix($0 + "/") } }
            if owner == nil {
                var visited: Set<Int32> = [process.pid]
                var parent = process.parent
                while parent > 1 && visited.insert(parent).inserted {
                    if let root = roots[parent] { owner = root; break }
                    guard let ancestor = byPID[parent] else { break }
                    parent = ancestor.parent
                }
            }
            if let owner {
                var usage = result[owner, default: AppMemoryUsage()]
                usage.bytes += process.residentBytes
                usage.count += 1
                result[owner] = usage
            }
        }
        return result
    }

    static func sample(apps: [AppProcessGroup]) throws -> [String: AppMemoryUsage] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,ppid=,rss=,comm="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "ProcessMemory", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "读取进程失败，请重试"])
        }
        return aggregate(parse(String(decoding: data, as: UTF8.self)), apps: apps)
    }
}
