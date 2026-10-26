// Google search → a "GIF" toggle next to Tools (Instrumente).
//
// Google Images does have an "animated only" filter, but it sits two clicks deep
// (Tools → Type → GIF) and Victor could not find it. The filter itself is just
// `tbs=itp:animated` in the URL, so this pill is a plain link that adds or removes
// it, and switches to the Images tab (`udm=2`) on the way in — the filter means
// nothing on the "All" tab.
//
// Google's class names are minified and change, so the anchor is found by its
// text (the Tools button) with the tab strip (`[role=list]`) as fallback. The
// page re-renders that strip on its own, hence the observer that puts the pill
// back whenever it disappears.

const PILL_ID = 'vr-gif-toggle';
const FILTER = 'itp:animated';

function tbsParts(url) {
  return (url.searchParams.get('tbs') || '').split(',').filter(Boolean);
}

function isOn(url) {
  return tbsParts(url).includes(FILTER);
}

function toggledHref() {
  const url = new URL(location.href);
  const rest = tbsParts(url).filter((p) => p !== FILTER);
  if (isOn(url)) {
    if (rest.length) url.searchParams.set('tbs', rest.join(','));
    else url.searchParams.delete('tbs');
  } else {
    url.searchParams.set('tbs', [...rest, FILTER].join(','));
    url.searchParams.set('udm', '2');
    url.searchParams.delete('start');          // page 2 of stills is not page 2 of GIFs
  }
  return url.href;
}

function anchor() {
  const tools = [...document.querySelectorAll('[role=button]')]
    .find((el) => /^(Instrumente|Tools)$/.test(el.textContent.trim()));
  if (tools) return { el: tools, where: 'afterend' };
  const tabs = document.querySelector('[role=list]');
  if (tabs) return { el: tabs, where: 'beforeend' };
  return null;
}

function pill() {
  const on = isOn(new URL(location.href));
  const a = document.createElement('a');
  a.id = PILL_ID;
  a.href = toggledHref();
  a.textContent = on ? '✓ Animated Gif' : 'Animated Gif';
  a.title = on ? 'Show all images again' : 'Only animated GIFs (Tools → Type → GIF)';
  a.style.cssText = [
    'display:inline-flex', 'align-items:center', 'align-self:center',
    'height:28px', 'padding:0 12px', 'margin-left:12px', 'border-radius:14px',
    'font:500 14px/1 Google Sans,Roboto,Arial,sans-serif', 'text-decoration:none',
    'white-space:nowrap', 'flex:none', 'cursor:pointer',
    on ? 'background:#8ab4f8;color:#202124;border:1px solid #8ab4f8'
       : 'background:transparent;color:inherit;border:1px solid currentColor',
  ].join(';');
  return a;
}

function ensure() {
  const existing = document.getElementById(PILL_ID);
  if (existing) {
    existing.href = toggledHref();             // the query may have changed under it
    return;
  }
  const spot = anchor();
  if (spot) spot.el.insertAdjacentElement(spot.where, pill());
}

ensure();
new MutationObserver(() => {
  if (!document.getElementById(PILL_ID)) ensure();
}).observe(document.documentElement, { childList: true, subtree: true });
