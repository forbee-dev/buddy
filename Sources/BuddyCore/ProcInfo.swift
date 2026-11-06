import Darwin

public enum ProcInfo {
    /// nil when the process does not exist (sysctl returns an empty record for unknown pids).
    private static func kinfo(_ pid: Int32) -> kinfo_proc? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0, info.kp_proc.p_pid == pid else { return nil }
        return info
    }

    private static func ttyName(_ info: kinfo_proc) -> String? {
        let dev = info.kp_eproc.e_tdev
        guard dev != -1, let name = devname(dev, S_IFCHR) else { return nil }
        let s = String(cString: name)
        return s == "??" ? nil : s
    }

    public static func parent(of pid: Int32) -> Int32? { info(of: pid)?.ppid }

    /// Controlling tty name, e.g. "ttys004".
    public static func tty(of pid: Int32) -> String? { info(of: pid)?.tty }

    /// Parent pid and tty in one sysctl.
    public static func info(of pid: Int32) -> (ppid: Int32?, tty: String?)? {
        guard let k = kinfo(pid) else { return nil }
        let ppid = k.kp_eproc.e_ppid
        return (ppid > 0 ? ppid : nil, ttyName(k))
    }

    public static func isAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    /// True if `root` is `pid` or one of its ancestors.
    public static func descends(_ pid: Int32, from root: Int32) -> Bool { ancestors(of: pid).contains(root) }

    /// pid, its parent, grandparent, ... up to launchd (exclusive).
    public static func ancestors(of pid: Int32, limit: Int = 32) -> [Int32] {
        var out: [Int32] = []
        var p: Int32? = pid
        while let cur = p, cur > 1, out.count < limit {
            out.append(cur)
            p = parent(of: cur)
        }
        return out
    }
}

extension ProcInfo {
    public struct Status: Sendable, Equatable {
        public var pgid: Int32
        public var tpgid: Int32
        public var stopped: Bool
        public init(pgid: Int32, tpgid: Int32, stopped: Bool) { self.pgid = pgid; self.tpgid = tpgid; self.stopped = stopped }
    }

    /// Process group, the tty's foreground group, and the stopped flag. nil if the process is gone.
    public static func status(of pid: Int32) -> Status? {
        guard let info = kinfo(pid) else { return nil }
        return Status(pgid: info.kp_eproc.e_pgid, tpgid: info.kp_eproc.e_tpgid, stopped: Int32(info.kp_proc.p_stat) == SSTOP)
    }
}

extension ProcInfo {
    public static func allPids() -> [Int32] {
        let n = proc_listallpids(nil, 0)
        guard n > 0 else { return [] }
        // Room for processes that start between the two calls.
        var pids = [Int32](repeating: 0, count: Int(n) + 64)
        let got = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        return got > 0 ? pids.prefix(Int(got)).filter { $0 > 0 } : []
    }

    /// Current directory; nil when the process is gone or belongs to another user.
    public static func cwd(of pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return path.isEmpty ? nil : path
    }

    /// The `keys` of the environment the process started with; nil when the kernel does not give it (another user's process).
    public static func environment(of pid: Int32, keys: Set<String>) -> [String: String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return nil }
        return parseEnvironment(Array(buf.prefix(size)), keys: keys)
    }

    /// KERN_PROCARGS2 layout: argc (Int32), the exec path, NUL padding, argc arguments, then KEY=VALUE strings up to an empty one.
    static func parseEnvironment(_ buf: [UInt8], keys: Set<String>) -> [String: String]? {
        guard buf.count >= 4 else { return nil }
        let argc = buf.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        var i = 4
        func next() -> String? {
            guard i < buf.count else { return nil }
            let start = i
            while i < buf.count, buf[i] != 0 { i += 1 }
            defer { i += 1 }
            return String(decoding: buf[start..<i], as: UTF8.self)
        }
        _ = next()
        while i < buf.count, buf[i] == 0 { i += 1 }
        for _ in 0..<max(argc, 0) {
            guard next() != nil else { return nil }
        }
        var env: [String: String] = [:]
        while let s = next(), !s.isEmpty {
            guard let eq = s.firstIndex(of: "="), keys.contains(String(s[..<eq])) else { continue }
            env[String(s[..<eq])] = String(s[s.index(after: eq)...])
        }
        return env
    }
}
