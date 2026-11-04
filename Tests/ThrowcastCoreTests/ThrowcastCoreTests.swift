import CoreVideo
import VideoToolbox
import XCTest
@testable import ThrowcastCore

final class WireTests: XCTestCase {
    func testGainScalesAudio() {
        let pcm = [Float(0.5)].withUnsafeBufferPointer { l in [Float(0.5)].withUnsafeBufferPointer { r in Wire.pcm16(left: l, right: r, gain: 0.5) } }
        XCTAssertEqual(pcm.withUnsafeBytes { $0.load(as: Int16.self) }, Int16(0.25 * 32767))
    }

    func testGainCoversOnlyWhatTheSiteRefused() {
        XCTAssertEqual(Engine.gain(wanted: 0.3, reported: 0.3), 1)
        XCTAssertEqual(Engine.gain(wanted: 0.3, reported: 0.6), 0.5)
        XCTAssertEqual(Engine.gain(wanted: 0, reported: 0.6), 0)
        XCTAssertEqual(Engine.gain(wanted: 0.5, reported: 0), 1)
    }

    func testUDPLayoutMatchesTheTV() {
        let packet = Data((0 ..< 3000).map { UInt8(truncatingIfNeeded: $0 * 31) })
        let datagrams = MediaUDP.datagrams(frame: 0x0102_0304, packet: Data([Wire.video]) + packet.dropFirst())
        // 3 shards of up to 1200 bytes, then one repair shard for the group.
        XCTAssertEqual(datagrams.count, 4)
        let first = [UInt8](datagrams[0])
        XCTAssertEqual(Array(first[0 ..< 12]), [0x54, 2, 4, 3, 2, 1, 0, 0, 3, 0, 0x58, 0x02])  // the last shard holds 600 bytes
        // The repair shard rebuilds a lost shard: XOR of the others and the repair gives it back.
        let shards = datagrams.prefix(3).map { [UInt8]($0.dropFirst(12)) }
        var rebuilt = [UInt8](datagrams[3].dropFirst(12))
        for shard in [shards[0], shards[2]] { for (i, byte) in shard.enumerated() { rebuilt[i] ^= byte } }
        XCTAssertEqual(Array(rebuilt.prefix(shards[1].count)), shards[1])
    }

