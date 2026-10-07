import AppKit
import SwiftUI

/// Lists all saved tunnels with start/stop switches.
struct TunnelsView: View {
    @Environment(ServerStore.self) private var store
    @Environment(TunnelManager.self) private var tunnels

    @State private var editing: Tunnel?
    @State private var isNew = false
    @State private var pendingDeletion: Tunnel?

    var body: some View {
        Group {
            if tunnels.tunnels.isEmpty {
                ContentUnavailableView {
                    Label("No Tunnels", systemImage: "point.3.connected.trianglepath.dotted")
                } description: {
                    Text("Forward a web app running at home, like Home Assistant or Proxmox, to localhost on this Mac.")
                } actions: {
                    Button("Add Tunnel…") { add() }
                        .disabled(store.servers.isEmpty)
                }
            } else {
                List {
                    ForEach(tunnels.tunnels) { tunnel in
                        TunnelRow(tunnel: tunnel, showsServer: true)
                            .contextMenu {
                                Button("Edit…", systemImage: "pencil") { edit(tunnel) }
                                Button("Delete…", systemImage: "trash", role: .destructive) { pendingDeletion = tunnel }
                            }
                    }
                }
            }
        }
        .navigationTitle("Tunnels")
        .toolbar {
            ToolbarItem {
                Button("Add Tunnel", systemImage: "plus") { add() }
                    .disabled(store.servers.isEmpty)
                    .help(store.servers.isEmpty ? "Add a server first" : "Add a tunnel")
            }
        }
        .sheet(item: $editing) { tunnel in
            TunnelEditorView(tunnel: tunnel, isNew: isNew)
        }
        .confirmationDialog(
            "Delete \(pendingDeletion?.name ?? "tunnel")?",
            isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
            presenting: pendingDeletion
        ) { tunnel in
            Button("Delete", role: .destructive) { tunnels.delete(tunnel) }
        }
    }

    private func add() {
        isNew = true
        editing = Tunnel(serverID: store.servers.first?.id)
    }

    private func edit(_ tunnel: Tunnel) {
        isNew = false
        editing = tunnel
    }
}

/// One tunnel with its status and an on/off switch. Also used on the server detail page.
struct TunnelRow: View {
    @Environment(ServerStore.self) private var store
    @Environment(TunnelManager.self) private var tunnels

    let tunnel: Tunnel
    var showsServer = false

    var body: some View {
        let status = tunnels.status(of: tunnel)
        HStack(spacing: 12) {
            Circle()
                .fill(color(for: status))
                .frame(width: 9, height: 9)

            VStack(alignment: .leading, spacing: 2) {
                Text(tunnel.name.isEmpty ? tunnel.summary : tunnel.name)
                    .lineLimit(1)
                Text(subtitle(for: status))
                    .font(.caption)
                    .foregroundStyle(isFailed(status) ? Color.red : Color.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }

            Spacer()

            if tunnel.kind == .local, status == .running, let url = tunnel.browserURL {
                Button("Open in Browser", systemImage: "safari") { NSWorkspace.shared.open(url) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Open \(url.absoluteString)")
            }

            if status == .starting {
                ProgressView().controlSize(.small)
            }

            Toggle("Enabled", isOn: Binding {
                tunnels.isActive(tunnel)
            } set: { isOn in
                if isOn { tunnels.start(tunnel, using: store) } else { tunnels.stop(tunnel) }
            })
            .toggleStyle(.switch)
            .labelsHidden()
            .controlSize(.small)
        }
        .padding(.vertical, 3)
    }

    private func subtitle(for status: TunnelManager.Status) -> String {
        if case .failed(let message) = status { return message }
        var parts = [tunnel.name.isEmpty ? nil : tunnel.summary]
        if showsServer {
            parts.append("via \(tunnel.serverID.flatMap(store.server(withID:))?.name ?? "missing server")")
        }
        return parts.compactMap(\.self).joined(separator: " · ")
    }

    private func isFailed(_ status: TunnelManager.Status) -> Bool {
        if case .failed = status { return true }
        return false
    }

    private func color(for status: TunnelManager.Status) -> Color {
        switch status {
        case .stopped: .secondary.opacity(0.4)
        case .starting: .yellow
        case .running: .green
        case .failed: .red
        }
    }
}

struct TunnelEditorView: View {
    @Environment(ServerStore.self) private var store
    @Environment(TunnelManager.self) private var tunnels
    @Environment(\.dismiss) private var dismiss

    private let isNew: Bool
    @State private var draft: Tunnel

    init(tunnel: Tunnel, isNew: Bool) {
        self.isNew = isNew
        _draft = State(initialValue: tunnel)
    }

    private var isValid: Bool {
        let ports = 1...65535
        guard draft.serverID != nil, ports.contains(draft.localPort) else { return false }
        if draft.kind == .dynamic { return true }
        return ports.contains(draft.remotePort) && !draft.remoteHost.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $draft.name, prompt: Text("Home Assistant"))
                Picker("Through Server", selection: $draft.serverID) {
                    ForEach(store.servers) { server in
                        Text(server.name).tag(Optional(server.id))
                    }
                }
                Picker("Type", selection: $draft.kind) {
                    ForEach(TunnelKind.allCases) { kind in
                        Text(kind.label).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section {
                TextField("Local Port", value: $draft.localPort, format: .number.grouping(.never))
                if draft.kind == .local {
                    TextField("Destination Host", text: $draft.remoteHost, prompt: Text("localhost or 192.168.1.20"))
                    TextField("Destination Port", value: $draft.remotePort, format: .number.grouping(.never))
                }
            } footer: {
                Text(explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Start when SSH Manager opens", isOn: $draft.startAutomatically)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(isNew ? "Add" : "Save") { save() }
                    .disabled(!isValid)
            }
        }
    }

    private var explanation: String {
        let server = draft.serverID.flatMap(store.server(withID:))?.name ?? "the server"
        switch draft.kind {
        case .local:
            let host = draft.remoteHost.isEmpty ? "host" : draft.remoteHost
            return "Opening http://localhost:\(draft.localPort) on this Mac reaches \(host):\(draft.remotePort) as seen from \(server). Use “localhost” for a service on \(server) itself, or a LAN address for another device at home."
        case .dynamic:
            return "Set your browser or system proxy to SOCKS5 localhost:\(draft.localPort) to browse as if you were on \(server)’s network."
        }
    }

    private func save() {
        var tunnel = draft
        tunnel.name = tunnel.name.trimmingCharacters(in: .whitespaces)
        tunnel.remoteHost = tunnel.remoteHost.trimmingCharacters(in: .whitespaces)
        let wasActive = tunnels.isActive(tunnel)
        tunnels.upsert(tunnel)
        // Restart a running tunnel so the new settings take effect.
        if wasActive {
            tunnels.stop(tunnel)
            Task {
                try? await Task.sleep(for: .milliseconds(400))
                tunnels.start(tunnel, using: store)
            }
        }
        dismiss()
    }
}
