import { sameWindow } from './geometry.js';
const API = 'http://127.0.0.1:47122';
const view = document.getElementById('view');
const tvLabel = document.getElementById('tv');
let scrubbing = false;
let shown = '';
let changingVolume = false;

function showToggle(paused) {
  const toggle = view.querySelector('#toggle');
  toggle.setAttribute('aria-label', paused ? 'Play' : 'Pause');
  toggle.querySelector('use').setAttribute('href', paused ? '#icon-play' : '#icon-pause');
}

async function api(path, body) {
  const response = await fetch(API + path, body
    ? { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) }
    : undefined);
  const json = await response.json();
  if (!response.ok) throw new Error(json.error ?? 'Throwcast couldn’t do that.');
  return json;
}

function show(id, fill) {
  view.replaceChildren(document.getElementById(id).content.cloneNode(true));
  fill(view);
}

function message(title, detail) {
  const key = title + detail;
  if (shown === key) return;
  shown = key;
  show('message', (root) => {
    root.querySelector('h1').textContent = title;
    root.querySelector('p').textContent = detail;
  });
}

const clock = (seconds) => {
  const s = Math.max(0, Math.floor(seconds));
  const hours = Math.floor(s / 3600);
  const minutes = Math.floor(s / 60) % 60;
  const rest = String(s % 60).padStart(2, '0');
  return hours ? `${hours}:${String(minutes).padStart(2, '0')}:${rest}` : `${minutes}:${rest}`;
};

async function pageVideo(tabId) {
  try {
    return await chrome.tabs.sendMessage(tabId, 'describe');
  } catch {
    return null;
  }
}

/// HLS and DASH adapt to the connection, so they beat a plain file. Among files, largest wins.
async function rankedLinks(tab, page) {
  const name = `videos:${tab.id}`;
  const found = [...((await chrome.storage.session.get(name))[name] ?? [])];
  if (page?.src && !found.some((v) => v.url === page.src)) found.push({ url: page.src, kind: 'Video file', rank: 1, bytes: 0, headers: {} });
  // What the page's player is actually using beats anything else seen on the page.
  return found.sort((a, b) => (b.url === page?.src) - (a.url === page?.src) || b.rank - a.rank || b.bytes - a.bytes);
}

function tabView(tab, secondary) {
  const key = `tab:${tab.url}:${secondary?.label ?? ''}`;
  if (shown === key) return;
  shown = key;
  show('tab', (root) => {
    root.querySelector('.title').textContent = tab.title;
    const cast = root.querySelector('#cast');
    const error = root.querySelector('.error');
    cast.addEventListener('click', async () => {
      cast.disabled = true;
      cast.textContent = 'Starting…';
      error.hidden = true;
      try {
        // Only a click in the extension may capture a tab's sound, so it's asked for here.
        const streamId = await chrome.tabCapture.getMediaStreamId({ targetTabId: tab.id }).catch(() => null);
        const reply = await chrome.runtime.sendMessage({ type: 'castTab', tabId: tab.id, streamId });
        if (reply?.error) throw new Error(reply.error);
        // The TV takes a moment, and that's when macOS can refuse the window.
        await new Promise((resolve) => setTimeout(resolve, 2500));
        const after = await api('/status');
        if (after.failure) throw new Error(after.failure);
      } catch (problem) {
        error.textContent = problem.message;
        error.hidden = false;
        cast.disabled = false;
        cast.textContent = 'Show This Tab on TV';
      }
    });
    const other = root.querySelector('#other');
    other.hidden = !secondary;
    if (secondary) {
      other.textContent = secondary.label;
      other.addEventListener('click', secondary.run);
    }
  });
}

