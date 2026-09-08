import os
import SwiftUI
import FamilyControls
import ManagedSettings

struct ContentView: View {
    @State private var authStatus: AuthorizationStatus = .notDetermined
    @State private var selection = TokenStore.shared.selection
    @State private var showPicker = false
    @State private var shieldedCount = 0

    /// Shields are written straight from the app process. On Mac Catalyst there
    /// is no DeviceActivityMonitor extension to write them from — the extension
    /// points do not exist on that platform — so this is the only path by which
    /// a Mac can shield anything at all.
    private let store = ManagedSettingsStore()

    var body: some View {
        VStack(spacing: 24) {
            Text("Screen Time Scheduler")
                .font(.title2)
                .padding(.top)

            authSection

            if authStatus == .approved {
                pickerSection
                Divider()
                shieldSection
            }
        }
        .padding()
        .familyActivityPicker(isPresented: $showPicker, selection: $selection)
        .onChange(of: selection) { newValue in
            TokenStore.shared.save(newValue)
        }
        .task {
            authStatus = AuthorizationCenter.shared.authorizationStatus
            refreshShieldState()
        }
    }

    // MARK: - Auth

    @ViewBuilder
    private var authSection: some View {
        switch authStatus {
        case .approved:
            Label("Authorized", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .denied:
            Label("Authorization denied — enable in Settings", systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)
        default:
            Button("Request Authorization") {
                Task { await requestAuth() }
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private func requestAuth() async {
        logInfo(Logger.auth, "\(LogEvent.authRequested): requesting .individual authorization")
        do {
            try await AuthorizationCenter.shared.requestAuthorization(for: .individual)
        } catch {
            logError(Logger.auth, "auth_failed error=\(error)")
        }
        authStatus = AuthorizationCenter.shared.authorizationStatus
        logInfo(Logger.auth, "\(LogEvent.authGranted): status=\(authStatus)")
    }

    // MARK: - Picker

    @ViewBuilder
    private var pickerSection: some View {
        VStack(spacing: 12) {
            Text("Selected apps: \(selection.applicationTokens.count)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button("Choose Apps to Block") {
                showPicker = true
            }
            .buttonStyle(.bordered)
        }
    }

    // MARK: - Shield

    @ViewBuilder
    private var shieldSection: some View {
        VStack(spacing: 12) {
            Text("Currently shielded: \(shieldedCount)")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Button("Apply Shield to Selected (\(selection.applicationTokens.count))") {
                applyShield()
            }
            .buttonStyle(.borderedProminent)
            .disabled(selection.applicationTokens.isEmpty)

            // Removes a single token from an active shield without clearing the
            // rest — the atomicPerTokenUnshield capability (PLAN.md risk 11).
            // If the other apps stay blocked and this one does not, it works.
            Button("Unshield One App") {
                unshieldOne()
            }
            .buttonStyle(.bordered)
            .disabled(shieldedCount == 0)

            Button("Clear Shield") {
                clearShield()
            }
            .buttonStyle(.bordered)
            .disabled(shieldedCount == 0)
        }
    }

    private func refreshShieldState() {
        shieldedCount = store.shield.applications?.count ?? 0
        logInfo(Logger.shield, "shield_state count=\(shieldedCount)")
    }

    private func applyShield() {
        let tokens = selection.applicationTokens
        store.shield.applications = tokens.isEmpty ? nil : tokens
        let hashes = tokens.map { String($0.hashValue) }.sorted().joined(separator: ",")
        logInfo(Logger.shield, "\(LogEvent.shieldApplied): count=\(tokens.count) hashes=[\(hashes)]")
        refreshShieldState()
    }

    private func unshieldOne() {
        guard var current = store.shield.applications, let removed = current.first else { return }
        current.remove(removed)
        store.shield.applications = current.isEmpty ? nil : current
        logInfo(Logger.shield,
                "shield_token_removed removed_hash=\(removed.hashValue) remaining=\(current.count)")
        refreshShieldState()
    }

    private func clearShield() {
        store.shield.applications = nil
        logInfo(Logger.shield, "\(LogEvent.shieldCleared)")
        refreshShieldState()
    }
}
