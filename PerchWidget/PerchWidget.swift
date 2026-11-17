import SwiftUI
import WidgetKit

/// Watch-face complications for Perch.
///
/// The Watch app writes `ComplicationSnapshot` into the App Group from its
/// background refresh and calls `WidgetCenter.reloadAllTimelines()`; the
/// timeline policy is `.never` because only the app knows when the data is new.
@main
struct PerchWidgetBundle: WidgetBundle {
    var body: some Widget {
        PerchComplication()
    }
}

struct ComplicationEntry: TimelineEntry {
    let date: Date
    let snapshot: ComplicationSnapshot
}

struct PerchComplicationProvider: TimelineProvider {
    func placeholder(in context: Context) -> ComplicationEntry {
        ComplicationEntry(
            date: Date(),
            snapshot: ComplicationSnapshot(
                unread: 3,
                author: "Perch",
                text: "Your timeline, on your wrist.",
                updated: Date()
            )
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (ComplicationEntry) -> Void) {
        completion(ComplicationEntry(date: Date(), snapshot: AppGroup.loadSnapshot() ?? .empty))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ComplicationEntry>) -> Void) {
        let entry = ComplicationEntry(date: Date(), snapshot: AppGroup.loadSnapshot() ?? .empty)
        completion(Timeline(entries: [entry], policy: .never))
    }
}

struct PerchComplication: Widget {
    static let kind = "PerchComplication"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: PerchComplicationProvider()) { entry in
            ComplicationView(entry: entry)
        }
        .configurationDisplayName("Perch")
        .description("Unread notifications and the newest post from your timeline.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline, .accessoryCorner])
    }
}

struct ComplicationView: View {
    @Environment(\.widgetFamily) private var family
    let entry: ComplicationEntry

    var body: some View {
        Group {
            switch family {
            case .accessoryRectangular: rectangular
            case .accessoryInline: inline
            case .accessoryCorner: corner
            default: circular
            }
        }
        .containerBackground(for: .widget) { Color.clear }
    }

    // MARK: Circular — bird + unread count

    private var circular: some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: 0) {
                Image(systemName: "bird.fill")
                    .font(.system(size: 13, weight: .semibold))
                if entry.snapshot.unread > 0 {
                    Text("\(entry.snapshot.unread)")
                        .font(.system(size: 12, weight: .bold))
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                }
            }
            .padding(2)
        }
        .widgetAccentable()
    }

    // MARK: Rectangular — newest post: author + two lines

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 3) {
                Image(systemName: "bird.fill")
                Text(entry.snapshot.author ?? "Perch")
                    .font(.headline)
                    .lineLimit(1)
            }
            Text(bodyText)
                .font(.caption2)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Inline — single line of text

    private var inline: some View {
        Text("Perch" + inlineSuffix)
    }

    // MARK: Corner — bird with a curved label

    private var corner: some View {
        Image(systemName: "bird.fill")
            .font(.title3)
            .widgetLabel {
                Text(entry.snapshot.unread > 0 ? "\(entry.snapshot.unread) unread" : "Perch")
            }
    }

    // MARK: Text helpers

    private var trimmedText: String {
        entry.snapshot.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private var bodyText: String {
        if !trimmedText.isEmpty { return trimmedText }
        // `unread` is the notification badge, not a count of new posts.
        let n = entry.snapshot.unread
        return n > 0 ? "\(n) unread notification\(n == 1 ? "" : "s")" : "No new notifications"
    }

    private var inlineSuffix: String {
        if entry.snapshot.unread > 0 { return ": \(entry.snapshot.unread) unread" }
        if let author = entry.snapshot.author, !author.isEmpty { return ": " + author }
        return ""
    }
}
