import { pageCrop, sameWindow } from './geometry.js';
import { connect } from './stream.js';

// Watches this tab's network traffic for real video links. Nothing leaves the browser until you press Play.
const PATTERNS = [
  { kind: 'HLS', rank: 3, url: /\.m3u8(\?|$)/i, type: /mpegurl/i },
  { kind: 'DASH', rank: 2, url: /\.mpd(\?|$)/i, type: /dash\+xml/i },
  { kind: 'Video file', rank: 1, url: /\.(mp4|m4v|mov|webm)(\?|$)/i, type: /^video\/(mp4|webm|quicktime)/i },
];
const SKIP = /\.(ts|m4s|m4a|aac|vtt|key)(\?|$)|[/_-]audio[/_.-]/i;
const key = (tabId) => `videos:${tabId}`;

function classify(url, contentType) {
  if (SKIP.test(url) || !/^https?:/i.test(url)) return null;
  return PATTERNS.find((p) => p.url.test(url) || p.type.test(contentType)) ?? null;
}

// Sites often serve a video only to the browser that asked, so these go along with the link.
const requestHeaders = new Map();
const WANTED = new Set(['referer', 'origin', 'user-agent', 'cookie', 'authorization']);

chrome.webRequest.onSendHeaders.addListener(
  (details) => {
    if (details.tabId < 0) return;
    const kept = {};
    for (const header of details.requestHeaders ?? []) {
      if (WANTED.has(header.name.toLowerCase())) kept[header.name] = header.value;
    }
    requestHeaders.set(details.requestId, kept);
    if (requestHeaders.size > 500) requestHeaders.delete(requestHeaders.keys().next().value);
  },
  { urls: ['<all_urls>'], types: ['media', 'xmlhttprequest', 'other'] },
  ['requestHeaders', 'extraHeaders'],
);

async function remember(tabId, video) {
  const name = key(tabId);
  const list = (await chrome.storage.session.get(name))[name] ?? [];
  const path = video.url.split('?')[0];
  if (list.some((v) => v.url.split('?')[0] === path)) return;
  list.push(video);
  await chrome.storage.session.set({ [name]: list.slice(-20) });
  chrome.action.setBadgeBackgroundColor({ tabId, color: '#0A84FF' });
  chrome.action.setBadgeText({ tabId, text: String(list.length) });
}

chrome.webRequest.onHeadersReceived.addListener(
  (details) => {
    if (details.tabId < 0) return;
    const header = (name) => details.responseHeaders?.find((h) => h.name.toLowerCase() === name)?.value ?? '';
    const match = classify(details.url, header('content-type'));
    if (!match) return;
    // Short clips and ad pings aren't what anyone wants on a TV.
    const bytes = Number(header('content-length')) || 0;
    if (match.rank === 1 && bytes > 0 && bytes < 1_000_000) return;
    remember(details.tabId, { url: details.url, kind: match.kind, rank: match.rank, bytes, headers: requestHeaders.get(details.requestId) ?? {} });
  },
  { urls: ['<all_urls>'], types: ['media', 'xmlhttprequest', 'other'] },
  ['responseHeaders'],
);

chrome.webRequest.onCompleted.addListener((details) => requestHeaders.delete(details.requestId), { urls: ['<all_urls>'] });

chrome.tabs.onUpdated.addListener((tabId, change) => {
  if (change.url) {
    chrome.storage.session.remove(key(tabId));
    chrome.action.setBadgeText({ tabId, text: '' });
  }
});

chrome.tabs.onRemoved.addListener(async (tabId) => {
  chrome.storage.session.remove(key(tabId));
  // Closing the tab on the TV ends the cast.
  const { castingTab } = await chrome.storage.local.get('castingTab');
  if (castingTab?.tabId === tabId) await endTabCast(castingTab);
});

const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

// --- Casting a tab to the TV --------------------------------------------------------------------------
// The extension does this by itself: it captures the tab, encodes it on the Mac's hardware and streams it
// to the Throwcast TV app. It needs nothing else on the Mac.

const RECEIVER = 'Thrwcast4K.Receiver';

/// A Samsung TV's own answer about itself, or null. Every Samsung TV from 2016 on answers on port 8001.
async function askTv(host, ms = 1500) {
  const answer = await fetch(`http://${host}:8001/api/v2/`, { signal: AbortSignal.timeout(ms) }).then((r) => r.json()).catch(() => null);
  const device = answer?.device;
  if (!device || device.type !== 'Samsung SmartTV') return null;
  const [width, height] = String(device.resolution ?? '3840x2160').split('x').map(Number);
  return { name: device.name ?? 'Samsung TV', host, width: width || 3840, height: height || 2160 };
}

