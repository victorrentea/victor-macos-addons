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
/// **"Rolling" is `readyState`, not `paused`, and the difference is a whole
/// silent evening.** In a tab that has never been rendered, YouTube attaches its
/// MediaSource and `play()` resolves — `paused` goes false, `networkState` says
/// LOADING — but `readyState` stays at HAVE_NOTHING and `currentTime` never
/// leaves 0, because the player appends its segments from a
/// `requestAnimationFrame` callback and Chrome paints no frames for a tab it has
/// never shown (measured: 0 rAF callbacks against 22 `setTimeout` ticks in the
/// same five seconds). Reporting `!paused` as success made the retry loop below
/// declare victory on the first try over a video that would never make a sound.
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
  // HAVE_FUTURE_DATA or better: there is decoded audio queued up, which is the
  // only evidence from in here that the room will hear something.
  return media.some((el) => !el.paused && !el.ended && el.readyState >= 3);
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
 * ever stops allowing it, `startMedia` is where it will show.
 *
 * **A freshly created tab additionally has to be painted once** — see
 * `renderOnce`. That is the one part of "no window on the screen" that had to
 * give: a tab Chrome has never rendered gets no `requestAnimationFrame`, and
 * without rAF YouTube's player never feeds its MediaSource, so the video sits
 * unpaused and empty forever. Selecting the tab for a moment costs no window:
 * it is done inside a window that is already open and not focused, and the tab
 * that was selected there is put back as soon as sound comes out.
 */
async function playInBackground(msg) {
  const found = await findTab(msg);

  // **The key is a toggle.** One shortcut for "music on" and none for "music
  // off" is a key you can only press once: the mix keeps going until a window is
  // dug out of the dock to stop it, which is the same window this whole mode
  // exists not to show. `audible` is Chrome's own answer to "is this tab making
  // a sound" and costs no injection, so the decision is made before anything is
  // opened or painted.
  //
  // ⌘⌃F sends two messages per press — a probe, then the real call a second
  // later — and both carry the same `press` id. When the tab is there the probe
  // does everything the second call could, so the second one is dropped: without
  // that, the probe would pause the music and its sibling would start it again a
  // heartbeat later, and the toggle would be a key that does nothing. A tab that
  // is *not* there is the one case the second message exists for (it carries the
  // url), so no press is claimed on that path.
  if (found) {
    if (claimed(msg.press)) return;
    if (found.audible && await pauseMedia(found.id)) return;
  }

  let tab = found;

  if (!tab) {
    if (!msg.url) return;                      // a probe, and the answer is "no"
    tab = await openHiddenTab(msg.url);
    if (!tab) return;
  }

  // A tab we just made has certainly never been painted, so go straight for the
  // paint instead of spending a first attempt proving it. A tab that was already
  // there has usually been looked at, and `play()` alone is enough for it.
  //
  // **Unless Chrome threw its document away.** Memory Saver (`high_efficiency
  // _mode`, on by default and on here) discards a tab that has been idle for
  // hours — and a discarded tab keeps its url and title in the strip, so
  // `findTab` matches it exactly like a live one. There is nothing inside it to
  // script: `play()` has no `<video>` to reach, and only *selecting* the tab
  // makes Chrome load the page again. That is what had ⌘⌃F silent for two days —
  // the mix tab from the morning was discarded by lunchtime, every press found
  // it, poked an empty renderer for ten seconds and gave up, and the next press
  // repeated it. A discarded tab therefore gets the same treatment as one we
  // just created, and `renderOnce` waits for the reload it triggers.
  // A discarded tab has to be *told* to come back. Selecting it is not enough:
  // Chrome leaves `status: 'unloaded'` on a tab whose window is behind something
  // else, and an unloaded tab cannot even be scripted — `executeScript` fails
  // with "Cannot access contents of the page", which is what the ladder below
  // was spending ten seconds re-discovering on every press. `reload()` commits
  // the page; `renderOnce` then gives it the frames the player needs.
  if (found && found.discarded) await reloadDiscarded(tab.id);
  if ((!found || found.discarded) && await renderOnce(tab)) return;

  for (let attempt = 0; attempt < 8; attempt++) {
    if (await tryStart(tab.id)) return;
    // Two rounds of `play()` got us nowhere: this tab has never been rendered
    // either (a leftover from an earlier miss, or one Chrome discarded), so it
    // needs the same paint a new one does.
    if (attempt === 1) {
      const rendered = await renderOnce(tab);
      if (rendered === BUSY) return;             // the other call owns this tab
      if (rendered) return;
    }
    await sleep(700);
  }
  // Thrown, not logged: `background.js` mirrors a rejected command into the
  // Mac's own log, and silence that leaves no trace anywhere is exactly how
  // this shortcut managed to be broken without anyone being able to see why.
  throw new Error(`music never started in tab ${tab.id} — ${await diagnose(tab)}`);
}

