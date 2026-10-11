import Darwin
import Foundation

/// Lightweight libproc/sysctl helpers used to identify what is running in a
/// terminal session and whether it is actively doing work.
enum ProcessInspector {
    /// Arguments of a process (argv), read via KERN_PROCARGS2. Returns an empty
    /// array if the process is gone or not inspectable.
    static func arguments(pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }

        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return [] }

        // Layout: argc (Int32), exec path, NUL padding, argv[0..argc), envp...
        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        var index = MemoryLayout<Int32>.size

        // Skip the executable path and the NUL padding after it.
        while index < size && buffer[index] != 0 { index += 1 }
        while index < size && buffer[index] == 0 { index += 1 }

        var args: [String] = []
        var start = index
        while index < size && args.count < Int(argc) {
            if buffer[index] == 0 {
                args.append(String(bytes: buffer[start..<index], encoding: .utf8) ?? "")
                start = index + 1
            }
            index += 1
        }
        return args
    }

    /// Short process name (as shown by `ps -c`). Uses KERN_PROC_PID rather than
    /// proc_name because it also works for processes owned by other users
    /// (e.g. setuid tools like `top`).
    static func name(pid: pid_t) -> String? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let name = withUnsafeBytes(of: &info.kp_proc.p_comm) { raw in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
        return name.isEmpty ? nil : name
    }

    /// Total CPU time (user + system) in nanoseconds consumed by every process
    /// in a process group. Tools spawned by an agent normally live in the agent's
    /// process group, so this captures "the agent is running a build" too.
    static func cpuTimeNanos(processGroup pgid: pid_t) -> UInt64 {
        var pids = [pid_t](repeating: 0, count: 256)
        // Unlike proc_listpids, this returns the number of pids (not bytes).
        let found = proc_listpgrppids(pgid, &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        let count = min(max(0, Int(found)), pids.count)
        let members = count > 0 ? Array(pids.prefix(count)) : [pgid]
        return members.reduce(0) { $0 + cpuTimeNanos(pid: $1) }
    }

    static func cpuTimeNanos(pid: pid_t) -> UInt64 {
        var info = rusage_info_v2()
        let result = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V2, $0)
            }
        }
        guard result == 0 else { return 0 }
        return machToNanos(info.ri_user_time + info.ri_system_time)
    }

    /// rusage times are reported in mach absolute time units, which are not
    /// nanoseconds on Apple Silicon.
    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    private static func machToNanos(_ value: UInt64) -> UInt64 {
        value * UInt64(timebase.numer) / UInt64(max(timebase.denom, 1))
    }
}
