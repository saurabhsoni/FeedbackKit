#if canImport(UIKit)
import SwiftUI
import UIKit

/// Owns the feedback flow: when the sheet is up, what's attached, and what
/// happens on send. One instance lives in the environment, installed by
/// `.feedback(_:)`, so any view — or a shake — can trigger it.
@MainActor
@Observable
public final class FeedbackPresenter {
    public private(set) var isPresented = false

    /// The automatic capture of the app, taken at trigger time. Nil once the
    /// user removes it.
    var autoScreenshot: Data?
    /// Images the user attached themselves.
    var userAttachments: [Data] = []

    var draft = ""
    var category: FeedbackCategory = .general
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
        transport = SupabaseTransport(config: config, session: session)
        queue = FeedbackQueue(transport: transport, appID: config.appID)
        identity = FeedbackIdentity.load()
        reporterName = identity.reporterName ?? ""

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
        autoScreenshot = ScreenshotCapture.capture()
        userAttachments = []
        draft = ""
        state = .editing
        isPresented = true
    }

    public func dismiss() {
        isPresented = false
    }

    /// Bound to the sheet so a swipe-to-dismiss also resets state.
    var presentationBinding: Binding<Bool> {
        Binding(
            get: { self.isPresented },
            set: { newValue in
                self.isPresented = newValue
                if !newValue {
                    self.reset()
                }
            }
        )
    }

    private func reset() {
        autoScreenshot = nil
        userAttachments = []
        draft = ""
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
            appVersion: Self.bundleString("CFBundleShortVersionString"),
            buildNumber: Self.bundleString("CFBundleVersion"),
            body: body,
            category: category,
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
    }

    /// `Bundle.main`, never `Bundle.module` — the latter is the package's own
    /// resource bundle with a generated Info.plist, and carries the package's
    /// version rather than the host app's.
    private static func bundleString(_ key: String) -> String {
        Bundle.main.object(forInfoDictionaryKey: key) as? String ?? "unknown"
    }
}
#endif
