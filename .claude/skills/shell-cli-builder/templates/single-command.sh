#!/bin/zsh
# ============================================================================
# toolname — one-line description
# ============================================================================
#
# INSTALL (add to ~/.zshrc):
#   source ~/path/to/toolname.sh
#
# USAGE:
#   toolname [options] <arg>
#
# OPTIONS:
#   -f, --flag <V>   an option that takes a value
#       --dry-run    preview without acting
#   -h, --help       show this help
# ============================================================================

function toolname() {
  # --- colour (TTY + NO_COLOR aware; glyphs degrade to ASCII) --------------
  local C_RESET C_BOLD C_DIM C_RED C_GREEN C_YELLOW C_CYAN G_OK G_ERR G_WARN G_ASK
  if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    C_RESET=$'\e[0m'; C_BOLD=$'\e[1m'; C_DIM=$'\e[2m'
    C_RED=$'\e[31m'; C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'; C_CYAN=$'\e[36m'
    G_OK="✓"; G_ERR="✗"; G_WARN="!"; G_ASK="?"
  else
    C_RESET=""; C_BOLD=""; C_DIM=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_CYAN=""
    G_OK="[ok]"; G_ERR="[x]"; G_WARN="[!]"; G_ASK="?"
  fi
  local _ok _err _warn _info
  _ok()   { print -r -- "${C_GREEN}${G_OK}${C_RESET} $*"; }
  _err()  { print -r -- "${C_RED}${G_ERR}${C_RESET} $*" >&2; }
  _warn() { print -r -- "${C_YELLOW}${G_WARN}${C_RESET} $*"; }
  _info() { print -r -- "${C_CYAN}-${C_RESET} $*"; }

  # --- help ----------------------------------------------------------------
  local _help
  _help() {
    print -r -- "${C_BOLD}toolname${C_RESET} ${C_DIM}— one-line description${C_RESET}"
    print -r -- "  ${C_CYAN}toolname [options] <arg>${C_RESET}"
    print -r -- "  ${C_CYAN}-f, --flag <V>${C_RESET}   an option with a value"
    print -r -- "  ${C_CYAN}    --dry-run${C_RESET}    preview without acting"
    print -r -- "  ${C_CYAN}-h, --help${C_RESET}       this help"
  }

  # --- args ----------------------------------------------------------------
  local flag="" dry=0
  local -a rest
  while (($#)); do
    case "$1" in
      -h|--help)   _help; return 0 ;;
      -f|--flag)   [[ $# -ge 2 ]] || { _err "--flag needs a value"; return 1; }
                   flag="$2"; shift 2 ;;
      --flag=*)    flag="${1#*=}"; shift ;;
      --dry-run)   dry=1; shift ;;
      --)          shift; while (($#)); do rest+=("$1"); shift; done ;;
      -*)          _err "unknown option: $1"; return 1 ;;
      *)           rest+=("$1"); shift ;;
    esac
  done

  if [[ ${#rest[@]} -eq 0 ]]; then
    _err "usage: ${C_BOLD}toolname <arg>${C_RESET}"
    return 1
  fi

  # --- dependency check (example) ------------------------------------------
  # command -v jq >/dev/null 2>&1 || { _err "${C_BOLD}jq${C_RESET} is required."; return 1; }

  # --- confirmation prompt (example; default No) ---------------------------
  if [[ "$dry" -eq 0 ]]; then
    printf "%s Proceed on %s%s%s? %s[y/N]%s " \
      "${C_YELLOW}${G_ASK}${C_RESET}" "${C_BOLD}" "${rest[1]}" "${C_RESET}" \
      "${C_DIM}" "${C_RESET}"
    local reply; read -r reply
    case "$reply" in
      y|Y|yes|YES) ;;
      *) _info "Aborted."; return 1 ;;
    esac
  fi

  # --- do the work ---------------------------------------------------------
  local arg; for arg in "${rest[@]}"; do
    if [[ "$dry" -eq 1 ]]; then
      _info "would process ${C_BOLD}$arg${C_RESET}"
    else
      # ... real action here ...
      _ok "processed ${C_BOLD}$arg${C_RESET}"
    fi
  done

  return 0
}
