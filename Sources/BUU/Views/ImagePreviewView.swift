import AppKit
import SwiftUI
import BUUKit

/// A Quick Look style overlay for a single attached image.
///
/// Click the backdrop (or press Esc) to dismiss; the image can also be opened in
/// Preview.app, which it is a real file on disk for.
struct ImagePreviewOverlay: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let attachment: ImageAttachment
    let onClose: () -> Void

    @State private var image: NSImage?
    @State private var fileURL: URL?
    @State private var isLoading = true
    @State private var didAppear = false
    @State private var escapeMonitor: Any?

    var body: some View {
        ZStack {
            Color.black.opacity(0.62)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: onClose)
                .accessibilityHidden(true)

            VStack(spacing: Theme.Spacing.m) {
                imageArea
                footer
            }
            .padding(Theme.Spacing.xl)
            .scaleEffect(didAppear || reduceMotion ? 1 : 0.97)
            .opacity(didAppear ? 1 : 0)
        }
        .onAppear {
            withAnimation(Theme.Motion.standard(reduceMotion: reduceMotion)) {
                didAppear = true
            }
            installEscapeMonitor()
        }
        .onDisappear {
            removeEscapeMonitor()
        }
        .onExitCommand(perform: onClose)
        .task { await load() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Image preview")
        .accessibilityAddTraits(.isModal)
    }

    // MARK: - Pieces

    @ViewBuilder
    private var imageArea: some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: 1100, maxHeight: 720)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous))
                .shadow(color: .black.opacity(0.4), radius: 24, y: 10)
                .onTapGesture { } // keep taps on the image from closing the overlay
                .accessibilityLabel("Attached image")
        } else if isLoading {
            ProgressView()
                .controlSize(.large)
                .frame(minWidth: 240, minHeight: 180)
        } else {
            VStack(spacing: Theme.Spacing.s) {
                Image(systemName: "photo.badge.exclamationmark")
                    .font(.system(size: 32))
                Text("This image could not be loaded")
                    .font(.callout)
            }
            .foregroundStyle(.white.opacity(0.85))
            .frame(minWidth: 280, minHeight: 180)
        }
    }

    private var footer: some View {
        HStack(spacing: Theme.Spacing.m) {
            Text(caption)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.75))

            Spacer(minLength: Theme.Spacing.l)

            Button("Open in Preview") {
                if let fileURL { NSWorkspace.shared.open(fileURL) }
            }
            .disabled(fileURL == nil)

            Button("Done", action: onClose)
                .keyboardShortcut(.defaultAction)
        }
        .controlSize(.regular)
    }

    private var caption: String {
        var parts: [String] = []

        let width = attachment.pixelWidth > 0
            ? attachment.pixelWidth
            : (image?.representations.first?.pixelsWide ?? 0)
        let height = attachment.pixelHeight > 0
            ? attachment.pixelHeight
            : (image?.representations.first?.pixelsHigh ?? 0)
        if width > 0, height > 0 {
            parts.append("\(width) × \(height)")
        }

        let bytes = attachment.byteCount > 0
            ? attachment.byteCount
            : (image?.tiffRepresentation?.count ?? 0)
        if bytes > 0 {
            parts.append(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))
        }

        return parts.joined(separator: " · ")
    }

    // MARK: - Keyboard

    /// The composer's text view owns the responder chain while the app is
    /// running, so Esc is caught at the event level while the overlay is open.
    private func installEscapeMonitor() {
        guard escapeMonitor == nil else { return }
        let closer = EscapeCloser(onClose)
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 53 else { return event }
            MainActor.assumeIsolated { closer.run() }
            return nil
        }
    }

    private func removeEscapeMonitor() {
        if let escapeMonitor {
            NSEvent.removeMonitor(escapeMonitor)
        }
        escapeMonitor = nil
    }

    // MARK: - Loading

    private func load() async {
        defer { isLoading = false }
        guard let data = await AttachmentImageLoader.shared.data(for: attachment) else { return }
        image = NSImage(data: data)
        fileURL = await AttachmentImageLoader.shared.url(for: attachment)
    }
}

#Preview("Image preview – dark") {
    ZStack {
        Theme.Colors.canvas
        ImagePreviewOverlay(
            attachment: ImageAttachment(
                fileName: "preview.png",
                mimeType: "image/png",
                pixelWidth: 1600,
                pixelHeight: 1000,
                byteCount: 420_000
            ),
            onClose: {}
        )
    }
    .frame(width: 900, height: 620)
    .preferredColorScheme(.dark)
}

#Preview("Image preview – light") {
    ZStack {
        Theme.Colors.canvas
        ImagePreviewOverlay(
            attachment: ImageAttachment(fileName: "preview.png", mimeType: "image/png"),
            onClose: {}
        )
    }
    .frame(width: 900, height: 620)
    .preferredColorScheme(.light)
}

/// Wraps the close action so it can be captured by the key monitor without
/// tripping Swift 6 sendability checks.
private final class EscapeCloser: @unchecked Sendable {
    private let action: () -> Void

    init(_ action: @escaping () -> Void) {
        self.action = action
    }

    func run() {
        action()
    }
}
