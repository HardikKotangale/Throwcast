import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import ScreenCaptureKit

public enum CastSource: Hashable, Sendable {
    case screen, mirror, extend
    /// `crop` is in points within the window, for showing only part of it.
    case window(CGWindowID, crop: CGRect? = nil)
}

public struct CastStats: Sendable {
    public var fps = 0.0
    public var mbps = 0.0
    public var rttMs = 0.0
    public var dropped = 0
    public var maxGapMs = 0.0
    public var bitrateMbps = 0.0
    public var encodedFps = 0.0
    public var capturedFps = 0.0
    public init() {}
}

public enum CastState: Equatable, Sendable {
    case connecting, casting
    case failed(String)
    case stopped
}

public enum CastError: LocalizedError {
    case noDisplay, noWindow, virtualDisplayFailed, timedOut, receiverMissing, windowHidden

    public var errorDescription: String? {
        switch self {
        case .noDisplay: "Couldn't find a display to capture."
        case .noWindow: "That window is no longer open."
        case .virtualDisplayFailed: "macOS refused the TV-sized display. Try This Screen instead."
        case .timedOut: "The TV didn't connect. Open Throwcast on the TV and try again."
        case .receiverMissing: "Throwcast isn't installed on this TV yet."
        case .windowHidden: "Keep the browser window on your current desktop, not minimized, then try again."
        }
    }
}

/// One cast: waits for the TV, starts capture once its player is open, and streams until stopped.
public final class CastSession {
    public var onState: ((CastState) -> Void)?
    public var onStats: ((CastStats) -> Void)?
    /// About once a second, a small JPEG of the picture going to the TV.
    public var onPreview: ((Data) -> Void)?
    /// macOS stopped the capture itself, not this app.
    public var onCaptureEnded: (() -> Void)?

    private let host: String
    private var config: StreamConfig
    private let source: CastSource
    private let server: WebSocketServer
    private let lock = NSLock()
    private var encoder: HEVCEncoder?
    private var capture: Capture?
    private var virtualDisplay: VirtualDisplay?
    private var lastPixels: CVPixelBuffer?
    private var pacer: DispatchSourceTimer?
    private var pacerStart: UInt64 = 0
    private var lastTick = -1
    private var hasFreshFrame = false
    private var holdingPicture = false
    private var windowSize: CGSize?
    private var appliedCrop: CGRect?
    private var adjustments: Adjustments
    private lazy var adjuster = FrameAdjuster()
    private lazy var previewContext = CIContext(options: [.cacheIntermediates: false])
    private var lastSentIndex = 0
    private var bitrate = 0
    private var calmChecks = 0
    private var encodedCount = 0
    private var capturedCount = 0
    private var stats = CastStats()
    private var timers: [DispatchSourceTimer] = []
    private var finished = false
    private let timerQueue = DispatchQueue(label: "throwcast.timers")

    public init(host: String, config: StreamConfig, source: CastSource) {
        self.host = host
        self.config = config
        self.source = source
        bitrate = config.bitrate
        adjustments = config.adjustments
        server = WebSocketServer(allowedHost: host)
    }

    public func start() {
        onState?(.connecting)
        server.onText = { [weak self] in self?.handle($0) }
        server.onDisconnect = { [weak self] in self?.onState?(.connecting) }
        do {
            try server.start()
        } catch {
            finish(.failed("Couldn't open the streaming port: \(error.localizedDescription)"))
            return
        }
        startTimers()
        timerQueue.asyncAfter(deadline: .now() + 25) { [weak self] in
            guard let self, self.capture == nil, !self.finished else { return }
            self.finish(.failed(CastError.timedOut.localizedDescription))
        }
    }

    /// Applies to the next frame, without restarting, so sliders track the TV as they move.
    public func setAdjustments(_ values: Adjustments) {
        lock.withLock {
            adjustments = values
            hasFreshFrame = true
        }
    }

    /// No restart either, so the TV's sound follows the slider.
    public func setVolume(_ value: Double) {
        lock.withLock { config.volume = value }
        capture?.volume = Float(value)
    }

