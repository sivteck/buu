import AppKit
import SwiftUI
import UniformTypeIdentifiers
import BUUKit

struct ComposerView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var isEditorFocused = false
    @State private var isImportingImages = false
    @State private var isDropTargeted = false
    @State private var editorWidth: CGFloat = 520
    /// Measured outside `body`: sizing the whole draft on every unrelated
    /// state change was the composer's most expensive layout work.
    @State private var editorHeight: CGFloat = 28

    private var isComposerActive: Bool { isEditorFocused || isDropTargeted }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            if !appState.pendingImages.isEmpty {
                AttachmentStrip(images: appState.pendingImages) { image in
                    appState.removeImage(image)
                }
            }

            HStack(alignment: .bottom, spacing: Theme.Spacing.s) {
                attachmentMenu
                editor
                sendButton
            }
            .padding(.horizontal, Theme.Spacing.s)
            .padding(.vertical, Theme.Spacing.s)
            .background(
                .regularMaterial,
                in: RoundedRectangle(cornerRadius: Theme.Radius.l, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.l, style: .continuous)
                    .strokeBorder(
                        isComposerActive ? Color.accentColor.opacity(0.85) : Theme.Colors.separator,
                        lineWidth: isComposerActive ? 2 : 1
                    )
            }
            .shadow(color: .black.opacity(0.10), radius: 6, y: 2)
        }
        .padding(.top, Theme.Spacing.m)
        .padding(.bottom, Theme.Spacing.m)
        .contentColumn()
        .background(.bar, ignoresSafeAreaEdges: .bottom)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Theme.Colors.separator)
                .frame(height: 1)
        }
        .themeAnimation(isEditorFocused, reduceMotion: reduceMotion)
        .fileImporter(
            isPresented: $isImportingImages,
            allowedContentTypes: [.image],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                Task { await appState.addImages(at: urls) }
            }
        }
        .onDrop(of: ChatPasteboard.dropTypes, isTargeted: $isDropTargeted) { providers in
            var accepted = false
            for provider in providers {
                if ChatPasteboard.loadImage(from: provider, into: { data in
                    appState.addImageData(data)
                }) {
                    accepted = true
                }
            }
            return accepted
        }
        .onExitCommand {
            if appState.isSending { appState.stop() }
        }
        .onAppear { updateEditorHeight() }
        .onChange(of: appState.composerText) { updateEditorHeight() }
    }

    // MARK: - Editor

    private var editor: some View {
        @Bindable var appState = appState

        return ZStack(alignment: .topLeading) {
            if appState.composerText.isEmpty {
                Text("Message")
                    .font(.system(size: Theme.Typography.bodySize))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 0)
                    .padding(.top, 4)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }

            ComposerTextView(
                text: $appState.composerText,
                isFocused: $isEditorFocused,
                focusToken: appState.focusComposerToken,
                onImageData: { data in
                    for item in data { appState.addImageData(item) }
                },
                onSend: { appState.send() },
                onStop: { appState.stop() },
                onDropTargeted: { targeted in
                    isDropTargeted = targeted
                }
            )
            .accessibilityLabel("Message")
            .frame(height: editorHeight)
            .background(
                GeometryReader { geometry in
                    Color.clear.preference(key: EditorWidthKey.self, value: geometry.size.width)
                }
            )
            .themeAnimation(editorHeight, reduceMotion: reduceMotion)
        }
        .frame(minHeight: 24, alignment: .topLeading)
        .onPreferenceChange(EditorWidthKey.self) { width in
            if width > 0, abs(width - editorWidth) > 0.5 {
                editorWidth = width
                updateEditorHeight()
            }
        }
    }

    /// Grows with the text from one line up to ``Theme/Metrics/composerMaxLines``,
    /// then the field scrolls internally. Measurements happen on text/width
    /// changes, not on every body evaluation.
    private static let bodyLineHeight: CGFloat = {
        let font = NSFont.systemFont(ofSize: Theme.Typography.bodySize)
        return ceil(font.ascender - font.descender + font.leading)
    }()

    private func updateEditorHeight() {
        let font = NSFont.systemFont(ofSize: Theme.Typography.bodySize)
        let lineHeight = Self.bodyLineHeight
        let usable = max(80, editorWidth - 12)
        let sample = appState.composerText.isEmpty ? "Ag" : appState.composerText
        let bounds = (sample as NSString).boundingRect(
            with: NSSize(width: usable, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        )
        let lines = max(1, min(Theme.Metrics.composerMaxLines, Int(ceil(bounds.height / lineHeight))))
        let height = CGFloat(lines) * lineHeight + 8
        if abs(height - editorHeight) > 0.5 {
            editorHeight = height
        }
    }

    // MARK: - Controls

    private var attachmentMenu: some View {
        Menu {
            Button("Add Image…") { isImportingImages = true }
            Button("Paste Image") { appState.pasteImageFromClipboard() }
            if !appState.pendingImages.isEmpty {
                Divider()
                Button("Clear Attachments") { appState.clearPendingImages() }
            }
        } label: {
            Image(systemName: "paperclip")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .iconHitTarget()
        .help("Attach an image")
        .accessibilityLabel("Attach an image")
    }

    @ViewBuilder
    private var sendButton: some View {
        if appState.isSending {
            Button {
                appState.stop()
            } label: {
                Image(systemName: "stop.circle.fill")
                    .font(.system(size: 22))
                    .symbolRenderingMode(.hierarchical)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .iconHitTarget()
            .help("Stop generating (Esc)")
            .accessibilityLabel("Stop generating")
        } else {
            Button {
                appState.send()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 22))
                    .symbolRenderingMode(.hierarchical)
            }
            .buttonStyle(.plain)
            .foregroundStyle(appState.canSend ? Color.accentColor : Color.secondary.opacity(0.45))
            .disabled(!appState.canSend)
            .iconHitTarget()
            .help("Send (Return)")
            .accessibilityLabel("Send message")
        }
    }
}

// MARK: - Attachments

struct AttachmentStrip: View {
    let images: [PendingImage]
    let onRemove: (PendingImage) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Spacing.s) {
                ForEach(images) { image in
                    ZStack(alignment: .topTrailing) {
                        Image(nsImage: image.thumbnail)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 56, height: 56)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.s, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: Theme.Radius.s, style: .continuous)
                                    .strokeBorder(Theme.Colors.separator, lineWidth: 1)
                            }

                        Button {
                            onRemove(image)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.body)
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, .black.opacity(0.6))
                        }
                        .buttonStyle(.plain)
                        .offset(x: 5, y: -5)
                        .accessibilityLabel("Remove image")
                    }
                }
            }
            .padding(.vertical, Theme.Spacing.xs)
        }
    }
}

private struct EditorWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - Previews

#Preview("Composer – dark") {
    VStack {
        Spacer()
        ComposerView()
    }
    .frame(width: 760, height: 260)
    .background(Theme.Colors.canvas)
    .environment(AppState())
    .preferredColorScheme(.dark)
}

#Preview("Composer – light") {
    VStack {
        Spacer()
        ComposerView()
    }
    .frame(width: 760, height: 260)
    .background(Theme.Colors.canvas)
    .environment(AppState())
    .preferredColorScheme(.light)
}
