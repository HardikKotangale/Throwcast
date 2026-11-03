import CoreMedia
import Foundation

/// Binary WebSocket message: kind(1) flags(1) pad(6) pts-seconds(Float64 LE) payload.
/// The 16-byte header keeps the payload 8-byte aligned for the TV's JavaScript.
public enum Wire {
    public static let port: UInt16 = 47120
    public static let probePort: UInt16 = 47121
    public static let headerSize = 16
    public static let video: UInt8 = 1
    public static let audio: UInt8 = 2
    public static let test: UInt8 = 3

    public static func packet(kind: UInt8, key: Bool, pts: Double, payload: Data) -> Data {
        var out = Data(capacity: headerSize + payload.count)
        out.append(kind)
        out.append(key ? 1 : 0)
        out.append(contentsOf: [0, 0, 0, 0, 0, 0])
        withUnsafeBytes(of: pts.bitPattern.littleEndian) { out.append(contentsOf: $0) }
        out.append(payload)
        return out
    }

    /// Converts VideoToolbox length-prefixed NAL units to the start-code form the TV expects.
    /// Returns nil if a length runs past the end, rather than sending a corrupt frame.
    public static func annexB(lengthPrefixed input: Data, lengthSize: Int = 4) -> Data? {
        let startCode: [UInt8] = [0, 0, 0, 1]
        var out = Data(capacity: input.count + 64)
        var offset = input.startIndex
        while offset < input.endIndex {
            guard offset + lengthSize <= input.endIndex else { return nil }
            var length = 0
            for byte in input[offset ..< offset + lengthSize] { length = length << 8 | Int(byte) }
            offset += lengthSize
            guard length > 0, offset + length <= input.endIndex else { return nil }
            out.append(contentsOf: startCode)
            out.append(input[offset ..< offset + length])
            offset += length
        }
        return out
    }

    /// VPS, SPS and PPS as start-code data. Sent before every key frame so the TV can join any time.
    public static func parameterSets(_ format: CMFormatDescription) -> Data {
        var out = Data()
        var count = 0
        CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, parameterSetIndex: 0, parameterSetPointerOut: nil,
                                                           parameterSetSizeOut: nil, parameterSetCountOut: &count,
                                                           nalUnitHeaderLengthOut: nil)
        for index in 0 ..< count {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            guard CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, parameterSetIndex: index,
                                                                     parameterSetPointerOut: &pointer, parameterSetSizeOut: &size,
                                                                     parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr,
                  let pointer else { continue }
            out.append(contentsOf: [0, 0, 0, 1])
            out.append(pointer, count: size)
        }
        return out
    }

    /// Float32 planar or interleaved stereo to interleaved 16-bit little-endian PCM.
    public static func pcm16(left: UnsafeBufferPointer<Float>, right: UnsafeBufferPointer<Float>, gain: Float = 1) -> Data {
        let frames = min(left.count, right.count)
        var out = Data(count: frames * 4)
        out.withUnsafeMutableBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for index in 0 ..< frames {
                samples[index * 2] = Int16(max(-1, min(1, left[index] * gain)) * 32767).littleEndian
                samples[index * 2 + 1] = Int16(max(-1, min(1, right[index] * gain)) * 32767).littleEndian
            }
        }
        return out
    }
}
