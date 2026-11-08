/// The part of a browser window that is the page. The browser's own bars are at the top, so the
/// page sits at the bottom of the window. A tab's size comes straight from the browser, in the
/// same points as the window, so it needs nothing from the page and browser zoom doesn't affect it.
export function pageCrop(window, tab) {
  const width = Math.min(window.width, tab.width);
  const height = Math.min(window.height, tab.height);
  return { x: 0, y: Math.max(0, window.height - height), width, height };
}

/// A browser window is the one Throwcast shows with One Window: the same place and size, give or take.
export function sameWindow(window, cast, tabTitle = '') {
  if (!window || !cast) return false;
  if (Math.abs(window.left - cast.x) + Math.abs(window.top - cast.y) + Math.abs(window.width - cast.width) + Math.abs(window.height - cast.height) < 80) return true;
  // Fill, Keep Shape, full screen or a move can leave the sizes apart. A browser window's title is its
  // showing tab's, so a matching title is the same window whatever its shape.
  return sameTitle(cast.title, tabTitle);
}

export function sameTitle(windowTitle, tabTitle) {
  const clean = (text) => String(text ?? '').replace(/^\(\d+\)\s*/, '').trim().toLowerCase();
  const a = clean(windowTitle), b = clean(tabTitle);
  if (a.length < 3 || b.length < 3) return false;
  return a === b || a.startsWith(b) || b.startsWith(a);
}
