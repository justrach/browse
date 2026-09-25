import AppKit
import IOKit
import Metal
import SwiftUI

/// Anonymous numbers about this Mac and the app on it, for the stats page at
/// `Stats.endpoint` — only when switched on, in Settings › Privacy, and off
/// until then.
///
/// Once a day, a report says: a random id made on this Mac (forgotten when
/// sharing is switched off, so switching it on again is a new Mac as far as
/// anyone can tell), the app and macOS versions, the chip, its CPU cores
/// (performance and efficiency), its GPU and GPU cores, memory, how much
/// memory the app itself holds, how many tabs are open and how many hold their
/// page, and the Mac's thermal state. No address, page, search, name, serial
/// number or anything typed. It goes over a session with no cookies and no
/// cache, and the server neither reads nor keeps the address it came from
/// (see analytics/).
@MainActor
final class Stats {
    static let shared = Stats()

    /// Where the reports go and the numbers can be seen. SEARCH_STATS_URL
    /// points elsewhere, for testing.
    static let endpoint = URL(string: ProcessInfo.processInfo.environment["SEARCH_STATS_URL"] ?? "https://search-codegraff-stats.rachpradhan.workers.dev")!

    private weak var browser: Browser?
    private var timer: Timer?
    private static let every: TimeInterval = 24 * 60 * 60

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.timeoutIntervalForRequest = 20
        return URLSession(configuration: config)
    }()

    func start(for browser: Browser) {
        self.browser = browser
        schedule()
    }

    /// Checked hourly while sharing is on — a Mac that sleeps through the day
    /// still sends once it wakes — and not at all while it is off.
    func schedule() {
        timer?.invalidate()
        timer = nil
        guard let browser, browser.prefs.shareStats else { return }
        let timer = Timer(timeInterval: 60 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sendIfDue() }
        }
        timer.tolerance = 10 * 60
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        // Not in the launch's way.
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in self?.sendIfDue() }
    }

    /// A report, if sharing is on and a day has passed since the last — or at
    /// once, when sharing has just been switched on.
    func sendIfDue(now: Bool = false) {
        guard let browser, browser.prefs.shareStats else { return }
        if !now, let last = Store.settings.object(forKey: "stats.sent") as? Date, Date().timeIntervalSince(last) < Stats.every - 600 { return }
        guard let body = try? JSONSerialization.data(withJSONObject: report(browser)) else { return }
        var request = URLRequest(url: Stats.endpoint.appendingPathComponent("v1/ping"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        Stats.session.dataTask(with: request) { _, response, _ in
            guard let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status) else { return }
            Task { @MainActor in Store.settings.set(Date(), forKey: "stats.sent") }
        }.resume()
    }

    /// Switched off: the id goes with it.
    static func forget() {
        Store.settings.removeObject(forKey: "stats.id")
        Store.settings.removeObject(forKey: "stats.sent")
    }

    private static var installID: String {
        if let id = Store.settings.string(forKey: "stats.id") { return id }
        let id = UUID().uuidString.lowercased()
        Store.settings.set(id, forKey: "stats.id")
        return id
    }

    /// Everything a report says, and nothing else.
    func report(_ browser: Browser, id: String? = nil) -> [String: Any] {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let tabs = browser.tabs.filter { !$0.bench }
        var cpu: [String: Any] = ["cores": Stats.number("hw.physicalcpu") ?? ProcessInfo.processInfo.processorCount]
        if let performance = Stats.number("hw.perflevel0.physicalcpu") { cpu["performance"] = performance }
        if let efficiency = Stats.number("hw.perflevel1.physicalcpu") { cpu["efficiency"] = efficiency }
        var gpu: [String: Any] = ["name": MTLCreateSystemDefaultDevice()?.name ?? "Unknown"]
        if let cores = Stats.gpuCores() { gpu["cores"] = cores }
        let thermal: String
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: thermal = "nominal"
        case .fair: thermal = "fair"
        case .serious: thermal = "serious"
        case .critical: thermal = "critical"
        @unknown default: thermal = "nominal"
        }
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "x86_64"
        #endif
        return [
            "id": id ?? Stats.installID,
            "app": Updater.version,
            "os": "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
            "chip": Stats.text("machdep.cpu.brand_string") ?? "Unknown",
            "arch": arch,
            "cpu": cpu,
            "gpu": gpu,
            "memory_gb": Int((Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824).rounded()),
            "app_mb": max(1, Stats.footprintMB()),
            "tabs": tabs.count,
            "awake": tabs.filter { $0.built != nil && !$0.asleep }.count,
            "thermal": thermal,
        ]
    }

    // MARK: - asking the Mac

    private static func text(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    private static func number(_ name: String) -> Int? {
        var value: Int64 = 0
        var size = MemoryLayout<Int64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return Int(value)
    }

    /// Apple silicon's GPU says how many cores it has in the I/O registry;
    /// an Intel Mac's doesn't, and the report leaves it out.
    private static func gpuCores() -> Int? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AGXAccelerator"), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var service = IOIteratorNext(iterator)
        while service != 0 {
            let cores = IORegistryEntryCreateCFProperty(service, "gpu-core-count" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Int
            IOObjectRelease(service)
            if let cores { return cores }
            service = IOIteratorNext(iterator)
        }
        return nil
    }

    /// The app's own memory as macOS counts it (Activity Monitor's "Memory").
    private static func footprintMB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint / 1_048_576) : 0
    }
}

/// Settings › Privacy: the switch, and both sides of what it sends.
struct StatsCard: View {
    @ObservedObject var browser: Browser
    @ObservedObject var prefs: Preferences

    var body: some View {
        Card {
            Line(
                "Share anonymous stats",
                "Once a day: this Mac's chip, CPU and GPU cores, memory and macOS version, how much memory the app uses and how many tabs are open. Under a random id made on this Mac — never your address, a page, or anything you typed"
            ) {
                Switch(on: Binding(
                    get: { prefs.shareStats },
                    set: { on in
                        prefs.shareStats = on
                        if on { Stats.shared.sendIfDue(now: true) } else { Stats.forget() }
                        Stats.shared.schedule()
                    }
                ))
            }
            Rule()
            Line("What is shared", "This Mac's report as it would be sent, and every Mac's put together") {
                HStack(spacing: 6) {
                    Pill("This Mac's") { showReport() }
                    Pill("Everyone's") { browser.open(Stats.endpoint, foreground: true) }
                }
            }
        }
    }

    /// The report, word for word, in a tab of its own. Nothing is sent to show it.
    private func showReport() {
        // With sharing off there is no id yet, and showing the report
        // mustn't make one.
        let report = Stats.shared.report(browser, id: prefs.shareStats ? nil : "(made when sharing is switched on)")
        guard let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8),
              let encoded = text.addingPercentEncoding(withAllowedCharacters: .alphanumerics),
              let url = URL(string: "data:text/plain;charset=utf-8,\(encoded)")
        else { return }
        browser.open(url, foreground: true)
    }
}
