import Darwin
import Foundation

/// Lightweight sysctl helpers used to identify what is running in a terminal session.
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

    /// Current working directory of a process. Unlike the shell-reported pwd
    /// (OSC 7), this follows a process that changes directory on its own,
    /// e.g. an agent switching into a git worktree.
    static func currentDirectory(pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.stride)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: &info.pvi_cdir.vip_path) { raw in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
        return path.isEmpty ? nil : path
    }
}
