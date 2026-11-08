// Casting a tab with no Mac app: this page captures the tab, encodes its picture on the Mac's hardware
// H.264 encoder, and sends picture and sound straight to the TV, in the same messages the Mac app uses.
// It runs only while a tab is on the TV; the extension closes it when the cast ends.

// The TV app listens on the first free port of these, like it does for UDP.
const PORTS = [47140, 47141, 47142, 47143, 47144, 47145, 47146, 47147, 47148, 47149];
const HEADER = 16;

/// kind 1 is video, 2 audio; then a key-frame flag, padding, and the time in seconds, as the TV reads them.
export function packet(kind, key, seconds, payload) {
  const out = new Uint8Array(HEADER + payload.byteLength);
  out[0] = kind;
  out[1] = key ? 1 : 0;
  new DataView(out.buffer).setFloat64(8, seconds, true);
  out.set(payload, HEADER);
  return out;
}

/// The largest part of the picture in the TV's shape, centered, so the tab isn't stretched to fit.
/// Even numbers, because the encoder's colour format works in 2×2 blocks.
export function tvShape(width, height, aspect) {
  const even = (n) => Math.max(0, Math.floor(n / 2) * 2);
  const w = Math.max(2, even(Math.min(width, height * aspect)));
  const h = Math.max(2, even(Math.min(height, w / aspect)));
  return { x: even((width - w) / 2), y: even((height - h) / 2), width: w, height: h };
}

/// The TV's size, at most 4K, and a bitrate that suits it over Wi-Fi.
/// The size to send: the chosen quality, but never more than the TV shows, nor more than 4K.
export function streamSize(tv, quality = '4k') {
  const wanted = { '4k': 2160, 1440: 1440, 1080: 1080 }[quality] ?? 2160;
  const height = Math.min(wanted, tv.height || 2160, 2160);
  const width = Math.round((height * 16) / 9 / 2) * 2;
  const bitrate = height >= 2160 ? 30e6 : height >= 1440 ? 18e6 : 10e6;
  return { width, height, bitrate };
}

// The TV app takes a few seconds to start listening after it opens, so keep trying for a while.
export function connect(host, until = performance.now() + 15000) {
  return new Promise((resolve, reject) => {
    const next = (i) => {
      if (i >= PORTS.length) {
        if (performance.now() < until) return setTimeout(() => next(0), 700);
        return reject(new Error('Throwcast on the TV didn’t answer. Open it from the TV’s Apps screen and try again.'));
      }
      const socket = new WebSocket(`ws://${host}:${PORTS[i]}`);
      socket.binaryType = 'arraybuffer';
      const timer = setTimeout(() => socket.close(), 1500);
      socket.onopen = () => {
        clearTimeout(timer);
        socket.onerror = socket.onclose = null;
        resolve(socket);
      };
      socket.onerror = socket.onclose = () => {
        clearTimeout(timer);
        socket.onerror = socket.onclose = null;
        next(i + 1);
      };
    };
    next(0);
  });
}

let cast;
let captured;
// The captured tab for as long as it's on the TV, kept across a restart with new stream settings.
let held;

/// Takes the tab straight away: Chrome's permission to capture it expires within seconds, before the TV
/// may even be found. The stream to the TV starts once it is.
export async function captureTab(streamId) {
  stopStream();
  captured?.getTracks().forEach((track) => track.stop());
  captured = await navigator.mediaDevices.getUserMedia({
    audio: { mandatory: { chromeMediaSource: 'tab', chromeMediaSourceId: streamId } },
    video: { mandatory: { chromeMediaSource: 'tab', chromeMediaSourceId: streamId, maxWidth: 3840, maxHeight: 2160, maxFrameRate: 60 } },
  });
}

