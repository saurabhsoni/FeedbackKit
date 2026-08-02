@testable import FeedbackKit
import Foundation
import Testing

// The read-back half: what the RPC sends, what the rows mean, and which
// changes are worth telling someone about. Split from `FeedbackKitTests` only
// because one file was getting long enough to stop being readable.

// MARK: - History decoding

@Test("Both shapes of PostgREST timestamp decode", arguments: [
    // Same column, same day: microseconds when there are any, and nothing at
    // all when the value lands on a whole second. One parser cannot read both.
    "2026-08-02T10:11:12.345678+00:00",
    "2026-08-02T10:11:12+00:00"
])
func historyDecodesBothTimestampShapes(timestamp: String) throws {
    let item = try decodeHistoryItem(createdAt: timestamp)
    // To the second — the fractional part is not what's under test.
    #expect(Int(item.createdAt.timeIntervalSince1970) == 1_785_665_472)
}

@Test("A timestamp that is neither shape fails loudly")
func historyRejectsUnparseableTimestamp() {
    #expect(throws: DecodingError.self) {
        try decodeHistoryItem(createdAt: "yesterday afternoon")
    }
}

@Test("Vocabulary the build has never heard falls back instead of throwing")
func historyFallsBackOnUnknownVocabulary() throws {
    // The server can start returning a word after this build shipped. One
    // unknown string must cost one field, not the whole screen.
    let item = try decodeHistoryItem(category: "regression", state: "escalated")
    #expect(item.category == .general)
    #expect(item.state == .received)
}

@Test("Known vocabulary still decodes as itself")
func historyDecodesKnownVocabulary() throws {
    let item = try decodeHistoryItem(category: "idea", state: "not_planned")
    #expect(item.category == .idea)
    #expect(item.state == .notPlanned)
    #expect(item.screenshotCount == 2)
    #expect(item.implementRequested)
    #expect(item.detail == "Looking at it now.")
}

@Test("The two new states decode as themselves", arguments: [
    ("unclear", FeedbackHistoryItem.State.unclear),
    ("superseded", FeedbackHistoryItem.State.superseded)
])
func historyDecodesNewStates(word: String, expected: FeedbackHistoryItem.State) throws {
    #expect(try decodeHistoryItem(state: word).state == expected)
}

@Test("The new columns decode, and their absence is not an error")
func historyDecodesNewColumns() throws {
    let titled = try decodeHistoryItem(
        title: "\"Widget prices go stale overnight\"",
        severity: "1",
        supersededBy: "\"9f8e7d6c-5b4a-4392-8281-706f5e4d3c2b\""
    )
    #expect(titled.title == "Widget prices go stale overnight")
    #expect(titled.severity == .high)
    #expect(titled.supersededBy?.uuidString.lowercased() == "9f8e7d6c-5b4a-4392-8281-706f5e4d3c2b")

    // A row the runner hasn't titled yet, and one written before the severity
    // column existed. Both are ordinary, so neither may throw.
    let bare = try decodeHistoryItem(title: "null", severity: "null", supersededBy: "null")
    #expect(bare.title == nil)
    #expect(bare.supersededBy == nil)
    // Server-side default for a new row is 2, so a missing one reads the same.
    #expect(bare.severity == .medium)

    // A severity outside 1...3 is a vocabulary the build hasn't learned; it
    // costs one field, like every other unknown value in this decoder.
    #expect(try decodeHistoryItem(severity: "7").severity == .medium)
}

@Test("Only an unclear row that hasn't already been answered can be resent")
func needsClarificationIsNarrow() {
    #expect(historyItem(state: .unclear).needsClarification)
    // The server moves a row out of `unclear` as it supersedes it. If a refresh
    // catches the two mid-flight, offering to answer an answered question is
    // the worse of the two possible mistakes.
    #expect(!historyItem(state: .unclear, supersededBy: UUID()).needsClarification)
    #expect(!historyItem(state: .working).needsClarification)
}

// MARK: - Live for you

@Test("Live-for-you compares build numbers numerically, then exactly")
func liveInBuildComparison() {
    // Shipped two builds ago, so whoever is on 43 already has it.
    #expect(implementedItem(fixedIn: "41").isLive(inBuild: "43"))
    #expect(implementedItem(fixedIn: "43").isLive(inBuild: "43"))
    #expect(!implementedItem(fixedIn: "44").isLive(inBuild: "43"))
    // A non-numeric build string has no ordering worth guessing at, so only an
    // exact match counts.
    #expect(implementedItem(fixedIn: "1.2.3").isLive(inBuild: "1.2.3"))
    #expect(!implementedItem(fixedIn: "1.2.3").isLive(inBuild: "1.2.4"))
    // Nothing is live until a build has been recorded against it.
    #expect(!implementedItem(fixedIn: nil).isLive(inBuild: "43"))
}

