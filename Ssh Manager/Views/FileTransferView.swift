import AppKit
import SwiftUI

/// Dual-pane file explorer with a transfer queue at the bottom.
struct FileTransferView: View {
    let model: FileTransferModel

    @State private var mouseMonitor = MouseNavigationMonitor()

    var body: some View {
        panes
            .background { shortcuts }
            .confirmationDialog(
                conflictTitle,
                isPresented: Binding(get: { model.pendingTransfer != nil },
                                     set: { if !$0 { model.pendingTransfer = nil } }),
                presenting: model.pendingTransfer
            ) { pending in
                Button("Replace", role: .destructive) { model.resolvePendingTransfer(replace: true) }
                if pending.canSkip {
                    Button("Skip Existing") { model.resolvePendingTransfer(replace: false) }
                }
                Button("Cancel", role: .cancel) {}
            } message: { pending in
                Text(pending.destination.location.isLocal
                     ? "Replacing moves the existing items to the Trash."
                     : "Replacing permanently deletes the existing items on \(pending.destination.location.title).")
            }
            .onAppear {
                mouseMonitor.start { direction in
                    let pane = model.activePane
                    Task {
                        switch direction {
                        case .back: await pane.goBack()
                        case .forward: await pane.goForward()
                        }
                    }
                }
            }
            .onDisappear { mouseMonitor.stop() }
    }

    private var conflictTitle: String {
        guard let conflicts = model.pendingTransfer?.conflicts else { return "" }
        return conflicts.count == 1
            ? "“\(conflicts[0].name)” already exists. Replace it?"
            : "\(conflicts.count) items already exist. Replace them?"
    }

    /// Invisible buttons that provide window-wide shortcuts for the active pane.
    private var shortcuts: some View {
        Group {
            Button("Back") { Task { await model.activePane.goBack() } }
                .keyboardShortcut("[", modifiers: .command)
            Button("Forward") { Task { await model.activePane.goForward() } }
                .keyboardShortcut("]", modifiers: .command)
            Button("Enclosing Folder") { Task { await model.activePane.goUp() } }
                .keyboardShortcut(.upArrow, modifiers: .command)
            Button("Refresh") { Task { await model.activePane.load() } }
                .keyboardShortcut("r", modifiers: .command)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    private var panes: some View {
        VSplitView {
            HSplitView {
                FilePaneView(model: model, pane: model.left)
                    .frame(minWidth: 340)
                FilePaneView(model: model, pane: model.right)
                    .frame(minWidth: 340)
            }
            .frame(minHeight: 300)

            TransfersView()
                .frame(minHeight: 100, idealHeight: 160)
        }
        .navigationTitle("File Transfer")
    }
}

/// Listens for the side buttons on a mouse (button 4 = back, button 5 = forward).
final class MouseNavigationMonitor {
    enum Direction {
        case back, forward
    }

    private var monitor: Any?

    func start(_ handler: @escaping (Direction) -> Void) {
        stop()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .otherMouseDown) { event in
            switch event.buttonNumber {
            case 3:
                handler(.back)
                return nil
            case 4:
                handler(.forward)
                return nil
            default:
                return event
            }
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

struct TransfersView: View {
    @Environment(TransferCenter.self) private var center

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Transfers")
                    .font(.headline)
                Spacer()
                Button("Clear Finished") { center.clearFinished() }
                    .disabled(!center.hasFinishedJobs)
                    .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            Divider()

            if center.jobs.isEmpty {
                ContentUnavailableView {
                    Label("No Transfers", systemImage: "arrow.up.arrow.down")
                } description: {
                    Text("Drag files between panes, or use Copy and Move.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(center.jobs) { job in
                    TransferRow(job: job) { center.cancel(job.id) }
                }
            }
        }
    }
}

struct TransferRow: View {
    let job: TransferCenter.Job
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            statusIcon
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(job.title)
                    .lineLimit(1)
                if job.state == .running, let fraction = job.fractionCompleted {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(isFailed ? Color.red : Color.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
            Spacer()
            if job.state == .running {
                Button("Cancel", systemImage: "xmark.circle.fill", action: onCancel)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Cancel transfer")
            }
        }
        .padding(.vertical, 2)
    }

    private var isFailed: Bool {
        if case .failed = job.state { return true }
        return false
    }

    private var subtitle: String {
        switch job.state {
        case .failed(let message): message
        case .cancelled: "Cancelled — \(job.detail)"
        case .running: progressText ?? job.detail
        case .succeeded:
            if let total = job.totalBytes {
                "\(total.formatted(.byteCount(style: .file))) — \(job.detail)"
            } else {
                job.detail
            }
        }
    }

    /// e.g. "12 MB of 340 MB · 5.2 MB/s · 1 min, 3 sec left"
    private var progressText: String? {
        guard let total = job.totalBytes else { return nil }
        var parts = ["\(job.transferredBytes.formatted(.byteCount(style: .file))) of \(total.formatted(.byteCount(style: .file)))"]
        if job.bytesPerSecond > 0 {
            parts.append("\(Int64(job.bytesPerSecond).formatted(.byteCount(style: .file)))/s")
        }
        if let remaining = job.secondsRemaining, remaining.isFinite {
            let duration = Duration.seconds(remaining.rounded())
            parts.append("\(duration.formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2))) left")
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch job.state {
        case .running:
            ProgressView().controlSize(.small)
        case .succeeded:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .cancelled:
            Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
        }
    }
}
