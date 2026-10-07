import AppKit
import SwiftUI

struct ServerDetailView: View {
    @Environment(TunnelManager.self) private var tunnels
    @AppStorage(TerminalLauncher.preferenceKey) private var terminalPreference = TerminalLauncher.defaultPreference

    let server: Server
    let onConnect: () -> Void
    let onConnectExternally: () -> Void
    let onEdit: () -> Void
    let onBrowse: () -> Void

    private enum ConnectionStatus: Equatable {
        case idle
        case testing
        case succeeded(String)
        case failed(String)
    }

    @State private var status: ConnectionStatus = .idle
    @State private var newTunnel: Tunnel?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                actions
                statusView
                details
                tunnelsSection
                if !server.notes.isEmpty {
                    GroupBox("Notes") {
                        Text(server.notes)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(4)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(server.name)
        .toolbar {
            ToolbarItem {
                Button("Edit", systemImage: "pencil", action: onEdit)
            }
        }
        .onChange(of: server.id) { status = .idle }
        .sheet(item: $newTunnel) { tunnel in
            TunnelEditorView(tunnel: tunnel, isNew: true)
        }
    }

    private var tunnelsSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 4) {
                let serverTunnels = tunnels.tunnels(for: server.id)
                if serverTunnels.isEmpty {
                    Text("No tunnels yet. Forward a web app running at home to localhost on this Mac.")
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 2)
                } else {
                    ForEach(serverTunnels) { tunnel in
                        TunnelRow(tunnel: tunnel)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        } label: {
            HStack {
                Text("Tunnels")
                Spacer()
                Button("Add Tunnel", systemImage: "plus") { newTunnel = Tunnel(serverID: server.id) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "server.rack")
                .font(.system(size: 28))
                .foregroundStyle(.tint)
                .frame(width: 52, height: 52)
                .background(.tint.opacity(0.12), in: .rect(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 2) {
                Text(server.name)
                    .font(.title2.bold())
                Text(server.displayAddress)
                    .font(.body.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    private var actions: some View {
        HStack {
            Button(action: onConnect) {
                Label("Connect", systemImage: "terminal")
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)

            Button(action: onBrowse) {
                Label("Browse Files", systemImage: "folder")
            }

            Button {
                testConnection()
            } label: {
                Label("Test", systemImage: "bolt.horizontal")
            }
            .disabled(status == .testing)

            Menu {
                if terminalPreference == TerminalLauncher.builtInID {
                    Button("Connect in External Terminal", action: onConnectExternally)
                    Divider()
                }
                Button("Copy SSH Command") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(server.plainSSHCommand, forType: .string)
                }
                Button("Close Background Connection") {
                    Task { await SSH.disconnect(server) }
                }
            } label: {
                Label("More", systemImage: "ellipsis")
            }
            .fixedSize()
        }
        .controlSize(.large)
    }

    @ViewBuilder
    private var statusView: some View {
        switch status {
        case .idle:
            EmptyView()
        case .testing:
            Label {
                Text("Connecting…")
            } icon: {
                ProgressView().controlSize(.small)
            }
        case .succeeded(let message):
            Label(message, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .textSelection(.enabled)
        }
    }

    private var details: some View {
        GroupBox("Details") {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                detailRow("Group", server.group)
                detailRow("Host", server.host)
                detailRow("Port", String(server.port))
                detailRow("Username", server.username.isEmpty ? "—" : server.username)
                detailRow("Authentication", server.authMethod.label)
                if server.authMethod == .privateKey {
                    detailRow("Key File", server.keyPath.isEmpty ? "—" : server.keyPath)
                }
                detailRow("Last Connected",
                          server.lastConnected?.formatted(date: .abbreviated, time: .shortened) ?? "Never")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }

    private func detailRow(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            Text(value)
                .textSelection(.enabled)
        }
    }

    private func testConnection() {
        status = .testing
        let server = server
        Task {
            do {
                status = .succeeded(try await SSH.testConnection(server))
            } catch {
                status = .failed(error.localizedDescription)
            }
        }
    }
}
