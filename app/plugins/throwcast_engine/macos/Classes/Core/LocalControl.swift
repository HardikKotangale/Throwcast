import Foundation
import Network

public struct ControlRequest {
    public let method: String
    public let path: String
    public let body: [String: Any]
}

/// Tiny HTTP server for the browser extension. It only listens on this Mac, and only answers
/// extensions, so a web page can't drive the TV. Stream links come from the page, so they're checked.
public final class LocalControl {
    public static let port: UInt16 = 47122
    private static let maxRequest = 64 * 1024

    public var handler: ((ControlRequest, @escaping (Int, [String: Any]) -> Void) -> Void)?
    private let queue = DispatchQueue(label: "throwcast.control")
    private var listener: NWListener?

    public init() {}

    public func start() throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: Self.port)!)
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] in self?.accept($0) }
        listener.start(queue: queue)
        self.listener = listener
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        read(connection, buffer: Data())
    }

    private func read(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, finished, error in
            guard let self, error == nil else { return connection.cancel() }
            let combined = buffer + (data ?? Data())
            if combined.count > Self.maxRequest { return self.reply(connection, 413, [:], origin: nil) }
            if let request = Self.parse(combined) {
                self.route(request, on: connection)
            } else if finished {
                connection.cancel()
            } else {
                self.read(connection, buffer: combined)
            }
        }
    }

    private struct Parsed {
        let method: String, path: String, origin: String?, body: Data
    }

    /// Nil until the whole request has arrived.
    private static func parse(_ data: Data) -> Parsed? {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let lines = String(decoding: data[data.startIndex ..< end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        let first = lines[0].split(separator: " ")
        guard first.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        guard data.distance(from: end.upperBound, to: data.endIndex) >= length else { return nil }
        let start = end.upperBound
        return Parsed(method: String(first[0]), path: String(first[1]), origin: headers["origin"], body: data[start ..< data.index(start, offsetBy: length)])
    }

    private static func isExtension(_ origin: String?) -> Bool {
        origin?.hasPrefix("chrome-extension://") == true
    }

    private func route(_ request: Parsed, on connection: NWConnection) {
        // Web pages always send their own Origin on POST, and can't forge it. A GET with no Origin
        // can't be read by a page, because the reply carries no CORS header for it.
        let readOnly = request.method == "GET" && request.origin == nil
        guard Self.isExtension(request.origin) || readOnly else { return reply(connection, 403, ["error": "Not allowed"], origin: nil) }
        if request.method == "OPTIONS" { return reply(connection, 204, [:], origin: request.origin) }
        let body = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any] ?? [:]
        DispatchQueue.main.async { [weak self] in
            self?.handler?(ControlRequest(method: request.method, path: request.path, body: body)) { status, json in
                self?.queue.async { self?.reply(connection, status, json, origin: request.origin) }
            }
        }
    }

    private func reply(_ connection: NWConnection, _ status: Int, _ json: [String: Any], origin: String?) {
        let body = status == 204 ? Data() : (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
        var head = "HTTP/1.1 \(status) \(status < 300 ? "OK" : "Error")\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
        if let origin {
            head += "Access-Control-Allow-Origin: \(origin)\r\nAccess-Control-Allow-Headers: Content-Type\r\nAccess-Control-Allow-Methods: GET, POST, OPTIONS\r\n"
        }
        connection.send(content: Data((head + "\r\n").utf8) + body, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in connection.cancel() })
    }
}
