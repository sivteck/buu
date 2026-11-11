import AppKit
import SwiftUI

// MARK: - Design tokens

/// One place for every spacing, radius, size and semantic colour used by the
/// interface. Everything is based on system colours, so light/dark mode and
/// increased contrast are handled by the OS instead of hard-coded hex values.
enum Theme {

    enum Spacing {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
    }

    enum Radius {
        static let xs: CGFloat = 6
        static let s: CGFloat = 8
        /// Containers: table and code blocks.
        static let m: CGFloat = 10
        /// Composer and message bubbles.
        static let l: CGFloat = 14
    }

    enum Table {
        static let minColumnWidth: CGFloat = 80
        static let maxColumnWidth: CGFloat = 320
        static let cellPaddingH: CGFloat = 8
        static let cellPaddingV: CGFloat = 6
        /// Rough advance width of 13pt system text, used for column sizing.
        static let characterWidth: CGFloat = 7.1
    }

    enum Metrics {
        /// Width of the centred conversation column (header, messages, composer).
        static let readableWidth: CGFloat = 760
        /// A user bubble never grows past this (≈75% of the column).
        static let bubbleMaxWidth: CGFloat = 540
        /// Compact composer: one line plus padding.
        static let composerMinHeight: CGFloat = 44
        static let composerMaxLines = 8
        /// Minimum hit target for icon-only buttons.
        static let controlSize: CGFloat = 28
        static let sidebarMin: CGFloat = 220
        static let sidebarIdeal: CGFloat = 250
        static let sidebarMax: CGFloat = 300
        /// Sidebar 220 + display pane 520 + inspector 340 + split padding.
        static let sidebarMinWidth: CGFloat = 220
        static let displayPaneMinWidth: CGFloat = 520
        static let windowMinWidth: CGFloat = 1120
        /// Toolbar + display + VM bar + inspector header/tabs/trace/composer.
        static let windowMinHeight: CGFloat = 720
        /// Code blocks taller than this collapse behind "Show all N lines".
        static let collapsedCodeLines = 18
        /// Bottom content inset so the last row never touches the composer divider.
        static let transcriptBottomInset: CGFloat = 32
        /// Outer inset of a sidebar row (the selection highlight starts here).
        static let rowInset: CGFloat = 8
        /// Inner inset of the row content inside the highlight.
        static let rowInnerInset: CGFloat = 10
    }

    enum Typography {
        static let bodySize: CGFloat = 14.5
        /// 14.5pt text needs ~4pt extra leading for a 1.35 line height.
        static let bodyLineSpacing: CGFloat = 4
        static let codeSize: CGFloat = 13
        static let tableSize: CGFloat = 13
        static let paragraphSpacing: CGFloat = 10

        static var body: Font { .system(size: bodySize) }
        static var code: Font { .system(size: codeSize, design: .monospaced) }
        static var metadata: Font { .caption2 }
    }

    enum Colors {
        static var canvas: Color { Color(nsColor: .windowBackgroundColor) }
        static var control: Color { Color(nsColor: .controlBackgroundColor) }
        static var separator: Color { Color(nsColor: .separatorColor) }
        static var codeSurface: Color { Color(nsColor: .textBackgroundColor) }
        static var userBubble: Color { Color.accentColor.opacity(0.16) }
        static var inlineCode: Color { Color.primary.opacity(0.07) }

        // Semantic status signals.
        static var success: Color { .green }
        static var warning: Color { .orange }
        static var danger: Color { .red }
        static var info: Color { .blue }
    }

    enum Motion {
        /// The single spring used for composer growth, disclosure and insertion.
        static func standard(reduceMotion: Bool) -> Animation? {
            reduceMotion ? nil : .snappy(duration: 0.25)
        }
    }
}

// MARK: - Layout helpers

extension View {
    /// Places the content in the shared conversation column: centred when the
    /// window is wide, full width with the platform gutter when it is narrow.
    func contentColumn() -> some View {
        self
            .frame(maxWidth: Theme.Metrics.readableWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, Theme.Spacing.l)
    }

    /// A 28×28pt hit target for icon-only buttons.
    func iconHitTarget(_ size: CGFloat = Theme.Metrics.controlSize) -> some View {
        frame(width: size, height: size)
            .contentShape(Rectangle())
    }

    /// Shows the pointing hand while hovering, if the platform allows it.
    func pointingHandOnHover() -> some View {
        modifier(PointingHandModifier())
    }

    /// Applies the shared spring animation when motion is allowed.
    func themeAnimation<V: Equatable>(_ value: V, reduceMotion: Bool) -> some View {
        animation(Theme.Motion.standard(reduceMotion: reduceMotion), value: value)
    }
}

private struct PointingHandModifier: ViewModifier {
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                guard hovering != isHovering else { return }
                isHovering = hovering
                if hovering {
                    NSCursor.pointingHand.push()
                } else {
                    NSCursor.pop()
                }
            }
            .onDisappear {
                if isHovering {
                    isHovering = false
                    NSCursor.pop()
                }
            }
    }
}
