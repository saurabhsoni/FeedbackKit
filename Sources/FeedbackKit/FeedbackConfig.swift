import Foundation

/// Everything an app must tell FeedbackKit about itself.
///
/// Deliberately an immutable `Sendable` value passed in at the call site rather
/// than a `FeedbackKit.configure()` singleton. A singleton is global mutable
/// state — hostile to Swift 6 concurrency, and it fails at *runtime* (silently,
/// as an unconfigured no-op) if a view happens to render before configuration
/// runs. Passing the config in makes the requirement a compile-time one.
public struct FeedbackConfig: Sendable, Equatable {
    /// Slug identifying this app in the shared backend, e.g. `myeverythingapp`.
    /// Must match `^[a-z0-9][a-z0-9._-]{1,39}$` — the same rule the database
    /// enforces, checked here so a typo fails on your simulator rather than as
    /// a 400 from a stranger's phone.
    public let appID: String

    /// Supabase project URL, e.g. `https://abcdefgh.supabase.co`.
    public let projectURL: URL

    /// The Supabase **publishable** key (`sb_publishable_…`).
    ///
    /// This ships inside the app binary and is meant to. The database grants it
    /// INSERT on nine columns and nothing else: it cannot read one row back,
    /// cannot delete, and cannot write the triage columns. See `supabase/setup.sql`.
    public let publishableKey: String

    /// Human-facing name of the app, shown in the feedback sheet's header.
    /// Defaults to `CFBundleDisplayName`/`CFBundleName`.
    public let displayName: String

    public init(
        appID: String,
        projectURL: URL,
        publishableKey: String,
        displayName: String? = nil
    ) {
        self.appID = appID
        self.projectURL = projectURL
        self.publishableKey = publishableKey
        self.displayName = displayName ?? Self.bundleDisplayName()

        assert(
            appID.range(of: "^[a-z0-9][a-z0-9._-]{1,39}$", options: .regularExpression) != nil,
            "FeedbackKit: appID \"\(appID)\" is not a valid slug — the database will reject it."
        )
    }

    /// Reads the config out of Info.plist, so the keys can be injected per-app
    /// from a gitignored xcconfig instead of being committed in source.
    ///
    /// Returns `nil` — rather than a half-built config that fails later at the
    /// network layer — when a key is missing, so the caller can surface the
    /// misconfiguration immediately. A missing xcconfig otherwise produces the
    /// worst possible failure: a green build where feedback silently vanishes.
    public static func fromInfoPlist(
        appID: String,
        urlKey: String = "FeedbackProjectURL",
        keyKey: String = "FeedbackPublishableKey",
        bundle: Bundle = .main
    ) -> FeedbackConfig? {
        guard
            let urlString = bundle.object(forInfoDictionaryKey: urlKey) as? String,
            let keyString = bundle.object(forInfoDictionaryKey: keyKey) as? String,
            !urlString.isEmpty, !keyString.isEmpty,
            // An unsubstituted build setting looks like "$(FEEDBACK_PROJECT_URL)"
            // and would otherwise sail through as a valid-looking string.
            !urlString.hasPrefix("$("), !keyString.hasPrefix("$("),
            let url = URL(string: urlString)
        else { return nil }

        return FeedbackConfig(appID: appID, projectURL: url, publishableKey: keyString)
    }

    private static func bundleDisplayName() -> String {
        let bundle = Bundle.main
        if let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String {
            return name
        }
        if let name = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String {
            return name
        }
        return "This app"
    }
}

extension Bundle {
    /// Reads a string out of the **host app's** Info.plist.
    ///
    /// `Bundle.main`, never `Bundle.module` — the latter is the package's own
    /// resource bundle with a generated Info.plist, and carries the package's
    /// version rather than the host app's. Shared because the version and build
    /// number are wanted in three places: on a report, in the sheet's "Also
    /// sent" row, and as the yardstick for "is this fix live for me yet".
    static func mainInfoString(_ key: String) -> String {
        Bundle.main.object(forInfoDictionaryKey: key) as? String ?? "unknown"
    }
}
