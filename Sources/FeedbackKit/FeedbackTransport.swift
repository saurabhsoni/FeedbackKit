import Foundation

/// The seam between "collect feedback" and "send it somewhere".
///
/// Everything above this protocol — the sheet, the shake trigger, screenshot
/// capture, the offline queue — is backend-agnostic. Swapping Supabase for
/// something else later means writing one new conformance, not touching the UI.
protocol FeedbackTransport: Sendable {
    /// Uploads attachments, then writes the row. Throws `FeedbackError`.
    func send(_ report: FeedbackReport) async throws

    /// Reads back what one install has sent, newest first. Throws `FeedbackError`.
    ///
    /// Writing and reading are one protocol rather than two because they are
    /// one backend: a conformance that can insert a report but cannot say what
    /// became of it would only push the problem to the caller.
    func history(appID: String, deviceID: String) async throws -> [FeedbackHistoryItem]
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
            implementRequested: report.implementRequested,
            screenshots: screenshotPaths,
            reporter: report.reporter,
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
    private struct Row: Encodable {
        let appID: String
        let appVersion: String
        let buildNumber: String
        let body: String
        let category: String
        let implementRequested: Bool
        let screenshots: [String]
        let reporter: String?
        let deviceID: String
        let device: DeviceContext

        /// Postgres column names, which are snake_case.
        enum CodingKeys: String, CodingKey {
            case appID = "app_id"
            case appVersion = "app_version"
            case buildNumber = "build_number"
            case body
            case category
            case implementRequested = "implement_requested"
            case screenshots
            case reporter
            case deviceID = "device_id"
            case device
        }
    }

    // MARK: - Read-back

    func history(appID: String, deviceID: String) async throws -> [FeedbackHistoryItem] {
        // An RPC rather than a filtered select: with the shipped key there is no
        // JWT to scope an RLS policy on, so the install ID has to be an argument
        // the function filters by internally, where the caller can't widen it.
        let url = config.projectURL.appending(path: "rest/v1/rpc/feedback_for_install")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuth(to: &request)
        request.httpBody = try Self.historyBody(appID: appID, deviceID: deviceID)

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
    /// `feedback_for_install(p_app_id, p_device_id)` exactly. Split out from
    /// the request so a test can pin the names — getting them wrong is a 404
    /// at runtime rather than a compile error.
    static func historyBody(appID: String, deviceID: String) throws -> Data {
        try JSONEncoder().encode(HistoryArguments(appID: appID, deviceID: deviceID))
    }

    private struct HistoryArguments: Encodable {
        let appID: String
        let deviceID: String

        enum CodingKeys: String, CodingKey {
            case appID = "p_app_id"
            case deviceID = "p_device_id"
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
