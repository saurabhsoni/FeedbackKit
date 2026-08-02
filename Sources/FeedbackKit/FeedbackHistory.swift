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
    }

    public let id: UUID
    public let createdAt: Date
    public let category: FeedbackCategory
    public let body: String
    public let screenshotCount: Int
    public let state: State
    /// `work_note` — one sentence written for the reporter to read. Distinct
    /// from the private `notes` column, which is never returned to a client.
    public let detail: String?
    /// The build the fix first shipped in, compared against the running one.
    public let fixedInBuild: String?
    public let implementRequested: Bool

    /// What a row actually renders. `implemented` splits in two: the fix
    /// exists somewhere, versus the fix is in the build in this person's hand
    /// right now — which is the only version of the news they care about.
    public enum DisplayState: Sendable, Equatable {
        case received
        case queued
        case working
        case implemented
        case live
        case failed
        case notPlanned
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
        case body
        case screenshotCount = "screenshot_count"
        case state
        case detail
        case fixedInBuild = "fixed_in_build"
        case implementRequested = "implement_requested"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decode(UUID.self, forKey: .id)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        body = try container.decode(String.self, forKey: .body)
        screenshotCount = try container.decodeIfPresent(Int.self, forKey: .screenshotCount) ?? 0
        detail = try container.decodeIfPresent(String.self, forKey: .detail)
        fixedInBuild = try container.decodeIfPresent(String.self, forKey: .fixedInBuild)
        implementRequested = try container.decodeIfPresent(Bool.self, forKey: .implementRequested) ?? false

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

    private let appID: String
    private let deviceID: String
    private let transport: any FeedbackTransport

    init(appID: String, deviceID: String, transport: any FeedbackTransport) {
        self.appID = appID
        self.deviceID = deviceID
        self.transport = transport
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

    /// Marks what we hold as stale without throwing it away, so the next
    /// `load()` goes back to the network. Called after a submission: the list
    /// the user is most likely to open next no longer includes what they sent.
    func invalidate() {
        state = .idle
    }

    private func fetch() async {
        state = .loading
        do {
            items = try await transport.history(appID: appID, deviceID: deviceID)
            state = .loaded
        } catch {
            state = .failed((error as? FeedbackError)?.errorDescription ?? error.localizedDescription)
        }
    }
}
