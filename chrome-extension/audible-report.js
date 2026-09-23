// Tell the Mac how many tabs are making sound, every time that number moves.
//
// The Mac's "is something else playing?" guard (SystemAudioActivity) reads
// CoreAudio's per-process `IsRunningOutput`, and Chrome's audio helper holds
// its output stream open long after the sound stops — measured 2026-09-23 at
// RMS 0 with nothing playing, which vetoed the lid-awake heartbeat's volume
// boost and left the pulse at a slider of 13. Chrome cannot be skipped
// outright the way Wispr or Krisp are: it is where the music plays. `audible`
// is Chrome's own per-tab answer, so the Mac asks it instead.

export function watchAudible(send) {
  let last = -1;
  const report = async () => {
    const n = (await chrome.tabs.query({ audible: true })).length;
    if (n === last) return;
    last = n;
    send({ type: 'audible', tabs: n });
  };
  chrome.tabs.onUpdated.addListener((_id, change) => { if ('audible' in change) report(); });
  chrome.tabs.onRemoved.addListener(() => report());
  // A fresh socket starts from "unknown" on the Mac, so the first report is
  // always sent, even when the number did not move.
  return () => { last = -1; return report(); };
}
