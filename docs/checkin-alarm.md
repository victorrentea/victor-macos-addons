# ✈️ Check-in alarm

Asked for 8 Oct 2026 (Victor: *"I forgot many times to do the check-in"*). Once an
hour the app asks Gmail whether an airline wrote "online check-in is open". For
each new one it **marks the mail read** and raises an **orange bottom-left pill**,
`✈️ Check in now: Ryanair → Otopeni`, with a Glass chime. The pill **stays until
clicked** (click-only, like the 🎤 DJI alarm; a hover does nothing):

- **click** → the mail opens in Victor's Chrome on the screen under the mouse
  (`https://mail.google.com/mail/u/0/#all/<threadId>`), and the pill sinks;
- **right-click** → the pill sinks, nothing opens.

Several at once queue: the pill shows the oldest, with `(+N)`. The queue is kept
in `UserDefaults` (`checkin.pending`) and comes back after a restart, silently. It
has to: the mail is already read, so a dropped pill would leave no reminder at all.

## Which mails

`CheckInMailPolicy.query` has one clause per airline, each pinned to the sender
**and** to the subject only the check-in mail uses. It was built from the real
inbox and, over the year before, matched 34 threads, all of them check-in mails.

| airline | sender | subject |
|---|---|---|
| Ryanair | `ryanairemail.com` | "Check in online for your flight to X" (RO: "check-in-ul online") |
| Wizz Air | `wizznews.com` (marketing domain!) | "It's time to check in!" / "Este timpul să faceți check-in!" |
| KLM | `infos-klm.com`, `klm-info.com` | "Check-in is open!", "Check in for your flight to X" |
| Lufthansa group (LH, Brussels, Austrian, Swiss) | any | "Your flight is ready for check-in" |
| Air France | `service-airfrance.com` | "Check-in…" |
| LOT | `lot.com` | "It's time to check-in" |
| Animawings | `mailinganimawings.com` | "Time to Check-In" |

Left out, on purpose: Ryanair's "It's almost time for your flight" (2 days ahead,
check-in not open yet), Lufthansa/Brussels' "Check in carry-on baggage free of
charge" (bags at the airport), Wizz's "Check-in contact" from `wizzair.com` (a phone
number form), LOT's "Prepare for your flight". **Tarom sends no check-in mail**
(only invoices and the Amadeus e-ticket), and neither has easyJet, so neither has
a clause. A new airline is one line in `clauses`.

The search looks back `newer_than:1d`: the mail lands ~24–48 h before departure and
the poll is hourly. Each thread rings once (`checkin.seen`, the last 300 ids).

## Why `gmail-cli` and not the Gmail MCP connector

The connector lives inside a Claude session. Reaching it from the app would mean a
`claude -p` run every hour, 24 a day, spending subscription quota on one fixed
search. `gmail-cli` (skill `gmail-web`, `~/.local/bin/gmail-cli`) drives a headless
Chrome on its own signed-in profile: ~10 s, no model, nothing on screen.

- `gmail-cli search '<query>' 20 --json` lists results **without opening them**, so
  looking marks nothing read.
- `gmail-cli read '<query> is:unread' N` is the step that marks read: it opens
  exactly the new, unread hits. It runs before the pill rings; if it fails, the
  pill still shows and the mail simply stays unread.
- The app's LaunchAgent has launchd's bare PATH, so the watch sets one that finds
  `node` and `playwright-cli`. A run is killed after 180 s.
- If `gmail-cli` says the profile is signed out, run `gmail-cli --login` once.

## Timing

`CheckInMailWatch` ticks every 5 min and polls when the last poll is ≥ 1 h old
(`CheckInMailPolicy.isDue`), so a Mac that slept through the hour checks soon after
waking. First poll 60 s after launch. A failed poll (offline, signed out, the shared
headless profile busy with another `gmail-cli` such as the FAN PIN cron) is logged
and retried the next hour; nothing is marked seen.

## Testing

- `GET /test/checkin` — last poll time and outcome, plus the queue.
- `GET /test/checkin/poll` — ask Gmail now (answers before the ~10 s run ends;
  call `/test/checkin` again for the result).
- `GET /test/checkin/simulate` — a fake Ryanair pill on the **external** screens only
  (off the projected retina); `/simulate/all` draws it everywhere, like the real one.
- `GET /test/checkin/clear` — drop the queue without opening anything.
- Unit tests: `CheckInMailPolicyTests` (subjects → city, pill text, ring-once,
  restart survival, click opens / right-click doesn't).
