import Foundation

/// Pure geometry check used by the DEBUG layout overlay and unit tests.
public enum LayoutAudit {
    public static func invalidRegions(
        _ frames: [String: CGRect],
        in size: CGSize,
        tolerance: CGFloat = 1
    ) -> [String] {
        frames.compactMap { name, rect in
            let invalid = rect.width <= tolerance
                || rect.height <= tolerance
                || rect.minX < -tolerance
                || rect.minY < -tolerance
                || rect.maxX > size.width + tolerance
                || rect.maxY > size.height + tolerance
            return invalid ? name : nil
        }.sorted()
    }

    #if DEBUG
    public static func assertValid(
        _ frames: [String: CGRect],
        in size: CGSize,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let invalid = invalidRegions(frames, in: size)
        if !invalid.isEmpty {
            assertionFailure(
                "Layout regions outside \(size) bounds: \(invalid.joined(separator: ", "))",
                file: file,
                line: line
            )
        }
    }
    #endif
}
