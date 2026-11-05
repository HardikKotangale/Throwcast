import { sameWindow } from './geometry.js';
const API = 'http://127.0.0.1:47122';
const view = document.getElementById('view');
const tvLabel = document.getElementById('tv');
let scrubbing = false;
let shown = '';
// The popup checks every second. One slow answer mustn't redraw it: the Mac app's status and the
// video's state are kept from the last good answer until a few in a row are missing.
let lastApp = { value: null, misses: 0 };
let lastVideo = { value: null, misses: 0 };
let lastReport = { value: null, misses: 0 };
function steady(memory, answer, allowed = 3) {
  if (answer) {
    memory.value = answer;
    memory.misses = 0;
  } else if (++memory.misses >= allowed) memory.value = null;
  return memory.value;
}
let changingVolume = false;
// The TV's volume for a tab cast, as saved; read once, then kept as the slider moves.
let castVolume = null;
// The TV list is open, from Change or because no TV is chosen yet.
let choosingTv = false;

function showToggle(paused) {
  const toggle = view.querySelector('#toggle');
  toggle.setAttribute('aria-label', paused ? 'Play' : 'Pause');
  toggle.querySelector('use').setAttribute('href', paused ? '#icon-play' : '#icon-pause');
}

// The Throwcast Mac app, only for its extras when it happens to be open. Casting a tab never needs it.
async function api(path, body) {
  const response = await fetch(API + path, body
    ? { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) }
    : { signal: AbortSignal.timeout(600) });
  const json = await response.json();
  if (!response.ok) throw new Error(json.error ?? 'Throwcast couldn’t do that.');
  return json;
}

