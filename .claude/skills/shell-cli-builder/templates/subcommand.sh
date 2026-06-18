#!/bin/zsh
# ============================================================================
# toolname — multi-subcommand tool
# ============================================================================
#
# INSTALL (add to ~/.zshrc):
#   source ~/path/to/toolname.sh
#
# COMMANDS:
#   toolname do <arg>     perform the main action
#   toolname list         list things
#   toolname status       show current state
#   toolname help         show help
# ============================================================================

# Override TOOL_HOME before sourcing to relocate state.
: "${TOOL_HOME:=$HOME/.toolname}"

# --- runtime path resolution (call-time, honours env changes) --------------
_tool_resolve_paths() {
  # resolve any env-dependent paths here so exports after sourcing are honoured
  TOOL_DATA="${TOOL_HOME%/}/data"
}

# --- colour + glyphs (TTY + NO_COLOR aware) ---------------------------------
_tool_init_colors() {
  if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    C_RESET=$'\e[0m'; C_BOLD=$'\e[1m'; C_DIM=$'\e[2m'
    C_RED=$'\e[31m'; C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'; C_CYAN=$'\e[36m'
    G_OK="✓"; G_ERR="✗"; G_WARN="!"; G_ASK="?"; G_DOT="●"
  else
    C_RESET=""; C_BOLD=""; C_DIM=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_CYAN=""
    G_OK="[ok]"; G_ERR="[x]"; G_WARN="[!]"; G_ASK="?"; G_DOT="*"
  fi
}

# --- print helpers ----------------------------------------------------------
_c_ok()   { print -r -- "${C_GREEN}${G_OK}${C_RESET} $*"; }
_c_err()  { print -r -- "${C_RED}${G_ERR}${C_RESET} $*" >&2; }
_c_warn() { print -r -- "${C_YELLOW}${G_WARN}${C_RESET} $*"; }
_c_info() { print -r -- "${C_CYAN}-${C_RESET} $*"; }

# --- guards -----------------------------------------------------------------
_tool_require() {
  if ! command -v "$1" >/dev/null 2>&1; then
    _c_err "${C_BOLD}$1${C_RESET} is required but not found in PATH."
    return 1
  fi
}

# --- subcommand: do ---------------------------------------------------------
_tool_do() {
  local arg="$1"
  if [[ -z "$arg" ]]; then
    _c_info "usage: ${C_BOLD}toolname do <arg>${C_RESET}"; return 1
  fi
  # destructive? confirm (default No):
  # printf "%s Proceed? %s[y/N]%s " "${C_YELLOW}${G_ASK}${C_RESET}" "${C_DIM}" "${C_RESET}"
  # local r; read -r r; case "$r" in y|Y|yes|YES) ;; *) _c_info "Aborted."; return 1 ;; esac
  mkdir -p "$TOOL_DATA"
  _c_ok "did the thing with ${C_BOLD}$arg${C_RESET}."
}

# --- subcommand: list -------------------------------------------------------
_tool_list() {
  if [[ ! -d "$TOOL_DATA" ]]; then
    _c_warn "nothing yet. Create with ${C_BOLD}toolname do <arg>${C_RESET}."
    return 0
  fi
  # declare loop-locals ONCE (avoid zsh local-in-loop echo)
  local f
  print -r -- "${C_BOLD}  ITEMS${C_RESET}"
  for f in "$TOOL_DATA"/*(N); do
    print -r -- "  ${C_CYAN}${f:t}${C_RESET}"
  done
}

# --- subcommand: status -----------------------------------------------------
_tool_status() {
  print -r -- "${C_BOLD}toolname${C_RESET} ${C_DIM}status${C_RESET}"
  printf "  %sData dir:%s ${C_DIM}%s${C_RESET}\n" "${C_DIM}" "${C_RESET}" "$TOOL_DATA"
}

# --- help -------------------------------------------------------------------
_tool_help() {
  cat <<USAGE
${C_BOLD}toolname${C_RESET} ${C_DIM}— multi-subcommand tool${C_RESET}

${C_BOLD}Usage:${C_RESET}
  ${C_CYAN}toolname do${C_RESET} ${C_DIM}<arg>${C_RESET}   perform the main action
  ${C_CYAN}toolname list${C_RESET}        list things
  ${C_CYAN}toolname status${C_RESET}      show current state
  ${C_CYAN}toolname help${C_RESET}        this help
USAGE
}

# --- dispatcher -------------------------------------------------------------
toolname() {
  local cmd="$1"; shift 2>/dev/null
  _tool_resolve_paths
  _tool_init_colors
  case "$cmd" in
    do)     _tool_do     "$@" ;;
    list)   _tool_list   "$@" ;;
    status) _tool_status "$@" ;;
    help|-h|--help|"") _tool_help ;;
    *) _c_err "unknown command '$cmd'"; _c_info "Run ${C_BOLD}toolname help${C_RESET}."; return 1 ;;
  esac
}