export async function startStream(settings, onEnd) {
  const { tv, quality, delay = 400, fps = 60, bitrate: chosen = 'auto', volume = 1 } = settings;
  const media = captured ?? held?.media;
  if (!media) throw new Error('The tab wasn’t captured. Press Show This Tab on TV again.');
  captured = undefined;
  held = { media, settings, onEnd, sound: held?.media === media ? held.sound : undefined };
  // A chosen bitrate, in Mbps, or the one that suits the size: more is sharper, but needs stronger Wi-Fi.
  const fitting = streamSize(tv, quality);
  const { width, height } = fitting;
  const typed = Number(chosen);
  const bitrate = chosen !== 'auto' && typed >= 5 ? Math.min(typed, 100) * 1e6 : fps === 30 ? fitting.bitrate * 0.65 : fitting.bitrate;
  const me = { media, socket: null, encoder: null, reader: null, audio: null, track: null, ready: false, wantKey: true, started: performance.now(), times: new Map(), lastFrame: 0 };
  const deliver = (bytes) => {
    if (me.socket?.readyState === WebSocket.OPEN) me.socket.send(bytes);
  };
  cast = me;
  const seconds = () => (performance.now() - me.started) / 1000;
  const end = (reason) => {
    if (cast !== me) return;
    stopStream();
    onEnd(reason);
  };
  try {
    me.socket = await connect(tv.host);
  } catch (problem) {
    if (cast === me) stopStream();
    throw problem;
  }
  if (cast !== me) return;
  const socket = me.socket;
  // Over TCP nothing is lost, so the only risk is falling behind. More than half a second waiting
  // to go out means Wi-Fi can't keep up; skipping new frames lets it catch up without a stall.
  const backlog = bitrate / 8 / 2;
  socket.onclose = () => end('The TV stopped the cast.');
  socket.onmessage = (event) => {
    if (typeof event.data !== 'string') return;
    const message = JSON.parse(event.data);
    if (message.type === 'hello') {
      socket.send(JSON.stringify({ type: 'config', width, height, fps, main10: false, hdr: false, smooth: delay >= 400, delay, udp: false, codec: 'h264' }));
    } else if (message.type === 'ready') {
      me.ready = true;
      me.wantKey = true;
    } else if (message.type === 'idr') {
      me.wantKey = true;
    } else if (message.type === 'stats') {
      // What the TV reports once a second, for anyone who asks how the cast is going.
      me.stats = message;
    } else if (message.type === 'error') {
      end(message.message || 'The TV couldn’t play the stream.');
    } else if (message.type === 'remote') {
      // The iPhone remote, through the TV. The extension checks the command again before acting on it.
      chrome.runtime.sendMessage({ type: 'remoteCommand', command: message }).catch(() => {});
    }
  };
  socket.send(JSON.stringify({ type: 'throwcast', name: 'Chrome' }));

  me.encoder = new VideoEncoder({
    output: (chunk) => {
      if (cast !== me || socket.readyState !== WebSocket.OPEN) return;
      const data = new Uint8Array(chunk.byteLength);
      chunk.copyTo(data);
      const at = me.times.get(chunk.timestamp) ?? seconds();
      me.times.delete(chunk.timestamp);
      deliver(packet(1, chunk.type === 'key', at, data));
    },
    error: (problem) => end(`The encoder stopped: ${problem.message}`),
  });
  // H.264 High on the Mac's hardware: 4K at 60 frames a second, measured, and the TV plays it directly.
  me.encoder.configure({ codec: 'avc1.640034', width, height, bitrate, framerate: fps, latencyMode: 'realtime', hardwareAcceleration: 'prefer-hardware', avc: { format: 'annexb' } });

  // The tab's sound, in the 20 ms blocks of 16-bit stereo the TV plays. Capturing it silences the tab
  // on the Mac, so it plays on the TV alone. Built once per cast: Chrome won't load the sound module
  // again in the same page, so a restart with new settings keeps it and only sends somewhere new.
  if (!held.sound) {
    const context = new AudioContext({ sampleRate: 48000 });
    await context.audioWorklet.addModule('pcm-worklet.js');
    const pcm = new AudioWorkletNode(context, 'pcm', { channelCount: 2, channelCountMode: 'explicit' });
    const mute = new GainNode(context, { gain: 0 });
    // The extension's own volume for the TV, on the sound as it leaves Chrome, so a site that keeps
    // resetting its player's volume can't undo it.
    const level = new GainNode(context, { gain: volume });
    context.createMediaStreamSource(media).connect(level).connect(pcm).connect(mute).connect(context.destination);
    // The Mac sleeping with the lid closed can pause the sound; start it again by itself. After a wake a
    // state change isn't always reported, so check now and then too.
    context.onstatechange = () => {
      if (context.state !== 'running' && context.state !== 'closed') context.resume().catch(() => {});
    };
    const watch = setInterval(() => context.state === 'suspended' && context.resume().catch(() => {}), 2000);
    held.sound = { context, pcm, watch, level };
  }
  const { pcm } = held.sound;
  pcm.port.onmessage = (event) => {
    if (cast === me && me.ready && socket.readyState === WebSocket.OPEN) deliver(packet(2, true, seconds() - 0.02, new Uint8Array(event.data)));
  };

  // A copy of the tab's picture for this session, so a restart with new settings never ends the capture.
  media.getVideoTracks()[0].onended = () => end('The tab stopped sharing.');
  me.track = media.getVideoTracks()[0].clone();
  me.reader = new MediaStreamTrackProcessor({ track: me.track }).readable.getReader();
  // Half a 60 FPS frame of slack, so a frame arriving a little early still counts: 30 means exactly every other one.
  const every = 1000 / fps - 8;
  (async () => {
    while (cast === me) {
      const { value: frame, done } = await me.reader.read().catch(() => ({ done: true }));
      if (done) break;
      const now = performance.now();
      // At 30 FPS, every other frame; and never more than the encoder or Wi-Fi can take.
      if (!me.ready || now - me.lastFrame < every || me.encoder.encodeQueueSize > 2 || socket.bufferedAmount > backlog) {
        frame.close();
        continue;
      }
      me.lastFrame = now;
      const shape = tvShape(frame.visibleRect?.width ?? frame.codedWidth, frame.visibleRect?.height ?? frame.codedHeight, width / height);
      shape.x += frame.visibleRect?.x ?? 0;
      shape.y += frame.visibleRect?.y ?? 0;
      let cropped;
      try {
        cropped = new VideoFrame(frame, { visibleRect: shape, timestamp: frame.timestamp });
      } catch {
        cropped = frame.clone();
      }
      frame.close();
      me.times.set(cropped.timestamp, seconds());
      if (me.times.size > 120) me.times.delete(me.times.keys().next().value);
      me.encoder.encode(cropped, { keyFrame: me.wantKey });
      me.wantKey = false;
      cropped.close();
    }
  })();
}