// Writes only what changed. The popup updates every second, and rewriting unchanged text or layout
// makes Chrome measure it again, which jumps its scroll and looks like it reloaded.
function setText(element, text) {
  if (element && element.textContent !== String(text)) element.textContent = text;
}
function setHidden(element, hidden) {
  if (element && element.hidden !== Boolean(hidden)) element.hidden = Boolean(hidden);
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

// The Mac app's styles and ranges, so a picture looks the same either way.
const NEUTRAL = { brightness: 0, contrast: 1, saturation: 1, warmth: 0, gamma: 1 };
const STYLES = {
  natural: NEUTRAL,
  // The TV standard is a little deeper than a Mac's screen: slightly darker mid-tones.
  video: { ...NEUTRAL, contrast: 1.02, gamma: 1.08 },
  cinema: { ...NEUTRAL, contrast: 1.05, warmth: 0.2 },
  vivid: { ...NEUTRAL, contrast: 1.08, saturation: 1.25 },
};
const NOTES = {
  natural: 'Looks the way it does on your Mac.',
  video: 'The TV standard for shows, a little deeper than your Mac.',
  cinema: 'Warm and rich, for films in a dim room.',
  vivid: 'Bolder color for bright rooms and sports.',
};
const same = (a, b) => Object.keys(NEUTRAL).every((key) => Math.abs(a[key] - b[key]) < 0.001);

/// Picture and Stream settings, saved for every cast. During a cast, the picture changes on the TV as a
/// slider moves; a stream change restarts the stream with it.
async function wireSettings(root, castTabId) {
  const slot = root.querySelector('.settings-slot');
  slot.replaceChildren(document.getElementById('settings').content.cloneNode(true));
  const saved = await chrome.storage.local.get(['quality', 'delay', 'fps', 'bitrate', 'look', 'openPanel', 'customLooks']);
  let look = { ...NEUTRAL, ...(saved.look ?? {}) };
  const custom = saved.customLooks ?? {};
  // Picture and Stream: one panel at a time, or none, so the popup stays short. Pressing the open one
  // closes it. The choice is remembered for next time.
  const openPanel = (name) => {
    slot.querySelectorAll('[data-tab]').forEach((tab) => tab.setAttribute('aria-expanded', tab.dataset.tab === name));
    slot.querySelectorAll('[data-panel]').forEach((panel) => { panel.hidden = panel.dataset.panel !== name; });
  };
  let open = saved.openPanel ?? null;
  openPanel(open);
  slot.querySelectorAll('[data-tab]').forEach((tab) => tab.addEventListener('click', () => {
    open = open === tab.dataset.tab ? null : tab.dataset.tab;
    openPanel(open);
    chrome.storage.local.set({ openPanel: open });
  }));
  const sliders = [...slot.querySelectorAll('[data-look]')];
  // Shadows runs the other way from gamma, as in the app: right shows more in dark scenes.
  const valueOf = (key) => (key === 'shadows' ? 2 - look.gamma : look[key]);
  const neutralOf = (key) => (key === 'shadows' ? 1 : NEUTRAL[key]);
  const render = () => {
    for (const input of sliders) {
      const key = input.dataset.look;
      const value = valueOf(key), middle = neutralOf(key);
      input.value = value;
      const reach = value >= middle ? Number(input.max) - middle : middle - Number(input.min);
      const percent = Math.round(((value - middle) / reach) * 100);
      input.nextElementSibling.textContent = percent === 0 ? '0' : percent > 0 ? `+${percent}` : String(percent);
    }
    let note = 'Your own picture. Save it with + New to keep it.';
    slot.querySelectorAll('[data-style]').forEach((button) => {
      const style = button.dataset.style === 'custom' ? custom[button.dataset.name] : STYLES[button.dataset.style];
      const on = Boolean(style) && same(look, style);
      button.setAttribute('aria-pressed', on);
      if (on) note = button.dataset.style === 'custom' ? 'One of your styles.' : NOTES[button.dataset.style];
    });
    slot.querySelector('.style-note').textContent = note;
  };
  const apply = (next) => {
    look = next;
    render();
    chrome.storage.local.set({ look });
    if (castTabId) chrome.tabs.sendMessage(castTabId, { look }).catch(() => {});
  };
  for (const input of sliders) {
    input.addEventListener('input', () => {
      const key = input.dataset.look;
      let value = Number(input.value);
      // A slider near its middle settles on it, so neutral is easy to find again.
      if (Math.abs(value - neutralOf(key)) < (Number(input.max) - Number(input.min)) * 0.02) value = neutralOf(key);
      apply(key === 'shadows' ? { ...look, gamma: 2 - value } : { ...look, [key]: value });
    });
  }
  slot.querySelectorAll('[data-style]').forEach((button) => button.addEventListener('click', () => apply({ ...STYLES[button.dataset.style] })));
  slot.querySelector('#resetLook').addEventListener('click', () => apply({ ...NEUTRAL }));

  // Your own styles, saved by name from the sliders, as buttons beside the built-in ones.
  const showCustom = () => {
    slot.querySelectorAll('[data-style="custom"]').forEach((button) => button.remove());
    const before = slot.querySelector('#newStyle');
    for (const name of Object.keys(custom)) {
      const button = document.createElement('button');
      button.dataset.style = 'custom';
      button.dataset.name = name;
      button.textContent = name;
      button.addEventListener('click', () => apply({ ...custom[name] }));
      const remove = Object.assign(document.createElement('button'), { className: 'remove', textContent: '×', type: 'button', title: `Delete ${name}` });
      remove.setAttribute('aria-label', `Delete ${name}`);
      remove.addEventListener('click', async (event) => {
        event.stopPropagation();
        delete custom[name];
        await chrome.storage.local.set({ customLooks: custom });
        showCustom();
        render();
      });
      button.append(remove);
      before.before(button);
    }
  };
  const form = slot.querySelector('.name-style');
  const nameInput = slot.querySelector('#styleName');
  slot.querySelector('#newStyle').addEventListener('click', () => {
    form.hidden = false;
    nameInput.value = '';
    nameInput.focus();
  });
  slot.querySelector('#cancelStyle').addEventListener('click', () => { form.hidden = true; });
  form.addEventListener('submit', async (event) => {
    event.preventDefault();
    const name = nameInput.value.trim();
    if (!name) return nameInput.focus();
    custom[name] = { ...look };
    await chrome.storage.local.set({ customLooks: custom });
    form.hidden = true;
    showCustom();
    render();
  });
  showCustom();
  render();

  const values = { quality: saved.quality ?? '4k', fps: String(saved.fps ?? 60), delay: String(saved.delay ?? 400), bitrate: String(saved.bitrate ?? 'auto') };
  // A typed bitrate: any whole number of Mbps from 5 to 100. It replaces the buttons until one is pressed.
  const typed = slot.querySelector('#bitrate');
  if (!['auto', '20', '40', '60'].includes(values.bitrate)) typed.value = values.bitrate;
  typed.addEventListener('change', async () => {
    const mbps = Math.round(Number(typed.value));
    if (!(mbps >= 5 && mbps <= 100)) {
      typed.value = ['auto', '20', '40', '60'].includes(values.bitrate) ? '' : values.bitrate;
      return;
    }
    typed.value = String(mbps);
    if (String(mbps) === values.bitrate) return;
    values.bitrate = String(mbps);
    slot.querySelectorAll('[data-setting="bitrate"] button').forEach((button) => button.setAttribute('aria-pressed', button.dataset.value === values.bitrate));
    await chrome.storage.local.set({ bitrate: mbps });
    if (castTabId) chrome.runtime.sendMessage({ type: 'streamSettings', changes: { bitrate: mbps } }).catch(() => {});
  });
  // Test: measures the Wi-Fi to the TV and offers a bitrate that leaves it room.
  const testButton = slot.querySelector('#testWifi');
  const testResult = slot.querySelector('.test-result');
  testButton.hidden = Boolean(castTabId);
  testButton.addEventListener('click', async () => {
    testButton.disabled = true;
    testButton.textContent = 'Testing…';
    testResult.hidden = false;
    testResult.textContent = 'Opening Throwcast on the TV, then sending for 3 seconds…';
    const result = await chrome.runtime.sendMessage({ type: 'testWifi' }).catch((e) => ({ error: e.message }));
    testButton.disabled = false;
    testButton.textContent = 'Test Again';
    if (result?.error) {
      testResult.textContent = result.error;
      return;
    }
    testResult.textContent = `${result.mbps} Mbps, ${result.rttMs} ms round trip. Suggested bitrate: ${result.recommended} Mbps. `;
    const use = Object.assign(document.createElement('button'), { className: 'link-button', textContent: 'Use It' });
    use.addEventListener('click', async () => {
      typed.value = String(result.recommended);
      typed.dispatchEvent(new Event('change'));
      use.remove();
    });
    testResult.append(use);
  });
  slot.querySelectorAll('[data-setting]').forEach((group) => {
    const name = group.dataset.setting;
    group.querySelectorAll('button').forEach((button) => {
      button.setAttribute('aria-pressed', button.dataset.value === values[name]);
      button.addEventListener('click', async () => {
        if (button.dataset.value === values[name]) return;
        values[name] = button.dataset.value;
        const value = name === 'quality' || (name === 'bitrate' && button.dataset.value === 'auto') ? button.dataset.value : Number(button.dataset.value);
        group.querySelectorAll('button').forEach((other) => other.setAttribute('aria-pressed', other === button));
        if (name === 'bitrate') typed.value = '';
        await chrome.storage.local.set({ [name]: value });
        if (castTabId) chrome.runtime.sendMessage({ type: 'streamSettings', changes: { [name]: value } }).catch(() => {});
      });
    });
  });
}

async function showTvRow(root) {
  const { tv } = await chrome.storage.local.get('tv');
  root.querySelector('#tvName').textContent = tv?.name ?? '';
  root.querySelector('#changeTv').addEventListener('click', () => {
    choosingTv = true;
    shown = '';
    refresh();
  });
}

function tabView(tab, secondary) {
  const key = `tab:${tab.url}:${secondary?.label ?? ''}`;
  if (shown === key) return;
  shown = key;
  show('tab', (root) => {
    showTvRow(root);
    wireSettings(root, null);
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
        shown = '';
        refresh();
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
      // A tab this extension casts gets every setting; a window the Mac app casts has the app's own.
      if (casting.standalone) wireSettings(root, casting.tabId);
      const send = (message) => chrome.tabs.sendMessage(casting.tabId, message).catch(() => {});
      root.querySelector('#stopCast').addEventListener('click', () => {
        shown = '';
        chrome.runtime.sendMessage({ type: 'endCast' });
      });
      // The same as full screen on the page: the video fills the TV, or the whole page comes back.
      root.querySelectorAll('[data-mode]').forEach((button) => button.addEventListener('click', () => {
        send({ fill: button.dataset.mode === 'video' }).then(refresh);
      }));
      root.querySelector('#back').addEventListener('click', () => send({ jump: -10 }));
      root.querySelector('#goLive').addEventListener('click', () => send('live').then(refresh));
      root.querySelector('#forward').addEventListener('click', () => send({ jump: 10 }));
      root.querySelector('#toggle').addEventListener('click', (event) => send(event.currentTarget.getAttribute('aria-label').toLowerCase()).then(refresh));
      const volume = root.querySelector('#volume');
      volume.addEventListener('pointerdown', () => { changingVolume = true; });
      // A tab cast: the extension's own volume for the TV, which no site can reset. It's saved, so the next
      // cast starts at the same level.
      volume.addEventListener('input', () => {
        const level = volume.value / 100;
        if (!casting.standalone) return api('/tabVolume', { volume: level }).catch(() => {});
        castVolume = level;
        chrome.storage.local.set({ castVolume: level });
        chrome.runtime.sendMessage({ type: 'streamVolume', volume: level }).catch(() => {});
      });
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
  // The tab's title now, so a new video in the same tab shows its own name.
  const liveTab = casting.tabId ? await chrome.tabs.get(casting.tabId).catch(() => null) : null;
  setText(view.querySelector('.title'), liveTab?.title ?? casting.title ?? 'Casting to your TV');
  // What the TV says it's showing, once a second; the dot turns green once frames arrive.
  const report = steady(lastReport, casting.standalone ? await chrome.runtime.sendMessage({ type: 'streamStats' }).catch(() => null) : null);
  const playing = report?.fps > 0;
  view.querySelector('.status').classList.toggle('on', Boolean(playing || !casting.standalone));
  setText(view.querySelector('.health'), playing ? `${Math.round(report.fps)} FPS on the TV · ${report.mbps.toFixed(0)} Mbps` : casting.standalone ? 'Starting on your TV…' : 'On your TV, from the Throwcast app');
  const { pictureSize = 'cover' } = await chrome.storage.local.get('pictureSize');
  view.querySelectorAll('[data-size]').forEach((button) => button.setAttribute('aria-pressed', button.dataset.size === pictureSize));
  const video = steady(lastVideo, casting.tabId ? await chrome.tabs.sendMessage(casting.tabId, 'describe').catch(() => null) : null);
  setHidden(view.querySelector('.controls'), !video);
  setHidden(view.querySelector('.mode'), !video || !casting.standalone);
  view.querySelectorAll('[data-mode]').forEach((button) => {
    const on = button.dataset.mode === (video?.filled ? 'video' : 'page');
    if (button.getAttribute('aria-pressed') !== String(on)) button.setAttribute('aria-pressed', on);
  });
  // Show All, Fill and Stretch shape the video while it fills the TV.
  setHidden(view.querySelector('.segments.size'), !casting.tabId || (casting.standalone && !video?.filled));
  if (!video) return;
  const scrub = view.querySelector('#scrub');
  // A live stream has no end to measure against, so it gets the LIVE mark instead of a timeline.
  const behind = video.live && video.behind >= 15;
  setHidden(view.querySelector('.live'), !video.live);
  const pill = view.querySelector('#goLive');
  pill.classList.toggle('behind', behind);
  pill.disabled = !behind;
  setText(pill.querySelector('span'), behind ? 'Go Live' : 'LIVE');
  setText(view.querySelector('.live .note'), behind ? `${clock(video.behind)} behind` : 'Watching live');
  // The slider runs over the video, or for a live stream that keeps one, from the oldest moment it can
  // rewind to up to live.
  const rewind = video.live && video.start !== null && video.start !== undefined;
  const from = rewind ? video.start : 0;
  const span = rewind ? video.time + video.behind - video.start : video.duration;
  setHidden(scrub, !(span > 0) || (video.live && !rewind));
  setHidden(view.querySelector('.times'), !(span > 0) || (video.live && !rewind));
  scrub.dataset.from = from;
  scrub.dataset.span = span;
  if (!scrubbing && span > 0) scrub.value = ((video.time - from) / span) * 1000;
  setText(view.querySelector('#now'), rewind ? `−${clock(video.behind)}` : clock(video.time));
  setText(view.querySelector('#total'), rewind ? 'Live' : clock(video.duration));
  if (casting.standalone && castVolume === null) castVolume = (await chrome.storage.local.get('castVolume')).castVolume ?? 1;
  if (!changingVolume) view.querySelector('#volume').value = (casting.standalone ? castVolume : status.tabVolume ?? video.volume) * 100;
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

function tvsView() {
  if (shown === 'tvs') return;
  shown = 'tvs';
  show('tvs', (root) => {
    const list = root.querySelector('.tvs');
    const detail = root.querySelector('.detail');
    const error = root.querySelector('.error');
    const choose = async (tv) => {
      await chrome.storage.local.set({ tv });
      choosingTv = false;
      shown = '';
      refresh();
    };
    chrome.runtime.sendMessage({ type: 'findTvs' }).then((tvs) => {
      if (shown !== 'tvs') return;
      detail.textContent = tvs?.length ? 'Found on your Wi-Fi:' : 'No TV found on your Wi-Fi. Type its address below.';
      for (const tv of tvs ?? []) {
        const button = document.createElement('button');
        button.append(tv.name, Object.assign(document.createElement('small'), { textContent: tv.host }));
        button.addEventListener('click', () => choose(tv));
        list.append(button);
      }
    });
    const add = root.querySelector('#add');
    add.addEventListener('click', async () => {
      error.hidden = true;
      add.disabled = true;
      const tv = await chrome.runtime.sendMessage({ type: 'addTv', address: root.querySelector('#address').value });
      add.disabled = false;
      if (tv) return choose(tv);
      error.textContent = 'No Samsung TV answered at that address. Check it’s on and on the same Wi-Fi.';
      error.hidden = false;
    });
  });
}

async function refresh() {
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  const { castingTab, tv, lastStreamEnd } = await chrome.storage.local.get(['castingTab', 'tv', 'lastStreamEnd']);
  tvLabel.textContent = tv?.name ?? '';
  if (castingTab) return castingView(castingTab, { standalone: true });
  if (lastStreamEnd) {
    await chrome.storage.local.remove('lastStreamEnd');
    shown = '';
    return message('The cast ended', lastStreamEnd);
  }
  if (shown.startsWith('The cast ended')) return;
  if (choosingTv || !tv) return tvsView();

  // Extras when the Throwcast Mac app is also open: a video it plays from a link, and its One Window casts.
  const app = steady(lastApp, await api('/status').catch(() => null));
  if (app?.playback?.state === 'failed') return message('This video can’t play on the TV', app.playback.error ?? 'Show the tab instead.');
  if (app?.playback && app.playback.state !== 'ended') return playingView(app.playback);
  if (app?.casting && tab && sameWindow(await chrome.windows.get(tab.windowId).catch(() => null), app.castWindow)) {
    return castingView({ tabId: tab.id, title: tab.title }, app);
  }
  if (!tab?.url?.startsWith('http')) return message('Open a page to cast', 'Then press Show This Tab on TV here.');
  if (!app?.tv) return tabView(tab);

  // With the app, a video file or stream on the page can also be handed to the TV's own player.
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
