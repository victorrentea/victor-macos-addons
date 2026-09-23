// Runs in the page's own JS world before Teams loads.
(() => {
  const TAG = '[teams-guest-audio]';

  // 1. Noise suppression Off by default.
  // Teams keeps the mode per tenant AND per meeting, e.g.
  //   tmp.<tenant>…<meeting-thread>.react-web-client.noiseSuppressionMode = "\"Auto\""
  // so every new meeting starts on Auto. Any key never touched in this page
  // reads as Off; a choice made during the meeting still wins until reload.
  const NS_KEY = /\.noiseSuppressionMode$/;
  const chosenThisPage = new Map();
  const { getItem, setItem } = Storage.prototype;
  Storage.prototype.getItem = function (key) {
    if (this === localStorage && NS_KEY.test(key)) {
      return chosenThisPage.get(key) ?? '"Off"';
    }
    return getItem.call(this, key);
  };
  Storage.prototype.setItem = function (key, value) {
    if (this === localStorage && NS_KEY.test(key)) chosenThisPage.set(key, String(value));
    return setItem.call(this, key, value);
  };

  // 2. Screen share: "Share with system audio" pre-ticked, and the system
  // sound delivered raw (Chrome otherwise runs noise suppression, echo
  // cancellation and auto gain on it, which mangles music and demo sounds).
  const nativeGetDisplayMedia = MediaDevices.prototype.getDisplayMedia;
  MediaDevices.prototype.getDisplayMedia = function (constraints = {}) {
    const audio = typeof constraints.audio === 'object' ? constraints.audio : {};
    const patched = {
      ...constraints,
      audio: { ...audio, noiseSuppression: false, echoCancellation: false, autoGainControl: false },
      systemAudio: 'include',
      audioSelection: 'preferred',
    };
    console.debug(TAG, 'getDisplayMedia', patched);
    return nativeGetDisplayMedia.call(this, patched);
  };

  console.debug(TAG, 'active');
})();
