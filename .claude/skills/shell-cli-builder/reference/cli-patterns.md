# CLI patterns reference

The authoritative spec for building sourced shell CLIs in the house style.
Every snippet here is copy-paste ready. Prefer zsh (`#!/bin/zsh`); note bash
differences where they matter.

---

## 1. File shape

A sourced CLI defines a function (the command) and supporting helpers, then —
if it has subcommands — a dispatcher. It does **not** run anything at source
time except defining functions.

```sh
#!/bin/zsh
# toolname — one-line description
#
# INSTALL: source ~/path/to/toolname.sh   (add to ~/.zshrc)
# USAGE:   toolname <args>

function toolname() {
  # colour setup, arg parsing, logic
}
```

Keep everything inside the function (or prefix private helpers with `_tool_`)
so sourcing doesn't pollute the namespace.

---

## 2. Colour, TTY-gated, with glyph fallback

Colour only when stdout is a terminal and `NO_COLOR` is unset. When off, blank
the colour vars **and** swap fancy glyphs for ASCII so piped output is clean.

```sh
local C_RESET C_BOLD C_DIM C_RED C_GREEN C_YELLOW C_CYAN
local G_OK G_ERR G_WARN G_ASK G_DOT
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  C_RESET=$'\e[0m'; C_BOLD=$'\e[1m'; C_DIM=$'\e[2m'
  C_RED=$'\e[31m'; C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'; C_CYAN=$'\e[36m'
  G_OK="✓"; G_ERR="✗"; G_WARN="!"; G_ASK="?"; G_DOT="●"
else
  C_RESET=""; C_BOLD=""; C_DIM=""
  C_RED=""; C_GREEN=""; C_YELLOW=""; C_CYAN=""
  G_OK="[ok]"; G_ERR="[x]"; G_WARN="[!]"; G_ASK="?"; G_DOT="*"
fi
```

