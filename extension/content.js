// Runs in every frame of a page. Reports the main video, and while on the TV makes it fill the picture.
let reporting;
let size;
// One Window is showing this tab's browser window: the page shows as it is until the user asks for
// full screen, which fills the TV with the video instead.
let watching = false;
let preferredSize = 'cover';
let volumeSlider;

// Live streams report a length that's endless, absurd (Twitch says about 34 years), marked live by the
// player, or growing a little at a time as you watch. An unknown length while loading proves nothing, and
// neither does one jump from an ad to the video, so a normal video isn't mistaken for live.
// YouTube says so in its page data: a broadcast with a start and no end yet is live now; one with an end
// was live once. Its length looks like a normal video's (the stream so far) and grows only while it
// downloads, so a paused or rewound stream showed as a plain video without this.
// YouTube's player shows its Live button only on live streams, wherever you came from in the site.
function youtubeBadge(video) {
  const badge = video.closest('.html5-video-player')?.querySelector('.ytp-live-badge');
  return badge && getComputedStyle(badge).display !== 'none' ? badge : null;
}

// Where a YouTube live stream really is, from YouTube's own player, which fullscreen.js reaches in the page's
// world. The video's own clock and "seekable" range don't match the stream: the seekable end can be hours
// or days past what exists yet, and setting its time is ignored. A command moves the player first.
function youtube(command = {}) {
  const player = location.hostname.endsWith('youtube.com') && document.getElementById('movie_player');
  if (!player) return null;
  document.dispatchEvent(new CustomEvent('throwcast-youtube', { detail: JSON.stringify(command) }));
  try {
    const progress = JSON.parse(player.dataset.throwcastProgress);
    return Number.isFinite(progress.current) && progress.end > 0 ? progress : null;
  } catch {
    return null;
  }
}

function youtubeLive(video) {
  if (!/(^|\.)youtube\.com$/.test(location.hostname)) return false;
  if (youtubeBadge(video)) return true;
  const publication = document.querySelector('[itemprop="publication"]');
  const meta = (name) => publication?.querySelector(`[itemprop="${name}"]`)?.getAttribute('content');
  // The page data must be this video's, not one left over from the last video in the same page.
  const shown = document.querySelector('meta[itemprop="identifier"]')?.getAttribute('content');
  const wanted = new URLSearchParams(location.search).get('v') ?? location.pathname.match(/^\/(?:live|shorts)\/([\w-]{11})/)?.[1];
  if (shown && wanted && shown !== wanted) return false;
  return meta('isLiveBroadcast') === 'True' && !meta('endDate');
}

function isLive(video) {
  if (youtubeLive(video)) return true;
  const data = video.dataset;
  if (data.throwcastSrc !== video.currentSrc) {
    data.throwcastSrc = video.currentSrc;
    delete data.throwcastLength;
    data.throwcastGrowth = '0';
  }
  const length = video.duration;
  if (length === Infinity || length > 86400 || video.closest('.ytp-live')) return true;
  if (video.readyState < 1 || !Number.isFinite(length)) return false;
  const last = Number(data.throwcastLength);
  if (last && length > last + 0.2 && length - last < 30) data.throwcastGrowth = String(Number(data.throwcastGrowth) + 1);
  data.throwcastLength = length;
  return Number(data.throwcastGrowth) >= 4;
}

// The newest moment that can be played. Twitch claims one about 34 years ahead, so an edge hours away
// is ignored for what's actually loaded.
function liveEdge(video) {
  const last = (ranges) => (ranges.length ? ranges.end(ranges.length - 1) : video.currentTime);
  const seekable = last(video.seekable);
  return Number.isFinite(seekable) && seekable - video.currentTime < 6 * 3600 ? seekable : last(video.buffered);
}

// How far back a live stream can be rewound, when the site keeps a window (YouTube does, Twitch doesn't).
function rewindStart(video) {
  if (!video.seekable.length) return null;
  const start = video.seekable.start(0);
  const span = liveEdge(video) - start;
  return Number.isFinite(start) && span > 60 && span < 12 * 3600 ? start : null;
}