    /// The picture inside a browser window that changed size since the cast began, such as after F made the
    /// page fullscreen: the TV's shape, as large as fits, centered. Fullscreen has no title bar to leave out.
    static func crop(original: CGRect, startSize: CGSize, nowSize: CGSize, aspect: CGFloat) -> CGRect {
        guard abs(nowSize.width - startSize.width) > 2 || abs(nowSize.height - startSize.height) > 2 else { return original }
        let top = nowSize.height > startSize.height ? 0 : original.minY
        let area = CGRect(x: 0, y: top, width: nowSize.width, height: max(nowSize.height - top, 1))
        let width = min(area.width, area.height * aspect)
        let height = width / aspect
        return CGRect(x: area.midX - width / 2, y: area.midY - height / 2, width: width, height: height).integral
    }

    /// A tab's sound from the extension. It's stamped as it arrives, ending now, on the video's clock.
    public func sendTabAudio(_ pcm: Data) {
        guard let capture, let now = capture.now(), pcm.count >= 4 else { return }
        let gain = Float(lock.withLock { config.volume })
        var samples = pcm
        if gain < 0.999 {
            samples.withUnsafeMutableBytes { raw in
                for index in raw.bindMemory(to: Int16.self).indices {
                    let value = raw.bindMemory(to: Int16.self)[index]
                    raw.bindMemory(to: Int16.self)[index] = Int16(Float(Int16(littleEndian: value)) * gain).littleEndian
                }
            }
        }
        let seconds = Double(pcm.count / 4) / 48_000
        server.sendBinary(Wire.packet(kind: Wire.audio, key: true, pts: max(0, now - seconds), payload: samples))
    }

    /// Mission Control shrinks every window, and every kind of capture sees the shrunken picture.
    /// The Dock opens these windows at layer 18 just before anything moves, and closes them once it's over.
    static func isMissionControl(_ windows: [[String: Any]]) -> Bool {
        windows.contains { $0[kCGWindowOwnerName as String] as? String == "Dock" && $0[kCGWindowLayer as String] as? Int == 18 }
    }

    private var sourceCrop: CGRect? {
        if case let .window(_, crop) = source { return crop }
        return nil
    }

    public func stop() { finish(.stopped) }
    public func fail(_ message: String) { finish(.failed(message)) }

    private func finish(_ state: CastState) {
        guard lock.withLock({ let was = finished; finished = true; return !was }) else { return }
        timers.forEach { $0.cancel() }
        pacer?.cancel()
        server.stop()
        let capture = capture
        Task {
            await capture?.stop()
            self.encoder?.invalidate()
            self.virtualDisplay = nil
            self.onState?(state)
        }
    }

    private func handle(_ message: [String: Any]) {
        switch message["type"] as? String {
        case "hello":
            // An SDR TV would show HDR as washed out, so it gets Accurate instead.
            if config.color == .hdr, message["hdr"] as? Bool == false { config.color = .srgb }
            server.sendText(config.json())
        case "ready":
            Task { await beginCapture() }
        case "idr":
            encoder?.requestKeyFrame()
        case "pong":
            if let sent = message["t"] as? Double {
                lock.withLock { stats.rttMs = (Date().timeIntervalSince1970 - sent) * 1000 }
            }
        case "stats":
            lock.withLock {
                stats.fps = message["fps"] as? Double ?? 0
                stats.mbps = message["mbps"] as? Double ?? 0
                stats.maxGapMs = message["maxGapMs"] as? Double ?? 0
            }
        case "error":
            finish(.failed("The TV reported: \(message["message"] as? String ?? "unknown error")"))
        default: break
        }
    }

