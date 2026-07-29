#if canImport(UIKit)
import UIKit

/// Grabs what the user is currently looking at.
///
/// Timing is the whole problem here. The capture has to happen *before* the
/// feedback sheet starts presenting, otherwise the screenshot is a picture of
/// the feedback sheet. `capture()` is synchronous precisely so a caller can do
/// `capture()` then `isPresented = true` and be certain of the ordering — see
/// `FeedbackPresenter.present()`. Never capture from the sheet's `onAppear`.
@MainActor
enum ScreenshotCapture {
    /// Returns compressed JPEG bytes rather than a `UIImage`, so everything
    /// downstream — the queue, the upload actor — handles a plain `Sendable`
    /// value and the on-disk queue format is the same bytes we'd send.
    ///
    /// Returns `nil` when there is no foreground scene to draw.
    static func capture(quality: CGFloat = 0.7) -> Data? {
        guard let scene = activeScene() else { return nil }

        // Every visible window, back to front. Just the key window would miss
        // the software keyboard, which lives in its own `UIRemoteKeyboardWindow`
        // — and a bug report about a keyboard-obscured field is exactly the kind
        // that needs the keyboard in the picture.
        let windows = scene.windows
            .filter { !$0.isHidden && $0.alpha > 0 && !$0.bounds.isEmpty }
            .sorted { $0.windowLevel < $1.windowLevel }

        guard let base = windows.first else { return nil }
        let bounds = base.bounds

        let format = UIGraphicsImageRendererFormat.default()
        // Full @3x on a Pro Max is ~8 MB before compression and buys nothing for
        // reading a bug report; the bucket caps uploads at 5 MB.
        format.scale = min(2, scene.screen.scale)
        // Works around the iOS 18+ regression where a wide-gamut (P3) render
        // comes back visibly too dark.
        format.preferredRange = .standard

        let image = UIGraphicsImageRenderer(bounds: bounds, format: format).image { context in
            // `drawHierarchy` is the only API Apple documents as capturing
            // regardless of drawing technique (UIKit, Quartz, SpriteKit).
            // `afterScreenUpdates: false` captures the frame as committed right
            // now — `true` would flush a pending CoreAnimation transaction and
            // can pull a presenting sheet into the shot.
            //
            // It still can't capture hardware-composited layers (AVPlayerLayer,
            // camera preview): those are composited out of process and come out
            // black on device, though not in the Simulator. Falling back to
            // `layer.render` keeps a degraded shot rather than nothing.
            for window in windows {
                let drawn = window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
                if !drawn {
                    window.layer.render(in: context.cgContext)
                }
            }
            redactSensitiveRegions(in: windows, base: base, context: context)
        }

        return image.jpegData(compressionQuality: quality)
    }

    /// Paints over anything that should never leave the device.
    ///
    /// This is done explicitly rather than trusting the system: the render
    /// server's secure-layer exclusion applies to *system* screenshots, while
    /// `drawHierarchy` renders in-process, so a password very plausibly would
    /// come out legible. SwiftUI's `.privacySensitive()` is no help either — it
    /// only activates under `RedactionReasons.privacy`, which the system
    /// applies to widgets and the Lock Screen, not to in-app rendering.
    private static func redactSensitiveRegions(
        in windows: [UIWindow],
        base: UIWindow,
        context: UIGraphicsImageRendererContext
    ) {
        var rects: [CGRect] = []
        for window in windows {
            collectSensitiveRects(from: window, into: &rects, relativeTo: base)
        }
        guard !rects.isEmpty else { return }

        UIColor.darkGray.setFill()
        for rect in rects {
            context.fill(rect.insetBy(dx: -2, dy: -2))
        }
    }

    private static func collectSensitiveRects(
        from view: UIView,
        into rects: inout [CGRect],
        relativeTo base: UIWindow
    ) {
        if view.isHidden || view.alpha == 0 {
            return
        }

        let isSecureField = (view as? UITextField)?.isSecureTextEntry == true
        if isSecureField || view.feedbackIsRedacted {
            rects.append(view.convert(view.bounds, to: base))
            // No need to walk into a view that is being covered entirely.
            return
        }

        for subview in view.subviews {
            collectSensitiveRects(from: subview, into: &rects, relativeTo: base)
        }
    }

    private static func activeScene() -> UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
    }
}

// MARK: - Opt-in redaction

extension UIView {
    private static let redactionKey = malloc(1)!

    /// Set by the `.feedbackRedact()` SwiftUI modifier. Associated-object
    /// storage because the flag has to be readable from an arbitrary
    /// `UIView` during the capture walk.
    var feedbackIsRedacted: Bool {
        get { objc_getAssociatedObject(self, UIView.redactionKey) as? Bool ?? false }
        set { objc_setAssociatedObject(self, UIView.redactionKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }
}
#endif