function state(video) {
  const live = isLive(video);
  const stream = live ? youtube() : null;
  if (stream) {
    const span = stream.end - stream.start;
    return {
      time: stream.current, duration: 0, paused: video.paused, volume: video.muted ? 0 : video.volume, live,
      behind: Math.max(0, stream.end - stream.current),
      start: span > 60 && span < 12 * 3600 ? stream.start : null,
    };
  }
  return {
    time: video.currentTime || 0,
    duration: live || !Number.isFinite(video.duration) ? 0 : video.duration,
    paused: video.paused,
    volume: video.muted ? 0 : video.volume,
    live,
    behind: live ? Math.max(0, liveEdge(video) - video.currentTime) : 0,
    start: live ? rewindStart(video) : null,
  };
}

// Finds elements inside open shadow roots too, where many custom players keep their video.
function deepAll(selector, root = document) {
  const found = [...root.querySelectorAll(selector)];
  for (const element of root.querySelectorAll('*')) if (element.shadowRoot) found.push(...deepAll(selector, element.shadowRoot));
  return found;
}

const area = (element) => {
  const box = element.getBoundingClientRect();
  return box.width * box.height;
};

// The one that's playing beats a bigger one that isn't, such as a paused preview or a poster.
const mainVideo = () => {
  if (fitted?.isConnected && fitted.tagName === 'VIDEO') return fitted;
  return deepAll('video').sort((a, b) => area(b) * (b.paused ? 1 : 3) - area(a) * (a.paused ? 1 : 3))[0];
};

let fitted;
let guard;

// While on the TV, report the video and collect any controls pressed in the Throwcast app.
function report() {
  // A next episode can swap the video without reloading the page, and a player can drop the fit.
  applyFit();
  const video = mainVideo();
  if (!video) return;
  chrome.runtime.sendMessage({ type: 'tabState', ...state(video), filled: Boolean(size) }).catch(() => {});
}

// Whichever is bigger: a video in this frame, or a frame that may hold one. Frames inside frames
// work too, because every frame runs this and fills its own part.
function fitTarget() {
  const video = mainVideo();
  const frame = deepAll('iframe').sort((a, b) => area(b) - area(a))[0];
  if (video && (!frame || area(video) * 2 >= area(frame))) return video;
  return frame && area(frame) > 0 ? frame : video;
}

function fitStyle(element) {
  return {
    position: 'fixed', inset: '0', width: '100vw', height: '100vh', 'max-width': 'none', 'max-height': 'none',
    margin: '0', padding: '0', border: '0', transform: 'none', 'z-index': '2147483647', background: '#000',
    display: 'block', visibility: 'visible', opacity: '1', 'object-fit': size,
  };
}

// The top layer draws above everything on the page at full size, whatever transforms, frames
// or stacking the site uses, and unlike fullscreen it needs no click.
function applyFit() {
  if (!size) return;
  document.documentElement?.setAttribute('data-throwcast-casting', '');
  const target = fitTarget();
  if (target !== fitted) release();
  if (!target) return;
  fitted = target;
  if (!('throwcastStyle' in target.dataset)) target.dataset.throwcastStyle = target.getAttribute('style') ?? '';
  guard?.disconnect();
  for (const [name, value] of Object.entries(fitStyle(target))) {
    if (target.style.getPropertyValue(name) !== value || target.style.getPropertyPriority(name) !== 'important') target.style.setProperty(name, value, 'important');
  }
  if (!target.hasAttribute('popover')) {
    target.setAttribute('popover', 'manual');
    target.dataset.throwcastPopover = '';
  }
  try {
    if (!target.matches(':popover-open')) target.showPopover();
  } catch {}
  // Players resize their video as they go. Put the fit back the moment they do.
  guard = new MutationObserver(() => applyFit());
  guard.observe(target, { attributes: true, attributeFilter: ['style', 'popover', 'class'] });
}

function release() {
  guard?.disconnect();
  guard = undefined;
  const element = fitted;
  fitted = undefined;
  if (!element) return;
  try {
    if ('throwcastPopover' in element.dataset) {
      element.hidePopover();
      element.removeAttribute('popover');
    }
  } catch {}
  const saved = element.dataset.throwcastStyle;
  if (saved) element.setAttribute('style', saved);
  else element.removeAttribute('style');
  delete element.dataset.throwcastStyle;
  delete element.dataset.throwcastPopover;
}

// The half-second check keeps retrying, so a page that isn't ready yet still ends up filled.
function fit(mode) {
  size = mode;
  reporting ??= setInterval(report, 500);
  applyFit();
}

