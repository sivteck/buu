import AppKit
import SwiftUI

/// Owns "should the transcript follow the stream?".
///
/// Two separate facts are tracked, which is what makes sending a message work:
///
/// - ``isSentinelVisible`` — a *layout* fact: the marker at the end of the list
///   is on screen. Appending a message pushes it off screen, so this alone must
///   never decide anything.
/// - ``isFollowing`` — a *user intent* fact: true when the sentinel became
///   visible, cleared only when the user scrolls up while it is off screen.
///
/// Rules: follow at most once per 100 ms, never animate while tokens arrive, and
/// give a manual scroll 400 ms of grace so we never fight the trackpad.
@MainActor
@Observable
final class TranscriptScroller {

    /// Show the "scroll to latest" button when we are not following.
    var showsScrollToLatest: Bool { !isFollowing }

    /// Observed: drives the "scroll to latest" button.
    private(set) var isFollowing = true
    /// Only read from the scoped scroll observer, never from a body.
    @ObservationIgnored private(set) var isSentinelVisible = true

    @ObservationIgnored private var lastProgrammaticScroll = Date.distantPast
    @ObservationIgnored private var lastManualScroll = Date.distantPast

    private let minimumInterval: TimeInterval = 0.1
    private let manualScrollGrace: TimeInterval = 0.4

    // MARK: - Sentinels

    /// The end of the list came into view: the user is at the bottom, resume
    /// following. This also fires after we programmatically scroll.
    func bottomSentinelAppeared() {
        isSentinelVisible = true
        isFollowing = true
        RenderDebug.logScroll("sentinel visible → following")
    }

    /// The end of the list left the view (scrolled up, or new content grew).
    /// Intent is deliberately left untouched: growing content must not stop us
    /// from following, only an actual user scroll may do that.
    func bottomSentinelDisappeared() {
        isSentinelVisible = false
    }

    // MARK: - Following

    /// Called whenever new tokens arrive.
    func followIfNeeded(proxy: ScrollViewProxy, lastID: UUID?) {
        guard isFollowing, let lastID else { return }

        let now = Date()
        guard now.timeIntervalSince(lastManualScroll) > manualScrollGrace else { return }
        guard now.timeIntervalSince(lastProgrammaticScroll) > minimumInterval else { return }

        lastProgrammaticScroll = now
        proxy.scrollTo(lastID, anchor: .bottom)
    }

    /// Jumps to the newest message (new chat, first appearance, sending).
    func jumpToBottom(proxy: ScrollViewProxy, lastID: UUID?, animated: Bool) {
        guard let lastID else { return }
        isFollowing = true
        lastProgrammaticScroll = Date()

        if animated {
            withAnimation(.snappy(duration: 0.25)) {
                proxy.scrollTo(lastID, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(lastID, anchor: .bottom)
        }
    }

    func reset() {
        isFollowing = true
        isSentinelVisible = true
        lastManualScroll = .distantPast
        lastProgrammaticScroll = .distantPast
    }

    // MARK: - Manual scrolling

    /// A vertical trackpad/mouse scroll while the end of the list is off screen
    /// means the user took over. Horizontal swipes (tables, code blocks) and
    /// momentum that happens while the bottom is visible are ignored, otherwise
    /// flicking to the bottom would immediately cancel following again.
    func userScrolledVertically() {
        lastManualScroll = Date()
        guard !isSentinelVisible else { return }
        guard isFollowing else { return }

        isFollowing = false
        RenderDebug.logScroll("user scrolled up → following off")
    }
}

// MARK: - Scoped scroll observation

/// Invisible bridge placed inside the transcript. It reports live scrolling
/// from the transcript's own `NSScrollView` only — unlike a global `NSEvent`
/// monitor this cannot observe the sidebar, the composer, or the horizontal
/// scroll views nested inside message rows.
struct TranscriptScrollTracking: NSViewRepresentable {
    let onUserScroll: () -> Void

    func makeNSView(context: Context) -> TranscriptScrollTrackingView {
        let view = TranscriptScrollTrackingView()
        view.onUserScroll = onUserScroll
        return view
    }

    func updateNSView(_ nsView: TranscriptScrollTrackingView, context: Context) {
        nsView.onUserScroll = onUserScroll
        nsView.attachIfNeeded()
    }
}

final class TranscriptScrollTrackingView: NSView {
    var onUserScroll: (() -> Void)?

    private weak var observedScrollView: NSScrollView?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        if window == nil {
            detach()
        } else {
            attachIfNeeded()
        }
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        attachIfNeeded()
    }

    func attachIfNeeded() {
        guard let scrollView = enclosingScrollView else { return }
        guard observedScrollView !== scrollView else { return }

        detach()
        observedScrollView = scrollView
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(liveScrollBegan),
            name: NSScrollView.willStartLiveScrollNotification,
            object: scrollView
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func liveScrollBegan(_ notification: Notification) {
        onUserScroll?()
    }

    private func detach() {
        NotificationCenter.default.removeObserver(
            self,
            name: NSScrollView.willStartLiveScrollNotification,
            object: observedScrollView
        )
        observedScrollView = nil
    }
}
