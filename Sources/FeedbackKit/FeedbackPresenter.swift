#if canImport(UIKit)
import SwiftUI
import UIKit

/// Owns the feedback flow: when the sheet is up, what's attached, and what
/// happens on send. One instance lives in the environment, installed by
/// `.feedback(_:)`, so any view — or a shake — can trigger it.
@MainActor
@Observable
public final class FeedbackPresenter {
    /// Which of the package's sheets is up, if any.
    ///
    /// One optional route rather than a `Bool` per sheet: chaining two
    /// `.sheet(isPresented:)` on the same view silently presents only the
    /// first, and the bug looks like "the button does nothing" rather than
    /// like a modifier conflict.
    enum Route: String, Identifiable {
        case compose
        case history

        var id: String {
            rawValue
        }
    }

    private(set) var route: Route?

    /// A sheet queued to open as soon as the current one finishes closing.
    private var pendingRoute: Route?

    /// Whether any of the package's sheets is up. Still the guard on
    /// `present()`, which is what keeps a shake from screenshotting our own UI.
    public var isPresented: Bool {
        route != nil
    }

    /// What this install has already sent. Owned here rather than by the view
    /// so it outlives the sheet being closed and reopened.
    public let history: FeedbackHistoryStore

    /// The automatic capture of the app, taken at trigger time. Nil once the
    /// user removes it.
    var autoScreenshot: Data?
    /// Images the user attached themselves.
    var userAttachments: [Data] = []

    var draft = ""
    var category: FeedbackCategory = .general
    var implementRequested = false
    var reporterName: String
    var state: SubmissionState = .editing

    enum SubmissionState: Equatable {
        case editing
        case sending
        case sent
        case failed(String)
    }

    let config: FeedbackConfig
    private let identity: FeedbackIdentity
    private let queue: FeedbackQueue
    private let transport: any FeedbackTransport
    private let shake = ShakeDetector()

    public init(config: FeedbackConfig, session: URLSession = .shared) {
        self.config = config
        let transport = SupabaseTransport(config: config, session: session)
        self.transport = transport
        queue = FeedbackQueue(transport: transport, appID: config.appID)

        let identity = FeedbackIdentity.load()
        self.identity = identity
        reporterName = identity.reporterName ?? ""
        // The same install ID that goes out as `device_id` on every report is
        // what reads them back — there is no second identifier.
        history = FeedbackHistoryStore(
            appID: config.appID,
            deviceID: identity.installID,
            transport: transport
        )

        shake.onShake = { [weak self] in
            self?.present()
        }
    }

    // MARK: - Lifecycle

    func activate() {
        shake.start()
        Task { await queue.drain() }
    }

    func deactivate() {
        shake.stop()
    }

    // MARK: - Presenting

    /// Captures the screen, *then* presents.
    ///
    /// The order is the entire trick. `ScreenshotCapture.capture()` is
    /// synchronous, so by the time `isPresented` flips, the image is already in
    /// hand and shows the app as the user saw it — not the feedback sheet.
    public func present() {
        guard !isPresented else { return }
        pendingRoute = nil
        autoScreenshot = ScreenshotCapture.capture()
        userAttachments = []
        draft = ""
        implementRequested = false
        state = .editing
        route = .compose
    }

    /// Opens the list of this install's own reports.
    ///
    /// No screenshot: nothing about reading your own history is improved by a
    /// picture of the screen you opened it from, and capturing one would cost
    /// a full-screen render for an image nobody sends.
    public func presentHistory() {
        guard !isPresented else { return }
        pendingRoute = nil
        route = .history
    }

    public func dismiss() {
        route = nil
    }

    /// Swaps one of our sheets for another, from inside it.
    ///
    /// The hop through "no sheet at all" is not optional: assigning a new item
    /// to a `.sheet(item:)` that is already presenting cancels the current
    /// presentation and drops the new one on the floor. `onDismiss` is the only
    /// callback that fires once the first sheet is genuinely gone, so the
    /// second is queued behind it rather than timed against an animation.
    func replaceSheet(with next: Route) {
        pendingRoute = next
        route = nil
    }

    /// Bound to the sheet's `onDismiss`, so a swipe-to-dismiss resets too.
    func sheetDidDismiss() {
        reset()
        if let pendingRoute {
            self.pendingRoute = nil
            route = pendingRoute
        }
    }

    var routeBinding: Binding<Route?> {
        Binding(
            get: { self.route },
            set: { self.route = $0 }
        )
    }

    private func reset() {
        autoScreenshot = nil
        userAttachments = []
        draft = ""
        implementRequested = false
        state = .editing
    }

    // MARK: - Attachments

    func removeAutoScreenshot() {
        autoScreenshot = nil
    }

    /// Downscales off the main actor — a 48 MP library photo would otherwise
    /// block the UI for a noticeable beat while it decodes.
    func addUserAttachment(_ raw: Data) async {
        let prepared = await Task.detached { ImagePrep.downscaleAndEncode(raw) }.value
        guard let prepared else { return }
        userAttachments.append(prepared)
    }

    func removeUserAttachment(at index: Int) {
        guard userAttachments.indices.contains(index) else { return }
        userAttachments.remove(at: index)
    }

    var attachmentCount: Int {
        (autoScreenshot == nil ? 0 : 1) + userAttachments.count
    }

    // MARK: - Sending

    var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && state != .sending
    }

    func submit() async {
        let body = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }

        state = .sending

        let trimmedName = reporterName.trimmingCharacters(in: .whitespacesAndNewlines)
        FeedbackIdentity.saveReporterName(trimmedName)

        var attachments: [FeedbackReport.Attachment] = []
        if let autoScreenshot {
            attachments.append(.init(id: UUID(), jpeg: autoScreenshot, origin: .autoCapture))
        }
        for image in userAttachments {
            attachments.append(.init(id: UUID(), jpeg: image, origin: .userPicked))
        }

        let report = FeedbackReport(
            appID: config.appID,
            appVersion: Bundle.mainInfoString("CFBundleShortVersionString"),
            buildNumber: Bundle.mainInfoString("CFBundleVersion"),
            body: body,
            category: category,
            implementRequested: implementRequested,
            reporter: trimmedName.isEmpty ? nil : trimmedName,
            deviceID: identity.installID,
            device: DeviceContext.current(),
            attachments: attachments
        )

        do {
            try await transport.send(report)
            state = .sent
        } catch let error as FeedbackError where error.isRetryable {
            // Queued, so from the user's point of view this succeeded — which is
            // true: it is durably recorded and will send itself.
            await queue.enqueue(report)
            state = .sent
        } catch {
            state = .failed((error as? FeedbackError)?.errorDescription ?? error.localizedDescription)
        }

        // Whichever way that succeeded, any history already loaded is now one
        // report short of the truth — and this is the moment someone is most
        // likely to go looking at it.
        if state == .sent {
            history.invalidate()
        }
    }
}
#endif
