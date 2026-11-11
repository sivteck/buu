import AppKit
import QuickLookUI

final class QuickLookPresenter: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    @MainActor static let shared = QuickLookPresenter()
    private let lock = NSLock()
    private var previewedURL: URL?

    @MainActor
    func present(_ url: URL) {
        lock.lock()
        previewedURL = url
        lock.unlock()
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        lock.lock()
        let hasURL = previewedURL != nil
        lock.unlock()
        return hasURL ? 1 : 0
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        lock.lock()
        let url = previewedURL
        lock.unlock()
        return url.map { $0 as NSURL }
    }
}