function unfit() {
  clearInterval(reporting);
  reporting = undefined;
  size = undefined;
  document.documentElement.removeAttribute('data-throwcast-casting');
  release();
}

function watch() {
  if (watching || size) return;
  watching = true;
  // Lets fullscreen.js catch full-screen requests, which would otherwise move the window to its own desktop.
  document.documentElement.setAttribute('data-throwcast-casting', '');
  reporting ??= setInterval(report, 500);
}

function unwatch() {
  if (!watching) return;
  watching = false;
  unfit();
}

function setFill(on) {
  if (!watching) return;
  size = on ? preferredSize : undefined;
  if (on) applyFit();
  else release();
  report();
}

// Every frame of the tab fills or lets go together, because the video can sit inside a frame.
const askFill = (on) => chrome.runtime.sendMessage({ type: 'fill', on }).catch(() => {});

// F, a double-click or the player's button. A cast tab is already full, so it stays that way; in a
// window cast it switches the video between filling the TV and the page as it was.
document.addEventListener('throwcast-fullscreen', () => (watching ? askFill(!size) : applyFit()));
// Anything that still gets through, such as Chrome's own video controls, is undone straight away.
document.addEventListener('fullscreenchange', () => {
  if (!document.fullscreenElement || !(size || watching)) return;
  document.exitFullscreen().catch(() => {});
  if (watching && !size) askFill(true);
});
// Escape leaves the fill, as it leaves full screen.
document.addEventListener('keydown', (event) => {
  if (watching && size && event.key === 'Escape') {
    event.stopPropagation();
    askFill(false);
  }
}, true);

// The player's own slider is the short one sitting at the video's volume. A seek bar is wider.
function findVolumeSlider(video) {
  return [...document.querySelectorAll('input[type="range"]')].find((input) => {
    const min = Number(input.min) || 0;
    const share = (input.value - min) / ((Number(input.max) || 100) - min);
    return input.getBoundingClientRect().width < 240 && Math.abs(share - video.volume) < 0.02;
  });
}

// Moves the site's slider too, or its player can put its own volume back.
function setVolume(video, value) {
  if (!volumeSlider?.isConnected) volumeSlider = findVolumeSlider(video);
  if (volumeSlider) {
    const min = Number(volumeSlider.min) || 0;
    const level = min + value * ((Number(volumeSlider.max) || 100) - min);
    Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set.call(volumeSlider, String(level));
    volumeSlider.dispatchEvent(new Event('input', { bubbles: true }));
    volumeSlider.dispatchEvent(new Event('change', { bubbles: true }));
  }
  video.volume = value;
  video.muted = value === 0;
}

chrome.runtime.onMessage.addListener((message, _sender, respond) => {
  if (message === 'ping') respond(true);
  if (message?.fit) {
    if (!watching) fit(message.fit);
    else {
      preferredSize = message.fit;
      if (size) setFill(true);
    }
  }
  if (message?.fill !== undefined) setFill(message.fill);
  if (message === 'unfit') unfit();
  const video = mainVideo();
  if (!video) return false;
  if (message === 'pause') video.pause();
  if (message === 'play') video.play().catch(() => {});
  // A YouTube live stream moves through its own player, in its own clock; anything else directly.
  const stream = isLive(video) ? youtube() : null;
  if (message?.jump) stream ? youtube({ seek: stream.current + message.jump }) : (video.currentTime += message.jump);
  if (message?.seek !== undefined) stream ? youtube({ seek: message.seek }) : (video.currentTime = message.seek);
  if (message?.volume !== undefined) setVolume(video, message.volume);
  if (message === 'live') {
    if (stream) youtube({ live: true });
    else video.currentTime = liveEdge(video) - 1;
  }

  if (message === 'describe') {
    const src = video.currentSrc || video.src || '';
    respond({ ...state(video), src: /^https?:/.test(src) ? src : '', protected: Boolean(video.mediaKeys) });
  }
  return false;
});

function castCheck() {
  chrome.runtime.sendMessage({ type: 'castCheck' }).then((mode) => {
    if (mode === 'window') watch();
    else if (mode) fit(mode);
    else unwatch();
  }).catch(() => {});
}

// A refreshed page or the next episode picks the cast back up.
castCheck();
// A window cast can start or end at any time, so a tab on screen with a video keeps asking, every 2 s.
setInterval(() => {
  if (document.visibilityState === 'visible' && (watching || deepAll('video').length)) castCheck();
}, 2000);
