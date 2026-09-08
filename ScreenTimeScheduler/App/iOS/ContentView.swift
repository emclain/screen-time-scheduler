import os
import SwiftUI
import FamilyControls
import ManagedSettings

struct ContentView: View {
    @State private var authStatus: AuthorizationStatus = .notDetermined
    @State private var selection = TokenStore.shared.selection
    @State private var showPicker = false
    @State private var shieldedCount = 0
    @State private var lastAuthError: String?

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

    /// Both buttons stay visible in every state, and the raw status is always
    /// on screen. The earlier version swapped the button out for a label once
    /// the status left .notDetermined, which looked exactly like "clicking does
    /// nothing" while actually being "there is no longer a button".
    private var authSection: some View {
        VStack(spacing: 10) {
            Text("Authorization: \(statusText)")
                .font(.subheadline)
                .foregroundStyle(authStatus == .approved ? .green : .primary)

            HStack(spacing: 12) {
                Button("Request .individual") {
                    Task { await requestAuth(for: .individual) }
                }
                .buttonStyle(.borderedProminent)

                Button("Request .child") {
                    Task { await requestAuth(for: .child) }
                }
                .buttonStyle(.bordered)
            }

            // Surfaced on screen as well as logged: the machine under test has
            // no Xcode, and Console can be configured to hide messages.
            if let lastAuthError {
                Text(lastAuthError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private var statusText: String {
        switch authStatus {
        case .notDetermined: return "notDetermined"
        case .denied:        return "denied"
        case .approved:      return "approved"
        @unknown default:    return "unknown(\(authStatus.rawValue))"
        }
    }

    private func requestAuth(for member: FamilyControlsMember) async {
        let name = (member == .child) ? ".child" : ".individual"
        lastAuthError = nil
        logInfo(Logger.auth, "\(LogEvent.authRequested): requesting \(name) authorization")
        do {
            try await AuthorizationCenter.shared.requestAuthorization(for: member)
            logInfo(Logger.auth, "auth_returned_no_error member=\(name)")
        } catch {
            let detail = "\(error) | localized=\(error.localizedDescription)"
            lastAuthError = "\(name) failed: \(detail)"
            logError(Logger.auth, "auth_failed member=\(name) error=\(detail)")
        }
        authStatus = AuthorizationCenter.shared.authorizationStatus
        logInfo(Logger.auth, "\(LogEvent.authGranted): member=\(name) status=\(statusText)")
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
