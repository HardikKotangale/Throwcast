// clang++ -std=c++17 tv/wasm/websocket_test.cpp -o /tmp/ws && /tmp/ws
#include "websocket.h"

#include <cassert>
#include <cstdio>

using namespace throwcast::ws;

// A frame the way a browser sends it: masked.
static std::vector<uint8_t> Masked(uint8_t first, const std::string& body) {
  std::vector<uint8_t> out{first};
  const uint8_t mask[4] = {0x12, 0x34, 0x56, 0x78};
  if (body.size() < 126) out.push_back(uint8_t(0x80 | body.size()));
  else if (body.size() < 65536) out.insert(out.end(), {uint8_t(0x80 | 126), uint8_t(body.size() >> 8), uint8_t(body.size())});
  else {
    out.push_back(0x80 | 127);
    for (int i = 7; i >= 0; --i) out.push_back(uint8_t(uint64_t(body.size()) >> (i * 8)));
  }
  out.insert(out.end(), mask, mask + 4);
  for (size_t i = 0; i < body.size(); ++i) out.push_back(uint8_t(body[i]) ^ mask[i & 3]);
  return out;
}

int main() {
  {
    // A phone's reader refuses anything over its limit, while the browser's default takes key frames.
    std::vector<Message> out;
    Reader phone(16);
    const auto small = Masked(0x81, "{\"cmd\":\"stop\"}");
    assert(phone.Add(small.data(), small.size(), out) && out.size() == 1);
    Reader limited(16);
    const auto big = Masked(0x81, std::string(17, 'x'));
    assert(!limited.Add(big.data(), big.size(), out));
    Reader browser;
    assert(browser.Add(big.data(), big.size(), out));
  }
  // The example from RFC 6455 section 1.3.
  const std::string request = "GET / HTTP/1.1\r\nHost: tv\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                              "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n";
  assert(HandshakeReply(request).find("Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n") != std::string::npos);
  assert(HandshakeReply("GET / HTTP/1.1\r\nHost: tv\r\n\r\n").empty());
  // Header names are case-insensitive.
  assert(!HandshakeReply("GET / HTTP/1.1\r\nsec-websocket-key: abc\r\n\r\n").empty());

  // A text message, split at every byte, still comes out whole.
  Reader reader;
  std::vector<Message> out;
  const auto hello = Masked(0x81, "{\"type\":\"throwcast\"}");
  for (uint8_t byte : hello) assert(reader.Add(&byte, 1, out));
  assert(out.size() == 1 && out[0].opcode == kText && std::string(out[0].data.begin(), out[0].data.end()) == "{\"type\":\"throwcast\"}");

  // Medium and large binary messages, back to back in one read.
  out.clear();
  const std::string medium(1000, 'a'), large(200000, 'b');
  auto both = Masked(0x82, medium);
  const auto second = Masked(0x82, large);
  both.insert(both.end(), second.begin(), second.end());
  assert(reader.Add(both.data(), both.size(), out));
  assert(out.size() == 2 && out[0].data.size() == 1000 && out[1].data.size() == 200000 && out[1].data[199999] == 'b');

  // A message in two frames, with a ping between them, as the protocol allows.
  out.clear();
  auto split = Masked(0x02, "first ");
  const auto ping = Masked(0x89, "p");
  const auto rest = Masked(0x80, "second");
  split.insert(split.end(), ping.begin(), ping.end());
  split.insert(split.end(), rest.begin(), rest.end());
  assert(reader.Add(split.data(), split.size(), out));
  assert(out.size() == 2 && out[0].opcode == kPing && out[1].opcode == kBinary);
  assert(std::string(out[1].data.begin(), out[1].data.end()) == "first second");

  // A sender that doesn't mask isn't a browser.
  Reader strict;
  out.clear();
  const uint8_t unmasked[] = {0x81, 0x01, 'x'};
  assert(!strict.Add(unmasked, sizeof unmasked, out));

  // What the TV sends back: unmasked, with the right length form.
  const std::string reply = "{\"type\":\"hello\"}";
  auto framed = Frame(kText, reinterpret_cast<const uint8_t*>(reply.data()), reply.size());
  assert(framed[0] == 0x81 && framed[1] == reply.size() && framed.size() == reply.size() + 2);
  framed = Frame(kBinary, reinterpret_cast<const uint8_t*>(large.data()), large.size());
  assert(framed[1] == 127 && framed.size() == large.size() + 10);

  std::puts("websocket: all passed");
}
