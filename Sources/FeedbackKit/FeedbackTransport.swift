import Foundation

/// The seam between "collect feedback" and "send it somewhere".
///
/// Everything above this protocol — the sheet, the shake trigger, screenshot
/// capture, the offline queue — is backend-agnostic. Swapping Supabase for
/// something else later means writing one new conformance, not touching the UI.
protocol FeedbackTransport: Sendable {
    /// Uploads attachments, then writes the row. Throws `FeedbackError`.
    func send(_ report: FeedbackReport) async throws

    /// Reads back what one install — or one account — has sent, newest first.
    /// Throws `FeedbackError`.
    ///
    /// Writing and reading are one protocol rather than two because they are
    /// one backend: a conformance that can insert a report but cannot say what
    /// became of it would only push the problem to the caller.
    func history(appID: String, deviceID: String, userID: String?) async throws -> [FeedbackHistoryItem]

    /// Whether this person's implement request starts work immediately, or
    /// waits for the developer to approve it. Throws `FeedbackError`.
    func capabilities(appID: String, deviceID: String, userID: String?) async throws -> Bool
}

/// Remembers the last answer `feedback_capabilities` gave, so the compose
/// sheet's footer doesn't start on one promise and swap to the other a second
/// later while a network round trip completes under the reader.
///
/// Only ever holds a *successful* answer. A miss reads `false`, which is the
/// same thing the cautious copy says, so an app that has never reached the
/// backend and an app that has been told "no" behave identically — see
/// `FeedbackPresenter.autoImplementAllowed` for why that matters.
struct FeedbackCapabilityCache {
    private let key: String
    private let defaults: UserDefaults

    /// Keyed by app rather than globally: one process only ever hosts one
    /// config, but a bare key would read as a lie the first time that stops
    /// being true.
    init(appID: String, defaults: UserDefaults) {
        key = "feedbackkit.autoImplement.v1.\(appID)"
        self.defaults = defaults
    }

    var lastKnown: Bool {
        defaults.bool(forKey: key)
    }

    func remember(_ allowed: Bool) {
        defaults.set(allowed, forKey: key)
    }
}

/// Supabase implementation: PostgREST for the row, Storage for the images.
///
/// No SDK dependency on purpose — this is two `URLSession` calls, and taking
/// supabase-swift would drag a large transitive graph into every app that ever
/// wants a feedback button.
struct SupabaseTransport: FeedbackTransport {
    let config: FeedbackConfig
    let session: URLSession

    private static let bucket = "feedback-shots"

