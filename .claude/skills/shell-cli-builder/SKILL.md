---
name: shell-cli-builder
description: Build polished, sourced shell CLIs (zsh/bash functions) with a consistent house style — TTY-gated colour, glyph fallbacks, y/N confirmation prompts, dependency checks, env-var-with-fallback config, subcommand dispatch, and correct exit codes. Use whenever the user wants to create or improve a command-line tool meant to be sourced from ~/.zshrc or ~/.bashrc (a "gizmo", shell function, dotfiles utility, git helper, port killer, account switcher, updater, etc.), or asks to "add colour", "make it look like a CLI", "add a confirmation prompt", "check for a dependency", or "standardise the output" of an existing shell script. Trigger on requests to write a small CLI as a .sh file, not on application-level programs in Python/Go/Rust.
---

# shell-cli-builder

Build small, sourced shell CLIs that look and behave consistently: coloured
output that degrades cleanly, safe confirmation prompts, dependency checks,
env-var configuration with fallbacks, subcommand dispatch, and meaningful exit
codes.

These are the conventions distilled from building a family of such tools
(account switchers, git helpers, port killers, updaters). Follow them so every
gizmo feels like part of one set.

## When to use

Use for **sourced shell functions** — tools the user adds to `~/.zshrc` /
`~/.bashrc` and calls as a command (`gac`, `kp`, `claude-utils`, …). Not for
standalone application programs (those belong in Python/Go/Rust). If the tool
is more than a few hundred lines or needs real data structures, say so and
suggest a compiled language instead.

## How to build

1. **Read `reference/cli-patterns.md` first.** It is the authoritative spec for
   every pattern below — colour setup, prompts, guards, dispatch, exit codes,
   and the zsh gotchas. Do not write the script from memory; the details
   (glyph fallbacks, `local`-in-loop bug, `read` portability) are easy to get
   subtly wrong.
2. **Start from a template** in `templates/` — `single-command.sh` for a tool
   with one action, `subcommand.sh` for a tool with several (`save`/`switch`/
   `list` style). Copy it, rename the function, fill in the logic.
3. **Match the house style** exactly: the colour block, the `_c_*` print
   helpers, the `[y/N]` prompt shape, and the dependency-guard pattern are
   shared across all tools. Reuse them verbatim rather than reinventing.
4. **Validate.** Run `zsh -n file.sh` (and `bash -n` if it targets bash) before
   delivering. Exercise the prompt paths (`y` and `n`), the no-arg/help path,
   and the failure path. For colour, test once on a TTY and once piped /
   `NO_COLOR=1` to confirm the ASCII fallback is clean.

## The core patterns (summary — full detail in the reference)

- **Colour, TTY-gated.** Enable ANSI only when `[[ -t 1 && -z "$NO_COLOR" ]]`.
  When off, blank the colour vars *and* swap fancy glyphs (`✓ ✗ ! ●`) for ASCII
  (`[ok] [x] [!] *`) so piped/redirected output is pure ASCII.
- **Print helpers.** `_c_ok` / `_c_err` (→ stderr) / `_c_warn` / `_c_info`,
  each a glyph + colour + message. Keeps output uniform.
- **y/N prompts.** Print the question with `printf` (no newline), `read -r
  reply`, `case` on `y|Y|yes|YES`; default to No. For destructive or
  account-affecting actions, default No and abort cleanly on anything else.
- **Dependency checks.** `command -v <tool> >/dev/null 2>&1 || { error; return 1; }`
  — check before use, name the missing tool, fail with a clear message.
- **Env var + fallback.** `: "${VAR:=default}"` to default-and-export, or
  `local x="${VAR:-fallback}"` to read without exporting. Nested
  `${VAR:-${OTHER:-}}` chains multiple sources safely under `set -u`.
- **Subcommand dispatch.** A `case "$cmd"` router; resolve any runtime paths at
  dispatch time (not source time) so env changes are honoured.
- **Exit codes.** `0` success, `1` error/abort, `2` "nothing found" or usage —
  and return the real downstream exit code rather than a hardcoded one.
- **Process guards.** When an action conflicts with a running process, list the
  PIDs and offer to kill them (`[y/N]`) rather than silently failing.

## zsh gotchas the reference covers

- Re-declaring `local` vars **inside** a loop makes zsh echo them each
  iteration — declare loop-locals once before the loop.
- `read` flag differences and prompt portability between bash and zsh.
- Atomic file writes via `mktemp` + `mv` so a half-written file never lands.

## Output

Deliver the finished `.sh` as a single file. If the user keeps a catalog
(e.g. a gizmos repo), offer to add a section via their catalog tooling.
