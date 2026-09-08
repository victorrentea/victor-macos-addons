// Publishes the end-of-session feedback survey on FreeOnlineSurveys.
//
// The Mac app sends {type:"publish-feedback-form", session:"AI@MassMutual"} when
// the 📝 menu item is pressed (it only offers that item while a session is
// live). This opens a tab, clones the most recent form, renames the clone to the
// session, publishes it, and hands the URL straight back to the Mac:
//
//   GET 127.0.0.1:55123/feedback-form/published?url=…&title=…
//
// which copies it, raises the 🔳 URL+QR banner on the projected screen, appends
// it to the session notes, and hands it to the training daemon so it appears as
// a row in every participant's left-hand menu in Interact.
//
// ── How it waits ────────────────────────────────────────────────────────────
//
// Every step here is "do nothing until the Angular app has rendered the next
// thing". The obvious way to write that — re-inject a probe from the service
// worker every 300ms — costs, on average, half a poll interval per step, and
// this flow has fourteen of them: ~2s of pure sleeping on a good run, ~5s when
// several steps land just after a tick. Invisible in a test, extremely visible
// standing in front of a room waiting for the QR code.
//
// So the waiting happens INSIDE the page instead. `pageOp` takes an optional
// `expect` descriptor and, when given one, returns a promise that resolves the
// instant a MutationObserver sees the DOM reach that state — typically within a
// frame of the render, rather than up to 300ms after it. The service worker
// re-injects only when the document is replaced under it (login bounce, the
// Send navigation), not on a timer.
//
// Two details keep that honest:
//   • A 200ms in-page interval runs alongside the observer. It is a safety net,
//     not the mechanism: a couple of conditions here (a button becoming visible,
//     the URL changing) can in principle settle without a mutation reaching the
//     observer. It costs one local function call — no round trip, nothing to
//     wake the service worker.
//   • Each injected wait is capped at WAIT_CHUNK_MS and reports back. A promise
//     left pending in a document that then navigates would otherwise take its
//     executeScript call with it; chunking means the worst case is one short
//     chunk, not the whole step's timeout.
//
// Clicks are guarded per-element with a `data-va-clicked` marker instead of by
// "return true right after clicking". Under a 300ms poll the old shape was
// merely lucky; at observer speed a re-entered `case` would click Copy twice
// and leave a second clone behind.
//
// ── What the site does, all of it learned the hard way ──────────────────────
//
// It is Angular, and its classes carry build-hashed `ng-tns-c…` suffixes. What
// does NOT move, and is therefore what everything below selects on: the custom
// element `sh-dashboard-project` (one form row), and plain BEM classes under it
// — `h5.dashboard-project__title`, `button.nrm-btn`, `mat-dialog-container`,
// `div.launch-url`.
//
//  • Never match an action button by its text: Material renders the icon as a
//    ligature *inside* the button, so the Copy button's text is "file_copy Copy".
//    Match the label <span>, scoped to the row.
//  • The bounce to the login page is late and JavaScript-driven — a signed-out
//    visit to /dashboard/all still shows the app's own URL for a second or two.
//    Wait for a positive marker of one screen or the other, never for a URL.
//  • Google sign-in lands on /en-GB/home, which also has a "NEW FORM" button and
//    so passes every "am I in the app" check while showing no forms at all.
//  • The dashboard renders exactly 20 rows. On a full account the count is 20
//    before the Copy and 20 after, so "wait for the list to grow" never fires:
//    the signal is "Clone of: <title>" reaching row 0.
//  • A fresh clone arrives ALREADY expanded — clicking it "to open it" folds it
//    shut, and the flow then hunts for a Rename button that is no longer there.
//  • The share URL is not in an input. It only looks like a field; it is the
//    text of div.launch-url. Scanning input values finds nothing, forever.
//  • Setting input.value alone does not reach Angular's form model — the
//    'input' event has to be dispatched by hand.

const ADDONS = 'http://127.0.0.1:55123';
const DASHBOARD = 'https://app.freeonlinesurveys.com/en-GB/dashboard/all';
const LOGIN_HOST = 'identity.freeonlinesurveys.com';

