# 📝 Feedback form (FreeOnlineSurveys)

The end-of-session ritual, in one menu press: clone the most recent survey,
rename the clone to the live session, publish it, and put the link in front of
the room — projected banner, clipboard, and session notes.

## The chain

```
📝 menu item (only while a session is live)
   │  or:  curl 127.0.0.1:55123/feedback-form/publish
   ▼
AppDelegate.requestFeedbackForm()      ← session name from the session folder
   ▼  ChromeBridge, ws://127.0.0.1:8766
   {"type":"publish-feedback-form","session":"AI@MassMutual"}
   ▼
chrome-extension/feedback-form.js      ← does the whole dance in Victor's Chrome
   ▼  GET 127.0.0.1:55123/feedback-form/published?url=…&title=…
AppDelegate.feedbackFormPublished()    → clipboard + 🔳 banner + session notes
   ▼  POST 127.0.0.1:1234/feedback-form
training-assistant daemon              → a row in every participant's left menu
```

**Why the automation lives in the Chrome extension.** FreeOnlineSurveys signs in
through Google. A scripted browser of its own (the first attempt was a Playwright
CLI on a dedicated profile) therefore needs a *second* Google sign-in before it
can do anything, and that sign-in never happened — the robot sat at a login page.
The extension runs inside the browser that is already signed in, which removes
the credential problem rather than working around it.

**Why fire-and-forget.** The bridge command gets no reply. The work takes tens of
seconds and an MV3 service worker can be torn down and resurrected in the middle
of it; a reply channel would have to survive that, whereas an HTTP call from
whichever worker is alive at the end does not. The link arriving on screen *is*
the acknowledgement.

## HTTP surface (`:55123`)

| route | does |
|---|---|
| `GET /session/name` | `{"ok":true,"name":"AI@MM","folder":"…"}` — the session folder with its date prefix stripped, or `{"ok":false,"reason":"no-session"}` |
| `GET /feedback-form/publish` | asks Chrome for a fresh form; fails with `no-chrome-extension` when nothing is on the socket |
| `GET /feedback-form/published?url=…&title=…` | the whole landing: clipboard + 🔳 banner + notes + the participants' menu |
| `GET /link/publish?url=…` | clipboard + 🔳 banner + a line in the session notes — the generic one, no room involved |
| `GET /link/hide` | takes the banner back down |

`/link/publish` deliberately does **not** toggle the way the menu item does: an
HTTP call that hides the banner because it happened to be up is a coin flip, not
an API, so an already-visible banner is re-shown with the new URL.

## The participants' end

The daemon route `POST :1234/feedback-form` already existed for this, complete
with an `#feedback-row` sitting hidden in `participant.html`: it persists the
link, broadcasts `feedback_form_updated`, and every open participant page
reveals a **Feedback form** row in its left-hand menu without a reload.
`DELETE :1234/feedback-form` retracts it from the whole room.

The Mac's push is fire-and-forget: the daemon is only up during a workshop, and
a link that already reached the clipboard, the banner and the notes has done
most of its job — a dead daemon must not turn that into a failure. It says which
way it went in the log.

This is also why it is a **separate route** from `/link/publish`: putting an
arbitrary link on the projected screen must never also push it to the room.

## The menu item

**📝 Generate Feedback Form**, directly under 🟢 Interact Link — it is the other link the room is given — and
**hidden**, not greyed, when no session is live. A row that cannot do anything is
noise on a menu read at a glance.

## The reminder

`FeedbackFormReminder` puts a bottom-left **`Feedback form?`** pill up at
**16:50, 17:20 and 17:50**, hover-to-accept, exactly like the wrap-up offer —
interleaved with that offer's 16:45 / 17:15 rather than aligned with it, since
two pills in the same minute compete for the same glance. The third slot is for
the days that run long.

It is gated on a live session, and a slot whose gate fails is **not** marked
fired — a session that starts late still gets the offer on the next tick inside
the grace window, instead of having silently burned its slot while the daemon
was down. `GET /test/feedback-reminder` shows it now, schedule and gate bypassed.

## Anti-double-run

Before the Copy — never after, when a stray clone would already exist and need
deleting by hand — the extension looks for a form with **the same name and
today's date**. If it finds one it stops and paints the reason across the top of
the tab it opened. Same name months later is a different workshop and is fine;
same name this afternoon means the automation is about to run twice, which is
easy to do with two reminder slots and a menu item all pointing at it.

The row's date is parsed rather than compared as a string: matching
`"4 Sept 2026"` by hand would mean matching the site's locale, its month
abbreviations and its timezone, and would stop matching silently the day any of
the three changed.

## What the site does to you

The Angular DOM notes — which selectors survive a rebuild, why text matching
fails on the action buttons, why the clone arrives already expanded, why the
share URL is not in an input — live in the header comment of
[`chrome-extension/feedback-form.js`](../chrome-extension/feedback-form.js),
next to the code that depends on them.

## Testing

The extension must be reloaded in `chrome://extensions` after any change to
`chrome-extension/` — the Mac-side rebuild does not touch it. Watch it work in
the service worker console (`chrome://extensions` → *Victor Chrome Addons* →
*service worker*); every step logs.

```bash
curl -s 127.0.0.1:55123/feedback-form/publish   # same path as the menu item
```
