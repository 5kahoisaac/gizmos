#!/bin/zsh
# ============================================================================
# gac — git add & commit with semantic-commit shortcuts
# ============================================================================
#
# INSTALL (add to ~/.zshrc):
#   source ~/path/to/gac.sh
#
# USAGE:
#   gac <type> <message...>     stage all + commit with a semantic prefix
#   gac <message...>            commit with no prefix (no type given)
#   gac -s <type> <message...>  commit ONLY already-staged changes (skip add -A)
#   gac -h | --help             show the shortcut legend
#
# EXAMPLES:
#   gac f add login endpoint     ->  ✅ FEAT: add login endpoint
#   gac b fix null deref         ->  🐛 BUG FIX: fix null deref
#   gac sec patch xss in form    ->  🔒 SECURITY: patch xss in form
#   gac up bump deps to latest   ->  ⬆️ DEPS UP: bump deps to latest
#   gac -s d update readme       ->  📖 DOCS: update readme   (staged only)
#   gac just a quick note        ->  just a quick note        (no prefix)
#
# TYPES (run 'gac -h' for the grouped legend):
#   e INIT · f FEAT · w WORKING ON · z WIP · i IMPROVE · r REFACTOR
#   b BUG FIX · h HOTFIX · p PERF · sec SECURITY · lint LINT
#   x REMOVE · rv REVERT · s STYLE
#   d DOCS · t TEST · c CHORE · cfg CONFIG · up DEPS UP · dn DEPS DOWN · m MERGE
#   n NEW RELEASE
# ============================================================================