/** Longest a single injected wait may block before reporting back. */
const WAIT_CHUNK_MS = 5_000;
/** In-page safety tick, for the rare state change no mutation announces. */
const SAFETY_POLL_MS = 200;

/**
 * Everything that touches the page, in one injectable function.
 *
 * It has to be one function because `chrome.scripting.executeScript` serialises
 * what it injects: nothing here can close over module scope, so the helpers,
 * the operations AND the waiting travel together and are re-created on every
 * call. Cheap, and the alternative (a content script holding state) would not
 * survive the navigations this flow makes.
 *
 * With no `expect`, it runs the operation once and returns its value. With one,
 * it returns a promise for `{ok:true, value}` as soon as the operation's value
 * satisfies it, or `{ok:false}` when `budgetMs` runs out.
 */
function pageOp(op, arg, expect, budgetMs) {
  const trim = (s) => (s || '').trim();
  const rows = () => Array.from(document.querySelectorAll('sh-dashboard-project'));
  const titleEl = (row) => row.querySelector('h5.dashboard-project__title');
  const titleOf = (row) => {
    const h = titleEl(row);
    // The title= attribute is the untruncated name; the text may be ellipsised.
    return h ? trim(h.getAttribute('title') || h.innerText) : '';
  };
  const actionBtn = (row, label) =>
    Array.from(row.querySelectorAll('button.nrm-btn')).find((b) => {
      const span = b.querySelector('span');
      return span && trim(span.innerText) === label;
    });
  const forms = () =>
    rows().map((row) => {
      const meta = trim((row.querySelector('.dashboard-project__meta') || {}).innerText).replace(/\s+/g, ' ');
      // "3 Sept 2026 10 Responses ADD LABEL" → "3 Sept 2026"
      const date = (meta.match(/^\d{1,2}\s+\S+\s+\d{4}/) || [null])[0];
      return { title: titleOf(row), meta, date };
    });
  const expanded = (i) => {
    const row = rows()[i];
    return !!row && !!actionBtn(row, 'Copy');
  };
  /* One click per element per document. The observer can re-run an operation
   * within a frame of the previous run, so "I clicked, the DOM has not caught
   * up yet, click again" is a live hazard here — on Copy it means a second
   * clone to delete by hand. */
  const clickOnce = (el) => {
    if (!el) return false;
    if (!el.dataset.vaClicked) {
      el.dataset.vaClicked = '1';
      el.click();
    }
    return true;
  };
  const URL_RE = /https?:\/\/[^\s]*freeonlinesurveys\.com\/s\/[A-Za-z0-9_-]+/;

  function run(op, arg) {
    switch (op) {
      // Which of the two screens are we on, once the page has made up its mind?
      // Positive markers only — the URL lies for the first second or two.
      case 'screen':
        if (location.host === 'identity.freeonlinesurveys.com') return 'login';
        if (rows().length > 0) return 'dashboard';
        if (/new form/i.test(document.body.innerText || '')) return 'app';
        return 'loading';

      case 'clickGoogle':
        // A plain <button type=submit name=provider value=Google id=submitGoogle>
        // in the login form — a full-page POST, not a popup. The id is the one
        // stable handle on that page.
        return clickOnce(document.querySelector('#submitGoogle'));

      case 'forms':
        return forms();

      /* Just row 0's name. The clone and the rename are both watched by waiting
       * on this, and it is re-read on every mutation of a 20-row list — no
       * reason to ship the whole list back each time. */
      case 'topTitle': {
        const row = rows()[0];
        return row ? titleOf(row) : null;
      }

      /* Is there already a form with this exact name carrying TODAY's date?
       *
       * The row's date is PARSED rather than string-compared against a date we
       * format ourselves: matching "4 Sept 2026" by hand would mean matching the
       * site's locale, its month abbreviations and its timezone, and would stop
       * matching silently the day any of the three changed. "Sept" is not a month
       * name JavaScript accepts, so it is clipped to three letters first.
       *
       * Same NAME and same DAY is the signal — a name reused months later is a
       * different workshop and perfectly legitimate; a second one this afternoon
       * means the automation is about to run twice for the same session.
       */
      case 'duplicate': {
        const dayOf = (s) => {
          const m = (s || '').match(/^(\d{1,2})\s+([A-Za-z]+)\s+(\d{4})$/);
          if (!m) return null;
          const d = new Date(`${m[1]} ${m[2].slice(0, 3)} ${m[3]}`);
          return isNaN(d) ? null : `${d.getFullYear()}-${d.getMonth() + 1}-${d.getDate()}`;
        };
        const now = new Date();
        const today = `${now.getFullYear()}-${now.getMonth() + 1}-${now.getDate()}`;
        const dup = forms().find((f) => f.title === arg && dayOf(f.date) === today);
        return dup ? { title: dup.title, date: dup.date, meta: dup.meta } : null;
      }

      /* Say why we stopped, in the page, where the eye already is. A console
       * message would be invisible: this tab was opened by the automation and is
       * the only thing on screen at that moment. */
      case 'showError': {
        const id = 'va-feedback-error';
        document.getElementById(id)?.remove();
        const el = document.createElement('div');
        el.id = id;
        el.textContent = arg;
        el.style.cssText = [
          'position:fixed', 'inset:0 0 auto 0', 'z-index:2147483647',
          'background:#b3261e', 'color:#fff',
          'font:600 20px/1.4 -apple-system,BlinkMacSystemFont,Segoe UI,sans-serif',
          'padding:18px 24px', 'text-align:center',
          'box-shadow:0 6px 24px rgba(0,0,0,.35)',
        ].join(';');
        document.documentElement.appendChild(el);
        return true;
      }

      /* Clicking the title TOGGLES the row, and a fresh clone arrives already
       * expanded — so this only clicks a closed row, and then not again for
       * 600ms. Without that floor the observer would re-enter mid-animation and
       * fold the row back shut. */
      case 'expand': {
        if (expanded(arg)) return true;
        const row = rows()[arg];
        if (!row) return false;
        const el = titleEl(row) || row;
        const last = Number(el.dataset.vaExpandAt || 0);
        if (Date.now() - last > 600) {
          el.dataset.vaExpandAt = String(Date.now());
          el.click();
        }
        return expanded(arg);
      }

      case 'expanded':
        return expanded(arg);

      case 'action': {
        const row = rows()[arg.i];
        if (!row) return false;
        return clickOnce(actionBtn(row, arg.label));
      }

      case 'dialogValue': {
        const inp = document.querySelector('mat-dialog-container input');
        return inp ? inp.value : null;
      }

      case 'setTitle': {
        const inp = document.querySelector('mat-dialog-container input');
        if (!inp) return false;
        if (inp.value !== arg) {
          inp.value = arg;
          // Angular's form model listens on the native events; assigning .value
          // alone leaves it holding the old title and SAVE writes that instead.
          inp.dispatchEvent(new Event('input', { bubbles: true }));
          inp.dispatchEvent(new Event('change', { bubbles: true }));
        }
        return inp.value === arg;
      }

      case 'save': {
        const dlg = document.querySelector('mat-dialog-container');
        if (!dlg) return false;
        return clickOnce(Array.from(dlg.querySelectorAll('button')).find((x) => /^save$/i.test(trim(x.innerText))));
      }

      case 'dialogGone':
        return !document.querySelector('mat-dialog-container');

      /* One step, three possible states, so the wait can hold out for a real
       * outcome instead of accepting "no button yet" as "already published".
       * 'done' — the share URL is on the page, publishing is behind us.
       * 'clicked' — PUBLISH NOW was there and has now been pressed, once.
       * null — the launch page has not rendered its button yet; keep waiting. */
      case 'publishStep': {
        if (run('shareUrl', null)) return 'done';
        const b = Array.from(document.querySelectorAll('button, a')).find(
          (e) => e.offsetParent !== null && /publish\s*now/i.test(e.innerText || '')
        );
        if (!b) return null;
        clickOnce(b);
        return 'clicked';
      }

      case 'shareUrl': {
        const el = document.querySelector('div.launch-url');
        const m = (el ? trim(el.textContent) : document.body.innerText || '').match(URL_RE);
        return m ? m[0] : null;
      }

      case 'onLaunchPage':
        return /\/launch(\?|$)/.test(location.pathname + location.search);

      default:
        return null;
    }
  }

  /** The serialisable half of a predicate — the other half lives in the worker. */
  function satisfied(v, e) {
    switch (e.kind) {
      case 'eq': return v === e.v;
      case 'in': return e.v.indexOf(v) !== -1;
      case 'notIn': return e.v.indexOf(v) === -1;
      case 'text': return typeof v === 'string';
      case 'url': return typeof v === 'string' && v.length > 0;
      case 'truthy':
      default: return !!v;
    }
  }

  const attempt = () => {
    // An operation reading a half-rendered row can throw; that is simply "not
    // yet", never a reason to abandon the wait.
    try {
      const v = run(op, arg);
      return satisfied(v, expect) ? { ok: true, value: v } : null;
    } catch {
      return null;
    }
  };

  if (!expect) return run(op, arg);

  // The overwhelmingly common case: it is already true, and this costs nothing.
  const now = attempt();
  if (now) return now;

  return new Promise((resolve) => {
    let done = false;
    let scheduled = false;
    const finish = (out) => {
      if (done) return;
      done = true;
      observer.disconnect();
      clearInterval(ticker);
      clearTimeout(budget);
      resolve(out);
    };
    const check = () => {
      scheduled = false;
      const hit = attempt();
      if (hit) finish(hit);
    };
    // A single Angular render fires mutations in bursts; coalescing them onto
    // the next frame turns a burst into one evaluation without adding latency
    // that anyone could see.
    const schedule = () => {
      if (scheduled || done) return;
      scheduled = true;
      requestAnimationFrame(check);
    };
    const observer = new MutationObserver(schedule);
    observer.observe(document.documentElement, {
      childList: true, subtree: true, attributes: true, characterData: true,
    });
    const ticker = setInterval(check, SAFETY_POLL_MS);
    const budget = setTimeout(() => finish({ ok: false }), budgetMs);
  });
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const inject = (tabId, args) =>
  chrome.scripting.executeScript({ target: { tabId }, func: pageOp, args });

async function exec(tabId, op, arg) {
  const [res] = await inject(tabId, [op, arg ?? null, null, 0]);
  return res ? res.result : null;
}

/**
 * Block until a page operation's value satisfies `expect`.
 *
 * The waiting itself happens in the page (see `pageOp`); this loop exists only
 * to survive the document being swapped underneath it — the login bounce and
 * the Send navigation both destroy the frame mid-wait, which rejects the
 * injection. That is expected, not fatal: re-inject into whatever document
 * replaced it and carry on against the same deadline.
 */
async function waitFor(tabId, op, arg, expect, timeoutMs, label) {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    const budget = Math.min(WAIT_CHUNK_MS, deadline - Date.now());
    if (budget <= 0) break;
    let out = null;
    try {
      const [res] = await inject(tabId, [op, arg ?? null, expect, budget]);
      out = res ? res.result : null;
    } catch {
      await sleep(50);   // navigating, or the document is not there yet
      continue;
    }
    if (out && out.ok) return out.value;
  }
  throw new Error(`timed out waiting for ${label}`);
}

