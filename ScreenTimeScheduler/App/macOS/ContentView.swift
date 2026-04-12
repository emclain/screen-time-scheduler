import SwiftUI
import FamilyControls
import ManagedSettings
import os

#if os(macOS)

@MainActor
struct ContentView: View {
    // MARK: - Probe state
    @State private var probeReport: ProbeReport? = nil
    @State private var isRunning = false

    // MARK: - Family controls state
    @State private var authStatus: AuthorizationStatus = .notDetermined
    @State private var selection = TokenStore.shared.selection
    @State private var showPicker = false
    @State private var shieldedTokens: Set<ApplicationToken> = []

    private let store = ManagedSettingsStore()
    private let logger = Logger(subsystem: "com.example.sts", category: "shield-ui")

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Screen Time Scheduler (macOS)")
                .font(.title2)
                .padding(.top)

            Divider()

            // MARK: Probe section
            probeSection

            Divider()

            // MARK: Shield test section
            shieldSection
        }
        .padding()
        .frame(minWidth: 520, minHeight: 400)
        .familyActivityPicker(isPresented: $showPicker, selection: $selection)
        .onChange(of: selection) { newValue in
            TokenStore.shared.save(newValue)
        }
        .task {
            authStatus = AuthorizationCenter.shared.authorizationStatus
            shieldedTokens = store.shield.applications ?? []
        }
    }

    // MARK: - Probe section

    private var probeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Capability Probes")
                .font(.headline)

            Button(action: runProbes) {
                HStack {
                    if isRunning {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(isRunning ? "Running…" : "Run Probes")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isRunning)

            if let report = probeReport {
                ScrollView {
                    Text(report.summary)
                        .font(.system(.body, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(minHeight: 120)
                .background(Color(nsColor: .textBackgroundColor))
                .cornerRadius(6)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))

                Button("Copy to Clipboard") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(report.summary, forType: .string)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    // MARK: - Shield test section

    private var shieldSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Shield Test (screen-uc3)")
                .font(.headline)

            authRow

            if authStatus == .approved {
                pickerRow
                shieldControls
                shieldStateView
            }
        }
    }

    // MARK: Auth row

    @ViewBuilder
    private var authRow: some View {
        switch authStatus {
        case .approved:
            Label("Authorized", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .denied:
            Label("Authorization denied — enable in System Settings", systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)
        default:
            Button("Request Authorization") {
                Task { await requestAuth() }
            }
            .buttonStyle(.borderedProminent)
        }
    }

    // MARK: Picker row

    private var pickerRow: some View {
        HStack {
            Text("Selected apps: \(selection.applicationTokens.count)")
                .foregroundStyle(.secondary)
            Spacer()
            Button("Choose Apps…") { showPicker = true }
                .buttonStyle(.bordered)
        }
    }

    // MARK: Shield controls

    private var shieldControls: some View {
        HStack(spacing: 10) {
            Button("Shield All") {
                shieldAll()
            }
            .buttonStyle(.borderedProminent)
            .disabled(selection.applicationTokens.isEmpty)

            Button("Clear All") {
                clearAll()
            }
            .buttonStyle(.bordered)
            .disabled(shieldedTokens.isEmpty)
        }
    }

    // MARK: Shield state display

    @ViewBuilder
    private var shieldStateView: some View {
        let tokens = Array(shieldedTokens).sorted { $0.hashValue < $1.hashValue }
        VStack(alignment: .leading, spacing: 6) {
            if tokens.isEmpty {
                Text("No apps currently shielded.")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
            } else {
                Text("Currently shielded (\(tokens.count)):")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                ForEach(Array(tokens.enumerated()), id: \.offset) { index, token in
                    HStack {
                        Text("App \(index + 1)  (hash: \(token.hashValue))")
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.primary)
                        Spacer()
                        Button("Unshield") {
                            unshield(token)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .padding(8)
        .background(Color(nsColor: .textBackgroundColor))
        .cornerRadius(6)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
    }

    // MARK: - Actions

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

    private func shieldAll() {
        let tokens = selection.applicationTokens
        store.shield.applications = tokens
        shieldedTokens = store.shield.applications ?? []
        logInfo(Logger.shield, "\(LogEvent.shieldApplied): count=\(tokens.count)")
    }

    private func unshield(_ token: ApplicationToken) {
        var current = store.shield.applications ?? []
        current.remove(token)
        store.shield.applications = current.isEmpty ? nil : current
        shieldedTokens = store.shield.applications ?? []
        logInfo(Logger.shield, "token_unshielded remaining=\(shieldedTokens.count)")
    }

    private func clearAll() {
        store.shield.applications = nil
        shieldedTokens = []
        logInfo(Logger.shield, "\(LogEvent.shieldCleared): all shields removed")
    }

    private func runProbes() {
        isRunning = true
        probeReport = nil
        Task {
            let result = await CapabilityProbe(log: logger).runAll()
            probeReport = result
            isRunning = false
        }
    }
}

#endif
