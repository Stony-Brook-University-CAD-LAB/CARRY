import Foundation
import UIKit
import Combine

/// Decodes a `multipart/x-mixed-replace` MJPEG stream (web_stream_node on port 5000) into UIImages.
/// Frames are found by scanning for JPEG SOI (FF D8) / EOI (FF D9) markers, so the exact
/// multipart boundary text does not matter.
///
/// Threading: all stream state (`buffer`, `task`, `url`) lives on `queue`, the session's delegate
/// queue. Published properties are only written on the main thread.
final class MJPEGStream: NSObject, ObservableObject {

    @Published private(set) var image: UIImage?
    @Published private(set) var fps: Double = 0
    /// True only while frames are actually arriving (cleared if nothing is received for 2 s).
    @Published private(set) var isStreaming = false
    @Published private(set) var errorText: String?

    private var session: URLSession!
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.name = "MJPEGStream"
        q.maxConcurrentOperationCount = 1
        return q
    }()

    // Accessed only on `queue`.
    private var task: URLSessionDataTask?
    private var buffer = Data()
    private var frameTimes: [Date] = []
    private var url: URL?
    private var generation = 0

    private var lastFrameAt: Date?
    private var watchdog: Timer?

    override init() {
        super.init()
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = .infinity
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
    }

    // MARK: Public (main thread)

    func start(url: URL) {
        errorText = nil
        queue.addOperation { [self] in
            self.generation += 1
            self.openTask(url: url, generation: self.generation)
        }
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.checkFrameAge() }
        }
    }

    func stop() {
        watchdog?.invalidate()
        watchdog = nil
        queue.addOperation { [self] in
            self.generation += 1
            self.url = nil
            self.task?.cancel()
            self.task = nil
            self.buffer.removeAll()
        }
        isStreaming = false
        fps = 0
    }

    // MARK: Internals (on `queue`)

    private func openTask(url: URL, generation: Int) {
        guard generation == self.generation else { return }
        task?.cancel()
        buffer.removeAll(keepingCapacity: true)
        self.url = url
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let t = session.dataTask(with: request)
        task = t
        t.resume()
    }

    private func scheduleReconnect() {
        guard let url else { return }
        let gen = generation
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.queue.addOperation {
                guard let self, gen == self.generation else { return }
                self.openTask(url: url, generation: gen)
            }
        }
    }

    private func extractFrames() {
        let soi = Data([0xFF, 0xD8])
        let eoi = Data([0xFF, 0xD9])
        while true {
            guard let start = buffer.range(of: soi) else {
                // Keep the last byte: it may be the 0xFF of an SOI split across two chunks.
                buffer = Data(buffer.suffix(1))
                return
            }
            guard let end = buffer.range(of: eoi, in: start.upperBound..<buffer.endIndex) else {
                if start.lowerBound > buffer.startIndex { buffer = Data(buffer[start.lowerBound...]) }
                return
            }
            let frameData = buffer.subdata(in: start.lowerBound..<end.upperBound)
            buffer = Data(buffer[end.upperBound...])
            if let img = UIImage(data: frameData) {
                let now = Date()
                frameTimes.append(now)
                frameTimes.removeAll { now.timeIntervalSince($0) > 2 }
                let fps = Double(frameTimes.count) / 2.0
                DispatchQueue.main.async {
                    self.image = img
                    self.fps = fps
                    self.lastFrameAt = now
                    self.isStreaming = true
                }
            }
        }
    }

    // MARK: Watchdog (main thread)

    private func checkFrameAge() {
        guard let lastFrameAt else { return }
        if Date().timeIntervalSince(lastFrameAt) > 2.0, isStreaming {
            isStreaming = false
            fps = 0
            errorText = "Video stalled — no frames for 2 s"
        }
    }
}

extension MJPEGStream: URLSessionDataDelegate {
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard dataTask === task else { return }
        buffer.append(data)
        if buffer.count > 4_000_000 { buffer.removeAll(keepingCapacity: true) }   // never let a bad stream eat memory
        extractFrames()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard task === self.task else { return }
        self.task = nil
        buffer.removeAll(keepingCapacity: true)
        let text: String
        if let error {
            if (error as NSError).code == NSURLErrorCancelled { return }
            text = "Video: \(error.localizedDescription)"
        } else {
            text = "Video stream closed by rover — reconnecting"
        }
        DispatchQueue.main.async {
            self.isStreaming = false
            self.fps = 0
            self.errorText = text
        }
        scheduleReconnect()
    }
}
