import AppKit
import Foundation

/// What's playing in a browser, read by the Mac app itself, with no extension: during a cast it asks the
/// browser you used last, through AppleScript, to run a few lines in its showing tab. The same reading and
/// controls as the extension's content script (extension/content.js), so YouTube live works the same way.
///
/// Each browser needs one switch, once: Chrome, Edge, Brave and Arc have View → Developer → Allow JavaScript
/// from Apple Events, Safari has Develop → Allow JavaScript from Apple Events. macOS also asks once whether
/// Throwcast may control the browser.
public final class BrowserPlayback {
    enum Kind { case chromium, arc, safari }
    struct Browser { let bundleID: String, name: String, kind: Kind }

    static let browsers = [
        Browser(bundleID: "com.google.Chrome", name: "Google Chrome", kind: .chromium),
        Browser(bundleID: "com.brave.Browser", name: "Brave Browser", kind: .chromium),
        Browser(bundleID: "com.microsoft.edgemac", name: "Microsoft Edge", kind: .chromium),
        Browser(bundleID: "company.thebrowser.Browser", name: "Arc", kind: .arc),
        Browser(bundleID: "com.apple.Safari", name: "Safari", kind: .safari),
    ]

    /// A report in the extension's tabState shape (any queue).
    public var onState: (([String: Any]) -> Void)?
    /// Why nothing can be read, such as the browser's switch being off (main queue), once per problem.
    public var onProblem: ((String) -> Void)?

    private let queue = DispatchQueue(label: "throwcast.browser")
    private var timer: DispatchSourceTimer?
    private var lastBrowser: String?
    private var observer: NSObjectProtocol?
    private var lastProblem: String?

