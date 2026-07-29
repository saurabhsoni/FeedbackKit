import Foundation

/// The seam between "collect feedback" and "send it somewhere".
///
/// Everything above this protocol — the sheet, the shake trigger, screenshot
/// capture, the offline queue — is backend-agnostic. Swapping Supabase for
/// something else later means writing one new conformance, not touching the UI.
protocol FeedbackTransport: Sendable {
    /// Uploads attachments, then writes the row. Throws `FeedbackError`.
    func send(_ report: FeedbackReport) async throws
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
            paths.append(try await upload(attachment, appID: report.appID))
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
            app_id: report.appID,
            app_version: report.appVersion,
            build_number: report.buildNumber,
            body: report.body,
            category: report.category.rawValue,
            screenshots: screenshotPaths,
            reporter: report.reporter,
            device_id: report.deviceID,
            device: report.device
        )
        request.httpBody = try JSONEncoder().encode(row)

        try await perform(request, describing: "save feedback")
    }

    /// Mirrors the insertable column grant in `setup.sql` exactly. The triage
    /// columns are absent because the shipped key cannot write them.
    private struct Row: Encodable {
        let app_id: String
        let app_version: String
        let build_number: String
        let body: String
        let category: String
        let screenshots: [String]
        let reporter: String?
        let device_id: String
        let device: DeviceContext
    }

    // MARK: - Shared

    private func applyAuth(to request: inout URLRequest) {
        // Supabase wants the key in both headers, and rejects the request if
        // the bearer token differs from `apikey`.
        request.setValue(config.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(config.publishableKey)", forHTTPHeaderField: "Authorization")
    }

    private func perform(_ request: URLRequest, describing action: String) async throws {
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
    }

    /// Supabase errors arrive as JSON like `{"message":"...","hint":null}`.
    /// Surface the message rather than dumping the envelope at the user.
    private static func readable(_ raw: String) -> String {
        guard
            let data = raw.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return raw.prefix(200).description }

        if let message = object["message"] as? String { return message }
        if let error = object["error"] as? String { return error }
        return raw.prefix(200).description
    }
}
