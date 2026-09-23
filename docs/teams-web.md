# 🎙️ Teams web as a guest: noise suppression Off + screen share with system audio

`chrome-extension/teams-guest-audio.js`: a content script in the page's own JS world
(`"world": "MAIN"`, `document_start`) on `teams.microsoft.com`, `teams.cloud.microsoft`
and `teams.live.com`. Victor joins client meetings **by link, as a guest, in Chrome**.
Before the script, two settings had to be fixed by hand in every meeting.

## Noise suppression resets in every meeting, by design
Measured 2026-09-23 in a live guest meeting: Teams stores the mode in `localStorage`
**per tenant and per meeting thread**:

```
tmp.<tenant>.8:defaultOid:anon.prod.<tenant>.<19:meeting_…@thread.v2>.react-web-client.noiseSuppressionMode = "\"Auto\""
```

(`tmp.default.default.light-meetings.noiseSuppressionMode` is the pre-join one.) A new
link means a new key, which starts at `"Auto"`, so no setting can stick. The script
overrides `Storage.prototype.getItem`: any `….noiseSuppressionMode` key reads `"Off"`,
unless Teams wrote it in this same page, so a switch flipped mid-meeting still works
until the next reload.

## "Share with system audio" is Chrome's switch, not Teams'
Teams already calls `getDisplayMedia({video: …, audio: {restrictOwnAudio: true}})`. The
switch lives in **Chrome's** picker, where Entire screen / Window start **off**. The
script adds the following to that call:

- `audioSelection: 'preferred'`: the switch starts **on**. Verified live on the Entire
  screen tab of the Chrome picker, 2026-09-23.
- `noiseSuppression / echoCancellation / autoGainControl: false`: without them Chrome
  ran all three on the system sound (and delivered it mono). With them it arrives
  stereo and raw.
- `systemAudio: 'include'`: already the default. It's there so a future default flip
  doesn't silently cost the sound.

Chrome captures `loopbackWithoutChrome`, so meeting audio played by Chrome itself is not
sent back to the participants.

## Deploy / check
`curl localhost:55123/chrome/extension/reload`, then **reload the Teams tab** (the script
has to be there before Teams starts). Console at level Verbose: `[teams-guest-audio] active`.

Not verified yet: that Teams really *reads* the key through `getItem` at join time,
rather than from a cache primed earlier. Check it in the first meeting after the deploy.