const sleep = (ms) => new Promise((done) => setTimeout(done, ms));

/// Keypresses this worker has already acted on. A handful is all that is ever
/// live — the second message of a press arrives about a second after the first —
/// so the list is trimmed rather than expired on a clock.
const handledPresses = [];

function claimed(press) {
  if (press === undefined || press === null) return false;
  if (handledPresses.includes(press)) return true;
  handledPresses.push(press);
  if (handledPresses.length > 20) handledPresses.shift();
  return false;
}

/// Stop everything that is playing in the tab, and say whether anything was.
///
/// The `data-va-dictation-paused` marker is deliberately **not** set: that one
/// is `dictation-pause.js`'s ledger of what it owes a resume, and a track Victor
/// silenced by hand must stay silent when the dictation window closes.
async function pauseMedia(tabId) {
  try {
    const results = await chrome.scripting.executeScript({
      target: { tabId, allFrames: true },
      func: () => {
        const playing = [...document.querySelectorAll('video, audio')].filter((el) => !el.paused && !el.ended);
        playing.forEach((el) => el.pause());
        return playing.length > 0;
      },
    });
    return results.some((r) => r && r.result);
  } catch (e) {
    return false;
  }
}

/// Bring a discarded tab's document back, and wait for it to commit.
async function reloadDiscarded(tabId) {
  try {
    await chrome.tabs.reload(tabId);
  } catch (e) {
    // Gone, or Chrome refuses: `renderOnce` still gets its try.
  }
  await waitUntilLoaded(tabId);
}

/// One `startMedia` round trip. False for "not yet", never a throw: a tab that
/// is still navigating, or a page we may not script, is a reason to try again.
async function tryStart(tabId) {
  try {
    const results = await chrome.scripting.executeScript({
      target: { tabId, allFrames: true },
      func: startMedia,
    });
    return results.some((r) => r && r.result);
  } catch (e) {
    return false;
  }
}

/// Select the tab just long enough for Chrome to paint it, then put the window's
/// previous tab back. Returns whether the music is rolling by the end.
///
/// **Nothing is focused and no window moves** — `chrome.tabs.update` selects a
/// tab inside its window; only `chrome.windows.update({focused:true})` would
/// raise it, and it is deliberately not called. When the host window is behind
/// something else (the usual case: ⌘⌃F is pressed from a terminal or the IDE),
/// this is invisible from outside the browser.
///
/// The wait is a poll, not a fixed sleep, so the swap lasts as briefly as the
/// player allows — measured at well under a second once the frames start. Once
/// audio is actually playing Chrome keeps the renderer at full speed even after
/// the tab goes back to hidden, which is why this has to happen exactly once.
///
/// Re-entrancy matters here because ⌘⌃F deliberately fires twice — a probe and
/// then the real call a second later — and both can reach this point for the
/// same tab. Two overlapping swaps would race over which tab to put back, so
/// the second one waits for nothing and simply reports "not rolling yet".
const rendering = new Set();

/// "Someone else is already painting this tab" — distinct from "painted it, no
/// sound". ⌘⌃F fires a probe and then the real call a second later; the loser of
/// that race used to run its own ladder out and throw `music never started` while
/// the winner was still loading the page, so a *working* keypress could still
/// report a failure. The loser now simply steps aside.
const BUSY = 'busy';

