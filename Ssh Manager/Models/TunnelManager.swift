import AppKit
import Darwin
import Foundation
import Observation

/// Owns saved tunnels and the ssh processes that keep them open.
///
/// Each running tunnel is its own `ssh -N` process (not multiplexed), so stopping one
/// never affects terminal sessions or file browsing on the same server.
@Observable
final class TunnelManager {
    enum Status: Equatable {
        case stopped
        case starting
        case running
        case failed(String)
    }

    private(set) var tunnels: [Tunnel] = []
    private(set) var statuses: [UUID: Status] = [:]
    var lastError: String?

    @ObservationIgnored private var processes: [UUID: Process] = [:]
    @ObservationIgnored private var stopping: Set<UUID> = []
    @ObservationIgnored private var pendingFailures: [UUID: String] = [:]
    @ObservationIgnored private var didAutoStart = false
    /// Set when tunnels.json is unreadable and couldn't be backed up, so it must not be overwritten.
    @ObservationIgnored private var isSavingBlocked = false
    @ObservationIgnored private var terminationObserver: NSObjectProtocol?

    private static var tunnelsFile: URL { SSHPaths.supportDirectory.appending(path: "tunnels.json") }
    private static var processesFile: URL { SSHPaths.supportDirectory.appending(path: "tunnel-processes.json") }

