import Cocoa

/// Optional menu bar icon that opens the same window as a panel under the icon,
/// so there is one set of settings and no second copy of the interface.
final class MenuBarController: NSObject {
    private static let panelSize = NSSize(width: 380, height: 720)
    private var item: NSStatusItem?
    private var isPanel = false
    private var savedFrame: NSRect?
    private var casting = false

    // Not `canBecomeMain`: that's false while hidden, which is exactly when this has to find it.
    private var window: NSWindow? { NSApp.windows.first { $0.contentView?.subviews.isEmpty == false && $0.styleMask.contains(.titled) } }

    func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: "throwcast.menuBar")
        if enabled, item == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.button?.target = self
            item.button?.action = #selector(clicked)
            item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
            self.item = item
            updateIcon()
        } else if !enabled, let item {
            NSStatusBar.system.removeStatusItem(item)
            self.item = nil
            leavePanel()
        }
    }

    func setDockIcon(_ visible: Bool) {
        NSApp.setActivationPolicy(visible ? .regular : .accessory)
    }

    func setCasting(_ casting: Bool) {
        self.casting = casting
        updateIcon()
    }

    private func updateIcon() {
        let image = NSImage(systemSymbolName: casting ? "tv.fill" : "tv", accessibilityDescription: "Throwcast")
        image?.isTemplate = true
        item?.button?.image = image
    }

    @objc private func clicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            menu.addItem(withTitle: "Quit Throwcast", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            item?.menu = menu
            item?.button?.performClick(nil)
            item?.menu = nil
            return
        }
        guard let window else { return }
        if isPanel, window.isVisible {
            window.orderOut(nil)
        } else {
            showPanel(window)
        }
    }

    private func showPanel(_ window: NSWindow) {
        guard let button = item?.button, let anchor = button.window?.convertToScreen(button.frame) else { return }
        if !isPanel { savedFrame = window.frame }
        isPanel = true
        window.setContentSize(Self.panelSize)
        let visible = button.window?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let x = min(anchor.midX - Self.panelSize.width / 2, visible.maxX - Self.panelSize.width - 8)
        window.setFrameTopLeftPoint(NSPoint(x: max(visible.minX + 8, x), y: anchor.minY - 6))
        window.level = .popUpMenu
        [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].forEach { window.standardWindowButton($0)?.isHidden = true }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        NotificationCenter.default.addObserver(self, selector: #selector(resigned), name: NSWindow.didResignKeyNotification, object: window)
    }

    @objc private func resigned() {
        guard isPanel else { return }
        window?.orderOut(nil)
    }

    private func leavePanel() {
        guard isPanel, let window else { return }
        isPanel = false
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: window)
        window.level = .normal
        [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].forEach { window.standardWindowButton($0)?.isHidden = false }
        if let savedFrame { window.setFrame(savedFrame, display: true) }
    }

    /// Clicking the Dock icon brings back the full window, whichever way it was last shown.
    func showWindow() {
        leavePanel()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
