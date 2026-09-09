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

/// Start the tab's media — resume what is paused, from wherever it stopped.
///
/// Injected into the page, so it must be self-contained. It deliberately does
/// **not** touch `ended` elements: replaying a finished mix from track one is
/// the "opened a fresh tab" behaviour this whole file exists to avoid.
///
/// It is `async` and reports whether anything is actually rolling, because the
/// background path below has to retry: a tab that was created a moment ago has
/// no `<video>` in it yet, and `play()` on a page Chrome's autoplay policy has
/// not yet made up its mind about rejects.
///
/// Unmuting is deliberate. A YouTube tab that autoplayed while hidden is often
/// muted by the player itself, and silent focus music is the one outcome ⌘⌃F
/// must not produce.
///
/// The `data-va-dictation-paused` marker is `dictation-pause.js`'s: pressing
/// ⌘⌃F during a dictation resumes the music by hand, and clearing the marker
/// keeps that module's ledger honest — it must not believe it still owes a
/// resume for a track that is already playing.
async function startMedia() {
  const media = [...document.querySelectorAll('video, audio')].filter((el) => !el.ended);
  for (const el of media) {
    delete el.dataset.vaDictationPaused;
    if (!el.paused) continue;
    el.muted = false;
    try {
      await el.play();
    } catch (e) {
      // Autoplay refused, or the player is still wiring itself up. Either way
      // the caller's next attempt is the answer, not a louder try here.
    }
  }
  return media.some((el) => !el.paused);
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

/// The window a new tab should be born in: an ordinary, non-incognito one,
/// preferring the one already on the target screen — that is the browser under
/// the eyes, so the tab appears where the hand is pointing without a single
/// window moving. A minimized window is the last resort of the last resort: it
/// counts as "a window exists", but a visible one is always chosen over it.
///
/// `undefined` means Chrome genuinely has nowhere to put a tab (only popups,
/// only incognito, or no windows at all), which is the one case that deserves
/// a new window.
async function hostWindow(screen) {
  const windows = await chrome.windows.getAll({});
  const normal = windows.filter((w) => w.type === 'normal' && !w.incognito);
  const visible = normal.filter((w) => w.state !== 'minimized');
  const pool = visible.length ? visible : normal;
  if (!pool.length) return undefined;
  return (screen && pool.find((w) => centreIsOn(w, screen))) || pool[0];
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
  if (msg.background) return playInBackground(msg);

  const tab = await findTab(msg);

  if (!tab) {
    if (!msg.url) return;                      // a probe, and the answer is "no"
    // A tab in a browser that is already open beats a fourth browser window:
    // the page opens where Victor's other tabs live, and the window keeps the
    // size and place he gave it. `placeWindow` then does the same thing it does
    // for a tab that was already there — raise it, and only carry it over if it
    // is on another display.
    const host = await hostWindow(msg.screen);
    if (host) {
      await chrome.tabs.create({ url: msg.url, windowId: host.id, active: true });
      await placeWindow(host.id, msg.screen);
      return;
    }
    // No window at all to put it in: its own, placed on the right display in
    // the same call — Chrome otherwise sizes a new window from its memory of
    // the last one, which is usually a different monitor.
    await chrome.windows.create({ url: msg.url, focused: true, ...(msg.screen || {}) });
    return;
  }

  await chrome.tabs.update(tab.id, { active: true });
  await placeWindow(tab.windowId, msg.screen);

  if (!msg.resume) return;
  try {
    await chrome.scripting.executeScript({
      target: { tabId: tab.id, allFrames: true },
      func: startMedia,
    });
  } catch (e) {
    // chrome://, the Web Store, a PDF viewer — the tab is focused either way,
    // which is most of what was asked for.
    console.log('[focus-tab] cannot script tab', tab.id, e.message);
  }
}

/**
 * ⌘⌃F — put the music on without putting a window on the screen.
 *
 * The key asks for *sound*, not for YouTube: nothing may come forward, no
 * window may move, and above all **no new window may open** — a browser window
 * appearing over the slides is the whole thing this mode exists to avoid. So a
 * missing tab is created with `active: false` in a window that already exists,
 * and a tab that is already there is neither activated nor raised; only its
 * media is started.
 *
 * The retry loop is not defensive padding. A tab created a moment ago has no
 * `<video>` element yet, and YouTube does not start playing on its own in a tab
 * that has never been visible — the injected `play()` is what starts it, and it
 * has to wait for the player to exist. Chrome allows that call without a user
 * gesture because youtube.com has a high media-engagement score here; if it
 * ever stops allowing it, this is the line that will say so in the log.
 */
async function playInBackground(msg) {
  let tab = await findTab(msg);

  if (!tab) {
    if (!msg.url) return;                      // a probe, and the answer is "no"
    tab = await openHiddenTab(msg.url);
    if (!tab) return;
  }

  for (let attempt = 0; attempt < 8; attempt++) {
    try {
      const results = await chrome.scripting.executeScript({
        target: { tabId: tab.id, allFrames: true },
        func: startMedia,
      });
      if (results.some((r) => r && r.result)) return;
    } catch (e) {
      // Still navigating, or a page we may not script. Try again.
    }
    await new Promise((done) => setTimeout(done, 700));
  }
  console.log('[focus-tab] music never started in tab', tab.id);
}

/// A new tab in the background of a window that already exists.
///
/// `chrome.windows.create` is what this function exists NOT to call. If there
/// is genuinely no ordinary window to put a tab in, one is opened **minimized**
/// — still no window on the screen, and the music plays out of it all the same.
async function openHiddenTab(url) {
  const windows = await chrome.windows.getAll({});
  const host = windows.find((w) => w.type === 'normal' && !w.incognito);
  if (host) return chrome.tabs.create({ url, windowId: host.id, active: false });

  const win = await chrome.windows.create({ url, focused: false, state: 'minimized' });
  return win.tabs && win.tabs[0];
}
