// Right-click an image → "Save Image to Downloads": straight into the Downloads
// folder, no Save As dialog. Chrome picks the file name from the URL.
//
// It cannot sit right under Chrome's own "Save Image As…": an extension's items
// always go in the extensions block at the bottom of the context menu.

const MENU_ID = 'save-image-to-downloads';

export function installSaveImage() {
  // Context menus persist across worker restarts, so create once per install;
  // removeAll first so a reload never trips over a duplicate id.
  chrome.runtime.onInstalled.addListener(() => {
    chrome.contextMenus.removeAll(() => {
      chrome.contextMenus.create({ id: MENU_ID, title: 'Save Image to Downloads', contexts: ['image'] });
    });
  });

  chrome.contextMenus.onClicked.addListener((info) => {
    if (info.menuItemId !== MENU_ID || !info.srcUrl) return;
    chrome.downloads.download({ url: info.srcUrl, saveAs: false, conflictAction: 'uniquify' });
  });
}
