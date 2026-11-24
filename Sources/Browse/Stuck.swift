import Darwin
import WebKit

/// A page process still running flat out after its tab let it go.
///
/// Closing or sleeping a tab drops its view, and WebKit then asks the page's
/// process to wind down. A process whose main thread never comes back to
/// hear that keeps going with no tab left to show it. WebKit's accessibility
/// tree update can loop like that for good once anything on the Mac reads
/// the screen through Accessibility (Siri, 1Password, a window manager, an
/// agent): Safari does the same on the same pages (FB25656366), so the loop
/// itself waits on Apple. What browse can do is not leave it burning a core
/// with nothing left showing it.
///
/// Ten seconds after the view goes, the process is inspected once. Only one
/// that spent most of that time on the CPU, is still a WebKit WebContent
/// process, has the same start timestamp (so PID reuse is immune), and is no
/// longer used by any live view (nor by any extension page) is ended.
@MainActor
enum Stuck {
    /// Time for a healthy page to wind down after its view is gone.
    static let wait: TimeInterval = 10
    /// Share of one core that counts as stuck over `wait`.
    static let busy = 0.8

    private static let key = "_webProcessIdentifier"

    static func watch(_ web: WKWebView) {
        if #available(macOS 15.4, *) {
            if let scheme = web.url?.scheme?.lowercased(),
               scheme == Extensions.scheme || scheme == Extensions.formerScheme {
                return
            }
            if Extensions.shared.contexts.values.contains(where: {
                $0.webViewConfiguration?.userContentController === web.configuration.userContentController
            }) {
                return
            }
        }
        guard let pid = process(of: web), let born = started(pid), let start = cpu(pid) else { return }
        weak let gone = web
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
            MainActor.assumeIsolated {
                guard let end = cpu(pid), end >= start,
                      Double(end - start) / 1e9 >= wait * busy,
                      isPage(pid) else { return }
                let shared = Web.pages.allObjects.contains { $0 !== gone && process(of: $0) == pid }
                guard !shared else { return }
                // Guard against PID reuse between view teardown and inspection.
                guard started(pid) == born else { return }
                kill(pid, SIGKILL)
            }
        }
    }

    private static func process(of web: WKWebView) -> pid_t? {
        guard web.responds(to: NSSelectorFromString(key)),
              let pid = web.value(forKey: key) as? Int, pid > 0 else { return nil }
        return pid_t(pid)
    }

    /// CPU time the process has used, in nanoseconds (converting Apple silicon Mach ticks).
    private static func cpu(_ pid: pid_t) -> UInt64? {
        var usage = rusage_info_v2()
        let read = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V2, $0)
            }
        }
        guard read == 0 else { return nil }
        var base = mach_timebase_info_data_t()
        mach_timebase_info(&base)
        guard base.denom > 0 else { return nil }
        let ticks = usage.ri_user_time &+ usage.ri_system_time
        return ticks.multipliedReportingOverflow(by: UInt64(base.numer)).partialValue / UInt64(base.denom)
    }

    /// Process start timestamp in microseconds, identifying a specific instance alongside its PID.
    private static func started(_ pid: pid_t) -> UInt64? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return info.pbi_start_tvsec &* 1_000_000 &+ info.pbi_start_tvusec
    }

    /// True only for a WebKit WebContent worker process.
    private static func isPage(_ pid: pid_t) -> Bool {
        var path = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &path, UInt32(path.count))
        guard length > 0 else { return false }
        return String(decoding: path.prefix(Int(length)), as: UTF8.self).hasSuffix("/com.apple.WebKit.WebContent")
    }
}
