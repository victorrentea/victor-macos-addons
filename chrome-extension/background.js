// Victor Chrome Addons — the Chrome half of Victor Addons.
//
// One socket to the Mac app, two jobs behind it:
//   • dictation-pause.js   pause the music while Wispr Flow is dictating
//   • feedback-form.js     clone/rename/publish the session's feedback survey
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

const PORT = 8766;
const RECONNECT_MIN_MS = 1000;
const RECONNECT_MAX_MS = 30000;

let socket = null;
let reconnectDelay = RECONNECT_MIN_MS;

/* The Mac replays the dictation state on connect, so a `dictation` message may
 * be a replay rather than an edge — the module handles that. A
 * `publish-feedback-form` is never replayed: it is a one-shot command, and the
 * Mac only sends it on a menu press. */
function dispatch(msg) {
  switch (msg.type) {
    case 'ping':
      return;                                  // keeps this worker resident
    case 'dictation':
      return onDictation(!!msg.active).catch((e) => console.log('[addons] dictation failed', e));
    case 'publish-feedback-form':
      return publishFeedbackForm(msg.session).catch((e) => console.log('[addons] feedback form failed', e));
    default:
      return;
  }
}

function connect() {
  if (socket && (socket.readyState === WebSocket.OPEN || socket.readyState === WebSocket.CONNECTING)) return;
  socket = new WebSocket(`ws://127.0.0.1:${PORT}`);

  socket.onopen = () => {
    reconnectDelay = RECONNECT_MIN_MS;
    console.log('[addons] connected to Victor Addons');
  };

  socket.onmessage = (event) => {
    let msg;
    try { msg = JSON.parse(event.data); } catch { return; }
    dispatch(msg);
  };

  const retry = () => {
    socket = null;
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
chrome.alarms.create('reconnect', { periodInMinutes: 0.5 });
chrome.alarms.onAlarm.addListener((alarm) => {
  if (alarm.name === 'reconnect') connect();
});

chrome.runtime.onStartup.addListener(connect);
chrome.runtime.onInstalled.addListener(connect);
connect();
