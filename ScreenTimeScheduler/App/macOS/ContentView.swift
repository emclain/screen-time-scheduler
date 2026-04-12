import SwiftUI
import os

#if os(macOS)

@MainActor
struct ContentView: View {
    @State private var report: ProbeReport? = nil
    @State private var isRunning = false

    private let logger = Logger(subsystem: "com.example.sts", category: "probe")

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Screen Time Scheduler (macOS)")
                .font(.title2)
                .padding(.top)

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

            if let report {
                ScrollView {
                    Text(report.summary)
                        .font(.system(.body, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(minHeight: 200)
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
        .padding()
        .frame(minWidth: 500, minHeight: 300)
    }

    private func runProbes() {
        isRunning = true
        report = nil
        Task {
            let result = await CapabilityProbe(log: logger).runAll()
            report = result
            isRunning = false
        }
    }
}

#endif
