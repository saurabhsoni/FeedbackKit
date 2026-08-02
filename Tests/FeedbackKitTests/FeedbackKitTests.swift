@testable import FeedbackKit
import Foundation
import Testing

// iOS-only package, so these run on a simulator destination:
//   xcodebuild test -scheme FeedbackKit \
//     -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
// `swift test` builds for macOS, where UIKit is absent, and will not work.

@Test("Categories match the database CHECK constraint")
func categoriesMatchDatabaseConstraint() {
    // If these drift from setup.sql, every insert of the changed category 400s.
    #expect(Set(FeedbackCategory.allCases.map(\.rawValue)) == ["bug", "idea", "general"])
}

@Test("Category titles stay short enough for a segmented control")
func categoryTitlesAreShort() {
    for category in FeedbackCategory.allCases {
        #expect(category.title.count <= 10)
    }
}

@Test("Config rejects an unsubstituted build setting")
func configRejectsUnsubstitutedPlaceholder() {
    // The failure this guards against: a missing Secrets.xcconfig leaves
    // "$(FEEDBACK_PROJECT_URL)" in Info.plist, which is a perfectly valid
    // string and would otherwise sail through to a confusing network error.
    let bundle = StubBundle(values: [
        "FeedbackProjectURL": "$(FEEDBACK_PROJECT_URL)",
        "FeedbackPublishableKey": "$(FEEDBACK_PUBLISHABLE_KEY)"
    ])
    #expect(FeedbackConfig.fromInfoPlist(appID: "testapp", bundle: bundle) == nil)
}

@Test("Config rejects empty values")
func configRejectsEmptyValues() {
    let bundle = StubBundle(values: [
        "FeedbackProjectURL": "",
        "FeedbackPublishableKey": "sb_publishable_abc"
    ])
    #expect(FeedbackConfig.fromInfoPlist(appID: "testapp", bundle: bundle) == nil)
}

@Test("Config reads a well-formed Info.plist")
func configReadsValidPlist() throws {
    let bundle = StubBundle(values: [
        "FeedbackProjectURL": "https://abcdef.supabase.co",
        "FeedbackPublishableKey": "sb_publishable_abc"
    ])
    let config = try #require(FeedbackConfig.fromInfoPlist(appID: "testapp", bundle: bundle))
    #expect(config.appID == "testapp")
    #expect(config.projectURL.absoluteString == "https://abcdef.supabase.co")
}

@Test("Only transient failures are retried", arguments: [
    (FeedbackError.offline, true),
    (FeedbackError.transport("boom"), true),
    (FeedbackError.rejected(status: 503, detail: ""), true),
    (FeedbackError.rejected(status: 429, detail: ""), true),
    // A 4xx will be just as malformed next time — retrying forever would wedge
    // the queue behind a report that can never succeed.
    (FeedbackError.rejected(status: 400, detail: ""), false),
    (FeedbackError.rejected(status: 403, detail: ""), false),
    (FeedbackError.emptyBody, false)
])
func retryabilityMatchesIntent(error: FeedbackError, expected: Bool) {
    #expect(error.isRetryable == expected)
}

@Test("A queued report survives a Codable round trip")
func reportRoundTrips() throws {
    let original = FeedbackReport(
        appID: "testapp",
        appVersion: "1.2.3",
        buildNumber: "42",
        body: "The widget shows stale prices",
        category: .bug,
        reporter: "agrima",
        deviceID: "abc-123",
        device: DeviceContext(
            model: "iPhone14,3", modelName: "iPhone 13 Pro Max",
            os: "iOS 26.4.1", locale: "en_IN", timeZone: "Asia/Kolkata",
            screen: "1284x2778@3x", appearance: "dark", textSize: "Large",
            lowPower: false, freeDiskMB: 8192
        ),
        attachments: [.init(id: UUID(), jpeg: Data([0xFF, 0xD8, 0xFF]), origin: .autoCapture)]
    )

    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(FeedbackReport.self, from: data)

    #expect(decoded.id == original.id)
    #expect(decoded.body == original.body)
    #expect(decoded.category == .bug)
    #expect(decoded.attachments.first?.jpeg == Data([0xFF, 0xD8, 0xFF]))
    #expect(decoded.device.model == "iPhone14,3")
}

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

// MARK: - RPC

@Test("The history RPC names its arguments the way the function declares them")
func historyRequestBodyMatchesFunctionSignature() throws {
    // PostgREST matches RPC arguments by name against
    // feedback_for_install(p_app_id, p_device_id). A typo is a 404 at runtime.
    let data = try SupabaseTransport.historyBody(appID: "testapp", deviceID: "abc-123")
    let json = try JSONSerialization.jsonObject(with: data) as? [String: String]
    #expect(json == ["p_app_id": "testapp", "p_device_id": "abc-123"])
}

// MARK: - Helpers

private func decodeHistoryItem(
    createdAt: String = "2026-08-02T10:11:12.345678+00:00",
    category: String = "idea",
    state: String = "not_planned"
) throws -> FeedbackHistoryItem {
    let json = """
    {
      "id": "6c1e5a9e-7f1a-4c0e-9d9b-4e1f2a3b4c5d",
      "created_at": "\(createdAt)",
      "category": "\(category)",
      "body": "The widget shows stale prices",
      "screenshot_count": 2,
      "state": "\(state)",
      "detail": "Looking at it now.",
      "fixed_in_build": null,
      "implement_requested": true
    }
    """
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = FeedbackHistoryItem.dateDecoding
    return try decoder.decode(FeedbackHistoryItem.self, from: Data(json.utf8))
}

private func implementedItem(fixedIn build: String?) -> FeedbackHistoryItem {
    FeedbackHistoryItem(
        id: UUID(),
        createdAt: Date(),
        category: .bug,
        body: "The widget shows stale prices",
        screenshotCount: 0,
        state: .implemented,
        detail: nil,
        fixedInBuild: build,
        implementRequested: true
    )
}

/// Stands in for `Bundle.main` so plist parsing can be tested without a host app.
private final class StubBundle: Bundle, @unchecked Sendable {
    private let values: [String: String]

    init(values: [String: String]) {
        self.values = values
        super.init()
    }

    override func object(forInfoDictionaryKey key: String) -> Any? {
        values[key]
    }
}
