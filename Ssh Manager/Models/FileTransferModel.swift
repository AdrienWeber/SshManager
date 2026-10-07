import Foundation
import Observation
import SwiftUI

/// State for one side of the dual-pane file explorer.
@Observable
final class PaneModel: Identifiable {
    let id = UUID()
    var location: FileLocation = .local
    var path: String = "/"
    var entries: [FileEntry] = []
    var selection: Set<FileEntry.ID> = []
    var sortOrder = [KeyPathComparator(\FileEntry.name, comparator: .localizedStandard)]
    var showHidden = false
    var isLoading = false
    var errorMessage: String?

    @ObservationIgnored private var hasLoaded = false
    @ObservationIgnored private var loadToken = UUID()

    /// Folders first, then the table's sort order.
    var visibleEntries: [FileEntry] {
        let filtered = showHidden ? entries : entries.filter { !$0.name.hasPrefix(".") }
        return filtered.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            for comparator in sortOrder {
                switch comparator.compare(lhs, rhs) {
                case .orderedAscending: return true
                case .orderedDescending: return false
                case .orderedSame: continue
                }
            }
            return false
        }
    }

    var selectedEntries: [FileEntry] { entries(for: selection) }

    func entries(for ids: Set<FileEntry.ID>) -> [FileEntry] {
        entries.filter { ids.contains($0.id) }
    }

    func loadIfNeeded() async {
        guard !hasLoaded else { return }
        hasLoaded = true
        await load()
    }

    /// Loads `requestedPath` and records it in the history, or reloads the current path when nil.
    /// An empty path means the home directory.
    func load(path requestedPath: String? = nil) async {
        await load(requestedPath ?? path, history: requestedPath == nil ? .none : .push)
    }

    private func load(_ target: String, history: HistoryAction) async {
        let token = UUID()
        loadToken = token
        let previousPath = path
        let location = location
        isLoading = true
        do {
            let listing = try await FileOperations.list(location, path: target)
            guard loadToken == token else { return }
            let changed = listing.path != previousPath
            if changed { selection = [] }
            recordHistory(history, leaving: previousPath, changed: changed)
            path = listing.path
            entries = listing.entries
            errorMessage = nil
        } catch {
            guard loadToken == token else { return }
            errorMessage = error.localizedDescription
            // Drop history entries that can no longer be opened (e.g. deleted folders).
            switch history {
            case .back: backStack.removeLast()
            case .forward: forwardStack.removeLast()
            case .none, .push: break
            }
        }
        isLoading = false
    }

    func switchTo(_ newLocation: FileLocation) async {
        hasLoaded = true
        location = newLocation
        entries = []
        selection = []
        errorMessage = nil
        backStack = []
        forwardStack = []
        path = "/"
        await load(path, history: .none)
    }

    // MARK: - History

    private enum HistoryAction {
        case none, push, back, forward
    }

    private(set) var backStack: [String] = []
    private(set) var forwardStack: [String] = []

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }

    func goBack() async {
        guard let target = backStack.last else { return }
        await load(target, history: .back)
    }

    func goForward() async {
        guard let target = forwardStack.last else { return }
        await load(target, history: .forward)
    }

    private func recordHistory(_ action: HistoryAction, leaving previousPath: String, changed: Bool) {
        let shouldRecord = changed && !previousPath.isEmpty
        switch action {
        case .none:
            break
        case .push:
            guard shouldRecord else { return }
            backStack.append(previousPath)
            forwardStack.removeAll()
        case .back:
            backStack.removeLast()
            if shouldRecord { forwardStack.append(previousPath) }
        case .forward:
            forwardStack.removeLast()
            if shouldRecord { backStack.append(previousPath) }
        }
    }

    func goUp() async {
        guard path != "/", !path.isEmpty else { return }
        await load(path: (path as NSString).deletingLastPathComponent)
    }

    func goHome() async {
        await load(path: location.isLocal ? NSHomeDirectory() : "")
    }
}

