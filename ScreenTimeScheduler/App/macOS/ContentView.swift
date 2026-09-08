import SwiftUI
import os

#if os(macOS)

@MainActor
struct ContentView: View {
    // MARK: - Probe state
    @State private var probeReport: ProbeReport? = nil
    @State private var isRunning = false

    private let logger = Logger(subsystem: "net.emclain.ScreenScheduler", category: "shield-ui")

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Screen Time Scheduler (macOS)")
                .font(.title2)
                .padding(.top)

            Divider()

            // MARK: Probe section
            probeSection

        }
        .padding()
        .frame(minWidth: 520, minHeight: 400)
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

    // MARK: - Actions

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
