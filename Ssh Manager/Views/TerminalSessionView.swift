import AppKit
import SwiftUI
#if canImport(SwiftTerm)
import SwiftTerm
#endif

/// Detail view for a terminal session inside the main window.
struct TerminalSessionView: View {
    let session: TerminalSession
    let onClose: () -> Void

    var body: some View {
        TerminalHostView(session: session)
            .id(session.generation)
            .overlay(alignment: .bottom) {
                if case .ended(let exitCode) = session.state {
                    endedBanner(exitCode: exitCode)
                }
            }
            .navigationTitle(session.server.name)
            .navigationSubtitle(session.title ?? session.server.displayAddress)
            .toolbar {
                ToolbarItemGroup {
                    Button("Reconnect", systemImage: "arrow.clockwise") { session.connect() }
                        .help("Reconnect")
                    Button("Close Session", systemImage: "xmark") { onClose() }
                        .help("Close session")
                }
            }
    }

    private func endedBanner(exitCode: Int32?) -> some View {
        HStack(spacing: 12) {
            Image(systemName: exitCode == 0 ? "checkmark.circle" : "bolt.horizontal.circle")
            Text(exitCode == 0
                 ? "Session ended."
                 : "Connection closed (exit code \(exitCode.map(String.init) ?? "?")).")
            Spacer()
            Button("Close", action: onClose)
            Button("Reconnect") { session.connect() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
        .padding(12)
        .background(.regularMaterial, in: .rect(cornerRadius: 10))
        .padding(12)
    }
}

/// Embeds the session's long-lived terminal view. Dismantling only detaches it, never kills ssh.
struct TerminalHostView: NSViewRepresentable {
    let session: TerminalSession

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        #if canImport(SwiftTerm)
        if let terminal = session.terminalView {
            terminal.removeFromSuperview()
            terminal.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(terminal)
            NSLayoutConstraint.activate([
                terminal.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                terminal.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                terminal.topAnchor.constraint(equalTo: container.topAnchor),
                terminal.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
            DispatchQueue.main.async {
                terminal.window?.makeFirstResponder(terminal)
            }
        }
        #endif
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
        nsView.subviews.forEach { $0.removeFromSuperview() }
    }
}
