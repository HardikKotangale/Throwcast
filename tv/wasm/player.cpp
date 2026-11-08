// Feeds frames from JavaScript into Samsung's hardware player. Playback runs on the main
// thread, so packets use kIgnoreSessionId and setup is a chain of listener callbacks.
// In UDP mode a background thread receives the stream, since Samsung's sockets can't run on the
// main thread, and the main thread collects finished frames from it.
#include <arpa/inet.h>
#include <emscripten.h>
#include <netinet/in.h>
#include <pthread.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>

#include <algorithm>
#include <atomic>
#include <cerrno>
#include <deque>
#include <chrono>
#include <mutex>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

#include "samsung/html/html_media_element.h"
#include "samsung/wasm/elementary_audio_track_config.h"
#include "samsung/wasm/elementary_media_packet.h"
#include "samsung/wasm/elementary_media_stream_source.h"
#include "samsung/wasm/elementary_media_stream_source_listener.h"
#include "samsung/wasm/elementary_media_track.h"
#include "samsung/wasm/elementary_media_track_listener.h"
#include "samsung/wasm/elementary_video_track_config.h"
#include "samsung/wasm/operation_result.h"
#include "samsung/wasm/session_id.h"
#include "udp_frames.h"
#include "websocket.h"

using namespace samsung::wasm;
using samsung::html::HTMLMediaElement;