/// Samsung TVs on this network. A browser can't learn its own address, so this first finds which of the
/// networks home routers use is the one here: on it, an address with nothing listening refuses at once,
/// while a network that isn't here just times out. Then it asks every address on that network, a few
/// dozen at a time, because Chrome holds back new connections while many are still waiting.
// ponytail: common home networks only; typing the TV's address covers any other.
async function findTvs() {
  const { tv } = await chrome.storage.local.get('tv');
  const prefixes = ['192.168.1', '192.168.0', '10.0.0', '10.0.1', '192.168.86', '192.168.68', '192.168.50', '172.16.0'];
  const mine = tv?.host?.split('.').slice(0, 3).join('.');
  if (mine && !prefixes.includes(mine)) prefixes.unshift(mine);
  const here = await Promise.all(prefixes.map((prefix) =>
    fetch(`http://${prefix}.1:8001/`, { signal: AbortSignal.timeout(1200) }).then(() => prefix, (e) => (e.name === 'TimeoutError' ? null : prefix))));
  const networks = here.filter(Boolean);
  const hosts = networks.flatMap((prefix) => Array.from({ length: 253 }, (_, i) => `${prefix}.${i + 2}`));
  const found = [];
  for (let start = 0; start < hosts.length; start += 48) {
    found.push(...(await Promise.all(hosts.slice(start, start + 48).map((host) => askTv(host, 1500)))).filter(Boolean));
  }
  return found;
}

/// The TV to cast to: the one chosen in the extension, if it still answers.
async function chosenTv() {
  const { tv } = await chrome.storage.local.get('tv');
  return tv?.host ? askTv(tv.host) : null;
}

/// Opens Throwcast on the TV. The TV can answer 200 without starting it, so this checks.
async function openReceiver(host) {
  const url = `http://${host}:8001/api/v2/applications/${RECEIVER}`;
  const before = await fetch(url, { signal: AbortSignal.timeout(3000) }).catch(() => null);
  if (before?.status === 404) throw new Error('Throwcast isn’t installed on this TV yet.');
  for (let i = 0; i < 4; i++) {
    await fetch(url, { method: 'POST', signal: AbortSignal.timeout(4000) }).catch(() => {});
    await wait(1500);
    const now = await fetch(url, { signal: AbortSignal.timeout(3000) }).then((r) => r.json()).catch(() => null);
    if (now?.running) return;
  }
  throw new Error('Couldn’t open Throwcast on the TV. Open it from the TV’s Apps screen, then try again.');
}

/// Pages opened before the extension last reloaded have no working script.
async function prepare(tabId) {
  if (await chrome.tabs.sendMessage(tabId, 'ping').catch(() => false)) return;
  await chrome.scripting.executeScript({ target: { tabId, allFrames: true }, files: ['fullscreen.js'], world: 'MAIN' }).catch(() => {});
  await chrome.scripting.executeScript({ target: { tabId, allFrames: true }, files: ['content.js'] }).catch(() => {});
}

async function castTab(tabId, streamId) {
  if (!streamId) throw new Error('Chrome didn’t allow this tab to be captured. Press the extension’s button again.');
  // Capture first: Chrome's permission to capture the tab runs out within seconds, and opening the TV
  // can take longer than that.
  if (!(await chrome.offscreen.hasDocument())) {
    await chrome.offscreen.createDocument({ url: 'offscreen.html', reasons: ['USER_MEDIA'], justification: 'Captures the cast tab and sends it to the TV.' });
  }
  const captured = await chrome.runtime.sendMessage({ type: 'streamCapture', streamId });
  if (captured?.error) throw new Error(captured.error);
  const tv = await chosenTv();
  if (!tv) throw new Error('Your TV didn’t answer. Make sure it’s on and on the same Wi-Fi, or choose it again.');
  await prepare(tabId);
  await openReceiver(tv.host);
  const { quality = '4k', delay = 400, fps = 60, bitrate = 'auto', castVolume = 1 } = await chrome.storage.local.get(['quality', 'delay', 'fps', 'bitrate', 'castVolume']);
  const reply = await chrome.runtime.sendMessage({ type: 'streamStart', tv, quality, delay, fps, bitrate, volume: castVolume });
  if (reply?.error) throw new Error(reply.error);
  const tab = await chrome.tabs.get(tabId);
  await chrome.storage.local.set({ castingTab: { tabId, title: tab.title, standalone: true, tv: tv.name } });
  // The page works as usual on the TV; full screen, or Fill in the extension, fills the TV with the video.
  const { pictureSize = 'cover', look = null } = await chrome.storage.local.get(['pictureSize', 'look']);
  await chrome.tabs.sendMessage(tabId, { watch: 'tab' }).catch(() => {});
  await chrome.tabs.sendMessage(tabId, { fit: pictureSize }).catch(() => {});
  await chrome.tabs.sendMessage(tabId, { look }).catch(() => {});
}

