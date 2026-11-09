# 📖 Walkie's vocabulary ⇄ Wispr Flow's Dictionary (`WalkieDictSync`)

**2026-11-09.** Walkie Talkie's ✍️ editor reads `~/.walkie-talkie/vocabulary.txt`; Wispr Flow
keeps its own Dictionary in `flow.sqlite`. `walkie-talkie/helpers/walkie-dict` keeps the two in
sync (a three-way merge — adds and deletes travel both ways; the rules are in its docstring and
in `walkie-talkie/.claude/rules/destinations-and-outbox.md`). An agent runs `walkie-dict add` on a
term it is sure was misheard; that call syncs by itself. What it does not cover is a word Victor
adds or deletes **in Wispr's Hub** — that is this timer's job.

- **Here, not a LaunchAgent** (Victor: *"sau mai bine, îl poți programa ca timer în victor macos
  addons"*). The LaunchAgent `ro.victorrentea.walkie-dict-sync` lived for one hour and was removed.
- **Every 10 min, first run 30 s after launch**, on a utility queue: `/usr/bin/python3
  ~/workspace/walkie-talkie/helpers/walkie-dict sync`. No checkout → nothing happens.
- **Logged only when something moved or failed** (`📖 walkie-dict sync (exit N): …`); the usual
  `in sync` stays out of the log.
- **The dependency points this way only.** Walkie Talkie is public and must work without this app,
  so the sync is a caller of Walkie's script and nothing in Walkie knows about it.