namespace {

constexpr size_t kBufferSize = 16 * 1024 * 1024;
constexpr uint32_t kSampleRate = 48000;

void Notify(const std::string& message) {
  EM_ASM({ Module.onPlayer(UTF8ToString($0)); }, message.c_str());
}

uint8_t* g_buffer;
uint32_t g_width, g_height, g_fps;
bool g_main10, g_h264;
int g_opened;
bool g_tracksAdded;
ElementaryMediaStreamSource* g_source;
HTMLMediaElement* g_element;
ElementaryMediaTrack g_video, g_audio;

class TrackListener : public ElementaryMediaTrackListener {
 public:
  void OnTrackOpen() override {
    if (++g_opened == 2) Notify("ready");
  }
  void OnTrackClosed(ElementaryMediaTrack::CloseReason) override {
    --g_opened;
    Notify("closed");
  }
  void OnAppendError(OperationResult result) override { Notify("append-error:" + std::to_string(static_cast<int>(result))); }
} g_videoListener, g_audioListener;

void AddVideoTrack() {
  // H.264 High at level 5.2, which covers 4K at 60 frames a second.
  const std::string mime = g_h264 ? "video/mp4; codecs=\"avc1.640034\""
                           : g_main10 ? "video/mp4; codecs=\"hev1.2.4.L153.B0\""
                                      : "video/mp4; codecs=\"hev1.1.6.L153.B0\"";
  ElementaryVideoTrackConfig config{mime, {}, DecodingMode::kHardware, g_width, g_height, g_fps, 1};
  g_source->AddTrack(config, [](OperationResult result, ElementaryMediaTrack track) {
    if (result != OperationResult::kSuccess) {
      Notify("video-rejected");
      return;
    }
    g_video = std::move(track);
    g_video.SetListener(&g_videoListener);
    g_source->Open([](OperationResult) {});
  });
}

void AddAudioTrack() {
  ElementaryAudioTrackConfig config{"audio/webm; codecs=\"pcm\"", {}, DecodingMode::kHardware,
                                    SampleFormat::kS16, ChannelLayout::kStereo, kSampleRate};
  g_source->AddTrack(config, [](OperationResult result, ElementaryMediaTrack track) {
    if (result != OperationResult::kSuccess) {
      Notify("audio-rejected");
      return;
    }
    g_audio = std::move(track);
    g_audio.SetListener(&g_audioListener);
    AddVideoTrack();
  });
}

class SourceListener : public ElementaryMediaStreamSourceListener {
 public:
  void OnSourceClosed() override {
    if (g_tracksAdded) return;
    g_tracksAdded = true;
    AddAudioTrack();
  }
  void OnSourceOpenPending() override {
    g_element->Play([](OperationResult result) {
      if (result != OperationResult::kSuccess) Notify("play-failed");
    });
  }
  void OnPipelineError(MediaPipelineError, const char* message) override {
    Notify(std::string("pipeline-error:") + (message ? message : ""));
  }
} g_sourceListener;

void Append(ElementaryMediaTrack& track, int size, bool key, double pts, double duration, bool video) {
  if (g_opened < 2) return;
  ElementaryMediaPacket packet{
      Seconds(pts), Seconds(pts), Seconds(duration), key, static_cast<size_t>(size), g_buffer,
      video ? g_width : 0, video ? g_height : 0, video ? g_fps : 0, video ? 1u : 0u, kIgnoreSessionId};
  auto result = track.AppendPacketAsync(packet);
  if (!result) Notify(std::string(video ? "append-error:video:" : "append-error:audio:") + std::to_string(static_cast<int>(result.operation_result)));
}

// The first free of these. The TV keeps a reloaded page's port open, so the next one may be needed.
constexpr uint16_t kUdpPort = 47125, kUdpPorts = 10;
std::atomic<int> g_udpPort{0};
std::mutex g_udpLock;
throwcast::Reassembler g_udp;
uint8_t* g_udpOut;
uint32_t g_mac;  // only this sender's datagrams are taken
// Read by the main thread for its reports. The receiving thread can't call JavaScript itself.
std::atomic<int> g_udpState{0};  // 0 starting, 1 receiving, -1 no socket, -2 port taken
std::atomic<uint32_t> g_udpIn{0}, g_udpRefused{0}, g_udpFrames{0};

// Asks the Mac to resend what the repair shards couldn't fill: 'N', a count, then frame and shard pairs.
// A resent shard comes back in about one Wi-Fi round trip, well before the frame is due on screen.
std::atomic<uint32_t> g_udpAsked{0};
void AskAgain(int fd, const sockaddr_in& mac, std::vector<throwcast::Ask>& asks, std::vector<uint8_t>& request) {
  if (!mac.sin_port) return;
  asks.clear();
  {
    std::lock_guard<std::mutex> hold(g_udpLock);
    g_udp.Asks(emscripten_get_now(), asks);
  }
  for (size_t start = 0; start < asks.size(); start += 200) {
    const size_t count = std::min<size_t>(200, asks.size() - start);
    request.assign({'N', uint8_t(count), uint8_t(count >> 8)});
    for (size_t i = start; i < start + count; ++i) {
      const auto& a = asks[i];
      request.insert(request.end(), {uint8_t(a.frame), uint8_t(a.frame >> 8), uint8_t(a.frame >> 16), uint8_t(a.frame >> 24),
                                     uint8_t(a.index), uint8_t(a.index >> 8)});
    }
    sendto(fd, request.data(), request.size(), 0, reinterpret_cast<const sockaddr*>(&mac), sizeof mac);
    g_udpAsked += uint32_t(count);
  }
}

void* ReceiveUdp(void*) {
  int fd = socket(AF_INET, SOCK_DGRAM, 0);
  if (fd < 0) {
    g_udpState = -1;
    return nullptr;
  }
  // A 4K key frame arrives as hundreds of datagrams at once, so give them room.
  int room = 8 * 1024 * 1024;
  setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &room, sizeof room);
  timeval wait{0, 4000};  // wake often, so holes are asked for quickly and lost frames given up on in silence
  setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &wait, sizeof wait);
  int reuse = 1;
  setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof reuse);
  sockaddr_in address{};
  address.sin_family = AF_INET;
  address.sin_addr.s_addr = htonl(INADDR_ANY);
  uint16_t port = kUdpPort;
  for (; port < kUdpPort + kUdpPorts; ++port) {
    address.sin_port = htons(port);
    if (bind(fd, reinterpret_cast<sockaddr*>(&address), sizeof address) == 0) break;
  }
  if (port == kUdpPort + kUdpPorts) {
    g_udpState = -2;
    return nullptr;
  }
  g_udpPort = port;
  g_udpState = 1;
  static uint8_t datagram[2048];
  sockaddr_in mac{};  // where the stream comes from, which is where requests to resend go
  std::vector<throwcast::Ask> asks;
  std::vector<uint8_t> request;
  for (;;) {
    sockaddr_in from{};
    socklen_t fromSize = sizeof from;
    ssize_t size = recvfrom(fd, datagram, sizeof datagram, 0, reinterpret_cast<sockaddr*>(&from), &fromSize);
    if (size <= 0) {
      AskAgain(fd, mac, asks, request);
      continue;
    }
    ++g_udpIn;
    // Some socket layers leave the sender blank; only a known, different sender is refused.
    if (from.sin_addr.s_addr && from.sin_addr.s_addr != g_mac) {
      ++g_udpRefused;
      continue;
    }
    if (from.sin_port) mac = from;
    {
      std::lock_guard<std::mutex> hold(g_udpLock);
      g_udp.Add(datagram, size_t(size), emscripten_get_now());
    }
    AskAgain(fd, mac, asks, request);
  }
}

