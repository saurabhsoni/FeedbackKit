import Foundation

/// What the user is sending. Categories map 1:1 to the database CHECK constraint.
public enum FeedbackCategory: String, Sendable, CaseIterable, Codable {
    case bug
    case idea
    case general

    /// What the picker actually offers. `general` is deliberately absent.
    ///
    /// "General" turned out to be where everything went that the reporter
    /// couldn't be bothered to classify, and a general remark is the one thing
    /// nothing downstream can act on — it can't be triaged, queued or built.
    /// The *case* stays: rows written by builds already in the field still say
    /// `general`, the database CHECK still accepts it, and deleting the case
    /// would both break decoding and be a breaking API change. So it lives on
    /// as vocabulary for reading, not for writing.
    public static let selectable: [FeedbackCategory] = [.bug, .idea]

    /// Kept to one short word each — these sit in a segmented control, which
    /// truncates rather than wraps.
    public var title: String {
        switch self {
        case .bug: "Bug"
        case .idea: "Idea"
        // Only ever seen in the history list now, where "General" reads like a
        // label the user chose. They didn't — an older build chose it for them.
        case .general: "Feedback"
        }
    }

    public var symbolName: String {
        switch self {
        case .bug: "ladybug"
        case .idea: "lightbulb"
        case .general: "text.bubble"
        }
    }
}

/// How much this matters, from the reporter's side.
///
/// The raw values are the wire format: `severity smallint check (severity
/// between 1 and 3)`, **1 = most severe**, so a plain `order by severity asc`
/// on the server is already a priority queue. Don't renumber them.
///
/// The words are a function of the category rather than the case, because
/// "Critical" is a real thing to say about a bug and a faintly absurd thing to
/// say about a feature request. The *value* is what travels; the words are
/// presentation.
public enum FeedbackSeverity: Int, Sendable, CaseIterable, Codable {
    case high = 1, medium = 2, low = 3

    public func title(for category: FeedbackCategory) -> String {
        switch (category, self) {
        case (.bug, .high): "Critical"
        case (.bug, .medium): "Important"
        case (.bug, .low): "Minor"
        case (_, .high): "Major"
        case (_, .medium): "Mid"
        case (_, .low): "Minor"
        }
    }
}

/// One feedback submission, as it will be stored.
///
/// `Codable` so an unsent report can be written to disk and retried later —
/// see `FeedbackQueue`. Attachments are carried as raw JPEG bytes here and
/// only become storage paths once uploaded.
struct FeedbackReport: Sendable, Codable, Identifiable {
    let id: UUID
    let appID: String
    let appVersion: String
    let buildNumber: String
    let body: String
    let category: FeedbackCategory
    let severity: FeedbackSeverity
    /// Whether the reporter asked for this to be worked on straight away. The
    /// app can only ever set the flag — the queue entry it implies is created
    /// server-side, since `work_state` is not a column the shipped key can write.
    let implementRequested: Bool
    let reporter: String?
    /// The host app's own stable account id, when it has accounts. Written to
    /// `user_id`, which is what lets one person's history follow them onto a
    /// second device — `deviceID` alone can't, by design.
    let userID: String?
    /// The report this one rewrites, when the reporter was asked for a detail
    /// and came back with one. The server supersedes the referenced row.
    let clarifies: UUID?
    let deviceID: String
    let device: DeviceContext
    let attachments: [Attachment]
    let createdAt: Date

    struct Attachment: Sendable, Codable, Identifiable {
        let id: UUID
        /// Compressed JPEG bytes, already downscaled.
        let jpeg: Data
        /// Whether this was the automatic capture of the app or a user-picked image.
        let origin: Origin

        enum Origin: String, Sendable, Codable {
            case autoCapture
            case userPicked
        }
    }

    init(
        id: UUID = UUID(),
        appID: String,
        appVersion: String,
        buildNumber: String,
        body: String,
        category: FeedbackCategory,
        severity: FeedbackSeverity = .medium,
        implementRequested: Bool = false,
        reporter: String?,
        userID: String? = nil,
        clarifies: UUID? = nil,
        deviceID: String,
        device: DeviceContext,
        attachments: [Attachment],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.appID = appID
        self.appVersion = appVersion
        self.buildNumber = buildNumber
        self.body = body
        self.category = category
        self.severity = severity
        self.implementRequested = implementRequested
        self.reporter = reporter
        self.userID = userID
        self.clarifies = clarifies
        self.deviceID = deviceID
        self.device = device
        self.attachments = attachments
        self.createdAt = createdAt
    }

    /// Hand-written so a report queued by an **older build** still decodes.
    ///
    /// `FeedbackQueue` writes this type to disk as JSON and drains it after the
    /// app has been updated, so the on-disk shape is a compatibility surface,
    /// not an implementation detail. The synthesised decoder throws on a missing
    /// key, which would make every field added here quietly destroy a queue the
    /// user was promised was safe. Every field added from now on must be
    /// `decodeIfPresent` with a default that matches what the server would have
    /// applied anyway — `severity` defaults to 2 in the insert trigger, so an
    /// old report arriving without one lands in exactly the same place.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decode(UUID.self, forKey: .id)
        appID = try container.decode(String.self, forKey: .appID)
        appVersion = try container.decode(String.self, forKey: .appVersion)
        buildNumber = try container.decode(String.self, forKey: .buildNumber)
        body = try container.decode(String.self, forKey: .body)
        category = try container.decode(FeedbackCategory.self, forKey: .category)
        implementRequested = try container.decode(Bool.self, forKey: .implementRequested)
        reporter = try container.decodeIfPresent(String.self, forKey: .reporter)
        deviceID = try container.decode(String.self, forKey: .deviceID)
        device = try container.decode(DeviceContext.self, forKey: .device)
        attachments = try container.decode([Attachment].self, forKey: .attachments)
        createdAt = try container.decode(Date.self, forKey: .createdAt)

        // Added in 1.2.0 — absent from anything queued by 1.1.x.
        severity = try container.decodeIfPresent(FeedbackSeverity.self, forKey: .severity) ?? .medium
        userID = try container.decodeIfPresent(String.self, forKey: .userID)
        clarifies = try container.decodeIfPresent(UUID.self, forKey: .clarifies)
    }
}

/// Why a submission failed, in terms a user can act on.
public enum FeedbackError: Error, LocalizedError, Sendable {
    case notConfigured
    case emptyBody
    case attachmentTooLarge
    case offline
    /// The backend rejected the write. Carries the HTTP status and any body.
    case rejected(status: Int, detail: String)
    case transport(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            "Feedback isn't set up in this build."
        case .emptyBody:
            "Write a little about what you'd like to say."
        case .attachmentTooLarge:
            "That image is too large to send."
        case .offline:
            "You're offline — this will send once you're back on the network."
        case let .rejected(status, detail):
            detail.isEmpty ? "The server rejected this (\(status))." : detail
        case let .transport(message):
            message
        }
    }

    /// Whether keeping the report on disk and retrying later makes sense.
    /// A 4xx means the request itself is wrong, so retrying it forever would
    /// just be a queue that never drains.
    var isRetryable: Bool {
        switch self {
        case .offline, .transport:
            true
        case let .rejected(status, _):
            status >= 500 || status == 429
        case .notConfigured, .emptyBody, .attachmentTooLarge:
            false
        }
    }
}
