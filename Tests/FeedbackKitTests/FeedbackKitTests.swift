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
    // `general` is still here even though nothing offers it any more: the
    // constraint deliberately did not narrow, and rows written by builds
    // already in the field still say it.
    #expect(Set(FeedbackCategory.allCases.map(\.rawValue)) == ["bug", "idea", "general"])
}

@Test("The picker offers what can be acted on, and keeps the rest readable")
func selectableCategoriesDropGeneral() {
    #expect(FeedbackCategory.selectable == [.bug, .idea])
    // The distinction that matters: not offered, still understood. Removing the
    // case would break decoding of every legacy row and every older client.
    #expect(!FeedbackCategory.selectable.contains(.general))
    #expect(FeedbackCategory(rawValue: "general") == .general)
}

@Test("Category titles stay short enough for a segmented control")
func categoryTitlesAreShort() {
    for category in FeedbackCategory.allCases {
        #expect(category.title.count <= 10)
    }
}

// MARK: - Severity

@Test("Severity raw values are the wire format, most severe first")
func severityMatchesWireFormat() {
    // `severity smallint check (severity between 1 and 3)`, 1 = most severe, so
    // the runner's `order by severity asc` is already a priority queue.
    // Renumbering these silently reverses it.
    #expect(FeedbackSeverity.high.rawValue == 1)
    #expect(FeedbackSeverity.medium.rawValue == 2)
    #expect(FeedbackSeverity.low.rawValue == 3)
    #expect(FeedbackSeverity.allCases.map(\.rawValue) == [1, 2, 3])
}

@Test("The words change with the category but the value doesn't")
func severityWordsFollowCategory() {
    // The whole reason the words are a function rather than a property: the
    // same stored 1 is "Critical" about a bug and "Major" about an idea.
    #expect(FeedbackSeverity.high.title(for: .bug) == "Critical")
    #expect(FeedbackSeverity.medium.title(for: .bug) == "Important")
    #expect(FeedbackSeverity.low.title(for: .bug) == "Minor")
    #expect(FeedbackSeverity.high.title(for: .idea) == "Major")
    #expect(FeedbackSeverity.medium.title(for: .idea) == "Mid")
    #expect(FeedbackSeverity.low.title(for: .idea) == "Minor")
    // A legacy `general` row can be prefilled into the sheet by a
    // clarification, so it needs words too — the non-bug ones.
    #expect(FeedbackSeverity.high.title(for: .general) == "Major")
}

@Test("Severity words stay short enough for a segmented control")
func severityTitlesAreShort() {
    for severity in FeedbackSeverity.allCases {
        for category in FeedbackCategory.allCases {
            #expect(severity.title(for: category).count <= 10)
        }
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
    let original = sampleReport()

    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(FeedbackReport.self, from: data)

    #expect(decoded.id == original.id)
    #expect(decoded.body == original.body)
    #expect(decoded.category == .bug)
    #expect(decoded.severity == .high)
    #expect(decoded.userID == "001234.abcdef")
    #expect(decoded.attachments.first?.jpeg == Data([0xFF, 0xD8, 0xFF]))
    #expect(decoded.device.model == "iPhone14,3")
}

@Test("A report queued by an older build still decodes after the update")
func legacyQueuedReportSurvivesAnUpgrade() throws {
    // The failure this guards against is invisible and unrecoverable: the
    // synthesised decoder throws on a missing key, `FeedbackQueue.drain()`
    // treats an undecodable file as poison and deletes it, and a report the
    // user was told was safely recorded is gone. Every field added to
    // `FeedbackReport` from now on has to survive this test.
    let modern = try JSONEncoder().encode(sampleReport())
    var object = try #require(try JSONSerialization.jsonObject(with: modern) as? [String: Any])
    for added in ["severity", "userID", "clarifies"] {
        object.removeValue(forKey: added)
    }

    let legacy = try JSONSerialization.data(withJSONObject: object)
    let decoded = try JSONDecoder().decode(FeedbackReport.self, from: legacy)

    #expect(decoded.body == "The widget shows stale prices")
    // Matches what the insert trigger would have defaulted it to server-side,
    // so an old report and a new one land in the same place.
    #expect(decoded.severity == .medium)
    #expect(decoded.userID == nil)
    #expect(decoded.clarifies == nil)
}

// MARK: - Helpers

private func sampleReport() -> FeedbackReport {
    FeedbackReport(
        appID: "testapp",
        appVersion: "1.2.3",
        buildNumber: "42",
        body: "The widget shows stale prices",
        category: .bug,
        severity: .high,
        reporter: "agrima",
        userID: "001234.abcdef",
        deviceID: "abc-123",
        device: DeviceContext(
            model: "iPhone14,3", modelName: "iPhone 13 Pro Max",
            os: "iOS 26.4.1", locale: "en_IN", timeZone: "Asia/Kolkata",
            screen: "1284x2778@3x", appearance: "dark", textSize: "Large",
            lowPower: false, freeDiskMB: 8192
        ),
        attachments: [.init(id: UUID(), jpeg: Data([0xFF, 0xD8, 0xFF]), origin: .autoCapture)]
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