Rules:
- Gate on `[[ -t 1 ]]` (stdout is a TTY) **and** `-z "${NO_COLOR:-}"`
  (respects the `NO_COLOR` convention, https://no-color.org).
- Blanking the glyphs matters: a literal `✓` left in the no-colour branch shows
  up as raw UTF-8 in logs. Swap to `[ok]` etc.
- 256-colour / truecolor: stick to the 8 basic SGR codes (30–37) for maximum
  terminal compatibility. Bold/dim (`1`/`2`) are widely supported.
- For a subcommand tool, re-evaluate colour at dispatch time so it reflects the
  current stream (e.g. `tool list | cat` should be plain).

---

## 3. Print helpers

Uniform status lines. Errors go to **stderr**.

```sh
_c_ok()   { print -r -- "${C_GREEN}${G_OK}${C_RESET} $*"; }
_c_err()  { print -r -- "${C_RED}${G_ERR}${C_RESET} $*" >&2; }
_c_warn() { print -r -- "${C_YELLOW}${G_WARN}${C_RESET} $*"; }
_c_info() { print -r -- "${C_CYAN}-${C_RESET} $*"; }
```

In bash, replace `print -r --` with `printf '%s\n'`. `print -r` (zsh) avoids
backslash interpretation; the bash equivalent is `printf '%s\n' "$*"`.

For a tagged/aligned column style (good for multi-step output like an updater):

```sh
ok()   { printf '  %s%-5s%s %s\n' "${C_GREEN}"  "${G_OK} OK"   "${C_RESET}" "$*"; }
warn() { printf '  %s%-5s%s %s\n' "${C_YELLOW}" "${G_WARN} SKIP" "${C_RESET}" "$*" >&2; }
fail() { printf '  %s%-5s%s %s\n' "${C_RED}"    "${G_ERR} FAIL" "${C_RESET}" "$*" >&2; }
```

---

## 4. y/N confirmation prompts

Default to **No**. Print the prompt with `printf` (no trailing newline), read,
then `case`. Only explicit yes proceeds.

```sh
printf "%s Proceed? %s[y/N]%s " "${C_YELLOW}${G_ASK}${C_RESET}" "${C_DIM}" "${C_RESET}"
local reply; read -r reply
case "$reply" in
  y|Y|yes|YES) ;;                       # proceed
  *) _c_info "Aborted."; return 1 ;;     # anything else = No
esac
```

Guidelines:
- **Destructive or state-changing** actions (delete, overwrite, kill, hard
  reset, account switch) → default No, require explicit `y`.
- Show **what** will be affected before the prompt (the PIDs, the file, the
  account email) so the choice is informed.
- `read -r` always (prevents backslash mangling). In bash you can use
  `read -r -p "prompt " reply` to combine; zsh's `read` supports `read -r
  "reply?prompt "` but `printf` + `read -r` is the portable form used here.
- For a "different value, confirm overwrite" pattern, compare current vs new and
  only prompt when they actually differ (skip the prompt when it's a no-op).

---

## 5. Dependency checking

Check a required external tool exists before using it; name it on failure.

```sh
_need() { command -v "$1" >/dev/null 2>&1; }

_require() {
  if ! _need "$1"; then
    _c_err "${C_BOLD}$1${C_RESET} is required but not found in PATH."
    return 1
  fi
}

# usage
_require jq || return 1
```

- Use `command -v`, not `which` (which is an external binary and not always
  present; `command -v` is a builtin and portable).
- Only require a tool on the code path that needs it (e.g. `lsof` only when
  touching processes), so unrelated subcommands still work.
- For optional enhancements, degrade gracefully: `_need curl || { skip }`.

---

## 6. Reading variables with fallback

```sh
# default-and-export (sets VAR if unset/empty, exports going forward)
: "${OUTPUT_LINES:=20}"

# read without exporting
local repo="${ECC_REPO:-$HOME/Documents/ECC}"

# chain multiple sources, safe under `set -u`
local cfg="${CLAUDE_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}}"

# unset vs empty: :- triggers on unset OR empty; - triggers only on unset
local x="${MAYBE_EMPTY-fallback}"   # keeps an explicit empty value
```

Notes:
- Under `set -u` (recommended in subshell entrypoints), always reference
  possibly-unset vars with a default: `"${VAR:-}"`, never bare `"$VAR"`.
- A commented-out default (e.g. `# DEFAULT_REPO=...`) means "unset" — handle it
  as a skip, not an error. Pattern: `VAR="${VAR:-${DEFAULT_VAR:-}}"` then branch
  on empty.
- Let callers override via env: read config from env vars so the tool stays
  configurable without editing the file.

---

## 7. Argument parsing

For a flag-and-positional CLI:

```sh
local signal="TERM" dry=0
local -a ports
while (($#)); do
  case "$1" in
    -h|--help)    _help; return 0 ;;
    -s|--signal)  [[ $# -ge 2 ]] || { _c_err "--signal needs a value"; return 1; }
                  signal="$2"; shift 2 ;;
    --signal=*)   signal="${1#*=}"; shift ;;
    --dry-run)    dry=1; shift ;;
    --)           shift; while (($#)); do ports+=("$1"); shift; done ;;
    -*)           _c_err "unknown option: $1"; return 1 ;;
    *)            ports+=("$1"); shift ;;
  esac
done
```

- Support both `--flag value` and `--flag=value`.
- `--` ends option parsing; everything after is positional.
- Validate that flags needing a value actually got one.

---

## 8. Subcommand dispatch

```sh
toolname() {
  local cmd="$1"; shift 2>/dev/null
  _resolve_paths      # resolve runtime state at call time, not source time
  _init_colors
  case "$cmd" in
    save)   _tool_save   "$@" ;;
    list)   _tool_list   "$@" ;;
    help|-h|--help|"") _tool_help ;;
    *) _c_err "unknown command '$cmd'"; _c_info "Run 'toolname help'."; return 1 ;;
  esac
}
```

- Resolve any environment-dependent paths **inside** the dispatcher (call time),
  so a variable exported after sourcing is still honoured.
- Provide aliases by pointing multiple `case` arms at the same helper
  (e.g. `init)` → `_tool_save`).

---

## 9. Exit codes

| Code | Meaning |
| --- | --- |
| `0` | success |
| `1` | error, or user aborted a prompt |
| `2` | "nothing found" / usage error (optional, mirrors many tools) |

- **Return the real downstream code**, not a hardcoded one. Capture it
  immediately in the failure branch:

```sh
if "$@" >"$out" 2>&1; then
  : # success
else
  status=$?          # capture NOW, before anything else resets $?
fi
return "$status"
```

- A classic bug: `return 1` at the end of a success path. Make the happy path
  `return 0` (or fall through) and only return non-zero on real failure.

---

## 10. Process guards (kill-or-abort)

When an action conflicts with a running process, list it and offer to kill:

```sh
_pids() { { pgrep -x toolproc; pgrep -f 'toolproc$'; } 2>/dev/null | sort -un; }

if _pids | grep -q .; then
  local -a pids; pids=(${(f)"$(_pids)"})          # zsh: split on newlines
  _c_warn "A process is running:"
  local p; for p in "${pids[@]}"; do
    print -r -- "    pid $p $(ps -p "$p" -o comm= 2>/dev/null)"
  done
  printf "%s Kill and continue? [y/N] " "${C_YELLOW}${G_ASK}${C_RESET}"
  local r; read -r r
  case "$r" in
    y|Y|yes|YES) for p in "${pids[@]}"; do kill -9 "$p" 2>/dev/null; done ;;
    *) _c_info "Aborted."; return 1 ;;
  esac
fi
```

(bash: replace `${(f)...}` with `mapfile -t pids < <(_pids)`.)

---

## 11. Atomic file writes

Never write a config file in place if a crash mid-write would corrupt it. Write
to a temp file, then `mv` (atomic on the same filesystem).

```sh
local tmp; tmp="$(mktemp)"
if jq '.key = "value"' "$file" > "$tmp"; then
  mv "$tmp" "$file"
else
  rm -f "$tmp"; _c_err "failed to update $file"; return 1
fi
```

Set restrictive perms on secrets: `chmod 600 "$file"`.

---

## 12. zsh gotchas (these bite repeatedly)

**`local` inside a loop echoes the variable.** Re-declaring an already-local
variable with `local` on a later loop iteration makes zsh print it
(`var=''`). Declare all loop-local vars **once before** the loop:

```sh
# WRONG — prints "name=''" each iteration
for d in *; do local name; name="$d"; done
# RIGHT
local name
for d in *; do name="$d"; done
```

**Splitting command output into an array.** zsh: `arr=(${(f)"$(cmd)"})` splits
on newlines. bash: `mapfile -t arr < <(cmd)`.

**`print -r --` vs `printf`.** zsh's `print -r --` is robust against leading
dashes and backslashes; bash uses `printf '%s\n'`. Pick based on the shebang.

**Numeric/glob test for a port etc.** zsh: `[[ "$x" == <-> ]]` matches a number.
bash: `[[ "$x" =~ ^[0-9]+$ ]]`.

**`set -euo pipefail`** belongs in subshell entrypoints (`( ... )` that do real
work), not at the top of a sourced file — it would change the user's
interactive shell options.

---

## 13. Help text

Every tool answers `-h` / `--help` (and ideally bare invocation). Keep it short:
title line, usage, options, a couple of examples. Colour the keywords, dim the
comments. For a heredoc that needs colour-var expansion, use an **unquoted**
delimiter (`<<USAGE`); for literal text, quote it (`<<'USAGE'`).

---

## 14. Pre-delivery checklist

- [ ] `zsh -n file.sh` (and `bash -n` if bash-targeted) passes.
- [ ] `-h`/`--help` and bare invocation work.
- [ ] Prompt `y` and `n` paths both tested; default is No.
- [ ] Colour on a TTY; `NO_COLOR=1` / piped output is pure ASCII (no escapes,
      no stray UTF-8 glyphs).
- [ ] Required tools are checked with a clear message.
- [ ] Exit codes: 0 success, non-zero on real failure; downstream code
      propagated.
- [ ] No `local`-in-loop echo; loop-locals declared once.
- [ ] Secrets written with `chmod 600`; config writes are atomic.
