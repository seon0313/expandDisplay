import CoreMedia
import Foundation
import VideoToolbox

/// Hardware H.264 encoder tuned for low latency. Produces Annex-B access units.
final class VideoEncoder {
    /// (annexB, isKeyframe, ptsMicroseconds) — `nil` data means the frame was dropped/failed.
    var onOutput: ((Data?, Bool, Int64) -> Void)?

    private var session: VTCompressionSession?
    let width: Int
    let height: Int

    init?(width: Int, height: Int, fps: Int, bitrate: Int) {
        self.width = width
        self.height = height

        let lowLatencySpec: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true,
            kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true,
        ]
        let hwSpec: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true,
        ]
        var created: VTCompressionSession?
        for spec in [lowLatencySpec, hwSpec] {
            let status = VTCompressionSessionCreate(
                allocator: nil, width: Int32(width), height: Int32(height),
                codecType: kCMVideoCodecType_H264,
                encoderSpecification: spec as CFDictionary,
                imageBufferAttributes: nil, compressedDataAllocator: nil,
                outputCallback: nil, refcon: nil, compressionSessionOut: &created)
            if status == noErr, created != nil { break }
            created = nil
        }
        guard let session = created else { return nil }
        self.session = session

        func set(_ key: CFString, _ value: Any) {
            VTSessionSetProperty(session, key: key, value: value as CFTypeRef)
        }
        set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue!)
        set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse!)
        set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_High_AutoLevel)
        applyBitrate(session, bitrate)
        set(kVTCompressionPropertyKey_ExpectedFrameRate, fps as CFNumber)
        // TCP is lossless, so periodic keyframes are only a safety net. Keyframes are 5-10x larger
        // than P-frames and cause visible stutter, so keep them rare; the phone asks for one when needed.
        set(kVTCompressionPropertyKey_MaxKeyFrameInterval, (fps * 60) as CFNumber)
        set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, 60 as CFNumber)
        set(kVTCompressionPropertyKey_MaxFrameDelayCount, 0 as CFNumber)
        if #available(macOS 13.0, *) {
            set(kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, kCFBooleanTrue!)
        }
        VTCompressionSessionPrepareToEncodeFrames(session)
    }

    deinit { invalidate() }

    /// Change bitrate on the fly, without recreating the session.
    func setBitrate(_ bitrate: Int) {
        guard let session else { return }
        applyBitrate(session, bitrate)
    }

    private func applyBitrate(_ session: VTCompressionSession, _ bitrate: Int) {
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrate as CFNumber)
        // Cap bursts at ~1.5x the average over one second.
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits,
                             value: [bitrate * 3 / 2 / 8, 1] as CFArray)
    }

    func invalidate() {
        if let session {
            VTCompressionSessionInvalidate(session)
        }
        session = nil
    }

    func encode(_ pixelBuffer: CVPixelBuffer, pts: CMTime, forceKeyframe: Bool) {
        guard let session else {
            onOutput?(nil, false, 0)
            return
        }
        let props: CFDictionary? = forceKeyframe
            ? [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue!] as CFDictionary
            : nil
        let ptsUs = Int64(CMTimeGetSeconds(pts) * 1_000_000)
        let status = VTCompressionSessionEncodeFrame(
            session, imageBuffer: pixelBuffer, presentationTimeStamp: pts,
            duration: .invalid, frameProperties: props, infoFlagsOut: nil
        ) { [weak self] status, _, sampleBuffer in
            guard let self else { return }
            guard status == noErr, let sampleBuffer,
                  let result = Self.annexB(from: sampleBuffer) else {
                self.onOutput?(nil, false, ptsUs)
                return
            }
            self.onOutput?(result.0, result.1, ptsUs)
        }
        if status != noErr {
            onOutput?(nil, false, ptsUs)
        }
    }

    private static let startCode: [UInt8] = [0, 0, 0, 1]

    private static func annexB(from sb: CMSampleBuffer) -> (Data, Bool)? {
        var isKey = true
        if let arr = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[CFString: Any]],
           let first = arr.first {
            isKey = !((first[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false)
        }

        var out = Data()
        var nalHeaderLength: Int32 = 4
        if let fmt = CMSampleBufferGetFormatDescription(sb) {
            var count = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                fmt, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil,
                parameterSetCountOut: &count, nalUnitHeaderLengthOut: &nalHeaderLength)
            if isKey {
                for i in 0..<count {
                    var ptr: UnsafePointer<UInt8>?
                    var size = 0
                    let st = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                        fmt, parameterSetIndex: i, parameterSetPointerOut: &ptr, parameterSetSizeOut: &size,
                        parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                    if st == noErr, let ptr {
                        out.append(contentsOf: startCode)
                        out.append(ptr, count: size)
                    }
                }
            }
        }

        guard let block = CMSampleBufferGetDataBuffer(sb) else { return nil }
        let total = CMBlockBufferGetDataLength(block)
        var avcc = [UInt8](repeating: 0, count: total)
        let st = avcc.withUnsafeMutableBytes {
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: total, destination: $0.baseAddress!)
        }
        guard st == noErr else { return nil }

        let hl = Int(nalHeaderLength)
        var off = 0
        out.reserveCapacity(out.count + total + 16)
        while off + hl <= total {
            var len = 0
            for i in 0..<hl { len = (len << 8) | Int(avcc[off + i]) }
            off += hl
            guard len > 0, off + len <= total else { break }
            out.append(contentsOf: startCode)
            out.append(contentsOf: avcc[off..<(off + len)])
            off += len
        }
        return (out, isKey)
    }
}
