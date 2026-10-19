import AppKit
import IOKit
import LauncherCore

/// CPU, memory, disk, GPU, temperature and battery, for the `stats` keyword.
final class SystemStats {
    static let keyword = "stats"

    // MARK: CPU (mach host_processor_info, sampled between calls)

    private var lastTicks: (user: UInt64, system: UInt64, idle: UInt64, nice: UInt64)?

    private func cpuTicks() -> (UInt64, UInt64, UInt64, UInt64)? {
        var count: mach_msg_type_number_t = 0
        var info: processor_info_array_t?
        var n: natural_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &n, &info, &count) == KERN_SUCCESS, let info else { return nil }
        defer { vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(count) * vm_size_t(MemoryLayout<integer_t>.size)) }
        var u: UInt64 = 0, s: UInt64 = 0, i: UInt64 = 0, nc: UInt64 = 0
        for c in 0..<Int(n) {
            let base = c * Int(CPU_STATE_MAX)
            u += UInt64(info[base + Int(CPU_STATE_USER)])
            s += UInt64(info[base + Int(CPU_STATE_SYSTEM)])
            i += UInt64(info[base + Int(CPU_STATE_IDLE)])
            nc += UInt64(info[base + Int(CPU_STATE_NICE)])
        }
        return (u, s, i, nc)
    }

    /// Percent busy since the previous call; nil on the first call.
    func cpuPercent() -> Double? {
        guard let now = cpuTicks() else { return nil }
        defer { lastTicks = now }
        guard let last = lastTicks else { return nil }
        let busy = Double((now.0 - last.0) + (now.1 - last.1) + (now.3 - last.3))
        let total = busy + Double(now.2 - last.2)
        return total > 0 ? busy / total * 100 : nil
    }

    var loadAverage: Double {
        var l = [Double](repeating: 0, count: 3)
        getloadavg(&l, 3)
        return l[0]
    }

    // MARK: Memory

    struct Memory { var used: UInt64; var total: UInt64; var compressed: UInt64; var pressure: String }

    func memory() -> Memory {
        let total = ProcessInfo.processInfo.physicalMemory
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let ok = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        } == KERN_SUCCESS
        let page = UInt64(vm_kernel_page_size)
        let used = ok ? (UInt64(stats.active_count) + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * page : 0
        let compressed = ok ? UInt64(stats.compressor_page_count) * page : 0
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        sysctlbyname("kern.memorystatus_level", &level, &size, nil, 0)   // percent of memory free of pressure
        let pressure = level >= 40 ? "normal" : level >= 20 ? "warning" : "critical"
        return Memory(used: used, total: total, compressed: compressed, pressure: pressure)
    }

    // MARK: Disk

    func disk() -> (free: Int64, total: Int64)? {
        let url = URL(fileURLWithPath: "/")
        guard let v = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]),
              let free = v.volumeAvailableCapacityForImportantUsage, let total = v.volumeTotalCapacity else { return nil }
        return (free, Int64(total))
    }

    // MARK: GPU (IOAccelerator performance statistics)

    func gpuPercent() -> Int? {
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iter) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iter) }
        var best: Int?
        while case let entry = IOIteratorNext(iter), entry != 0 {
            defer { IOObjectRelease(entry) }
            if let props = IORegistryEntryCreateCFProperty(entry, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any] {
                if let v = props["Device Utilization %"] as? Int ?? props["GPU Activity(%)"] as? Int { best = max(best ?? 0, v) }
            }
        }
        return best
    }

    // MARK: Temperature (HID sensor services, no root needed on Apple silicon)

    private typealias CreateFn = @convention(c) (CFAllocator?) -> Unmanaged<CFTypeRef>?
    private typealias SetMatchingFn = @convention(c) (CFTypeRef, CFDictionary) -> Void
    private typealias CopyServicesFn = @convention(c) (CFTypeRef) -> Unmanaged<CFArray>?
    private typealias CopyPropFn = @convention(c) (CFTypeRef, CFString) -> Unmanaged<CFTypeRef>?
    private typealias CopyEventFn = @convention(c) (CFTypeRef, Int64, Int32, Int64) -> Unmanaged<CFTypeRef>?
    private typealias GetFloatFn = @convention(c) (CFTypeRef, Int32) -> Double

    private lazy var hid: (client: CFTypeRef, copyServices: CopyServicesFn, copyProp: CopyPropFn, copyEvent: CopyEventFn, getFloat: GetFloatFn)? = {
        guard let h = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW) else { return nil }
        func sym<T>(_ n: String, _ t: T.Type) -> T? { dlsym(h, n).map { unsafeBitCast($0, to: t) } }
        guard let create = sym("IOHIDEventSystemClientCreate", CreateFn.self),
              let setMatching = sym("IOHIDEventSystemClientSetMatching", SetMatchingFn.self),
              let copyServices = sym("IOHIDEventSystemClientCopyServices", CopyServicesFn.self),
              let copyProp = sym("IOHIDServiceClientCopyProperty", CopyPropFn.self),
              let copyEvent = sym("IOHIDServiceClientCopyEvent", CopyEventFn.self),
              let getFloat = sym("IOHIDEventGetFloatValue", GetFloatFn.self),
              let client = create(kCFAllocatorDefault)?.takeRetainedValue() else { return nil }
        setMatching(client, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary)   // temperature sensors
        return (client, copyServices, copyProp, copyEvent, getFloat)
    }()

    struct Temps { var cpu: Double?; var gpu: Double?; var hottest: (String, Double)? }

    func temperatures() -> Temps {
        guard let hid, let services = hid.copyServices(hid.client)?.takeRetainedValue() as? [CFTypeRef] else { return Temps() }
        var cpu: [Double] = [], gpu: [Double] = [], hottest: (String, Double)?
        for s in services {
            guard let name = hid.copyProp(s, "Product" as CFString)?.takeRetainedValue() as? String,
                  let ev = hid.copyEvent(s, 15, 0, 0)?.takeRetainedValue() else { continue }
            let v = hid.getFloat(ev, 15 << 16)
            guard v > 0, v < 130 else { continue }
            let n = name.lowercased()
            if n.contains("tdie") || n.contains("acc") || n.contains("cpu") { cpu.append(v) }
            if n.contains("gpu") { gpu.append(v) }
            if hottest == nil || v > hottest!.1 { hottest = (name, v) }
        }
        return Temps(cpu: cpu.max(), gpu: gpu.max(), hottest: hottest)
    }

    // MARK: Battery

    func battery() -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = ["-g", "batt"]
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        try? p.run(); p.waitUntilExit()
        let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard let line = text.split(separator: "\n").first(where: { $0.contains("%") }) else { return nil }
        // "-InternalBattery-0 (id=...)	87%; charging; 0:53 remaining present: true"
        let parts = line.split(separator: "\t").last?.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) } ?? []
        guard parts.count >= 2 else { return nil }
        var s = "\(parts[0]) · \(parts[1])"
        if parts.count >= 3, parts[2].contains("remaining"), !parts[2].contains("(no estimate)") {
            s += " · " + parts[2].replacingOccurrences(of: " present: true", with: "")
        }
        return s
    }

    // MARK: Formatting

    private static func gb(_ bytes: UInt64) -> String { String(format: "%.1f GB", Double(bytes) / 1_073_741_824) }
    private static func gb(_ bytes: Int64) -> String {
        bytes >= 1_000_000_000_000 ? String(format: "%.2f TB", Double(bytes) / 1e12) : String(format: "%.0f GB", Double(bytes) / 1e9)
    }
    private static func deg(_ v: Double?) -> String { v.map { String(format: "%.0f °C", $0) } ?? "—" }

    // MARK: Results

    /// One reading of every sensor. It takes about 200 ms (`pmset` and the HID services are
    /// the slow parts), so it is made off the main thread.
    private struct Snapshot {
        var cpu: Double?; var load: Double; var gpu: Int?; var memory: Memory
        var disk: (free: Int64, total: Int64)?; var temps: Temps; var battery: String?
    }

    // Younger than the 2 s tick of `live`, so each tick starts a new reading.
    private lazy var snapshot = Cached(maxAge: 1) { [unowned self] in
        Snapshot(cpu: cpuPercent(), load: loadAverage, gpu: gpuPercent(), memory: memory(),
                 disk: disk(), temps: temperatures(), battery: battery())
    }

    func results(refresh: @escaping () -> Void) -> [Result] {
        guard let now = snapshot.get(refresh: refresh) else {
            return [Result(id: "stats:loading", title: "Reading the sensors…", subtitle: "",
                           icon: IconLoader.shared.icon(forSpec: "sf:cpu"), action: .none)]
        }
        let monitor = "/System/Applications/Utilities/Activity Monitor.app"
        let open: ResultAction = .openPath(monitor)
        let temps = now.temps
        let thermal: String = {
            switch ProcessInfo.processInfo.thermalState {
            case .nominal: return "thermal state nominal"
            case .fair: return "thermal state fair"
            case .serious: return "thermal state serious"
            case .critical: return "thermal state critical"
            @unknown default: return ""
            }
        }()

        var rows: [Result] = []
        let cpu = now.cpu
        let cores = ProcessInfo.processInfo.activeProcessorCount
        rows.append(Result(id: "stats:cpu", title: "CPU " + (cpu.map { String(format: "%.0f%%", $0) } ?? "measuring…"),
                           subtitle: "\(cores) cores · load \(String(format: "%.1f", now.load)) · \(Self.deg(temps.cpu))",
                           icon: IconLoader.shared.icon(forSpec: "sf:cpu"), action: open))

        if let g = now.gpu {
            rows.append(Result(id: "stats:gpu", title: "GPU \(g)%", subtitle: temps.gpu.map { "GPU \(Self.deg($0))" } ?? "Apple GPU",
                               icon: IconLoader.shared.icon(forSpec: "sf:rectangle.3.group"), action: open))
        }

        let m = now.memory
        rows.append(Result(id: "stats:mem", title: "Memory \(Self.gb(m.used)) of \(Self.gb(m.total))",
                           subtitle: "pressure \(m.pressure) · \(Self.gb(m.compressed)) compressed",
                           icon: IconLoader.shared.icon(forSpec: "sf:memorychip"), action: open))

        if let d = now.disk {
            let pct = Double(d.total - d.free) / Double(d.total) * 100
            rows.append(Result(id: "stats:disk", title: "Disk \(Self.gb(d.free)) free of \(Self.gb(d.total))",
                               subtitle: String(format: "%.0f%% used · Macintosh HD", pct),
                               icon: IconLoader.shared.icon(forSpec: "sf:internaldrive"), action: open))
        }

        rows.append(Result(id: "stats:temp", title: "Temperature \(Self.deg(temps.hottest?.1))",
                           subtitle: [temps.hottest.map { "hottest: \($0.0)" }, thermal].compactMap { $0 }.joined(separator: " · "),
                           icon: IconLoader.shared.icon(forSpec: "sf:thermometer.medium"), action: open))

        if let b = now.battery {
            rows.append(Result(id: "stats:batt", title: "Battery " + b, subtitle: "Return opens Activity Monitor",
                               icon: IconLoader.shared.icon(forSpec: "sf:battery.75percent"), action: open))
        }
        return rows
    }
}

extension SystemStats {
    var command: KeaCommand {
        KeaCommand(id: "stats", name: "System Stats", keywords: [Self.keyword],
                   help: [.init(keyword: "stats", summary: "Live CPU, GPU, memory, disk, temperature, battery", example: "stats")],
                   // The numbers refresh every 2 s for as long as the list is on screen.
                   live: (2, { true }),
                   results: { [unowned self] ctx in results(refresh: ctx.refresh) })
    }
}
