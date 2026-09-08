// Victor Chrome Addons — the Chrome half of Victor Addons.
//
// One socket to the Mac app, two jobs behind it:
//   • dictation-pause.js   pause the music while Wispr Flow is dictating
//   • feedback-form.js     clone/rename/publish the session's feedback survey
//   • focus-tab.js         send ⌘⌃L/G/N/F to the tab that is already open
//
// This file owns nothing but the transport. The Mac app (Victor Addons) pushes
// commands over a WebSocket on 127.0.0.1:8766 and each feature module handles
// its own message type.
//
// Why the survey automation lives HERE rather than in a scripted browser of its
// own: FreeOnlineSurveys signs in through Google, so any other browser needs a
// second Google sign-in to reach the account. This extension runs inside the
// browser that is already signed in — which is the whole reason it exists.

import { onDictation } from './dictation-pause.js';
import { publishFeedbackForm } from './feedback-form.js';
import { focusOrOpen } from './focus-tab.js';

const PORT = 8766;
const RECONNECT_MIN_MS = 1000;
const RECONNECT_MAX_MS = 30000;

/// How long the reconnect alarm waits, in minutes. **The slow one is not
/// impatience, it is noise control.** Chrome writes its own
/// `net::ERR_CONNECTION_REFUSED` line into this extension's log for every failed
/// WebSocket, and no handler here can suppress it — so while the Mac app is off
/// (a rebuild, a night), a 30-second retry fills chrome://extensions with
/// hundreds of entries that hide the one that matters. Retrying is cheap; the
/// log entry is the cost, so the interval follows how likely the app is to be
/// there: fast right after a drop, slow once it is clearly gone.
const ALARM_FAST_MIN = 0.5;
const ALARM_SLOW_MIN = 5;
/// Failures before the alarm gives up on "it is coming right back". Four at half
/// a minute covers a rebuild-and-restart; a night does not deserve 2000 lines.
const FAILURES_BEFORE_SLOW = 4;

let socket = null;
let reconnectDelay = RECONNECT_MIN_MS;

/// Chrome collects console output from a service worker, but only DevTools
/// opened by hand on that worker will show it. Mirroring it to the Mac puts it
/// in `/tmp/victor-macos-addons.log` next to the app's own lines, in the order
/// they happened — readable from a terminal, and from an agent.
function log(...args) {
  console.log(...args);
  report('info', args);
}

function logError(...args) {
  console.error(...args);
  report('error', args);
}

/// Never throws and never logs: a failure to ship a log line must not become a
/// log line, or one dropped frame becomes a loop.
function report(level, args) {
  if (!socket || socket.readyState !== WebSocket.OPEN) return;
  try {
    const text = args.map((a) => (typeof a === 'string' ? a : safe(a))).join(' ');
    socket.send(JSON.stringify({ type: 'log', level, text }));
  } catch {}
}

function safe(value) {
  if (value instanceof Error) return `${value.name}: ${value.message}`;
  try { return JSON.stringify(value); } catch { return String(value); }
}

/// How many connects in a row have failed. In `chrome.storage.session`, not a
/// variable, for the same reason `dictation-pause.js` keeps its state there: the
/// worker this counter would live in is torn down between two alarm ticks, so a
/// variable resets to zero every wake and the count never reaches anything.
async function noteConnectResult(ok) {
  const { failures = 0 } = await chrome.storage.session.get('failures');
  const now = ok ? 0 : failures + 1;
  if (now !== failures) await chrome.storage.session.set({ failures: now });
  await armAlarm(now);
}

/// Arm the reconnect alarm at the period the failure count calls for, and
/// **only if it is not already armed there** — `chrome.alarms.create` on an
/// existing name restarts its clock, and this runs on every worker wake, so
/// re-arming unconditionally would keep pushing the next tick away.
async function armAlarm(failures) {
  if (failures === undefined) {
    ({ failures = 0 } = await chrome.storage.session.get('failures'));
  }
  const period = failures >= FAILURES_BEFORE_SLOW ? ALARM_SLOW_MIN : ALARM_FAST_MIN;
  const existing = await chrome.alarms.get('reconnect');
  if (existing && existing.periodInMinutes === period) return;
  chrome.alarms.create('reconnect', { periodInMinutes: period });
}

/* The Mac replays the dictation state on connect, so a `dictation` message may
 * be a replay rather than an edge — the module handles that. A
 * `publish-feedback-form` and `focus-or-open` are never replayed: they are
 * one-shot commands, sent on a menu press and a hotkey respectively. */
function dispatch(msg) {
  switch (msg.type) {
    case 'ping':
      return;                                  // keeps this worker resident
    case 'dictation':
      return onDictation(!!msg.active).catch((e) => logError('[addons] dictation failed', e));
    case 'publish-feedback-form':
      return publishFeedbackForm(msg.session).catch((e) => logError('[addons] feedback form failed', e));
    case 'focus-or-open':
      return focusOrOpen(msg).catch((e) => logError('[addons] focus-or-open failed', e));
    case 'reload':
      // Re-reads this unpacked extension from disk. It is here because nothing
      // outside Chrome can press Reload on chrome://extensions — that page is
      // closed to extensions, and codex refuses browser control — so a change to
      // these files used to end with a manual click. We are already inside the
      // browser; we can just do it.
      log('[addons] reloading on request from the Mac');
      return chrome.runtime.reload();
    default:
      return;
  }
}

function connect() {
  if (socket && (socket.readyState === WebSocket.OPEN || socket.readyState === WebSocket.CONNECTING)) return;
  socket = new WebSocket(`ws://127.0.0.1:${PORT}`);

  socket.onopen = () => {
    reconnectDelay = RECONNECT_MIN_MS;
    // **Say what we understand.** Rebuilding the Mac app does not reload an
    // unpacked extension, so an old worker can sit on this socket dropping every
    // message type it has never heard of — and the app, seeing a connection, used
    // to hand it work that then vanished. The app now waits for a feature to be
    // named before routing anything through it, and falls back to its own path
    // otherwise. Add the name here in the same commit that adds the handler.
    socket.send(JSON.stringify({ type: 'hello', features: ['dictation', 'publish-feedback-form', 'focus-or-open', 'reload'] }));
    noteConnectResult(true);
    log('[addons] connected to Victor Addons');
  };

  socket.onmessage = (event) => {
    let msg;
    try { msg = JSON.parse(event.data); } catch { return; }
    dispatch(msg);
  };

  const retry = () => {
    socket = null;
    noteConnectResult(false);
    setTimeout(connect, reconnectDelay);
    reconnectDelay = Math.min(reconnectDelay * 2, RECONNECT_MAX_MS);
  };
  socket.onclose = retry;
  socket.onerror = () => { try { socket.close(); } catch {} };
}

// **An alarm, because a sleeping worker cannot reconnect itself.** The socket
// keeps this worker resident while it is open, and the retry above covers a drop
// the worker is awake to see. Neither covers the case that actually happened: the
// Mac app restarts, the socket closes, and Chrome recycles the worker before the
// retry fires — after which nothing in this extension is running to notice, and
// the pause silently stops working until something else wakes it. An alarm is the
// only thing that wakes a dead MV3 worker on a schedule, so it is the floor under
// the whole mechanism. `connect()` is a no-op while a socket is already open.
armAlarm();
chrome.alarms.onAlarm.addListener((alarm) => {
  if (alarm.name === 'reconnect') connect();
});

chrome.runtime.onStartup.addListener(connect);
chrome.runtime.onInstalled.addListener(connect);
connect();
