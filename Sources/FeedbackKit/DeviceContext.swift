import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// The environment a report came from — the things you always end up asking
/// for ("what phone? what version?") and never get on the first reply.
///
/// Encoded straight into the `device` jsonb column. Kept small on purpose: the
/// column has a 2 KB size check, and every field here is one you'd actually use
/// while reproducing a bug.
struct DeviceContext: Sendable, Codable, Equatable {
    var model: String
    var modelName: String
    var os: String
    var locale: String
    var timeZone: String
    var screen: String
    var appearance: String
    var textSize: String
    var lowPower: Bool
    var freeDiskMB: Int?

    /// Nothing here identifies a person. Deliberately absent: IDFA (needs
    /// AppTrackingTransparency and is useless for debugging), name, phone
    /// number, contacts, precise location, and the carrier. If a field wouldn't
    /// help reproduce a bug, it isn't worth the privacy cost of collecting it.
    @MainActor
    static func current() -> DeviceContext {
        #if canImport(UIKit)
        let device = UIDevice.current
        let identifier = machineIdentifier()
        return DeviceContext(
            model: identifier,
            modelName: marketingName(for: identifier) ?? device.model,
            os: "\(device.systemName) \(device.systemVersion)",
            locale: Locale.current.identifier,
            timeZone: TimeZone.current.identifier,
            screen: screenDescription(),
            appearance: appearanceDescription(),
            textSize: UIApplication.shared.preferredContentSizeCategory.rawValue
                .replacingOccurrences(of: "UICTContentSizeCategory", with: ""),
            lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled,
            freeDiskMB: freeDiskMB()
        )
        #else
        return DeviceContext(
            model: "unknown", modelName: "unknown",
            os: ProcessInfo.processInfo.operatingSystemVersionString,
            locale: Locale.current.identifier, timeZone: TimeZone.current.identifier,
            screen: "unknown", appearance: "unknown", textSize: "unknown",
            lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled, freeDiskMB: nil
        )
        #endif
    }

    /// A human-readable one-liner for the disclosure row in the sheet, so the
    /// user can see exactly what is being attached before they send it.
    var summary: String {
        "\(modelName) · \(os) · \(locale)"
    }

    // MARK: - Pieces

    /// The hardware string (`iPhone14,3`). There is no public API for this;
    /// `uname` is the long-standing way to get it.
    private static func machineIdentifier() -> String {
        // `uname` reports the host Mac's architecture under the simulator, which
        // names the simulated device here instead.
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return simulated
        }
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    /// Only the models likely to show up here. An unknown identifier falls back
    /// to the raw string, which is still perfectly greppable — this table is a
    /// convenience, not something to keep exhaustively current.
    private static func marketingName(for identifier: String) -> String? {
        let known: [String: String] = [
            "iPhone13,1": "iPhone 12 mini", "iPhone13,2": "iPhone 12",
            "iPhone13,3": "iPhone 12 Pro", "iPhone13,4": "iPhone 12 Pro Max",
            "iPhone14,4": "iPhone 13 mini", "iPhone14,5": "iPhone 13",
            "iPhone14,2": "iPhone 13 Pro", "iPhone14,3": "iPhone 13 Pro Max",
            "iPhone14,7": "iPhone 14", "iPhone14,8": "iPhone 14 Plus",
            "iPhone15,2": "iPhone 14 Pro", "iPhone15,3": "iPhone 14 Pro Max",
            "iPhone15,4": "iPhone 15", "iPhone15,5": "iPhone 15 Plus",
            "iPhone16,1": "iPhone 15 Pro", "iPhone16,2": "iPhone 15 Pro Max",
            "iPhone17,3": "iPhone 16", "iPhone17,4": "iPhone 16 Plus",
            "iPhone17,1": "iPhone 16 Pro", "iPhone17,2": "iPhone 16 Pro Max",
            "iPhone17,5": "iPhone 16e",
        ]
        return known[identifier]
    }

    #if canImport(UIKit)
    @MainActor
    private static func screenDescription() -> String {
        guard let screen = activeScene()?.screen else { return "unknown" }
        let size = screen.bounds.size
        let scale = screen.scale
        return "\(Int(size.width * scale))x\(Int(size.height * scale))@\(Int(scale))x"
    }

    @MainActor
    private static func appearanceDescription() -> String {
        switch activeScene()?.traitCollection.userInterfaceStyle {
        case .dark: "dark"
        case .light: "light"
        default: "unspecified"
        }
    }

    /// `UIScreen.main` is deprecated under multi-scene; go through the
    /// foreground-active scene instead.
    @MainActor
    private static func activeScene() -> UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
    }
    #endif

    private static func freeDiskMB() -> Int? {
        guard
            let url = try? FileManager.default.url(
                for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: false
            ),
            let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
            let bytes = values.volumeAvailableCapacityForImportantUsage
        else { return nil }
        return Int(bytes / 1_048_576)
    }
}
