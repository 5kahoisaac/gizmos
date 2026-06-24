# gizmos

![gizmos](gizmos.png)

A catalog of small, single-file shell utilities. Nothing here is a framework or
a product — just zsh/bash functions that save a few keystrokes and print pretty
output while doing it. Each one does exactly one thing.

## Table of contents

<!-- toc:start -->
- [Setup](#setup)
- [ai-sweeper](#ai-sweeper) — clear caches, logs, and dead sessions across multiple AI coding agents
- [ai-updater](#ai-updater) — update all your AI coding CLIs at once
- [gac](#gac) — git add & commit with semantic emoji shortcuts
- [killport](#killport) — kill processes and containers listening on TCP ports
<!-- toc:end -->

---

## Setup

Clone the repo, then add this loop to your shell config to source every script.

```sh
# 1. clone the repo
git clone <repo-url> ~/.gizmos

# 2. add to ~/.zshrc
for f in ~/.gizmos/*.sh; do
  [ -r "$f" ] && source "$f"
done

# 3. reload
source ~/.zshrc
```

---

<!-- sections:start -->

## ai-sweeper

`ai-sweeper.sh` · zsh

clear caches, logs, and dead sessions across multiple AI coding agents

```sh
ai-sweeper status                  # disk usage per agent
ai-sweeper list codex-cli          # preview what would be deleted
ai-sweeper --dry-run clean         # rehearsal run across all agents
ai-sweeper clean codex-desktop     # delete one agent's junk
```

---

## ai-updater

`ai-updater.sh` · bash/zsh

update all your AI coding CLIs at once

```sh
ai-updater update               # update all tools
ai-updater update claude        # update one tool
ai-updater update claude codex headroom   # update several
ai-updater update ecc --ecc-repo ~/src/ecc  # ECC repo only
```

---

## gac

`gac.sh` · zsh

Stage everything and commit with a semantic emoji prefix, in one short command.
Run `gac -h` for the full grouped legend.

```sh
gac f add login endpoint     # → ✅ FEAT: add login endpoint
gac b fix null deref         # → 🐛 BUG FIX: fix null deref
gac -s d update readme       # → 📖 DOCS: update readme   (staged only)
gac just a quick note        # → just a quick note        (no prefix)
```

---

## killport

`killport.sh` · zsh

Kill whatever is listening on a TCP port — the owning process by default, or
the Docker container publishing it in `auto` mode. Supports multiple ports,
signal control, dry-run preview, and a `--no-fail` exit-code override.

```sh
killport 8080               # free port 8080 (SIGTERM the listener)
killport 3000 8080 9090     # free several ports at once
killport -s KILL 8080       # use SIGKILL instead of SIGTERM
killport --dry-run 5432     # preview without killing anything
```

<!-- sections:end -->

## License

[MIT](LICENSE.md)