/// How fast and quick the Wi-Fi to the TV is, the way the Mac app's Wi-Fi Check measures it: the round
/// trip first, then as much data as the connection takes for 3 seconds. Suggests 60% of that as the
/// bitrate, in 5 Mbps steps, so the stream has headroom for Wi-Fi's dips.
async function testWifi() {
  const tv = await chosenTv();
  if (!tv) throw new Error('Your TV didn’t answer. Make sure it’s on and on the same Wi-Fi, or choose it again.');
  await openReceiver(tv.host);
  const socket = await connect(tv.host);
  const next = (type) => new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('The TV stopped answering during the test.')), 8000);
    socket.onmessage = (event) => {
      if (typeof event.data !== 'string') return;
      const message = JSON.parse(event.data);
      if (message.type === type) {
        clearTimeout(timer);
        resolve(message);
      }
    };
  });
  try {
    socket.send(JSON.stringify({ type: 'throwcast', name: 'Chrome' }));
    await next('hello');
    const rtts = [];
    for (let i = 0; i < 5; i++) {
      const sent = performance.now();
      socket.send(JSON.stringify({ type: 'ping', t: sent }));
      await next('pong');
      rtts.push(performance.now() - sent);
    }
    socket.send(JSON.stringify({ type: 'test' }));
    // 64 KB pieces: the TV holds what arrives until its page collects it, each screen refresh.
    const chunk = new Uint8Array(64 * 1024);
    const until = performance.now() + 3000;
    while (performance.now() < until) {
      // Keep a little queued, but never more than the connection can carry.
      if (socket.bufferedAmount < 16 * chunk.length) socket.send(chunk);
      else await wait(2);
    }
    while (socket.bufferedAmount > 0 && performance.now() < until + 3000) await wait(10);
    socket.send(JSON.stringify({ type: 'testEnd' }));
    const result = await next('testResult');
    const mbps = result.ms > 0 ? (result.bytes * 8) / (result.ms * 1000) : 0;
    rtts.sort((a, b) => a - b);
    const recommended = Math.max(5, Math.min(100, Math.floor((mbps * 0.6) / 5) * 5));
    return { mbps: Math.round(mbps), rttMs: Math.round(rtts[rtts.length >> 1]), recommended };
  } finally {
    socket.close();
  }
}

/// Nothing stays running once a cast ends, or fails to start: the capture page closes.
async function closeCapture() {
  await chrome.runtime.sendMessage({ type: 'streamStop' }).catch(() => {});
  if (await chrome.offscreen.hasDocument()) await chrome.offscreen.closeDocument().catch(() => {});
}

async function endTabCast(castingTab) {
  await chrome.storage.local.remove('castingTab');
  chrome.tabs.sendMessage(castingTab.tabId, 'unfit').catch(() => {});
  await closeCapture();
}

// --- Extras when the Throwcast Mac app is also open -----------------------------------------------
// The app can cast a whole browser window with One Window. Then the tab showing in that window gets the
// same full-screen fill and play controls as a cast tab. None of this is needed to cast a tab.

const API = 'http://127.0.0.1:47122';

async function post(path, body) {
  const response = await fetch(API + path, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body ?? {}) });
  const json = await response.json();
  if (!response.ok) throw new Error(json.error ?? 'Throwcast couldn’t do that.');
  return json;
}

// The crop last sent for a window cast, so it's only sent when the fill changes.
let windowCrop = '';

// The app's status, at most once a second however many tabs ask.
let status = { at: 0, value: null };
async function appStatus() {
  if (Date.now() - status.at > 1000) {
    status = { at: Date.now(), value: await fetch(API + '/status', { signal: AbortSignal.timeout(800) }).then((r) => r.json()).catch(() => null) };
  }
  return status.value;
}

/// The app is showing this browser window with One Window, and this is the tab on screen in it.
async function inCastWindow(tab) {
  if (!tab?.active) return null;
  const cast = (await appStatus())?.castWindow;
  if (!cast) windowCrop = '';
  const window = cast && (await chrome.windows.get(tab.windowId).catch(() => null));
  if (!window) return null;
  return sameWindow(window, cast, tab.title) ? window : null;
}

// --- Messages -------------------------------------------------------------------------------------------

