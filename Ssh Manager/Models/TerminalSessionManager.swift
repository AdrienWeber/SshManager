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
        case ended(Int32?)
    }

    let id = UUID()
    let server: Server
    var title: String?
    var state: State = .running
    /// Incremented on every (re)connect so the hosting view re-attaches the new terminal.
    private(set) var generation = 0

    #if canImport(SwiftTerm)
    @ObservationIgnored private(set) var terminalView: LocalProcessTerminalView?
    @ObservationIgnored private var delegateProxy: TerminalDelegateProxy?
    #endif

    init(server: Server) {
        self.server = server
        connect()
    }

    func connect() {
        #if canImport(SwiftTerm)
        terminalView?.terminate()

        let view = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        let proxy = TerminalDelegateProxy(session: self)
        view.processDelegate = proxy
        view.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        if environment["LANG"] == nil { environment["LANG"] = "en_US.UTF-8" }
        environment.merge(AskPass.environment(for: server)) { $1 }

        view.startProcess(
            executable: SSHPaths.ssh,
            args: ["-F", SSHPaths.configFile.path, server.alias],
            environment: environment.map { "\($0.key)=\($0.value)" },
            execName: "ssh"
        )
        terminalView = view
        delegateProxy = proxy
        #endif
        title = nil
        state = .running
        generation += 1
    }

    func terminate() {
        #if canImport(SwiftTerm)
        if state == .running { terminalView?.terminate() }
        #endif
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
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        // Ignore the old process ending after a reconnect.
        guard let session, source === session.terminalView else { return }
        session.state = .ended(exitCode)
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