const TRUTHY = { kind: 'truthy' };
const SETTLED = { kind: 'notIn', v: ['loading', null] };
const TEXT = { kind: 'text' };
const URLISH = { kind: 'url' };
const eq = (v) => ({ kind: 'eq', v });
const oneOf = (...v) => ({ kind: 'in', v });

/** Get the tab onto the dashboard, taking the Google door if it is shut. */
async function reachDashboard(tabId) {
  let screen = await waitFor(tabId, 'screen', null, SETTLED, 45_000, 'the page to settle');
  if (screen === 'login') {
    await waitFor(tabId, 'clickGoogle', null, TRUTHY, 15_000, 'the Sign in with Google button');
    screen = await waitFor(tabId, 'screen', null, oneOf('app', 'dashboard'), 90_000, 'the sign-in to go through');
  }
  if (screen !== 'dashboard') {
    // Google drops us on /en-GB/home, which has a NEW FORM button but no rows.
    await chrome.tabs.update(tabId, { url: DASHBOARD });
    await waitFor(tabId, 'screen', null, eq('dashboard'), 45_000, 'the forms list');
  }
}

/**
 * Clone the newest form, name it after the session, publish it, and hand the
 * link to the Mac. Leaves the tab open on purpose — on success it is the QR
 * code page, and on failure it is the evidence.
 */
