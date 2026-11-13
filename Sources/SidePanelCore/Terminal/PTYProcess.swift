import Foundation
import CPTY
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

@inline(__always)
private func systemWrite(_ fd: Int32, _ buf: UnsafeRawPointer, _ count: Int) -> Int {
    #if canImport(Darwin)
    return Darwin.write(fd, buf, count)
    #else
    return Glibc.write(fd, buf, count)
    #endif
}

public enum PTYError: Error, CustomStringConvertible {
    case spawnFailed(errno: Int32)

    public var description: String {
        switch self {
        case .spawnFailed(let e): return "Could not start the shell: \(String(cString: strerror(e)))"
        }
    }
}

/// A child process attached to a pseudo-terminal.
///
/// Output is read on a private queue and handed to `onOutput` on `callbackQueue`.
/// Input is written on a private serial queue so large pastes never block the UI.
public final class PTYProcess {
    public let pid: pid_t
    public let executable: String
    private let masterFD: Int32
    private let readSource: DispatchSourceRead
    private let readQueue = DispatchQueue(label: "sidepanel.pty.read")
    private let writeQueue = DispatchQueue(label: "sidepanel.pty.write")
    private let callbackQueue: DispatchQueue
    private let stateLock = NSLock()
    private var closed = false
    private var started = false

    /// Raw bytes from the terminal.
    public var onOutput: ((Data) -> Void)?
    /// Called once with the exit code after the child has gone away.
    public var onExit: ((Int32) -> Void)?

    public init(executable: String,
                arguments: [String],
                environment: [String: String],
                workingDirectory: String?,
                columns: Int,
                rows: Int,
                callbackQueue: DispatchQueue = .main) throws {
        self.executable = executable
        self.callbackQueue = callbackQueue

        let argv = arguments.map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }

        var childPid: pid_t = 0
        let fd: Int32 = argv.withUnsafeBufferPointer { argvPtr in
            envp.withUnsafeBufferPointer { envPtr in
                sp_pty_spawn(executable,
                             argvPtr.baseAddress,
                             envPtr.baseAddress,
                             workingDirectory,
                             UInt16(clamping: rows),
                             UInt16(clamping: columns),
                             &childPid)
            }
        }
        guard fd >= 0 else { throw PTYError.spawnFailed(errno: errno) }

