import CoreGraphics
import CoreVideo
import Foundation
import ScreenCaptureKit
import VideoToolbox

public enum ColorMode: String, CaseIterable, Identifiable, Sendable {
    /// `srgb` encodes like the Mac's own screen and looks closest to it on a TV.
    /// `accurate` is the Rec. 709 video encoding, which comes out darker and more contrasty.
    case srgb, accurate, hdr
    public var id: String { rawValue }
}

public enum Quality: String, CaseIterable, Identifiable, Sendable {
    case good, better, best
    public var id: String { rawValue }

    /// Megabits per second at 4K60; other sizes scale by pixel rate.
    var baseMbps: Double {
        switch self {
        case .good: 25
        case .better: 40
        case .best: 75
        }
    }
}

public struct StreamConfig: Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var fps: Int
    public var color: ColorMode
    public var quality: Quality
    public var tenBit: Bool
    /// Peak brightness advertised to an HDR TV. Lower looks brighter on TVs that tone-map.
    public var hdrPeakNits: Int
    /// Holds about 0.1 s on the TV to absorb Wi-Fi bursts. Best for video; adds delay to typing.
    public var smooth = true
    /// An exact bitrate, like OBS. Nil uses the quality preset.
    public var bitrateMbps: Int?
    /// 0 to 1, applied to the audio sent to the TV.
    public var volume = 1.0
    /// Off when a browser tab's sound arrives on its own, from the extension.
    public var capturesAudio = true
    public var adjustments = Adjustments()

    public init(width: Int = 3840, height: Int = 2160, fps: Int = 60, color: ColorMode = .accurate,
                quality: Quality = .better, tenBit: Bool = true, hdrPeakNits: Int = 1000) {
        self.width = width
        self.height = height
        self.fps = fps
        self.color = color
        self.quality = quality
        self.tenBit = tenBit
        self.hdrPeakNits = hdrPeakNits
    }

    public var bitrate: Int {
        if let bitrateMbps { return min(500, max(5, bitrateMbps)) * 1_000_000 }
        let scale = Double(width * height * fps) / Double(3840 * 2160 * 60)
        return Int(quality.baseMbps * max(scale, 0.25) * 1_000_000)
    }

    /// HDR is meaningless in 8 bits, so it forces 10-bit.
    public var main10: Bool { tenBit || color == .hdr }

    public var pixelFormat: OSType {
        main10 ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    }

    public var profile: CFString {
        main10 ? kVTProfileLevel_HEVC_Main10_AutoLevel : kVTProfileLevel_HEVC_Main_AutoLevel
    }

    /// The color macOS converts the screen into, before encoding.
    public var captureColorSpace: CFString {
        switch color {
        case .hdr: CGColorSpace.itur_2100_PQ
        case .srgb: CGColorSpace.sRGB
        case .accurate: CGColorSpace.itur_709
        }
    }

    /// The label written into the video, so the TV decodes the same color it was given.
    public var primaries: CFString {
        color == .hdr ? kCVImageBufferColorPrimaries_ITU_R_2020 : kCVImageBufferColorPrimaries_ITU_R_709_2
    }
    public var transfer: CFString {
        color == .hdr ? kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ : kCVImageBufferTransferFunction_ITU_R_709_2
    }
    public var matrix: CFString {
        color == .hdr ? kCVImageBufferYCbCrMatrix_ITU_R_2020 : kCVImageBufferYCbCrMatrix_ITU_R_709_2
    }

    /// HEVC SEI mastering display volume: Display P3 primaries, D65, big-endian.
    public var masteringDisplay: Data {
        let values: [UInt16] = [13250, 34500, 7500, 3000, 34000, 16000, 15635, 16450]
        var data = Data()
        for value in values { withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) } }
        withUnsafeBytes(of: UInt32(hdrPeakNits * 10_000).bigEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(1).bigEndian) { data.append(contentsOf: $0) }
        return data
    }

    public var contentLight: Data {
        var data = Data()
        withUnsafeBytes(of: UInt16(hdrPeakNits).bigEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt16(min(hdrPeakNits, 400)).bigEndian) { data.append(contentsOf: $0) }
        return data
    }

    public func json() -> String {
        #"{"type":"config","width":\#(width),"height":\#(height),"fps":\#(fps),"main10":\#(main10),"hdr":\#(color == .hdr),"smooth":\#(smooth)}"#
    }
}
