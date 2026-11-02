import AppKit
import SwiftUI
import UniformTypeIdentifiers
import BUUKit

// MARK: - Pasteboard helpers

/// Reads images out of a pasteboard or a drag session.
enum ChatPasteboard {

    /// Pasteboard types that can carry an image (in decoding order).
    static var imageTypes: [NSPasteboard.PasteboardType] {
        [
            .png,
            .tiff,
            NSPasteboard.PasteboardType("public.jpeg"),
            NSPasteboard.PasteboardType("public.heic"),
            NSPasteboard.PasteboardType("com.compuserve.gif"),
            NSPasteboard.PasteboardType("org.webmproject.webp"),
        ]
    }

    /// Types we accept as drop targets.
    static var dropTypes: [UTType] { [.fileURL, .image, .url] }

    /// True when the pasteboard *might* contain an image (cheap check, used for
    /// drag highlighting and for deciding whether to intercept a paste).
    static func hasImage(in pasteboard: NSPasteboard) -> Bool {
        if hasImageFile(in: pasteboard) { return true }
        return pasteboard.availableType(from: imageTypes) != nil
    }

    /// True when the pasteboard holds at least one file whose extension is an
    /// image type. Uses the extension so nothing has to be read from disk.
    static func hasImageFile(in pasteboard: NSPasteboard) -> Bool {
        guard let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] else { return false }

        return urls.contains { url in
            guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
            return type.conforms(to: .image)
        }
    }

    /// Every image on the pasteboard: dropped files, raw bitmap data or a
    /// bitmap that only exists as an `NSImage`.
    static func images(from pasteboard: NSPasteboard) -> [Data] {
        var result: [Data] = []
        var seen = Set<Data>()

        func append(_ data: Data?) {
            guard let data, !data.isEmpty, ImageProcessor.mimeType(for: data).hasPrefix("image/") else { return }
            guard seen.insert(data).inserted else { return }
            result.append(data)
        }

        // Files copied in Finder or dragged from a file manager.
        if let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] {
            for url in urls {
                append(try? Data(contentsOf: url))
            }
        }

        // Raw bitmap data (screenshots, browser drags).
        for type in imageTypes {
            append(pasteboard.data(forType: type))
        }

        // Last resort: whatever AppKit can decode into an image.
        if result.isEmpty, let image = NSImage(pasteboard: pasteboard), let tiff = image.tiffRepresentation {
            append(tiff)
        }

        return result
    }

    /// Starts loading one image from a drop provider.
    ///
    /// - Returns: `true` when the provider could produce something we accept.
    @discardableResult
    static func loadImage(
        from provider: NSItemProvider,
        into handler: @escaping @MainActor (Data) -> Void
    ) -> Bool {
        // A file dragged from Finder / Finder-like apps.
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                guard let url = fileURL(from: item),
                      let data = try? Data(contentsOf: url),
                      ImageProcessor.mimeType(for: data).hasPrefix("image/") else { return }
                Task { @MainActor in handler(data) }
            }
            return true
        }

        // Image data supplied by the source app (browsers, Preview, …).
        if let identifier = provider.registeredTypeIdentifiers.first(where: {
            UTType($0)?.conforms(to: .image) == true
        }) {
            provider.loadDataRepresentation(forTypeIdentifier: identifier) { data, _ in
                guard let data, !data.isEmpty else { return }
                Task { @MainActor in handler(data) }
            }
            return true
        }

        // A remote image URL dragged out of a web page.
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { item, _ in
                guard let url = remoteURL(from: item),
                      let data = try? Data(contentsOf: url),
                      ImageProcessor.mimeType(for: data).hasPrefix("image/") else { return }
                Task { @MainActor in handler(data) }
            }
            return true
        }

        return false
    }

    private static func fileURL(from item: (any NSSecureCoding)?) -> URL? {
        if let url = item as? URL, url.isFileURL { return url }
        if let url = item as? NSURL, url.isFileURL { return url as URL }
        if let data = item as? Data { return URL(dataRepresentation: data, relativeTo: nil) }
        if let string = item as? String, let url = URL(string: string), url.isFileURL { return url }
        return nil
    }

    private static func remoteURL(from item: (any NSSecureCoding)?) -> URL? {
        if let url = item as? URL, isRemote(url) { return url }
        if let url = item as? NSURL, isRemote(url as URL) { return url as URL }
        if let string = item as? String, let url = URL(string: string), isRemote(url) { return url }
        return nil
    }

    private static func isRemote(_ url: URL) -> Bool {
        url.scheme == "http" || url.scheme == "https"
    }
}

// MARK: - Text view

