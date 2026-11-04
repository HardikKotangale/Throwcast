// Runs in the page's own world, where its players live. While a tab is on the TV its video already fills
// the screen, so a request to go fullscreen (F, double-click, the player's button) fills the TV instead
// of resizing the window, which would throw off the picture the TV gets.
if (!window.throwcastFullscreen) {
  window.throwcastFullscreen = true;
  const casting = () => document.documentElement.hasAttribute('data-throwcast-casting');
  for (const name of ['requestFullscreen', 'webkitRequestFullscreen', 'webkitRequestFullScreen']) {
    const original = Element.prototype[name];
    if (!original) continue;
    Element.prototype[name] = function (...options) {
      if (!casting()) return original.apply(this, options);
      document.dispatchEvent(new CustomEvent('throwcast-fullscreen'));
      return name === 'requestFullscreen' ? Promise.resolve() : undefined;
    };
  }
}

// YouTube live streams can only be moved through YouTube's own player, which the extension's other script
// can't reach. It asks here with an event, and reads where the stream is from an attribute on the player.
if (location.hostname.endsWith('youtube.com') && !window.throwcastYouTube) {
  window.throwcastYouTube = true;
  document.addEventListener('throwcast-youtube', (event) => {
    const player = document.getElementById('movie_player');
    if (!player?.getProgressState) return;
    let command = {};
    try { command = JSON.parse(event.detail); } catch {}
    if (Number.isFinite(command.seek)) player.seekTo(command.seek, true);
    if (command.live) player.seekToLiveHead();
    const progress = player.getProgressState();
    player.dataset.throwcastProgress = JSON.stringify({ current: progress.current, start: progress.seekableStart, end: progress.seekableEnd });
  });
}
