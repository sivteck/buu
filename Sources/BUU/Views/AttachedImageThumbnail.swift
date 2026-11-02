import AppKit
import SwiftUI
import BUUKit

/// Loads the binary data of attachments with a small in-memory cache.
actor AttachmentImageLoader {
    static let shared = AttachmentImageLoader()

    private let fileStore = FileStore()
    private var cache: [String: Data] = [:]

    func url(for attachment: ImageAttachment) async -> URL {
        await fileStore.attachmentsDirectory
            .appendingPathComponent(URL(fileURLWithPath: attachment.fileName).lastPathComponent)
    }

    func data(for attachment: ImageAttachment) async -> Data? {
        if let cached = cache[attachment.fileName] { return cached }
        let url = await url(for: attachment)
        guard let data = try? await fileStore.readData(from: url) else { return nil }
        cache[attachment.fileName] = data
        return data
    }
}

/// A clickable attachment thumbnail. Clicking it opens the full size preview.
struct AttachedImageThumbnail: View {
    @Environment(AppState.self) private var appState

    let attachment: ImageAttachment
    @State private var image: NSImage?
    @State private var isHovering = false

    var body: some View {
        Button {
            appState.previewImage(attachment)
        } label: {
            label
        }
        .buttonStyle(.plain)
        .pointingHandOnHover()
        .help("Click to view the image")
        .accessibilityLabel("View attached image")
        .onHover { isHovering = $0 }
        .task {
            if let data = await AttachmentImageLoader.shared.data(for: attachment),
               let loaded = NSImage(data: data) {
                image = loaded
            }
        }
    }

    private var label: some View {
        ZStack {
            Group {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.15))
                        .overlay { Image(systemName: "photo").foregroundStyle(.tertiary) }
                }
            }
            .frame(width: 88, height: 88)

            if isHovering {
                Color.black.opacity(0.25)
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(6)
                    .background(.black.opacity(0.35), in: Circle())
            }
        }
        .frame(width: 88, height: 88)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.s, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.s, style: .continuous)
                .strokeBorder(
                    isHovering ? Color.accentColor.opacity(0.8) : Theme.Colors.separator,
                    lineWidth: 1
                )
        }
        .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.s, style: .continuous))
        .animation(.easeOut(duration: 0.12), value: isHovering)
    }
}
