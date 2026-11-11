import Foundation

public enum ArtifactReconciliation {
    /// Decide whether a host artifact must be copied again. The guest remains
    /// authoritative; this is only a cheap fast path using size and mtime.
    public static func needsUpload(
        _ artifact: TaskArtifact,
        guestSize: Int64?,
        guestModified: Date?,
        timestampTolerance: TimeInterval = 2
    ) -> Bool {
        if artifact.guestState == .failed || artifact.guestState == .queued { return true }
        guard let guestSize, guestSize == Int64(artifact.byteCount) else { return true }
        if let known = artifact.guestModifiedAt, let guestModified,
           abs(known.timeIntervalSince(guestModified)) > timestampTolerance {
            return true
        }
        return false
    }
}
