import FlutterMacOS

public extension Notification.Name {
    static let throwcastShowWindow = Notification.Name("throwcast.showWindow")
}

public class ThrowcastEnginePlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
    private let engine = Engine()
    private let menuBar = MenuBarController()
    private var sink: FlutterEventSink?

    public static func register(with registrar: FlutterPluginRegistrar) {
        let plugin = ThrowcastEnginePlugin()
        plugin.engine.emitLine = { [weak plugin] line in
            DispatchQueue.main.async { plugin?.sink?(line) }
        }
        NotificationCenter.default.addObserver(forName: .throwcastShowWindow, object: nil, queue: .main) { [weak plugin] _ in plugin?.menuBar.showWindow() }
        registrar.addMethodCallDelegate(plugin, channel: FlutterMethodChannel(name: "throwcast/commands", binaryMessenger: registrar.messenger))
        FlutterEventChannel(name: "throwcast/events", binaryMessenger: registrar.messenger).setStreamHandler(plugin)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch (call.method, call.arguments) {
        case let ("send", line as String):
            engine.receive(line)
        case let ("menuBar", enabled as Bool):
            menuBar.setEnabled(enabled)
        case let ("dockIcon", visible as Bool):
            menuBar.setDockIcon(visible)
        case let ("casting", casting as Bool):
            menuBar.setCasting(casting)
        default:
            result(FlutterMethodNotImplemented)
            return
        }
        result(nil)
    }

    public func onListen(withArguments _: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        sink = events
        return nil
    }

    public func onCancel(withArguments _: Any?) -> FlutterError? {
        sink = nil
        return nil
    }
}
