// The WebSocket protocol (RFC 6455), server side, for the browser extension to stream to this TV without
// the Mac app. Plain C++ with no TV calls, so it's tested on the Mac too.
//
// A browser can only open a WebSocket, not a plain connection, and a TV web app can't accept one in
// JavaScript, so the player's C++ takes it: it answers the opening HTTP request, then unwraps each message.
#pragma once

#include <cstdint>
#include <cctype>
#include <cstring>
#include <string>
#include <vector>

namespace throwcast {
namespace ws {

// SHA-1, only for the handshake's Sec-WebSocket-Accept. Not for anything secret.
inline std::string Sha1(const std::string& input) {
  uint32_t h[5] = {0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0};
  std::string m = input;
  const uint64_t bits = uint64_t(input.size()) * 8;
  m += char(0x80);
  while (m.size() % 64 != 56) m += char(0);
  for (int i = 7; i >= 0; --i) m += char((bits >> (i * 8)) & 0xFF);
  auto rotl = [](uint32_t x, int n) { return (x << n) | (x >> (32 - n)); };
  for (size_t chunk = 0; chunk < m.size(); chunk += 64) {
    uint32_t w[80];
    for (int i = 0; i < 16; ++i)
      w[i] = uint32_t(uint8_t(m[chunk + i * 4])) << 24 | uint32_t(uint8_t(m[chunk + i * 4 + 1])) << 16 |
             uint32_t(uint8_t(m[chunk + i * 4 + 2])) << 8 | uint32_t(uint8_t(m[chunk + i * 4 + 3]));
    for (int i = 16; i < 80; ++i) w[i] = rotl(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1);
    uint32_t a = h[0], b = h[1], c = h[2], d = h[3], e = h[4];
    for (int i = 0; i < 80; ++i) {
      uint32_t f, k;
      if (i < 20) f = (b & c) | (~b & d), k = 0x5A827999;
      else if (i < 40) f = b ^ c ^ d, k = 0x6ED9EBA1;
      else if (i < 60) f = (b & c) | (b & d) | (c & d), k = 0x8F1BBCDC;
      else f = b ^ c ^ d, k = 0xCA62C1D6;
      const uint32_t t = rotl(a, 5) + f + e + k + w[i];
      e = d, d = c, c = rotl(b, 30), b = a, a = t;
    }
    h[0] += a, h[1] += b, h[2] += c, h[3] += d, h[4] += e;
  }
  std::string out;
  for (uint32_t v : h)
    for (int i = 3; i >= 0; --i) out += char((v >> (i * 8)) & 0xFF);
  return out;
}

inline std::string Base64(const std::string& input) {
  static const char* table = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  std::string out;
  for (size_t i = 0; i < input.size(); i += 3) {
    const uint32_t n = uint32_t(uint8_t(input[i])) << 16 | (i + 1 < input.size() ? uint32_t(uint8_t(input[i + 1])) << 8 : 0) |
                       (i + 2 < input.size() ? uint32_t(uint8_t(input[i + 2])) : 0);
    out += table[(n >> 18) & 63];
    out += table[(n >> 12) & 63];
    out += i + 1 < input.size() ? table[(n >> 6) & 63] : '=';
    out += i + 2 < input.size() ? table[n & 63] : '=';
  }
  return out;
}

// The reply to a browser's opening request, or empty if it isn't a WebSocket request (yet).
// `request` must hold everything up to the blank line that ends the HTTP headers.
inline std::string HandshakeReply(const std::string& request) {
  std::string lower = request;
  for (char& c : lower) c = char(std::tolower(uint8_t(c)));
  const std::string name = "sec-websocket-key:";
  const size_t at = lower.find(name);
  if (at == std::string::npos) return "";
  size_t start = at + name.size();
  while (start < request.size() && request[start] == ' ') ++start;
  const size_t end = request.find("\r\n", start);
  if (end == std::string::npos) return "";
  const std::string key = request.substr(start, end - start);
  const std::string accept = Base64(Sha1(key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"));
  return "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: " + accept + "\r\n\r\n";
}

enum Opcode : uint8_t { kContinuation = 0, kText = 1, kBinary = 2, kClose = 8, kPing = 9, kPong = 10 };

struct Message {
  uint8_t opcode;
  std::vector<uint8_t> data;
};

// Unwraps the browser's frames as bytes arrive, in any split. Browsers mask every frame they send,
// and may split a message into a first frame and continuations.
class Reader {
 public:
  // Takes bytes, and returns true while the stream is well formed. Finished messages go to `out`.
  bool Add(const uint8_t* bytes, size_t size, std::vector<Message>& out) {
    pending_.insert(pending_.end(), bytes, bytes + size);
    size_t used = 0;
    for (;;) {
      const size_t have = pending_.size() - used;
      if (have < 2) break;
      const uint8_t* p = pending_.data() + used;
      const bool fin = p[0] & 0x80;
      const uint8_t opcode = p[0] & 0x0F;
      const bool masked = p[1] & 0x80;
      uint64_t length = p[1] & 0x7F;
      size_t header = 2;
      if (length == 126) {
        if (have < 4) break;
        length = uint64_t(p[2]) << 8 | p[3];
        header = 4;
      } else if (length == 127) {
        if (have < 10) break;
        length = 0;
        for (int i = 0; i < 8; ++i) length = length << 8 | p[2 + i];
        header = 10;
      }
      if (!masked || length > kMaxMessage) return false;  // a browser always masks; anything else isn't one
      if (have < header + 4 + length) break;
      const uint8_t* mask = p + header;
      const uint8_t* body = mask + 4;
      std::vector<uint8_t>& into = opcode >= 8 ? control_ : partial_;
      if (opcode >= 8) control_.clear();
      if (opcode == kText || opcode == kBinary) {
        partial_.clear();
        partialOpcode_ = opcode;
      }
      const size_t base = into.size();
      into.resize(base + size_t(length));
      for (size_t i = 0; i < length; ++i) into[base + i] = body[i] ^ mask[i & 3];
      if (into.size() > kMaxMessage) return false;
      used += header + 4 + size_t(length);
      if (opcode >= 8) out.push_back({opcode, control_});
      else if (fin) {
        out.push_back({partialOpcode_, std::move(partial_)});
        partial_.clear();
      }
    }
    pending_.erase(pending_.begin(), pending_.begin() + used);
    return true;
  }

  // A 4K key frame is a few megabytes at most. Anything past this is a broken or hostile sender.
  static constexpr size_t kMaxMessage = 16 * 1024 * 1024;

 private:
  std::vector<uint8_t> pending_, partial_, control_;
  uint8_t partialOpcode_ = kBinary;
};

// One whole message from this server. Servers never mask.
inline std::vector<uint8_t> Frame(uint8_t opcode, const uint8_t* data, size_t size) {
  std::vector<uint8_t> out{uint8_t(0x80 | opcode)};
  if (size < 126) out.push_back(uint8_t(size));
  else if (size < 65536) out.insert(out.end(), {126, uint8_t(size >> 8), uint8_t(size)});
  else {
    out.push_back(127);
    for (int i = 7; i >= 0; --i) out.push_back(uint8_t(uint64_t(size) >> (i * 8)));
  }
  out.insert(out.end(), data, data + size);
  return out;
}

}  // namespace ws
}  // namespace throwcast