    init(config: FeedbackConfig, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    func send(_ report: FeedbackReport) async throws {
        // Images first: the row references their paths, so a half-succeeded
        // submission should leave orphaned images (harmless, invisible) rather
        // than a row pointing at objects that were never uploaded.
        var paths: [String] = []
        for attachment in report.attachments {
            try await paths.append(upload(attachment, appID: report.appID))
        }
        try await insertRow(report, screenshotPaths: paths)
    }

    // MARK: - Storage

    private func upload(_ attachment: FeedbackReport.Attachment, appID: String) async throws -> String {
        let path = "\(appID)/\(attachment.id.uuidString.lowercased()).jpg"
        let url = config.projectURL
            .appending(path: "storage/v1/object")
            .appending(path: Self.bucket)
            .appending(path: path)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        // Deliberately NOT sending `x-upsert: true` — upsert needs SELECT and
        // UPDATE policies, which a write-only bucket does not grant, and would
        // turn every upload into a 403.
        applyAuth(to: &request)
        request.httpBody = attachment.jpeg

        try await perform(request, describing: "upload screenshot")
        return path
    }

    // MARK: - PostgREST

    private func insertRow(_ report: FeedbackReport, screenshotPaths: [String]) async throws {
        let url = config.projectURL.appending(path: "rest/v1/feedback")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // `return=minimal` is required, not just polite: `return=representation`
        // would make PostgREST read the row back, which RLS forbids, failing an
        // insert that actually succeeded.
        request.setValue("return=minimal", forHTTPHeaderField: "Prefer")
        applyAuth(to: &request)

        let row = Row(
            appID: report.appID,
            appVersion: report.appVersion,
            buildNumber: report.buildNumber,
            body: report.body,
            category: report.category.rawValue,
            severity: report.severity.rawValue,
            implementRequested: report.implementRequested,
            screenshots: screenshotPaths,
            reporter: report.reporter,
            userID: report.userID,
            clarifies: report.clarifies?.uuidString.lowercased(),
            deviceID: report.deviceID,
            device: report.device
        )
        request.httpBody = try JSONEncoder().encode(row)

        try await perform(request, describing: "save feedback")
    }

    /// Mirrors the insertable column grant in `setup.sql` exactly. The triage
    /// columns are absent because the shipped key cannot write them —
    /// `implement_requested` is the one exception, granted on its own so the
    /// app can ask for work without being able to claim any was done.
    ///
    /// `title` and `superseded_by` are conspicuously *not* here: the runner
    /// writes the first and a trigger writes the second, and granting either to
    /// the shipped key would let a client name and retire its own rows.
    /// `clarifies` is granted, but the trigger that acts on it re-checks that
    /// the referenced row belongs to the same reporter — see `setup.sql`.
    private struct Row: Encodable {
        let appID: String
        let appVersion: String
        let buildNumber: String
        let body: String
        let category: String
        let severity: Int
        let implementRequested: Bool
        let screenshots: [String]
        let reporter: String?
        let userID: String?
        /// Sent as a plain string rather than as a `UUID`: `JSONEncoder` writes
        /// those uppercased. Postgres casts either happily, but every other id
        /// this package puts on the wire — install id, storage paths — is
        /// lowercase, and one uppercase outlier is the kind of thing that
        /// eventually gets compared as a string somewhere.
        let clarifies: String?
        let deviceID: String
        let device: DeviceContext

        /// Postgres column names, which are snake_case.
        enum CodingKeys: String, CodingKey {
            case appID = "app_id"
            case appVersion = "app_version"
            case buildNumber = "build_number"
            case body
            case category
            case severity
            case implementRequested = "implement_requested"
            case screenshots
            case reporter
            case userID = "user_id"
            case clarifies
            case deviceID = "device_id"
            case device
        }
    }

    // MARK: - Read-back

    func history(appID: String, deviceID: String, userID: String?) async throws -> [FeedbackHistoryItem] {
        // An RPC rather than a filtered select: with the shipped key there is no
        // JWT to scope an RLS policy on, so the install ID has to be an argument
        // the function filters by internally, where the caller can't widen it.
        let url = config.projectURL.appending(path: "rest/v1/rpc/feedback_for_install")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuth(to: &request)
        request.httpBody = try Self.historyBody(appID: appID, deviceID: deviceID, userID: userID)

        let data = try await perform(request, describing: "load your feedback")

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = FeedbackHistoryItem.dateDecoding
        do {
            return try decoder.decode([FeedbackHistoryItem].self, from: data)
        } catch {
            throw FeedbackError.transport("Couldn't read your feedback: \(error.localizedDescription)")
        }
    }

    /// PostgREST matches RPC arguments by name, so these keys have to spell
    /// `feedback_for_install(p_app_id, p_device_id, p_user_id)` exactly. Split
    /// out from the request so a test can pin the names — getting them wrong is
    /// a 404 at runtime rather than a compile error.
    static func historyBody(appID: String, deviceID: String, userID: String?) throws -> Data {
        try JSONEncoder().encode(InstallArguments(appID: appID, deviceID: deviceID, userID: userID))
    }

    // MARK: - Capabilities

    /// Asks whether this person's implement request starts work straight away.
    ///
    /// The answer only changes one sentence of footer copy, but it is a sentence
    /// that makes a promise: telling someone their request goes straight to the
    /// workshop when it is actually going into an approval queue is the kind of
    /// small lie that costs the whole feature its credibility. The caller treats
    /// every failure as "no" for that reason — see `FeedbackPresenter`.
    func capabilities(appID: String, deviceID: String, userID: String?) async throws -> Bool {
        let url = config.projectURL.appending(path: "rest/v1/rpc/feedback_capabilities")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        // Shorter than the write paths on purpose: nothing waits on this and
        // nobody should be kept waiting by it.
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuth(to: &request)
        request.httpBody = try Self.capabilitiesBody(appID: appID, deviceID: deviceID, userID: userID)

        let data = try await perform(request, describing: "check your permissions")

        // `returns table (auto_implement boolean)` is a set-returning function,
        // so PostgREST sends an array even though the function guarantees
        // exactly one row. An empty array would mean the guarantee broke; read
        // it as false rather than throwing, since false is the safe answer.
        guard let rows = try? JSONDecoder().decode([CapabilityRow].self, from: data) else {
            throw FeedbackError.transport("Couldn't read your permissions.")
        }
        return rows.first?.autoImplement ?? false
    }

    /// Same naming discipline as `historyBody` — `feedback_capabilities(p_app_id,
    /// p_device_id, p_user_id)`.
    static func capabilitiesBody(appID: String, deviceID: String, userID: String?) throws -> Data {
        try JSONEncoder().encode(InstallArguments(appID: appID, deviceID: deviceID, userID: userID))
    }

    private struct CapabilityRow: Decodable {
        let autoImplement: Bool

        enum CodingKeys: String, CodingKey {
            case autoImplement = "auto_implement"
        }
    }

    /// Both RPCs identify the caller the same way, so they share one argument
    /// shape.
    ///
    /// An app with no accounts simply has no `p_user_id`; the synthesised
    /// encoder drops a nil optional, and `p_user_id text default null` means a
    /// missing argument and an explicit null land on the same value anyway.
    /// Either way the function's length guard is what stops an empty id
    /// matching rows — never this side.
    private struct InstallArguments: Encodable {
        let appID: String
        let deviceID: String
        let userID: String?

        enum CodingKeys: String, CodingKey {
            case appID = "p_app_id"
            case deviceID = "p_device_id"
            case userID = "p_user_id"
        }
    }

    // MARK: - Shared

    private func applyAuth(to request: inout URLRequest) {
        // Supabase wants the key in both headers, and rejects the request if
        // the bearer token differs from `apikey`.
        request.setValue(config.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(config.publishableKey)", forHTTPHeaderField: "Authorization")
    }

    /// Returns the response body so a reading call can decode it. The two
    /// write paths ignore it — one error-mapping implementation for all three
    /// beats a second copy that drifts.
    @discardableResult
    private func perform(_ request: URLRequest, describing action: String) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed,
                 .timedOut, .cannotConnectToHost, .cannotFindHost:
                throw FeedbackError.offline
            default:
                throw FeedbackError.transport("Couldn't \(action): \(error.localizedDescription)")
            }
        } catch {
            throw FeedbackError.transport("Couldn't \(action): \(error.localizedDescription)")
        }

        guard let http = response as? HTTPURLResponse else {
            throw FeedbackError.transport("Couldn't \(action).")
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            let detail = String(data: data, encoding: .utf8) ?? ""
            throw FeedbackError.rejected(status: http.statusCode, detail: Self.readable(detail))
        }
        return data
    }

    /// Supabase errors arrive as JSON like `{"message":"...","hint":null}`.
    /// Surface the message rather than dumping the envelope at the user.
    private static func readable(_ raw: String) -> String {
        guard
            let data = raw.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return raw.prefix(200).description }

        if let message = object["message"] as? String {
            return message
        }
        if let error = object["error"] as? String {
            return error
        }
        return raw.prefix(200).description
    }
}
