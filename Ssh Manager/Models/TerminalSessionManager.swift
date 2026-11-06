import AppKit
import Foundation
import Observation
#if canImport(SwiftTerm)
import SwiftTerm
#endif

/// One interactive SSH session shown inside the main window.
///
/// The session owns its terminal view, so ssh keeps running while the user
/// switches to other sidebar items; the view is just re-attached when shown again.
@Observable
final class TerminalSession: Identifiable {
    enum State: Equatable {
        case running
        /// The connection dropped; another attempt starts shortly.
        case reconnecting(attempt: Int)
        case ended(Int32?)
    }

    static let maxReconnectAttempts = 3

    let id = UUID()
    let server: Server
    var title: String?
    var state: State = .running
    /// The remote working directory last reported by the shell (OSC 7 or a `user@host: dir` title).
    /// Reconnecting changes back into it.
    var workingDirectory: String?
    /// Incremented on every (re)connect so the hosting view re-attaches and focuses the terminal.
    private(set) var generation = 0

    @ObservationIgnored private var connectedAt = Date.now
    @ObservationIgnored private var reconnectAttempts = 0
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?
    @ObservationIgnored private var isClosed = false

    #if canImport(SwiftTerm)
    @ObservationIgnored private(set) var terminalView: LocalProcessTerminalView?
    @ObservationIgnored private var delegateProxy: TerminalDelegateProxy?
    #endif

    init(server: Server) {
        self.server = server
        start()
    }

    /// Reconnects on the user's request.
    func connect() {
        reconnectAttempts = 0
        start()
    }

    /// Stops a pending automatic reconnect and shows the session as ended.
    func cancelReconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
        if case .reconnecting = state { state = .ended(255) }
    }

    /// Starts ssh in the session's terminal. The terminal view is reused across reconnects,
    /// so the scrollback from the previous connection stays visible.
    private func start() {
        reconnectTask?.cancel()
        reconnectTask = nil
        #if canImport(SwiftTerm)
        let view: LocalProcessTerminalView
        if let existing = terminalView {
            existing.terminate()
            // Undo modes a program may have left on when the connection dropped
            // (alternate screen, mouse reporting, hidden cursor, …).
            existing.feed(text: Self.resetModes + "\r\n\u{1b}[2m[Reconnecting to \(server.name)…]\u{1b}[0m\r\n")
            view = existing
        } else {
            view = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
            let proxy = TerminalDelegateProxy(session: self)
            view.processDelegate = proxy
            view.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
            terminalView = view
            delegateProxy = proxy
        }

        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        if environment["LANG"] == nil { environment["LANG"] = "en_US.UTF-8" }
        environment.merge(AskPass.environment(for: server)) { $1 }

        // Interactive sessions get their own connection instead of sharing the multiplexed
        // master used for file browsing: a stale master (e.g. after sleep) or "Close Background
        // Connection" would otherwise take every open terminal down with it.
        var args = ["-F", SSHPaths.configFile.path, "-o", "ControlMaster=no", "-o", "ControlPath=none"]
        if let command = Self.restoreCommand(for: workingDirectory) {
            args += ["-t", server.alias, command]
        } else {
            args.append(server.alias)
        }

        view.startProcess(
            executable: SSHPaths.ssh,
            args: args,
            environment: environment.map { "\($0.key)=\($0.value)" },
            execName: "ssh"
        )
        #endif
        title = nil
        state = .running
        connectedAt = .now
        generation += 1
    }

    func terminate() {
        isClosed = true
        reconnectTask?.cancel()
        reconnectTask = nil
        #if canImport(SwiftTerm)
        if state == .running { terminalView?.terminate() }
        #endif
    }

    /// Called when ssh exits. `exitCode` is the decoded exit status (nil if killed by a signal).
    fileprivate func processEnded(exitCode: Int32?) {
        guard !isClosed else { return }
        let uptime = Date.now.timeIntervalSince(connectedAt)
        if uptime > 60 { reconnectAttempts = 0 }

        // ssh exits with 255 when the connection fails or drops. Only retry connections that
        // were working (or are already being retried), so a wrong password isn't repeated.
        let connectionLost = exitCode == 255 && (uptime > 10 || reconnectAttempts > 0)
        guard connectionLost, reconnectAttempts < Self.maxReconnectAttempts else {
            state = .ended(exitCode)
            return
        }

        reconnectAttempts += 1
        let attempt = reconnectAttempts
        state = .reconnecting(attempt: attempt)
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(attempt * 3))
            guard !Task.isCancelled, let self, self.state == .reconnecting(attempt: attempt) else { return }
            self.start()
        }
    }

    // MARK: - Working directory

    private static let resetModes = [
        "\u{1b}[?1049l",                                            // leave the alternate screen
        "\u{1b}[?1000l\u{1b}[?1002l\u{1b}[?1003l\u{1b}[?1006l",     // mouse reporting off
        "\u{1b}[?2004l",                                            // bracketed paste off
        "\u{1b}[?1l\u{1b}[?25h\u{1b}[0m",                           // normal cursor keys, visible cursor, plain text
    ].joined()

    /// A remote command that changes into `directory`, then starts the normal login shell.
    /// The `cd` failing (folder deleted) still opens the shell in the home directory.
    static func restoreCommand(for directory: String?) -> String? {
        guard let directory else { return nil }
        let target: String
        if directory.hasPrefix("~/"), directory.count > 2 {
            target = "\"$HOME\"/" + SSH.quote(String(directory.dropFirst(2)))
        } else if directory.hasPrefix("/") {
            target = SSH.quote(directory)
        } else {
            return nil  // "~" is where ssh starts anyway; "~user" can't be quoted safely.
        }
        return "cd \(target) 2>/dev/null; exec \"$SHELL\" -l"
    }

    /// Parses an OSC 7 report such as `file://host/var/www%20site`.
    static func directory(fromOSC7 value: String) -> String? {
        if value.hasPrefix("file://") {
            guard let path = URL(string: value)?.path(percentEncoded: false), path.hasPrefix("/") else { return nil }
            return path
        }
        return value.hasPrefix("/") ? value : nil
    }

    /// Many distributions (Debian, Ubuntu, …) set the window title to `user@host: ~/dir`.
    static func directory(fromTitle title: String) -> String? {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        guard let match = trimmed.wholeMatch(of: #/[^@\s]+@[^:\s]+:\s*((?:~|\/).*)/#) else { return nil }
        let path = String(match.1)
        return path == "~" || path.hasPrefix("~/") || path.hasPrefix("/") ? path : nil
    }
}

