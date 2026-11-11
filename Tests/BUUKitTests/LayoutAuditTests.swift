import Foundation
import Testing
@testable import BUUKit

@Suite("Layout audit")
struct LayoutAuditTests {
    @Test("Accepts regions fully inside each matrix size")
    func acceptsInside() {
        let sizes: [CGSize] = [
            CGSize(width: 1120, height: 720),
            CGSize(width: 1200, height: 720),
            CGSize(width: 1600, height: 1000),
        ]
        for size in sizes {
            let frames: [String: CGRect] = [
                "Sidebar": CGRect(x: 0, y: 0, width: 220, height: size.height),
                "Display": CGRect(x: 220, y: 52, width: 520, height: size.height - 88),
                "Inspector": CGRect(x: 740, y: 52, width: 380, height: size.height - 52),
                "Composer": CGRect(x: 740, y: size.height - 140, width: 380, height: 140),
            ]
            #expect(LayoutAudit.invalidRegions(frames, in: size).isEmpty)
        }
    }

    @Test("Flags regions outside the window or with no height")
    func flagsClippedAndEmpty() {
        let size = CGSize(width: 1200, height: 720)
        let frames: [String: CGRect] = [
            "LeftClipped": CGRect(x: -20, y: 0, width: 220, height: 720),
            "TopClipped": CGRect(x: 220, y: -30, width: 500, height: 300),
            "BottomClipped": CGRect(x: 220, y: 650, width: 500, height: 120),
            "ZeroHeight": CGRect(x: 220, y: 100, width: 500, height: 0),
        ]
        #expect(
            LayoutAudit.invalidRegions(frames, in: size)
                == ["BottomClipped", "LeftClipped", "TopClipped", "ZeroHeight"]
        )
    }

    @Test("Ignores sub-point rounding noise")
    func ignoresRounding() {
        let size = CGSize(width: 1200, height: 720)
        let frames = ["Inspector": CGRect(x: 0, y: 0, width: 1200.4, height: 720.4)]
        #expect(LayoutAudit.invalidRegions(frames, in: size).isEmpty)
    }
}