@Test("Implemented folds into live once the build is in hand")
func displayStateFoldsImplementedIntoLive() {
    let item = implementedItem(fixedIn: "41")
    #expect(item.displayState(inBuild: "43") == .live)
    #expect(item.displayState(inBuild: "40") == .implemented)
    // Only `implemented` folds — a build number can't make anything else live.
    #expect(implementedItem(fixedIn: nil).displayState(inBuild: "43") == .implemented)
}

@Test("Every state has a display state, including the two new ones", arguments: [
    (FeedbackHistoryItem.State.received, FeedbackHistoryItem.DisplayState.received),
    (.queued, .queued),
    (.working, .working),
    (.failed, .failed),
    (.notPlanned, .notPlanned),
    (.unclear, .unclear),
    (.superseded, .superseded)
])
func displayStateMapsEveryState(
    state: FeedbackHistoryItem.State,
    expected: FeedbackHistoryItem.DisplayState
) {
    #expect(historyItem(state: state).displayState(inBuild: "43") == expected)
}

// MARK: - Pill vocabulary

@Test("The new pills say what the reporter needs to hear")
func newPillWords() {
    #expect(FeedbackHistoryItem.DisplayState.unclear.title == "Needs a detail")
    #expect(FeedbackHistoryItem.DisplayState.superseded.title == "Replaced")
}

@Test("No two display states look the same in the snapshot")
func storageKeysAreDistinct() {
    // Two states sharing a key would make a real change invisible to the
    // watcher — the row would move and nobody would ever be told.
    let keys = FeedbackHistoryItem.DisplayState.allCases.map(\.storageKey)
    #expect(Set(keys).count == keys.count)
    #expect(FeedbackHistoryItem.DisplayState.allCases.allSatisfy { !$0.title.isEmpty })
}

// MARK: - RPC

@Test("The history RPC names its arguments the way the function declares them")
func historyRequestBodyMatchesFunctionSignature() throws {
    // PostgREST matches RPC arguments by name against
    // feedback_for_install(p_app_id, p_device_id, p_user_id). A typo is a 404
    // at runtime.
    let data = try SupabaseTransport.historyBody(
        appID: "testapp", deviceID: "abc-123", userID: "001234.abcdef"
    )
    let json = try JSONSerialization.jsonObject(with: data) as? [String: String]
    #expect(json == [
        "p_app_id": "testapp",
        "p_device_id": "abc-123",
        "p_user_id": "001234.abcdef"
    ])
}

@Test("An app with no accounts sends no p_user_id at all")
func historyRequestOmitsAbsentUser() throws {
    // Not "sends null": the cast below fails outright if the encoder writes one,
    // which is the point. The function declares `p_user_id text default null`,
    // so leaving it out is what lets the same call work against an app that
    // never signs anyone in.
    let data = try SupabaseTransport.historyBody(appID: "testapp", deviceID: "abc-123", userID: nil)
    let json = try JSONSerialization.jsonObject(with: data) as? [String: String]
    #expect(json == ["p_app_id": "testapp", "p_device_id": "abc-123"])
}

@Test("The capabilities RPC names its arguments the same way")
func capabilitiesRequestBodyMatchesFunctionSignature() throws {
    let data = try SupabaseTransport.capabilitiesBody(
        appID: "testapp", deviceID: "abc-123", userID: "001234.abcdef"
    )
    let json = try JSONSerialization.jsonObject(with: data) as? [String: String]
    #expect(json == [
        "p_app_id": "testapp",
        "p_device_id": "abc-123",
        "p_user_id": "001234.abcdef"
    ])
}

// MARK: - Status changes

@Test("The first ever run seeds the snapshot and says nothing")
func firstRunIsSilent() {
    // A fresh install with history behind it would otherwise greet its owner
    // with a notification per report they sent months ago.
    let items = [historyItem(state: .working), historyItem(state: .implemented)]
    #expect(FeedbackStatusDiff.changes(from: nil, to: items, inBuild: "43").isEmpty)
    #expect(FeedbackStatusDiff.snapshot(of: items, inBuild: "43").count == 2)
}

@Test("A row this install has never seen is recorded, not announced")
func unseenRowIsSilent() {
    // An empty dictionary means we *have* run before — so a row that isn't in
    // it appeared since, and the only way a row appears is that this person
    // wrote it seconds ago. "Received" is not news about a thing you just did.
    let fresh = historyItem(state: .received)
    #expect(FeedbackStatusDiff.changes(from: [:], to: [fresh], inBuild: "43").isEmpty)
}

@Test("A known row saying something new is the one thing that notifies")
func changedRowNotifies() throws {
    let item = historyItem(state: .working, detail: "Reproduced it, on it now.")
    let changes = FeedbackStatusDiff.changes(
        from: [item.id: "queued"], to: [item], inBuild: "43"
    )
    let change = try #require(changes.first)
    #expect(changes.count == 1)
    #expect(change.id == item.id)
    #expect(change.body == "Being worked on — Reproduced it, on it now.")
}

