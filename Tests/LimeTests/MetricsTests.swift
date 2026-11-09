import Testing
import Darwin
@testable import Lime

@Test @MainActor
func systemSampleHasPlausibleBounds() {
    let monitor = SystemMonitor()
    monitor.refresh()
    usleep(50_000)
    monitor.refresh()

    let sample = monitor.snapshot
    #expect(sample.memoryTotalBytes > 0)
    #expect(sample.memoryUsedBytes <= sample.memoryTotalBytes)
    #expect(sample.memoryAvailableBytes <= sample.memoryTotalBytes)
    #expect(sample.memoryUsedBytes + sample.memoryAvailableBytes == sample.memoryTotalBytes)
    if let cpu = sample.cpuPercent {
        #expect((0...100).contains(cpu))
    }
    if let diskTotal = sample.diskTotalBytes,
       let available = sample.diskAvailableBytes {
        #expect(diskTotal > 0)
        #expect(available <= diskTotal)
    }
    if let battery = sample.batteryPercent {
        #expect((0...100).contains(battery))
    }
    if let gpu = sample.gpuPercent {
        #expect((0...100).contains(gpu))
    }
}

@Test @MainActor
func historyIsBounded() {
    let monitor = SystemMonitor()
    for _ in 0..<40 { monitor.refresh() }
    #expect(monitor.cpuHistory.count <= 30)
    #expect(monitor.memoryHistory.count <= 30)
}
