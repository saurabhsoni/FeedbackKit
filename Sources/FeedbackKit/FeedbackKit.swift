#if canImport(UIKit)
import SwiftUI
import UIKit

// MARK: - Installing

public extension View {
    /// Installs the feedback flow: shake-to-report, the sheet, and the shared
    /// presenter that `FeedbackButton` and `openFeedback` reach for.
    ///
    /// Apply once, at the root of the app:
    ///
    /// ```swift
    /// ContentView()
    ///     .feedback(FeedbackConfig(
    ///         appID: "myeverythingapp",
    ///         projectURL: URL(string: "https://xyz.supabase.co")!,
    ///         publishableKey: "sb_publishable_…"
    ///     ))
    /// ```
    ///
    /// Not available in app extensions — it reaches `UIApplication.shared` to
    /// find the window to screenshot. The annotation is what makes that a
    /// compile error in a widget target rather than a silent runtime failure,
    /// since `APPLICATION_EXTENSION_API_ONLY` is not propagated into a package's
    /// compilation.
    @available(iOSApplicationExtension, unavailable)
    func feedback(_ config: FeedbackConfig) -> some View {
        modifier(FeedbackModifier(config: config, user: nil))
    }

    /// Convenience for `FeedbackConfig.fromInfoPlist(…)`, which is optional.
    ///
    /// A `nil` config disables feedback rather than shipping something that
    /// fails at the network layer. It trips an assertion in debug builds so a
    /// missing `Secrets.xcconfig` surfaces on the simulator instead of as
    /// silence from a friend's phone.
    @available(iOSApplicationExtension, unavailable)
    @ViewBuilder
    func feedback(_ config: FeedbackConfig?) -> some View {
        if let config {
            modifier(FeedbackModifier(config: config, user: nil))
        } else {
            onAppear {
                assertionFailure(
                    "FeedbackKit: no configuration found. Check Secrets.xcconfig "
                        + "and that the Info.plist keys are being substituted."
                )
            }
        }
    }

    /// The same, for an app that knows who is using it.
    ///
    /// ```swift
    /// ContentView()
    ///     .feedback(config, user: FeedbackUser(
    ///         id: account?.userID,
    ///         displayName: account?.fullName
    ///     ))
    /// ```
    ///
    /// Pass the *current* value on every render rather than a snapshot taken at
    /// launch: the modifier pushes each change through, so signing in or out
    /// mid-session re-scopes the history list and re-tags the next report
    /// without anything being torn down and rebuilt.
    ///
    /// A non-empty `displayName` also removes the "Your name" field from the
    /// sheet — the app already knows, so asking is just a chore with a worse
    /// answer than the one it has.
    @available(iOSApplicationExtension, unavailable)
    func feedback(_ config: FeedbackConfig, user: FeedbackUser?) -> some View {
        modifier(FeedbackModifier(config: config, user: user))
    }

    @available(iOSApplicationExtension, unavailable)
    @ViewBuilder
    func feedback(_ config: FeedbackConfig?, user: FeedbackUser?) -> some View {
        if let config {
            modifier(FeedbackModifier(config: config, user: user))
        } else {
            onAppear {
                assertionFailure(
                    "FeedbackKit: no configuration found. Check Secrets.xcconfig "
                        + "and that the Info.plist keys are being substituted."
                )
            }
        }
    }

    /// Marks a view so its contents are blacked out in automatic screenshots.
    ///
    /// Secure text fields are handled without this. Use it for anything else
    /// that shouldn't leave the device — a balance, an API key, someone's
    /// address.
    func feedbackRedact() -> some View {
        background(RedactionMarker().accessibilityHidden(true))
    }
}

@available(iOSApplicationExtension, unavailable)
private struct FeedbackModifier: ViewModifier {
    @State private var presenter: FeedbackPresenter
    @Environment(\.scenePhase) private var scenePhase

    private let user: FeedbackUser?

    init(config: FeedbackConfig, user: FeedbackUser?) {
        _presenter = State(initialValue: FeedbackPresenter(config: config))
        self.user = user
    }

    func body(content: Content) -> some View {
        content
            .environment(presenter)
            .environment(\.openFeedback, OpenFeedbackAction { presenter.present() })
            .environment(\.openFeedbackHistory, OpenFeedbackHistoryAction { presenter.presentHistory() })
            .background(ShakeCatcher { presenter.present() })
            // One `.sheet(item:)` for both screens, deliberately. Two chained
            // `.sheet(isPresented:)` on the same view is a long-standing
            // SwiftUI trap: the second is simply never presented.
            .sheet(
                item: presenter.routeBinding,
                onDismiss: { presenter.sheetDidDismiss() },
                content: { route in
                    switch route {
                    case .compose:
                        FeedbackView()
                            .environment(presenter)
                    case .history:
                        // The presenter goes in here too now: an `unclear` row
                        // offers "Edit and resend", which sends the reader back
                        // out to the compose sheet.
                        FeedbackHistoryView(store: presenter.history)
                            .environment(presenter)
                    }
                }
            )
            // Ahead of the scene-phase handler on purpose. Both fire on the
            // first pass with `initial: true`, and the capability check that
            // `activate()` kicks off wants the account id already in hand.
            .onChange(of: user, initial: true) { _, latest in
                presenter.updateUser(latest)
            }
            .onChange(of: scenePhase, initial: true) { _, phase in
                // Drain the offline queue whenever the app comes forward. A
                // background URLSession would be more thorough, but only the
                // host's app delegate can receive its completion callback, so a
                // package can't own that — and foreground draining needs no
                // configuration from the integrator at all.
                if phase == .active {
                    presenter.activate()
                } else {
                    presenter.deactivate()
                }
            }
    }
}

