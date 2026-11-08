import Darwin
import Foundation

/// Finds Samsung TVs running the Throwcast app. A TV web app can't advertise itself, so this asks
/// Samsung's own service on port 8001, the same check the Mac app and the extension use.
enum TVFinder {
    struct Found: Hashable { let host: String, name: String }

    static let appID = "Thrwcast4K.Receiver"

    /// The TVs among `hosts` that answer as a Samsung TV and have Throwcast open. 48 asked at a time.
    static func find(in hosts: [String]) async -> [Found] {
        guard !hosts.isEmpty else { return [] }
        let session = URLSession(configuration: {
            let c = URLSessionConfiguration.ephemeral
            c.timeoutIntervalForRequest = 1.5
            c.waitsForConnectivity = false
            return c
        }())
        defer { session.invalidateAndCancel() }
        return await withTaskGroup(of: Found?.self) { group in
            var next = 0
            var found: [Found] = []
            func add() {
                guard next < hosts.count else { return }
                let host = hosts[next]
                next += 1
                group.addTask { await check(host, session) }
            }
            for _ in 0 ..< min(48, hosts.count) { add() }
            for await result in group {
                if let result { found.append(result) }
                add()
            }
            return found.sorted { $0.name < $1.name }
        }
    }

    private static func check(_ host: String, _ session: URLSession) async -> Found? {
        guard let info = URL(string: "http://\(host):8001/api/v2/"),
              let (data, _) = try? await session.data(from: info),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let device = json["device"] as? [String: Any],
              (device["type"] as? String)?.contains("TV") == true else { return nil }
        guard let app = URL(string: "http://\(host):8001/api/v2/applications/\(appID)"),
              let (appData, _) = try? await session.data(from: app),
              let state = try? JSONSerialization.jsonObject(with: appData) as? [String: Any],
              state["running"] as? Bool == true else { return nil }
        return Found(host: host, name: device["name"] as? String ?? json["name"] as? String ?? "Samsung TV")
    }

    /// Every other address in this iPhone's Wi-Fi /24.
    static func neighbours() -> [String] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        var own: String?
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard String(cString: entry.ifa_name) == "en0", let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }
            var text = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &text, socklen_t(text.count), nil, 0, NI_NUMERICHOST) == 0 {
                own = String(cString: text)
            }
        }
        guard let own else { return [] }
        let parts = own.split(separator: ".")
        guard parts.count == 4 else { return [] }
        let prefix = parts[0 ..< 3].joined(separator: ".")
        return (1 ... 254).map { "\(prefix).\($0)" }.filter { $0 != own }
    }
}
