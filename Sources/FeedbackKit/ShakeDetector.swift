#if canImport(UIKit)
import CoreMotion
import SwiftUI
import UIKit

/// Shake-to-give-feedback.
///
/// Two independent detectors feeding one debounce, because neither alone is
/// sufficient:
///
/// * **UIKit motion events** (`motionEnded`) are what the Simulator's
///   Device ▸ Shake Device (⌃⌘Z) injects, so they're the only path you can
///   actually test on a Mac. But motion events are delivered to the *first
///   responder* and bubble up the chain — when nothing is focused, UIKit
///   delivers straight to the window and skips us entirely.
/// * **CoreMotion** has no responder-chain hole and works under a presented
///   sheet, but the Simulator has no accelerometer, so it never fires there.
///
/// The common alternative — an `extension UIWindow { override motionEnded }` —
/// is deliberately not used. That is an Objective-C category override: it
/// replaces `UIWindow`'s implementation process-wide for every window in the
/// host app, `super` becomes unreliable, and two libraries doing it means
/// last-one-loaded wins. Not something to put in a package other apps depend on.
@MainActor
@Observable
final class ShakeDetector {
    var onShake: (@MainActor () -> Void)?

    private let motion = CMMotionManager()
    private var lastFire = Date.distantPast
    private var isSettled = true
    private var isRunning = false

    /// Shakes are inherently multi-peak, and the two detectors can both fire for
    /// one physical shake. One debounce in front of everything.
    private let minimumInterval: TimeInterval = 1.5

    func start() {
        guard !isRunning else { return }
        isRunning = true

        // Otherwise iOS shows its own "Undo Typing?" alert on shake whenever a
        // text field has been edited, which would race our sheet.
        UIApplication.shared.applicationSupportsShakeToEdit = false

        // False on the Simulator — the UIKit half covers that case.
        guard motion.isAccelerometerAvailable else { return }
        motion.accelerometerUpdateInterval = 1.0 / 50
        motion.startAccelerometerUpdates(to: .main) { [weak self] data, _ in
            guard let self, let acceleration = data?.acceleration else { return }
            MainActor.assumeIsolated {
                self.consider(acceleration)
            }
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        motion.stopAccelerometerUpdates()
    }

    /// Called by the UIKit half.
    func handleMotionShake() {
        fire()
    }

    /// Hysteresis rather than a bare threshold: require the device to return to
    /// roughly rest (1g) before another peak counts, so one continuous shake
    /// reads as one gesture instead of a burst of them.
    private func consider(_ acceleration: CMAcceleration) {
        // Magnitude in g. At rest this reads ~1.0 (gravity alone).
        let force = sqrt(
            acceleration.x * acceleration.x
                + acceleration.y * acceleration.y
                + acceleration.z * acceleration.z
        )
        if force > 2.3, isSettled {
            isSettled = false
            fire()
        } else if force < 1.3 {
            isSettled = true
        }
    }

    private func fire() {
        let now = Date()
        guard now.timeIntervalSince(lastFire) > minimumInterval else { return }
        lastFire = now
        onShake?()
    }
}

/// The UIKit half — an invisible view controller that makes itself first
/// responder so `motionEnded` reaches it. Costs nothing and is what makes
/// ⌃⌘Z work in the Simulator.
struct ShakeCatcher: UIViewControllerRepresentable {
    let onShake: @MainActor () -> Void

    final class Controller: UIViewController {
        var onShake: (@MainActor () -> Void)?

        override var canBecomeFirstResponder: Bool {
            true
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            becomeFirstResponder()
        }

        override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
            guard motion == .motionShake else {
                super.motionEnded(motion, with: event)
                return
            }
            onShake?()
        }
    }

    func makeUIViewController(context _: Context) -> Controller {
        let controller = Controller()
        controller.onShake = onShake
        controller.view.isUserInteractionEnabled = false
        return controller
    }

    func updateUIViewController(_ controller: Controller, context _: Context) {
        controller.onShake = onShake
    }
}
#endif