/// The two panes plus the logic to move files between them.
@Observable
final class FileTransferModel {
    let left = PaneModel()
    let right = PaneModel()

    /// The pane under the pointer or last interacted with; target of mouse buttons and shortcuts.
    @ObservationIgnored var activePaneID: UUID?

    var activePane: PaneModel {
        activePaneID.flatMap(pane(withID:)) ?? left
    }

    func isLeft(_ pane: PaneModel) -> Bool { pane === left }
    func other(than pane: PaneModel) -> PaneModel { pane === left ? right : left }
    func pane(withID id: UUID) -> PaneModel? { [left, right].first { $0.id == id } }

    /// A transfer waiting for the user to decide what to do with items that already exist.
    struct PendingTransfer {
        let entries: [FileEntry]
        let conflicts: [FileEntry]
        let source: PaneModel
        let destination: PaneModel
        let move: Bool
        let center: TransferCenter

        var canSkip: Bool { conflicts.count < entries.count }
    }

    var pendingTransfer: PendingTransfer?

    /// Starts a transfer, or asks first (via `pendingTransfer`) if it would overwrite something.
    func transfer(_ entries: [FileEntry],
                  from source: PaneModel,
                  to destination: PaneModel,
                  move: Bool,
                  center: TransferCenter) {
        guard !entries.isEmpty, !destination.path.isEmpty else { return }
        // Nothing to do when dropping into the folder the items already live in.
        if source.location == destination.location, source.path == destination.path { return }

        let existingNames = Set(destination.entries.map(\.name))
        let conflicts = entries.filter { existingNames.contains($0.name) }
        if conflicts.isEmpty {
            start(entries, replacing: [], from: source, to: destination, move: move, center: center)
        } else {
            pendingTransfer = PendingTransfer(entries: entries, conflicts: conflicts, source: source,
                                              destination: destination, move: move, center: center)
        }
    }

    /// Resolves `pendingTransfer`: replace the existing items, or transfer only the others.
    func resolvePendingTransfer(replace: Bool) {
        guard let pending = pendingTransfer else { return }
        pendingTransfer = nil
        let conflictNames = Set(pending.conflicts.map(\.name))
        let entries = replace ? pending.entries : pending.entries.filter { !conflictNames.contains($0.name) }
        start(entries, replacing: replace ? Array(conflictNames) : [],
              from: pending.source, to: pending.destination, move: pending.move, center: pending.center)
    }

    private func start(_ entries: [FileEntry],
                       replacing: [String],
                       from source: PaneModel,
                       to destination: PaneModel,
                       move: Bool,
                       center: TransferCenter) {
        guard !entries.isEmpty else { return }
        let sourceLocation = source.location
        let destinationLocation = destination.location
        let destinationDirectory = destination.path

        let itemDescription = entries.count == 1 ? entries[0].name : "\(entries.count) items"
        center.start(
            title: "\(move ? "Move" : "Copy") \(itemDescription)",
            detail: "\(sourceLocation.title) → \(destinationLocation.title): \(destinationDirectory)"
        ) { progress in
            try await FileOperations.transfer(entries, from: sourceLocation, to: destinationLocation,
                                              destinationDirectory: destinationDirectory, move: move,
                                              replacing: replacing, progress: progress)
        } completion: { [weak source, weak destination] in
            Task {
                await destination?.load()
                if move { await source?.load() }
            }
        }
    }
}

/// In-app drag payload: identifies the source pane and the dragged paths.
nonisolated struct DragPayload {
    private static let prefix = "sshmgr-files"
    let paneID: UUID
    let paths: [String]

    var encoded: String {
        ([Self.prefix, paneID.uuidString] + paths).joined(separator: "\n")
    }

    init(paneID: UUID, paths: [String]) {
        self.paneID = paneID
        self.paths = paths
    }

    init?(string: String) {
        let lines = string.components(separatedBy: "\n")
        guard lines.count >= 3, lines[0] == Self.prefix, let id = UUID(uuidString: lines[1]) else { return nil }
        paneID = id
        paths = Array(lines.dropFirst(2))
    }
}
