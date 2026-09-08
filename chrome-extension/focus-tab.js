// ⌘⌃L / ⌘⌃G / ⌘⌃N / ⌘⌃F — go to the tab that is already open, instead of
// stacking a fourth Calendar next to the three from this morning.
//
// **Why this can only live in the extension.** The Mac app knows how to put a
// URL in the right browser and the right profile (`OfficialChrome`), and it can
// see Chrome's *windows* over Accessibility — but a window is as deep as AX
// goes. Nothing outside the browser can enumerate tabs and read their URLs;
// `chrome.tabs.query` is the only answer, and it runs here. The old AppleScript
// route could read tabs, but it addressed Chrome by bundle id, so it was as
// likely to inspect a Playwright browser as Victor's own — the whole reason
// `OfficialChrome` stopped using it. This extension is installed in exactly one
// profile, so "which Chrome" is not a question it can get wrong.
//
// **Why the window is placed here too**, rather than by the app afterwards: the
// app never learns which window the tab was in. The socket is one-way, so its
// only handle on the result would be "whatever Chrome focuses a moment later" —
// which is wrong in exactly the case that matters, a miss, where nothing was
// focused and the app would drag some unrelated window under the mouse. Chrome
// can move its own windows, and it is the one that knows which.

/// Resume media the tab already had loaded, from wherever it stopped.
///
/// Injected into the page, so it must be self-contained. It deliberately does
/// **not** touch `ended` elements: replaying a finished mix from track one is
/// the "opened a fresh tab" behaviour this whole file exists to avoid.
///
/// The `data-va-dictation-paused` marker is `dictation-pause.js`'s: pressing
/// ⌘⌃F during a dictation resumes the music by hand, and clearing the marker
/// keeps that module's ledger honest — it must not believe it still owes a
/// resume for a track that is already playing.
function resumePausedMedia() {
  let resumed = 0;
  for (const el of document.querySelectorAll('video, audio')) {
    if (!el.paused || el.ended) continue;
    delete el.dataset.vaDictationPaused;
    const p = el.play();
    if (p && typeof p.catch === 'function') p.catch(() => {});
    resumed++;
  }
  return resumed;
}

/// The first tab matching the request, or `undefined`.
///
/// `chrome.tabs.query({url})` takes match patterns, whose path glob is compared
/// against the path alone — the query string is invisible to it. Every
/// distinction Victor asked for lives in the query string ("Gmail but not an
/// open compose", "the YouTube tab of *this* mix"), so the patterns only narrow
/// to a host and `contains` / `notContains` do the real filtering here, against
/// the full URL.
///
/// `windowType: 'normal'` drops Chrome's popups and app windows; a Gmail
/// compose torn off into its own window is a popup, and is excluded both by
/// this and by `notContains`.
async function findTab({ match, contains, notContains }) {
  const tabs = await chrome.tabs.query({ url: match, windowType: 'normal' });
  return tabs.find((tab) => {
    const url = tab.url || '';
    if (contains && !url.includes(contains)) return false;
    if (notContains && url.includes(notContains)) return false;
    return true;
  });
}

/// Is the window's centre already on that screen? Chrome reports and accepts
/// window bounds in the same top-left-origin screen space the Mac measures its
/// displays in, so this is the app's own `OfficialChrome.topLeftRect` test.
function centreIsOn(win, screen) {
  const x = win.left + win.width / 2;
  const y = win.top + win.height / 2;
  return x >= screen.left && x < screen.left + screen.width
      && y >= screen.top && y < screen.top + screen.height;
}

/// Raise the window and, if it is on another display, bring it here.
///
/// A window already on the target screen is only raised — never resized. The
/// ⌘⌃ keys follow the eyes; they do not tidy the desk, and snapping a window
/// Victor had sized himself to fill the screen would be exactly that. The fill
/// is how a window *arriving* from another monitor is placed, matching what the
/// app does when it opens a new one.
async function placeWindow(windowId, screen) {
  const update = { focused: true };
  if (screen) {
    const win = await chrome.windows.get(windowId);
    if (!centreIsOn(win, screen)) {
      // Bounds are ignored on a maximized or fullscreen window, so it has to
      // come back to 'normal' in the same call before it can travel.
      if (win.state !== 'normal') update.state = 'normal';
      Object.assign(update, screen);
    }
  }
  await chrome.windows.update(windowId, update);
}

/**
 * Go to the page if it is open anywhere, otherwise open it.
 *
 * `url` is the fallback the Mac computed for the "not open" case, and it is not
 * always the page we search for: ⌘⌃F searches for *the focus mix* but falls
 * back to a URL entered at a random track, which is the point of that shortcut.
 * A `null` url makes this a **probe** — go there if it exists, otherwise do
 * nothing at all. ⌘⌃F fires one of those first so the common case (the mix is
 * already up) answers instantly, and only then spends a second reading YouTube
 * for the URL it sends in a second, identical call. Both are safe to run: this
 * whole function is idempotent, and the second one finds the tab the first one
 * focused.
 *
 * A found tab is never navigated. Re-assigning `url` on a tab that is already
 * there would reload Gmail, scroll the notes doc back to the top and restart
 * the music — the three things "take me to my tab" means the opposite of.
 */
export async function focusOrOpen(msg) {
  const tab = await findTab(msg);

  if (!tab) {
    if (!msg.url) return;                      // a probe, and the answer is "no"
    // Its own window, placed on the right display in the same call — Chrome
    // otherwise sizes a new window from its memory of the last one, which is
    // usually a different monitor.
    await chrome.windows.create({ url: msg.url, focused: true, ...(msg.screen || {}) });
    return;
  }

  await chrome.tabs.update(tab.id, { active: true });
  await placeWindow(tab.windowId, msg.screen);

  if (!msg.resume) return;
  try {
    await chrome.scripting.executeScript({
      target: { tabId: tab.id, allFrames: true },
      func: resumePausedMedia,
    });
  } catch (e) {
    // chrome://, the Web Store, a PDF viewer — the tab is focused either way,
    // which is most of what was asked for.
    console.log('[focus-tab] cannot script tab', tab.id, e.message);
  }
}
