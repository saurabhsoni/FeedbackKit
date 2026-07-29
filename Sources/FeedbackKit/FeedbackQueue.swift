import Foundation

/// Holds reports that couldn't be sent yet, and drains them later.
///
/// The point is that hitting Send always means "this is safely recorded". A
/// friend on a train who taps Send in a tunnel should not lose their sentence
/// and should not be asked to care.
actor FeedbackQueue {
    private let transport: any FeedbackTransport
    private let directory: URL

    /// Upper bounds so a permanently-offline device can't fill its own disk.
    private static let maxReports = 50
    private static let maxAttempts = 6

    init(transport: any FeedbackTransport, appID: String) {
        self.transport = transport

        // Application Support, not Caches (the system purges Caches under disk
        // pressure — silent loss of the exact thing we promised to keep) and not
        // Documents (user-visible if the host app enables file sharing).
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        directory = (base ?? URL.temporaryDirectory)
            .appending(path: "FeedbackKit", directoryHint: .isDirectory)
            .appending(path: appID, directoryHint: .isDirectory)
    }

    /// Writes a report to disk. Called when a send fails retryably.
    func enqueue(_ report: FeedbackReport) {
        prepareDirectory()
        trimIfNeeded()

        // Millisecond timestamp first so a plain filename sort is a queue order,
        // UUID second so two reports in the same millisecond can't collide.
        let stamp = Int(report.createdAt.timeIntervalSince1970 * 1000)
        let url = directory.appending(path: "\(stamp)-\(report.id.uuidString).json")

        guard let data = try? JSONEncoder().encode(Envelope(report: report, attempts: 0)) else { return }
        // `.completeFileProtectionUntilFirstUserAuthentication`, not `.complete`:
        // complete protection makes the file unreadable while the device is
        // locked, which is exactly when a retry is most likely to run.
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// Attempts every queued report, oldest first. Stops at the first retryable
    /// failure — if the network is down for one, it's down for all, and hammering
    /// the rest just burns battery.
    func drain() async {
        let files = queuedFiles()
        guard !files.isEmpty else { return }

        for file in files {
            guard let envelope = load(from: file) else {
                // Undecodable — most likely a format change. Delete it rather
                // than letting it wedge the head of the queue forever.
                try? FileManager.default.removeItem(at: file)
                continue
            }

            do {
                try await transport.send(envelope.report)
                try? FileManager.default.removeItem(at: file)
            } catch let error as FeedbackError where error.isRetryable {
                let next = envelope.attempts + 1
                if next >= Self.maxAttempts {
                    try? FileManager.default.removeItem(at: file)
                    continue
                }
                save(Envelope(report: envelope.report, attempts: next), to: file)
                return
            } catch {
                // A 4xx means the request itself is malformed — it will be just
                // as malformed next time. Treat as poison and drop it, or it
                // blocks everything behind it forever.
                try? FileManager.default.removeItem(at: file)
            }

            // Be gentle with a backlog.
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    var pendingCount: Int {
        queuedFiles().count
    }

    // MARK: - Storage

    private struct Envelope: Codable {
        let report: FeedbackReport
        let attempts: Int
    }

    private func prepareDirectory() {
        guard !FileManager.default.fileExists(atPath: directory.path) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // A pending-upload queue is transient machine state. Restoring it onto a
        // new device would re-send stale reports tagged with the wrong install.
        var url = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    private func queuedFiles() -> [URL] {
        let contents = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )
        return (contents ?? [])
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func load(from url: URL) -> Envelope? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Envelope.self, from: data)
    }

    private func save(_ envelope: Envelope, to url: URL) {
        guard let data = try? JSONEncoder().encode(envelope) else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private func trimIfNeeded() {
        let files = queuedFiles()
        guard files.count >= Self.maxReports else { return }
        for file in files.prefix(files.count - Self.maxReports + 1) {
            try? FileManager.default.removeItem(at: file)
        }
    }
}