        self.masterFD = fd
        self.pid = childPid
        self.readSource = DispatchSource.makeReadSource(fileDescriptor: fd, queue: readQueue)
        readSource.setEventHandler { [weak self] in self?.drain() }
        readSource.setCancelHandler { [fd] in close(fd) }
    }

    /// Begins reading output. Call once, after `onOutput` / `onExit` are set,
    /// so that nothing the child prints early is lost.
    public func start() {
        stateLock.lock()
        let shouldStart = !started && !closed
        started = true
        stateLock.unlock()
        if shouldStart { readSource.resume() }
    }

    deinit {
        terminate()
    }

    private func drain() {
        var buffer = [UInt8](repeating: 0, count: 65_536)
        var collected = Data()
        while true {
            let n = buffer.withUnsafeMutableBytes { read(masterFD, $0.baseAddress, $0.count) }
            if n > 0 {
                collected.append(buffer, count: n)
                if collected.count >= 1 << 20 { break }
                continue
            }
            if n < 0 && (errno == EAGAIN || errno == EINTR) { break }
            // EOF or EIO: the slave side has been closed — the child is gone.
            if !collected.isEmpty { deliver(collected) }
            finish()
            return
        }
        if !collected.isEmpty { deliver(collected) }
    }

    private func deliver(_ data: Data) {
        callbackQueue.async { [weak self] in self?.onOutput?(data) }
    }

    private func finish() {
        stateLock.lock()
        let alreadyClosed = closed
        closed = true
        stateLock.unlock()
        guard !alreadyClosed else { return }
        stateLock.lock()
        let wasStarted = started
        started = true
        stateLock.unlock()
        // A suspended dispatch source must be resumed before it can be cancelled.
        if !wasStarted { readSource.resume() }
        readSource.cancel()
        let pid = self.pid
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let status = sp_pty_wait(pid)
            let code = status < 0 ? -1 : sp_pty_exit_code(status)
            self?.callbackQueue.async { self?.onExit?(code) }
        }
    }

    public var isRunning: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return !closed
    }

    public func write(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        writeQueue.async { [weak self] in
            guard let self, self.isRunning else { return }
            var offset = 0
            while offset < bytes.count {
                let n = bytes.withUnsafeBytes { raw -> Int in
                    systemWrite(self.masterFD, raw.baseAddress! + offset, raw.count - offset)
                }
                if n > 0 {
                    offset += n
                } else if n < 0 && (errno == EAGAIN || errno == EINTR) {
                    var pfd = pollfd(fd: self.masterFD, events: Int16(POLLOUT), revents: 0)
                    _ = poll(&pfd, 1, 1000)
                    if !self.isRunning { return }
                } else {
                    return
                }
            }
        }
    }

    public func write(_ string: String) {
        write(Array(string.utf8))
    }

    public func resize(columns: Int, rows: Int) {
        guard isRunning else { return }
        _ = sp_pty_resize(masterFD, UInt16(clamping: rows), UInt16(clamping: columns))
    }

    /// Name of the program currently in the foreground of this terminal.
    public var foregroundProcessName: String? {
        guard isRunning else { return nil }
        var buf = [CChar](repeating: 0, count: 256)
        guard sp_pty_foreground_name(masterFD, &buf, Int32(buf.count)) == 0 else { return nil }
        return String(cString: buf)
    }

    /// Working directory of the foreground process (falls back to the shell itself).
    public var currentDirectory: String? {
        guard isRunning else { return nil }
        var buf = [CChar](repeating: 0, count: 4096)
        if sp_process_cwd(pid, &buf, Int32(buf.count)) == 0 {
            return String(cString: buf)
        }
        return nil
    }

    /// Hangs up on the child's process group and releases the PTY.
    public func terminate() {
        stateLock.lock()
        let wasClosed = closed
        stateLock.unlock()
        guard !wasClosed else { return }
        kill(-pid, SIGHUP)
        kill(pid, SIGHUP)
        finish()
    }

    // MARK: Defaults

    /// The user's login shell from the password database, falling back to $SHELL.
    public static func defaultShell() -> String {
        if let pw = getpwuid(getuid()), let shell = pw.pointee.pw_shell {
            let s = String(cString: shell)
            if !s.isEmpty, FileManager.default.isExecutableFile(atPath: s) { return s }
        }
        if let s = ProcessInfo.processInfo.environment["SHELL"], FileManager.default.isExecutableFile(atPath: s) {
            return s
        }
        for candidate in ["/bin/zsh", "/bin/bash", "/bin/sh"] where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        return "/bin/sh"
    }

    public static func homeDirectory() -> String {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return String(cString: dir)
        }
        return NSHomeDirectory()
    }

    /// Environment for an interactive shell: the app's own environment plus
    /// terminal identification and a UTF-8 locale when none is configured.
    public static func shellEnvironment(base: [String: String] = ProcessInfo.processInfo.environment,
                                        programVersion: String = "1.0") -> [String: String] {
        var env = base
        for key in ["__CFBundleIdentifier", "XPC_SERVICE_NAME", "XPC_FLAGS", "TERM_SESSION_ID", "ITERM_SESSION_ID", "INSIDE_EMACS"] {
            env.removeValue(forKey: key)
        }
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "SidePanel"
        env["TERM_PROGRAM_VERSION"] = programVersion
        if env["LANG"] == nil && env["LC_ALL"] == nil && env["LC_CTYPE"] == nil {
            env["LANG"] = "en_US.UTF-8"
        }
        if env["HOME"] == nil { env["HOME"] = homeDirectory() }
        if env["PATH"] == nil { env["PATH"] = "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" }
        if let pw = getpwuid(getuid()), let name = pw.pointee.pw_name {
            env["USER"] = env["USER"] ?? String(cString: name)
            env["LOGNAME"] = env["LOGNAME"] ?? String(cString: name)
        }
        return env
    }

    /// Starts the user's shell as a login shell (argv[0] prefixed with "-").
    /// The returned process has not started reading yet: set callbacks, then call `start()`.
    public static func spawnLoginShell(columns: Int, rows: Int, workingDirectory: String? = nil,
                                       shell: String? = nil,
                                       callbackQueue: DispatchQueue = .main) throws -> PTYProcess {
        let path = shell ?? defaultShell()
        let name = (path as NSString).lastPathComponent
        let env = shellEnvironment()
        return try PTYProcess(executable: path,
                              arguments: ["-" + name],
                              environment: env,
                              workingDirectory: workingDirectory ?? homeDirectory(),
                              columns: columns,
                              rows: rows,
                              callbackQueue: callbackQueue)
    }
}
