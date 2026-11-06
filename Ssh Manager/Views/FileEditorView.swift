import AppKit
import SwiftUI

/// A file opened in the built-in text editor.
struct EditRequest: Identifiable {
    let id = UUID()
    let entry: FileEntry
    let location: FileLocation
}

/// A simple plain-text editor for quick changes to local or remote files.
struct FileEditorView: View {
    @Environment(\.dismiss) private var dismiss

    let request: EditRequest
    /// Called after every successful save, e.g. to refresh the file list.
    let onSaved: () -> Void

    private enum Phase {
        case loading
        case loaded
        case failed(String)
    }

    @State private var phase = Phase.loading
    @State private var text = ""
    @State private var isDirty = false
    @State private var isSaving = false
    @State private var saveError: String?
    @State private var confirmingDiscard = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(minWidth: 640, idealWidth: 860, minHeight: 420, idealHeight: 620)
        .task { await load() }
        .interactiveDismissDisabled(isDirty)
        .confirmationDialog("Save changes to “\(request.entry.name)”?", isPresented: $confirmingDiscard) {
            Button("Save") { save(thenClose: true) }
            Button("Discard Changes", role: .destructive) { dismiss() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your changes will be lost if you don’t save them.")
        }
        .alert(
            "Couldn’t Save",
            isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(saveError ?? "")
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: request.location.isLocal ? "laptopcomputer" : "server.rack")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(request.entry.name)
                    .font(.headline)
                    .lineLimit(1)
                Text("\(request.location.title): \(request.entry.path)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Spacer()
            if isDirty {
                Text("Edited")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            ProgressView("Loading…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ContentUnavailableView {
                Label("Couldn’t Open File", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { Task { await load() } }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded:
            PlainTextEditor(text: $text) { isDirty = true }
        }
    }

    private var footer: some View {
        HStack {
            if isSaving {
                ProgressView().controlSize(.small)
                Text("Saving…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Close") { close() }
                .keyboardShortcut(.cancelAction)
            Button("Save") { save(thenClose: false) }
                .keyboardShortcut("s", modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(!isLoaded || isSaving || !isDirty)
        }
        .padding(12)
    }

    private var isLoaded: Bool {
        if case .loaded = phase { return true }
        return false
    }

    // MARK: - Actions

    private func load() async {
        phase = .loading
        do {
            text = try await FileOperations.readText(at: request.entry.path, at: request.location)
            isDirty = false
            phase = .loaded
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func close() {
        if isDirty {
            confirmingDiscard = true
        } else {
            dismiss()
        }
    }

    private func save(thenClose: Bool) {
        guard !isSaving else { return }
        isSaving = true
        let snapshot = text
        let path = request.entry.path
        let location = request.location
        Task {
            do {
                try await FileOperations.writeText(snapshot, to: path, at: location)
                // Edits made while saving still count as unsaved.
                if text == snapshot { isDirty = false }
                onSaved()
                if thenClose { dismiss() }
            } catch {
                saveError = error.localizedDescription
            }
            isSaving = false
        }
    }
}

/// An `NSTextView` set up for code and config files: monospaced, no smart quotes or autocorrect.
struct PlainTextEditor: NSViewRepresentable {
    @Binding var text: String
    let onEdit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.delegate = context.coordinator
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.string = text
        DispatchQueue.main.async {
            textView.window?.makeFirstResponder(textView)
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? NSTextView, textView.string != text else { return }
        textView.string = text
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PlainTextEditor

        init(_ parent: PlainTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            parent.onEdit()
        }
    }
}
