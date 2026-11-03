import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private let flutterViewController = FlutterViewController()

  override func awakeFromNib() {
    // Real window material sits behind Flutter, so macOS handles light, dark and Reduce Transparency.
    flutterViewController.backgroundColor = .clear
    let material = NSVisualEffectView()
    material.material = .underWindowBackground
    material.blendingMode = .behindWindow
    material.state = .followsWindowActiveState
    flutterViewController.view.frame = material.bounds
    flutterViewController.view.autoresizingMask = [.width, .height]
    material.addSubview(flutterViewController.view)
    contentView = material

    styleMask.insert(.fullSizeContentView)
    titlebarAppearsTransparent = true
    titleVisibility = .hidden
    title = "Throwcast"
    setContentSize(NSSize(width: 880, height: 720))
    minSize = NSSize(width: 380, height: 480)
    center()

    RegisterGeneratedPlugins(registry: flutterViewController)
    super.awakeFromNib()
  }
}
