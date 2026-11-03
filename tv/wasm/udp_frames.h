// Rebuilds stream frames from UDP datagrams. Plain C++ with no TV calls, so it's tested on the Mac too.
//
// Each datagram: magic(1) type(1) frame(4) index(2) count(2) lastLen(2), all little-endian, then the shard.
// type bit 0 marks a repair shard, and bits 1+ carry the frame's kind (1 video, 2 audio). A frame is cut
// into `count` shards of kShard bytes; the last holds `lastLen`. Every kGroup shards get one repair shard,
// their XOR, so any one lost shard in a group is rebuilt without asking the Mac again.
#pragma once

#include <cstdint>
#include <algorithm>
#include <cstring>
#include <deque>
#include <map>
#include <vector>

namespace throwcast {

constexpr size_t kShard = 1200;
constexpr size_t kGroup = 8;
constexpr size_t kHeader = 12;
constexpr uint8_t kMagic = 0x54;
// Defaults for how long a missing frame is waited for, before SetDelay matches them to the playback buffer.
constexpr double kWaitBehindMs = 40;
constexpr double kGiveUpMs = 150;
// A frame with holes is asked for again once nothing new for it has come in for this long, and again
// after kAskAgainMs, at most kMaxAsks times. One Wi-Fi round trip here is about 5 ms.
constexpr double kSettleMs = 3;
constexpr double kAskAgainMs = 15;
constexpr int kMaxAsks = 3;
// Asking for a whole frame, when not a single shard of it arrived.
constexpr uint16_t kWholeFrame = 0xFFFF;

struct Ask {
  uint32_t frame;
  uint16_t index;
};

class Reassembler {
 public:
  // Waits follow the playback buffer: a missing frame is given up on before the TV would have to show it.
  void SetDelay(double ms) {
    wait_behind_ = std::min(200.0, std::max(20.0, ms * 0.6));
    give_up_ = std::min(350.0, std::max(30.0, ms * 0.9));
  }

  void Add(const uint8_t* data, size_t size, double now) {
    if (size < kHeader || data[0] != kMagic) return;
    const bool repair = data[1] & 1;
    const uint8_t kind = data[1] >> 1;
    const uint32_t frame = Read32(data + 2);
    const uint16_t index = Read16(data + 6), count = Read16(data + 8), last = Read16(data + 10);
    if (count == 0 || last == 0 || last > kShard) return;
    // Until something has played, an earlier frame arriving late moves the start back to it.
    if (!started_ || (!played_ && Before(frame, next_))) {
      next_ = frame;
      started_ = true;
    }
    if (Before(frame, next_) || complete_.count(frame)) return;  // already played or skipped
    Frame& f = pending_[frame];
    if (f.count == 0) {
      f.count = count;
      f.last = last;
      f.kind = kind;
      f.first = now;
      f.shards.assign(count, {});
    }
    if (count != f.count) return;
    f.last_at = now;
    const uint8_t* body = data + kHeader;
    const size_t length = size - kHeader;
    if (repair) {
      if (index * kGroup < count && length == kShard) f.repairs[index].assign(body, body + length);
    } else if (index < count && f.shards[index].empty()) {
      if (length != (index + 1 == count ? last : kShard)) return;
      f.shards[index].assign(body, body + length);
      ++f.have;
    }
    Recover(f);
    if (f.have == f.count) Finish(frame, f, now);
  }

  // The next frame to play, in order. Gives up on a lost frame instead of waiting on it for long.
  bool Next(std::vector<uint8_t>& out, double now) {
    for (;;) {
      auto ready = complete_.find(next_);
      if (ready != complete_.end()) {
        out.swap(ready->second.bytes);
        complete_.erase(ready);
        missing_asked_.erase(next_);
        ++next_;
        played_ = true;
        return true;
      }
      if (!started_) return false;
      auto later = complete_.begin();
      auto waiting = pending_.find(next_);
      const bool behind = later != complete_.end() && now - later->second.at > wait_behind_;
      const bool stale = waiting != pending_.end() && now - waiting->second.first > give_up_;
      if (!behind && !stale) return false;
      Skip(waiting != pending_.end() ? waiting->second.kind : 0);
    }
  }