// The browser extension streams here without the Mac app. A browser can only open a WebSocket, so this
// thread takes it, unwraps each message, and leaves it for the page to collect, the way UDP frames are.
// One browser at a time; the page decides whether to keep it (a Mac may already be casting).
constexpr uint16_t kWsPort = 47140, kWsPorts = 10;
std::atomic<int> g_wsPort{0};
std::mutex g_wsLock;
std::deque<throwcast::ws::Message> g_wsIn;  // finished messages, for the page
std::deque<std::string> g_wsOut;            // the page's replies, for the browser
std::atomic<bool> g_wsDrop{false};
// Set before the page reloads. The TV keeps a reloaded page's sockets open, so the listener closes its
// own port first, or every reload would leave one more port taken and silent.
std::atomic<bool> g_wsStop{false};
std::atomic<uint32_t> g_wsOpened{0}, g_wsClosed{0};
uint8_t* g_wsBuffer;
bool g_wsLastText;

bool SendAll(int fd, const std::vector<uint8_t>& bytes) {
  size_t sent = 0;
  while (sent < bytes.size()) {
    const ssize_t n = send(fd, bytes.data() + sent, bytes.size() - sent, 0);
    if (n > 0) sent += size_t(n);
    else if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR)) usleep(1000);
    else return false;
  }
  return true;
}

void ServeBrowser(int client) {
  using namespace throwcast::ws;
  timeval wait{0, 4000};  // wake often, to send the page's replies and notice a request to close
  setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &wait, sizeof wait);
  std::vector<uint8_t> buffer(256 * 1024);
  // The opening HTTP request, up to its blank line, within 3 seconds.
  std::string request;
  const double deadline = emscripten_get_now() + 3000;
  while (request.find("\r\n\r\n") == std::string::npos && request.size() < 8192 && emscripten_get_now() < deadline) {
    const ssize_t n = recv(client, buffer.data(), buffer.size(), 0);
    if (n > 0) request.append(reinterpret_cast<char*>(buffer.data()), size_t(n));
    else if (n == 0 || (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR)) break;
  }
  const std::string reply = HandshakeReply(request);
  if (reply.empty() || !SendAll(client, std::vector<uint8_t>(reply.begin(), reply.end()))) {
    close(client);
    return;
  }
  {
    std::lock_guard<std::mutex> hold(g_wsLock);
    g_wsIn.clear();
    g_wsOut.clear();
  }
  g_wsDrop = false;
  ++g_wsOpened;
  Reader reader;
  std::vector<Message> got;
  std::deque<std::string> replies;
  bool open = true;
  while (open && !g_wsStop && !g_wsDrop.exchange(false)) {
    {
      std::lock_guard<std::mutex> hold(g_wsLock);
      replies.swap(g_wsOut);
    }
    for (const std::string& text : replies) open = open && SendAll(client, Frame(kText, reinterpret_cast<const uint8_t*>(text.data()), text.size()));
    replies.clear();
    const ssize_t n = recv(client, buffer.data(), buffer.size(), 0);
    if (n == 0) break;
    if (n < 0) {
      if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) continue;
      break;
    }
    got.clear();
    if (!reader.Add(buffer.data(), size_t(n), got)) break;
    for (Message& message : got) {
      if (message.opcode == kPing) open = open && SendAll(client, Frame(kPong, message.data.data(), message.data.size()));
      else if (message.opcode == kClose) open = false;
      else if (message.opcode == kText || message.opcode == kBinary) {
        std::lock_guard<std::mutex> hold(g_wsLock);
        // The page collects every screen refresh. A backlog this long means it's stuck, so stop growing.
        if (g_wsIn.size() < 600) g_wsIn.push_back(std::move(message));
      }
    }
  }
  close(client);
  ++g_wsClosed;
}

void* ListenForBrowser(void*) {
  const int fd = socket(AF_INET, SOCK_STREAM, 0);
  if (fd < 0) return nullptr;
  int reuse = 1;
  setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof reuse);
  sockaddr_in address{};
  address.sin_family = AF_INET;
  address.sin_addr.s_addr = htonl(INADDR_ANY);
  // The first free port: like UDP, a reloaded page can keep the last one for a while.
  uint16_t port = kWsPort;
  for (; port < kWsPort + kWsPorts; ++port) {
    address.sin_port = htons(port);
    if (bind(fd, reinterpret_cast<sockaddr*>(&address), sizeof address) == 0) break;
  }
  if (port == kWsPort + kWsPorts || listen(fd, 2) != 0) return nullptr;
  // accept() wakes every 200 ms, so a request to stop is noticed.
  timeval wait{0, 200000};
  setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &wait, sizeof wait);
  g_wsPort = port;
  while (!g_wsStop) {
    const int client = accept(fd, nullptr, nullptr);
    if (client < 0) {
      if (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) usleep(100000);
      continue;
    }
    ServeBrowser(client);
  }
  close(fd);
  g_wsPort = 0;
  return nullptr;
}

