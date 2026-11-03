import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

public enum EncoderError: Error { case create(OSStatus), rejected(String, OSStatus) }

/// Hardware HEVC or H.264 encoder. No B-frames: every frame is decodable on arrival, which is what keeps delay low.
public final class HEVCEncoder {
    private var evenFrames = false
    public typealias Output = (_ annexB: Data, _ key: Bool, _ pts: Double) -> Void

    private let session: VTCompressionSession
    private let output: Output
    private var forceKey = true
    public let config: StreamConfig

    public init(config: StreamConfig, output: @escaping Output) throws {
        self.config = config
        self.output = output
        // Not Apple's low-latency rate control: it holds latency by dropping frames, which shows as
        // uneven motion in video. Real-time mode without B-frames kept 60 fps in full-motion tests.
        let spec: [CFString: Any] = [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true]
        var made: VTCompressionSession?
        let status = VTCompressionSessionCreate(allocator: nil, width: Int32(config.width), height: Int32(config.height),
                                                codecType: config.codec.codecType, encoderSpecification: spec as CFDictionary,
                                                imageBufferAttributes: nil, compressedDataAllocator: nil,
                                                outputCallback: nil, refcon: nil, compressionSessionOut: &made)
        guard status == noErr, let made else { throw EncoderError.create(status) }
        session = made

        let required: [(CFString, CFTypeRef)] = [
            (kVTCompressionPropertyKey_RealTime, kCFBooleanTrue),
            (kVTCompressionPropertyKey_ProfileLevel, config.profile),
            (kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse),
            (kVTCompressionPropertyKey_AverageBitRate, config.bitrate as CFNumber),
            (kVTCompressionPropertyKey_ExpectedFrameRate, config.fps as CFNumber),
            // TCP doesn't lose frames and the TV asks when it needs one, so periodic key frames are just bitrate spikes.
            (kVTCompressionPropertyKey_MaxKeyFrameInterval, (config.fps * 300) as CFNumber),
            (kVTCompressionPropertyKey_ColorPrimaries, config.primaries),
            (kVTCompressionPropertyKey_TransferFunction, config.transfer),
            (kVTCompressionPropertyKey_YCbCrMatrix, config.matrix),
        ]
        for (key, value) in required {
            let status = VTSessionSetProperty(session, key: key, value: value)
            if status != noErr { throw EncoderError.rejected(key as String, status) }
        }
        // Like OBS's low-latency profiles: speed before a little quality. Not MaxFrameDelayCount 0: with
        // B-frames already off it gains nothing, and it made this encoder skip frames (measured 52 to 55 FPS).
        evenFrames = !config.smooth
        if evenFrames {
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, value: kCFBooleanTrue)
        }
        setBitrate(config.bitrate)
        if config.color == .hdr {
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MasteringDisplayColorVolume, value: config.masteringDisplay as CFData)
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ContentLightLevelInfo, value: config.contentLight as CFData)
        }
        VTCompressionSessionPrepareToEncodeFrames(session)
    }

    deinit { invalidate() }

    public func invalidate() { VTCompressionSessionInvalidate(session) }

    public func requestKeyFrame() { forceKey = true }

    /// Takes effect on the next frame, so a busy network costs some sharpness instead of frames.
    public func setBitrate(_ bitsPerSecond: Int) {
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bitsPerSecond as CFNumber)
        let perSecond = Double(bitsPerSecond) / 8
        // A cap on each single frame makes this encoder drop whole frames on fast motion (measured: 37 to
        // 50 FPS at Instant), so the low-delay modes only hold each second closer to the average.
        let limit = [perSecond * (evenFrames ? 1.5 : 2), 1.0] as CFArray
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: limit)
    }

    public func flush() { VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid) }

    public func encode(_ pixels: CVPixelBuffer, pts: Double) {
        var properties: CFDictionary?
        if forceKey {
            forceKey = false
            properties = [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
        }
        let time = CMTime(seconds: pts, preferredTimescale: 90_000)
        VTCompressionSessionEncodeFrame(session, imageBuffer: pixels, presentationTimeStamp: time, duration: .invalid,
                                        frameProperties: properties, infoFlagsOut: nil) { [output] status, _, sample in
            guard status == noErr, let sample, CMSampleBufferDataIsReady(sample),
                  let format = CMSampleBufferGetFormatDescription(sample),
                  let block = CMSampleBufferGetDataBuffer(sample) else { return }
            var length = 0
            var pointer: UnsafeMutablePointer<CChar>?
            guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length,
                                              dataPointerOut: &pointer) == noErr, let pointer else { return }
            let raw = Data(bytesNoCopy: pointer, count: length, deallocator: .none)
            guard var frame = Wire.annexB(lengthPrefixed: raw) else { return }
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
            let key = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool != true
            if key { frame = Wire.parameterSets(format) + frame }
            output(frame, key, CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample)))
        }
    }
}
