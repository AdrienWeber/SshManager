import Darwin
import Foundation
import Security

/// The app binary doubles as an `SSH_ASKPASS` helper.
///
/// When ssh needs a password it runs `$SSH_ASKPASS "<prompt>"` and reads the answer from stdout.
/// We point `SSH_ASKPASS` at our own executable and pass the server ID in an environment variable;
/// in that mode the app prints the Keychain secret and exits before any UI starts.
/// Because the same signed binary created the Keychain item, no extra access prompt is needed.
///
/// That also means anything that can launch the binary could ask it for secrets, so the helper
/// only answers when
/// - its parent process is `/usr/bin/ssh`, and
/// - the caller passes the random session token that the running app generated at launch.
///   The token is kept in the Keychain (readable without a prompt only by this app) and changes
///   on every launch, so it can't be read from disk or guessed.
nonisolated enum AskPass {
    static let environmentKey = "SSHMGR_ASKPASS_SERVER"
    static let tokenEnvironmentKey = "SSHMGR_ASKPASS_TOKEN"
    private static let tokenAccount = "askpass-session-token"

    static func runIfRequested() {
        let environment = ProcessInfo.processInfo.environment
        guard let rawID = environment[environmentKey] else { return }

        let prompt = CommandLine.arguments.dropFirst().joined(separator: " ").lowercased()
        // Only answer password / passphrase prompts; refuse anything else (e.g. 2FA codes).
        guard let id = UUID(uuidString: rawID),
              prompt.contains("password") || prompt.contains("passphrase"),
              isParentSSH(),
              let token = environment[tokenEnvironmentKey],
              let expected = KeychainStore.secret(forAccount: tokenAccount),
              constantTimeEquals(token, expected),
              let secret = KeychainStore.secret(for: id) else {
            exit(1)
        }
        FileHandle.standardOutput.write(Data((secret + "\n").utf8))
        exit(0)
    }

    /// Environment that makes ssh/scp use the helper for the given server.
    static func environment(for server: Server) -> [String: String] {
        guard let executable = Bundle.main.executablePath,
              KeychainStore.hasSecret(for: server.id),
              let token = sessionToken else { return [:] }
        return [
            "SSH_ASKPASS": executable,
            "SSH_ASKPASS_REQUIRE": "force",
            environmentKey: server.id.uuidString,
            tokenEnvironmentKey: token,
        ]
    }

    // MARK: - Session token

    /// Created once per app launch; replaces the token from the previous launch.
    private static let sessionToken: String? = {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        do {
            try KeychainStore.setSecret(token, forAccount: tokenAccount, label: "SSH Manager session token")
            return token
        } catch {
            return nil
        }
    }()

    private static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8), b = Array(rhs.utf8)
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    // MARK: - Caller check

    /// Whether the process that launched us is the system ssh binary.
    private static func isParentSSH() -> Bool {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(getppid(), &buffer, UInt32(buffer.count))
        guard length > 0 else { return false }
        let path = String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return path == SSHPaths.ssh
    }
}