/// 'cover' or 'contain' for the cast tab, 'window' for a tab in a window the app casts with One Window.
async function castMode(tab) {
  const { castingTab, pictureSize = 'cover' } = await chrome.storage.local.get(['castingTab', 'pictureSize']);
  if (castingTab?.tabId === tab?.id) return 'tab';
  if (await inCastWindow(tab)) return 'window';
  return (await onCastScreen(tab)) ? 'screen' : null;
}

/// The app is casting the whole screen, and this is the tab showing in the browser window used last:
/// the one you're watching. Its playback is reported, but nothing on the page changes.
async function onCastScreen(tab) {
  if (!tab?.active || !(await appStatus())?.castScreen) return false;
  const last = await chrome.windows.getLastFocused({ windowTypes: ['normal'] }).catch(() => null);
  return last?.id === tab.windowId;
}

async function checkIn(state, tab) {
  const { castingTab, pictureSize = 'cover' } = await chrome.storage.local.get(['castingTab', 'pictureSize']);
  // A cast tab's controls are in the extension, which asks the tab directly. Its state also goes to the TV,
  // for the iPhone remote.
  if (castingTab?.tabId === tab.id) {
    const saved = await chrome.storage.local.get(['castVolume', 'look', 'quality', 'bitrate', 'fps', 'delay']);
    const settings = { look: saved.look ?? null, size: pictureSize, quality: saved.quality ?? '4k', bitrate: String(saved.bitrate ?? 'auto'), fps: saved.fps ?? 60, delay: saved.delay ?? 400 };
    chrome.runtime.sendMessage({ type: 'streamTabState', state: { title: tab.title, time: state.time, duration: state.duration, paused: state.paused, live: state.live, behind: state.behind, volume: saved.castVolume ?? 1, settings } }).catch(() => {});
    return;
  }
  const window = await inCastWindow(tab);
  if (!window && !(await onCastScreen(tab))) return chrome.tabs.sendMessage(tab.id, 'unfit').catch(() => {});
  if (!window) {
    // A whole-screen cast: playback and controls only; the screen itself is what the TV shows.
    const { commands = [] } = await post('/tabState', { title: tab.title, time: state.time, duration: state.duration, paused: state.paused, volume: state.volume, live: state.live, behind: state.behind, start: state.start, size: pictureSize });
    for (const command of commands) {
      if (command.stop) await post('/control', { action: 'stop' }).catch(() => {});
      else runTabCommand(tab.id, command);
    }
    return;
  }
  // While its video fills the page, the TV shows only the page; otherwise the whole window.
  const crop = state.filled ? pageCrop(window, tab) : { x: 0, y: 0, width: window.width, height: window.height };
  const cropKey = JSON.stringify(crop);
  if (cropKey !== windowCrop) {
    windowCrop = cropKey;
    await post('/windowCrop', { crop }).catch(() => {});
  }
  const { commands = [] } = await post('/tabState', { title: tab.title, time: state.time, duration: state.duration, paused: state.paused, volume: state.volume, live: state.live, behind: state.behind, start: state.start, size: pictureSize });
  for (const command of commands) {
    if (command.stop) await post('/control', { action: 'stop' }).catch(() => {});
    else runTabCommand(tab.id, command);
  }
}

/// Play, pause, seek, jump or a volume, for the tab playing on the TV.
function runTabCommand(tabId, command) {
  if (command.action) chrome.tabs.sendMessage(tabId, command.action === 'seek' ? { seek: command.seconds } : command.action === 'jump' ? { jump: command.seconds } : command.action).catch(() => {});
  else if (command.volume !== undefined) chrome.tabs.sendMessage(tabId, { volume: command.volume }).catch(() => {});
}

/// The iPhone remote, through the TV, during a cast from this browser alone. Checked here again: only
/// playback controls and the cast's own volume, never anything that opens or plays a link.
const LOOK_RANGES = { brightness: [-0.25, 0.25], contrast: [0.75, 1.25], saturation: [0, 2], warmth: [-1, 1], gamma: [0.8, 1.2] };
const STREAM_VALUES = { quality: ['4k', '1440', '1080'], bitrate: ['auto', 20, 40, 60], fps: [60, 30], delay: [400, 100] };

