// ES5 only: older Tizen web engines run this file directly.
var PORT = 47120;
var PROBE_PORT = 47121;
var HEADER = 16;

var state = { lost: 0, socket: null, playerReady: false, wasmReady: false, config: null, frames: 0, bytes: 0, errors: 0, video: [], audio: [], clock: null, lastFrameAt: 0, maxGap: 0 };
var dom = {
  idle: document.getElementById('idle'), status: document.getElementById('status'),
  detail: document.getElementById('detail'), hud: document.getElementById('hud')
};

// A fresh page is the clean way to reset the video pipeline. The browser listener closes its port first,
// because the TV keeps a reloaded page's sockets open; 300 ms gives its thread time to notice.
function reload() {
  try { Module._tc_ws_stop(); } catch (e) {}
  setTimeout(function () { location.reload(); }, 300);
}

function say(status, detail) {
  dom.status.textContent = status;
  dom.detail.textContent = detail || '';
}

function capabilities() {
  // udp: this app can receive the stream over UDP, so the Mac may choose it.
  var caps = { type: 'hello', hdr: false, udp: true };
  try { caps.hdr = webapis.avinfo.isHdrTvSupport(); } catch (e) {}
  return caps;
}

function send(message) {
  if (state.socket && state.socket.readyState === 1) state.socket.send(JSON.stringify(message));
}

