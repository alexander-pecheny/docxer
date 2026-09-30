import AppKit

/// Logs startup and open times to stderr when launched with `-DocxerTiming YES`.
enum Timing {
    static let enabled = UserDefaults.standard.bool(forKey: "DocxerTiming")

    static var processStart: Date {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        sysctl(&mib, 4, &info, &size, nil, 0)
        let tv = info.kp_proc.p_starttime
        return Date(timeIntervalSince1970: Double(tv.tv_sec) + Double(tv.tv_usec) / 1e6)
    }

    static func log(_ what: String, since start: Date) {
        guard enabled else { return }
        FileHandle.standardError.write(String(format: "TIMING %@ %.1f ms\n", what, Date().timeIntervalSince(start) * 1000).data(using: .utf8)!)
    }
}
