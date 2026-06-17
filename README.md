# gizmos

<div align="center">
  <img src="gizmos.png" alt="skillless" width="100%" />
</div>

A catalog of small, single-file shell utilities I keep around as GitHub Gists.
Nothing here is a framework or a product — just zsh/bash functions that save a
few keystrokes and print pretty output while doing it. Each one does exactly one
thing.

## Table of contents

- [Setup](#setup)
- [agents-kit](#agents-kit) — update all your AI coding CLIs at once
- [claude-utils](#claude-utils) — switch between multiple Claude Code accounts
- [gac](#gac) — git add & commit with semantic emoji shortcuts

---

## Setup

Each script is a single file. Clone the gist, source it from your shell config, reload.

```sh
# 1. clone the gist (use the gist's clone URL)
git clone <gist-clone-url>
cd <gist-folder>

# 2. add it to your shell config
echo "source $(pwd)/<script>.sh" >> ~/.zshrc

# 3. reload
source ~/.zshrc
```

Repeat per script.

---

## agents-kit

**Gist:** [gist.github.com/5kahoisaac/bac9d61bf6e194fa7bb9c2466883829d](https://gist.github.com/5kahoisaac/bac9d61bf6e194fa7bb9c2466883829d) · bash/zsh

Update all your AI coding command-line tools in one shot — Claude Code,
OpenCode, OpenAI Codex CLI, Pi Coding Agent, LazyCodex — with consistent colored
status for each step. Tools you don't have installed are skipped with a notice.

```sh
agents-kit update            # update everything
agents-kit update --skip-ecc # tools only, skip the ECC repo step
agents-kit --help
```

---

## claude-utils

**Gist:** [gist.github.com/5kahoisaac/c5973e8277e8e0a4dde3906c99200be2](https://gist.github.com/5kahoisaac/c5973e8277e8e0a4dde3906c99200be2) · zsh

Run more than one Claude Code account on the same machine (e.g. Pro and Max, or
work and personal) and switch between them without logging out and back in.
Project history, MCP servers, plugins, skills, and agents stay shared.

```sh
claude-utils save pro        # capture the current login as "pro"
claude-utils list            # show profiles, active one marked
claude-utils switch pro      # swap to the "pro" account
claude-utils status          # active account + resolved paths
```

Requires [`jq`](https://stedolan.github.io/jq/).

---

## gac

**Gist:** [gist.github.com/5kahoisaac/980b6d5be79295c2a6236e0773dbf5ef](https://gist.github.com/5kahoisaac/980b6d5be79295c2a6236e0773dbf5ef) · zsh

Stage everything and commit with a semantic emoji prefix, in one short command.
Run `gac -h` for the full grouped legend.

```sh
gac f add login endpoint     # → ✅ FEAT: add login endpoint
gac b fix null deref         # → 🐛 BUG FIX: fix null deref
gac -s d update readme       # → 📖 DOCS: update readme   (staged only)
gac just a quick note        # → just a quick note        (no prefix)
```