async function castingView(casting, status) {
  if (shown !== 'casting') {
    shown = 'casting';
    show('casting', (root) => {
      const send = (message) => chrome.tabs.sendMessage(casting.tabId, message).catch(() => {});
      root.querySelector('#stopCast').addEventListener('click', () => {
        shown = '';
        chrome.runtime.sendMessage({ type: 'endCast' });
      });
      root.querySelector('#back').addEventListener('click', () => send({ jump: -10 }));
      root.querySelector('#goLive').addEventListener('click', () => send('live').then(refresh));
      root.querySelector('#forward').addEventListener('click', () => send({ jump: 10 }));
      root.querySelector('#toggle').addEventListener('click', (event) => send(event.currentTarget.getAttribute('aria-label').toLowerCase()).then(refresh));
      const volume = root.querySelector('#volume');
      volume.addEventListener('pointerdown', () => { changingVolume = true; });
      volume.addEventListener('input', () => api('/tabVolume', { volume: volume.value / 100 }).catch(() => {}));
      volume.addEventListener('change', () => { changingVolume = false; });
      const scrub = root.querySelector('#scrub');
      scrub.addEventListener('pointerdown', () => { scrubbing = true; });
      scrub.addEventListener('change', () => {
        scrubbing = false;
        send({ seek: Number(scrub.dataset.from) + (scrub.value / 1000) * Number(scrub.dataset.span) });
      });
      root.querySelectorAll('[data-size]').forEach((button) => button.addEventListener('click', async () => {
        await chrome.storage.local.set({ pictureSize: button.dataset.size });
        send({ fit: button.dataset.size });
        refresh();
      }));
    });
  }
  view.querySelector('.title').textContent = casting.title ?? 'Casting to your TV';
  const { pictureSize = 'cover' } = await chrome.storage.local.get('pictureSize');
  view.querySelectorAll('[data-size]').forEach((button) => button.setAttribute('aria-pressed', button.dataset.size === pictureSize));
  // A window cast from the app, or a tab from before the extension reloaded, still gets Stop Casting.
  view.querySelector('.segments').hidden = !casting.tabId;
  const video = casting.tabId ? await chrome.tabs.sendMessage(casting.tabId, 'describe').catch(() => null) : null;
  view.querySelector('.controls').hidden = !video;
  if (!video) return;
  const scrub = view.querySelector('#scrub');
  // A live stream has no end to measure against, so it gets the LIVE mark instead of a timeline.
  const behind = video.live && video.behind >= 15;
  view.querySelector('.live').hidden = !video.live;
  const pill = view.querySelector('#goLive');
  pill.classList.toggle('behind', behind);
  pill.disabled = !behind;
  pill.querySelector('span').textContent = behind ? 'Go Live' : 'LIVE';
  view.querySelector('.live .note').textContent = behind ? `${clock(video.behind)} behind` : 'Watching live';
  // The slider runs over the video, or for a live stream that keeps one, from the oldest moment it can
  // rewind to up to live.
  const rewind = video.live && video.start !== null && video.start !== undefined;
  const from = rewind ? video.start : 0;
  const span = rewind ? video.time + video.behind - video.start : video.duration;
  scrub.hidden = view.querySelector('.times').hidden = !(span > 0) || (video.live && !rewind);
  scrub.dataset.from = from;
  scrub.dataset.span = span;
  if (!scrubbing && span > 0) scrub.value = ((video.time - from) / span) * 1000;
  view.querySelector('#now').textContent = rewind ? `−${clock(video.behind)}` : clock(video.time);
  view.querySelector('#total').textContent = rewind ? 'Live' : clock(video.duration);
  if (!changingVolume) view.querySelector('#volume').value = (status.tabVolume ?? video.volume) * 100;
  showToggle(video.paused);
}

