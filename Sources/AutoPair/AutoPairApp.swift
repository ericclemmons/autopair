import SwiftUI

@main
struct AutoPairApp: App {
    @State private var appState = AppState()

    init() {
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra("AutoPair", systemImage: "link.circle.fill") {
            if appState.pairedDevices.isEmpty {
                Text("No paired devices found")
            } else {
                Section("Auto-connect when display attached") {
                    ForEach(appState.pairedDevices) { device in
                        let isSaved = appState.isDeviceSaved(device.address)
                        Toggle(isOn: Binding(
                            get: { isSaved },
                            set: { _ in appState.toggleDevice(device.address) }
                        )) {
                            Text("\(device.isConnected ? "🟢" : "⚪️") \(device.name.isEmpty ? device.address : device.name)")
                        }
                    }
                }

                Divider()

                Button("Refresh Devices") {
                    appState.refreshDevices()
                }

                Divider()

                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut("q")
            }
        }
        .menuBarExtraStyle(.menu)
    }
}
