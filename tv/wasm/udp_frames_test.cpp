// Checks the frame rebuilder on the Mac: clang++ -std=c++17 tv/wasm/udp_frames_test.cpp && ./a.out
#include <cassert>
#include <cstdio>
#include <algorithm>
#include <random>

#include "udp_frames.h"

using namespace throwcast;
using Bytes = std::vector<uint8_t>;

// The same layout the Mac sends (MediaUDP.datagrams), written independently.
std::vector<Bytes> Split(uint32_t frame, uint8_t kind, const Bytes& packet) {
  const size_t count = std::max<size_t>(1, (packet.size() + kShard - 1) / kShard);
  const size_t last = packet.size() - (count - 1) * kShard;
  auto header = [&](bool repair, size_t index) {
    return Bytes{kMagic, uint8_t((kind << 1) | repair), uint8_t(frame), uint8_t(frame >> 8), uint8_t(frame >> 16), uint8_t(frame >> 24),
                 uint8_t(index), uint8_t(index >> 8), uint8_t(count), uint8_t(count >> 8), uint8_t(last), uint8_t(last >> 8)};
  };
  std::vector<Bytes> out;
  for (size_t i = 0; i < count; ++i) {
    Bytes d = header(false, i);
    d.insert(d.end(), packet.begin() + i * kShard, packet.begin() + i * kShard + (i + 1 == count ? last : kShard));
    out.push_back(d);
  }
  for (size_t g = 0; g * kGroup < count; ++g) {
    Bytes parity(kShard, 0);
    for (size_t i = g * kGroup; i < std::min(count, (g + 1) * kGroup); ++i)
      for (size_t b = 0; b < (i + 1 == count ? last : kShard); ++b) parity[b] ^= packet[i * kShard + b];
    Bytes d = header(true, g);
    d.insert(d.end(), parity.begin(), parity.end());
    out.push_back(d);
  }
  return out;
}

Bytes Frame(size_t size, uint8_t seed) {
  Bytes b(size);
  for (size_t i = 0; i < size; ++i) b[i] = uint8_t(i * 31 + seed);
  return b;
}