// MARK: - Triggering

/// A ready-made "Send feedback" row for a settings screen or menu.
///
/// ```swift
/// Section { FeedbackButton() }
/// ```
@available(iOSApplicationExtension, unavailable)
public struct FeedbackButton<Label: View>: View {
    @Environment(FeedbackPresenter.self) private var presenter
    private let label: Label

    public init(@ViewBuilder label: () -> Label) {
        self.label = label()
    }

    public var body: some View {
        Button {
            presenter.present()
        } label: {
            label
        }
    }
}

@available(iOSApplicationExtension, unavailable)
public extension FeedbackButton where Label == SwiftUI.Label<Text, Image> {
    /// The default presentation: a labelled row that looks at home in a `List`.
    init(_ title: String = "Send Feedback", systemImage: String = "exclamationmark.bubble") {
        self.init { SwiftUI.Label(title, systemImage: systemImage) }
    }
}

/// The companion row: what you already sent, and what became of it.
///
/// ```swift
/// Section {
///     FeedbackButton()
///     FeedbackHistoryButton()
/// }
/// ```
@available(iOSApplicationExtension, unavailable)
public struct FeedbackHistoryButton<Label: View>: View {
    @Environment(FeedbackPresenter.self) private var presenter
    private let label: Label

    public init(@ViewBuilder label: () -> Label) {
        self.label = label()
    }

    public var body: some View {
        Button {
            presenter.presentHistory()
        } label: {
            label
        }
        // Unconditional: `badge(_ count:)` draws nothing at zero, so there is
        // no state to branch on. This is the whole of the in-app half of status
        // notifications — the notification itself is provisional and therefore
        // quiet, so the badge is what a person actually notices.
        .badge(presenter.history.unreadCount)
    }
}

@available(iOSApplicationExtension, unavailable)
public extension FeedbackHistoryButton where Label == SwiftUI.Label<Text, Image> {
    init(_ title: String = "Your Previous Feedback", systemImage: String = "tray.full") {
        self.init { SwiftUI.Label(title, systemImage: systemImage) }
    }
}

public extension EnvironmentValues {
    /// Opens the feedback sheet from anywhere inside `.feedback(_:)`.
    ///
    /// ```swift
    /// @Environment(\.openFeedback) private var openFeedback
    /// ...
    /// Button("Report a problem") { openFeedback() }
    /// ```
    var openFeedback: OpenFeedbackAction {
        get { self[OpenFeedbackKey.self] }
        set { self[OpenFeedbackKey.self] = newValue }
    }

    /// Opens the list of this install's own reports.
    var openFeedbackHistory: OpenFeedbackHistoryAction {
        get { self[OpenFeedbackHistoryKey.self] }
        set { self[OpenFeedbackHistoryKey.self] = newValue }
    }
}

/// Not `@MainActor` on the type itself: an `EnvironmentKey`'s `defaultValue` is
/// evaluated in a nonisolated context, so isolating the whole struct makes the
/// default unrepresentable. Isolating the call instead gives the same guarantee
/// where it matters.
public struct OpenFeedbackAction: Sendable {
    private let handler: (@MainActor @Sendable () -> Void)?

    init(handler: (@MainActor @Sendable () -> Void)?) {
        self.handler = handler
    }

    @MainActor
    public func callAsFunction() {
        handler?()
    }
}

private struct OpenFeedbackKey: EnvironmentKey {
    /// Defaults to a no-op rather than a crash: a view that offers a feedback
    /// button shouldn't take the app down when previewed outside `.feedback(_:)`.
    static let defaultValue = OpenFeedbackAction(handler: nil)
}

/// Not `@MainActor` for the same reason as `OpenFeedbackAction` — see there.
public struct OpenFeedbackHistoryAction: Sendable {
    private let handler: (@MainActor @Sendable () -> Void)?

    init(handler: (@MainActor @Sendable () -> Void)?) {
        self.handler = handler
    }

    @MainActor
    public func callAsFunction() {
        handler?()
    }
}

private struct OpenFeedbackHistoryKey: EnvironmentKey {
    static let defaultValue = OpenFeedbackHistoryAction(handler: nil)
}

// MARK: - Redaction plumbing

/// An invisible view that tags its SwiftUI-created superview as redacted, so
/// `ScreenshotCapture` can paint over it.
private struct RedactionMarker: UIViewRepresentable {
    func makeUIView(context _: Context) -> UIView {
        let view = MarkerView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_: UIView, context _: Context) {}

    private final class MarkerView: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            // `.background` places this behind the content, as a sibling inside
            // the same container — tagging the parent covers the whole thing.
            superview?.feedbackIsRedacted = true
        }
    }
}
#endif