    init() {
        Self.stopOrphanedProcesses()
        load()
        // ssh children outlive the app unless we stop them explicitly.
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopAll() }
        }
    }

    func status(of tunnel: Tunnel) -> Status {
        statuses[tunnel.id] ?? .stopped
    }

    func isActive(_ tunnel: Tunnel) -> Bool {
        switch status(of: tunnel) {
        case .starting, .running: true
        case .stopped, .failed: false
        }
    }

    func tunnels(for serverID: UUID) -> [Tunnel] {
        tunnels.filter { $0.serverID == serverID }
    }

    // MARK: - Editing

    func upsert(_ tunnel: Tunnel) {
        if let index = tunnels.firstIndex(where: { $0.id == tunnel.id }) {
            tunnels[index] = tunnel
        } else {
            tunnels.append(tunnel)
        }
        save()
    }

    func delete(_ tunnel: Tunnel) {
        stop(tunnel)
        tunnels.removeAll { $0.id == tunnel.id }
        statuses[tunnel.id] = nil
        save()
    }

    // MARK: - Running

    func startAutomaticTunnels(using store: ServerStore) {
        guard !didAutoStart else { return }
        didAutoStart = true
        for tunnel in tunnels where tunnel.startAutomatically {
            start(tunnel, using: store)
        }
    }

    func start(_ tunnel: Tunnel, using store: ServerStore) {
        let id = tunnel.id
        guard processes[id] == nil else { return }
        guard let server = tunnel.serverID.flatMap(store.server(withID:)) else {
            statuses[id] = .failed("The server for this tunnel no longer exists.")
            return
        }
        if Self.isListening(port: tunnel.localPort) {
            statuses[id] = .failed("Port \(tunnel.localPort) is already in use on this Mac.")
            return
        }

        let errorURL = FileManager.default.temporaryDirectory.appending(path: "sshmgr-tunnel-\(id.uuidString).err")
        FileManager.default.createFile(atPath: errorURL.path, contents: nil)
        guard let errorHandle = try? FileHandle(forWritingTo: errorURL) else {
            statuses[id] = .failed("Couldn't create a log file for the tunnel.")
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: SSHPaths.ssh)
        process.arguments = ["-F", SSHPaths.configFile.path, "-N",
                             "-o", "ControlMaster=no", "-o", "ControlPath=none",
                             "-o", "ExitOnForwardFailure=yes"]
            + tunnel.forwardArguments + [server.alias]
        process.environment = ProcessInfo.processInfo.environment.merging(AskPass.environment(for: server)) { $1 }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorHandle
        process.terminationHandler = { [weak self] finished in
            let exitCode = finished.terminationStatus
            try? errorHandle.close()
            let message = (try? String(contentsOf: errorURL, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            try? FileManager.default.removeItem(at: errorURL)
            Task { @MainActor in
                self?.processDidExit(id, exitCode: exitCode, message: message)
            }
        }

        statuses[id] = .starting
        do {
            try process.run()
        } catch {
            statuses[id] = .failed(error.localizedDescription)
            return
        }
        processes[id] = process
        recordRunningProcesses()

        // Consider the tunnel up once its local port accepts connections.
        let port = tunnel.localPort
        Task {
            for _ in 0..<40 {
                try? await Task.sleep(for: .milliseconds(500))
                guard statuses[id] == .starting else { return }
                if await Self.checkListening(port: port) {
                    statuses[id] = .running
                    return
                }
            }
            if statuses[id] == .starting {
                pendingFailures[id] = "Timed out waiting for the tunnel to open."
                stop(tunnel)
            }
        }
    }

    func stop(_ tunnel: Tunnel) {
        guard let process = processes[tunnel.id] else {
            if case .failed = status(of: tunnel) { statuses[tunnel.id] = .stopped }
            return
        }
        stopping.insert(tunnel.id)
        process.terminate()
    }

    func stopAll() {
        for tunnel in tunnels { stop(tunnel) }
    }

    private func processDidExit(_ id: UUID, exitCode: Int32, message: String) {
        processes[id] = nil
        recordRunningProcesses()
        guard tunnels.contains(where: { $0.id == id }) else {
            stopping.remove(id)
            statuses[id] = nil
            return
        }
        if stopping.remove(id) != nil {
            statuses[id] = pendingFailures.removeValue(forKey: id).map(Status.failed) ?? .stopped
        } else {
            statuses[id] = .failed(message.isEmpty ? "The tunnel closed (exit code \(exitCode))." : message)
        }
    }

    // MARK: - Orphaned processes

    /// Identifies a tunnel's ssh process. The start time guards against the PID being reused.
    private struct ProcessRecord: Codable {
        let pid: Int32
        let startTime: UInt64
    }

    /// Stopping tunnels on quit doesn't happen after a crash or force quit, so the running
    /// ssh processes are recorded on disk and cleaned up on the next launch.
    private func recordRunningProcesses() {
        let records = processes.values.compactMap { process in
            Self.startTime(of: process.processIdentifier).map {
                ProcessRecord(pid: process.processIdentifier, startTime: $0)
            }
        }
        if records.isEmpty {
            try? FileManager.default.removeItem(at: Self.processesFile)
        } else if let data = try? JSONEncoder().encode(records) {
            try? data.write(to: Self.processesFile, options: .atomic)
        }
    }

    private static func stopOrphanedProcesses() {
        guard let data = try? Data(contentsOf: processesFile),
              let records = try? JSONDecoder().decode([ProcessRecord].self, from: data) else { return }
        for record in records where startTime(of: record.pid) == record.startTime && isSSH(record.pid) {
            kill(record.pid, SIGTERM)
        }
        try? FileManager.default.removeItem(at: processesFile)
    }

    nonisolated private static func startTime(of pid: Int32) -> UInt64? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec
    }

    nonisolated private static func isSSH(_ pid: Int32) -> Bool {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return false }
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
            == SSHPaths.ssh
    }

    // MARK: - Port check

    @concurrent
    private static func checkListening(port: Int) async -> Bool {
        isListening(port: port)
    }

    /// Whether something accepts TCP connections on 127.0.0.1:`port`.
    nonisolated private static func isListening(port: Int) -> Bool {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(clamping: port).bigEndian)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: Self.tunnelsFile) else { return }
        do {
            tunnels = try JSONDecoder().decode([Tunnel].self, from: data)
        } catch {
            // Keep the unreadable file so the next save doesn't silently replace it with an empty list.
            var message = "Couldn't read saved tunnels: \(error.localizedDescription)"
            if let backup = SSHPaths.backUpUnreadableFile(Self.tunnelsFile) {
                message += "\n\nThe original file was kept as “\(backup.lastPathComponent)”."
            } else {
                isSavingBlocked = true
                message += "\n\nChanges won't be saved until the file is fixed or removed."
            }
            lastError = message
        }
    }

    private func save() {
        guard !isSavingBlocked else { return }
        do {
            try FileManager.default.createDirectory(at: SSHPaths.supportDirectory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(tunnels).write(to: Self.tunnelsFile, options: .atomic)
        } catch {
            lastError = "Couldn't save tunnels: \(error.localizedDescription)"
        }
    }
}
