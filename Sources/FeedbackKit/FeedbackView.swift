#if canImport(UIKit)
import SwiftUI

/// The feedback sheet.
struct FeedbackView: View {
    @Environment(FeedbackPresenter.self) private var presenter
    @Environment(\.dismiss) private var dismiss

    @FocusState private var bodyFocused: Bool

    var body: some View {
        @Bindable var presenter = presenter

        NavigationStack {
            Group {
                if presenter.state == .sent {
                    sentConfirmation
                } else {
                    form
                }
            }
            .navigationTitle(presenter.state == .sent ? "" : "Feedback")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .opacity(presenter.state == .sent ? 0 : 1)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if presenter.state == .sending {
                        ProgressView()
                    } else if presenter.state != .sent {
                        Button("Send") {
                            Task { await presenter.submit() }
                        }
                        .fontWeight(.semibold)
                        .disabled(!presenter.canSend)
                    }
                }
            }
        }
    }

    // MARK: - Form

    private var form: some View {
        @Bindable var presenter = presenter

        return List {
            if let question = presenter.clarifyingQuestion, presenter.clarifies != nil {
                clarificationSection(question)
            }

            Section {
                // `selectable`, not `allCases` — `general` is still a word this
                // build understands, but not one it offers.
                Picker("Kind", selection: $presenter.category) {
                    ForEach(FeedbackCategory.selectable, id: \.self) { category in
                        Text(category.title).tag(category)
                    }
                }
                .pickerStyle(.segmented)
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))

                // Tagged by severity value, never by position: the labels are a
                // function of the category, so switching Bug to Idea rewrites
                // all three words. Tagging by index would make the selection
                // jump; tagging by value leaves "the middle one" the middle one.
                // The label is invisible under `.segmented` but read aloud,
                // which is the only place the question gets asked in words.
                Picker(severityPrompt, selection: $presenter.severity) {
                    ForEach(FeedbackSeverity.allCases, id: \.self) { severity in
                        Text(severity.title(for: presenter.category)).tag(severity)
                    }
                }
                .pickerStyle(.segmented)
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            }

            Section {
                TextEditor(text: $presenter.draft)
                    .frame(minHeight: 120)
                    .focused($bodyFocused)
                    .overlay(alignment: .topLeading) {
                        if presenter.draft.isEmpty {
                            Text(placeholder)
                                .foregroundStyle(.secondary)
                                .padding(.top, 8)
                                .padding(.leading, 5)
                                .allowsHitTesting(false)
                        }
                    }
            } footer: {
                Text("Be as specific as you like — what you expected, and what happened instead.")
            }

            // Its own section, immediately under the words: this is part of
            // *what am I asking for*, not metadata about the report.
            if offersImplementToggle {
                Section {
                    Toggle("Start implementing this", isOn: $presenter.implementRequested)
                } footer: {
                    Text(implementFooter)
                }
            }

            FeedbackAttachmentsSection()

            // Gone entirely once the host app knows who this is. The name it
            // knows is better than the one someone would type into a form, and
            // an editable field over the top of it would only invite a second,
            // contradictory answer. What was sent stays visible under
            // "Also sent" — hiding the field is not the same as hiding the fact.
            if presenter.hostSuppliedName == nil {
                Section {
                    TextField("Your name", text: $presenter.reporterName)
                        .textContentType(.givenName)
                        .autocorrectionDisabled()
                } header: {
                    Text("From")
                } footer: {
                    Text("So I know who to follow up with. Remembered for next time.")
                }
            }

            contextSection

            Section {
                Button("Your previous feedback") {
                    presenter.replaceSheet(with: .history)
                }
            }

            if case let .failed(message) = presenter.state {
                Section {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .font(.footnote)
                }
            }
        }
        .listStyle(.insetGrouped)
        .animation(.default, value: presenter.category)
        .onChange(of: presenter.category) { _, _ in
            // A toggle the user can no longer see must not still be on when
            // they hit Send.
            if !offersImplementToggle {
                presenter.implementRequested = false
            }
        }
        .onAppear { bodyFocused = true }
    }

    /// Only a bug or an idea is something that can be *built*. A general
    /// remark isn't implementable, so the offer isn't made for it. Kept even
    /// though the picker no longer offers `general`, because a clarification
    /// can be prefilled from a legacy row that was filed as one.
    private var offersImplementToggle: Bool {
        presenter.category == .bug || presenter.category == .idea
    }

    /// Two different promises, and the difference matters more than the words.
    ///
    /// Saying "straight to the workshop" to someone whose request is actually
    /// going to sit in an approval queue is a promise the app can't keep, and
    /// the reporter finds out by watching nothing happen. So the confident copy
    /// appears only on a *successful* yes from `feedback_capabilities`; unknown,
    /// offline and no all read the same, cautious way.
    private var implementFooter: String {
        if presenter.autoImplementAllowed {
            return "Starts the work straight away instead of waiting for review. "
                + "Follow along under Your previous feedback."
        }
        return "Asks for this to be built. I'll have a look and approve it before work starts. "
            + "Follow along under Your previous feedback."
    }

    private var placeholder: String {
        switch presenter.category {
        case .bug: "What went wrong?"
        case .idea: "What would you like to see?"
        case .general: "What's on your mind?"
        }
    }

    /// Read aloud rather than drawn, so it can afford to be a whole question.
    private var severityPrompt: String {
        switch presenter.category {
        case .bug: "How bad is it?"
        case .idea, .general: "How big is it?"
        }
    }

    // MARK: - Clarifying

    /// Shown when this draft is an answer rather than a new report, so the
    /// person typing can see the question without leaving the sheet to go and
    /// find it again.
    private func clarificationSection(_ question: String) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Label("Adding a detail", systemImage: "questionmark.bubble")
                    .font(.footnote.weight(.semibold))
                Text(question)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
        } footer: {
            Text("Sending this replaces the earlier report, so nothing gets answered twice.")
        }
    }

    // MARK: - Transparency

    /// Shows exactly what gets sent alongside the message. Feedback tools that
    /// hide this feel like telemetry; showing it costs one row.
    private var contextSection: some View {
        Section {
            DisclosureGroup("Also sent") {
                let context = DeviceContext.current()
                // The name only appears here when the app supplied it, because
                // that is the only case where the user didn't type it and might
                // not know it is going along. When they typed it, the field
                // above is already the answer.
                if let name = presenter.hostSuppliedName {
                    LabeledContent("Sending as", value: name)
                }
                LabeledContent("Device", value: context.modelName)
                LabeledContent("System", value: context.os)
                LabeledContent("App", value: appVersionLine)
                LabeledContent("Language", value: context.locale)
            }
            .font(.footnote)
        }
    }

    private var appVersionLine: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(version) (\(build))"
    }

    // MARK: - Sent

    private var sentConfirmation: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 52))
                .foregroundStyle(.green)
                .accessibilityHidden(true)
            Text("Thank you")
                .font(.title2.weight(.semibold))
            Text("This goes straight to the person building the app.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent)
                .padding(.top, 8)
            // Right after sending is when someone most wants to see the queue
            // they just joined.
            Button("Your previous feedback") {
                presenter.replaceSheet(with: .history)
            }
            .font(.subheadline)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            // Long enough to register, short enough not to feel like a modal
            // the user has to dismiss.
            try? await Task.sleep(for: .seconds(1.6))
            // The sleep also ends when this view goes away — which it does the
            // moment someone taps through to history. Dismissing then would be
            // a stale action fired at whatever is on screen instead.
            guard !Task.isCancelled else { return }
            dismiss()
        }
    }
}
#endif
