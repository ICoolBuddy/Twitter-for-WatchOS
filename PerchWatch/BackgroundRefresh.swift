import Foundation
import WatchKit
import WidgetKit
import XKit

/// Periodic background refresh + watch-face complication updates.
///
/// `PerchWatchApp` asks watchOS for a wake-up roughly every 30 minutes and
/// calls `handle()` from `.backgroundTask(.appRefresh)`. The handler always
/// asks for the next wake-up again, also when it bails out early.
enum BackgroundRefresh {
    /// Preferred interval between background runs (watchOS decides the exact time).
    static let interval: TimeInterval = 30 * 60
    /// Hard budget for the network work in one run; the system reclaims us after that.
    static let timeBudget: TimeInterval = 15

    /// Ask watchOS to wake us again in ~30 minutes.
    @MainActor
    static func schedule() {
        WKApplication.shared().scheduleBackgroundRefresh(
            withPreferredDate: Date().addingTimeInterval(interval),
            userInfo: nil
        ) { _ in }
    }

    /// Same as `schedule()`, for call sites that are not on the main actor.
    static func scheduleSoon() {
        Task { @MainActor in schedule() }
    }

    /// One background app refresh: freshen the cached timeline, the badge and
    /// the complication. Doing nothing (logged out / low power) is fine; we
    /// still reschedule.
    @MainActor
    static func handle() async {
        let app = AppModel.shared
        // A background launch may run before AppModel's first `reloadState()`
        // Task has finished, so make sure the session/account state is loaded.
        await app.reloadState()
        guard app.canBrowse else {
            schedule()
            return
        }
        guard !ProcessInfo.processInfo.isLowPowerModeEnabled else {
            schedule()
            return
        }

        await withTimeBudget {
            await refresh()
        }
        schedule()
    }

    @MainActor
    private static func refresh() async {
        let app = AppModel.shared
        let kind = HomeKind(rawValue: UserDefaults.standard.string(forKey: PerchSettings.homeKind) ?? "")
            ?? .following
        let cacheName = app.timelineCacheName(kind)

        var newest: XTweet?
        if let page = try? await app.client.homeTimeline(kind, cursor: nil) {
            TimelineDiskCache.save(page.items, name: cacheName)
            let tweets = page.items.flatMap(\.tweets)
            newest = tweets.first { !$0.isTombstone }
            // Warm exactly what the feed shows first (same URLs and decode sizes
            // as the rows, reposts included), within this run's time budget.
            await ImageLoader.shared.prefetchFeed(Array(page.items.displayTweets.prefix(8))).value
        } else {
            // Offline: keep the complication useful with the last cached post.
            newest = TimelineDiskCache.load(name: cacheName).flatMap(\.tweets).first { !$0.isTombstone }
        }

        await app.refreshBadge(force: true)

        let shown = newest?.displayed
        AppGroup.saveSnapshot(ComplicationSnapshot(
            unread: app.badge.notifications,
            author: shown?.author.name,
            text: shown.map { snippet($0.text) },
            updated: Date()
        ))
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// One-line version of a post that fits the rectangular complication.
    private static func snippet(_ text: String) -> String {
        let collapsed = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        if collapsed.count <= 140 { return collapsed }
        return String(collapsed.prefix(139)) + "…"
    }

    /// Run `operation`, but stop waiting for it after `timeBudget` seconds.
    private static func withTimeBudget(_ operation: @escaping @Sendable () async -> Void) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await operation() }
            group.addTask {
                let deadline = UInt64(timeBudget * 1_000_000_000)
                do { try await Task.sleep(nanoseconds: deadline) } catch {}
            }
            _ = await group.next()
            group.cancelAll()
        }
    }
}
