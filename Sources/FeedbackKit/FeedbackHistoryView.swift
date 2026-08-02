#if canImport(UIKit)
import SwiftUI

/// Everything this install has sent, and what became of it.
///
/// The point of the screen is the second half. Feedback that disappears into a
/// form teaches people to stop sending it; a list that says "being worked on"
/// is the cheapest possible reply.
struct FeedbackHistoryView: View {
    let store: FeedbackHistoryStore

    @Environment(\.dismiss) private var dismiss

    /// The yardstick for "live for you": the build actually running right now.
    private let currentBuild = Bundle.mainInfoString("CFBundleVersion")

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Your feedback")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        .task { await store.load() }
    }

    @ViewBuilder
    private var content: some View {
        switch store.state {
        case .idle, .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .failed(message):
            failure(message)
        case .loaded:
            if store.items.isEmpty {
                ContentUnavailableView(
                    "No feedback yet",
                    systemImage: "tray",
                    description: Text("Anything you send will show up here, with what happened to it.")
                )
            } else {
                list
            }
        }
    }

    private var list: some View {
        List {
            ForEach(store.items) { item in
                row(item)
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await store.refresh() }
    }

    private func failure(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.title)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Retry") {
                Task { await store.refresh() }
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Row

    private func row(_ item: FeedbackHistoryItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: item.category.symbolName)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                StatusPill(state: item.displayState(inBuild: currentBuild))
                Spacer(minLength: 8)
                Text(item.createdAt.formatted(.relative(presentation: .named)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(item.body)
                .lineLimit(4)

            if let detail = item.detail, !detail.isEmpty {
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

/// The one bit of custom styling in the package. A status word needs to be
/// scannable down a column of otherwise-identical rows, which plain secondary
/// text is not.
private struct StatusPill: View {
    let state: FeedbackHistoryItem.DisplayState

    var body: some View {
        Text(title)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tint.opacity(0.15), in: Capsule())
    }

    /// Written from the reporter's side of the exchange: what this means for
    /// them, not what column it came out of.
    private var title: String {
        switch state {
        case .received: "Received"
        case .queued: "Queued"
        case .working: "Being worked on"
        case .implemented: "Ready in the next update"
        case .live: "Live in this version"
        case .failed: "Needs a closer look"
        case .notPlanned: "Not planned"
        }
    }

    private var tint: Color {
        switch state {
        case .received, .queued, .notPlanned: .secondary
        case .working: .blue
        case .implemented: .orange
        case .live: .green
        case .failed: .red
        }
    }
}
#endif
