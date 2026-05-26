# Status line Claude Code

Bara aceea care apare jos în Claude Code:

```
🤖 Opus 4.7 (4% of 1M) | 💰 74% left | ⏱️ 2h 37m left until 11:20
```

Arată: modelul, cât din context ai consumat, cât ți-a mai rămas din cota de 5h și când se resetează.

---

## Cum se configurează

Două lucruri îți trebuie:

1. **Un script** care primește pe stdin un JSON cu starea sesiunii și scuipă pe stdout linia de status.
2. **O înregistrare în `~/.claude/settings.json`** care îi spune lui Claude Code să ruleze scriptul ăla.

### 1. `~/.claude/settings.json`

```json
{
  "statusLine": {
    "type": "command",
    "command": "/Users/victorrentea/.claude/statusline-command.sh"
  }
}
```

Atât. Claude Code rulează comanda după fiecare mesaj și afișează stdout-ul ca status line.

### 2. `~/.claude/statusline-command.sh`

```sh
#!/bin/sh
# Claude Code status line: "Model (ctx% of SIZE) | 5h% left | Xh Ym left until HH:MM"
input=$(cat)
model=$(echo "$input" | jq -r '.model.display_name // "Claude"' | sed 's/ context)/)/')
ctx=$(echo "$input" | jq -r '.context_window.used_percentage // empty')
total=$(echo "$input" | jq -r '.context_window.context_window_size // empty')
five=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty')
reset=$(echo "$input" | jq -r '.rate_limits.five_hour.resets_at // empty')

ESC=$(printf '\033')
RESET="${ESC}[0m"
ORANGE="${ESC}[38;5;208m"
RED="${ESC}[31m"

if [ -n "$ctx" ]; then
  ctx_pct=$(printf '%.0f' "$ctx")

  # Resolve size label
  size_label=""
  if echo "$model" | grep -q '('; then
    size_label=$(echo "$model" | sed -n 's/.*(\(.*\)).*/\1/p')
    model=$(echo "$model" | sed 's/ *(.*)//')
  elif [ -n "$total" ]; then
    if [ "$total" -ge 1000000 ]; then
      size_label=$(printf '%.0fM' "$(echo "$total / 1000000" | bc -l)")
    else
      size_label=$(printf '%.0fK' "$(echo "$total / 1000" | bc -l)")
    fi
  fi

  if [ -n "$size_label" ]; then
    inner="${ctx_pct}% of ${size_label}"
    if [ "$ctx_pct" -ge 95 ]; then
      inner="${RED}${inner}${RESET}"
    elif [ "$ctx_pct" -ge 65 ]; then
      inner="${ORANGE}${inner}${RESET}"
    fi
    model="$model ($inner)"
  fi
fi

out="🤖 $model"

if [ -n "$five" ]; then
  left=$(printf '%.0f' "$(echo "100 - $five" | bc -l)")
  left_str="${left}% left"
  if [ "$left" -lt 5 ]; then
    left_str="${RED}${left_str}${RESET}"
  elif [ "$left" -lt 15 ]; then
    left_str="${ORANGE}${left_str}${RESET}"
  fi
  five_str="💰 ${left_str}"
  if [ -n "$reset" ]; then
    now=$(date +%s)
    diff=$((reset - now))
    if [ "$diff" -gt 0 ]; then
      h=$((diff / 3600))
      m=$(((diff % 3600) / 60))
      until_time=$(date -r "$reset" +%H:%M)
      if [ "$h" -gt 0 ]; then
        dur="${h}h ${m}m"
      else
        dur="${m}m"
      fi
      five_str="$five_str | ⏱️ ${dur} left until $until_time"
    fi
  fi
  out="$out | $five_str"
fi

echo "$out"
```

Fă-l executabil:

```sh
chmod +x ~/.claude/statusline-command.sh
```

---

## Cum funcționează, pe scurt

Claude Code îi trimite scriptului pe **stdin** un JSON cam așa:

```json
{
  "model": { "display_name": "Opus 4.7 (1M context)" },
  "context_window": {
    "used_percentage": 4.2,
    "context_window_size": 1000000
  },
  "rate_limits": {
    "five_hour": {
      "used_percentage": 26.5,
      "resets_at": 1731320400
    }
  }
}
```

Scriptul îl despachetează cu `jq` și construiește linia:

| Bucată                     | De unde vine                                       |
|----------------------------|----------------------------------------------------|
| `🤖 Opus 4.7`              | `.model.display_name` (fără sufixul „context")     |
| `(4% of 1M)`               | `.context_window.used_percentage` + size label     |
| `💰 74% left`              | `100 - .rate_limits.five_hour.used_percentage`     |
| `⏱️ 2h 37m left until 11:20` | calcul din `.rate_limits.five_hour.resets_at`    |

**Culori** (escape codes ANSI):
- Context ≥ 95% → roșu, ≥ 65% → portocaliu
- Cotă rămasă < 5% → roșu, < 15% → portocaliu

---

## Idei de personalizare

- Adaugă branch-ul curent: `git -C "$PWD" branch --show-current`
- Adaugă numele directorului: `basename "$PWD"`
- Schimbă emoji-urile (sau scoate-le)
- Schimbă pragurile de culoare după gustul tău

Scriptul rulează la fiecare mesaj, deci ține-l rapid — nimic ce durează > 100ms.

---

## Documentație oficială

https://docs.claude.com/en/docs/claude-code/statusline
