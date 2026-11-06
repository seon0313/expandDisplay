import CoreMedia
import Foundation
import ScreenCaptureKit

enum PipelineError: LocalizedError {
    case displayNotFound
    case encoderFailed

    var errorDescription: String? {
        switch self {
        case .displayNotFound: return "가상 디스플레이를 캡처 대상으로 찾지 못했습니다 (화면 기록 권한 확인)"
        case .encoderFailed: return "H.264 인코더를 만들 수 없습니다"
        }
    }
}

/// Captures one display with ScreenCaptureKit, encodes with VideoToolbox, ships frames to the session.
/// All mutable state lives on `queue` (= the session's network queue).
final class CapturePipeline: NSObject, SCStreamOutput, SCStreamDelegate {
    let displayID: CGDirectDisplayID
    let width: Int
    let height: Int
    let fps: Int
    let bitrate: Int
    var onError: ((Error) -> Void)?

    private weak var session: ClientSession?
    private let queue: DispatchQueue
    private var stream: SCStream?
    private var encoder: VideoEncoder?

    private var lastPixelBuffer: CVPixelBuffer?
    private var forceKeyframe = true
    private var dirty = false
    private var inFlight = 0
    private var stopped = false
    /// Max frames encoded-but-not-yet-handed-to-the-kernel. Keeps latency bounded on slow Wi-Fi.
    private let maxInFlight = 2

    init(displayID: CGDirectDisplayID, width: Int, height: Int, fps: Int, bitrate: Int, session: ClientSession) {
        self.displayID = displayID
        self.width = width
        self.height = height
        self.fps = fps
        self.bitrate = bitrate
        self.session = session
        self.queue = session.queue
        super.init()
    }

    func start() async throws {
        var scDisplay: SCDisplay?
        for _ in 0..<40 {
            if stopped { return }
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            if let d = content.displays.first(where: { $0.displayID == displayID }) {
                scDisplay = d
                break
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        guard let scDisplay else { throw PipelineError.displayNotFound }

        guard let encoder = VideoEncoder(width: width, height: height, fps: fps, bitrate: bitrate) else {
            throw PipelineError.encoderFailed
        }
        encoder.onOutput = { [weak self] data, key, pts in
            self?.queue.async { self?.deliver(data, key: key, ptsUs: pts) }
        }

        let filter = SCContentFilter(display: scDisplay, excludingWindows: [])
        let cfg = SCStreamConfiguration()
        cfg.width = width
        cfg.height = height
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        cfg.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        cfg.queueDepth = 6
        cfg.showsCursor = true
        cfg.capturesAudio = false
        cfg.colorSpaceName = CGColorSpace.sRGB

        let s = SCStream(filter: filter, configuration: cfg, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)

        queue.sync {
            self.encoder = encoder
            self.stream = s
        }
        if stopped { return }
        try await s.startCapture()
    }

    func stop() {
        queue.async {
            self.stopped = true
            self.encoder?.invalidate()
            self.encoder = nil
            self.lastPixelBuffer = nil
            if let s = self.stream {
                self.stream = nil
                s.stopCapture { _ in }
            }
        }
    }

    func requestKeyframe() {
        queue.async {
            self.forceKeyframe = true
            self.dirty = true
            self.encodeIfPossible()
        }
    }

    // MARK: SCStreamOutput (on queue)

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, !stopped, sampleBuffer.isValid else { return }
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: rawStatus),
              status == .complete,
              let pb = sampleBuffer.imageBuffer else { return }
        lastPixelBuffer = pb
        dirty = true
        encodeIfPossible()
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { self.onError?(error) }
    }

    // MARK: Encoding / flow control (on queue)

    private func encodeIfPossible() {
        guard !stopped, dirty, let pb = lastPixelBuffer, let encoder else { return }
        guard inFlight < maxInFlight else { return } // wait for the network to drain
        dirty = false
        inFlight += 1
        let key = forceKeyframe
        forceKeyframe = false
        // Host clock keeps PTS strictly increasing even when re-encoding the same buffer.
        let pts = CMClockGetTime(CMClockGetHostTimeClock())
        encoder.encode(pb, pts: pts, forceKeyframe: key)
    }

    private func deliver(_ data: Data?, key: Bool, ptsUs: Int64) {
        guard let data, let session, !stopped else {
            inFlight = max(0, inFlight - 1)
            if data == nil { forceKeyframe = true; dirty = true }
            encodeIfPossible()
            return
        }
        var payload = Data(capacity: data.count + 9)
        payload.append(key ? 1 : 0)
        payload.appendBE(ptsUs)
        payload.append(data)
        session.send(type: Proto.frame, payload: payload) { [weak self] in
            guard let self else { return }
            self.queue.async {
                self.inFlight = max(0, self.inFlight - 1)
                self.encodeIfPossible()
            }
        }
    }
}