// The iPhone remote, for a cast from the browser extension alone (with the Mac app, the phone talks to the
// Mac). Its own ports, so the extension, which takes the first WebSocket in 47140-47149, never lands here.
// Up to 3 phones on this one thread. Text only, and small: the page decides who is paired and what's allowed.
constexpr uint16_t kPhonePort = 47150, kPhonePorts = 10;
constexpr size_t kPhoneMax = 16 * 1024;
constexpr int kMaxPhones = 3;
std::atomic<int> g_phonePort{0};
std::mutex g_phoneLock;
std::deque<std::pair<int, std::string>> g_phoneIn;   // (phone, text), for the page
std::deque<std::pair<int, std::string>> g_phoneOut;  // (phone, text), for the phones
std::deque<int> g_phoneEvents;                       // +id connected, -id gone
std::deque<int> g_phoneDrops;                        // phones the page wants gone
char* g_phoneBuffer;
int g_phoneFrom;

struct Phone {
  int fd, id;
  throwcast::ws::Reader reader{kPhoneMax};
};

// The opening request, within a second. A phone on the LAN answers in milliseconds.
bool PhoneHandshake(int fd) {
  timeval wait{0, 20000};
  setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &wait, sizeof wait);
  std::string request;
  char chunk[2048];
  const double deadline = emscripten_get_now() + 1000;
  while (request.find("\r\n\r\n") == std::string::npos && request.size() < 8192 && emscripten_get_now() < deadline) {
    const ssize_t n = recv(fd, chunk, sizeof chunk, 0);
    if (n > 0) request.append(chunk, size_t(n));
    else if (n == 0 || (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR)) return false;
  }
  const std::string reply = throwcast::ws::HandshakeReply(request);
  return !reply.empty() && SendAll(fd, std::vector<uint8_t>(reply.begin(), reply.end()));
}

void* ListenForPhones(void*) {
  using namespace throwcast::ws;
  const int fd = socket(AF_INET, SOCK_STREAM, 0);
  if (fd < 0) return nullptr;
  int reuse = 1;
  setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof reuse);
  sockaddr_in address{};
  address.sin_family = AF_INET;
  address.sin_addr.s_addr = htonl(INADDR_ANY);
  uint16_t port = kPhonePort;
  for (; port < kPhonePort + kPhonePorts; ++port) {
    address.sin_port = htons(port);
    if (bind(fd, reinterpret_cast<sockaddr*>(&address), sizeof address) == 0) break;
  }
  if (port == kPhonePort + kPhonePorts || listen(fd, 4) != 0) return nullptr;
  // Short waits everywhere: one thread takes new phones and serves the connected ones in turn.
  timeval wait{0, 5000};
  setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &wait, sizeof wait);
  g_phonePort = port;
  std::vector<Phone> phones;
  int nextId = 1;
  std::vector<uint8_t> buffer(16 * 1024);
  std::vector<Message> got;
  auto drop = [&](size_t index) {
    close(phones[index].fd);
    std::lock_guard<std::mutex> hold(g_phoneLock);
    g_phoneEvents.push_back(-phones[index].id);
    phones.erase(phones.begin() + long(index));
  };
  while (!g_wsStop) {
    const int client = accept(fd, nullptr, nullptr);
    if (client >= 0) {
      if (int(phones.size()) >= kMaxPhones || !PhoneHandshake(client)) {
        close(client);
      } else {
        timeval quick{0, 2000};
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &quick, sizeof quick);
        phones.push_back(Phone{client, nextId++});
        std::lock_guard<std::mutex> hold(g_phoneLock);
        g_phoneEvents.push_back(phones.back().id);
      }
    }
    std::deque<std::pair<int, std::string>> out;
    std::deque<int> drops;
    {
      std::lock_guard<std::mutex> hold(g_phoneLock);
      out.swap(g_phoneOut);
      drops.swap(g_phoneDrops);
    }
    for (size_t i = phones.size(); i-- > 0;) {
      Phone& phone = phones[i];
      bool open = std::find(drops.begin(), drops.end(), phone.id) == drops.end();
      for (const auto& item : out) {
        if (open && item.first == phone.id)
          open = SendAll(phone.fd, Frame(kText, reinterpret_cast<const uint8_t*>(item.second.data()), item.second.size()));
      }
      if (open) {
        const ssize_t n = recv(phone.fd, buffer.data(), buffer.size(), 0);
        if (n == 0) open = false;
        else if (n < 0) open = errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR;
        else {
          got.clear();
          open = phone.reader.Add(buffer.data(), size_t(n), got);
          for (Message& message : got) {
            if (message.opcode == kPing) open = open && SendAll(phone.fd, Frame(kPong, message.data.data(), message.data.size()));
            else if (message.opcode == kClose) open = false;
            else if (message.opcode == kText) {
              std::lock_guard<std::mutex> hold(g_phoneLock);
              if (g_phoneIn.size() < 100) g_phoneIn.emplace_back(phone.id, std::string(message.data.begin(), message.data.end()));
            }
          }
        }
      }
      if (!open) drop(i);
    }
  }
  for (size_t i = phones.size(); i-- > 0;) drop(i);
  close(fd);
  g_phonePort = 0;
  return nullptr;
}

}  // namespace