@Test("A row saying the same thing twice says nothing")
func unchangedRowIsSilent() {
    let item = historyItem(state: .working)
    #expect(FeedbackStatusDiff.changes(from: [item.id: "working"], to: [item], inBuild: "43").isEmpty)
}

@Test("Getting the build that contains the fix is itself the news")
func shippingABuildCountsAsAChange() throws {
    // Nothing moved server-side here — the build in the reporter's hand did.
    // The snapshot is deliberately build-relative so this still reads as news.
    let item = implementedItem(fixedIn: "41")
    let changes = FeedbackStatusDiff.changes(
        from: [item.id: "implemented"], to: [item], inBuild: "43"
    )
    #expect(try #require(changes.first).body == "Live in this version")
    // And on the build that predates the fix, nothing has happened at all.
    #expect(FeedbackStatusDiff.changes(from: [item.id: "implemented"], to: [item], inBuild: "40").isEmpty)
}

@Test("A notification leads with the title the runner wrote")
func notificationPrefersTheServerTitle() {
    let item = historyItem(title: "Widget prices go stale overnight")
    #expect(FeedbackStatusDiff.summary(of: item) == "Widget prices go stale overnight")
}

@Test("Without a title, the body is cut at a word boundary")
func notificationFallsBackToTheBody() {
    let long = historyItem(
        title: nil,
        body: "The widget on my lock screen keeps showing yesterday's prices"
    )
    let summary = FeedbackStatusDiff.summary(of: long)
    #expect(summary.hasSuffix("…"))
    #expect(summary.count <= 41)
    // Cut between words, never mid-syllable: a title that ends "yesterd…" reads
    // like a bug in the app rather than a summary of one.
    #expect(!summary.dropLast().hasSuffix(" "))
    #expect(long.body.hasPrefix(summary.dropLast()))

    // A body that fits is left exactly alone, with no ellipsis to imply
    // there's more.
    #expect(FeedbackStatusDiff.summary(of: historyItem(title: nil, body: "It crashed")) == "It crashed")

    // Leading newlines would otherwise produce a title that looks blank.
    let ragged = historyItem(title: nil, body: "\n\n  It   crashed\n")
    #expect(FeedbackStatusDiff.summary(of: ragged) == "It crashed")
}

@Test("A notification body without a note is just the pill words")
func notificationBodyWithoutDetail() {
    let item = historyItem(state: .failed, detail: nil)
    let changes = FeedbackStatusDiff.changes(from: [item.id: "working"], to: [item], inBuild: "43")
    #expect(changes.first?.body == "Needs a closer look")
}

// MARK: - Helpers

/// Raw JSON rather than an encoded round trip, because the shape under test is
/// the one PostgREST sends — including the parts this decoder has to tolerate.
/// The new columns are passed as literal JSON fragments so a test can hand them
/// `null` as easily as a value.
private func decodeHistoryItem(
    createdAt: String = "2026-08-02T10:11:12.345678+00:00",
    category: String = "idea",
    state: String = "not_planned",
    title: String = "null",
    severity: String = "2",
    supersededBy: String = "null"
) throws -> FeedbackHistoryItem {
    let json = """
    {
      "id": "6c1e5a9e-7f1a-4c0e-9d9b-4e1f2a3b4c5d",
      "created_at": "\(createdAt)",
      "category": "\(category)",
      "title": \(title),
      "body": "The widget shows stale prices",
      "severity": \(severity),
      "screenshot_count": 2,
      "state": "\(state)",
      "detail": "Looking at it now.",
      "fixed_in_build": null,
      "implement_requested": true,
      "superseded_by": \(supersededBy)
    }
    """
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = FeedbackHistoryItem.dateDecoding
    return try decoder.decode(FeedbackHistoryItem.self, from: Data(json.utf8))
}

private func historyItem(
    id: UUID = UUID(),
    title: String? = nil,
    body: String = "The widget shows stale prices",
    severity: FeedbackSeverity = .medium,
    state: FeedbackHistoryItem.State = .received,
    detail: String? = nil,
    fixedInBuild: String? = nil,
    supersededBy: UUID? = nil
) -> FeedbackHistoryItem {
    FeedbackHistoryItem(
        id: id,
        createdAt: Date(),
        category: .bug,
        title: title,
        body: body,
        severity: severity,
        screenshotCount: 0,
        state: state,
        detail: detail,
        fixedInBuild: fixedInBuild,
        implementRequested: true,
        supersededBy: supersededBy
    )
}

private func implementedItem(fixedIn build: String?) -> FeedbackHistoryItem {
    historyItem(state: .implemented, fixedInBuild: build)
}
