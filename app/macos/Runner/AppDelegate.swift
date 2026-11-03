import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    // With the menu bar icon on, closing the window keeps Throwcast available from there.
    return !UserDefaults.standard.bool(forKey: "throwcast.menuBar")
  }

  override func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    NotificationCenter.default.post(name: Notification.Name("throwcast.showWindow"), object: nil)
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
