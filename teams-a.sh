#!/bin/zsh
# ============================================================================
# teams-a — keep Microsoft Teams active so your presence stays green
# ============================================================================
#
# Every interval it brings Teams to the front and presses ⌘2 (Chat), which
# Teams counts as activity and stops flipping your presence to Away. Runs in
# the foreground until Ctrl-C; a `caffeinate` child keeps the display awake.
#
# INSTALL (add to ~/.zshrc):
#   source ~/path/to/teams-a.sh
#
# USAGE:
#   teams-a [OPTIONS]
#
# OPTIONS:
#   -i, --interval <SECS>  seconds between refreshes (default: 300)
#       --once             refresh once and exit (handy permissions test)
#       --no-caffeinate    don't keep the display awake
#   -y, --yes              skip the confirmation prompt
#   -h, --help             this help
#
# ENVIRONMENT:
#   TEAMS_A_INTERVAL  default interval in seconds (default: 300)
#   TEAMS_A_APP       Teams app name (default: "Microsoft Teams"; newer
#                     installs may be "Microsoft Teams (work or school)")
#
# NOTES:
#   Each refresh steals keyboard focus for a moment — don't run it while typing.
#   The ⌘2 keystroke needs Accessibility permission for your terminal:
#   System Settings → Privacy & Security → Accessibility.
#
# EXIT CODES:
#   0  stopped cleanly (Ctrl-C), or --once succeeded
#   1  error (missing tool, app not found, bad input, prompt declined)
#
# EXAMPLES:
#   teams-a
#   teams-a -i 120
#   teams-a --once
#   TEAMS_A_APP="Microsoft Teams (work or school)" teams-a
# ============================================================================

