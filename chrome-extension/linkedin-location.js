// LinkedIn invitations → "📍 Dubai, United Arab Emirates" in the top-right corner of each card.
//
// The invitation card does not carry the sender's location, so it is read from the same
// Voyager endpoint LinkedIn's own profile page uses, with the signed-in session.
//
// Every lookup is a profile read on Victor's account, and LinkedIn polices those. So: only
// cards actually on screen, one at a time, each person once (chrome.storage.local, 90 days),
// and the first 403/429/999 stops all lookups until the next page load.
//
// LinkedIn's class names are hashed and change, so the card is found from its Accept button.
// The content script loads on all of linkedin.com because the site is a single-page app:
// walking from the feed to My Network never loads a new document.

const BADGE = 'vr-li-location';
const ACCEPT = 'button[aria-label^="Accept "][aria-label$="invitation"]';
const DECORATION = 'com.linkedin.voyager.dash.deco.identity.profile.WebTopCardCore-19';
const TTL_MS = 90 * 24 * 3600 * 1000;
const GAP_MS = 800;

const known = new Map(); // slug → Promise<location name or null>
let queue = Promise.resolve();
let stopped = false;

function cardParts(button) {
  const card = button.closest('[role=listitem], li');
  const href = card?.querySelector('a[href*="/in/"]')?.getAttribute('href') || '';
  const slug = href.match(/\/in\/([^/?#]+)/)?.[1];
  return slug ? { card, slug } : null;
}

async function fetchLocation(slug) {
  if (stopped) return undefined;
  const csrf = document.cookie.match(/JSESSIONID="?([^";]+)/)?.[1];
  const url = '/voyager/api/identity/dash/profiles?q=memberIdentity'
    + `&memberIdentity=${encodeURIComponent(slug)}&decorationId=${DECORATION}`;
  const res = await fetch(url, {
    credentials: 'include',
    headers: {
      'csrf-token': csrf,
      'x-restli-protocol-version': '2.0.0',
      accept: 'application/vnd.linkedin.normalized+json+2.1',
    },
  });
  if (!res.ok) {
    console.warn(`[linkedin-location] ${res.status} for ${slug}`);
    if ([403, 429, 999].includes(res.status)) stopped = true;
    return undefined;
  }
  const { included = [] } = await res.json();
  const geoUrn = included.find((e) => e.publicIdentifier && e.geoLocation)?.geoLocation.geoUrn;
  return included.find((e) => e.entityUrn === geoUrn)?.defaultLocalizedName ?? null;
}

async function locationOf(slug) {
  const key = `li-location:${slug}`;
  const stored = (await chrome.storage.local.get(key))[key];
  if (stored && Date.now() - stored.at < TTL_MS) return stored.name;

  const turn = queue.then(() => fetchLocation(slug));
  queue = turn.catch(() => {}).then(() => new Promise((done) => setTimeout(done, GAP_MS)));
  const name = await turn;
  if (name !== undefined) await chrome.storage.local.set({ [key]: { name, at: Date.now() } });
  return name ?? null;
}

async function decorate(button) {
  const parts = cardParts(button);
  if (!parts) return;
  const { card, slug } = parts;
  if (!known.has(slug)) known.set(slug, locationOf(slug).catch(() => null));
  const name = await known.get(slug);
  if (!name || cardParts(button)?.slug !== slug || card.querySelector(`.${BADGE}`)) return;

  const badge = document.createElement('span');
  badge.className = BADGE;
  badge.dataset.slug = slug;
  badge.textContent = `📍 ${name}`;
  badge.style.cssText = 'position:absolute;top:8px;right:16px;font-size:12px;opacity:.7;white-space:nowrap';
  card.style.position = 'relative';
  card.append(badge);
}

const onScreen = new IntersectionObserver((entries) => {
  for (const { isIntersecting, target } of entries) {
    if (!isIntersecting) continue;
    onScreen.unobserve(target);
    decorate(target);
  }
});

function scan() {
  if (!location.pathname.startsWith('/mynetwork')) return;
  for (const button of document.querySelectorAll(ACCEPT)) {
    const parts = cardParts(button);
    if (!parts) continue;
    const badge = parts.card.querySelector(`.${BADGE}`);
    if (badge?.dataset.slug === parts.slug) continue;
    badge?.remove(); // LinkedIn reuses the card element for the next invitation.
    onScreen.observe(button);
  }
}

let pending;
new MutationObserver(() => {
  clearTimeout(pending);
  pending = setTimeout(scan, 300);
}).observe(document.body, { childList: true, subtree: true });
scan();