#if canImport(SwiftTerm)
private final class TerminalDelegateProxy: NSObject, LocalProcessTerminalViewDelegate {
    weak var session: TerminalSession?

    init(session: TerminalSession) {
        self.session = session
    }

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        session?.title = title.isEmpty ? nil : title
        if let directory = TerminalSession.directory(fromTitle: title) {
            session?.workingDirectory = directory
        }
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        if let directory = directory.flatMap(TerminalSession.directory(fromOSC7:)) {
            session?.workingDirectory = directory
        }
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        guard let session, source === session.terminalView else { return }
        session.processEnded(exitCode: exitCode.flatMap(Self.exitStatus(fromWaitStatus:)))
    }

    /// SwiftTerm reports the raw `waitpid` status; extract the exit code (nil if killed by a signal).
    private static func exitStatus(fromWaitStatus status: Int32) -> Int32? {
        status & 0x7f == 0 ? (status >> 8) & 0xff : nil
    }
}
#endif

@Observable
final class TerminalSessionManager {
    private(set) var sessions: [TerminalSession] = []

    func session(withID id: UUID) -> TerminalSession? {
        sessions.first { $0.id == id }
    }

    func open(_ server: Server) -> TerminalSession {
        let session = TerminalSession(server: server)
        sessions.append(session)
        return session
    }

    func close(_ session: TerminalSession) {
        session.terminate()
        sessions.removeAll { $0 === session }
    }

    /// Sidebar label; numbered when several sessions are open to the same server.
    func label(for session: TerminalSession) -> String {
        let sameServer = sessions.filter { $0.server.id == session.server.id }
        guard sameServer.count > 1, let index = sameServer.firstIndex(where: { $0 === session }) else {
            return session.server.name
        }
        return "\(session.server.name) (\(index + 1))"
    }
}
