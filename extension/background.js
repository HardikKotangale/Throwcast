import { pageCrop, windowHeightFor } from './geometry.js';

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
  // Closing the tab on the TV ends the cast. There's no tab left to bring back.
  const { castingTab } = await chrome.storage.local.get('castingTab');
  if (castingTab?.tabId !== tabId) return;
  chrome.runtime.sendMessage({ type: 'tabAudioStop' }).catch(() => {});
  await chrome.storage.local.remove('castingTab');
  await post('/control', { action: 'stop' }).catch(() => {});
});

const API = 'http://127.0.0.1:47122';
const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

async function post(path, body) {
  const response = await fetch(API + path, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body ?? {}) });
  const json = await response.json();
  if (!response.ok) throw new Error(json.error ?? 'Throwcast couldn’t do that.');
  return json;
}

/// Pages opened before the extension last reloaded have no working script.
async function prepare(tabId) {
  if (await chrome.tabs.sendMessage(tabId, 'ping').catch(() => false)) return;
  await chrome.scripting.executeScript({ target: { tabId, allFrames: true }, files: ['fullscreen.js'], world: 'MAIN' }).catch(() => {});
  await chrome.scripting.executeScript({ target: { tabId, allFrames: true }, files: ['content.js'] }).catch(() => {});
}

/// Moves the tab to the private TV display, in a window with no toolbar. Runs here, not in the popup,
/// because the popup closes if moving the tab closes its window.
/// The tab's own sound, so it plays on the TV and the Mac keeps everything else. Without it, the app
/// falls back to recording the browser's sound.
async function startTabAudio(streamId) {
  if (!streamId) return false;
  if (!(await chrome.offscreen.hasDocument())) {
    await chrome.offscreen.createDocument({ url: 'offscreen.html', reasons: ['USER_MEDIA'], justification: 'Plays the cast tab’s sound on the TV.' });
  }
  return chrome.runtime.sendMessage({ type: 'tabAudio', streamId }).catch(() => false);
}

async function castTab(tabId, streamId) {
  const tab = await chrome.tabs.get(tabId);
  await prepare(tabId);
  await startTabAudio(streamId).catch(() => false);
  const display = await post('/castTab/begin');
  const created = await chrome.windows.create({
    tabId, type: 'popup', focused: false, left: display.x, top: display.y + 30, width: display.width, height: display.height - 40,
  });
  await wait(500);
  let moved = (await chrome.tabs.get(tabId));
  let window = await chrome.windows.get(created.id);
  await chrome.windows.update(created.id, { height: windowHeightFor(display.width, window, moved) });
  await wait(300);
  moved = await chrome.tabs.get(tabId);
  window = await chrome.windows.get(created.id);
  await chrome.storage.local.set({ castingTab: { tabId, windowId: tab.windowId, index: tab.index, title: tab.title, cast: created.id } });
  const { pictureSize = 'cover' } = await chrome.storage.local.get('pictureSize');
  await chrome.tabs.sendMessage(tabId, { fit: pictureSize }).catch(() => {});
  await post('/castTab', {
    title: moved.title,
    bounds: { x: window.left, y: window.top, width: window.width, height: window.height },
    crop: pageCrop(window, moved),
  });
}

/// Puts the tab back where it came from. Its old window may have closed if this was its only tab.
async function endCast() {
  chrome.runtime.sendMessage({ type: 'tabAudioStop' }).catch(() => {});
  const { castingTab } = await chrome.storage.local.get('castingTab');
  await post('/control', { action: 'stop' }).catch(() => {});
  if (!castingTab) return;
  await chrome.storage.local.remove('castingTab');
  const { tabId, windowId, index } = castingTab;
  await chrome.tabs.sendMessage(tabId, 'unfit').catch(() => {});
  const original = await chrome.windows.get(windowId).catch(() => null);
  if (original) {
    await chrome.tabs.move(tabId, { windowId, index });
    await chrome.tabs.update(tabId, { active: true });
  } else {
    await chrome.windows.create({ tabId, focused: true });
  }
}

async function castSize(tabId) {
  const { castingTab, pictureSize = 'cover' } = await chrome.storage.local.get(['castingTab', 'pictureSize']);
  return castingTab?.tabId === tabId ? pictureSize : null;
}

async function checkIn(state, tabId) {
  const { castingTab, pictureSize = 'cover' } = await chrome.storage.local.get(['castingTab', 'pictureSize']);
  // A tab left over from an earlier cast must not speak for this one, or take its controls.
  if (castingTab?.tabId !== tabId) return chrome.tabs.sendMessage(tabId, 'unfit').catch(() => {});
  const { commands = [] } = await post('/tabState', { time: state.time, duration: state.duration, paused: state.paused, volume: state.volume, live: state.live, behind: state.behind, start: state.start, size: pictureSize });
  for (const command of commands) {
    if (command.stop) await endCast();
    else if (command.action) chrome.tabs.sendMessage(tabId, command.action === 'seek' ? { seek: command.seconds } : command.action === 'jump' ? { jump: command.seconds } : command.action).catch(() => {});
    else if (command.volume !== undefined) chrome.tabs.sendMessage(tabId, { volume: command.volume }).catch(() => {});
    else if (command.size) {
      await chrome.storage.local.set({ pictureSize: command.size });
      chrome.tabs.sendMessage(tabId, { fit: command.size }).catch(() => {});
    }
  }
}

chrome.runtime.onMessage.addListener((message, sender, respond) => {
  if (message?.type === 'tabState' && sender.tab) {
    checkIn(message, sender.tab.id).catch(() => {});
    return false;
  }
  if (message?.type === 'castCheck') {
    castSize(sender.tab?.id).then(respond);
    return true;
  }
  if (message?.type === 'castTab') {
    castTab(message.tabId, message.streamId).then(() => respond({}), async (problem) => {
      await endCast();
      respond({ error: problem.message });
    });
    return true;
  }
  if (message?.type === 'endCast') {
    endCast().then(() => respond({}));
    return true;
  }
  return false;
});
