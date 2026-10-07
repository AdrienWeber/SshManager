import AppKit
import SwiftUI

struct ServerEditorView: View {
    @Environment(ServerStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    private let isNew: Bool
    private let hasStoredSecret: Bool
    private let onSave: (Server) -> Void

    @State private var draft: Server
    @State private var secret = ""
    @State private var forgetSecret = false

    init(server: Server, isNew: Bool, onSave: @escaping (Server) -> Void = { _ in }) {
        self.isNew = isNew
        self.onSave = onSave
        hasStoredSecret = !isNew && KeychainStore.hasSecret(for: server.id)
        _draft = State(initialValue: server)
    }

    private var isValid: Bool {
        let host = draft.host.trimmingCharacters(in: .whitespaces)
        return !host.isEmpty && (1...65535).contains(draft.port) && validationMessage == nil
    }

    /// Hosts and usernames end up in ssh_config, where spaces and quotes would break them.
    private var validationMessage: String? {
        let forbidden = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'"))
        if draft.host.trimmingCharacters(in: .whitespaces).rangeOfCharacter(from: forbidden) != nil {
            return "The host can't contain spaces or quotes."
        }
        if draft.username.trimmingCharacters(in: .whitespaces).rangeOfCharacter(from: forbidden) != nil {
            return "The username can't contain spaces or quotes."
        }
        if draft.authMethod == .privateKey, draft.keyPath.contains("\"") {
            return "The key file path can't contain double quotes."
        }
        return nil
    }

    var body: some View {
        Form {
            Section("General") {
                TextField("Name", text: $draft.name, prompt: Text("Proxmox"))
                HStack {
                    TextField("Group", text: $draft.group, prompt: Text("Homelab"))
                    if !store.groupNames.isEmpty {
                        Menu {
                            ForEach(store.groupNames, id: \.self) { group in
                                Button(group) { draft.group = group }
                            }
                        } label: {
                            Image(systemName: "chevron.down")
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    }
                }
            }

            Section("Connection") {
                TextField("Host", text: $draft.host, prompt: Text("192.168.1.10 or vps.example.com"))
                TextField("Port", value: $draft.port, format: .number.grouping(.never))
                TextField("Username", text: $draft.username, prompt: Text("root"))
                if let validationMessage {
                    Text(validationMessage)
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            }

            Section("Authentication") {
                Picker("Method", selection: $draft.authMethod) {
                    ForEach(AuthMethod.allCases) { method in
                        Text(method.label).tag(method)
                    }
                }

                switch draft.authMethod {
                case .password:
                    SecureField("Password", text: $secret, prompt: Text(secretPrompt))
                case .privateKey:
                    HStack {
                        TextField("Key File", text: $draft.keyPath, prompt: Text("~/.ssh/id_ed25519"))
                        Button("Choose…") { chooseKey() }
                    }
                    SecureField("Passphrase", text: $secret, prompt: Text(hasStoredSecret ? secretPrompt : "Optional"))
                case .agent:
                    Text("Uses keys loaded in ssh-agent or the default keys in ~/.ssh.")
                        .foregroundStyle(.secondary)
                }

                if hasStoredSecret && draft.authMethod != .agent {
                    Toggle("Forget saved secret", isOn: $forgetSecret)
                }
            }

            Section("Notes") {
                TextEditor(text: $draft.notes)
                    .frame(minHeight: 60)
            }
        }
        .formStyle(.grouped)
        .frame(width: 500)
        .fixedSize(horizontal: false, vertical: true)
        .navigationTitle(isNew ? "New Server" : "Edit Server")
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

    private var secretPrompt: String {
        hasStoredSecret ? "Saved — leave empty to keep" : "Stored in your Keychain"
    }

    private func save() {
        var server = draft
        server.name = server.name.trimmingCharacters(in: .whitespaces)
        server.host = server.host.trimmingCharacters(in: .whitespaces)
        server.username = server.username.trimmingCharacters(in: .whitespaces)
        server.group = server.group.trimmingCharacters(in: .whitespaces)
        if server.name.isEmpty { server.name = server.host }
        if server.group.isEmpty { server.group = "Servers" }

        // nil keeps the existing secret, "" removes it.
        let newSecret: String?
        if server.authMethod == .agent || forgetSecret {
            newSecret = ""
        } else {
            newSecret = secret.isEmpty ? nil : secret
        }

        store.upsert(server, secret: newSecret)
        onSave(server)
        dismiss()
    }

    private func chooseKey() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory()).appending(path: ".ssh")
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let home = NSHomeDirectory()
        draft.keyPath = url.path.hasPrefix(home) ? "~" + url.path.dropFirst(home.count) : url.path
    }
}