    private func beginCapture() async {
        // The TV reconnecting mid-cast only needs a fresh key frame.
        if capture != nil {
            encoder?.requestKeyFrame()
            onState?(.casting)
            return
        }
        do {
            let encoder = try HEVCEncoder(config: config) { [weak self] data, key, pts in
                guard let self else { return }
                self.lock.withLock { self.encodedCount += 1 }
                self.server.sendBinary(Wire.packet(kind: Wire.video, key: key, pts: pts, payload: data))
            }
            let capture = try Capture(filter: await makeFilter(), config: config, crop: sourceCrop)
            capture.volume = Float(config.volume)
            capture.onEnded = { [weak self] in
                self?.onCaptureEnded?()
                self?.stop()
            }
            capture.onVideo = { [weak self] pixels, pts in self?.video(pixels, pts: pts) }
            capture.onAudio = { [weak self] pcm, pts in
                guard let self else { return }
                self.server.sendBinary(Wire.packet(kind: Wire.audio, key: true, pts: pts, payload: pcm))
            }
            self.encoder = encoder
            self.capture = capture
            try await capture.start()
            onState?(.casting)
        } catch {
            // macOS can't capture a window on another desktop, and says so only as "capture failure".
            let code = (error as NSError).code
            finish(.failed(code == -3811 && sourceCrop != nil ? CastError.windowHidden.localizedDescription : error.localizedDescription))
        }
    }

    // Not just on-screen windows: a browser window can be on another Space, or covered.
    private func content() async throws -> SCShareableContent {
        try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
    }

    private func makeFilter() async throws -> SCContentFilter {
        switch source {
        case .screen:
            let displays = try await content().displays
            guard let display = displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? displays.first else { throw CastError.noDisplay }
            return SCContentFilter(display: display, excludingWindows: [])
        case let .window(id, _):
            guard let window = try await content().windows.first(where: { $0.windowID == id }) else { throw CastError.noWindow }
            return SCContentFilter(desktopIndependentWindow: window)
        case .mirror, .extend:
            guard let display = VirtualDisplay(width: config.width, height: config.height, fps: config.fps, name: "Throwcast TV") else {
                throw CastError.virtualDisplayFailed
            }
            virtualDisplay = display
            if source == .mirror, !display.mirrorMainDisplay() { throw CastError.virtualDisplayFailed }
            // A new display takes a moment to reach ScreenCaptureKit.
            for _ in 0 ..< 25 {
                try await Task.sleep(for: .milliseconds(200))
                let wanted = source == .mirror ? CGDisplayPrimaryDisplay(display.id) : display.id
                if let found = try await content().displays.first(where: { $0.displayID == wanted }) {
                    return SCContentFilter(display: found, excludingWindows: [])
                }
            }
            throw CastError.virtualDisplayFailed
        }
    }

    private func video(_ pixels: CVPixelBuffer, pts: Double) {
        let start = lock.withLock {
            // The last good picture stays on the TV, and its sound keeps playing.
            guard !holdingPicture else { return false }
            lastPixels = pixels
            hasFreshFrame = true
            capturedCount += 1
            guard pacer == nil else { return false }
            // Half a frame in, so ticks land mid-slot. On the edge of a slot, a tick that's a little
            // late lands in the next one, and that frame is never sent.
            pacerStart = DispatchTime.now().uptimeNanoseconds - UInt64(pts * 1e9) - UInt64(500_000_000 / config.fps)
            return true
        }
        if start { startPacer() }
    }

