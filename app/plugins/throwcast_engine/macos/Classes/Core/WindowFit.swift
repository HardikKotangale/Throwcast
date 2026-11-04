import AppKit
import ApplicationServices

/// Gives a cast window the TV's shape while it's on the TV, the way a cast browser tab gets one, and
/// puts it back afterwards. Moving another app's window needs the Accessibility permission; without
/// it the window is cast at its own shape, with bars.
final class WindowFit {
    private let element: AXUIElement
    private let original: CGRect

    private init(element: AXUIElement, original: CGRect) {
        self.element = element
        self.original = original
    }

    /// Asks macOS for Accessibility once, the first time a window is cast. Later casts don't nag.
    static func allowed() -> Bool {
        if AXIsProcessTrusted() { return true }
        let asked = "throwcast.askedAccessibility"
        if !UserDefaults.standard.bool(forKey: asked) {
            UserDefaults.standard.set(true, forKey: asked)
            AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
        }
        return false
    }

    /// Resizes the window at `frame` (screen points, top-left origin, as ScreenCaptureKit gives them)
    /// to the largest `aspect`-shaped rectangle that fits the usable part of its screen, centered.
    /// Nil if it can't: no permission, a full-screen window, or no matching window found.
    static func fit(pid: pid_t, frame: CGRect, aspect: CGFloat) -> WindowFit? {
        guard allowed(), let element = window(pid: pid, near: frame), !isFullScreen(element),
              let area = usableArea(containing: frame) else { return nil }
        let target = shaped(in: area, aspect: aspect)
        guard abs(target.width - frame.width) > 2 || abs(target.height - frame.height) > 2 else { return nil }
        set(element, to: target)
        return WindowFit(element: element, original: frame)
    }

    func restore() { Self.set(element, to: original) }

    /// The largest rectangle of this shape inside `area`, centered in it.
    static func shaped(in area: CGRect, aspect: CGFloat) -> CGRect {
        let width = min(area.width, area.height * aspect)
        let height = width / aspect
        return CGRect(x: area.midX - width / 2, y: area.midY - height / 2, width: width, height: height).integral
    }

    private static func window(pid: pid_t, near frame: CGRect) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return nil }
        func distance(_ window: AXUIElement) -> CGFloat {
            guard let other = self.frame(of: window) else { return .infinity }
            return abs(other.minX - frame.minX) + abs(other.minY - frame.minY) + abs(other.width - frame.width) + abs(other.height - frame.height)
        }
        guard let best = windows.min(by: { distance($0) < distance($1) }), distance(best) < 40 else { return nil }
        return best
    }

    private static func frame(of window: AXUIElement) -> CGRect? {
        var position: CFTypeRef?, size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &size) == .success else { return nil }
        var point = CGPoint.zero, extent = CGSize.zero
        AXValueGetValue(position as! AXValue, .cgPoint, &point)
        AXValueGetValue(size as! AXValue, .cgSize, &extent)
        return CGRect(origin: point, size: extent)
    }

    private static func isFullScreen(_ window: AXUIElement) -> Bool {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(window, "AXFullScreen" as CFString, &value) == .success && value as? Bool == true
    }

    /// The screen the window is mostly on, without the menu bar and Dock, in top-left coordinates.
    private static func usableArea(containing frame: CGRect) -> CGRect? {
        guard let primaryHeight = NSScreen.screens.first?.frame.height else { return nil }
        func topLeft(_ rect: CGRect) -> CGRect { CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height) }
        let screen = NSScreen.screens.max { a, b in
            topLeft(a.frame).intersection(frame).area < topLeft(b.frame).intersection(frame).area
        }
        return screen.map { topLeft($0.visibleFrame) }
    }

    /// Position, then size, then position again: a window that grows past the screen edge gets pulled back in.
    private static func set(_ window: AXUIElement, to rect: CGRect) {
        var origin = rect.origin, size = rect.size
        if let point = AXValueCreate(.cgPoint, &origin) { AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, point) }
        if let extent = AXValueCreate(.cgSize, &size) { AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, extent) }
        if let point = AXValueCreate(.cgPoint, &origin) { AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, point) }
    }
}

private extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}
