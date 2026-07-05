import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var draft = VPNConfiguration()
    @State private var draftUsername = ""
    @State private var draftPassword = ""
    @State private var didLoadDraft = false

    var body: some View {
        Form {
            Section("VPN Gateway") {
                TextField("Host", text: $draft.host)
                    .textFieldStyle(.roundedBorder)

                HStack {
                    Text("Port")
                    Spacer()
                    TextField("443", value: $draft.port, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                }
            }

            Section("Credentials") {
                TextField("Username", text: $draftUsername)
                    .textFieldStyle(.roundedBorder)

                SecureField("Password", text: $draftPassword)
                    .textFieldStyle(.roundedBorder)

                Label("Stored securely in macOS Keychain", systemImage: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Security") {
                TextField("Trusted certificate SHA256", text: $draft.trustedCert)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))

                TextField("Realm (optional)", text: $draft.realm)
                    .textFieldStyle(.roundedBorder)

                Text("Run once to obtain:\nopenssl s_client -connect host:443 </dev/null 2>/dev/null | openssl x509 -outform PEM | openssl dgst -sha256")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Behavior") {
                Toggle("Connect automatically on launch", isOn: $draft.autoConnect)
                Toggle("Launch at login", isOn: $draft.launchAtLogin)

                Stepper(
                    "Reconnect interval: \(draft.persistentInterval)s",
                    value: $draft.persistentInterval,
                    in: 0...300,
                    step: 5
                )

                Toggle("Set DNS via VPN", isOn: $draft.setDNS)
                Toggle("Set routes via VPN", isOn: $draft.setRoutes)
            }

            Section("Requirements") {
                if appState.openfortivpnInstalled {
                    Label("openfortivpn found", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Label("Install openfortivpn: brew install openfortivpn", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 540)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    appState.applySettings(
                        config: draft,
                        username: draftUsername,
                        password: draftPassword
                    )
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .onAppear {
            guard !didLoadDraft else { return }
            didLoadDraft = true
            loadDraft()
            appState.refreshSystemStatus()
        }
    }

    private func loadDraft() {
        draft = appState.config
        if let credentials = CredentialStore.resolveOptional() {
            draftUsername = credentials.username
            draftPassword = credentials.password
        }
    }
}