  // The shards worth asking the Mac for again: holes the repair shards can't fill, in frames that have
  // gone quiet. A frame that never arrived at all, with later ones already here, is asked for whole.
  void Asks(double now, std::vector<Ask>& out) {
    if (!started_) return;
    const bool later_arrived = !pending_.empty() || !complete_.empty();
    for (uint32_t frame = next_; later_arrived && frame != Newest(); ++frame) {
      if (pending_.count(frame) || complete_.count(frame)) continue;
      auto asked = missing_asked_.find(frame);
      if (asked != missing_asked_.end() && now - asked->second < kAskAgainMs) continue;
      missing_asked_[frame] = now;
      out.push_back({frame, kWholeFrame});
      if (out.size() >= 64) return;
    }
    for (auto& [frame, f] : pending_) {
      if (now - f.last_at < kSettleMs || f.asks >= kMaxAsks || now - f.asked_at < kAskAgainMs) continue;
      f.asked_at = now;
      ++f.asks;
      for (size_t start = 0; start < f.count; start += kGroup) {
        const size_t end = std::min<size_t>(start + kGroup, f.count);
        int gaps = 0;
        for (size_t i = start; i < end; ++i) gaps += f.shards[i].empty();
        // One hole with its repair shard here fills itself; anything else needs the Mac.
        if (gaps == 0 || (gaps == 1 && f.repairs.count(uint16_t(start / kGroup)))) continue;
        for (size_t i = start; i < end; ++i)
          if (f.shards[i].empty()) out.push_back({frame, uint16_t(i)});
      }
      if (out.size() >= 256) return;
    }
  }

  // Video frames given up on since the last call. Any of them means the picture needs a fresh key frame.
  uint32_t TakeLostVideo() {
    const uint32_t lost = lost_video_;
    lost_video_ = 0;
    return lost;
  }

 private:
  struct Frame {
    uint16_t count = 0, last = 0, have = 0;
    uint8_t kind = 0;
    double first = 0, last_at = 0, asked_at = -1e9;
    int asks = 0;
    std::vector<std::vector<uint8_t>> shards;
    std::map<uint16_t, std::vector<uint8_t>> repairs;
  };
  struct Done {
    std::vector<uint8_t> bytes;
    double at;
  };

  static uint16_t Read16(const uint8_t* p) { return p[0] | p[1] << 8; }
  static uint32_t Read32(const uint8_t* p) { return p[0] | p[1] << 8 | p[2] << 16 | uint32_t(p[3]) << 24; }
  static bool Before(uint32_t a, uint32_t b) { return int32_t(a - b) < 0; }

  // A group missing exactly one shard gets it back from the repair shard.
  void Recover(Frame& f) {
    for (auto& [group, repair] : f.repairs) {
      const size_t start = group * kGroup, end = std::min<size_t>(start + kGroup, f.count);
      int missing = -1, gaps = 0;
      for (size_t i = start; i < end; ++i)
        if (f.shards[i].empty()) missing = int(i), ++gaps;
      if (gaps != 1) continue;
      std::vector<uint8_t> rebuilt = repair;
      for (size_t i = start; i < end; ++i)
        for (size_t b = 0; b < f.shards[i].size(); ++b) rebuilt[b] ^= f.shards[i][b];
      rebuilt.resize(size_t(missing) + 1 == f.count ? f.last : kShard);
      f.shards[missing] = std::move(rebuilt);
      ++f.have;
    }
  }

  void Finish(uint32_t frame, Frame& f, double now) {
    Done done{{}, now};
    done.bytes.reserve((f.count - 1) * kShard + f.last);
    for (auto& shard : f.shards) done.bytes.insert(done.bytes.end(), shard.begin(), shard.end());
    complete_[frame] = std::move(done);
    pending_.erase(frame);
  }

  // One past the newest frame seen, so frames before it that never showed up can be asked for.
  uint32_t Newest() const {
    uint32_t newest = next_;
    if (!pending_.empty()) newest = std::max(newest, pending_.rbegin()->first + 1);
    if (!complete_.empty()) newest = std::max(newest, complete_.rbegin()->first + 1);
    return newest;
  }

  void Skip(uint8_t kind) {
    // Nothing arrived at all for this frame, so its kind is unknown: treat it as video to be safe.
    if (kind != 2) ++lost_video_;
    pending_.erase(next_);
    missing_asked_.erase(next_);
    ++next_;
    // Forget anything that can no longer be played.
    while (!pending_.empty() && Before(pending_.begin()->first, next_)) pending_.erase(pending_.begin());
  }

  bool started_ = false, played_ = false;
  double wait_behind_ = kWaitBehindMs, give_up_ = kGiveUpMs;
  std::map<uint32_t, double> missing_asked_;
  uint32_t next_ = 0, lost_video_ = 0;
  std::map<uint32_t, Frame> pending_;
  std::map<uint32_t, Done> complete_;
};

}  // namespace throwcast