var Module = {
  noExitRuntime: true,
  onPlayer: function (message) {
    if (message === 'udp-ready') {
      return;
    } else if (message === 'ready') {
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
    state.wsIn = Module._tc_ws_start();
    state.phoneIn = Module._tc_remote_start();
    if (state.config) startPlayer();
  }
};

function startPlayer() {
  var c = state.config;
  Module._tc_start(c.width, c.height, c.fps, c.main10 ? 1 : 0, c.codec === 'h264' ? 1 : 0);
  // Over UDP the stream comes in on a background thread in the player; this side collects it.
  if (c.udp && state.socket) {
    var parts = state.socket.host.split('.');
    var mac = ((+parts[0] << 24) >>> 0) + (+parts[1] << 16) + (+parts[2] << 8) + +parts[3];
    state.udpOut = Module._tc_udp_start(mac, c.delay != null ? c.delay : (c.smooth ? 400 : 33));
    state.udp = true;
  }
}

// Frames rebuilt from UDP, in order, handed over the same way WebSocket frames are.
function collectUdp(now) {
  // The Mac keeps using the WebSocket until it hears which port the receiver got.
  if (!state.udpAnnounced && Module._tc_udp_port() > 0) {
    state.udpAnnounced = true;
    send({ type: 'udp', port: Module._tc_udp_port() });
  }
  var size;
  while ((size = Module._tc_udp_next()) > 0) onPacket(Module.HEAPU8.slice(state.udpOut, state.udpOut + size).buffer);
  var lost = Module._tc_udp_lost();
  if (!lost) return;
  state.lost += lost;
  // Frames after a lost one would show broken, so the picture holds until a fresh key frame.
  state.waitForKey = true;
  if (!state.askedForKeyAt || now - state.askedForKeyAt > 250) {
    state.askedForKeyAt = now;
    send({ type: 'idr' });
  }
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
  var view = new DataView(data);
  if (view.getUint8(0) === 1) {
    if (state.waitForKey) {
      if (!view.getUint8(1)) return;
      state.waitForKey = false;
    }
    state.video.push(data);
  }
  else state.audio.push(data);
}

function ptsMs(data) {
  return new DataView(data).getFloat64(8, true) * 1000;
}

// The browser extension, streaming without the Mac app. The player's C++ holds its WebSocket, because a TV
// web app can't accept one itself; this side treats it like the Mac's connection, through the same messages.
function browserSocket() {
  return {
    readyState: 1, host: '', browser: true,
    send: function (text) { Module.ccall('tc_ws_send', null, ['string'], [text]); },
    close: function () { Module._tc_ws_close(); }
  };
}

function collectBrowser() {
  if (!state.wsIn) return;
  // An ended connection first, so a browser that reconnects straight away is seen as new.
  if (Module._tc_ws_closed() && state.browser) {
    var was = state.browser;
    state.browser = null;
    if (state.socket === was) onClosed();
  }
  if (Module._tc_ws_opened()) state.browser = browserSocket();
  var size;
  while (state.browser && (size = Module._tc_ws_next()) > 0) {
    var data = Module._tc_ws_text() ? Module.UTF8ToString(state.wsIn) : Module.HEAPU8.slice(state.wsIn, state.wsIn + size).buffer;
    onMessage({ target: state.browser, data: data });
  }
}

// The player shows a frame the moment it gets one, but Wi-Fi delivers in bursts and sometimes stalls.
// Playing by timestamp keeps motion even, and the Smooth delay rides out those pauses.
function pump(now) {
  requestAnimationFrame(pump);
  collectBrowser();
  collectPhones();
  var config = state.config;
  if (!config) return;
  if (state.udp) collectUdp(now);
  var delay = config.delay != null ? config.delay : (config.smooth ? 400 : 0);
  var head = state.video.length ? state.video[0] : state.audio[0];
  if (!head) return;
  if (state.clock === null) state.clock = now + delay - ptsMs(head);
  var late = now - (ptsMs(head) + state.clock);
  // A stall outlasted the delay. Pick up from here instead of rushing through old frames.
  if (late > 100) {
    state.clock = now + delay - ptsMs(head);
    late = 0;
  }
  // Time lost to a stall comes back too slowly to see.
  // Short buffers catch up faster, so Instant stays instant.
  if (state.video.length && ptsMs(state.video[state.video.length - 1]) + state.clock - now > delay + 60) state.clock -= delay < 100 ? 1 : 0.25;
  // The screen shows one frame per refresh, so a second one in the same refresh would never be seen.
  var room = late > 20 ? 2 : 1;
  while (room-- && state.video.length && ptsMs(state.video[0]) + state.clock <= now + 4) append(state.video.shift());
  while (state.audio.length && ptsMs(state.audio[0]) + state.clock <= now + 4) append(state.audio.shift());
}

function onMessage(event) {
  // One sender at a time, Mac or browser: whoever connected first keeps the TV until their cast ends.
  // Anything from another connection is refused, so two can never feed the player at once.
  if (state.socket && event.target !== state.socket) {
    event.target.onclose = event.target.onmessage = null;
    event.target.close();
    return;
  }
  if (typeof event.data !== 'string') return onPacket(event.data);
  var message = JSON.parse(event.data);
  if (message.type === 'throwcast') {
    // Only a Mac is worth looking for again after a reload; a browser connects to the TV by itself.
    if (!event.target.browser) localStorage.setItem('mac', event.target.host);
    event.target.claimed = true;
    state.socket = event.target;
    say('Connecting to ' + (message.name || 'your Mac'));
    send(capabilities());
  } else if (message.type === 'config') {
    if (state.config) return reload();
    state.config = message;
    if (state.wasmReady) startPlayer();
  } else if (message.type === 'direct') {
    startDirect(message);
  } else if (message.type === 'directControl') {
    controlDirect(message);
  } else if (message.type === 'directStop') {
    stopDirect();
    reload();
  } else if (message.type === 'test') {
    state.test = { bytes: 0, start: 0, last: 0 };
    say('Testing the connection', 'This takes a few seconds');
  } else if (message.type === 'testEnd') {
    send({ type: 'testResult', bytes: state.test.bytes, ms: state.test.last - state.test.start });
    state.test = null;
    say('Looking for your Mac', 'Choose this TV in Throwcast on your Mac');
  } else if (message.type === 'ping') {
    send({ type: 'pong', t: message.t });
  } else if (message.type === 'tabState' && event.target.browser) {
    // What the extension's cast tab is playing, for the iPhone remote.
    state.tab = message;
    toPhones(tabEvent());
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
    reload();
  } else if (state.config) reload();
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
  var line = { type: 'stats', lost: state.lost, fps: state.frames / seconds,
    udp: state.udp ? { state: Module._tc_udp_state(), in: Module._tc_udp_in(), refused: Module._tc_udp_refused(), frames: Module._tc_udp_frames(), asked: Module._tc_udp_asked() } : undefined, mbps: state.bytes * 8 / 1e6 / seconds, errors: state.errors, maxGapMs: state.maxGap };
  state.frames = state.bytes = state.errors = state.maxGap = state.lost = 0;
  remoteReport(line);
  if (state.playerReady) {
    send(line);
    if (!dom.hud.hidden && state.config) {
      dom.hud.textContent = state.config.width + ' x ' + state.config.height + (state.config.hdr ? '  HDR' : '  SDR') + '\n' +
        Math.round(line.fps) + ' fps   ' + line.mbps.toFixed(1) + ' Mbps';
    }
  }
}

// The iPhone remote, for casts from the browser extension alone (with the Mac app, the phone talks to the
// Mac). The player's C++ holds the phones' WebSockets; pairing, the allow-list and everything else are here.
// A phone pairs by typing the code this TV shows, so whoever pairs can see the screen. After that it has a
// token. It can play, pause, seek, change the volume and stop: never send a link to play.
var PHONE_COMMANDS = { hello: 1, tabControl: 1, volume: 1, endTab: 1, stop: 1, look: 1, size: 1, stream: 1 };
var phones = {};          // id -> { trusted, name }
var pairing = null;       // { code, until, tries }
var pairLockedUntil = 0;
var tvInfo = { name: 'TV', width: 3840, height: 2160, host: '' };
var lastCastState = '';

function fetchTvInfo() {
  try { tvInfo.host = webapis.network.getIp(); } catch (e) {}
  var request = new XMLHttpRequest();
  request.onload = function () {
    try {
      var device = JSON.parse(request.responseText).device;
      tvInfo.name = device.name || tvInfo.name;
      var size = /(\d+)x(\d+)/.exec(device.resolution || '');
      if (size) { tvInfo.width = +size[1]; tvInfo.height = +size[2]; }
    } catch (e) {}
  };
  request.timeout = 2000;
  request.open('GET', 'http://127.0.0.1:8001/api/v2/');
  try { request.send(); } catch (e) {}
}

function pairedPhones() {
  try { return JSON.parse(localStorage.getItem('phones') || '{}'); } catch (e) { return {}; }
}

function forgetPhones() {
  localStorage.removeItem('phones');
  for (var id in phones) Module._tc_remote_drop(+id);
  say('Phones forgotten', 'Pair your iPhone again from Throwcast Remote');
}

function newToken() {
  var bytes = new Uint8Array(32);
  crypto.getRandomValues(bytes);
  var out = '';
  for (var i = 0; i < bytes.length; i++) out += (bytes[i] < 16 ? '0' : '') + bytes[i].toString(16);
  return out;
}

function toPhone(id, event) {
  Module.ccall('tc_remote_send', null, ['number', 'string'], [id, JSON.stringify(event)]);
}

function toPhones(event) {
  for (var id in phones) if (phones[id].trusted) toPhone(+id, event);
}

function macCasting() { return !!(state.socket && !state.socket.browser); }

function castState() {
  if (macCasting()) return 'stopped';
  if (state.socket && state.socket.browser && state.config) return state.playerReady ? 'casting' : 'connecting';
  return 'stopped';
}

function tabEvent() {
  var t = state.tab;
  return { event: 'tabState', title: t.title || 'This tab', time: t.time || 0, duration: t.duration || 0,
    paused: !!t.paused, live: !!t.live, behind: t.behind || 0, volume: t.volume, settings: t.settings || null };
}

function showPairing(name) {
  var now = Date.now();
  if (!pairing || now > pairing.until) {
    var code = '';
    var bytes = new Uint8Array(6);
    crypto.getRandomValues(bytes);
    for (var i = 0; i < 6; i++) code += String(bytes[i] % 10);
    pairing = { code: code, until: now + 60000, tries: 3 };
  }
  document.getElementById('pair-title').textContent = 'Allow ' + name + ' to control Throwcast';
  document.getElementById('pair-code').textContent = pairing.code.slice(0, 3) + ' ' + pairing.code.slice(3);
  document.getElementById('pair').hidden = false;
  clearTimeout(pairing.timer);
  pairing.timer = setTimeout(hidePairing, pairing.until - now);
}

function hidePairing() {
  document.getElementById('pair').hidden = true;
  if (pairing) clearTimeout(pairing.timer);
  pairing = null;
}

function admit(id) {
  phones[id].trusted = true;
  toPhone(id, { event: 'welcome', mac: tvInfo.name, kind: 'tv' });
  toPhone(id, { event: 'tv', host: tvInfo.host, name: tvInfo.name, width: tvInfo.width, height: tvInfo.height });
  toPhone(id, { event: 'state', state: castState() });
  if (macCasting()) toPhone(id, { event: 'remoteStatus', message: 'Your Mac is casting. Control it from the Mac.' });
  if (state.tab && castState() !== 'stopped') toPhone(id, tabEvent());
}

function onPhone(id, text) {
  var phone = phones[id];
  var message;
  try { message = JSON.parse(text); } catch (e) { return; }
  if (!phone || !message || !PHONE_COMMANDS[message.cmd]) return;
  if (message.cmd === 'hello') return phoneHello(id, message);
  if (!phone.trusted) return toPhone(id, { event: 'needsPairing', enterCode: true });
  // One control point per cast: a Mac's cast is the Mac's.
  if (macCasting()) return toPhone(id, { event: 'remoteStatus', message: 'Your Mac is casting. Control it from the Mac.' });
  if (!(state.socket && state.socket.browser)) return;
  if (message.cmd === 'endTab' || message.cmd === 'stop') {
    // The extension ends its cast when its socket closes, so this works with any version of it.
    state.socket.close();
  } else if (message.cmd === 'volume' || (message.cmd === 'tabControl' && typeof message.volume === 'number')) {
    send({ type: 'remote', cmd: 'tabControl', volume: Math.max(0, Math.min(1, +message.volume || 0)) });
  } else if (message.cmd === 'look' && message.look && typeof message.look === 'object') {
    var look = {}, keys = ['brightness', 'contrast', 'saturation', 'warmth', 'gamma'];
    for (var i = 0; i < keys.length; i++) look[keys[i]] = +message.look[keys[i]];
    send({ type: 'remote', cmd: 'look', look: look });
  } else if (message.cmd === 'size' && /^(contain|cover|fill)$/.test(message.size)) {
    send({ type: 'remote', cmd: 'size', size: message.size });
  } else if (message.cmd === 'stream' && message.changes && typeof message.changes === 'object') {
    var c = message.changes, changes = {};
    if (c.quality !== undefined) changes.quality = String(c.quality);
    if (c.bitrate !== undefined) changes.bitrate = c.bitrate === 'auto' ? 'auto' : +c.bitrate;
    if (c.fps !== undefined) changes.fps = +c.fps;
    if (c.delay !== undefined) changes.delay = +c.delay;
    send({ type: 'remote', cmd: 'stream', changes: changes });
  } else if (message.cmd === 'tabControl' && /^(play|pause|seek|jump|live|next|previous)$/.test(message.action)) {
    var command = { type: 'remote', cmd: 'tabControl', action: message.action };
    if (typeof message.seconds === 'number' && isFinite(message.seconds)) command.seconds = message.seconds;
    send(command);
  }
}

function phoneHello(id, message) {
  var phone = phones[id];
  phone.name = String(message.name || 'An iPhone').slice(0, 60);
  var paired = pairedPhones();
  if (message.token && paired[message.token]) return admit(id);
  var now = Date.now();
  if (now < pairLockedUntil) return toPhone(id, { event: 'pairingRefused', triesLeft: 0, wait: Math.ceil((pairLockedUntil - now) / 1000) });
  if (message.code && pairing && now < pairing.until) {
    if (String(message.code) === pairing.code) {
      hidePairing();
      var token = newToken();
      paired[token] = phone.name;
      // At most 8 phones; the oldest goes first.
      var tokens = Object.keys(paired);
      while (tokens.length > 8) delete paired[tokens.shift()];
      localStorage.setItem('phones', JSON.stringify(paired));
      toPhone(id, { event: 'paired', token: token });
      return admit(id);
    }
    if (--pairing.tries <= 0) {
      hidePairing();
      pairLockedUntil = now + 30000;
      return toPhone(id, { event: 'pairingRefused', triesLeft: 0, wait: 30 });
    }
    return toPhone(id, { event: 'pairingRefused', triesLeft: pairing.tries });
  }
  showPairing(phone.name);
  toPhone(id, { event: 'needsPairing', enterCode: true });
}

function collectPhones() {
  if (!state.phoneIn) return;
  var event;
  while ((event = Module._tc_remote_event())) {
    if (event > 0) phones[event] = { trusted: false, name: 'An iPhone' };
    else delete phones[-event];
  }
  var size;
  while ((size = Module._tc_remote_next()) > 0) onPhone(Module._tc_remote_from(), Module.UTF8ToString(state.phoneIn));
}

// Once a second: the cast's state when it changes, and its numbers while it runs.
function remoteReport(line) {
  if (!state.phoneIn) return;
  var now = castState();
  if (now !== lastCastState) {
    lastCastState = now;
    toPhones({ event: 'state', state: now });
  }
  if (now === 'casting') toPhones({ event: 'stats', fps: line.fps, mbps: line.mbps });
}

document.addEventListener('keydown', function (event) {
  if (event.keyCode === 10009) {
    stopDirect();
    try { tizen.application.getCurrentApplication().exit(); } catch (e) { window.close(); }
  } else if (event.keyCode === 13 || event.keyCode === 457) {
    dom.hud.hidden = !dom.hud.hidden;
  } else if (event.keyCode === 403 && !state.socket) {
    forgetPhones();
  }
});

document.addEventListener('visibilitychange', function () {
  if (document.hidden && state.socket) state.socket.close();
});

try { webapis.appcommon.setScreenSaver(webapis.appcommon.AppCommonScreenSaverState.SCREEN_SAVER_OFF); } catch (e) {}
try { tizen.tvinputdevice.registerKey('ColorF0Red'); } catch (e) {}
setInterval(report, 1000);
fetchTvInfo();
requestAnimationFrame(pump);
findMac();
