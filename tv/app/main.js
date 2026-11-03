// ES5 only: older Tizen web engines run this file directly.
var PORT = 47120;
var PROBE_PORT = 47121;
var HEADER = 16;

var state = { socket: null, playerReady: false, wasmReady: false, config: null, frames: 0, bytes: 0, errors: 0, video: [], audio: [], clock: null, lastFrameAt: 0, maxGap: 0 };
var dom = {
  idle: document.getElementById('idle'), status: document.getElementById('status'),
  detail: document.getElementById('detail'), hud: document.getElementById('hud')
};

function say(status, detail) {
  dom.status.textContent = status;
  dom.detail.textContent = detail || '';
}

function capabilities() {
  var caps = { type: 'hello', hdr: false };
  try { caps.hdr = webapis.avinfo.isHdrTvSupport(); } catch (e) {}
  return caps;
}

function send(message) {
  if (state.socket && state.socket.readyState === 1) state.socket.send(JSON.stringify(message));
}

var Module = {
  noExitRuntime: true,
  onPlayer: function (message) {
    if (message === 'ready') {
      state.playerReady = true;
      dom.idle.className = 'casting';
      send({ type: 'ready' });
    } else if (message.indexOf('append-error') === 0) {
      state.errors++;
      if (message.indexOf('audio') < 0) state.needsKeyFrame = true;
    } else if (message !== 'closed') {
      send({ type: 'error', message: message });
      say('This TV could not play the stream', message);
    }
  },
  onRuntimeInitialized: function () {
    state.buffer = Module._tc_buffer();
    state.capacity = Module._tc_buffer_size();
    state.wasmReady = true;
    if (state.config) startPlayer();
  }
};

function startPlayer() {
  var c = state.config;
  Module._tc_start(c.width, c.height, c.fps, c.main10 ? 1 : 0);
}

function append(data) {
  var view = new DataView(data);
  var size = data.byteLength - HEADER;
  Module.HEAPU8.set(new Uint8Array(data, HEADER), state.buffer);
  var pts = view.getFloat64(8, true);
  if (view.getUint8(0) === 1) {
    Module._tc_video(size, view.getUint8(1), pts);
    var now = performance.now();
    if (state.lastFrameAt) state.maxGap = Math.max(state.maxGap, now - state.lastFrameAt);
    state.lastFrameAt = now;
    state.frames++;
    state.bytes += size;
  } else {
    Module._tc_audio(size, pts);
  }
}

function onPacket(data) {
  if (state.test) {
    var now = performance.now();
    if (!state.test.start) state.test.start = now;
    state.test.last = now;
    state.test.bytes += data.byteLength;
    return;
  }
  if (!state.playerReady) return;
  var size = data.byteLength - HEADER;
  if (size <= 0 || size > state.capacity) return;
  if (new DataView(data).getUint8(0) === 1) state.video.push(data);
  else state.audio.push(data);
}

function ptsMs(data) {
  return new DataView(data).getFloat64(8, true) * 1000;
}

// The player shows a frame the moment it gets one, but Wi-Fi delivers in bursts and sometimes stalls.
// Playing by timestamp keeps motion even, and the Smooth delay rides out those pauses.
function pump(now) {
  requestAnimationFrame(pump);
  var config = state.config;
  if (!config) return;
  var delay = config.smooth ? 400 : 0;
  var head = state.video.length ? state.video[0] : state.audio[0];
  if (!head) return;
  if (state.clock === null) state.clock = now + delay - ptsMs(head);
  var late = now - (ptsMs(head) + state.clock);
  // A stall outlasted the delay. Pick up from here instead of rushing through old frames.
  if (late > (config.smooth ? 100 : 400)) {
    state.clock = now + (config.smooth ? 0 : delay) - ptsMs(head);
    late = 0;
  }
  // Time lost to a stall comes back too slowly to see.
  if (state.video.length && ptsMs(state.video[state.video.length - 1]) + state.clock - now > delay + 60) state.clock -= 0.25;
  // The screen shows one frame per refresh, so a second one in the same refresh would never be seen.
  var room = late > 20 ? 2 : 1;
  while (room-- && state.video.length && ptsMs(state.video[0]) + state.clock <= now + 4) append(state.video.shift());
  while (state.audio.length && ptsMs(state.audio[0]) + state.clock <= now + 4) append(state.audio.shift());
}