function gac() {
  # --- colour setup (TTY + NO_COLOR aware) ---------------------------------
  local C_RESET C_BOLD C_DIM C_RED C_GREEN C_YELLOW C_CYAN
  if [[ -t 1 && -z "$NO_COLOR" ]]; then
    C_RESET=$'\e[0m'; C_BOLD=$'\e[1m'; C_DIM=$'\e[2m'
    C_RED=$'\e[31m'; C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'; C_CYAN=$'\e[36m'
  else
    C_RESET=""; C_BOLD=""; C_DIM=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_CYAN=""
  fi

  # --- help legend ---------------------------------------------------------
  _gac_help() {
    print -r -- "${C_DIM}--------------------------------------${C_RESET}"
    print -r -- "${C_BOLD}gac <type> <message>${C_RESET}  ${C_DIM}— git add -A && commit with a semantic prefix${C_RESET}"
    print -r -- "${C_DIM}--------------------------------------${C_RESET}"
    print -r -- "${C_DIM}Start${C_RESET}"
    print -r -- "  🎉 ${C_BOLD}INIT${C_RESET}           ${C_CYAN}e${C_RESET}"
    print -r -- "${C_DIM}Build${C_RESET}"
    print -r -- "  ✅ ${C_BOLD}FEAT${C_RESET}           ${C_CYAN}f${C_RESET}"
    print -r -- "  🛠 ${C_BOLD}WORKING ON${C_RESET}     ${C_CYAN}w${C_RESET}"
    print -r -- "  🚧 ${C_BOLD}WIP${C_RESET}            ${C_CYAN}z${C_RESET}"
    print -r -- "  👌 ${C_BOLD}IMPROVE${C_RESET}        ${C_CYAN}i${C_RESET}"
    print -r -- "  🪚 ${C_BOLD}REFACTOR${C_RESET}       ${C_CYAN}r${C_RESET}"
    print -r -- "${C_DIM}Fix${C_RESET}"
    print -r -- "  🐛 ${C_BOLD}BUG FIX${C_RESET}        ${C_CYAN}b${C_RESET}"
    print -r -- "  🚑 ${C_BOLD}HOTFIX${C_RESET}         ${C_CYAN}h${C_RESET}"
    print -r -- "  ⚡ ${C_BOLD}PERF${C_RESET}           ${C_CYAN}p${C_RESET}"
    print -r -- "  🔒 ${C_BOLD}SECURITY${C_RESET}       ${C_CYAN}sec${C_RESET}"
    print -r -- "  🚨 ${C_BOLD}LINT${C_RESET}           ${C_CYAN}lint${C_RESET}"
    print -r -- "${C_DIM}Clean${C_RESET}"
    print -r -- "  🔥 ${C_BOLD}REMOVE${C_RESET}         ${C_CYAN}x${C_RESET}"
    print -r -- "  ⏪ ${C_BOLD}REVERT${C_RESET}         ${C_CYAN}rv${C_RESET}"
    print -r -- "  🎨 ${C_BOLD}STYLE${C_RESET}          ${C_CYAN}s${C_RESET}"
    print -r -- "${C_DIM}Maintain${C_RESET}"
    print -r -- "  📖 ${C_BOLD}DOCS${C_RESET}           ${C_CYAN}d${C_RESET}"
    print -r -- "  🧪 ${C_BOLD}TEST${C_RESET}           ${C_CYAN}t${C_RESET}"
    print -r -- "  📦 ${C_BOLD}CHORE${C_RESET}          ${C_CYAN}c${C_RESET}"
    print -r -- "  ⚙️ ${C_BOLD}CONFIG${C_RESET}         ${C_CYAN}cfg${C_RESET}"
    print -r -- "  ⬆️ ${C_BOLD}DEPS UP${C_RESET}        ${C_CYAN}up${C_RESET}"
    print -r -- "  ⬇️ ${C_BOLD}DEPS DOWN${C_RESET}      ${C_CYAN}dn${C_RESET}"
    print -r -- "  🔀 ${C_BOLD}MERGE${C_RESET}          ${C_CYAN}m${C_RESET}"
    print -r -- "${C_DIM}Ship${C_RESET}"
    print -r -- "  🚀 ${C_BOLD}NEW RELEASE${C_RESET}    ${C_CYAN}n${C_RESET}"
    print -r -- "${C_DIM}--------------------------------------${C_RESET}"
    print -r -- "${C_DIM}flags: -s commit staged only · -h help${C_RESET}"
  }

  # --- no args / explicit help ---------------------------------------------
  if [[ $# -eq 0 || "$1" == "--help" || "$1" == "-h" ]]; then
    _gac_help
    return 1
  fi

  # --- flag: -s / --staged  (commit only staged, skip 'git add -A') --------
  local add_all=1
  if [[ "$1" == "-s" || "$1" == "--staged" ]]; then
    add_all=0
    shift
    if [[ $# -eq 0 ]]; then
      print -r -- "${C_RED}✗${C_RESET} nothing to commit message given after ${C_BOLD}-s${C_RESET}." >&2
      return 1
    fi
  fi

  # --- must be inside a git repo -------------------------------------------
  if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    print -r -- "${C_RED}✗${C_RESET} not inside a git repository." >&2
    return 1
  fi

  # --- resolve semantic prefix from first token ----------------------------
  local prefix=""
  case "$1" in
    # Start
    e)    prefix="🎉 INIT:" ;;
    # Build
    f)    prefix="✅ FEAT:" ;;
    w)    prefix="🛠 WORKING ON:" ;;
    z)    prefix="🚧 WIP:" ;;
    i)    prefix="👌 IMPROVE:" ;;
    r)    prefix="🪚 REFACTOR:" ;;
    # Fix
    b)    prefix="🐛 BUG FIX:" ;;
    h)    prefix="🚑 HOTFIX:" ;;
    p)    prefix="⚡ PERF:" ;;
    sec)  prefix="🔒 SECURITY:" ;;
    lint) prefix="🚨 LINT:" ;;
    # Clean
    x)    prefix="🔥 REMOVE:" ;;
    rv)   prefix="⏪ REVERT:" ;;
    s)    prefix="🎨 STYLE:" ;;
    # Maintain
    d)    prefix="📖 DOCS:" ;;
    t)    prefix="🧪 TEST:" ;;
    c)    prefix="📦 CHORE:" ;;
    cfg)  prefix="⚙️ CONFIG:" ;;
    up)   prefix="⬆️ DEPS UP:" ;;
    dn)   prefix="⬇️ DEPS DOWN:" ;;
    m)    prefix="🔀 MERGE:" ;;
    # Ship
    n)    prefix="🚀 NEW RELEASE:" ;;
  esac

  # If the first token matched a shortcut, consume it; otherwise treat the
  # whole input as a raw (prefix-less) commit message.
  if [[ -n "$prefix" ]]; then
    shift
  fi

  local message="$*"

  # --- require a non-empty message -----------------------------------------
  if [[ -z "${message// /}" ]]; then
    if [[ -n "$prefix" ]]; then
      print -r -- "${C_RED}✗${C_RESET} missing commit message after ${C_BOLD}${prefix}${C_RESET}" >&2
    else
      print -r -- "${C_RED}✗${C_RESET} empty commit message." >&2
    fi
    print -r -- "${C_DIM}usage: gac <type> <message>   (gac -h for types)${C_RESET}" >&2
    return 1
  fi

  # --- assemble final commit text ------------------------------------------
  local commit_msg
  if [[ -n "$prefix" ]]; then
    commit_msg="$prefix $message"
  else
    commit_msg="$message"
  fi

  # --- stage (unless -s) ---------------------------------------------------
  if [[ "$add_all" -eq 1 ]]; then
    if ! git add -A; then
      print -r -- "${C_RED}✗${C_RESET} 'git add -A' failed." >&2
      return 1
    fi
  fi

  # --- nothing staged? bail before an empty commit -------------------------
  if git diff --cached --quiet; then
    print -r -- "${C_YELLOW}!${C_RESET} nothing staged to commit." >&2
    return 1
  fi

  # --- commit, preserving git's real exit code -----------------------------
  print -r -- "${C_DIM}committing:${C_RESET} ${C_BOLD}${commit_msg}${C_RESET}"
  if git commit -m "$commit_msg"; then
    print -r -- "${C_GREEN}✓${C_RESET} committed."
    return 0
  else
    local rc=$?
    print -r -- "${C_RED}✗${C_RESET} commit failed (exit $rc)." >&2
    return $rc
  fi
}