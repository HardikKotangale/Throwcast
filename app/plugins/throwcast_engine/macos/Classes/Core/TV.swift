import Foundation

public struct TV: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let model: String
    public let host: String
    public let width: Int
    public let height: Int

    public var resolutionLabel: String {
        switch height {
        case 4320...: "8K"
        case 2160...: "4K"
        case 1440...: "1440p"
        default: "\(height)p"
        }
    }

    /// Parses Samsung's `/api/v2/` answer. Unknown resolutions fall back to 4K and the manual picker.
    public init?(samsungJSON data: Data) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let device = root["device"] as? [String: Any], let host = device["ip"] as? String else { return nil }
        let size = (device["resolution"] as? String ?? "").split(separator: "x").compactMap { Int($0) }
        id = device["id"] as? String ?? host
        name = device["name"] as? String ?? "Samsung TV"
        model = device["modelName"] as? String ?? ""
        self.host = host
        width = size.count == 2 ? size[0] : 3840
        height = size.count == 2 ? size[1] : 2160
    }

    public static func fetch(host: String, timeout: TimeInterval = 3) async -> TV? {
        guard let url = URL(string: "http://\(host):8001/api/v2/") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return nil }
        return TV(samsungJSON: data)
    }

    /// Asks every address on this Mac's Wi-Fi or Ethernet for a Samsung TV. Slower than Bonjour by
    /// about a second, but it still works on networks that drop multicast.
    // ponytail: /24 only; larger subnets rely on Bonjour or a typed address.
    public static func scanLocalNetwork() async -> [TV] {
        let hosts = Self.neighbours()
        return await withTaskGroup(of: TV?.self) { group in
            for host in hosts { group.addTask { await TV.fetch(host: host, timeout: 1) } }
            var found: [TV] = []
            for await tv in group { if let tv { found.append(tv) } }
            return found
        }
    }

    static func neighbours() -> [String] {
        localAddresses().flatMap { address -> [String] in
            let parts = address.split(separator: ".")
            return (1 ... 254).map { "\(parts[0]).\(parts[1]).\(parts[2]).\($0)" }.filter { $0 != address }
        }
    }

    /// This Mac's address on the network the TV is on.
    public static func localAddress() -> String? { localAddresses().first }

    private static func localAddresses() -> [String] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return [] }
        defer { freeifaddrs(head) }
        var addresses: [String] = []
        var cursor = head
        while let entry = cursor?.pointee {
            cursor = entry.ifa_next
            guard let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  String(cString: entry.ifa_name).hasPrefix("en") else { continue }
            var text = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &text, socklen_t(text.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let numeric = String(cString: text)
            if numeric.split(separator: ".").count == 4 { addresses.append(numeric) }
        }
        return addresses
    }

    public enum Launch: Sendable {
        case running
        /// The TV answered 404: the app really isn't on it.
        case missing
        /// Asked, but couldn't confirm it started. The TV may still open it, or the user can.
        case unconfirmed
    }

    /// Opens the receiver. The TV can answer 200 without starting it, so this checks and retries.
    /// Every request has a short timeout, so the whole check ends within about 40 seconds.
    @discardableResult
    public func launchReceiver() async -> Launch {
        guard let url = URL(string: "http://\(host):8001/api/v2/applications/Thrwcast4K.Receiver") else { return .unconfirmed }
        func request(_ method: String) -> URLRequest {
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.timeoutInterval = 4
            return request
        }
        // A 404 means the app isn't on this TV, so there's nothing to retry.
        if let (_, response) = try? await URLSession.shared.data(for: request("GET")), (response as? HTTPURLResponse)?.statusCode == 404 { return .missing }
        for _ in 0 ..< 4 {
            _ = try? await URLSession.shared.data(for: request("POST"))
            try? await Task.sleep(for: .milliseconds(1500))
            if let (data, _) = try? await URLSession.shared.data(for: request("GET")),
               let status = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               status["running"] as? Bool == true { return .running }
        }
        return .unconfirmed
    }
}
