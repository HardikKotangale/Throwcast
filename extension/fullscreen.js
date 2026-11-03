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