    /// Sends on a fixed clock so frames carry even timestamps, whatever timing macOS delivers them with.
    /// Only changed frames are encoded: a still screen costs almost no power on the Mac or the TV.
    private func startPacer() {
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: DispatchQueue(label: "throwcast.pacer", qos: .userInteractive))
        timer.schedule(deadline: .now(), repeating: .nanoseconds(1_000_000_000 / config.fps), leeway: .microseconds(500))
        timer.setEventHandler { [weak self] in self?.tick() }
        lock.withLock { pacer = timer }
        timer.resume()
    }

    private func tick() {
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - pacerStart) / 1e9
        let index = Int(elapsed * Double(config.fps))
        // A slow trickle while still lets the picture sharpen and tells the TV the cast is alive.
        let keepAlive = config.fps / 2
        let frame: CVPixelBuffer? = lock.withLock {
            guard index != lastTick else { return nil }
            lastTick = index
            guard hasFreshFrame || index - lastSentIndex >= keepAlive else { return nil }
            hasFreshFrame = false
            lastSentIndex = index
            return lastPixels
        }
        guard let frame else { return }
        // Skipping before the encoder keeps every sent frame decodable. Smooth has 0.4 s of buffer
        // on the TV, so a late frame is still on time and only a long stall is worth skipping for.
        if server.inflightBytes > bitrate / 8 / (config.smooth ? 2 : 8) {
            lock.withLock { stats.dropped += 1 }
            return
        }
        let values = lock.withLock { adjustments }
        let adjusted = values.isNeutral ? frame : adjuster?.apply(values, to: frame) ?? frame
        encoder?.encode(adjusted, pts: Double(index) / Double(config.fps))
    }

    /// Video changes every pixel, so it can need more than the TV's Wi-Fi carries. Backing off
    /// the bitrate early keeps the frame rate steady; it climbs back once the link is calm.
    private func adaptBitrate() {
        let rtt = lock.withLock { stats.rttMs }
        let backlogMs = server.inflightBytes * 8000 / max(config.bitrate, 1)
        // Only network signals: a low TV frame rate can come from the encoder holding its target,
        // and lowering the target for that would drop even more frames.
        let struggling = config.smooth ? backlogMs > 300 || rtt > 350 : backlogMs > 80 || rtt > 150
        var next = bitrate
        if struggling {
            calmChecks = 0
            next = max(config.bitrate * 3 / 10, bitrate * 4 / 5)
        } else {
            calmChecks += 1
            if calmChecks >= 6 {
                calmChecks = 0
                next = min(config.bitrate, bitrate * 6 / 5)
            }
        }
        if next != bitrate {
            bitrate = next
            encoder?.setBitrate(next)
        }
        lock.withLock { stats.bitrateMbps = Double(next) / 1e6 }
    }

    private func sendPreview() {
        guard let onPreview, let pixels = lock.withLock({ lastPixels }) else { return }
        let image = CIImage(cvPixelBuffer: pixels)
        let scale = 480 / max(image.extent.width, 1)
        let small = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        if let jpeg = previewContext.jpegRepresentation(of: small, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) { onPreview(jpeg) }
    }

    private func followWindowSize(_ windows: [[String: Any]]) {
        guard case let .window(id, original?) = source, let capture,
              let bounds = windows.first(where: { $0[kCGWindowNumber as String] as? Int == Int(id) })?[kCGWindowBounds as String] as? [String: Double],
              let width = bounds["Width"], let height = bounds["Height"] else { return }
        let size = CGSize(width: width, height: height)
        let start = windowSize ?? size
        windowSize = start
        let next = Self.crop(original: original, startSize: start, nowSize: size, aspect: CGFloat(config.width) / CGFloat(config.height))
        guard next != (appliedCrop ?? original) else { return }
        appliedCrop = next
        Task { await capture.setCrop(next) }
    }

    private func startTimers() {
        func every(_ seconds: Double, _ body: @escaping (CastSession) -> Void) {
            let timer = DispatchSource.makeTimerSource(queue: timerQueue)
            timer.schedule(deadline: .now() + seconds, repeating: seconds)
            timer.setEventHandler { [weak self] in if let self { body(self) } }
            timer.resume()
            timers.append(timer)
        }
        if case .window = source {
            every(0.05) { session in
                let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
                let open = Self.isMissionControl(windows)
                session.lock.withLock { session.holdingPicture = open }
                session.followWindowSize(windows)
            }
        }
        every(0.25) { session in
            session.server.sendText(#"{"type":"ping","t":\#(Date().timeIntervalSince1970)}"#)
            session.adaptBitrate()
        }
        every(1) { session in
            session.sendPreview()
            session.onStats?(session.lock.withLock {
                session.stats.encodedFps = Double(session.encodedCount)
                session.encodedCount = 0
                session.stats.capturedFps = Double(session.capturedCount)
                session.capturedCount = 0
                return session.stats
            })
        }
    }
}