function sendView(tab, title, detail, payload) {
  const key = `send:${tab.url}:${detail}`;
  if (shown === key) return;
  shown = key;
  show('send', (root) => {
    root.querySelector('.title').textContent = title;
    root.querySelector('.detail').textContent = detail;
    const button = root.querySelector('#play');
    root.querySelector('#instead').addEventListener('click', () => { shown = ''; tabView(tab); });
    button.addEventListener('click', async () => {
      const error = root.querySelector('.error');
      button.disabled = true;
      button.textContent = 'Sending…';
      error.hidden = true;
      try {
        const page = await pageVideo(tab.id);
        const result = await api('/play', { ...payload, title, start: page?.time ?? 0 });
        chrome.tabs.sendMessage(tab.id, 'pause').catch(() => {});
        refresh();
      } catch (problem) {
        error.textContent = problem.message;
        error.hidden = false;
        button.disabled = false;
        button.textContent = 'Play on TV';
      }
    });
  });
}

function playingView(playback) {
  if (shown !== 'playing') {
    shown = 'playing';
    show('playing', (root) => {
      const control = (action, seconds) => api('/control', { action, seconds }).then(refresh).catch(() => {});
      root.querySelector('#back').addEventListener('click', () => control('jump', -10));
      root.querySelector('#forward').addEventListener('click', () => control('jump', 10));
      root.querySelector('#stop').addEventListener('click', () => control('stop'));
      root.querySelector('#toggle').addEventListener('click', (event) => {
        control(event.currentTarget.getAttribute('aria-label').toLowerCase());
      });
      const scrub = root.querySelector('#scrub');
      scrub.addEventListener('pointerdown', () => { scrubbing = true; });
      scrub.addEventListener('change', () => {
        scrubbing = false;
        control('seek', (scrub.value / 1000) * Number(scrub.dataset.duration));
      });
    });
  }
  view.querySelector('.title').textContent = playback.title;
  const scrub = view.querySelector('#scrub');
  scrub.dataset.duration = playback.duration;
  if (!scrubbing && playback.duration > 0) scrub.value = (playback.time / playback.duration) * 1000;
  view.querySelector('#now').textContent = clock(playback.time);
  view.querySelector('#total').textContent = clock(playback.duration);
  showToggle(playback.state === 'paused');
}

async function refresh() {
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  let status;
  try {
    status = await api('/status');
  } catch {
    tvLabel.textContent = '';
    return message('Open Throwcast on your Mac', 'The extension hands videos to the app, which sends them to your TV.');
  }
  tvLabel.textContent = status.tv?.name ?? '';
  if (status.playback?.state === 'failed') return message('This video can’t play on the TV', status.playback.error ?? 'Cast its window from Throwcast instead.');
  if (status.playback && status.playback.state !== 'ended') return playingView(status.playback);
  if (!status.tv) return message('Choose a TV in Throwcast', 'Your TV needs to be selected in the app first.');
  const { castingTab } = await chrome.storage.local.get('castingTab');
  if (status.casting && castingTab) return castingView(castingTab, status);
  // A browser window cast with One Window: the controls work on the tab showing in it.
  if (status.casting && tab && sameWindow(await chrome.windows.get(tab.windowId).catch(() => null), status.castWindow)) {
    return castingView({ tabId: tab.id, title: tab.title }, status);
  }
  if (status.casting) return castingView({}, status);
  // Stopped from the app, or the app quit: bring the tab home.
  if (castingTab && !shown.startsWith('tab:')) return chrome.runtime.sendMessage({ type: 'endCast' });
  if (!tab?.url?.startsWith('http')) return message('Open a page to cast', 'Then press Show This Tab on TV here.');

  // Casting the page works on any site. Sending the link stays as the cooler option when one exists.
  const page = await pageVideo(tab.id);
  const [link, ...others] = await rankedLinks(tab, page);
  if (!link) return tabView(tab);
  const withPage = (item) => ({ url: item.url, headers: { Referer: tab.url, ...item.headers } });
  const detail = `${link.kind} · plays on the TV by itself, if the site allows it`;
  tabView(tab, {
    label: 'Send Video Link Instead',
    run: () => {
      shown = '';
      sendView(tab, tab.title, detail, { ...withPage(link), alternates: others.slice(0, 4).map(withPage) });
    },
  });
}

refresh();
setInterval(refresh, 1000);