function onMessage(event) {
  if (typeof event.data !== 'string') return onPacket(event.data);
  var message = JSON.parse(event.data);
  if (message.type === 'throwcast') {
    localStorage.setItem('mac', event.target.host);
    event.target.claimed = true;
    state.socket = event.target;
    say('Connecting to ' + (message.name || 'your Mac'));
    send(capabilities());
  } else if (message.type === 'config') {
    if (state.config) return location.reload();
    state.config = message;
    if (state.wasmReady) startPlayer();
  } else if (message.type === 'direct') {
    startDirect(message);
  } else if (message.type === 'directControl') {
    controlDirect(message);
  } else if (message.type === 'directStop') {
    stopDirect();
    location.reload();
  } else if (message.type === 'test') {
    state.test = { bytes: 0, start: 0, last: 0 };
    say('Testing the connection', 'This takes a few seconds');
  } else if (message.type === 'testEnd') {
    send({ type: 'testResult', bytes: state.test.bytes, ms: state.test.last - state.test.start });
    state.test = null;
    say('Looking for your Mac', 'Choose this TV in Throwcast on your Mac');
  } else if (message.type === 'ping') {
    send({ type: 'pong', t: message.t });
  }
}

// Plays a video link with the TV's own player, for videos sent from the browser extension.
function startDirect(message) {
  var player = webapis.avplay;
  // A retry with the next link starts over from a clean player.
  try { player.stop(); player.close(); } catch (e) {}
  state.direct = message;
  var attempt = message.attempt;
  document.getElementById('player').className = 'hidden';
  dom.idle.className = 'casting';
  try {
    player.open(message.url);
    player.setListener({
      onstreamcompleted: function () { send({ type: 'playback', attempt: attempt, state: 'ended' }); player.stop(); },
      onerror: function (error) { send({ type: 'playerError', attempt: attempt, message: 'The TV couldn’t play this video format.' }); say('Trying another way to play this', String(error)); }
    });
    player.setDisplayRect(0, 0, 1920, 1080);
    player.setDisplayMethod('PLAYER_DISPLAY_MODE_LETTER_BOX');
    try { player.setStreamingProperty('SET_MODE_4K', 'TRUE'); } catch (e) {}
    if (message.start > 1) player.seekTo(Math.floor(message.start * 1000));
    player.prepareAsync(function () { player.play(); }, function () {
      send({ type: 'playerError', attempt: attempt, message: 'The TV couldn’t open this video.' });
      say('Trying another way to play this', message.title || '');
    });
  } catch (error) {
    send({ type: 'playerError', attempt: attempt, message: 'The TV refused this video.' });
  }
}

function controlDirect(message) {
  var player = webapis.avplay;
  try {
    if (message.action === 'pause') player.pause();
    else if (message.action === 'play') player.play();
    else if (message.action === 'seek') player.seekTo(Math.floor(message.seconds * 1000));
    else if (message.action === 'jump') {
      var ms = Math.abs(message.seconds * 1000);
      if (message.seconds > 0) player.jumpForward(ms);
      else player.jumpBackward(ms);
    }
  } catch (e) {}
}

function stopDirect() {
  if (!state.direct) return;
  state.direct = null;
  try { webapis.avplay.stop(); webapis.avplay.close(); } catch (e) {}
}

function reportDirect() {
  var player = webapis.avplay;
  try {
    send({ type: 'playback', attempt: state.direct.attempt, state: player.getState().toLowerCase(), time: player.getCurrentTime() / 1000, duration: player.getDuration() / 1000 });
  } catch (e) {}
}

// A cast that ended leaves the video pipeline open, and reloading is the clean way to reset it.
function onClosed() {
  if (state.direct) {
    stopDirect();
    location.reload();
  } else if (state.config) location.reload();
  else { state.socket = null; setTimeout(findMac, 1000); }
}

function connect(host, done) {
  var socket = new WebSocket('ws://' + host + ':' + PORT);
  socket.binaryType = 'arraybuffer';
  socket.host = host;
  var finished = false;
  function finish(ok) {
    if (finished) return;
    finished = true;
    clearTimeout(timer);
    if (!ok) { socket.onclose = socket.onmessage = null; socket.close(); }
    done(ok);
  }
  var timer = setTimeout(function () { finish(false); }, 800);
  socket.onerror = function () { finish(false); };
  socket.onclose = function () { if (finished) onClosed(); else finish(false); };
  socket.onmessage = function (event) {
    onMessage(event);
    if (socket.claimed) finish(true);
  };
}

