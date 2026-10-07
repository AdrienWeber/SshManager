import SwiftUI

enum SidebarItem: Hashable {
    case files
    case tunnels
    case server(UUID)
    case session(UUID)
}

struct EditorTarget: Identifiable {
    let server: Server
    let isNew: Bool
    var id: UUID { server.id }
}

struct ContentView: View {
    @Environment(ServerStore.self) private var store
    @Environment(TunnelManager.self) private var tunnels
    @Environment(TerminalSessionManager.self) private var terminals
    @AppStorage(TerminalLauncher.preferenceKey) private var terminalBundleID = TerminalLauncher.defaultPreference

    @State private var selection: SidebarItem? = .files
    @State private var transferModel = FileTransferModel()
    @State private var editorTarget: EditorTarget?
    @State private var pendingDeletion: Server?
    @State private var searchText = ""
    @State private var errorMessage: String?

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .task { tunnels.startAutomaticTunnels(using: store) }
        .sheet(item: $editorTarget) { target in
            ServerEditorView(server: target.server, isNew: target.isNew) { saved in
                selection = .server(saved.id)
            }
        }
        .confirmationDialog(
            "Delete \(pendingDeletion?.name ?? "server")?",
            isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
            presenting: pendingDeletion
        ) { server in
            Button("Delete", role: .destructive) {
                if selection == .server(server.id) { selection = .files }
                store.delete(server)
            }
        } message: { _ in
            Text("The session and its saved credentials will be removed.")
        }
        .alert(
            "Something Went Wrong",
            isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        // `initial: true` so errors raised while loading at launch are shown too.
        .onChange(of: store.lastError, initial: true) { _, newValue in
            if let newValue {
                errorMessage = newValue
                store.lastError = nil
            }
        }
        .onChange(of: tunnels.lastError, initial: true) { _, newValue in
            if let newValue {
                errorMessage = newValue
                tunnels.lastError = nil
            }
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: $selection) {
            Section {
                Label("File Transfer", systemImage: "arrow.left.arrow.right")
                    .tag(SidebarItem.files)
                Label("Tunnels", systemImage: "point.3.connected.trianglepath.dotted")
                    .badge(tunnels.tunnels.filter { tunnels.status(of: $0) == .running }.count)
                    .tag(SidebarItem.tunnels)
            }

            if !terminals.sessions.isEmpty {
                Section("Sessions") {
                    ForEach(terminals.sessions) { session in
                        SessionRow(session: session, label: terminals.label(for: session))
                            .tag(SidebarItem.session(session.id))
                    }
                }
            }

            if store.servers.isEmpty {
                Section("Servers") {
                    Button("Add Your First Server…", systemImage: "plus") { addServer() }
                        .buttonStyle(.borderless)
                }
            }

            ForEach(store.groupedServers(matching: searchText)) { group in
                Section(group.name) {
                    ForEach(group.servers) { server in
                        ServerRow(server: server)
                            .tag(SidebarItem.server(server.id))
                    }
                }
            }
        }
        .contextMenu(forSelectionType: SidebarItem.self) { items in
            if let server = server(in: items) {
                Button("Connect", systemImage: "terminal") { connect(server) }
                if terminalBundleID == TerminalLauncher.builtInID {
                    Button("Connect in External Terminal", systemImage: "macwindow") { connectExternally(server) }
                }
                Button("Browse Files", systemImage: "folder") { browse(server) }
                Divider()
                Button("Edit…", systemImage: "pencil") { editorTarget = EditorTarget(server: server, isNew: false) }
                Button("Duplicate", systemImage: "plus.square.on.square") {
                    selection = .server(store.duplicate(server).id)
                }
                Divider()
                Button("Delete…", systemImage: "trash", role: .destructive) { pendingDeletion = server }
            } else if let session = session(in: items) {
                Button("Reconnect", systemImage: "arrow.clockwise") { session.connect() }
                Button("New Session to \(session.server.name)", systemImage: "plus") { connect(session.server) }
                Button("Browse Files", systemImage: "folder") { browse(session.server) }
                Divider()
                Button("Close Session", systemImage: "xmark") { close(session) }
            }
        } primaryAction: { items in
            // Double-click a server to connect.
            if let server = server(in: items) { connect(server) }
        }
        .searchable(text: $searchText, placement: .sidebar, prompt: "Search servers")
        .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        .toolbar {
            ToolbarItem {
                Button("Add Server", systemImage: "plus") { addServer() }
                    .help("Add a server")
            }
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .server(let id):
            if let server = store.server(withID: id) {
                ServerDetailView(
                    server: server,
                    onConnect: { connect(server) },
                    onConnectExternally: { connectExternally(server) },
                    onEdit: { editorTarget = EditorTarget(server: server, isNew: false) },
                    onBrowse: { browse(server) }
                )
            } else {
                ContentUnavailableView("No Server Selected", systemImage: "server.rack")
            }
        case .tunnels:
            TunnelsView()
        case .session(let id):
            if let session = terminals.session(withID: id) {
                TerminalSessionView(session: session) { close(session) }
            } else {
                ContentUnavailableView("Session Closed", systemImage: "terminal")
            }
        case .files, nil:
            FileTransferView(model: transferModel)
        }
    }

    // MARK: - Actions

    private func server(in items: Set<SidebarItem>) -> Server? {
        guard let item = items.first, case .server(let id) = item else { return nil }
        return store.server(withID: id)
    }

    private func session(in items: Set<SidebarItem>) -> TerminalSession? {
        guard let item = items.first, case .session(let id) = item else { return nil }
        return terminals.session(withID: id)
    }

    private func close(_ session: TerminalSession) {
        if selection == .session(session.id) {
            selection = store.server(withID: session.server.id) != nil ? .server(session.server.id) : .files
        }
        terminals.close(session)
    }

    private func addServer() {
        editorTarget = EditorTarget(server: Server(), isNew: true)
    }

    private func connect(_ server: Server) {
        if terminalBundleID == TerminalLauncher.builtInID, TerminalLauncher.isBuiltInAvailable {
            let session = terminals.open(server)
            selection = .session(session.id)
            store.markConnected(server.id)
        } else {
            connectExternally(server)
        }
    }

    private func connectExternally(_ server: Server) {
        Task {
            do {
                try await store.connect(server,
                                        terminalBundleID: TerminalLauncher.externalBundleID(for: terminalBundleID))
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func browse(_ server: Server) {
        selection = .files
        Task { await transferModel.right.switchTo(.remote(server)) }
    }
}

struct ServerRow: View {
    let server: Server

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 1) {
                Text(server.name)
                    .lineLimit(1)
                Text(server.displayAddress)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        } icon: {
            Image(systemName: "server.rack")
        }
    }
}

struct SessionRow: View {
    let session: TerminalSession
    let label: String

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .lineLimit(1)
                Text(session.state == .running ? (session.title ?? "Connected") : "Disconnected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        } icon: {
            Image(systemName: "terminal")
                .foregroundStyle(session.state == .running ? Color.green : Color.secondary)
        }
    }
}

#Preview {
    ContentView()
        .environment(ServerStore())
        .environment(TransferCenter())
        .environment(TunnelManager())
        .environment(TerminalSessionManager())
        .frame(width: 1000, height: 600)
}
