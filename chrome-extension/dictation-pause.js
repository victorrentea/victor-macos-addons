// Pauses the music while Victor dictates, instead of ducking its volume.
//
// The Mac app (Victor Addons) owns the dictation window: it watches Wispr
// Flow's CoreAudio process and pushes {type:"dictation", active:bool} over a
// WebSocket on 127.0.0.1:8766. Everything about *which* tab is playing is
// decided here, because that is the only place it is knowable — CoreAudio funnels
// every Chrome tab through one audio helper process, so from the outside "Chrome
// is making sound" is the finest grain available. chrome.tabs.query({audible})
// is the per-tab answer.
//
// State lives in chrome.storage.session, not in a variable: an MV3 service
// worker can be torn down between the pause and the resume, and the resume must
// still land on exactly the tabs that were paused.

const PORT = 8766;
const RECONNECT_MIN_MS = 1000;
const RECONNECT_MAX_MS = 30000;

let socket = null;
let reconnectDelay = RECONNECT_MIN_MS;

// --- the two halves of the job, injected into the page ---------------------

// Pause every media element that is actually playing, and mark it so the
// resume can find exactly those (and not the ones the user had already paused).
function pauseAudibleMedia() {
  let paused = 0;
  for (const el of document.querySelectorAll('video, audio')) {
    if (el.paused || el.ended) continue;
    el.dataset.vaDictationPaused = '1';
    el.pause();
    paused++;
  }
  return paused;
}

// Resume only what we paused. A tab the user closed the media in, or navigated
// away from, simply has nothing marked — nothing happens.
function resumeMarkedMedia() {
  let resumed = 0;
  for (const el of document.querySelectorAll('[data-va-dictation-paused]')) {
    delete el.dataset.vaDictationPaused;
    const p = el.play();
    if (p && typeof p.catch === 'function') p.catch(() => {});
    resumed++;
  }
  return resumed;
}

// --- pause / resume ---------------------------------------------------------

async function pauseEverythingAudible() {
  const { engaged } = await chrome.storage.session.get('engaged');
  if (engaged) return;                    // already paused for this dictation
  const tabs = await chrome.tabs.query({ audible: true });
  const ids = [];
  for (const tab of tabs) {
    try {
      await chrome.scripting.executeScript({
        target: { tabId: tab.id, allFrames: true },
        func: pauseAudibleMedia,
      });
      ids.push(tab.id);
    } catch (e) {
      // A tab we may not script (chrome://, the Web Store, a PDF viewer).
      console.log('[dictation-pause] cannot script tab', tab.id, e.message);
    }
  }
  await chrome.storage.session.set({ engaged: true, pausedTabs: ids });
  console.log('[dictation-pause] paused', ids.length, 'tab(s)');
}

async function resumeWhatWePaused() {
  const { engaged, pausedTabs } = await chrome.storage.session.get(['engaged', 'pausedTabs']);
  // Clear the latch first: a failure below must not leave us thinking a pause
  // is still outstanding, or the next dictation would never pause anything.
  await chrome.storage.session.set({ engaged: false, pausedTabs: [] });
  if (!engaged) return;
  for (const tabId of pausedTabs || []) {
    try {
      await chrome.scripting.executeScript({
        target: { tabId, allFrames: true },
        func: resumeMarkedMedia,
      });
    } catch (e) {
      console.log('[dictation-pause] tab gone on resume', tabId, e.message);
    }
  }
  console.log('[dictation-pause] resumed', (pausedTabs || []).length, 'tab(s)');
}

// --- the link to the Mac app ------------------------------------------------

function connect() {
  if (socket && (socket.readyState === WebSocket.OPEN || socket.readyState === WebSocket.CONNECTING)) return;
  socket = new WebSocket(`ws://127.0.0.1:${PORT}`);

  socket.onopen = () => {
    reconnectDelay = RECONNECT_MIN_MS;
    console.log('[dictation-pause] connected to Victor Addons');
  };

  socket.onmessage = (event) => {
    let msg;
    try { msg = JSON.parse(event.data); } catch { return; }
    if (msg.type === 'ping') return;      // keeps this worker resident
    if (msg.type !== 'dictation') return;
    // The app replays the state on connect, so this also recovers a worker that
    // was torn down mid-dictation and owes a resume.
    (msg.active ? pauseEverythingAudible() : resumeWhatWePaused())
      .catch((e) => console.log('[dictation-pause] failed', e));
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
