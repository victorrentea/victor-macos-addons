// Pauses the music while Victor dictates, instead of ducking its volume.
//
// The Mac app owns the dictation window: it watches Wispr Flow's CoreAudio
// process and pushes {type:"dictation", active:bool} over the bridge. Everything
// about *which* tab is playing is decided here, because that is the only place
// it is knowable — CoreAudio funnels every Chrome tab through one audio helper
// process, so from the outside "Chrome is making sound" is the finest grain
// available. chrome.tabs.query({audible}) is the per-tab answer.
//
// State lives in chrome.storage.session, not in a variable: an MV3 service
// worker can be torn down between the pause and the resume, and the resume must
// still land on exactly the tabs that were paused.

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

/**
 * The dictation window opened or closed.
 *
 * The app replays the state on connect, so this also recovers a worker that was
 * torn down mid-dictation and owes a resume.
 */
export function onDictation(active) {
  return active ? pauseEverythingAudible() : resumeWhatWePaused();
}