extern "C" {

// Starts listening for the browser extension. Messages are copied to the returned buffer by tc_ws_next.
EMSCRIPTEN_KEEPALIVE uint8_t* tc_ws_start() {
  if (!g_wsBuffer) {
    g_wsBuffer = new uint8_t[kBufferSize + 1];
    pthread_t thread;
    pthread_create(&thread, nullptr, ListenForBrowser, nullptr);
    pthread_detach(thread);
  }
  return g_wsBuffer;
}

EMSCRIPTEN_KEEPALIVE int tc_ws_port() { return g_wsPort; }
// Browsers that connected, and connections that ended, since the last call.
EMSCRIPTEN_KEEPALIVE int tc_ws_opened() { return int(g_wsOpened.exchange(0)); }
EMSCRIPTEN_KEEPALIVE int tc_ws_closed() { return int(g_wsClosed.exchange(0)); }

// Copies the next message to the buffer: its size, or 0 when there's none. Text ends with a 0 byte.
EMSCRIPTEN_KEEPALIVE int tc_ws_next() {
  std::lock_guard<std::mutex> hold(g_wsLock);
  if (g_wsIn.empty()) return 0;
  throwcast::ws::Message message = std::move(g_wsIn.front());
  g_wsIn.pop_front();
  const size_t size = std::min(message.data.size(), kBufferSize);
  std::memcpy(g_wsBuffer, message.data.data(), size);
  g_wsBuffer[size] = 0;
  g_wsLastText = message.opcode == throwcast::ws::kText;
  return int(size);
}

EMSCRIPTEN_KEEPALIVE int tc_ws_text() { return g_wsLastText; }

EMSCRIPTEN_KEEPALIVE void tc_ws_send(const char* text) {
  std::lock_guard<std::mutex> hold(g_wsLock);
  g_wsOut.emplace_back(text);
}

EMSCRIPTEN_KEEPALIVE void tc_ws_close() { g_wsDrop = true; }
// Closes the listener and any browser, before the page reloads.
EMSCRIPTEN_KEEPALIVE void tc_ws_stop() { g_wsStop = true; }

// The iPhone remote's listener. Messages are copied to the returned buffer by tc_remote_next.
EMSCRIPTEN_KEEPALIVE char* tc_remote_start() {
  if (!g_phoneBuffer) {
    g_phoneBuffer = new char[kPhoneMax + 1];
    pthread_t thread;
    pthread_create(&thread, nullptr, ListenForPhones, nullptr);
    pthread_detach(thread);
  }
  return g_phoneBuffer;
}

EMSCRIPTEN_KEEPALIVE int tc_remote_port() { return g_phonePort; }

// The next phone message, as text in the buffer: its size, or 0 when there's none. tc_remote_from says who sent it.
EMSCRIPTEN_KEEPALIVE int tc_remote_next() {
  std::lock_guard<std::mutex> hold(g_phoneLock);
  if (g_phoneIn.empty()) return 0;
  const std::string text = std::move(g_phoneIn.front().second);
  g_phoneFrom = g_phoneIn.front().first;
  g_phoneIn.pop_front();
  const size_t size = std::min(text.size(), kPhoneMax);
  std::memcpy(g_phoneBuffer, text.data(), size);
  g_phoneBuffer[size] = 0;
  return int(size);
}

EMSCRIPTEN_KEEPALIVE int tc_remote_from() { return g_phoneFrom; }

// The next connect (+id) or disconnect (-id), or 0.
EMSCRIPTEN_KEEPALIVE int tc_remote_event() {
  std::lock_guard<std::mutex> hold(g_phoneLock);
  if (g_phoneEvents.empty()) return 0;
  const int event = g_phoneEvents.front();
  g_phoneEvents.pop_front();
  return event;
}

EMSCRIPTEN_KEEPALIVE void tc_remote_send(int phone, const char* text) {
  std::lock_guard<std::mutex> hold(g_phoneLock);
  if (g_phoneOut.size() < 400) g_phoneOut.emplace_back(phone, text);
}

EMSCRIPTEN_KEEPALIVE void tc_remote_drop(int phone) {
  std::lock_guard<std::mutex> hold(g_phoneLock);
  g_phoneDrops.push_back(phone);
}

// Starts receiving the stream over UDP from `mac`, an IPv4 address in host byte order.
EMSCRIPTEN_KEEPALIVE uint8_t* tc_udp_start(uint32_t mac, int delayMs) {
  g_mac = htonl(mac);
  {
    std::lock_guard<std::mutex> hold(g_udpLock);
    g_udp.SetDelay(delayMs);
  }
  if (!g_udpOut) {
    g_udpOut = new uint8_t[kBufferSize];
    pthread_t thread;
    pthread_create(&thread, nullptr, ReceiveUdp, nullptr);
    pthread_detach(thread);
  }
  return g_udpOut;
}

// Copies the next finished frame, in order, to the buffer tc_udp_start returned. 0 when none is ready.
EMSCRIPTEN_KEEPALIVE int tc_udp_next() {
  static std::vector<uint8_t> frame;
  std::lock_guard<std::mutex> hold(g_udpLock);
  if (!g_udp.Next(frame, emscripten_get_now()) || frame.size() > kBufferSize) return 0;
  ++g_udpFrames;
  std::memcpy(g_udpOut, frame.data(), frame.size());
  return int(frame.size());
}

// What the receiving thread has seen: state, then datagrams in, refused and frames rebuilt, packed for one call.
EMSCRIPTEN_KEEPALIVE int tc_udp_state() { return g_udpState; }
EMSCRIPTEN_KEEPALIVE int tc_udp_port() { return g_udpPort; }
EMSCRIPTEN_KEEPALIVE int tc_udp_in() { return int(g_udpIn.exchange(0)); }
EMSCRIPTEN_KEEPALIVE int tc_udp_refused() { return int(g_udpRefused.exchange(0)); }
EMSCRIPTEN_KEEPALIVE int tc_udp_frames() { return int(g_udpFrames.exchange(0)); }
EMSCRIPTEN_KEEPALIVE int tc_udp_asked() { return int(g_udpAsked.exchange(0)); }

// Video frames lost since the last call. Any of them means a fresh key frame is needed.
EMSCRIPTEN_KEEPALIVE int tc_udp_lost() {
  std::lock_guard<std::mutex> hold(g_udpLock);
  return int(g_udp.TakeLostVideo());
}

EMSCRIPTEN_KEEPALIVE uint8_t* tc_buffer() {
  if (!g_buffer) g_buffer = new uint8_t[kBufferSize];
  return g_buffer;
}

EMSCRIPTEN_KEEPALIVE int tc_buffer_size() { return kBufferSize; }

EMSCRIPTEN_KEEPALIVE void tc_start(int width, int height, int fps, int main10, int h264) {
  g_h264 = h264;
  g_width = width;
  g_height = height;
  g_fps = fps;
  g_main10 = main10;
  g_element = new HTMLMediaElement("player");
  g_source = new ElementaryMediaStreamSource(EmssLatencyMode::kUltraLow, EmssRenderingMode::kMediaElement);
  g_source->SetListener(&g_sourceListener);
  g_element->SetSrc(g_source);
}

EMSCRIPTEN_KEEPALIVE void tc_video(int size, int key, double pts) {
  Append(g_video, size, key, pts, 1.0 / g_fps, true);
}

EMSCRIPTEN_KEEPALIVE void tc_audio(int size, double pts) {
  Append(g_audio, size, true, pts, size / 4.0 / kSampleRate, false);
}

}  // extern "C"

int main() {
  emscripten_exit_with_live_runtime();
}
