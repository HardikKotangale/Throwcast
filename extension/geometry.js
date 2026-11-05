/// The part of a browser window that is the page. The browser's own bars are at the top, so the
/// page sits at the bottom of the window. A tab's size comes straight from the browser, in the
/// same points as the window, so it needs nothing from the page and browser zoom doesn't affect it.
export function pageCrop(window, tab) {
  const width = Math.min(window.width, tab.width);
  const height = Math.min(window.height, tab.height);
  return { x: 0, y: Math.max(0, window.height - height), width, height };
}

/// A browser window is the one Throwcast shows with One Window: the same place and size, give or take.
export function sameWindow(window, cast) {
  if (!window || !cast) return false;
  return Math.abs(window.left - cast.x) + Math.abs(window.top - cast.y) + Math.abs(window.width - cast.width) + Math.abs(window.height - cast.height) < 80;
}
