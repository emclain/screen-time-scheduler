import os
import SwiftUI
import FamilyControls

struct ContentView: View {
    @State private var authStatus: AuthorizationStatus = .notDetermined
    @State private var selection = TokenStore.shared.selection
    @State private var showPicker = false

    var body: some View {
        VStack(spacing: 24) {
            Text("Screen Time Scheduler")
                .font(.title2)
                .padding(.top)

            authSection

            if authStatus == .approved {
                pickerSection
            }
        }
        .padding()
        .familyActivityPicker(isPresented: $showPicker, selection: $selection)
        .onChange(of: selection) { newValue in
            TokenStore.shared.save(newValue)
        }
        .task {
            authStatus = AuthorizationCenter.shared.authorizationStatus
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
}
