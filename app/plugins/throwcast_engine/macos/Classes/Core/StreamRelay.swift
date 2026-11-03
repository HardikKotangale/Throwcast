import Foundation
import Network

/// Fetches a video with the browser's own headers and passes the bytes to the TV, untouched.
/// Sites often serve a link only to the browser that asked for it, and the TV has no login or
/// referrer of its own. Only the chosen TV may use this, and only with this playback's token.
public final class StreamRelay: NSObject, URLSessionDataDelegate {
    public static let port: UInt16 = 47123
    private static let highWater = 8 * 1024 * 1024
    private static let lowWater = 2 * 1024 * 1024
    private static let allowedHeaders: Set<String> = ["referer", "origin", "user-agent", "cookie", "authorization"]
    private static let sensitiveHeaders: Set<String> = ["cookie", "authorization"]

    /// The last refusal from a website, so the user sees the real reason.
    public private(set) var lastFailure: Int?

    private let allowedHost: String
    private let macAddress: String
    private let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    private let queue = DispatchQueue(label: "throwcast.relay")
    private var listener: NWListener?
    private var headersByHost: [String: [String: String]] = [:]
    private var transfers: [Int: Transfer] = [:]
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 20
        let delegateQueue = OperationQueue()
        delegateQueue.underlyingQueue = queue
        return URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
    }()

    private final class Transfer {
        let connection: NWConnection
        var isManifest = false
        var manifest = Data()
        var finalURL: URL?
        var inflight = 0
        var headSent = false

        init(_ connection: NWConnection) { self.connection = connection }
    }

    public init?(allowedHost: String) {
        guard let address = TV.localAddress() else { return nil }
        self.allowedHost = allowedHost
        macAddress = address
        super.init()
    }

    public func start() throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: Self.port)!)
        listener.newConnectionHandler = { [weak self] in self?.accept($0) }
        listener.start(queue: queue)
        self.listener = listener
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        session.invalidateAndCancel()
    }

    /// Remembers what the browser sent for this site and returns the address the TV should use.
    public func register(url: String, headers: [String: String]) -> String? {
        guard let parsed = URL(string: url), let host = parsed.host else { return nil }
        let filtered = headers.filter { Self.allowedHeaders.contains($0.key.lowercased()) }
        queue.sync { headersByHost[host.lowercased()] = filtered }
        return relayed(parsed.absoluteString)
    }

    /// The upstream host stays in the path, so relative links in a playlist keep resolving through here.
    func relayed(_ link: String) -> String? {
        // Percent-encoded forms stay exact: signed links break if a single character changes.
        guard let parts = URLComponents(string: link), let scheme = parts.scheme, let authority = parts.percentEncodedHost else { return nil }
        let port = parts.port.map { ":\($0)" } ?? ""
        let query = parts.percentEncodedQuery.map { "?\($0)" } ?? ""
        return "http://\(macAddress):\(Self.port)/\(token)/\(scheme)/\(authority)\(port)\(parts.percentEncodedPath)\(query)"
    }

    func upstream(path: String) -> URL? {
        let parts = path.split(separator: "/", maxSplits: 3, omittingEmptySubsequences: true)
        guard parts.count == 4, parts[0] == token, ["http", "https"].contains(parts[1]) else { return nil }
        return URL(string: "\(parts[1])://\(parts[2])/\(parts[3])")
    }

    private func accept(_ connection: NWConnection) {
        guard case let .hostPort(host, _) = connection.endpoint,
              "\(host)".split(separator: "%")[0].replacingOccurrences(of: "::ffff:", with: "") == allowedHost else {
            return connection.cancel()
        }
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, _, _ in
            guard let self, let data, let text = String(data: data, encoding: .isoLatin1) else { return connection.cancel() }
            self.serve(text, on: connection)
        }
    }

    private func serve(_ request: String, on connection: NWConnection) {
        let lines = request.components(separatedBy: "\r\n")
        let first = lines[0].split(separator: " ")
        guard first.count >= 2, let url = upstream(path: String(first[1])) else { return refuse(connection, 403) }
        var outgoing = URLRequest(url: url)
        apply(headers(for: url), to: &outgoing)
        if let range = lines.first(where: { $0.lowercased().hasPrefix("range:") }) {
            outgoing.setValue(range.dropFirst(6).trimmingCharacters(in: .whitespaces), forHTTPHeaderField: "Range")
        }
        let task = session.dataTask(with: outgoing)
        transfers[task.taskIdentifier] = Transfer(connection)
        connection.stateUpdateHandler = { [weak task] state in
            if case .cancelled = state { task?.cancel() }
            if case .failed = state { task?.cancel() }
        }
        task.resume()
    }

    /// Logins only go to the site they came from. A separate video CDN gets the referrer but no cookies.
    private func headers(for url: URL) -> [String: String] {
        let host = url.host?.lowercased() ?? ""
        if let exact = headersByHost[host] { return exact }
        return (headersByHost.values.first ?? [:]).filter { !Self.sensitiveHeaders.contains($0.key.lowercased()) }
    }

    private func apply(_ headers: [String: String], to request: inout URLRequest) {
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
    }

    private func refuse(_ connection: NWConnection, _ status: Int) {
        let head = "HTTP/1.1 \(status) Error\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in connection.cancel() })
    }

    private func head(_ response: HTTPURLResponse, length: Int?) -> Data {
        var text = "HTTP/1.1 \(response.statusCode) OK\r\nConnection: close\r\nAccess-Control-Allow-Origin: *\r\n"
        for name in ["Content-Type", "Content-Range", "Accept-Ranges"] {
            if let value = response.value(forHTTPHeaderField: name) { text += "\(name): \(value)\r\n" }
        }
        if let length {
            text += "Content-Length: \(length)\r\n"
        } else if let value = response.value(forHTTPHeaderField: "Content-Length") {
            text += "Content-Length: \(value)\r\n"
        }
        return Data((text + "\r\n").utf8)
    }

    private static func isManifest(_ response: HTTPURLResponse) -> Bool {
        let type = response.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        let path = response.url?.path.lowercased() ?? ""
        return type.contains("mpegurl") || type.contains("dash+xml") || path.hasSuffix(".m3u8") || path.hasSuffix(".mpd")
    }

    public func urlSession(_: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                           completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let transfer = transfers[dataTask.taskIdentifier], let http = response as? HTTPURLResponse else {
            return completionHandler(.cancel)
        }
        if http.statusCode >= 400 { lastFailure = http.statusCode }
        transfer.finalURL = http.url
        transfer.isManifest = http.statusCode < 300 && Self.isManifest(http)
        if !transfer.isManifest {
            transfer.headSent = true
            transfer.connection.send(content: head(http, length: nil), completion: .idempotent)
        }
        completionHandler(.allow)
    }

    public func urlSession(_: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let transfer = transfers[dataTask.taskIdentifier] else { return }
        if transfer.isManifest {
            transfer.manifest.append(data)
            return
        }
        transfer.inflight += data.count
        // Holds the download back to the TV's pace, so a long film can't fill the Mac's memory.
        if transfer.inflight > Self.highWater { dataTask.suspend() }
        transfer.connection.send(content: data, completion: .contentProcessed { [weak dataTask, weak transfer] _ in
            guard let transfer else { return }
            transfer.inflight -= data.count
            if transfer.inflight < Self.lowWater { dataTask?.resume() }
        })
    }

    public func urlSession(_: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let transfer = transfers.removeValue(forKey: task.taskIdentifier) else { return }
        if error != nil, !transfer.headSent, !transfer.isManifest { return refuse(transfer.connection, 502) }
        if transfer.isManifest, let http = task.response as? HTTPURLResponse {
            guard let text = String(data: transfer.manifest, encoding: .utf8) else { return refuse(transfer.connection, 502) }
            let body = Data(rewrite(text, base: transfer.finalURL).utf8)
            transfer.connection.send(content: head(http, length: body.count) + body, contentContext: .finalMessage, isComplete: true,
                                     completion: .contentProcessed { [connection = transfer.connection] _ in connection.cancel() })
            return
        }
        transfer.connection.send(content: nil, contentContext: .finalMessage, isComplete: true,
                                 completion: .contentProcessed { [connection = transfer.connection] _ in connection.cancel() })
    }

    /// Points every link in a playlist back through the relay, so the TV never contacts the site itself.
    func rewrite(_ text: String, base: URL?) -> String {
        if text.hasPrefix("#EXTM3U") {
            return text.components(separatedBy: "\n").map { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty { return line }
                if trimmed.hasPrefix("#") { return rewriteAttributes(line, base: base) }
                return absolute(trimmed, base: base) ?? line
            }.joined(separator: "\n")
        }
        guard let regex = try? NSRegularExpression(pattern: #"https?://[^\s"'<>]+"#) else { return text }
        var output = text
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let range = Range(match.range, in: text), let link = relayed(String(text[range])),
                  let target = Range(match.range, in: output) else { continue }
            output.replaceSubrange(target, with: link)
        }
        return output
    }

    private func absolute(_ link: String, base: URL?) -> String? {
        URL(string: link, relativeTo: base).flatMap { relayed($0.absoluteString) }
    }

    private func rewriteAttributes(_ line: String, base: URL?) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"URI="([^"]+)""#) else { return line }
        var output = line
        for match in regex.matches(in: line, range: NSRange(line.startIndex..., in: line)).reversed() {
            guard let range = Range(match.range(at: 1), in: line), let link = absolute(String(line[range]), base: base),
                  let target = Range(match.range(at: 1), in: output) else { continue }
            output.replaceSubrange(target, with: link)
        }
        return output
    }
}
