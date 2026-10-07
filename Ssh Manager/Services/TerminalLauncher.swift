import AppKit
import Foundation

/// Opens an interactive SSH session in Terminal or iTerm2 by handing it a one-shot `.command` script.
enum TerminalLauncher {
    static let preferenceKey = "terminalBundleID"
    static let defaultBundleID = "com.apple.Terminal"
    /// Preference value meaning "use the terminal built into SSH Manager".
    static let builtInID = "builtin"

    static var isBuiltInAvailable: Bool {
        #if canImport(SwiftTerm)
        true
        #else
        false
        #endif
    }

    static var defaultPreference: String { isBuiltInAvailable ? builtInID : defaultBundleID }

    /// Resolves the preference to an external app, for when the built-in terminal isn't used.
    static func externalBundleID(for preference: String) -> String {
        preference == builtInID ? defaultBundleID : preference
    }

    struct TerminalApp: Identifiable, Hashable {
        let bundleID: String
        let name: String
        var id: String { bundleID }
    }

    static var installedTerminals: [TerminalApp] {
        [
            TerminalApp(bundleID: "com.apple.Terminal", name: "Terminal"),
            TerminalApp(bundleID: "com.googlecode.iterm2", name: "iTerm2"),
        ].filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundleID) != nil }
    }

    static func open(_ server: Server, bundleID: String) async throws {
        let workspace = NSWorkspace.shared
        guard let appURL = workspace.urlForApplication(withBundleIdentifier: bundleID)
                ?? workspace.urlForApplication(withBundleIdentifier: defaultBundleID) else {
            throw SSHError("No terminal app found.")
        }

        let scriptURL = FileManager.default.temporaryDirectory
            .appending(path: "ssh-\(server.id.uuidString.prefix(8)).command")
        try makeScript(for: server).write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)

        _ = try await workspace.open([scriptURL], withApplicationAt: appURL,
                                     configuration: NSWorkspace.OpenConfiguration())
    }

    /// The script only contains the server ID; the password is fetched from the Keychain by the askpass helper.
    private static func makeScript(for server: Server) -> String {
        var lines = [
            "#!/bin/sh",
            "rm -f \"$0\"",
            "clear",
            "printf '\\033]0;%s\\007' \(SSH.quote(server.name))",
        ]
        for (key, value) in AskPass.environment(for: server).sorted(by: { $0.key < $1.key }) {
            lines.append("export \(key)=\(SSH.quote(value))")
        }
        lines.append("exec \(SSHPaths.ssh) -F \(SSH.quote(SSHPaths.configFile.path)) \(server.alias)")
        return lines.joined(separator: "\n") + "\n"
    }
}
