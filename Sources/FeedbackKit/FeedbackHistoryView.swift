#if canImport(UIKit)
import SwiftUI

/// Everything this install has sent, and what became of it.
///
/// The point of the screen is the second half. Feedback that disappears into a
/// form teaches people to stop sending it; a list that says "being worked on"
/// is the cheapest possible reply.
struct FeedbackHistoryView: View {
    let store: FeedbackHistoryStore

    @Environment(FeedbackPresenter.self) private var presenter
    @Environment(\.dismiss) private var dismiss

    /// The yardstick for "live for you": the build actually running right now.
    private let currentBuild = Bundle.mainInfoString("CFBundleVersion")

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Your previous feedback")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        .task {
            await store.load()
            // After the load, not before: whatever the fetch turned up, they
            // are looking straight at it, so the badge has done its job.
            store.markSeen()
        }
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
        .refreshable {
            await store.refresh()
            store.markSeen()
        }
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

            // The server-written title leads when there is one, and demotes the
            // body to context. Without one the body *is* the row, which is why
            // its line limit changes rather than the title being faked locally.
            if let title = item.title, !title.isEmpty {
                Text(title)
                    .fontWeight(.medium)
                Text(item.body)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            } else {
                Text(item.body)
                    .lineLimit(4)
            }

            if let detail = item.detail, !detail.isEmpty {
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if item.needsClarification {
                Button("Edit and resend") {
                    presenter.presentClarification(of: item)
                }
                .font(.footnote.weight(.semibold))
                // `.borderless` is load-bearing in a `List`: the default row
                // style hands the whole row's tap area to a single button
                // inside it, so without this, tapping anywhere on the row —
                // including the text someone is trying to read — reopens the
                // compose sheet.
                .buttonStyle(.borderless)
                .padding(.top, 2)
            }
        }
        .padding(.vertical, 2)
        // A replaced report is kept rather than hidden — seeing what you sent
        // before is half of understanding why the new one reads differently —
        // but it should not compete with the live one for attention.
        .opacity(item.state == .superseded ? 0.55 : 1)
    }
}

/// The one bit of custom styling in the package. A status word needs to be
/// scannable down a column of otherwise-identical rows, which plain secondary
/// text is not.
private struct StatusPill: View {
    let state: FeedbackHistoryItem.DisplayState

    var body: some View {
        // The words live on `DisplayState` rather than here, because the status
        // notification has to say exactly the same thing and two copies of a
        // vocabulary drift the moment one of them is reworded.
        Text(state.title)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tint.opacity(0.15), in: Capsule())
    }

    private var tint: Color {
        switch state {
        // `superseded` sits with the other quiet ones on purpose: being
        // replaced is not a verdict on the report, it is bookkeeping.
        case .received, .queued, .notPlanned, .superseded: .secondary
        case .working: .blue
        case .implemented: .orange
        case .live: .green
        case .failed: .red
        // The one row with something for the reporter to do, so it gets the
        // one colour nothing else uses.
        case .unclear: .yellow
        }
    }
}
#endif
