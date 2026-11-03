/// The part of a browser window that is the page. The browser's own bars are at the top, so the
/// page sits at the bottom of the window. A tab's size comes straight from the browser, in the
/// same points as the window, so it needs nothing from the page and browser zoom doesn't affect it.
export function pageCrop(window, tab) {
  const width = Math.min(window.width, tab.width);
  const height = Math.min(window.height, tab.height);
  return { x: 0, y: Math.max(0, window.height - height), width, height };
}

/// The window height that makes the page exactly 16:9, once the browser's title bar is added.
export function windowHeightFor(width, window, tab) {
  return Math.round(width * 9 / 16) + (window.height - tab.height);
}
