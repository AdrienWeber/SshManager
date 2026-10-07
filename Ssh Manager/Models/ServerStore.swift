import Foundation
import Observation

struct ServerGroup: Identifiable {
    let name: String
    let servers: [Server]
    var id: String { name }
}

/// Owns the saved servers, persists them as JSON, and keeps the generated ssh_config in sync.
@Observable
final class ServerStore {
    private(set) var servers: [Server] = []
    var lastError: String?
    /// Set when servers.json is unreadable and couldn't be backed up, so it must not be overwritten.
    @ObservationIgnored private var isSavingBlocked = false

    init() {
        load()
        writeConfig()
    }

    func server(withID id: UUID) -> Server? {
        servers.first { $0.id == id }
    }

    var groupNames: [String] {
        Array(Set(servers.map(\.group))).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    func groupedServers(matching query: String) -> [ServerGroup] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let filtered = trimmed.isEmpty ? servers : servers.filter {
            $0.name.localizedCaseInsensitiveContains(trimmed)
                || $0.host.localizedCaseInsensitiveContains(trimmed)
                || $0.group.localizedCaseInsensitiveContains(trimmed)
        }
        return Dictionary(grouping: filtered, by: \.group)
            .map { name, servers in
                ServerGroup(name: name, servers: servers.sorted {
                    $0.name.localizedStandardCompare($1.name) == .orderedAscending
                })
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Inserts or updates a server. `secret`: `nil` keeps the stored one, `""` deletes it.
    func upsert(_ server: Server, secret: String?) {
        if let index = servers.firstIndex(where: { $0.id == server.id }) {
            servers[index] = server
        } else {
            servers.append(server)
        }
        if let secret {
            if secret.isEmpty {
                KeychainStore.deleteSecret(for: server.id)
            } else {
                do { try KeychainStore.setSecret(secret, for: server.id) } catch {
                    lastError = error.localizedDescription
                }
            }
        }
        save()
    }

    func duplicate(_ server: Server) -> Server {
        var copy = server
        copy.id = UUID()
        copy.name += " Copy"
        copy.lastConnected = nil
        upsert(copy, secret: KeychainStore.secret(for: server.id))
        return copy
    }

    func delete(_ server: Server) {
        servers.removeAll { $0.id == server.id }
        KeychainStore.deleteSecret(for: server.id)
        save()
        Task { await SSH.disconnect(server) }
    }

    /// Opens the session in an external terminal app.
    func connect(_ server: Server, terminalBundleID: String) async throws {
        try await TerminalLauncher.open(server, bundleID: terminalBundleID)
        markConnected(server.id)
    }

    func markConnected(_ id: UUID) {
        guard let index = servers.firstIndex(where: { $0.id == id }) else { return }
        servers[index].lastConnected = .now
        save()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: SSHPaths.serversFile) else { return }
        do {
            servers = try JSONDecoder().decode([Server].self, from: data)
        } catch {
            // Keep the unreadable file so the next save doesn't silently replace it with an empty list.
            let backup = SSHPaths.backUpUnreadableFile(SSHPaths.serversFile)
            var message = "Couldn't read saved servers: \(error.localizedDescription)"
            if let backup {
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
            try encoder.encode(servers).write(to: SSHPaths.serversFile, options: .atomic)
        } catch {
            lastError = "Couldn't save servers: \(error.localizedDescription)"
        }
        writeConfig()
    }

    private func writeConfig() {
        do { try SSHConfigWriter.write(servers: servers) } catch {
            lastError = "Couldn't write ssh config: \(error.localizedDescription)"
        }
    }
}