async function remoteCommand(command) {
  const { castingTab } = await chrome.storage.local.get('castingTab');
  if (!castingTab?.standalone) return;
  if (command?.cmd === 'look' && command.look && typeof command.look === 'object') {
    // The picture: each value kept inside the popup's own range.
    const look = {};
    for (const [key, [low, high]] of Object.entries(LOOK_RANGES)) {
      const value = Number(command.look[key]);
      look[key] = Number.isFinite(value) ? Math.min(high, Math.max(low, value)) : key === 'brightness' || key === 'warmth' ? 0 : 1;
    }
    await chrome.storage.local.set({ look });
    chrome.tabs.sendMessage(castingTab.tabId, { look }).catch(() => {});
    return;
  }
  if (command?.cmd === 'size' && ['contain', 'cover', 'fill'].includes(command.size)) {
    await chrome.storage.local.set({ pictureSize: command.size });
    chrome.tabs.sendMessage(castingTab.tabId, { fit: command.size }).catch(() => {});
    return;
  }
  if (command?.cmd === 'stream' && command.changes && typeof command.changes === 'object') {
    // Quality, bitrate, frame rate or delay: the stream starts again with them, as from the popup.
    const changes = {};
    for (const [name, allowed] of Object.entries(STREAM_VALUES)) {
      if (command.changes[name] !== undefined && allowed.includes(command.changes[name])) changes[name] = command.changes[name];
    }
    if (!Object.keys(changes).length) return;
    await chrome.storage.local.set(changes);
    chrome.runtime.sendMessage({ type: 'streamRestart', changes }).catch(() => {});
    return;
  }
  if (command?.cmd !== 'tabControl') return;
  if (typeof command.volume === 'number') {
    const level = Math.min(1, Math.max(0, command.volume));
    await chrome.storage.local.set({ castVolume: level });
    chrome.runtime.sendMessage({ type: 'streamVolume', volume: level }).catch(() => {});
  } else if (['live', 'next', 'previous'].includes(command.action)) {
    chrome.tabs.sendMessage(castingTab.tabId, command.action).catch(() => {});
  } else if (['play', 'pause', 'seek', 'jump'].includes(command.action)) {
    const seconds = Number.isFinite(command.seconds) ? command.seconds : undefined;
    runTabCommand(castingTab.tabId, { action: command.action, seconds });
  }
}

/// Stops whatever this browser is showing on the TV: its own tab cast, or the app's window cast.
async function endCast() {
  const { castingTab } = await chrome.storage.local.get('castingTab');
  if (castingTab) return endTabCast(castingTab);
  await post('/control', { action: 'stop' }).catch(() => {});
}

chrome.runtime.onMessage.addListener((message, sender, respond) => {
  if (message?.type === 'remoteCommand' && !sender.tab) {
    remoteCommand(message.command);
    return false;
  }
  if (message?.type === 'tabState' && sender.tab) {
    checkIn(message, sender.tab).catch(() => {});
    return false;
  }
  if (message?.type === 'castCheck') {
    castMode(sender.tab).then(respond);
    return true;
  }
  // Full screen in one frame of a tab: every frame fills or lets go together.
  if (message?.type === 'fill' && sender.tab) {
    chrome.tabs.sendMessage(sender.tab.id, { fill: message.on }).catch(() => {});
    return false;
  }
  if (message?.type === 'findTvs') {
    findTvs().then(respond, () => respond([]));
    return true;
  }
  if (message?.type === 'addTv') {
    askTv(String(message.address ?? '').trim(), 3000).then(respond, () => respond(null));
    return true;
  }
  if (message?.type === 'testWifi') {
    chrome.storage.local.get('castingTab').then(({ castingTab }) => {
      if (castingTab) return respond({ error: 'Stop casting to test the Wi-Fi: the TV can only do one at a time.' });
      testWifi().then(respond, (problem) => respond({ error: problem?.message || String(problem) }));
    });
    return true;
  }
  if (message?.type === 'castTab') {
    castTab(message.tabId, message.streamId).then(() => respond({}), async (problem) => {
      const { castingTab } = await chrome.storage.local.get('castingTab');
      if (castingTab) await endTabCast(castingTab);
      else await closeCapture();
      respond({ error: problem?.message || String(problem) });
    });
    return true;
  }
  // Quality, frame rate or delay changed during a cast: the stream starts again with them.
  if (message?.type === 'streamSettings') {
    chrome.storage.local.get('castingTab').then(async ({ castingTab }) => {
      if (!castingTab) return respond({});
      respond(await chrome.runtime.sendMessage({ type: 'streamRestart', changes: message.changes }).catch((e) => ({ error: e.message })));
    });
    return true;
  }
  if (message?.type === 'streamEnded') {
    chrome.storage.local.get('castingTab').then(({ castingTab }) => {
      if (!castingTab) return;
      chrome.storage.local.set({ lastStreamEnd: message.reason });
      endTabCast(castingTab);
    });
    return false;
  }
  if (message?.type === 'endCast') {
    endCast().then(() => respond({}));
    return true;
  }
  return false;
});