int main() {
  std::mt19937 rng(7);
  {  // In order, every size from one byte to many shards, including exact multiples of a shard.
    Reassembler r;
    std::vector<Bytes> sent;
    for (size_t size : {1, 1199, 1200, 1201, 9600, 50000}) sent.push_back(Frame(size, uint8_t(size)));
    for (uint32_t f = 0; f < sent.size(); ++f)
      for (auto& d : Split(f, 1, sent[f])) r.Add(d.data(), d.size(), 0);
    Bytes out;
    for (auto& expected : sent) assert(r.Next(out, 0) && out == expected);
    assert(!r.Next(out, 0) && r.TakeLostVideo() == 0);
  }
  {  // Shuffled arrival, with one shard of every group lost: all frames rebuilt, in order.
    Reassembler r;
    std::vector<Bytes> sent, datagrams;
    for (uint32_t f = 0; f < 5; ++f) {
      sent.push_back(Frame(20000 + f * 777, uint8_t(f)));
      auto parts = Split(f, 1, sent.back());
      const size_t count = (sent.back().size() + kShard - 1) / kShard;
      for (size_t i = 0; i < parts.size(); ++i)
        if (!(i < count && i % kGroup == 3)) datagrams.push_back(parts[i]);
    }
    std::shuffle(datagrams.begin(), datagrams.end(), rng);
    for (auto& d : datagrams) r.Add(d.data(), d.size(), 0);
    Bytes out;
    for (auto& expected : sent) assert(r.Next(out, 0) && out == expected);
    assert(r.TakeLostVideo() == 0);
  }
  {  // A video frame lost entirely: playback moves on once a later one has waited, and asks for a key frame.
    Reassembler r;
    Bytes a = Frame(3000, 1), c = Frame(3000, 3);
    for (auto& d : Split(0, 1, a)) r.Add(d.data(), d.size(), 0);
    for (auto& d : Split(2, 1, c)) r.Add(d.data(), d.size(), 10);
    Bytes out;
    assert(r.Next(out, 10) && out == a);
    assert(!r.Next(out, 20));  // still worth waiting for frame 1
    assert(r.Next(out, 10 + kWaitBehindMs + 1) && out == c);
    assert(r.TakeLostVideo() == 1);
  }
  {  // A sound frame that can't be rebuilt is skipped without asking for a new picture.
    Reassembler r;
    Bytes v = Frame(2000, 4), s = Frame(3000, 5), v2 = Frame(2000, 6);
    for (auto& d : Split(0, 1, v)) r.Add(d.data(), d.size(), 0);
    auto sound = Split(1, 2, s);
    r.Add(sound[0].data(), sound[0].size(), 0);  // one of three shards, no repair
    for (auto& d : Split(2, 1, v2)) r.Add(d.data(), d.size(), 0);
    Bytes out;
    assert(r.Next(out, 0) && out == v);
    assert(r.Next(out, kWaitBehindMs + 1) && out == v2);
    assert(r.TakeLostVideo() == 0);
  }
  {  // A half-arrived frame with nothing after it is dropped once it's too old, so nothing stalls forever.
    Reassembler r;
    auto parts = Split(0, 1, Frame(9000, 9));
    r.Add(parts[0].data(), parts[0].size(), 0);
    Bytes out;
    assert(!r.Next(out, kGiveUpMs - 1));
    assert(!r.Next(out, kGiveUpMs + 1) && r.TakeLostVideo() == 1);
    for (auto& d : Split(1, 1, Frame(100, 1))) r.Add(d.data(), d.size(), 200);
    assert(r.Next(out, 200) && out == Frame(100, 1));
  }
  {  // Junk and repeats are ignored.
    Reassembler r;
    uint8_t junk[30] = {1, 2, 3};
    r.Add(junk, sizeof junk, 0);
    auto parts = Split(0, 1, Frame(2500, 2));
    for (auto& d : parts) r.Add(d.data(), d.size(), 0);
    for (auto& d : parts) r.Add(d.data(), d.size(), 0);
    Bytes out;
    assert(r.Next(out, 0) && out == Frame(2500, 2) && !r.Next(out, 0));
  }
  {  // Two holes in one group can't be repaired locally: once the frame goes quiet, exactly those are asked for.
    Reassembler r;
    Bytes big = Frame(12000, 3);  // 10 shards: groups 0-7 and 8-9
    auto parts = Split(0, 1, big);
    for (size_t i = 0; i < parts.size(); ++i)
      if (i != 2 && i != 5) r.Add(parts[i].data(), parts[i].size(), 0);
    std::vector<Ask> asks;
    r.Asks(1, asks);
    assert(asks.empty());  // still arriving, too soon to ask
    r.Asks(kSettleMs + 1, asks);
    assert(asks.size() == 2 && asks[0].frame == 0 && asks[0].index == 2 && asks[1].index == 5);
    asks.clear();
    r.Asks(kSettleMs + 2, asks);
    assert(asks.empty());  // not asked again straight away
    r.Add(parts[2].data(), parts[2].size(), 6);  // the resent shard: with the repair, 5 now rebuilds too
    Bytes out;
    assert(r.Next(out, 6) && out == big);
  }
  {  // A frame that never arrived, with a later one here, is asked for whole; resent, it plays in order.
    Reassembler r;
    Bytes a = Frame(1500, 1), b = Frame(1500, 2), c = Frame(1500, 3);
    for (auto& d : Split(0, 1, a)) r.Add(d.data(), d.size(), 0);
    for (auto& d : Split(2, 1, c)) r.Add(d.data(), d.size(), 0);
    Bytes out;
    assert(r.Next(out, 0) && out == a);
    std::vector<Ask> asks;
    r.Asks(1, asks);
    assert(asks.size() == 1 && asks[0].frame == 1 && asks[0].index == kWholeFrame);
    for (auto& d : Split(1, 1, b)) r.Add(d.data(), d.size(), 5);
    assert(r.Next(out, 5) && out == b && r.Next(out, 5) && out == c && r.TakeLostVideo() == 0);
  }
  {  // Waits follow the buffer: at Instant a missing frame is given up on far sooner than at Smooth.
    Reassembler instant, smooth;
    instant.SetDelay(33);
    smooth.SetDelay(400);
    for (Reassembler* r : {&instant, &smooth}) {
      for (auto& d : Split(0, 1, Frame(100, 1))) r->Add(d.data(), d.size(), 0);
      for (auto& d : Split(2, 1, Frame(100, 2))) r->Add(d.data(), d.size(), 0);
      Bytes out;
      assert(r->Next(out, 0));
    }
    Bytes out;
    assert(instant.Next(out, 25) && instant.TakeLostVideo() == 1);
    assert(!smooth.Next(out, 25));
  }
  std::puts("udp_frames: all checks passed");
}
