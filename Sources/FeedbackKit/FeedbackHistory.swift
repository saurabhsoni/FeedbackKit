import Foundation

/// One report this install sent, as the backend chooses to describe it back.
///
/// Deliberately not `FeedbackReport` read in reverse. The RPC returns a
/// narrower shape on purpose — no private triage notes, no reporter, no device,
/// and a count of screenshots rather than paths to them (the bucket stays
/// unreadable by the app). Modelling it as its own type keeps that boundary
/// visible instead of implying the round trip is symmetric.
public struct FeedbackHistoryItem: Identifiable, Sendable, Equatable, Decodable {
    /// The one user-facing vocabulary. Derived server-side in
    /// `feedback_for_install` so every app says the same thing and no client
    /// has to know that `status` and `work_state` are two different columns.
    public enum State: String, Sendable, Codable {
        case received, queued, working, implemented, failed
        case notPlanned = "not_planned"
        /// The triage pass read it and couldn't tell what to build. `detail`
        /// carries the question, and the reporter can answer it by resending.
        case unclear
        /// A later report replaced this one. Set by the server, never here.
        case superseded
    }

    public let id: UUID
    public let createdAt: Date
    public let category: FeedbackCategory
    /// A one-line summary written server-side once the row has been looked at.
    /// Nil until then — a list of freshly-sent reports has nothing but bodies,
    /// and inventing a title on-device would just be the first line again.
    public let title: String?
    public let body: String
    public let severity: FeedbackSeverity
    public let screenshotCount: Int
    public let state: State
    /// `work_note` — one sentence written for the reporter to read. Distinct
    /// from the private `notes` column, which is never returned to a client.
    public let detail: String?
    /// The build the fix first shipped in, compared against the running one.
    public let fixedInBuild: String?
    public let implementRequested: Bool
    /// The report that replaced this one, when it has been superseded.
    public let supersededBy: UUID?

    /// What a row actually renders. `implemented` splits in two: the fix
    /// exists somewhere, versus the fix is in the build in this person's hand
    /// right now — which is the only version of the news they care about.
    public enum DisplayState: Sendable, Equatable, CaseIterable {
        case received
        case queued
        case working
        case implemented
        case live
        case failed
        case notPlanned
        case unclear
        case superseded
    }

    /// True when the running build already contains the fix.
    ///
    /// Compared as integers whenever both sides look like one, because a fix
    /// marked for build 41 is also present in build 43 and a string compare
    /// would miss that. Anything else — a `1.2.3`-style build string — falls
    /// back to exact equality rather than inventing an ordering for it.
    public func isLive(inBuild currentBuild: String) -> Bool {
        guard let fixedInBuild else { return false }
        if let fixed = Int(fixedInBuild), let current = Int(currentBuild) {
            return current >= fixed
        }
        return fixedInBuild == currentBuild
    }

    public func displayState(inBuild currentBuild: String) -> DisplayState {
        switch state {
        case .received: .received
        case .queued: .queued
        case .working: .working
        case .implemented: isLive(inBuild: currentBuild) ? .live : .implemented
        case .failed: .failed
        case .notPlanned: .notPlanned
        case .unclear: .unclear
        case .superseded: .superseded
        }
    }

    /// Whether this row is waiting on the reporter rather than on the developer
    /// — the one state with something for them to *do*.
    ///
    /// The `supersededBy` guard is belt and braces: the server moves a row out
    /// of `unclear` as it supersedes it, so both conditions should agree. If a
    /// refresh ever catches them mid-flight, offering "Edit and resend" on a row
    /// that has already been answered is the worse of the two mistakes.
    public var needsClarification: Bool {
        state == .unclear && supersededBy == nil
    }
}

// MARK: - Vocabulary

public extension FeedbackHistoryItem.DisplayState {
    /// The words on the pill, written from the reporter's side of the exchange:
    /// what this means for them, not what column it came out of.
    ///
    /// Lives on the state rather than in the pill view because the status
    /// notification has to say the same thing, and two copies of a vocabulary
    /// drift the moment one of them is reworded.
    var title: String {
        switch self {
        case .received: "Received"
        case .queued: "Queued"
        case .working: "Being worked on"
        case .implemented: "Ready in the next update"
        case .live: "Live in this version"
        case .failed: "Needs a closer look"
        case .notPlanned: "Not planned"
        case .unclear: "Needs a detail"
        case .superseded: "Replaced"
        }
    }
}

