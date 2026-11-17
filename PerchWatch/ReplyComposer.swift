import SwiftUI
import XKit

/// Reply sheet. On the Watch the `TextField` brings up dictation / scribble.
struct ReplyComposer: View {
    let tweet: XTweet

    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var sending = false
    @State private var error: String?
    @FocusState private var focused: Bool

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Reply to @\(tweet.displayed.author.screenName)")
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(2)

                    TextField("Write a reply", text: $text, axis: .vertical)
                        .font(.system(size: 15))
                        .lineLimit(3...6)
                        .focused($focused)

                    if let error {
                        Text(error)
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }

                    Button {
                        send()
                    } label: {
                        Text(sending ? "Sending…" : "Send")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(sending || trimmed.isEmpty)

                    Button("Cancel") { dismiss() }
                        .disabled(sending)
                        .frame(maxWidth: .infinity)
                }
                .padding(.horizontal, Metrics.horizontalPadding)
                .padding(.vertical, 6)
            }
            .background(Color.black)
            .navigationTitle("Reply")
            .onAppear { focused = true }
        }
    }

    private func send() {
        guard !sending, !trimmed.isEmpty else { return }
        let body = trimmed
        let replyTo = tweet.displayed.id
        sending = true
        error = nil
        Task {
            do {
                _ = try await app.client.createTweet(text: body, replyTo: replyTo)
                Haptics.success()
                dismiss()
            } catch {
                self.error = XError.from(error).localizedDescription
                Haptics.failure()
            }
            sending = false
        }
    }
}
