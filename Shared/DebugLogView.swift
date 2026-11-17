import SwiftUI
import XKit

/// Recent requests, already redacted by `RequestLog` (no cookies, tokens or query strings).
struct DebugLogView: View {
    @State private var entries: [RequestLogEntry] = []

    var body: some View {
        List {
            if entries.isEmpty {
                Text("No requests yet.").foregroundStyle(.secondary)
            }
            ForEach(entries) { e in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(e.status.map(String.init) ?? "ERR")
                            .font(.caption.monospacedDigit().bold())
                            .foregroundStyle(color(e.status))
                        Text(e.method).font(.caption2.bold())
                        Spacer()
                        Text("\(e.durationMs) ms").font(.caption2).foregroundStyle(.secondary)
                    }
                    Text(e.path).font(.caption2.monospaced()).lineLimit(2)
                    if !e.note.isEmpty { Text(e.note).font(.caption2).foregroundStyle(.secondary).lineLimit(3) }
                    Text(e.date, style: .time).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Requests")
        .task { entries = await RequestLog.shared.all() }
        .refreshable { entries = await RequestLog.shared.all() }
        .toolbar {
            ToolbarItem {
                Button("Clear") { Task { await RequestLog.shared.clear(); entries = [] } }
            }
        }
    }

    private func color(_ s: Int?) -> Color {
        guard let s else { return .red }
        switch s {
        case 200..<300: return .green
        case 429: return .orange
        default: return .red
        }
    }
}