export const streamStats = () => cast?.stats ?? null;

let sentTabState = '';
let sentTabStateAt = 0;

/// What the cast tab is playing, for the iPhone remote through the TV: when it changes, or once a second.
export function sendTabState(state) {
  const socket = cast?.socket;
  if (!cast?.ready || socket?.readyState !== WebSocket.OPEN) return;
  const tab = { type: 'tabState', title: String(state.title ?? '').slice(0, 200), time: +state.time || 0, duration: +state.duration || 0,
    paused: !!state.paused, live: !!state.live, behind: +state.behind || 0, volume: +state.volume, settings: state.settings ?? null };
  const key = JSON.stringify({ ...tab, time: Math.round(tab.time) });
  const now = performance.now();
  if (key === sentTabState && now - sentTabStateAt < 1000) return;
  sentTabState = key;
  sentTabStateAt = now;
  socket.send(JSON.stringify(tab));
}

/// The TV's volume, 0 to 1, straight away and for the rest of this cast.
export function setStreamVolume(value) {
  if (!held) return;
  const level = Math.min(1, Math.max(0, Number(value) || 0));
  held.settings = { ...held.settings, volume: level };
  if (held.sound) held.sound.level.gain.setTargetAtTime(level, held.sound.context.currentTime, 0.03);
}

/// New quality, frame rate or delay while casting: the stream to the TV starts again with them, and the
/// tab stays captured, so there's nothing to press again. The TV reloads for the new stream.
export async function restartStream(changes) {
  if (!held) throw new Error('Nothing is casting.');
  const { settings, onEnd } = held;
  endSession(cast);
  // The TV reloads its page after a stream ends. Connecting before that would reach the old page, which
  // is about to go away; two seconds is past it, and connect() keeps trying while the new page starts.
  await new Promise((resolve) => setTimeout(resolve, 2000));
  if (!held) return;
  await startStream({ ...settings, ...changes }, onEnd);
}

function endSession(me) {
  if (!me) return;
  if (cast === me) cast = undefined;
  me.reader?.cancel().catch(() => {});
  me.track?.stop();
  if (me.encoder && me.encoder.state !== 'closed') me.encoder.close();
  if (me.socket) {
    me.socket.onclose = null;
    me.socket.close();
  }
}

export function stopStream() {
  captured?.getTracks().forEach((track) => track.stop());
  captured = undefined;
  held?.media.getTracks().forEach((track) => track.stop());
  if (held?.sound) {
    clearInterval(held.sound.watch);
    held.sound.pcm.port.onmessage = null;
    held.sound.context.close().catch(() => {});
  }
  held = undefined;
  endSession(cast);
}