async function renderOnce(tab) {
  if (rendering.has(tab.id)) return BUSY;
  rendering.add(tab.id);
  try {
    return await renderOnceNow(tab);
  } finally {
    rendering.delete(tab.id);
  }
}

async function renderOnceNow(tab) {
  let previous;
  try {
    previous = (await chrome.tabs.query({ windowId: tab.windowId, active: true }))[0];
    await chrome.tabs.update(tab.id, { active: true });
  } catch (e) {
    return false;                              // the tab or window is already gone
  }
  // Selecting a discarded tab starts a full page load, and YouTube cold is
  // seconds — far longer than the poll below was ever given. Polling `play()`
  // through that load burns the whole budget on a renderer that has no player
  // yet, so wait for the document first and only then start counting.
  await waitUntilLoaded(tab.id);
  let rolling = false;
  for (let attempt = 0; attempt < 16 && !rolling; attempt++) {
    await sleep(250);
    rolling = await tryStart(tab.id);
  }
  if (previous && previous.id !== tab.id) {
    try {
      await chrome.tabs.update(previous.id, { active: true });
    } catch (e) {
      // Victor closed or moved it while we borrowed the window. His tab, his call.
    }
  }
  return rolling;
}

/// Wait until the tab has a document again: not `discarded`, and done loading.
///
/// Bounded at 15s — a cold YouTube on a slow line, not a hang. Timing out is not
/// an error here: the caller polls `play()` afterwards either way, and a page
/// that is still loading may well have its player up already.
async function waitUntilLoaded(tabId, budgetMs = 15000) {
  const deadline = Date.now() + budgetMs;
  while (Date.now() < deadline) {
    const tab = await chrome.tabs.get(tabId).catch(() => null);
    if (!tab) return false;
    if (!tab.discarded && tab.status === 'complete') return true;
    await sleep(250);
  }
  return false;
}

/// A new tab in the background of a window that already exists.
///
/// `chrome.windows.create` is what this function exists NOT to call. If there
/// is genuinely no ordinary window to put a tab in, one is opened **minimized**
/// — still no window on the screen. That last resort is the one place the music
/// can legitimately fail to start: a minimized window is never painted either,
/// so `renderOnce` has nothing to work with. It stays minimized anyway; a
/// browser window unfolding over the slides is the worse of the two outcomes.
///
/// **The host is chosen so that `renderOnce`'s tab swap is invisible**: an
/// unminimized window that is not the focused one, i.e. a window Victor is not
/// looking at. Only if every candidate is focused or minimized does the swap
/// become something he could notice, and even then it lasts under a second.
async function openHiddenTab(url) {
  const windows = await chrome.windows.getAll({});
  const normal = windows.filter((w) => w.type === 'normal' && !w.incognito);
  const open = normal.filter((w) => w.state !== 'minimized');
  const host = open.find((w) => !w.focused) || open[0] || normal[0];
  if (host) return chrome.tabs.create({ url, windowId: host.id, active: false });

  const win = await chrome.windows.create({ url, focused: false, state: 'minimized' });
  return win.tabs && win.tabs[0];
}

/// Why the music did not start, in one line, gathered only on the failure path.
async function diagnose(tab) {
  const t = await chrome.tabs.get(tab.id).catch(() => null);
  if (!t) return 'the tab is gone';
  const w = await chrome.windows.get(t.windowId).catch(() => null);
  let media = 'unscriptable';
  try {
    const r = await chrome.scripting.executeScript({
      target: { tabId: t.id, allFrames: true },
      func: () => [...document.querySelectorAll('video, audio')].map((el) => ({
        p: el.paused, e: el.ended, r: el.readyState, m: el.muted,
        t: Math.round(el.currentTime), d: Math.round(el.duration || 0),
      })),
    });
    media = JSON.stringify(r.flatMap((x) => x && x.result ? x.result : []));
  } catch (e) { media = 'unscriptable: ' + e.message; }
  return `url=${t.url} status=${t.status} discarded=${t.discarded} audible=${t.audible} `
       + `tabMuted=${t.mutedInfo && t.mutedInfo.muted} window=${w ? w.state : '?'}`
       + `${w && w.focused ? '/focused' : ''} media=${media}`;
}