    public init() {
        // The browser you were in last is the one you're watching, even while Throwcast is in front.
        lastBrowser = NSWorkspace.shared.frontmostApplication?.bundleIdentifier.flatMap { id in Self.browsers.contains { $0.bundleID == id } ? id : nil }
        observer = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let id = app.bundleIdentifier, Self.browsers.contains(where: { $0.bundleID == id }) else { return }
            self?.queue.async { self?.lastBrowser = id }
        }
    }

    deinit {
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }

    /// Reads twice a second until stopped.
    public func start() {
        queue.async { [weak self] in
            guard let self, self.timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
            timer.setEventHandler { [weak self] in self?.read() }
            timer.resume()
            self.timer = timer
        }
    }

    public func stop() {
        queue.async { [weak self] in
            self?.timer?.cancel()
            self?.timer = nil
        }
    }

    /// A control from the app or the phone: an action (play, pause, seek, jump, live, next, previous) or a volume.
    public func control(_ command: [String: Any]) {
        let call: String
        if let volume = command["volume"] as? Double {
            call = "actions.volume(\(min(1, max(0, volume))))"
        } else if let action = command["action"] as? String, ["play", "pause", "seek", "jump", "live", "next", "previous"].contains(action) {
            let seconds = (command["seconds"] as? Double).flatMap { $0.isFinite ? $0 : nil } ?? 0
            call = "actions['\(action)'](\(seconds))"
        } else {
            return
        }
        queue.async { [weak self] in _ = self?.run(Self.controls + "return \(call);})()") }
    }

    private func current() -> Browser? {
        let running = NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
        if let id = lastBrowser, running.contains(id) { return Self.browsers.first { $0.bundleID == id } }
        return Self.browsers.first { running.contains($0.bundleID) }
    }

    private func read() {
        guard let reply = run(Self.reader), !reply.isEmpty,
              let state = try? JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any] else { return }
        onState?(state)
    }

    /// Runs `js` in the showing tab of the browser's front window. Nil when it can't.
    private func run(_ js: String) -> String? {
        guard let browser = current() else { return nil }
        let code = js.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let body = switch browser.kind {
        case .chromium: "execute active tab of front window javascript \"\(code)\""
        case .arc: "tell front window to tell active tab to execute javascript \"\(code)\""
        case .safari: "do JavaScript \"\(code)\" in current tab of front window"
        }
        // A busy browser mustn't hold the cast up: two seconds at most.
        let source = "with timeout of 2 seconds\ntell application id \"\(browser.bundleID)\"\nif (count of windows) is 0 then return \"\"\n\(body)\nend tell\nend timeout"
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            let number = error[NSAppleScript.errorNumber] as? Int ?? 0
            let message = error[NSAppleScript.errorMessage] as? String ?? ""
            // -1743: not allowed to control the browser. Chrome's switch off says "JavaScript through AppleScript is turned off".
            let problem: String? = number == -1743
                ? "Allow Throwcast to control \(browser.name) in System Settings → Privacy & Security → Automation."
                : message.localizedCaseInsensitiveContains("JavaScript") ? "Turn on Allow JavaScript from Apple Events in \(browser.name) (\(browser.kind == .safari ? "Develop" : "View → Developer") menu) to control videos from Throwcast."
                : nil
            if let problem, problem != lastProblem {
                lastProblem = problem
                DispatchQueue.main.async { [weak self] in self?.onProblem?(problem) }
            }
            return nil
        }
        lastProblem = nil
        return result?.stringValue
    }

    /// The biggest video, favouring one that's playing, as the extension picks it. YouTube live reads from
    /// YouTube's own player, which this script can reach because it runs in the page itself.
    static let reader = """
    (() => {
      const area = (v) => { const r = v.getBoundingClientRect(); return r.width * r.height; };
      const video = [...document.querySelectorAll('video')].sort((a, b) => area(b) * (b.paused ? 1 : 3) - area(a) * (a.paused ? 1 : 3))[0];
      if (!video || !area(video)) return '';
      // AppleScript's script can't reach YouTube's player functions, so live comes from the page: YouTube marks
      // its time display ytp-live, and its LIVE badge says when you're at the live edge. Other sites' live video
      // has no fixed length. The seekable range is how far back it can go.
      const badge = document.querySelector('.ytp-live-badge');
      const live = !Number.isFinite(video.duration) || !!document.querySelector('.ytp-time-display.ytp-live');
      let time = video.currentTime || 0, behind = 0, start = -1;
      if (live && video.seekable.length) {
        const end = video.seekable.end(video.seekable.length - 1), first = video.seekable.start(0);
        behind = badge && badge.classList.contains('ytp-live-badge-is-livehead') ? 0 : Math.max(0, end - time);
        if (end - first > 60 && end - first < 43200) start = first;
      }
      return JSON.stringify({ title: document.title, time, duration: live || !Number.isFinite(video.duration) ? 0 : video.duration,
        paused: video.paused, volume: video.muted ? 0 : video.volume, live, behind, start });
    })()
    """

    static let controls = """
    (() => {
      const area = (v) => { const r = v.getBoundingClientRect(); return r.width * r.height; };
      const video = [...document.querySelectorAll('video')].sort((a, b) => area(b) * (b.paused ? 1 : 3) - area(a) * (a.paused ? 1 : 3))[0];
      if (!video) return '';
      const edge = () => (video.seekable.length ? video.seekable.end(video.seekable.length - 1) : video.currentTime);
      const click = (selector) => { const b = document.querySelector(selector); if (b && !b.disabled && b.getAttribute('aria-disabled') !== 'true') { b.click(); return true; } return false; };
      const play = () => video.play().catch(() => {});
      const pause = () => video.pause();
      // A live stream's times are inside its seekable range, so seeking there works the same as in a video.
      const seek = (s) => { video.currentTime = Math.min(s, edge()); };
      const jump = (s) => { video.currentTime = Math.min(video.currentTime + s, edge()); };
      const volume = (v) => { video.volume = v; video.muted = v === 0; };
      const next = () => click('.ytp-next-button, [data-uia="control-next"], [data-testid*="next" i], button[aria-label^="Next" i], button[title^="Next" i]')
        || document.dispatchEvent(new KeyboardEvent('keydown', { key: 'N', code: 'KeyN', shiftKey: true, bubbles: true }));
      const previous = () => click('.ytp-prev-button, [data-uia="control-previous"], [data-testid*="previous" i], button[aria-label^="Previous" i], button[title^="Previous" i]')
        || (video.currentTime = 0);
      const live_ = () => click('.ytp-live-badge') || (video.currentTime = edge() - 1);
      const actions = { play, pause, seek, jump, volume, next, previous, live: live_ };
    """
}