/// An `NSTextView` that understands images: ⌘V, the context-menu *Paste* item
/// and drag & drop all end up in `onImageData` instead of being silently
/// ignored by the text system.
final class ComposerNSTextView: NSTextView {

    var onImageData: (@MainActor ([Data]) -> Void)?
    var onSend: (@MainActor () -> Void)?
    var onStop: (@MainActor () -> Void)?
    var onDropTargeted: (@MainActor (Bool) -> Void)?

    override func paste(_ sender: Any?) {
        let pasteboard = NSPasteboard.general
        // A copied image file always wins, so ⌘V after "Copy" in Finder does
        // not paste the file name. Raw bitmap data only wins when there is no
        // text to paste, so copying rich text with a picture still pastes text.
        let shouldTryImage = ChatPasteboard.hasImageFile(in: pasteboard)
            || pasteboard.string(forType: .string) == nil

        if shouldTryImage {
            let images = ChatPasteboard.images(from: pasteboard)
            if !images.isEmpty {
                onImageData?(images)
                return
            }
        }

        super.paste(sender)
    }

    override func insertNewline(_ sender: Any?) {
        if NSEvent.modifierFlags.contains(.shift) {
            super.insertNewline(sender)
        } else {
            onSend?()
        }
    }

    override func cancelOperation(_ sender: Any?) {
        onStop?()
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard ChatPasteboard.hasImage(in: sender.draggingPasteboard) else {
            return super.draggingEntered(sender)
        }
        onDropTargeted?(true)
        return .copy
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        onDropTargeted?(false)
        super.draggingExited(sender)
    }

    override func draggingEnded(_ sender: any NSDraggingInfo) {
        onDropTargeted?(false)
        super.draggingEnded(sender)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        onDropTargeted?(false)
        let images = ChatPasteboard.images(from: sender.draggingPasteboard)
        if !images.isEmpty {
            onImageData?(images)
            return true
        }
        return super.performDragOperation(sender)
    }
}

// MARK: - Representable

/// A growing, borderless text view used by the composer.
struct ComposerTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool

    /// Incremented by the view model to move the keyboard focus here (⌘K).
    var focusToken: Int
    var onImageData: @MainActor ([Data]) -> Void
    var onSend: @MainActor () -> Void
    var onStop: @MainActor () -> Void
    var onDropTargeted: @MainActor (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.verticalScrollElasticity = .allowed

        let textView = ComposerNSTextView()
        textView.drawsBackground = false
        textView.isRichText = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.font = .systemFont(ofSize: Theme.Typography.bodySize)
        textView.textColor = .labelColor
        textView.insertionPointColor = .labelColor
        // No horizontal inset and no line fragment padding: the caret must
        // start exactly where the placeholder text starts.
        textView.textContainerInset = NSSize(width: 0, height: 4)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        let unlimited = CGFloat.greatestFiniteMagnitude
        textView.maxSize = NSSize(width: unlimited, height: unlimited)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0

        textView.registerForDraggedTypes([.fileURL, .png, .tiff] + ChatPasteboard.imageTypes)

        textView.string = text
        textView.delegate = context.coordinator
        applyCallbacks(to: textView)

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? ComposerNSTextView else { return }

        context.coordinator.parent = self
        applyCallbacks(to: textView)

        if textView.string != text {
            textView.string = text
        }

        if context.coordinator.lastFocusToken != focusToken {
            context.coordinator.lastFocusToken = focusToken
            let request = FocusRequest(window: scrollView.window, responder: textView)
            // Hop one runloop: moving the first responder synchronously inside
            // a view update would mutate state during that update.
            Task { @MainActor in request.apply() }
        }
    }

    private func applyCallbacks(to textView: ComposerNSTextView) {
        textView.onImageData = onImageData
        textView.onSend = onSend
        textView.onStop = onStop
        textView.onDropTargeted = onDropTargeted
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerTextView
        var lastFocusToken = 0

        init(_ parent: ComposerTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            guard parent.text != textView.string else { return }
            parent.text = textView.string
        }

        func textDidBeginEditing(_ notification: Notification) {
            parent.isFocused = true
        }

        func textDidEndEditing(_ notification: Notification) {
            parent.isFocused = false
        }
    }
}

/// Carries an AppKit focus request across a main-actor hop without capturing
/// non-`Sendable` AppKit objects in a `@Sendable` closure.
@MainActor
private final class FocusRequest {
    private weak var window: NSWindow?
    private weak var responder: NSView?

    init(window: NSWindow?, responder: NSView?) {
        self.window = window
        self.responder = responder
    }

    func apply() {
        guard let responder, let window else { return }
        if window.firstResponder !== responder {
            window.makeFirstResponder(responder)
        }
    }
}
