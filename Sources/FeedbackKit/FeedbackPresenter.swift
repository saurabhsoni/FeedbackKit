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
    var category: FeedbackCategory = .bug
    var severity: FeedbackSeverity = .medium
    var implementRequested = false
    var reporterName: String
    var state: SubmissionState = .editing

    /// The report this draft rewrites, when the reporter is answering a
    /// question. Nil for everything else, and cleared by `reset()` — a stale
    /// value here would quietly supersede an unrelated old report.
    private(set) var clarifies: UUID?
    /// The question that was asked, shown at the top of the draft so the person
    /// answering can see what they are answering.
    private(set) var clarifyingQuestion: String?

    /// Who the host app says this is. Nil for an app with no accounts.
    private(set) var user: FeedbackUser?

    /// The name the host app supplied, if it supplied one. Its presence is what
    /// removes the "Your name" field from the sheet.
    var hostSuppliedName: String? {
        user?.resolvedName
    }

    /// Whether an implement request from this person starts work immediately.
    ///
    /// A plain `Bool`, not an optional, because "we don't know yet" and "no"
    /// have to produce the same sentence: promising someone their request goes
    /// straight to the workshop and then queueing it for approval is a broken
    /// promise, while saying it will be reviewed and then watching it start
    /// immediately is a pleasant surprise. Only a successful `true` moves it.
    private(set) var autoImplementAllowed: Bool

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
    private let capabilityCache: FeedbackCapabilityCache

    public init(config: FeedbackConfig, session: URLSession = .shared) {
        self.config = config
        let cache = FeedbackCapabilityCache(appID: config.appID, defaults: .standard)
        capabilityCache = cache
        let transport = SupabaseTransport(config: config, session: session)
        self.transport = transport
        queue = FeedbackQueue(transport: transport, appID: config.appID)

        let identity = FeedbackIdentity.load()
        self.identity = identity
        reporterName = identity.reporterName ?? ""
        // Last known answer, so the footer doesn't flip from one promise to the
        // other a second after the sheet opens on someone who has seen it
        // before. A cache miss reads false, which is the safe copy.
        autoImplementAllowed = cache.lastKnown
        // The install ID that goes out as `device_id` on every report is what
        // reads them back; a signed-in account widens that to a second key.
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
        Task { await refreshCapabilities() }
        // Coming forward is the one moment we know the app is being looked at,
        // which makes it the moment to find out whether anything moved while it
        // wasn't. Deliberately quiet about failures — see `refreshInBackground`.
        Task { await history.refreshInBackground() }
    }

    func deactivate() {
        shake.stop()
    }

    // MARK: - Identity

    /// Takes the host app's word for who this is.
    ///
    /// Called on every change rather than once at construction, so signing in
    /// or out mid-session is picked up without anything being rebuilt: the next
    /// report carries the new account, and the history list re-scopes itself.
    func updateUser(_ user: FeedbackUser?) {
        guard user != self.user else { return }
        self.user = user

        // Migration, and it only ever runs one way. Once an app knows the
        // person's name, that name replaces whatever was typed into the old
        // field — which is now gone, so leaving a stale one would strand it.
        if let name = user?.resolvedName {
            FeedbackIdentity.adoptHostName(name)
            reporterName = name
        }

        history.updateUser(user)
        Task { await refreshCapabilities() }
    }

    /// Asks the backend whether this person is on the allowlist, and remembers
    /// a yes. A failure of any kind — offline, first run, a 500 — leaves the
    /// answer where it was rather than downgrading a cached yes on one bad
    /// network moment.
    private func refreshCapabilities() async {
        guard let allowed = try? await transport.capabilities(
            appID: config.appID, deviceID: identity.installID, userID: user?.resolvedID
        ) else { return }

        autoImplementAllowed = allowed
        capabilityCache.remember(allowed)
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
        pendingPrefill = nil
        autoScreenshot = ScreenshotCapture.capture()
        userAttachments = []
        draft = ""
        category = .bug
        severity = .medium
        clarifies = nil
        clarifyingQuestion = nil
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

    /// Opens the compose sheet as an answer to a question asked about an
    /// earlier report, prefilled with what that report said.
    ///
    /// Called from inside the history sheet, so it takes the same hop through
    /// "no sheet at all" as every other sheet swap — and that hop runs
    /// `reset()`, which exists precisely to make sure no draft survives a
    /// dismissal. The prefill therefore cannot be applied here: it would be
    /// wiped a frame later. It is parked instead and applied on the far side,
    /// which is the only place the compose sheet is about to appear with a
    /// draft it is *supposed* to keep.
    ///
    /// No screenshot either. `present()` captures one because the app is behind
    /// the sheet; here the history list is, and a picture of it tells nobody
    /// anything.
    public func presentClarification(of item: FeedbackHistoryItem) {
        let prefill = Prefill(
            body: item.body,
            category: item.category,
            severity: item.severity,
            clarifies: item.id,
            question: item.detail
        )
        guard isPresented else {
            // Not on screen at all — nothing to hop through, so apply directly.
            // An explicit request supersedes anything already queued, exactly
            // as it does in `present()`.
            pendingRoute = nil
            pendingPrefill = nil
            autoScreenshot = nil
            userAttachments = []
            implementRequested = false
            state = .editing
            apply(prefill)
            route = .compose
            return
        }
        pendingPrefill = prefill
        replaceSheet(with: .compose)
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
            // Before `route`, not after: the sheet's first render should
            // already have the text in it, rather than showing an empty editor
            // for a frame and then filling it in.
            if let pendingPrefill {
                self.pendingPrefill = nil
                apply(pendingPrefill)
            }
            route = pendingRoute
        }
    }

    var routeBinding: Binding<Route?> {
        Binding(
            get: { self.route },
            set: { self.route = $0 }
        )
    }

    /// A draft handed across the "no sheet at all" hop in `replaceSheet(with:)`.
    private struct Prefill {
        let body: String
        let category: FeedbackCategory
        let severity: FeedbackSeverity
        let clarifies: UUID
        let question: String?
    }

    private var pendingPrefill: Prefill?

    private func apply(_ prefill: Prefill) {
        draft = prefill.body
        category = prefill.category
        severity = prefill.severity
        clarifies = prefill.clarifies
        clarifyingQuestion = prefill.question
    }

    private func reset() {
        autoScreenshot = nil
        userAttachments = []
        draft = ""
        category = .bug
        severity = .medium
        clarifies = nil
        clarifyingQuestion = nil
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
            severity: severity,
            implementRequested: implementRequested,
            reporter: trimmedName.isEmpty ? nil : trimmedName,
            userID: user?.resolvedID,
            clarifies: clarifies,
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