extension FeedbackHistoryItem.DisplayState {
    /// A stable token for the persisted seen-state snapshot.
    ///
    /// Deliberately not `title`: rewording a pill would otherwise make every
    /// row in the snapshot look like it had changed, and fire a notification
    /// per report the next time the app came forward.
    var storageKey: String {
        switch self {
        case .received: "received"
        case .queued: "queued"
        case .working: "working"
        case .implemented: "implemented"
        case .live: "live"
        case .failed: "failed"
        case .notPlanned: "not_planned"
        case .unclear: "unclear"
        case .superseded: "superseded"
        }
    }
}

// MARK: - Decoding

extension FeedbackHistoryItem {
    /// Postgres column names, which are snake_case.
    private enum CodingKeys: String, CodingKey {
        case id
        case createdAt = "created_at"
        case category
        case title
        case body
        case severity
        case screenshotCount = "screenshot_count"
        case state
        case detail
        case fixedInBuild = "fixed_in_build"
        case implementRequested = "implement_requested"
        case supersededBy = "superseded_by"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decode(UUID.self, forKey: .id)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        body = try container.decode(String.self, forKey: .body)
        screenshotCount = try container.decodeIfPresent(Int.self, forKey: .screenshotCount) ?? 0
        detail = try container.decodeIfPresent(String.self, forKey: .detail)
        fixedInBuild = try container.decodeIfPresent(String.self, forKey: .fixedInBuild)
        implementRequested = try container.decodeIfPresent(Bool.self, forKey: .implementRequested) ?? false
        supersededBy = try container.decodeIfPresent(UUID.self, forKey: .supersededBy)

        // Decoded as a number and mapped, rather than as `FeedbackSeverity`
        // directly, for the same reason the words below fall back: a value
        // outside 1...3 must cost one field, not the row. Null means the row
        // predates the column, and the insert trigger defaults new rows to 2 —
        // so reading a missing one as `.medium` keeps old and new consistent.
        let severityValue = try container.decodeIfPresent(Int.self, forKey: .severity)
        severity = severityValue.flatMap(FeedbackSeverity.init(rawValue:)) ?? .medium

        // An unrecognised word means the server has learned one this build
        // hasn't. Falling back keeps the rest of the row — and every other row
        // in the response — readable; throwing would blank the whole screen
        // over a single vocabulary change deployed after the app shipped.
        let categoryName = try container.decode(String.self, forKey: .category)
        category = FeedbackCategory(rawValue: categoryName) ?? .general
        let stateName = try container.decode(String.self, forKey: .state)
        state = State(rawValue: stateName) ?? .received
    }

    /// PostgREST returns `timestamptz` in two shapes from the same column:
    /// `2026-08-02T10:11:12.345678+00:00` when there are microseconds, and
    /// `2026-08-02T10:11:12+00:00` when the value happens to land on a whole
    /// second. `includingFractionalSeconds` is a strictness switch, so no one
    /// parser can be assumed to read both — try each, and fail loudly rather
    /// than silently handing back a wrong date.
    static let dateDecoding: JSONDecoder.DateDecodingStrategy = .custom { decoder in
        let text = try decoder.singleValueContainer().decode(String.self)
        if let date = try? Self.fractionalSeconds.parse(text) {
            return date
        }
        if let date = try? Self.wholeSeconds.parse(text) {
            return date
        }
        throw DecodingError.dataCorrupted(
            DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "Expected an ISO 8601 timestamp, got \"\(text)\"."
            )
        )
    }

    /// `Date.ISO8601FormatStyle` rather than `ISO8601DateFormatter`: it is a
    /// `Sendable` value type, so these can be shared `static let`s without an
    /// `nonisolated(unsafe)` opt-out from Swift 6's checking.
    private static let fractionalSeconds = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let wholeSeconds = Date.ISO8601FormatStyle(includingFractionalSeconds: false)
}

