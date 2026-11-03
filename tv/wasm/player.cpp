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

#include <atomic>
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

}  // namespace

extern "C" {

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
