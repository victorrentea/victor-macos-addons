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

/**
 * Everything that touches the page, in one injectable function.
 *
 * It has to be one function because `chrome.scripting.executeScript` serialises
 * what it injects: nothing here can close over module scope, so the helpers and
 * the operations travel together and are re-created on every call. Cheap, and
 * the alternative (a content script holding state) would not survive the
 * navigations this flow makes.
 */
function pageOp(op, arg) {
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
  const URL_RE = /https?:\/\/[^\s]*freeonlinesurveys\.com\/s\/[A-Za-z0-9_-]+/;

  switch (op) {
    // Which of the two screens are we on, once the page has made up its mind?
    // Positive markers only — the URL lies for the first second or two.
    case 'screen':
      if (location.host === 'identity.freeonlinesurveys.com') return 'login';
      if (rows().length > 0) return 'dashboard';
      if (/new form/i.test(document.body.innerText || '')) return 'app';
      return 'loading';

    case 'clickGoogle': {
      // A plain <button type=submit name=provider value=Google id=submitGoogle>
      // in the login form — a full-page POST, not a popup. The id is the one
      // stable handle on that page.
      const b = document.querySelector('#submitGoogle');
      if (!b) return false;
      b.click();
      return true;
    }

    case 'forms':
      return forms();

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

    case 'expand': {
      // Only click if it is closed: a fresh clone arrives already expanded.
      if (expanded(arg)) return true;
      const row = rows()[arg];
      if (!row) return false;
      (titleEl(row) || row).click();
      return expanded(arg);
    }

    case 'expanded':
      return expanded(arg);

    case 'action': {
      const row = rows()[arg.i];
      if (!row) return false;
      const b = actionBtn(row, arg.label);
      if (!b) return false;
      b.click();
      return true;
    }

    case 'dialogValue': {
      const inp = document.querySelector('mat-dialog-container input');
      return inp ? inp.value : null;
    }

    case 'setTitle': {
      const inp = document.querySelector('mat-dialog-container input');
      if (!inp) return false;
      inp.value = arg;
      // Angular's form model listens on the native events; assigning .value
      // alone leaves it holding the old title and SAVE writes that instead.
      inp.dispatchEvent(new Event('input', { bubbles: true }));
      inp.dispatchEvent(new Event('change', { bubbles: true }));
      return inp.value === arg;
    }

    case 'save': {
      const dlg = document.querySelector('mat-dialog-container');
      if (!dlg) return false;
      const b = Array.from(dlg.querySelectorAll('button')).find((x) => /^save$/i.test(trim(x.innerText)));
      if (!b) return false;
      b.click();
      return true;
    }

    case 'dialogGone':
      return !document.querySelector('mat-dialog-container');

    case 'publishNow': {
      const b = Array.from(document.querySelectorAll('button, a')).find(
        (e) => e.offsetParent !== null && /publish\s*now/i.test(e.innerText || '')
      );
      if (!b) return 'absent';                 // already published
      b.click();
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

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function exec(tabId, op, arg) {
  const [res] = await chrome.scripting.executeScript({ target: { tabId }, func: pageOp, args: [op, arg ?? null] });
  return res ? res.result : null;
}

/**
 * Poll a page operation until `ok(value)` holds.
 *
 * Everything in this flow is an animated Angular transition, so "the element is
 * in the DOM" and "the element is where it will end up" are different moments;
 * polling the value is the only honest wait. A navigation mid-poll makes
 * executeScript throw — that is expected, not fatal, so it is swallowed.
 */
async function until(tabId, op, arg, ok, timeoutMs, label) {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    let v = null;
    try { v = await exec(tabId, op, arg); } catch { /* navigating */ }
    if (ok(v)) return v;
    if (Date.now() > deadline) throw new Error(`timed out waiting for ${label}`);
    await sleep(300);
  }
}

const truthy = (v) => !!v;

/** Get the tab onto the dashboard, taking the Google door if it is shut. */
async function reachDashboard(tabId) {
  let screen = await until(tabId, 'screen', null, (v) => v && v !== 'loading', 45_000, 'the page to settle');
  if (screen === 'login') {
    await until(tabId, 'clickGoogle', null, truthy, 15_000, 'the Sign in with Google button');
    screen = await until(tabId, 'screen', null, (v) => v === 'app' || v === 'dashboard', 90_000, 'the sign-in to go through');
  }
  if (screen !== 'dashboard') {
    // Google drops us on /en-GB/home, which has a NEW FORM button but no rows.
    await chrome.tabs.update(tabId, { url: DASHBOARD });
    await until(tabId, 'screen', null, (v) => v === 'dashboard', 45_000, 'the forms list');
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
  try {
    return await run(tabId, session);
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

  await until(tabId, 'expand', 0, truthy, 15_000, 'the newest form to expand');
  await until(tabId, 'action', { i: 0, label: 'Copy' }, truthy, 15_000, 'the Copy button');

  // Not "the list grew" — the dashboard renders a fixed 20 rows.
  const cloneTitle = `Clone of: ${source}`;
  await until(tabId, 'forms', null, (v) => v && v[0] && v[0].title === cloneTitle,
    30_000, `the clone "${cloneTitle}" to reach the top`);

  await until(tabId, 'expand', 0, truthy, 15_000, 'the clone to be expanded');
  await until(tabId, 'action', { i: 0, label: 'Rename' }, truthy, 15_000, 'the Rename button');
  await until(tabId, 'dialogValue', null, (v) => typeof v === 'string', 15_000, 'the rename dialog');
  await until(tabId, 'setTitle', session, truthy, 5_000, 'the new title to stick');
  await until(tabId, 'save', null, truthy, 5_000, 'the SAVE button');
  await until(tabId, 'forms', null, (v) => v && v[0] && v[0].title === session,
    20_000, `the row to read "${session}"`);

  await until(tabId, 'expand', 0, truthy, 15_000, 'the renamed row to be expanded');
  await until(tabId, 'action', { i: 0, label: 'Send' }, truthy, 15_000, 'the Send button');
  await until(tabId, 'onLaunchPage', null, truthy, 30_000, 'the Send page');

  // Absent means it is already published — idempotent either way.
  await until(tabId, 'publishNow', null, (v) => v === 'clicked' || v === 'absent', 20_000, 'the PUBLISH NOW button');
  const url = await until(tabId, 'shareUrl', null, (v) => typeof v === 'string' && v.length > 0,
    45_000, 'the share URL');

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