function teams-a() {
  emulate -L zsh
  setopt local_options local_traps
  unsetopt monitor   # background caffeinate without job-control chatter

  # --- colours (TTY + NO_COLOR aware; glyphs degrade to ASCII) -------------
  local C_RESET C_BOLD C_DIM C_RED C_GREEN C_YELLOW C_CYAN
  local G_OK G_ERR G_WARN G_ASK G_BOX
  if [[ -t 1 && -z "$NO_COLOR" ]]; then
    C_RESET=$'\e[0m'; C_BOLD=$'\e[1m'; C_DIM=$'\e[2m'
    C_RED=$'\e[31m'; C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'; C_CYAN=$'\e[36m'
    G_OK="✓"; G_ERR="✗"; G_WARN="!"; G_ASK="?"; G_BOX="▸"
  else
    C_RESET=""; C_BOLD=""; C_DIM=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_CYAN=""
    G_OK="[ok]"; G_ERR="[x]"; G_WARN="[!]"; G_ASK="?"; G_BOX="*"
  fi

  _ta_ok()   { print -r -- "${C_GREEN}${G_OK}${C_RESET} $*"; }
  _ta_err()  { print -r -- "${C_RED}${G_ERR}${C_RESET} $*" >&2; }
  _ta_warn() { print -r -- "${C_YELLOW}${G_WARN}${C_RESET} $*" >&2; }
  _ta_info() { print -r -- "${C_CYAN}-${C_RESET} $*"; }

  # --- help ----------------------------------------------------------------
  _ta_help() {
    print -r -- "${C_BOLD}${C_CYAN}teams-a${C_RESET} ${C_DIM}— keep Microsoft Teams active${C_RESET}"
    print -r -- ""
    print -r -- "${C_BOLD}Usage:${C_RESET} teams-a [options]"
    print -r -- ""
    print -r -- "${C_BOLD}Options:${C_RESET}"
    print -r -- "  ${C_CYAN}-i, --interval <SECS>${C_RESET}  seconds between refreshes ${C_DIM}(default: 300)${C_RESET}"
    print -r -- "  ${C_CYAN}    --once${C_RESET}             refresh once and exit"
    print -r -- "  ${C_CYAN}    --no-caffeinate${C_RESET}    don't keep the display awake"
    print -r -- "  ${C_CYAN}-y, --yes${C_RESET}              skip the confirmation prompt"
    print -r -- "  ${C_CYAN}-h, --help${C_RESET}             this help"
    print -r -- ""
    print -r -- "${C_BOLD}Environment:${C_RESET}"
    print -r -- "  ${C_CYAN}TEAMS_A_INTERVAL${C_RESET}  default interval in seconds"
    print -r -- "  ${C_CYAN}TEAMS_A_APP${C_RESET}       Teams app name ${C_DIM}(default: Microsoft Teams)${C_RESET}"
    print -r -- ""
    print -r -- "${C_BOLD}Examples:${C_RESET}"
    print -r -- "  ${C_DIM}teams-a${C_RESET}"
    print -r -- "  ${C_DIM}teams-a -i 120${C_RESET}"
    print -r -- "  ${C_DIM}teams-a --once${C_RESET}"
    print -r -- ""
    print -r -- "${C_DIM}Each refresh briefly steals keyboard focus. The Cmd-2 keystroke needs${C_RESET}"
    print -r -- "${C_DIM}Accessibility permission for your terminal.${C_RESET}"
  }

  # --- parse args ----------------------------------------------------------
  local interval="${TEAMS_A_INTERVAL:-300}" once=0 keep_awake=1 assume_yes=0
  while (($#)); do
    case "$1" in
      -h|--help) _ta_help; return 0 ;;
      -i|--interval)
        [[ $# -ge 2 ]] || { _ta_err "--interval needs a value"; return 1; }
        interval="$2"; shift 2 ;;
      --interval=*) interval="${1#*=}"; shift ;;
      --once) once=1; shift ;;
      --no-caffeinate) keep_awake=0; shift ;;
      -y|--yes) assume_yes=1; shift ;;
      -*) _ta_err "unknown option: $1"; return 1 ;;
      *) _ta_err "unexpected argument: $1"; return 1 ;;
    esac
  done

  if [[ "$interval" != <-> || "$interval" -lt 1 ]]; then
    _ta_err "interval must be a positive whole number of seconds: ${C_BOLD}$interval${C_RESET}"
    return 1
  fi

  # The app name is interpolated into AppleScript, so reject anything that
  # could break out of the quoted string.
  local app="${TEAMS_A_APP:-Microsoft Teams}"
  if [[ "$app" == *'"'* || "$app" == *'\'* ]]; then
    _ta_err "TEAMS_A_APP must not contain quotes or backslashes: ${C_BOLD}$app${C_RESET}"
    return 1
  fi

  # --- dependency checks ---------------------------------------------------
  if ! command -v osascript >/dev/null 2>&1; then
    _ta_err "${C_BOLD}osascript${C_RESET} is required but not found in PATH (macOS only)."
    return 1
  fi

  # Resolves through LaunchServices without launching the app.
  if ! osascript -e "id of application \"$app\"" >/dev/null 2>&1; then
    _ta_err "application not found: ${C_BOLD}$app${C_RESET}"
    _ta_info "Try ${C_DIM}TEAMS_A_APP=\"Microsoft Teams (work or school)\" teams-a${C_RESET}"
    return 1
  fi

  if [[ "$keep_awake" -eq 1 ]] && ! command -v caffeinate >/dev/null 2>&1; then
    _ta_warn "caffeinate not found — the display may still sleep."
    keep_awake=0
  fi

  # --- one refresh: focus Teams, then ⌘2 (Chat) ----------------------------
  # 1 = could not activate, 2 = keystroke blocked (usually Accessibility).
  _ta_refresh() {
    osascript -e "tell application \"$app\" to activate" >/dev/null 2>&1 || return 1
    sleep 0.4   # let the app take focus before the keystroke lands
    osascript -e 'tell application "System Events" to keystroke "2" using {command down}' \
      >/dev/null 2>&1 || return 2
    return 0
  }

  _ta_perm_hint() {
    _ta_info "Grant Accessibility to your terminal: ${C_DIM}System Settings → Privacy & Security → Accessibility${C_RESET}"
  }

  # --- single refresh ------------------------------------------------------
  local rc=0
  if [[ "$once" -eq 1 ]]; then
    _ta_refresh; rc=$?
    case "$rc" in
      0) _ta_ok "${C_BOLD}$app${C_RESET} status refreshed."; return 0 ;;
      2) _ta_err "the Cmd-2 keystroke was blocked."; _ta_perm_hint; return 1 ;;
      *) _ta_err "could not activate ${C_BOLD}$app${C_RESET}."; return 1 ;;
    esac
  fi

  # --- confirm before hijacking focus on a loop ----------------------------
  if [[ "$assume_yes" -eq 0 && -t 0 ]]; then
    _ta_warn "This grabs keyboard focus every ${interval}s until you press Ctrl-C."
    printf "%s Keep %s%s%s active? %s[y/N]%s " \
      "${C_YELLOW}${G_ASK}${C_RESET}" "${C_BOLD}" "$app" "${C_RESET}" \
      "${C_DIM}" "${C_RESET}"
    local reply; read -r reply
    case "$reply" in
      y|Y|yes|YES) ;;
      *) _ta_info "Aborted."; return 1 ;;
    esac
  fi

  # --- loop until interrupted ----------------------------------------------
  local caff_pid=""
  if [[ "$keep_awake" -eq 1 ]]; then
    caffeinate -d & caff_pid=$!
  fi

  # A global (not a local) so the trap can flip it from any scope.
  typeset -g _TEAMS_A_STOP=0
  trap 'typeset -g _TEAMS_A_STOP=1' INT TERM

  print -r -- "${C_BOLD}${C_CYAN}${G_BOX} teams-a${C_RESET} ${C_DIM}— refreshing $app every ${interval}s. Ctrl-C to stop.${C_RESET}"

  local count=0 warned_perm=0
  while [[ "$_TEAMS_A_STOP" -eq 0 ]]; do
    _ta_refresh; rc=$?
    case "$rc" in
      0) count=$((count + 1))
         _ta_ok "$(date '+%H:%M:%S') status refreshed ${C_DIM}(#$count)${C_RESET}" ;;
      2) _ta_warn "the Cmd-2 keystroke was blocked — this refresh may not count."
         if [[ "$warned_perm" -eq 0 ]]; then _ta_perm_hint; warned_perm=1; fi ;;
      *) _ta_warn "could not activate $app — is it installed and able to launch?" ;;
    esac
    [[ "$_TEAMS_A_STOP" -eq 1 ]] && break
    sleep "$interval"
  done

  [[ -n "$caff_pid" ]] && kill "$caff_pid" 2>/dev/null
  unset _TEAMS_A_STOP
  print -r -- ""
  _ta_info "stopped after ${C_BOLD}$count${C_RESET} refresh(es)."
  return 0
}
