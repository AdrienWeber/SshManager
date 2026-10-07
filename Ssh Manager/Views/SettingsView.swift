import AppKit
import SwiftUI

struct SettingsView: View {
    @Environment(ServerStore.self) private var store
    @AppStorage(TerminalLauncher.preferenceKey) private var terminalBundleID = TerminalLauncher.defaultPreference

    var body: some View {
        Form {
            Picker("Open sessions in", selection: $terminalBundleID) {
                if TerminalLauncher.isBuiltInAvailable {
                    Text("Inside SSH Manager").tag(TerminalLauncher.builtInID)
                    Divider()
                }
                ForEach(TerminalLauncher.installedTerminals) { app in
                    Text(app.name).tag(app.bundleID)
                }
            }

            LabeledContent("Generated ssh config") {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([SSHPaths.configFile])
                }
            }

            LabeledContent("Background connections") {
                Button("Close All") {
                    let servers = store.servers
                    Task {
                        for server in servers { await SSH.disconnect(server) }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }
}
