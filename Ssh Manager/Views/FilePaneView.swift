import AppKit
import SwiftUI

/// One side of the file explorer: a location picker, path bar and file table.
struct FilePaneView: View {
    @Environment(ServerStore.self) private var store
    @Environment(TransferCenter.self) private var transfers

    let model: FileTransferModel
    @Bindable var pane: PaneModel

    @State private var pathDraft = ""
    @State private var showingNewFolder = false
    @State private var newFolderName = ""
    @State private var renameTarget: FileEntry?
    @State private var renameText = ""
    @State private var deleteTargets: [FileEntry] = []
    @State private var operationError: String?
    @State private var isDropTargeted = false

    private var otherPane: PaneModel { model.other(than: pane) }
    private var arrowIcon: String { model.isLeft(pane) ? "arrow.right" : "arrow.left" }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .task { await pane.loadIfNeeded() }
        .onChange(of: pane.path, initial: true) { _, newValue in pathDraft = newValue }
        // Mouse back/forward buttons and shortcuts act on the pane under the pointer or last used.
        .onHover { inside in if inside { model.activePaneID = pane.id } }
        .onChange(of: pane.selection) { model.activePaneID = pane.id }
        .alert("New Folder", isPresented: $showingNewFolder) {
            TextField("Name", text: $newFolderName)
            Button("Create") { createFolder() }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Rename", isPresented: Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })) {
            TextField("Name", text: $renameText)
            Button("Rename") { renameSelected() }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            deleteTargets.count == 1 ? "Delete “\(deleteTargets[0].name)”?" : "Delete \(deleteTargets.count) items?",
            isPresented: Binding(get: { !deleteTargets.isEmpty }, set: { if !$0 { deleteTargets = [] } })
        ) {
            Button(pane.location.isLocal ? "Move to Trash" : "Delete", role: .destructive) { deleteTargetsNow() }
        } message: {
            Text(pane.location.isLocal
                 ? "The items will be moved to the Trash."
                 : "This permanently deletes the items on \(pane.location.title).")
        }
        .alert(
            "Operation Failed",
            isPresented: Binding(get: { operationError != nil }, set: { if !$0 { operationError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(operationError ?? "")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
            // Device / server selector, grouped like the sidebar.
            Picker("Location", selection: locationBinding) {
                Label("This Mac", systemImage: "laptopcomputer").tag(UUID?.none)
                ForEach(store.groupedServers(matching: "")) { group in
                    Section(group.name) {
                        ForEach(group.servers) { server in
                            Label(server.name, systemImage: "server.rack").tag(Optional(server.id))
                        }
                    }
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 190)
            .help("Choose the device to browse")

            HStack(spacing: 6) {
                Button("Back", systemImage: "chevron.left") { Task { await pane.goBack() } }
                    .disabled(!pane.canGoBack)
                    .help("Back (mouse back button or ⌘[)")
                Button("Forward", systemImage: "chevron.right") { Task { await pane.goForward() } }
                    .disabled(!pane.canGoForward)
                    .help("Forward (mouse forward button or ⌘])")
                Button("Enclosing Folder", systemImage: "arrow.up") { Task { await pane.goUp() } }
                    .help("Enclosing folder (⌘↑)")
                    .disabled(pane.path == "/" || pane.path.isEmpty)
                Button("Home", systemImage: "house") { Task { await pane.goHome() } }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)

            TextField("Path", text: $pathDraft)
                .textFieldStyle(.roundedBorder)
                .font(.body.monospaced())
                .onSubmit { Task { await pane.load(path: pathDraft) } }

            HStack(spacing: 6) {
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await pane.load() } }
                    .help("Refresh (⌘R)")

                Menu {
                    Button("New Folder…", systemImage: "folder.badge.plus") { promptNewFolder() }
                    Toggle("Show Hidden Files", isOn: $pane.showHidden)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
        }
        .padding(8)
    }

    private var locationBinding: Binding<UUID?> {
        Binding {
            pane.location.serverID
        } set: { id in
            let location: FileLocation = id.flatMap { store.server(withID: $0) }.map { .remote($0) } ?? .local
            Task { await pane.switchTo(location) }
        }
    }

    // MARK: - Table

    private var content: some View {
        table
            .overlay {
                if let message = pane.errorMessage, pane.entries.isEmpty {
                    ContentUnavailableView {
                        Label("Couldn't Open Folder", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(message)
                    } actions: {
                        Button("Try Again") { Task { await pane.load() } }
                    }
                    .background(.background)
                }
            }
            .overlay(alignment: .topTrailing) {
                if pane.isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .padding(8)
                }
            }
            .overlay {
                if isDropTargeted {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.accentColor, lineWidth: 3)
                        .padding(2)
                        .allowsHitTesting(false)
                }
            }
    }

    private var table: some View {
        Table(of: FileEntry.self, selection: $pane.selection, sortOrder: $pane.sortOrder) {
            TableColumn("Name", value: \.name) { entry in
                Label {
                    Text(entry.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } icon: {
                    Image(systemName: entry.iconName)
                        .foregroundStyle(entry.isDirectory ? Color.accentColor : Color.secondary)
                }
            }
            .width(min: 140, ideal: 240)

            TableColumn("Size", value: \.size) { entry in
                Text(entry.isDirectory ? "—" : entry.size.formatted(.byteCount(style: .file)))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .width(min: 60, ideal: 80)

            TableColumn("Modified", value: \.modifiedSortKey) { entry in
                Text(entry.modified?.formatted(date: .abbreviated, time: .shortened) ?? "—")
                    .foregroundStyle(.secondary)
            }
            .width(min: 100, ideal: 140)

            TableColumn("Permissions", value: \.permissions) { entry in
                Text(entry.permissions)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            .width(min: 80, ideal: 90)
        } rows: {
            ForEach(pane.visibleEntries) { entry in
                TableRow(entry)
                    .draggable(dragPayload(for: entry))
            }
        }
        .contextMenu(forSelectionType: FileEntry.ID.self) { ids in
            contextMenu(for: pane.entries(for: ids))
        } primaryAction: { ids in
            open(pane.entries(for: ids))
        }
        .onDeleteCommand { requestDelete(pane.selectedEntries) }
        .dropDestination(for: String.self) { items, _ in
            handleDrop(items)
        } isTargeted: { isDropTargeted = $0 }
    }

    @ViewBuilder
    private func contextMenu(for entries: [FileEntry]) -> some View {
        if entries.isEmpty {
            Button("New Folder…", systemImage: "folder.badge.plus") { promptNewFolder() }
            Button("Refresh", systemImage: "arrow.clockwise") { Task { await pane.load() } }
        } else {
            if entries.count == 1, entries[0].isDirectory || pane.location.isLocal {
                Button("Open", systemImage: "arrow.up.forward.app") { open(entries) }
                Divider()
            }
            Button("Copy to \(otherPane.location.title)", systemImage: "doc.on.doc") {
                transfer(entries, move: false)
            }
            Button("Move to \(otherPane.location.title)", systemImage: arrowIcon) {
                transfer(entries, move: true)
            }
            Divider()
            if entries.count == 1 {
                Button("Rename…", systemImage: "pencil") {
                    renameText = entries[0].name
                    renameTarget = entries[0]
                }
            }
            if pane.location.isLocal {
                Button("Show in Finder", systemImage: "finder") {
                    NSWorkspace.shared.activateFileViewerSelecting(entries.map { URL(fileURLWithPath: $0.path) })
                }
            }
            Button("Delete…", systemImage: "trash", role: .destructive) { requestDelete(entries) }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Text(summary)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Group {
                Button("Copy", systemImage: arrowIcon) { transfer(pane.selectedEntries, move: false) }
                    .help("Copy selection to \(otherPane.location.title)")
                Button("Move", systemImage: arrowIcon) { transfer(pane.selectedEntries, move: true) }
                    .help("Move selection to \(otherPane.location.title)")
            }
            .disabled(pane.selection.isEmpty)
        }
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var summary: String {
        let count = pane.visibleEntries.count
        let selected = pane.selection.count
        let items = count == 1 ? "1 item" : "\(count) items"
        return selected > 0 ? "\(selected) of \(items) selected" : items
    }

    // MARK: - Actions

    private func open(_ entries: [FileEntry]) {
        guard entries.count == 1, let entry = entries.first else { return }
        if entry.isDirectory {
            Task { await pane.load(path: entry.path) }
        } else if pane.location.isLocal {
            NSWorkspace.shared.open(URL(fileURLWithPath: entry.path))
        }
    }

    private func transfer(_ entries: [FileEntry], move: Bool) {
        model.transfer(entries, from: pane, to: otherPane, move: move, center: transfers)
    }

    /// Dragging a selected row drags the whole selection.
    private func dragPayload(for entry: FileEntry) -> String {
        let items = pane.selection.contains(entry.id) ? pane.selectedEntries : [entry]
        return DragPayload(paneID: pane.id, paths: items.map(\.path)).encoded
    }

    private func handleDrop(_ items: [String]) -> Bool {
        guard let payload = items.first.flatMap(DragPayload.init(string:)),
              let source = model.pane(withID: payload.paneID),
              source !== pane else { return false }
        let entries = source.entries.filter { payload.paths.contains($0.path) }
        model.transfer(entries, from: source, to: pane, move: false, center: transfers)
        return true
    }

    private func promptNewFolder() {
        newFolderName = "New Folder"
        showingNewFolder = true
    }

    private func createFolder() {
        let name = newFolderName.trimmingCharacters(in: .whitespaces)
        guard isValidFileName(name) else { return }
        let directory = pane.path
        let location = pane.location
        perform { try await FileOperations.makeDirectory(named: name, in: directory, at: location) }
    }

    private func renameSelected() {
        guard let target = renameTarget else { return }
        let name = renameText.trimmingCharacters(in: .whitespaces)
        guard isValidFileName(name), name != target.name else { return }
        let location = pane.location
        perform { try await FileOperations.rename(target, to: name, at: location) }
    }

    /// A single path component; "." and ".." would move the item somewhere else.
    private func isValidFileName(_ name: String) -> Bool {
        !name.isEmpty && !name.contains("/") && name != "." && name != ".."
    }

    private func requestDelete(_ entries: [FileEntry]) {
        deleteTargets = entries
    }

    private func deleteTargetsNow() {
        let entries = deleteTargets
        let location = pane.location
        perform { try await FileOperations.delete(entries, at: location) }
    }

    private func perform(_ operation: @escaping @Sendable () async throws -> Void) {
        Task {
            do {
                try await operation()
            } catch {
                operationError = error.localizedDescription
            }
            await pane.load()
        }
    }
}
