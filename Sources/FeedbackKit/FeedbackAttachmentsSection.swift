#if canImport(UIKit)
import PhotosUI
import SwiftUI
import UIKit

/// The attachments half of the compose sheet: the automatic capture, anything
/// the user adds, and the picker that adds it.
///
/// Its own type rather than a `var` on `FeedbackView` because it owns state
/// nothing else in that sheet touches — the `PhotosPickerItem` selection is
/// transient, exists only until the bytes have been loaded, and had no business
/// being a property of the whole form.
struct FeedbackAttachmentsSection: View {
    @Environment(FeedbackPresenter.self) private var presenter

    /// Cleared as soon as each pick has been read. Holding on to the items
    /// would keep the picker's own selection alive and re-fire `onChange` the
    /// next time the sheet is opened.
    @State private var pickerItems: [PhotosPickerItem] = []

    var body: some View {
        Section {
            if let screenshot = presenter.autoScreenshot, let image = UIImage(data: screenshot) {
                row(
                    image: image,
                    title: "The screen you were on",
                    subtitle: "Captured automatically",
                    remove: { presenter.removeAutoScreenshot() }
                )
            }

            ForEach(Array(presenter.userAttachments.enumerated()), id: \.offset) { index, data in
                if let image = UIImage(data: data) {
                    row(
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
                Text(
                    "Password fields are blacked out automatically. "
                        + "Remove the screenshot if you'd rather not send it."
                )
            }
        }
    }

    private func row(
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
}
#endif
