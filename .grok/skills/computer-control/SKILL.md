---
name: computer-control
description: >
  Grok Bot Agent Computer and local-exec policy for cell-lang. Use when the
  user says computer control, computer use, Agent Computer, grok bot, local
  computer, or asks a bot to click through a GUI instead of running
  zig -Dswift=false / tools/check.sh. Names the --test-filter false-green
  trap. Not Claude Computer Use and not Orca.
---

# Computer control (Grok Bot, this repo)

Grok Bot already has a computer. Do not install `athola/claude-night-market@computer-control` (Claude screenshots/mouse, 114 installs, Snyk fail) or `stablyai/orca@computer-use` (Orca IDE CLI; on Linux `orca` is the GNOME screen reader). Neither drives Grok Bot.

## Two computers, keep them apart

1. **Grok Bot Agent Computer** (cloud, account-scoped). Browser, filesystem, terminal. Shared by every Bot on the account. Docs: `https://docs.x.ai/grok-bot/computer-and-apps`. Open **Agent Computer** from the conversation to watch. One Bot, one computer-use task on its screen at a time.
2. **This Mac.** Separate. `~/.grokbot` is the local-exec daemon. Settings → General → Agent → Execution on Local Computer. Default is ask every time. Do not treat local-exec as the cloud computer.

Passwords, passkeys, 2FA, CAPTCHAs, payments: take over the Agent Computer, complete the step yourself, return control. Never paste secrets into chat.

## What to run instead of clicking

This repository is a Zig compiler. GUI computer-use is not the gate.

```sh
zig build -Dswift=false
zig build test -Dswift=false
tools/check.sh
```

`--test-filter` matching nothing still exits 0 because `src/root.zig` has an anonymous `test { refAllDecls(@This()); }`. Confirm the named test appears. Unique work lands on canonical `main`, not only in a worktree.

Prefer a connector or the CLI when one exists. Use the Agent Computer browser only for a site or app with no API, and only after the Cell commands above have a real exit code from the command itself (never `cmd | tail`).
