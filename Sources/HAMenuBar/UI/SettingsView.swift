import SwiftUI

struct SettingsView: View {
    @Environment(HomeStore.self) private var store

    var body: some View {
        @Bindable var store = store
        TabView(selection: $store.settingsTab) {
            ConnectionSettingsView()
                .tabItem { Label("Connection", systemImage: "network") }
                .tag(SettingsTab.connection)
            EntityPickerView()
                .tabItem { Label("Entities", systemImage: "pin") }
                .tag(SettingsTab.entities)
        }
        .frame(width: 540, height: store.settingsTab == .entities ? 560 : 400)
        .background(BringWindowToFront())
    }
}

private struct ConnectionSettingsView: View {
    @Environment(HomeStore.self) private var store

    @State private var baseURL = ""
    @State private var token = ""
    @State private var testState: TestState = .idle
    /// Only Keychain failures are shown here; connection progress comes live from the store.
    @State private var keychainError: String?

    private enum TestState: Equatable {
        case idle, running, success(String), failure(String)
    }

    private var urlIsValid: Bool { HAEndpoint.webSocketURL(from: baseURL) != nil }

    var body: some View {
        Form {
            Section("Status") {
                StatusLine(
                    indicator: store.status.indicator,
                    text: store.status.label(haVersion: store.haVersion)
                )
                .animation(.easeInOut(duration: 0.2), value: store.status)
            }

            Section {
                TextField("Server URL", text: $baseURL, prompt: Text("http://homeassistant.local:8123"))
                    .textContentType(.URL)
                    .autocorrectionDisabled()
                SecureField(
                    "Access token",
                    text: $token,
                    prompt: Text(store.settings.hasToken ? "Saved in Keychain — leave empty to keep" : "Long-lived access token")
                )
            } footer: {
                Text("Create a token in Home Assistant → your profile → Security → Long-lived access tokens. It is stored in the macOS Keychain.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack(spacing: 10) {
                    Button("Test Connection", action: testConnection)
                        .disabled(!urlIsValid || testState == .running || (token.isEmpty && !store.settings.hasToken))
                    Spacer()
                    if store.settings.hasToken {
                        Button("Remove Token", role: .destructive, action: removeToken)
                    }
                    Button("Save & Connect", action: save)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!urlIsValid)
                }
                if testState != .idle {
                    testStatus
                }
                if let keychainError {
                    StatusLine(indicator: .failure, text: keychainError)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { baseURL = store.settings.baseURLString }
    }

    @ViewBuilder
    private var testStatus: some View {
        switch testState {
        case .idle:
            EmptyView()
        case .running:
            StatusLine(indicator: .pending, text: "Testing connection…")
        case let .success(version):
            StatusLine(indicator: .ok, text: "Test passed · Home Assistant \(version)")
        case let .failure(message):
            StatusLine(indicator: .failure, text: "Test failed: \(message)")
        }
    }

    private func testConnection() {
        guard let url = HAEndpoint.webSocketURL(from: baseURL) else { return }
        let candidate = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let tokenToTest = candidate.isEmpty ? store.settings.token() : candidate else { return }
        testState = .running
        Task {
            do {
                let version = try await HAWebSocketClient.testConnection(url: url, token: tokenToTest)
                testState = .success(version)
            } catch {
                testState = .failure(error.localizedDescription)
            }
        }
    }

    private func save() {
        store.settings.setBaseURL(baseURL)
        keychainError = nil
        do {
            if !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try store.settings.saveToken(token)
                token = ""
            }
        } catch {
            keychainError = "Could not save token: \(error.localizedDescription)"
        }
        store.start()
    }

    private func removeToken() {
        keychainError = nil
        do {
            try store.settings.saveToken("")
        } catch {
            keychainError = "Could not remove token: \(error.localizedDescription)"
        }
        store.start()
    }
}
