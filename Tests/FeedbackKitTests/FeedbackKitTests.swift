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

// MARK: - Helpers

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
