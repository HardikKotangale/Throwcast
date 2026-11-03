import Foundation
import Network

/// Sends stream frames to the TV over UDP. Nothing waits for a lost packet: each frame is cut into
/// shards with one repair shard per group, so the TV rebuilds a single loss per group by itself and
/// skips a frame it can't, rather than holding everything up the way TCP does.
/// The layout matches `tv/wasm/udp_frames.h`.
final class MediaUDP {
    static let port: UInt16 = 47125
    static let shard = 1200
    static let group = 8
    static let magic: UInt8 = 0x54

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "throwcast.udp", qos: .userInteractive)
    private var frame: UInt32 = 0
    /// The last moments of the stream, so a shard the TV missed can be sent again. About half a second.
    private var recent: [UInt32: [Data]] = [:]
    private var recentOrder: [UInt32] = []
    private static let keep = 64
    private let resentLock = NSLock()
    private var resentCount = 0

    /// Shards sent again at the TV's request since the last call.
    func takeResent() -> Int { resentLock.withLock { defer { resentCount = 0 }; return resentCount } }

    init(host: String, port: UInt16) {
        let parameters = NWParameters.udp
        // Wi-Fi's video queue (WMM AC_VI) waits less than the default one when the air is busy.
        parameters.serviceClass = .interactiveVideo
        connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? NWEndpoint.Port(rawValue: Self.port)!, using: parameters)
        connection.start(queue: queue)
        listen()
    }

    /// The TV asks for shards it couldn't rebuild: 'N', a count, then frame (4 bytes) and shard (2) pairs.
    /// 0xFFFF as the shard means the whole frame never arrived.
    private func listen() {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data { self.resend(Array(data)) }
            if error == nil { self.listen() }
        }
    }

    private func resend(_ request: [UInt8]) {
        guard request.count >= 3, request[0] == UInt8(ascii: "N") else { return }
        let count = Int(request[1]) | Int(request[2]) << 8
        guard request.count >= 3 + count * 6 else { return }
        var resent = 0
        for item in 0 ..< count {
            let at = 3 + item * 6
            let frame = UInt32(request[at]) | UInt32(request[at + 1]) << 8 | UInt32(request[at + 2]) << 16 | UInt32(request[at + 3]) << 24
            let index = Int(request[at + 4]) | Int(request[at + 5]) << 8
            guard let datagrams = recent[frame] else { continue }
            let wanted = index == 0xFFFF ? datagrams : (index < datagrams.count ? [datagrams[index]] : [])
            for datagram in wanted { connection.send(content: datagram, completion: .idempotent) }
            resent += wanted.count
        }
        resentLock.withLock { resentCount += resent }
    }

    func stop() { connection.cancel() }

    /// Takes a `Wire.packet`. Frames are numbered in the order they're handed over.
    func send(_ packet: Data) {
        queue.async { [self] in
            frame &+= 1
            let datagrams = Self.datagrams(frame: frame, packet: packet)
            recent[frame] = datagrams
            recentOrder.append(frame)
            if recentOrder.count > Self.keep { recent[recentOrder.removeFirst()] = nil }
            // A big frame sent all at once can overflow Wi-Fi and lose several packets in a row, more than
            // repair shards can fix. Short pauses between bursts spread it over a few milliseconds.
            for (index, start) in stride(from: 0, to: datagrams.count, by: 32).enumerated() {
                if index > 0 { usleep(300) }
                connection.batch {
                    for datagram in datagrams[start ..< min(start + 32, datagrams.count)] { connection.send(content: datagram, completion: .idempotent) }
                }
            }
        }
    }

    static func datagrams(frame: UInt32, packet: Data) -> [Data] {
        let bytes = [UInt8](packet)
        let kind = bytes.first ?? 0
        let count = max(1, (bytes.count + shard - 1) / shard)
        let last = bytes.count - (count - 1) * shard
        func header(repair: Bool, index: Int) -> Data {
            var out = Data([magic, kind << 1 | (repair ? 1 : 0)])
            withUnsafeBytes(of: frame.littleEndian) { out.append(contentsOf: $0) }
            withUnsafeBytes(of: UInt16(index).littleEndian) { out.append(contentsOf: $0) }
            withUnsafeBytes(of: UInt16(count).littleEndian) { out.append(contentsOf: $0) }
            withUnsafeBytes(of: UInt16(last).littleEndian) { out.append(contentsOf: $0) }
            return out
        }
        var out: [Data] = []
        out.reserveCapacity(count + count / group + 1)
        for index in 0 ..< count {
            let start = index * shard
            var datagram = header(repair: false, index: index)
            datagram.append(contentsOf: bytes[start ..< start + (index == count - 1 ? last : shard)])
            out.append(datagram)
        }
        for groupIndex in 0 ..< (count + group - 1) / group {
            var parity = [UInt8](repeating: 0, count: shard)
            for index in groupIndex * group ..< min(count, (groupIndex + 1) * group) {
                let start = index * shard
                for offset in 0 ..< (index == count - 1 ? last : shard) { parity[offset] ^= bytes[start + offset] }
            }
            var datagram = header(repair: true, index: groupIndex)
            datagram.append(contentsOf: parity)
            out.append(datagram)
        }
        return out
    }
}
