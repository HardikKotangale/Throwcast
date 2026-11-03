import CoreGraphics
#if canImport(CVirtualDisplay)
import CVirtualDisplay
#endif
import Foundation

/// A display that exists only in software, at the TV's exact size.
/// macOS removes it automatically when this object or the app goes away, so a crash can't strand the user.
public final class VirtualDisplay {
    private let display: CGVirtualDisplay
    public var id: CGDirectDisplayID { display.displayID }

    public init?(width: Int, height: Int, fps: Int, name: String) {
        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.setDispatchQueue(.main)
        descriptor.name = name
        descriptor.maxPixelsWide = UInt32(width)
        descriptor.maxPixelsHigh = UInt32(height)
        // macOS silently keeps a display offline if its size implies an implausible pixel density,
        // and a reused serial can inherit a stale arrangement, so size follows points and serial is fresh.
        let hiDPI = width >= 2560
        let scale = hiDPI ? 2 : 1
        descriptor.sizeInMillimeters = CGSize(width: Double(width / scale) * 0.3125, height: Double(height / scale) * 0.3125)
        descriptor.vendorID = 0x7443
        descriptor.productID = 0x4B34
        descriptor.serialNum = UInt32.random(in: 1 ... .max)
        // Display P3, so wide-color windows are not clipped before capture.
        descriptor.redPrimary = CGPoint(x: 0.680, y: 0.320)
        descriptor.greenPrimary = CGPoint(x: 0.265, y: 0.690)
        descriptor.bluePrimary = CGPoint(x: 0.150, y: 0.060)
        descriptor.whitePoint = CGPoint(x: 0.3127, y: 0.3290)
        guard let display = CGVirtualDisplay(descriptor: descriptor) else { return nil }
        self.display = display

        // At 1440p and up, run 2x so the desktop stays a usable size and text is rendered at full sharpness.
        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = hiDPI ? 1 : 0
        settings.modes = [CGVirtualDisplayMode(width: UInt(width / scale), height: UInt(height / scale), refreshRate: Double(fps))]
        guard display.apply(settings) else { return nil }
    }

    /// Makes `id` show the same desktop as the main display, rendered at this display's resolution.
    public func mirrorMainDisplay() -> Bool {
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else { return false }
        guard CGConfigureDisplayMirrorOfDisplay(config, CGMainDisplayID(), id) == .success else {
            CGCancelDisplayConfiguration(config)
            return false
        }
        return CGCompleteDisplayConfiguration(config, .forSession) == .success
    }
}
