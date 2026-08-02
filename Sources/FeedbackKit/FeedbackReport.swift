import Foundation

/// What the user is sending. Categories map 1:1 to the database CHECK constraint.
public enum FeedbackCategory: String, Sendable, CaseIterable, Codable {
    case bug
    case idea
    case general

    /// Kept to one short word each — these sit in a segmented control, which
    /// truncates rather than wraps.
    public var title: String {
        switch self {
        case .bug: "Bug"
        case .idea: "Idea"
        case .general: "General"
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
    /// Whether the reporter asked for this to be worked on straight away. The
    /// app can only ever set the flag — the queue entry it implies is created
    /// server-side, since `work_state` is not a column the shipped key can write.
    let implementRequested: Bool
    let reporter: String?
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
        implementRequested: Bool = false,
        reporter: String?,
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
        self.implementRequested = implementRequested
        self.reporter = reporter
        self.deviceID = deviceID
        self.device = device
        self.attachments = attachments
        self.createdAt = createdAt
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
