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
