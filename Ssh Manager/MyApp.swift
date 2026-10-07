import SwiftUI

/// Custom entry point: when ssh launches this binary as its `SSH_ASKPASS` helper,
/// answer with the saved secret and exit before any UI is created.
@main
enum AppEntry {
    static func main() {
        AskPass.runIfRequested()
        MyApp.main()
    }
}

struct MyApp: App {
    @State private var store = ServerStore()
    @State private var transfers = TransferCenter()
    @State private var tunnels = TunnelManager()
    @State private var terminals = TerminalSessionManager()

    var body: some Scene {
        // A single window: terminal sessions live inside it, so they must not be duplicated.
        Window("SSH Manager", id: "main") {
            ContentView()
                .environment(store)
                .environment(transfers)
                .environment(tunnels)
                .environment(terminals)
                .frame(minWidth: 900, minHeight: 560)
        }

        Settings {
            SettingsView()
                .environment(store)
        }
    }
}