export async function publishFeedbackForm(session) {
  if (!session) throw new Error('no session name in the command');
  const tab = await chrome.tabs.create({ url: DASHBOARD, active: true });
  const tabId = tab.id;
  const started = Date.now();
  try {
    const url = await run(tabId, session);
    console.log(`[feedback-form] done in ${((Date.now() - started) / 1000).toFixed(1)}s`);
    return url;
  } catch (e) {
    /* Every failure ends up on the page, not just in the console: this tab was
     * opened by the automation and is what Victor is looking at. Painting the
     * reason there is the difference between "it stopped" and "it stopped
     * because today already has one of these". */
    console.log('[feedback-form] stopped:', e.message);
    await exec(tabId, 'showError', `Feedback form not created — ${e.message}`).catch(() => {});
    throw e;
  }
}

async function run(tabId, session) {
  console.log('[feedback-form] publishing for', session);

  await reachDashboard(tabId);

  const list = await exec(tabId, 'forms');
  if (!list || !list.length) throw new Error('dashboard has no forms');

  /* Anti-double-run. Checked BEFORE the Copy, because after it the damage is
   * done: a second clone exists and has to be deleted by hand. The offer can be
   * accepted twice easily enough — two reminder slots, plus the menu item — and
   * a workshop wants exactly one link. */
  const dup = await exec(tabId, 'duplicate', session);
  if (dup) {
    throw new Error(`"${session}" already exists for today (${dup.date}) — publish it from that form, or rename it first`);
  }

  const source = list[0].title;                 // Recent view: newest first
  console.log('[feedback-form] cloning', source);

  await waitFor(tabId, 'expand', 0, TRUTHY, 15_000, 'the newest form to expand');
  await waitFor(tabId, 'action', { i: 0, label: 'Copy' }, TRUTHY, 15_000, 'the Copy button');

  // Not "the list grew" — the dashboard renders a fixed 20 rows.
  const cloneTitle = `Clone of: ${source}`;
  await waitFor(tabId, 'topTitle', null, eq(cloneTitle), 30_000, `the clone "${cloneTitle}" to reach the top`);

  await waitFor(tabId, 'expand', 0, TRUTHY, 15_000, 'the clone to be expanded');
  await waitFor(tabId, 'action', { i: 0, label: 'Rename' }, TRUTHY, 15_000, 'the Rename button');
  await waitFor(tabId, 'dialogValue', null, TEXT, 15_000, 'the rename dialog');
  await waitFor(tabId, 'setTitle', session, TRUTHY, 5_000, 'the new title to stick');
  await waitFor(tabId, 'save', null, TRUTHY, 5_000, 'the SAVE button');
  await waitFor(tabId, 'topTitle', null, eq(session), 20_000, `the row to read "${session}"`);

  await waitFor(tabId, 'expand', 0, TRUTHY, 15_000, 'the renamed row to be expanded');
  await waitFor(tabId, 'action', { i: 0, label: 'Send' }, TRUTHY, 15_000, 'the Send button');
  await waitFor(tabId, 'onLaunchPage', null, TRUTHY, 30_000, 'the Send page');

  // 'done' means it was already published — idempotent either way.
  await waitFor(tabId, 'publishStep', null, oneOf('clicked', 'done'), 20_000, 'the PUBLISH NOW button');
  const url = await waitFor(tabId, 'shareUrl', null, URLISH, 45_000, 'the share URL');

  console.log('[feedback-form] published', url);
  /* /feedback-form/published, not /link/publish: this route does the same
   * three local things (clipboard, 🔳 banner, notes) AND hands the link to the
   * training daemon, which reveals it as a row in every participant's left-hand
   * menu in Interact. The generic route stays generic — putting an arbitrary
   * link on the projected screen must never also push it to the room. */
  const res = await fetch(
    `${ADDONS}/feedback-form/published?url=${encodeURIComponent(url)}&title=${encodeURIComponent(session)}`
  ).catch(() => null);
  console.log('[feedback-form] handed to the Mac:', res && res.ok ? await res.text() : 'FAILED');
  return url;
}