    func testH264IsEightBitAndThisMacHasHEVC() {
        var config = StreamConfig(width: 3840, height: 2160)
        config.tenBit = true
        config.codec = .h264
        XCTAssertFalse(config.main10)
        XCTAssertEqual(config.profile as String, kVTProfileLevel_H264_High_AutoLevel as String)
        XCTAssertTrue(config.json().contains(#""codec":"h264""#))
        XCTAssertTrue(VideoCodec.available.contains(.hevc))
    }

    func testCroppedPictureIsCentered() {
        // A browser page below its toolbar, wider than 16:9: full width, with equal bars above and below.
        let rect = Capture.centered(CGSize(width: 1512, height: 762), in: CGSize(width: 3840, height: 2160))
        XCTAssertEqual(rect.width, 3840, accuracy: 1)
        XCTAssertEqual(rect.minY, 2160 - rect.maxY, accuracy: 1)
    }

    func testHiddenWindowWithNoPictureIsBlank() {
        func image(_ fill: CGColor?) -> CGImage {
            let context = CGContext(data: nil, width: 64, height: 40, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            if let fill { context.setFillColor(fill); context.fill(CGRect(x: 0, y: 0, width: 64, height: 40)) }
            return context.makeImage()!
        }
        XCTAssertTrue(Engine.isBlank(image(nil)))                                   // transparent
        XCTAssertTrue(Engine.isBlank(image(CGColor(red: 0, green: 0, blue: 0, alpha: 1))))  // black
        XCTAssertFalse(Engine.isBlank(image(CGColor(red: 0.9, green: 0.9, blue: 0.9, alpha: 1))))  // a light window
    }

    func testWindowTakesTheTVShapeInsideTheScreen() {
        // A MacBook Air's usable area below the menu bar, and a 16:9 TV: as wide as the screen, centered.
        let area = CGRect(x: 0, y: 33, width: 1470, height: 923)
        let fit = WindowFit.shaped(in: area, aspect: 16 / 9)
        XCTAssertEqual(fit.width, 1470, accuracy: 1)
        XCTAssertEqual(fit.width / fit.height, 16 / 9, accuracy: 0.01)
        XCTAssertEqual(fit.midY, area.midY, accuracy: 1)
        // A tall screen is limited by its height instead.
        let tall = WindowFit.shaped(in: CGRect(x: 0, y: 0, width: 1000, height: 400), aspect: 16 / 9)
        XCTAssertEqual(tall.height, 400, accuracy: 1)
        XCTAssertEqual(tall.midX, 500, accuracy: 1)
    }

    func testCropFollowsTheWindow() {
        let original = CGRect(x: 0, y: 88, width: 1920, height: 1080)
        let start = CGSize(width: 1920, height: 1168)
        let aspect: CGFloat = 16 / 9
        XCTAssertEqual(CastSession.crop(original: original, startSize: start, nowSize: start, aspect: aspect), original)
        // Fullscreen on the 1920x1200 TV display: no title bar, the 16:9 middle of the window.
        XCTAssertEqual(CastSession.crop(original: original, startSize: start, nowSize: CGSize(width: 1920, height: 1200), aspect: aspect), CGRect(x: 0, y: 60, width: 1920, height: 1080))
        // Back from fullscreen a little shorter: the title bar is still left out, and the picture stays 16:9.
        let shorter = CastSession.crop(original: original, startSize: start, nowSize: CGSize(width: 1920, height: 1095), aspect: aspect)
        XCTAssertEqual(shorter.minY >= 88, true)
        XCTAssertEqual(shorter.width / shorter.height, aspect, accuracy: 0.01)
    }

    func testMissionControlIsTheDockAtLayer18() {
        let dock: [String: Any] = [kCGWindowOwnerName as String: "Dock", kCGWindowLayer as String: 20]
        let open: [String: Any] = [kCGWindowOwnerName as String: "Dock", kCGWindowLayer as String: 18]
        let app: [String: Any] = [kCGWindowOwnerName as String: "Notes", kCGWindowLayer as String: 18]
        XCTAssertFalse(CastSession.isMissionControl([dock, app]))
        XCTAssertTrue(CastSession.isMissionControl([dock, open]))
    }

    func testAnnexBReplacesLengths() {
        let input = Data([0, 0, 0, 2, 0xAA, 0xBB, 0, 0, 0, 1, 0xCC])
        XCTAssertEqual(Wire.annexB(lengthPrefixed: input), Data([0, 0, 0, 1, 0xAA, 0xBB, 0, 0, 0, 1, 0xCC]))
    }

    func testAnnexBRefusesTruncatedFrames() {
        XCTAssertNil(Wire.annexB(lengthPrefixed: Data([0, 0, 0, 9, 0xAA])))
        XCTAssertNil(Wire.annexB(lengthPrefixed: Data([0, 0])))
    }

    func testPacketLayout() {
        let packet = Wire.packet(kind: Wire.video, key: true, pts: 1.5, payload: Data([7]))
        XCTAssertEqual(packet.count, Wire.headerSize + 1)
        XCTAssertEqual(packet[0], 1)
        XCTAssertEqual(packet[1], 1)
        let bits = packet[8 ..< 16].reversed().reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        XCTAssertEqual(Double(bitPattern: bits), 1.5)
        XCTAssertEqual(packet[16], 7)
    }

    func testPCMClampsAndInterleaves() {
        let left: [Float] = [2, -2]
        let right: [Float] = [0, 0.5]
        let pcm = left.withUnsafeBufferPointer { l in right.withUnsafeBufferPointer { r in Wire.pcm16(left: l, right: r) } }
        let samples = pcm.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        XCTAssertEqual(samples, [32767, 0, -32767, 16383])
    }

    func testParsesRealSamsungAnswer() {
        let json = #"{"device":{"id":"uuid:1","ip":"192.0.2.10","modelName":"UN55AU8000FXZA","name":"Samsung AU8000 55 TV","resolution":"3840x2160"}}"#
        let tv = TV(samsungJSON: Data(json.utf8))
        XCTAssertEqual(tv?.width, 3840)
        XCTAssertEqual(tv?.resolutionLabel, "4K")
    }

    func testHDRForcesTenBitAndBitrateScales() {
        var config = StreamConfig(fps: 30, color: .hdr, tenBit: false)
        XCTAssertTrue(config.main10)
        XCTAssertEqual(config.bitrate, 20_000_000)
        config.color = .accurate
        XCTAssertFalse(config.main10)
    }
}

final class RelayTests: XCTestCase {
    func testPlaylistLinksGoThroughTheRelay() throws {
        let relay = try XCTUnwrap(StreamRelay(allowedHost: "192.0.2.10"))
        let base = URL(string: "https://cdn.example.com/show/master.m3u8")
        let text = "#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI=\"key.bin\"\n#EXTINF:6,\nseg1.ts?a=1\nhttps://other.example.com/seg2.ts\n"
        let lines = relay.rewrite(text, base: base).components(separatedBy: "\n")
        XCTAssertTrue(lines[1].contains("/https/cdn.example.com/show/key.bin"))
        XCTAssertTrue(lines[3].contains("/https/cdn.example.com/show/seg1.ts?a=1"))
        XCTAssertTrue(lines[4].contains("/https/other.example.com/seg2.ts"))
    }

    func testSignedLinksStayExact() throws {
        let relay = try XCTUnwrap(StreamRelay(allowedHost: "192.0.2.10"))
        let original = "https://cdn.example.com/a%20b/c.mp4?sig=a%2Bb%3D&x=1"
        let path = try XCTUnwrap(relay.relayed(original)).components(separatedBy: ":47123")[1]
        XCTAssertEqual(relay.upstream(path: path)?.absoluteString, original)
    }

    func testRepeatedPlayerErrorsDontCrash() {
        let playback = DirectPlayback(host: "192.0.2.10", links: ["http://a/b.mp4"], title: "t", start: 0, relay: nil)
        var failures = 0
        playback.onChange = { if $0.state == "failed" { failures += 1 } }
        playback.handle(["type": "hello"])
        for _ in 0 ..< 3 { playback.handle(["type": "playerError", "attempt": 1]) }
        XCTAssertEqual(failures, 1)
        playback.handle(["type": "playback", "attempt": 1, "state": "idle"])
        XCTAssertEqual(playback.status.state, "failed", "an idle report must not hide the failure")
    }

    func testRepeatedErrorDoesNotSkipTheNextLink() {
        let playback = DirectPlayback(host: "192.0.2.10", links: ["http://a/1.mp4", "http://a/2.mp4"], title: "t", start: 0, relay: nil)
        playback.handle(["type": "hello"])
        playback.handle(["type": "playerError", "attempt": 1])
        playback.handle(["type": "playerError", "attempt": 1])
        playback.handle(["type": "playback", "attempt": 2, "state": "playing", "time": 3.0])
        XCTAssertEqual(playback.status.state, "playing")
        XCTAssertNil(playback.status.error)
    }

    func testRelayPathRoundTripsAndRejectsOtherTokens() throws {
        let relay = try XCTUnwrap(StreamRelay(allowedHost: "192.0.2.10"))
        let original = "https://cdn.example.com:8443/a/b.mp4?sig=x"
        let path = try XCTUnwrap(URL(string: try XCTUnwrap(relay.relayed(original)))).absoluteString.components(separatedBy: ":47123")[1]
        XCTAssertEqual(relay.upstream(path: path)?.absoluteString, original)
        XCTAssertNil(relay.upstream(path: "/wrongtoken/https/cdn.example.com/a.mp4"))
        XCTAssertNil(relay.upstream(path: path.replacingOccurrences(of: "/https/", with: "/file/")))
    }
}

/// The color check: encode a known pattern on the real hardware encoder, read the color label
/// back out of the bitstream, then decode and confirm the pixels did not shift.
final class ColorRoundTripTests: XCTestCase {
    private func formatDescription(_ parameterSets: [Data]) throws -> CMFormatDescription {
        let storage = parameterSets.map { Array($0) }
        let pointers = UnsafeMutablePointer<UnsafePointer<UInt8>>.allocate(capacity: storage.count)
        let copies = storage.map { bytes -> UnsafeMutablePointer<UInt8> in
            let copy = UnsafeMutablePointer<UInt8>.allocate(capacity: bytes.count)
            copy.initialize(from: bytes, count: bytes.count)
            return copy
        }
        defer { copies.forEach { $0.deallocate() }; pointers.deallocate() }
        for (index, copy) in copies.enumerated() { pointers[index] = UnsafePointer(copy) }
        var format: CMFormatDescription?
        XCTAssertEqual(CMVideoFormatDescriptionCreateFromHEVCParameterSets(allocator: nil, parameterSetCount: storage.count, parameterSetPointers: pointers,
                                                                          parameterSetSizes: storage.map(\.count), nalUnitHeaderLength: 4,
                                                                          extensions: nil, formatDescriptionOut: &format), noErr)
        return try XCTUnwrap(format)
    }

    private func solidFrame(_ config: StreamConfig, y: UInt16, cb: UInt16, cr: UInt16) -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, config.width, config.height, config.pixelFormat,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        let pixels = buffer!
        CVPixelBufferLockBaseAddress(pixels, [])
        defer { CVPixelBufferUnlockBaseAddress(pixels, []) }
        let luma = CVPixelBufferGetBaseAddressOfPlane(pixels, 0)!.assumingMemoryBound(to: UInt16.self)
        let chroma = CVPixelBufferGetBaseAddressOfPlane(pixels, 1)!.assumingMemoryBound(to: UInt16.self)
        let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(pixels, 0) / 2
        let chromaStride = CVPixelBufferGetBytesPerRowOfPlane(pixels, 1) / 2
        for row in 0 ..< config.height { for col in 0 ..< config.width { luma[row * lumaStride + col] = y << 6 } }
        for row in 0 ..< config.height / 2 {
            for col in 0 ..< config.width / 2 {
                chroma[row * chromaStride + col * 2] = cb << 6
                chroma[row * chromaStride + col * 2 + 1] = cr << 6
            }
        }
        return pixels
    }

    private func roundTrip(_ config: StreamConfig) throws -> (Data, CVPixelBuffer) {
        let done = expectation(description: "frames")
        done.assertForOverFulfill = false
        var keyFrame: Data?
        let encoder = try HEVCEncoder(config: config) { data, key, _ in
            if key, keyFrame == nil { keyFrame = data; done.fulfill() }
        }
        let frame = solidFrame(config, y: 500, cb: 300, cr: 700)
        for index in 0 ..< 3 { encoder.encode(frame, pts: Double(index) / 30) }
        wait(for: [done], timeout: 10)
        encoder.flush()

        let stream = try XCTUnwrap(keyFrame)
        let units = stream.split(startCode: [0, 0, 0, 1])
        XCTAssertEqual(units.prefix { [32, 33, 34].contains(($0.first ?? 0) >> 1 & 0x3F) }.count, 3, "VPS, SPS and PPS must lead every key frame")
        let format = try formatDescription(Array(units.prefix(3)))

        var body = Data()
        for unit in units.dropFirst(3) {
            withUnsafeBytes(of: UInt32(unit.count).bigEndian) { body.append(contentsOf: $0) }
            body.append(unit)
        }
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: body.count, blockAllocator: nil,
                                           customBlockSource: nil, offsetToData: 0, dataLength: body.count, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
        body.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0, dataLength: body.count) }
        var sample: CMSampleBuffer?
        var size = body.count
        CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 0,
                                  sampleTimingArray: nil, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample)
        var session: VTDecompressionSession?
        XCTAssertEqual(VTDecompressionSessionCreate(allocator: nil, formatDescription: format, decoderSpecification: nil,
                                                    imageBufferAttributes: [kCVPixelBufferPixelFormatTypeKey: config.pixelFormat] as CFDictionary,
                                                    outputCallback: nil, decompressionSessionOut: &session), noErr)
        var out: CVPixelBuffer?
        var decodeStatus: OSStatus = -1
        VTDecompressionSessionDecodeFrame(session!, sampleBuffer: sample!, flags: [], infoFlagsOut: nil) { status, _, image, _, _ in
            decodeStatus = status
            out = image
        }
        VTDecompressionSessionWaitForAsynchronousFrames(session!)
        XCTAssertEqual(decodeStatus, noErr)
        return (stream, try XCTUnwrap(out))
    }

    private func check(_ config: StreamConfig) throws {
        let (stream, decoded) = try roundTrip(config)
        let format = try formatDescription(Array(stream.split(startCode: [0, 0, 0, 1]).prefix(3)))
        let ext = CMFormatDescriptionGetExtensions(format) as? [String: Any] ?? [:]
        XCTAssertEqual(ext[kCVImageBufferColorPrimariesKey as String] as? String, config.primaries as String)
        XCTAssertEqual(ext[kCVImageBufferTransferFunctionKey as String] as? String, config.transfer as String)
        XCTAssertEqual(ext[kCVImageBufferYCbCrMatrixKey as String] as? String, config.matrix as String)

        CVPixelBufferLockBaseAddress(decoded, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(decoded, .readOnly) }
        let row = config.height / 2, col = config.width / 2
        let luma = CVPixelBufferGetBaseAddressOfPlane(decoded, 0)!.assumingMemoryBound(to: UInt16.self)
        let y = Int(luma[row * CVPixelBufferGetBytesPerRowOfPlane(decoded, 0) / 2 + col] >> 6)
        let chroma = CVPixelBufferGetBaseAddressOfPlane(decoded, 1)!.assumingMemoryBound(to: UInt16.self)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(decoded, 1) / 2
        let cb = Int(chroma[row / 2 * stride + col / 2 * 2] >> 6)
        let cr = Int(chroma[row / 2 * stride + col / 2 * 2 + 1] >> 6)
        XCTAssertEqual(y, 500, accuracy: 4)
        XCTAssertEqual(cb, 300, accuracy: 4)
        XCTAssertEqual(cr, 700, accuracy: 4)
    }

    func testAccurateModeKeepsColorAndLabel() throws {
        try check(StreamConfig(width: 1920, height: 1080, fps: 30, color: .accurate, tenBit: true))
    }

    func testHDRModeKeepsColorAndLabel() throws {
        try check(StreamConfig(width: 1920, height: 1080, fps: 30, color: .hdr))
    }

    private func centerLuma(_ pixels: CVPixelBuffer) -> Int {
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        let plane = CVPixelBufferGetBaseAddressOfPlane(pixels, 0)!.assumingMemoryBound(to: UInt16.self)
        let row = CVPixelBufferGetHeight(pixels) / 2, col = CVPixelBufferGetWidth(pixels) / 2
        return Int(plane[row * CVPixelBufferGetBytesPerRowOfPlane(pixels, 0) / 2 + col] >> 6)
    }

    func testAdjustmentsChangeThePicture() throws {
        let config = StreamConfig(width: 640, height: 360, fps: 30)
        let frame = solidFrame(config, y: 500, cb: 512, cr: 512)
        CVBufferSetAttachment(frame, kCVImageBufferYCbCrMatrixKey, config.matrix, .shouldPropagate)
        let adjuster = try XCTUnwrap(FrameAdjuster())
        let same = try XCTUnwrap(adjuster.apply(Adjustments(), to: frame))
        XCTAssertEqual(centerLuma(same), 500, accuracy: 6, "neutral values must not shift the picture")
        let brighter = try XCTUnwrap(adjuster.apply(Adjustments(brightness: 0.2), to: frame))
        XCTAssertGreaterThan(centerLuma(brighter), 560)
        let darker = try XCTUnwrap(adjuster.apply(Adjustments(brightness: -0.2), to: frame))
        XCTAssertLessThan(centerLuma(darker), 440)
    }

    func testAdjustmentRangesAreClamped() {
        XCTAssertEqual(Adjustments(brightness: 9, saturation: -1).brightness, 0.25)
        XCTAssertEqual(Adjustments(brightness: 9, saturation: -1).saturation, 0)
        XCTAssertTrue(Adjustments().isNeutral)
    }

    func testEncoderAccepts4K60Main10() throws {
        _ = try HEVCEncoder(config: StreamConfig()) { _, _, _ in }
    }
}

private extension Data {
    func split(startCode: [UInt8]) -> [Data] {
        var units: [Data] = []
        var cursor = startIndex
        let needle = Data(startCode)
        while let found = range(of: needle, in: cursor ..< endIndex) {
            let next = range(of: needle, in: found.upperBound ..< endIndex)?.lowerBound ?? endIndex
            units.append(self[found.upperBound ..< next])
            cursor = next
        }
        return units
    }
}
