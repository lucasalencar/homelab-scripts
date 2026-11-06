---
name: Sudo Diagnostics Handoff
description: Sudo-blocked diagnosis bridge. Use when investigation stalls on sudo-only commands, permission denied, password prompts, or gaps in the passwordless-sudo allowlist. Bundles each check into one runnable script that saves output to /tmp for resume.
---

# Sudo Diagnostics Handoff

Use this when you cannot finish diagnosis without sudo the current
session cannot provide: `Permission denied`, empty output caused by
`kernel.dmesg_restrict`, root-only files, or any command outside the
passwordless-sudo allowlist (`AGENTS.md` rule 1).

Goal: one diagnostic step per script, user runs it where sudo works,
agent reads the result file and continues. Never dump a list of raw
sudo commands for the user to run by hand.

## Preconditions

1. Exhaust the non-sudo paths first: passwordless-allowlisted
   `sudo pvesh get ...`, group-readable `/etc/pve`, `journalctl`
   instead of `dmesg`, host `ps` + `/proc/<pid>/cgroup` instead of
   `pct exec ... systemctl`.
2. Confirm the OS split (`AGENTS.md` rule 2). Scripts generated here
   target Linux (the sudo host), even if the agent session runs on
   macOS.

## Workflow

1. Declare the block in one line: what you need and why non-sudo
   sources cannot provide it.
2. Write exactly one script for the next diagnostic step. Never bundle
   two steps or pre-write the follow-up.
3. Pause with run instructions and wait for the word `continue`.
4. On resume, read the result file (or the pasted content when hosts
   differ), state the conclusion, then proceed to the next step.

## Script contract

Every generated script must satisfy all of these:

- Path: `/tmp/opencode-diag/<slug>-<NN>.sh`, result:
  `/tmp/opencode-diag/<slug>-<NN>.out`. Keep `<slug>` short,
  increment `<NN>` per step.
- Create it with the file tools so it already exists in the session;
  tell the user the same path to recreate it on the sudo host when
  `/tmp` is not shared.
- Content: `#!/usr/bin/env bash`, `set -euo pipefail`, read-only
  commands only. No `rm`, `chmod`, `chown`, installs, config writes,
  or service restarts. Anything destructive needs explicit user
  approval first (`AGENTS.md` rule 1).
- Redirect with a `run()` function piped to `tee` so output always
  lands in the result file with a live copy preserved (verified:
  `exec > >(tee ...)` duplicates output, do not use it):
  `OUT=...; run() { ... }; run | tee "$OUT"`, then
  `echo "RESULT: $OUT" | tee -a "$OUT"`.
- Wrap each probe as `echo "=== <what> == diagnostics"; <cmd> || true`
  so one failing probe never aborts the bundle.
- End with a best-effort clipboard copy guarded by `command -v`
  (`wl-copy`, `xclip`, `xsel`, `pbcopy`), always `|| true`, then
  `echo "RESULT: $OUT"`.
- `chmod +x` the script before handing it over.

## Pause message

Keep it copy-paste ready, in this shape:

```text
Blocked on sudo: <one line>.
Script ready: /tmp/opencode-diag/<slug>-<NN>.sh

Run where sudo works:
  sudo bash /tmp/opencode-diag/<slug>-<NN>.sh
  cat /tmp/opencode-diag/<slug>-<NN>.out

Reply `continue` when done. If that host cannot see this
session's /tmp, recreate the script from the content above,
run it there, and paste the RESULT file content with `continue`.
```

## Resume contract

1. Read `/tmp/opencode-diag/<slug>-<NN>.out` first. If the file is
   absent, ask for the pasted content instead of re-running guesses.
2. Summarize the finding in one or two lines before proposing the
   next step.
3. Loop back to Workflow step 2 for the next single script.
