// Feeds frames from JavaScript into Samsung's hardware player. Everything runs on the main
// thread, so packets use kIgnoreSessionId and setup is a chain of listener callbacks.
#include <emscripten.h>

#include <chrono>
#include <cstdio>
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
bool g_main10;
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
  const std::string mime = g_main10 ? "video/mp4; codecs=\"hev1.2.4.L153.B0\""
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

}  // namespace

extern "C" {

EMSCRIPTEN_KEEPALIVE uint8_t* tc_buffer() {
  if (!g_buffer) g_buffer = new uint8_t[kBufferSize];
  return g_buffer;
}

EMSCRIPTEN_KEEPALIVE int tc_buffer_size() { return kBufferSize; }

EMSCRIPTEN_KEEPALIVE void tc_start(int width, int height, int fps, int main10) {
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