// MARK: - Store

/// The reports this install has sent, and what happened to them.
///
/// Read-only by construction: the RPC behind it takes the install ID as an
/// argument and filters inside a security-definer function, so this can only
/// ever see rows this install wrote — there is no query shape that widens it.
@MainActor
@Observable
public final class FeedbackHistoryStore {
    public enum LoadState: Equatable, Sendable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    public private(set) var items: [FeedbackHistoryItem] = []
    public private(set) var state: LoadState = .idle

    /// How many reports have moved since the reporter last looked at this list.
    ///
    /// Drives the badge on `FeedbackHistoryButton`. Zero after `markSeen()`,
    /// and durable across launches otherwise — a status change noticed while
    /// the app was closed is exactly the case the badge exists for.
    public private(set) var unreadCount = 0

    private let appID: String
    private let deviceID: String
    /// The signed-in account, when the host app has one. Widens the RPC's scope
    /// from "this install" to "this install or this account", which is what
    /// makes history follow someone onto a second device.
    private var userID: String?
    private let transport: any FeedbackTransport
    private let watcher: FeedbackStatusWatcher
    /// The yardstick for "live for you", captured once — it cannot change
    /// while the process is running.
    private let currentBuild: String

    init(
        appID: String,
        deviceID: String,
        transport: any FeedbackTransport,
        watcher: FeedbackStatusWatcher = FeedbackStatusWatcher(),
        currentBuild: String = Bundle.mainInfoString("CFBundleVersion")
    ) {
        self.appID = appID
        self.deviceID = deviceID
        self.transport = transport
        self.watcher = watcher
        self.currentBuild = currentBuild
    }

    /// Loads once. Safe to call from a `.task` that runs on every appearance —
    /// a second call while one is in flight, or after one succeeded, does
    /// nothing. A previous failure is not cached, so reopening retries.
    public func load() async {
        guard state != .loading, state != .loaded else { return }
        await fetch()
    }

    /// Fetches again regardless of what is already held. Pull-to-refresh and
    /// the Retry button.
    public func refresh() async {
        await fetch()
    }

    /// Refreshes without disturbing whatever is on screen.
    ///
    /// This is what runs every time the app comes forward, to feed the status
    /// watcher. It deliberately never touches `state`: flipping to `.loading`
    /// would blank the list under a reader's hands if it happened to be open,
    /// and a failure is swallowed because nobody asked for this fetch — showing
    /// them an error about a request they didn't make is worse than staying on
    /// slightly stale rows.
    func refreshInBackground() async {
        guard let fetched = try? await transport.history(
            appID: appID, deviceID: deviceID, userID: userID
        ) else { return }

        items = fetched
        state = .loaded
        unreadCount = await watcher.reconcile(items: fetched, inBuild: currentBuild)
    }

    /// The reporter is looking at the list, so nothing in it is unread any more.
    public func markSeen() {
        unreadCount = 0
        watcher.clearUnread()
    }

    /// Marks what we hold as stale without throwing it away, so the next
    /// `load()` goes back to the network. Called after a submission: the list
    /// the user is most likely to open next no longer includes what they sent.
    func invalidate() {
        state = .idle
    }

    /// Follows the host app's account in and out.
    ///
    /// Signing in widens what the RPC returns; signing out narrows it. Either
    /// way what we are holding is now the wrong set of rows, and on the way out
    /// it is someone else's — so it is dropped rather than left on screen until
    /// a refresh happens to replace it.
    func updateUser(_ user: FeedbackUser?) {
        let identifier = user?.resolvedID
        guard identifier != userID else { return }
        userID = identifier
        items = []
        invalidate()
    }

    private func fetch() async {
        state = .loading
        do {
            let fetched = try await transport.history(appID: appID, deviceID: deviceID, userID: userID)
            items = fetched
            state = .loaded
            unreadCount = await watcher.reconcile(items: fetched, inBuild: currentBuild)
        } catch {
            state = .failed((error as? FeedbackError)?.errorDescription ?? error.localizedDescription)
        }
    }
}
