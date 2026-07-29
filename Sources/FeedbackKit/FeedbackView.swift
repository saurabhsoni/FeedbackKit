#if canImport(UIKit)
import PhotosUI
import SwiftUI

/// The feedback sheet.
struct FeedbackView: View {
    @Environment(FeedbackPresenter.self) private var presenter
    @Environment(\.dismiss) private var dismiss

    @State private var pickerItems: [PhotosPickerItem] = []
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
            Section {
                Picker("Kind", selection: $presenter.category) {
                    ForEach(FeedbackCategory.allCases, id: \.self) { category in
                        Text(category.title).tag(category)
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

            attachmentsSection

            Section {
                TextField("Your name", text: $presenter.reporterName)
                    .textContentType(.givenName)
                    .autocorrectionDisabled()
            } header: {
                Text("From")
            } footer: {
                Text("So I know who to follow up with. Remembered for next time.")
            }

            contextSection

            if case let .failed(message) = presenter.state {
                Section {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .font(.footnote)
                }
            }
        }
        .listStyle(.insetGrouped)
        .onAppear { bodyFocused = true }
    }

    private var placeholder: String {
        switch presenter.category {
        case .bug: "What went wrong?"
        case .idea: "What would you like to see?"
        case .general: "What's on your mind?"
        }
    }

    // MARK: - Attachments

    private var attachmentsSection: some View {
        Section {
            if let screenshot = presenter.autoScreenshot, let image = UIImage(data: screenshot) {
                attachmentRow(
                    image: image,
                    title: "Screen when you shook",
                    subtitle: "Captured automatically",
                    remove: { presenter.removeAutoScreenshot() }
                )
            }

            ForEach(Array(presenter.userAttachments.enumerated()), id: \.offset) { index, data in
                if let image = UIImage(data: data) {
                    attachmentRow(
                        image: image,
                        title: "Attached image",
                        subtitle: byteCount(data),
                        remove: { presenter.removeUserAttachment(at: index) }
                    )
                }
            }

            if presenter.attachmentCount < 5 {
                PhotosPicker(
                    selection: $pickerItems,
                    maxSelectionCount: 5 - presenter.attachmentCount,
                    matching: .images,
                    photoLibrary: .shared()
                ) {
                    Label("Add an image", systemImage: "photo.on.rectangle.angled")
                }
                .onChange(of: pickerItems) { _, items in
                    guard !items.isEmpty else { return }
                    Task {
                        for item in items {
                            if let data = try? await item.loadTransferable(type: Data.self) {
                                await presenter.addUserAttachment(data)
                            }
                        }
                        pickerItems = []
                    }
                }
            }
        } header: {
            Text("Attachments")
        } footer: {
            if presenter.autoScreenshot != nil {
                Text("Password fields are blacked out automatically. Remove the screenshot if you'd rather not send it.")
            }
        }
    }

    private func attachmentRow(
        image: UIImage,
        title: String,
        subtitle: String,
        remove: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 12) {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 44, height: 60)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(.separator, lineWidth: 0.5)
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(role: .destructive, action: remove) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove attachment")
        }
    }

    private func byteCount(_ data: Data) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
    }

    // MARK: - Transparency

    /// Shows exactly what gets sent alongside the message. Feedback tools that
    /// hide this feel like telemetry; showing it costs one row.
    private var contextSection: some View {
        Section {
            DisclosureGroup("Also sent") {
                let context = DeviceContext.current()
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
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            // Long enough to register, short enough not to feel like a modal
            // the user has to dismiss.
            try? await Task.sleep(for: .seconds(1.6))
            dismiss()
        }
    }
}
#endif
