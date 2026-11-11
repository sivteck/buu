import Foundation
import VirtualMacCore

struct RestoreDownloadProgress: Sendable {
    var bytesWritten: Int64
    var totalBytes: Int64
    var fraction: Double?
    var bytesPerSecond: Double?
    var etaSeconds: TimeInterval?

    var isComplete: Bool {
        guard let fraction else { return false }
        return fraction >= 1
    }
}

/// Resumable Apple restore-image download.
///
/// Resume data is kept next to the destination (`<name>.ipsw.resume`) so a
/// network failure, cancellation or app restart can continue from the partial
/// file. If the server rejects stale resume data, one fresh retry is attempted
/// automatically.
final class RestoreDownload: NSObject, URLSessionDownloadDelegate {
    let destination: URL
    let resumeURL: URL
    var onProgress: ((RestoreDownloadProgress) -> Void)?
    var onResume: (() -> Void)?

    private var continuation: CheckedContinuation<URL, Error>?
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var result: Result<URL, Error>?
    private var sourceURL: URL?
    private var usedResumeData = false
    private var retriedWithoutResume = false
    private var finished = false
    private var cancelling = false

    private var lastReportAt = Date.distantPast
    private var lastLoggedPercent = -1
    private var speedSampleAt = Date()
    private var speedSampleBytes: Int64 = 0
    private var hasSpeedBaseline = false
    private var smoothedSpeed: Double?

    init(destination: URL) {
        self.destination = destination
        resumeURL = destination.appendingPathExtension("resume")
    }

    var hasResumeData: Bool {
        guard let values = try? resumeURL.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize else {
            return false
        }
        return size > 0
    }

    func run(from url: URL) async throws -> URL {
        sourceURL = url
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            start()
        }
    }

    /// Stop the download and persist URLSession's resume data.
    func cancel() {
        guard !finished else { return }
        cancelling = true
        if let task {
            task.cancel(byProducingResumeData: { [weak self] data in
                guard let self else { return }
                if let data {
                    try? data.write(to: self.resumeURL, options: .atomic)
                }
                self.finish(.failure(CancellationError()))
            })
        } else {
            finish(.failure(CancellationError()))
        }
    }

    private func start() {
        guard let sourceURL else {
            finish(.failure(Failure("No restore-image URL to download.")))
            return
        }
        retriedWithoutResume = false
        result = nil
        finished = false
        cancelling = false
        lastReportAt = .distantPast
        lastLoggedPercent = -1
        speedSampleAt = Date()
        speedSampleBytes = 0
        hasSpeedBaseline = false
        smoothedSpeed = nil

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 86400
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        self.session = session

        let task: URLSessionDownloadTask
        if let data = try? Data(contentsOf: resumeURL), !data.isEmpty {
            usedResumeData = true
            onResume?()
            stderr("Resuming the macOS download…")
            task = session.downloadTask(withResumeData: data)
        } else {
            usedResumeData = false
            try? FileManager.default.removeItem(at: resumeURL)
            task = session.downloadTask(with: sourceURL)
        }
        self.task = task
        task.resume()
    }

    // MARK: - URLSessionDownloadDelegate

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard !finished else { return }
        let now = Date()

        if !hasSpeedBaseline {
            hasSpeedBaseline = true
            speedSampleAt = now
            speedSampleBytes = totalBytesWritten
        }

        let sampleInterval = now.timeIntervalSince(speedSampleAt)
        if sampleInterval >= 0.5 {
            let instantaneous = Double(totalBytesWritten - speedSampleBytes) / sampleInterval
            smoothedSpeed = smoothedSpeed.map { $0 * 0.7 + instantaneous * 0.3 } ?? instantaneous
            speedSampleAt = now
            speedSampleBytes = totalBytesWritten
        }

        // Keep UI updates responsive without dispatching for every tiny chunk.
        guard now.timeIntervalSince(lastReportAt) >= 0.25 else { return }
        lastReportAt = now

        let total = max(totalBytesExpectedToWrite, 0)
        let fraction: Double? = total > 0
            ? min(1, max(0, Double(totalBytesWritten) / Double(total)))
            : nil
        let remaining = total > 0 ? max(0, Double(total - totalBytesWritten)) : nil
        let eta: TimeInterval? = {
            guard let remaining, let smoothedSpeed, smoothedSpeed > 0 else { return nil }
            return remaining / smoothedSpeed
        }()

        let progress = RestoreDownloadProgress(
            bytesWritten: totalBytesWritten,
            totalBytes: total,
            fraction: fraction,
            bytesPerSecond: smoothedSpeed,
            etaSeconds: eta
        )
        onProgress?(progress)

        let percent = Int(((fraction ?? 0) * 100).rounded())
        if percent / 5 != lastLoggedPercent / 5 {
            lastLoggedPercent = percent
            stderr(String(
                format: "Downloading macOS: %.0f%% (%.1f / %.1f GiB, %.1f MB/s)",
                (fraction ?? 0) * 100,
                Double(totalBytesWritten) / 1_073_741_824,
                Double(total) / 1_073_741_824,
                (smoothedSpeed ?? 0) / 1_000_000
            ))
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        do {
            guard let response = downloadTask.response as? HTTPURLResponse,
                  [200, 206].contains(response.statusCode) else {
                throw Failure("Apple restore-image download failed.")
            }
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: location, to: destination)
            try? FileManager.default.removeItem(at: resumeURL)
            result = .success(destination)
        } catch {
            result = .failure(error)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard !finished else { return }

        if let error {
            let nsError = error as NSError
            let resume = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
            if let resume {
                try? resume.write(to: resumeURL, options: .atomic)
            }

            if cancelling {
                finish(.failure(CancellationError()))
                return
            }

            if resume == nil, usedResumeData, !retriedWithoutResume {
                // Stale/corrupt resume data: retry once from the start.
                retriedWithoutResume = true
                try? FileManager.default.removeItem(at: resumeURL)
                session.finishTasksAndInvalidate()
                self.session = nil
                self.task = nil
                start()
                return
            }
            if resume == nil {
                try? FileManager.default.removeItem(at: resumeURL)
            }
            finish(.failure(error))
            return
        }

        if let result {
            finish(result)
        } else {
            finish(.failure(Failure("Download ended without a file.")))
        }
    }

    private func finish(_ result: Result<URL, Error>) {
        guard !finished else { return }
        finished = true
        continuation?.resume(with: result)
        continuation = nil
        task = nil
        session?.finishTasksAndInvalidate()
        session = nil
    }
}
