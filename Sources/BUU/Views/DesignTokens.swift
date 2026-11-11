import AppKit
import SwiftUI

enum DesignTokens {
    enum Space {
        static let xxs: CGFloat = 4
        static let xs: CGFloat = 8
        static let s: CGFloat = 12
        static let m: CGFloat = 16
        static let l: CGFloat = 24
    }

    enum Radius {
        static let small: CGFloat = 6
        static let medium: CGFloat = 10
        static let large: CGFloat = 14
        static let panel: CGFloat = 16
    }

    enum Surface {
        static var window: Color { Color(nsColor: .windowBackgroundColor) }
        static var panel: Color { Color(nsColor: .controlBackgroundColor) }
        static var card: Color { Color(nsColor: .textBackgroundColor).opacity(0.55) }
        static var input: Color { Color(nsColor: .textBackgroundColor).opacity(0.75) }
        static var elevated: Color { Color(nsColor: .controlBackgroundColor) }
        static var backdrop: Color { Color(nsColor: .underPageBackgroundColor) }
    }

    static let inspectorIdealWidth: CGFloat = 420
    static let inspectorMinWidth: CGFloat = 340
    static let inspectorMaxWidth: CGFloat = 640
}

enum MacWorkspaceTab: String, CaseIterable, Identifiable, Hashable {
    case workspace = "Workspace"
    case configuration = "Configuration"

    var id: String { rawValue }
    var systemImage: String {
        switch self {
        case .workspace: return "display"
        case .configuration: return "slider.horizontal.3"
        }
    }
}

enum MacAgentSection: String, CaseIterable, Identifiable, Hashable {
    case trace = "Trace"
    case artifacts = "Artifacts"
    case outputs = "Outputs"
    case queue = "Queue"

    var id: String { rawValue }
    var systemImage: String {
        switch self {
        case .trace: return "text.alignleft"
        case .artifacts: return "paperclip"
        case .outputs: return "tray.and.arrow.down"
        case .queue: return "list.number"
        }
    }
}

struct MacSplitView<Top: View, Bottom: View>: View {
    @Binding var ratio: CGFloat
    var minTop: CGFloat = 220
    var minBottom: CGFloat = 220
    @ViewBuilder var top: () -> Top
    @ViewBuilder var bottom: () -> Bottom

    @State private var dragStart: CGFloat?
    @State private var dragHeight: CGFloat = 1

    var body: some View {
        GeometryReader { proxy in
            let height = max(proxy.size.height, minTop + minBottom + 8)
            let clamped = min(max(ratio, 0.25), 0.8)
            let topHeight = max(minTop, min(height - minBottom - 8, height * clamped))
            VStack(spacing: 0) {
                top()
                    .frame(height: topHeight)
                    .frame(maxWidth: .infinity)
                divider(height: height)
                bottom()
                    .frame(maxHeight: .infinity)
                    .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(DesignTokens.Surface.window)
    }

    private func divider(height: CGFloat) -> some View {
        ZStack {
            Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 1)
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.secondary.opacity(0.25))
                .frame(width: 44, height: 5)
        }
        .frame(height: 8)
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
        }
        .gesture(
            DragGesture()
                .onChanged { value in
                    if dragStart == nil {
                        dragStart = ratio
                        dragHeight = max(1, height)
                    }
                    guard let start = dragStart else { return }
                    let delta = value.translation.height / dragHeight
                    ratio = min(max(start + delta, 0.25), 0.8)
                }
                .onEnded { _ in dragStart = nil }
        )
        .accessibilityLabel("Resize display and agent panel")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: ratio = min(0.8, ratio + 0.05)
            case .decrement: ratio = max(0.25, ratio - 0.05)
            @unknown default: break
            }
        }
    }
}