// Cheap "is a Mac casting to me?" check. Web engines throttle repeated failed WebSockets, HTTP isn't.
function probe(host, done) {
  var request = new XMLHttpRequest();
  var finished = false;
  function finish(ok) {
    if (finished) return;
    finished = true;
    request.abort();
    done(ok);
  }
  request.onload = function () { finish(request.status === 204); };
  request.onerror = request.ontimeout = function () { finish(false); };
  request.timeout = 700;
  request.open('GET', 'http://' + host + ':' + PROBE_PORT + '/throwcast');
  request.send();
}

// ponytail: TV web apps cannot use Bonjour, so scan the /24. Launch payloads or a Samsung
// multiscreen channel would avoid this, but both need a pairing prompt on the TV.
function scan(hosts, done) {
  var next = 0, active = 0, found = false;
  function pump() {
    while (!found && active < 48 && next < hosts.length) {
      (function (host) {
        active++;
        probe(host, function (ok) {
          active--;
          if (ok && !found) {
            found = true;
            connect(host, done);
          } else if (!found) {
            if (next >= hosts.length && !active) done(false);
            else pump();
          }
        });
      })(hosts[next++]);
    }
  }
  if (hosts.length) pump();
  else done(false);
}

function neighbours() {
  var ip = '';
  try { ip = webapis.network.getIp(); } catch (e) {}
  var parts = ip.split('.');
  if (parts.length !== 4) return [];
  var hosts = [];
  for (var i = 1; i < 255; i++) {
    if (String(i) !== parts[3]) hosts.push(parts[0] + '.' + parts[1] + '.' + parts[2] + '.' + i);
  }
  return hosts;
}

// Stay on the last Mac for a while, because a full scan takes seconds and that's almost always the one.
var lastMacTries = 0;

function findMac() {
  if (state.socket) return;
  say('Looking for your Mac', 'Choose this TV in Throwcast on your Mac');
  var last = localStorage.getItem('mac');
  if (last && lastMacTries++ < 15) {
    return probe(last, function (ok) {
      if (ok) connect(last, function (connected) { if (!connected) setTimeout(findMac, 600); });
      else setTimeout(findMac, 600);
    });
  }
  lastMacTries = 0;
  scan(neighbours(), function (ok) { if (!ok) setTimeout(findMac, 500); });
}

function report() {
  if (state.direct) reportDirect();
  if (state.needsKeyFrame) {
    state.needsKeyFrame = false;
    send({ type: 'idr' });
  }
  // Timers run late on a busy TV, and dividing by a fixed second would show that as lost frames.
  var at = performance.now();
  var seconds = state.reportedAt ? (at - state.reportedAt) / 1000 : 1;
  state.reportedAt = at;
  var line = { type: 'stats', fps: state.frames / seconds, mbps: state.bytes * 8 / 1e6 / seconds, errors: state.errors, maxGapMs: state.maxGap };
  state.frames = state.bytes = state.errors = state.maxGap = 0;
  if (state.playerReady) {
    send(line);
    if (!dom.hud.hidden && state.config) {
      dom.hud.textContent = state.config.width + ' x ' + state.config.height + (state.config.hdr ? '  HDR' : '  SDR') + '\n' +
        Math.round(line.fps) + ' fps   ' + line.mbps.toFixed(1) + ' Mbps';
    }
  }
}

document.addEventListener('keydown', function (event) {
  if (event.keyCode === 10009) {
    stopDirect();
    try { tizen.application.getCurrentApplication().exit(); } catch (e) { window.close(); }
  } else if (event.keyCode === 13 || event.keyCode === 457) {
    dom.hud.hidden = !dom.hud.hidden;
  }
});

document.addEventListener('visibilitychange', function () {
  if (document.hidden && state.socket) state.socket.close();
});

try { webapis.appcommon.setScreenSaver(webapis.appcommon.AppCommonScreenSaverState.SCREEN_SAVER_OFF); } catch (e) {}
setInterval(report, 1000);
requestAnimationFrame(pump);
findMac();
