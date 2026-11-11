import Foundation
import SwiftUI
import BUUKit

extension EnvironmentValues {
    @Entry var layoutDebugEnabled = false
}

struct LayoutRegionFramesKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct LayoutRegionModifier: ViewModifier {
    let name: String
    @Environment(\.layoutDebugEnabled) private var enabled

    func body(content: Content) -> some View {
        #if DEBUG
        content.background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: LayoutRegionFramesKey.self,
                    value: enabled ? [name: proxy.frame(in: .named("WindowContent"))] : [:]
                )
            }
        }
        #else
        content
        #endif
    }
}

extension View {
    func layoutRegion(_ name: String) -> some View {
        modifier(LayoutRegionModifier(name: name))
    }
}

struct LayoutDebugOverlay: View {
    @Environment(\.layoutDebugEnabled) private var enabled
    var frames: [String: CGRect]

    var body: some View {
        #if DEBUG
        if enabled {
            GeometryReader { proxy in
                let invalid = Set(LayoutAudit.invalidRegions(frames, in: proxy.size))
                ZStack(alignment: .topLeading) {
                    ForEach(Array(frames.keys).sorted(), id: \.self) { name in
                        if let rect = frames[name] {
                            let isInvalid = invalid.contains(name)
                            Rectangle()
                                .fill(isInvalid ? Color.red.opacity(0.10) : Color.clear)
                                .overlay {
                                    Rectangle().stroke(
                                        isInvalid ? Color.red : Color.accentColor.opacity(0.7),
                                        lineWidth: 1
                                    )
                                }
                                .frame(width: max(0, rect.width), height: max(0, rect.height))
                                .position(x: rect.midX, y: rect.midY)
                                .allowsHitTesting(false)
                        }
                    }
                }
                .onAppear { report(frames, size: proxy.size) }
                .onChange(of: frames) { _, newValue in report(newValue, size: proxy.size) }
            }
            .allowsHitTesting(false)
        }
        #endif
    }

    private func report(_ frames: [String: CGRect], size: CGSize) {
        let invalid = LayoutAudit.invalidRegions(frames, in: size)
        for name in frames.keys.sorted() {
            guard let rect = frames[name] else { continue }
            print("[Layout] \(name): \(rect) window=\(size)")
        }
        if !invalid.isEmpty {
            print("[Layout] WARNING regions outside bounds: \(invalid.joined(separator: ", "))")
        }
        #if DEBUG
        if ProcessInfo.processInfo.environment["BUU_LAYOUT_AUDIT_STRICT"] == "1" {
            LayoutAudit.assertValid(frames, in: size)
        }
        #endif
    }
}
