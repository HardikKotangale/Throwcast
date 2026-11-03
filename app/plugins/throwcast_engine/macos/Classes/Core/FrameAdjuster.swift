import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo
import Foundation
import Metal

public struct Adjustments: Equatable, Sendable {
    public var brightness = 0.0 // -0.25 ... 0.25
    public var contrast = 1.0 // 0.75 ... 1.25
    public var saturation = 1.0 // 0 ... 2
    public var warmth = 0.0 // -1 ... 1
    public var gamma = 1.0 // 0.8 ... 1.2

    public init(brightness: Double = 0, contrast: Double = 1, saturation: Double = 1, warmth: Double = 0, gamma: Double = 1) {
        self.brightness = min(0.25, max(-0.25, brightness))
        self.contrast = min(1.25, max(0.75, contrast))
        self.saturation = min(2, max(0, saturation))
        self.warmth = min(1, max(-1, warmth))
        self.gamma = min(1.2, max(0.8, gamma))
    }

    public var isNeutral: Bool { self == Adjustments() }
}

/// Applies picture adjustments on the GPU between capture and the encoder. Frames skip this
/// entirely when everything is neutral, so unused controls cost nothing.
/// Color management is off on purpose: values stay in the color the stream is already tagged with.
final class FrameAdjuster {
    private let context: CIContext
    private var pool: CVPixelBufferPool?

    init?() {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        context = CIContext(mtlDevice: device, options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull(), .cacheIntermediates: false])
    }

    func apply(_ values: Adjustments, to pixels: CVPixelBuffer) -> CVPixelBuffer? {
        let width = CVPixelBufferGetWidth(pixels), height = CVPixelBufferGetHeight(pixels)
        let format = CVPixelBufferGetPixelFormatType(pixels)
        if pool == nil {
            let attributes: [CFString: Any] = [kCVPixelBufferWidthKey: width, kCVPixelBufferHeightKey: height,
                                               kCVPixelBufferPixelFormatTypeKey: format, kCVPixelBufferIOSurfacePropertiesKey: [:]]
            CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
        }
        var output: CVPixelBuffer?
        guard let pool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &output) == kCVReturnSuccess, let output else { return nil }
        CVBufferPropagateAttachments(pixels, output)

        var image = CIImage(cvPixelBuffer: pixels, options: [.colorSpace: NSNull()])
        let controls = CIFilter.colorControls()
        controls.inputImage = image
        controls.brightness = Float(values.brightness)
        controls.contrast = Float(values.contrast)
        controls.saturation = Float(values.saturation)
        image = controls.outputImage ?? image
        if values.gamma != 1 {
            let gamma = CIFilter.gammaAdjust()
            gamma.inputImage = image
            gamma.power = Float(values.gamma)
            image = gamma.outputImage ?? image
        }
        if values.warmth != 0 {
            // Warmer means telling the filter the white was cooler than it looks.
            let temperature = CIFilter.temperatureAndTint()
            temperature.inputImage = image
            temperature.neutral = CIVector(x: 6500 + CGFloat(values.warmth) * 1800, y: 0)
            temperature.targetNeutral = CIVector(x: 6500, y: 0)
            image = temperature.outputImage ?? image
        }
        context.render(image, to: output, bounds: CGRect(x: 0, y: 0, width: width, height: height), colorSpace: nil)
        return output
    }
}
