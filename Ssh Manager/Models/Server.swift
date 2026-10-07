import Foundation

/// How a server authenticates the user.
nonisolated enum AuthMethod: String, Codable, CaseIterable, Identifiable, Sendable {
    case password
    case privateKey
    case agent

    var id: String { rawValue }

    var label: String {
        switch self {
        case .password: "Password"
        case .privateKey: "Private Key"
        case .agent: "SSH Agent / Default Keys"
        }
    }
}

/// A saved SSH session. Secrets (passwords, key passphrases) live in the Keychain, never here.
nonisolated struct Server: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var name: String = ""
    var group: String = "Homelab"
    var host: String = ""
    var port: Int = 22
    var username: String = ""
    var authMethod: AuthMethod = .password
    var keyPath: String = ""
    var notes: String = ""
    var lastConnected: Date?

    /// Host alias used in the generated ssh_config, so every ssh/scp call can refer to the server by one name.
    var alias: String { "sshmgr-\(id.uuidString.lowercased())" }

    var displayAddress: String {
        let target = username.isEmpty ? host : "\(username)@\(host)"
        return port == 22 ? target : "\(target):\(port)"
    }

    /// A plain ssh command the user can paste anywhere.
    var plainSSHCommand: String {
        var parts = ["ssh"]
        if port != 22 { parts += ["-p", String(port)] }
        if authMethod == .privateKey, !keyPath.isEmpty { parts += ["-i", keyPath] }
        parts.append(username.isEmpty ? host : "\(username)@\(host)")
        return parts.joined(separator: " ")
    }
}

/// Where a file pane is browsing: this Mac or a saved server.
nonisolated enum FileLocation: Hashable, Sendable {
    case local
    case remote(Server)

    var serverID: UUID? {
        switch self {
        case .local: nil
        case .remote(let server): server.id
        }
    }

    var title: String {
        switch self {
        case .local: "This Mac"
        case .remote(let server): server.name
        }
    }

    var isLocal: Bool { serverID == nil }

    // Identity is the server ID only, so editing a server's details doesn't make it a "different" location.
    static func == (lhs: FileLocation, rhs: FileLocation) -> Bool { lhs.serverID == rhs.serverID }
    func hash(into hasher: inout Hasher) { hasher.combine(serverID) }
}

nonisolated struct FileEntry: Identifiable, Hashable, Sendable {
    var id: String { path }
    let name: String
    let path: String
    let isDirectory: Bool
    let isSymlink: Bool
    let size: Int64
    let modified: Date?
    let permissions: String

    var modifiedSortKey: Date { modified ?? .distantPast }

    var iconName: String {
        if isDirectory { return isSymlink ? "folder.badge.gearshape" : "folder.fill" }
        return isSymlink ? "link" : "doc"
    }
}

nonisolated struct DirectoryListing: Sendable {
    let path: String
    let entries: [FileEntry]
}

nonisolated enum TunnelKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case local
    case dynamic

    var id: String { rawValue }

    var label: String {
        switch self {
        case .local: "Port Forward"
        case .dynamic: "SOCKS Proxy"
        }
    }
}

/// A saved SSH tunnel, e.g. forwarding a homelab web UI to `localhost` on this Mac.
nonisolated struct Tunnel: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var name: String = ""
    var serverID: UUID?
    var kind: TunnelKind = .local
    var localPort: Int = 8080
    var remoteHost: String = "localhost"
    var remotePort: Int = 80
    var startAutomatically = false

    var browserURL: URL? { URL(string: "http://localhost:\(localPort)") }

    var summary: String {
        switch kind {
        case .local: "localhost:\(localPort) → \(remoteHost):\(remotePort)"
        case .dynamic: "SOCKS proxy on localhost:\(localPort)"
        }
    }

    /// ssh arguments that create the forward (only listening on the loopback interface).
    var forwardArguments: [String] {
        switch kind {
        case .local: ["-L", "127.0.0.1:\(localPort):\(remoteHost):\(remotePort)"]
        case .dynamic: ["-D", "127.0.0.1:\(localPort)"]
        }
    }
}

/// Reports transfer progress (bytes done, total if known) from background work.
nonisolated struct ProgressReporter: Sendable {
    let report: @Sendable (Int64, Int64?) -> Void

    func callAsFunction(_ transferred: Int64, of total: Int64?) {
        report(transferred, total)
    }
}

nonisolated struct SSHError: LocalizedError, Sendable {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
