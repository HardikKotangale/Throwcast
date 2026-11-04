import CoreMedia
import QuartzCore
import CoreVideo
import Foundation
import ScreenCaptureKit

/// Delivers the screen and system audio on one clock, so sync is decided here and kept all the way to the TV.
final class Capture: NSObject, SCStreamOutput, SCStreamDelegate {
    var onVideo: ((CVPixelBuffer, Double) -> Void)?
    var onAudio: ((Data, Double) -> Void)?
    /// macOS ended the capture: its Stop Sharing button, or the window closing.
    var onEnded: (() -> Void)?
    private var stream: SCStream!
    private let settings: SCStreamConfiguration
    private let queue = DispatchQueue(label: "throwcast.capture", qos: .userInteractive)
    private let audioQueue = DispatchQueue(label: "throwcast.audio", qos: .userInteractive)
    private let lock = NSLock()
    private var origin: Double?
    private var gain: Float = 1

    init(filter: SCContentFilter, config: StreamConfig, crop: CGRect? = nil) throws {
        let settings = config.color == .hdr ? SCStreamConfiguration(preset: .captureHDRStreamCanonicalDisplay) : SCStreamConfiguration()
        settings.width = config.width
        settings.height = config.height
        settings.scalesToFit = true
        // Asking for exactly the frame rate makes macOS skip a frame whenever one arrives a hair early.
        // Twice as fast leaves that margin, and the pacer still sends only `fps` a second.
        settings.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(config.fps * 2))
        settings.queueDepth = 4
        settings.pixelFormat = config.pixelFormat
        settings.colorSpaceName = config.captureColorSpace
        settings.colorMatrix = config.matrix
        settings.showsCursor = true
        settings.capturesAudio = config.capturesAudio
        settings.sampleRate = 48_000
        settings.channelCount = 2
        settings.excludesCurrentProcessAudio = true
        if let crop {
            settings.sourceRect = crop
            settings.destinationRect = Self.centered(crop.size, in: CGSize(width: config.width, height: config.height))
        }
        self.settings = settings
        super.init()
        stream = SCStream(filter: filter, configuration: settings, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if config.capturesAudio { try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue) }
    }

    var volume: Float {
        get { lock.withLock { gain } }
        set { lock.withLock { gain = newValue } }
    }

    func start() async throws { try await stream.startCapture() }

    /// Starts or stops taking the browser's own sound, without restarting the stream.
    func setSystemAudio(_ on: Bool) async {
        guard settings.capturesAudio != on else { return }
        settings.capturesAudio = on
        if on { try? stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue) }
        try? await stream.updateConfiguration(settings)
        if !on { try? stream.removeStreamOutput(self, type: .audio) }
    }

    /// Changes the part of the window that's captured, without restarting the stream.
    func setCrop(_ crop: CGRect) async {
        settings.sourceRect = crop
        settings.destinationRect = Self.centered(crop.size, in: CGSize(width: settings.width, height: settings.height))
        try? await stream.updateConfiguration(settings)
    }

    /// ScreenCaptureKit puts a cropped picture in the top-left corner; this centers it, as large as fits.
    static func centered(_ size: CGSize, in output: CGSize) -> CGRect {
        let aspect = size.width / max(size.height, 1)
        let width = min(output.width, output.height * aspect)
        let height = width / aspect
        return CGRect(x: (output.width - width) / 2, y: (output.height - height) / 2, width: width, height: height)
    }

    func stop() async { try? await stream.stopCapture() }

    func stream(_ stream: SCStream, didStopWithError error: Error) { onEnded?() }

    /// Now, on the same clock as the captured frames, so sound from elsewhere lines up with them.
    func now() -> Double? {
        lock.withLock { origin.map { max(0, CACurrentMediaTime() - $0) } }
    }

    private func relative(_ sample: CMSampleBuffer) -> Double {
        let time = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
        return lock.withLock {
            if origin == nil { origin = time }
            return max(0, time - origin!)
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sample.isValid else { return }
        switch type {
        case .screen:
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
                  let pixels = CMSampleBufferGetImageBuffer(sample) else { return }
            onVideo?(pixels, relative(sample))
        case .audio:
            deliverAudio(sample)
        default: break
        }
    }

    private func deliverAudio(_ sample: CMSampleBuffer) {
        var blockBuffer: CMBlockBuffer?
        var needed = 0
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sample, bufferListSizeNeededOut: &needed, bufferListOut: nil,
                                                                bufferListSize: 0, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
                                                                flags: 0, blockBufferOut: nil)
        let storage = UnsafeMutableRawPointer.allocate(byteCount: needed, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { storage.deallocate() }
        let pointer = storage.bindMemory(to: AudioBufferList.self, capacity: 1)
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sample, bufferListSizeNeededOut: nil, bufferListOut: pointer,
                                                                      bufferListSize: needed, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
                                                                      flags: 0, blockBufferOut: &blockBuffer) == noErr else { return }
        let buffers = UnsafeMutableAudioBufferListPointer(pointer)
        guard buffers.count == 2, let left = buffers[0].mData, let right = buffers[1].mData else { return }
        let frames = Int(buffers[0].mDataByteSize) / MemoryLayout<Float>.size
        let pcm = Wire.pcm16(left: UnsafeBufferPointer(start: left.assumingMemoryBound(to: Float.self), count: frames),
                             right: UnsafeBufferPointer(start: right.assumingMemoryBound(to: Float.self), count: frames), gain: volume)
        onAudio?(pcm, relative(sample))
    }
}
