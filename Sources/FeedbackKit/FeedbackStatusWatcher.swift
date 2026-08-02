import Foundation
#if canImport(UIKit)
import UserNotifications
#endif

/// Works out what has actually changed since the reporter last looked.
///
/// Split out from the watcher, and free of both `UserDefaults` and
/// `UserNotifications`, because this is the part with the judgement in it —
/// "is this news?" is a question worth testing without a notification centre
/// or a bundle identifier in scope.
enum FeedbackStatusDiff {
    /// One piece of news, already phrased.
    struct Change: Equatable, Sendable {
        let id: UUID
        let title: String
        let body: String
    }

    /// What every row's pill says right now, in the shape that gets persisted.
    ///
    /// `uniquingKeysWith` rather than `uniqueKeysWithValues`: ids are a primary
    /// key so a duplicate shouldn't be possible, and trapping the app over a
    /// server oddity would be an absurd price for a snapshot nobody sees.
    static func snapshot(of items: [FeedbackHistoryItem], inBuild build: String) -> [UUID: String] {
        Dictionary(
            items.map { ($0.id, $0.displayState(inBuild: build).storageKey) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    /// The rows whose state genuinely moved, and are therefore worth telling
    /// someone about.
    ///
    /// Two silences are deliberate:
    ///
    /// * `seen == nil` is the first run — the snapshot has never been written.
    ///   Everything would look new, and a fresh install would greet its owner
    ///   with a notification per historical report. Seed and say nothing.
    /// * A row present in `items` but absent from a snapshot that *does* exist
    ///   is one this install has never seen — which, since the only way a row
    ///   gets here is that this person wrote it, means they sent it seconds ago.
    ///   "Received" is not news about a thing you just did. Record it, stay quiet.
    ///
    /// So the only thing that notifies is a known row saying something new.
    static func changes(
        from seen: [UUID: String]?,
        to items: [FeedbackHistoryItem],
        inBuild build: String
    ) -> [Change] {
        guard let seen else { return [] }

        return items.compactMap { item in
            let state = item.displayState(inBuild: build)
            guard
                let previous = seen[item.id],
                previous != state.storageKey
            else { return nil }

            return Change(id: item.id, title: summary(of: item), body: body(for: item, state: state))
        }
    }

    /// What to call this report on a notification an inch high.
    ///
    /// The server-written title when there is one; otherwise the opening of the
    /// body, cut at a word boundary — a title that ends mid-syllable reads like
    /// a bug in the app rather than a summary. Whitespace is flattened first
    /// because a body that starts with a line break would otherwise produce a
    /// title that appears to be blank.
    static func summary(of item: FeedbackHistoryItem, limit: Int = 40) -> String {
        if let title = item.title, !title.isEmpty {
            return title
        }

        let flattened = item.body.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard flattened.count > limit else { return flattened }

        let cut = flattened.prefix(limit)
        // Only back off to a word boundary if there is one late enough to leave
        // a useful amount of text; one very long first word is better truncated
        // than reduced to nothing.
        if let space = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: space) > limit / 2 {
            return String(cut[..<space]) + "…"
        }
        return cut.trimmingCharacters(in: .whitespaces) + "…"
    }

    /// The pill words, plus whatever the developer wrote for the reporter.
    /// The words alone are the whole point of the notification; `detail` is
    /// what turns "Needs a detail" into an answerable question.
    static func body(for item: FeedbackHistoryItem, state: FeedbackHistoryItem.DisplayState) -> String {
        guard let detail = item.detail, !detail.isEmpty else { return state.title }
        return "\(state.title) — \(detail)"
    }
}

// MARK: - Watcher

/// Tells the reporter when something they sent moves.
///
/// No push, no server, no device token: the app already asks for its own
/// history every time it comes forward, so the only missing piece is
/// remembering what each row said last time. That makes this a diff against a
/// snapshot in `UserDefaults` rather than an infrastructure project.
@MainActor
final class FeedbackStatusWatcher {
    /// Persisted as `[String: String]` even though it is modelled as
    /// `[UUID: String]` — a property list has no UUID key type, and writing one
    /// through `UserDefaults` would fail silently at runtime rather than at
    /// compile time.
    private static let snapshotKey = "feedbackkit.seenStates.v1"
    private static let unreadKey = "feedbackkit.unread.v1"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Folds a freshly fetched history into what we knew, notifies about
    /// anything that moved, and returns the number of reports the reporter
    /// hasn't looked at since.
    func reconcile(items: [FeedbackHistoryItem], inBuild build: String) async -> Int {
        let changes = FeedbackStatusDiff.changes(from: loadSnapshot(), to: items, inBuild: build)

        // Written before the notifications are posted, not after: a snapshot
        // that isn't saved because the app was killed mid-`add` would notify
        // about the same change again on the next launch, and a duplicate
        // notification is worse than a missed one.
        saveSnapshot(FeedbackStatusDiff.snapshot(of: items, inBuild: build))

        // Unread survives a relaunch — someone who sees a notification, ignores
        // it, and opens the app an hour later should still find the badge that
        // tells them where to look. Intersecting with what came back drops rows
        // that have aged past the RPC's 100-row window.
        var unread = loadUnread().intersection(Set(items.map(\.id)))
        unread.formUnion(changes.map(\.id))
        saveUnread(unread)

        if !changes.isEmpty {
            await post(changes)
        }
        return unread.count
    }

    /// Called when the history list is on screen: they are looking at it now.
    func clearUnread() {
        defaults.removeObject(forKey: Self.unreadKey)
    }

    // MARK: - Notifications

    #if canImport(UIKit)
    private func post(_ changes: [FeedbackStatusDiff.Change]) async {
        let center = UNUserNotificationCenter.current()
        guard await isAuthorized(center) else { return }

        for change in changes {
            let content = UNMutableNotificationContent()
            content.title = change.title
            content.body = change.body

            // Keyed by the report, so a row that moves twice replaces its own
            // earlier notification instead of stacking a history of itself in
            // Notification Centre. A nil trigger delivers immediately.
            let request = UNNotificationRequest(
                identifier: "feedbackkit.status.\(change.id.uuidString)",
                content: content,
                trigger: nil
            )
            try? await center.add(request)
        }
    }

    /// Asks for **provisional** authorization, and only ever provisional.
    ///
    /// That is what makes this safe to put in a package: provisional
    /// authorization is granted without showing a prompt and delivers quietly
    /// to Notification Centre, so adding FeedbackKit to an app can never spend
    /// the single chance iOS gives that app to ask for notifications properly,
    /// and can never produce a permission alert the integrator didn't design.
    /// A host app that later asks for full authorization is unaffected — its
    /// prompt still appears, and promoting the setting promotes these too.
    ///
    /// Never call `requestAuthorization` from this package with a
    /// non-provisional option set.
    private func isAuthorized(_ center: UNUserNotificationCenter) async -> Bool {
        await (try? center.requestAuthorization(options: [.alert, .sound, .provisional])) ?? false
    }
    #else
    private func post(_: [FeedbackStatusDiff.Change]) async {}
    #endif

    // MARK: - Storage

    private func loadSnapshot() -> [UUID: String]? {
        // An *absent* key is the first run; an empty dictionary is a real state
        // (an install that has looked and found nothing). Collapsing the two
        // would re-seed silently every time someone's history was empty, and
        // then miss the first change after they finally sent something.
        guard let raw = defaults.dictionary(forKey: Self.snapshotKey) as? [String: String] else { return nil }
        return Dictionary(
            raw.compactMap { key, value in UUID(uuidString: key).map { ($0, value) } },
            uniquingKeysWith: { first, _ in first }
        )
    }

    private func saveSnapshot(_ snapshot: [UUID: String]) {
        let raw = Dictionary(
            snapshot.map { ($0.key.uuidString, $0.value) },
            uniquingKeysWith: { first, _ in first }
        )
        defaults.set(raw, forKey: Self.snapshotKey)
    }

    private func loadUnread() -> Set<UUID> {
        let raw = defaults.stringArray(forKey: Self.unreadKey) ?? []
        return Set(raw.compactMap(UUID.init(uuidString:)))
    }

    private func saveUnread(_ unread: Set<UUID>) {
        guard !unread.isEmpty else {
            defaults.removeObject(forKey: Self.unreadKey)
            return
        }
        defaults.set(unread.map(\.uuidString), forKey: Self.unreadKey)
    }
}
