#!/bin/zsh
# ============================================================================
# claude-utils.sh — Multi-account switcher for Claude Code (CLI)
# ============================================================================
#
# Switches between Claude Code accounts by swapping the credential token and
# splicing the per-account oauthAccount identity into the active .claude.json.
# Project history, MCP state, plugins, skills and agents stay shared because
# only the oauthAccount field is rewritten — the rest of .claude.json is left
# untouched, and the profiles/ dir lives inside the config dir so it is
# naturally excluded from per-account forking.
#
# ---------------------------------------------------------------------------
# LAYOUT  (no CLAUDE_CONFIG_DIR — default)
#   ~/.claude.json                                 # identity/state (oauthAccount swapped)
#   ~/.claude/.credentials.json                    # live token (swapped on switch)
#   ~/.claude/profiles/<name>/.credentials.json    # stashed token per account
#   ~/.claude/profiles/<name>/.account.json        # raw oauthAccount object (flat)
#
# LAYOUT  (CLAUDE_CONFIG_DIR set — everything lives under it)
#   $CLAUDE_CONFIG_DIR/.claude.json
#   $CLAUDE_CONFIG_DIR/.credentials.json
#   $CLAUDE_CONFIG_DIR/profiles/<name>/...
#
# .account.json is the RAW oauthAccount object, e.g.
#   { "accountUuid": "...", "emailAddress": "...", "organizationUuid": "...", ... }
#
# ---------------------------------------------------------------------------
# INSTALL  (add to ~/.zshrc)
#   source ~/path/to/claude-utils.sh
#
# COMMANDS
#   claude-utils save   <profile>   capture current live login into a profile
#                                   (init is an alias). Creates if new; if the
#                                   profile holds a different account, asks
#                                   before overwriting.
#   claude-utils init   <profile>   alias for 'save'
#   claude-utils switch <profile>   load a profile into the active config dir
#   claude-utils list               list profiles, mark the active one
#   claude-utils status             show active account and resolved paths
#   claude-utils help               show usage
#
# RULE: never switch while a claude CLI session is running (guarded below).
# NOTE: uses `cp` for the token, so run `claude-utils save <prof>` after a
#       session if the token was refreshed and you want the profile current.
# ============================================================================

# ---------------------------------------------------------------------------
# Path resolution.
#
# The config dir is CLAUDE_CONFIG_DIR if set, otherwise ~/.claude.
# Resolved at CALL TIME (in _claude_resolve_paths) so a CLAUDE_CONFIG_DIR
# exported after sourcing is still honored.
#
# Layout fact that drives this:
#   - CLAUDE_CONFIG_DIR set  -> EVERYTHING under it, including
#       $CLAUDE_CONFIG_DIR/.claude.json and $CLAUDE_CONFIG_DIR/.credentials.json
#   - no CLAUDE_CONFIG_DIR    -> config dir is ~/.claude (credentials, profiles),
#     but the identity/state file is the TOP-LEVEL ~/.claude.json in $HOME.
#
#   CLAUDE_HOME          -> $CLAUDE_CONFIG_DIR (if set) else ~/.claude
#   CLAUDE_CREDS_LIVE    -> $CLAUDE_HOME/.credentials.json
#   CLAUDE_CONFIG_JSON   -> $CLAUDE_CONFIG_DIR/.claude.json (if dir set)
#                           else ~/.claude.json
#   CLAUDE_PROFILES_DIR  -> $CLAUDE_HOME/profiles
#
# Profiles are stored per config-dir, so a profile captured under one
# CLAUDE_CONFIG_DIR is not visible under another. That is intentional.
# ---------------------------------------------------------------------------
_claude_resolve_paths() {
  if [[ -n "$CLAUDE_CONFIG_DIR" ]]; then
    CLAUDE_HOME="${CLAUDE_CONFIG_DIR%/}"
    CLAUDE_CONFIG_JSON="$CLAUDE_HOME/.claude.json"
  else
    CLAUDE_HOME="$HOME/.claude"
    CLAUDE_CONFIG_JSON="$HOME/.claude.json"
  fi

  CLAUDE_PROFILES_DIR="$CLAUDE_HOME/profiles"
  CLAUDE_CREDS_LIVE="$CLAUDE_HOME/.credentials.json"
}

# ---------------------------------------------------------------------------
# Colour palette + print helpers.
#
# Colours are enabled only when stdout is a TTY and NO_COLOR is unset, so
# piping/redirecting output stays clean. Re-evaluated at call time.
# ---------------------------------------------------------------------------
_claude_init_colors() {
  if [[ -t 1 && -z "$NO_COLOR" ]]; then
    C_RESET=$'\e[0m'
    C_BOLD=$'\e[1m'
    C_DIM=$'\e[2m'
    C_RED=$'\e[31m'
    C_GREEN=$'\e[32m'
    C_YELLOW=$'\e[33m'
    C_BLUE=$'\e[34m'
    C_MAGENTA=$'\e[35m'
    C_CYAN=$'\e[36m'
    G_OK="✓" G_ERR="✗" G_WARN="!" G_INFO="›" G_DOT="●" G_ASK="?"
  else
    C_RESET="" C_BOLD="" C_DIM="" C_RED="" C_GREEN="" \
    C_YELLOW="" C_BLUE="" C_MAGENTA="" C_CYAN=""
    G_OK="[ok]" G_ERR="[x]" G_WARN="[!]" G_INFO="-" G_DOT="*" G_ASK="?"
  fi
}

# Leading glyph + colour for each message class.
_c_ok()    { print -r -- "${C_GREEN}${G_OK}${C_RESET} $*"; }
_c_err()   { print -r -- "${C_RED}${G_ERR}${C_RESET} $*" >&2; }
_c_warn()  { print -r -- "${C_YELLOW}${G_WARN}${C_RESET} $*"; }
_c_info()  { print -r -- "${C_CYAN}${G_INFO}${C_RESET} $*"; }
# Inline emphasis helpers.
_c_name()  { print -rn -- "${C_BOLD}${C_MAGENTA}$*${C_RESET}"; }
_c_acct()  { print -rn -- "${C_CYAN}$*${C_RESET}"; }

# --- internal: dependency + running-process guards -------------------------
_claude_require_jq() {
  if ! command -v jq >/dev/null 2>&1; then
    _c_err "${C_BOLD}jq${C_RESET} is required but not found in PATH."
    return 1
  fi
}

_claude_running() {
  # True if a claude CLI process appears to be running.
  pgrep -x claude >/dev/null 2>&1 || pgrep -f 'claude$' >/dev/null 2>&1
}

# --- internal: report the currently-active account email ------------------
_claude_active_email() {
  [[ -f "$CLAUDE_CONFIG_JSON" ]] || { echo ""; return; }
  jq -r '.oauthAccount.emailAddress // .oauthAccount.email // empty' \
     "$CLAUDE_CONFIG_JSON" 2>/dev/null
}

# --- subcommand: save — capture current live login into a profile ----------
# Creates the profile if new. If it exists and the stored account email
# differs from the current live account, prompts before overwriting.
# 'init' is an alias for this in the dispatcher.
_claude_utils_save() {
  local prof="$1"
  if [[ -z "$prof" ]]; then
    _c_info "usage: ${C_BOLD}claude-utils save <profile>${C_RESET}"; return 1
  fi
  _claude_require_jq || return 1

  if [[ ! -f "$CLAUDE_CREDS_LIVE" ]]; then
    _c_err "No live credentials at ${C_DIM}$CLAUDE_CREDS_LIVE${C_RESET} — run ${C_BOLD}claude${C_RESET} and ${C_BOLD}/login${C_RESET} first."
    return 1
  fi
  if [[ ! -f "$CLAUDE_CONFIG_JSON" ]]; then
    _c_err "No ${C_DIM}$CLAUDE_CONFIG_JSON${C_RESET} found — run ${C_BOLD}claude${C_RESET} and ${C_BOLD}/login${C_RESET} first."
    return 1
  fi

  local src="$CLAUDE_PROFILES_DIR/$prof"
  local live_email; live_email="$(_claude_active_email)"

  # If the profile already exists, compare stored vs live account email.
  if [[ -f "$src/.account.json" ]]; then
    local stored_email
    stored_email="$(jq -r '.emailAddress // .email // empty' "$src/.account.json" 2>/dev/null)"

    if [[ -n "$stored_email" && "$stored_email" != "$live_email" ]]; then
      _c_warn "Profile $(_c_name "$prof") currently holds a ${C_BOLD}${C_YELLOW}DIFFERENT${C_RESET} account:"
      print -r -- "    ${C_DIM}stored: ${C_RESET} ${C_RED}${stored_email}${C_RESET}"
      print -r -- "    ${C_DIM}current:${C_RESET} ${C_GREEN}${live_email:-(unknown)}${C_RESET}"
      printf "%s Overwrite %s%s%s with the current account? %s[y/N]%s " \
        "${C_YELLOW}${G_ASK}${C_RESET}" \
        "${C_BOLD}${C_MAGENTA}" "$prof" "${C_RESET}" \
        "${C_DIM}" "${C_RESET}"
      local reply; read -r reply
      case "$reply" in
        y|Y|yes|YES) ;;                                   # proceed
        *) _c_info "Aborted — profile $(_c_name "$prof") left unchanged."; return 1 ;;
      esac
    fi
  fi

  mkdir -p "$src"
  cp "$CLAUDE_CREDS_LIVE" "$src/.credentials.json"
  jq '.oauthAccount' "$CLAUDE_CONFIG_JSON" > "$src/.account.json"

  _c_ok "Saved profile $(_c_name "$prof")${live_email:+ ${C_DIM}(${C_RESET}$(_c_acct "$live_email")${C_DIM})${C_RESET}}."
}

# --- subcommand: switch — load a profile into the active config dir --------
_claude_utils_switch() {
  local prof="$1"
  if [[ -z "$prof" ]]; then
    _c_info "usage: ${C_BOLD}claude-utils switch <profile>${C_RESET}"; return 1
  fi
  _claude_require_jq || return 1

  local src="$CLAUDE_PROFILES_DIR/$prof"
  if [[ ! -d "$src" ]]; then
    _c_err "No profile $(_c_name "$prof")  ${C_DIM}(see 'claude-utils list')${C_RESET}"; return 1
  fi
  if [[ ! -f "$src/.credentials.json" ]]; then
    _c_err "Missing ${C_BOLD}.credentials.json${C_RESET} in profile $(_c_name "$prof")"; return 1
  fi
  if [[ ! -f "$src/.account.json" ]]; then
    _c_err "Missing ${C_BOLD}.account.json${C_RESET} in profile $(_c_name "$prof")"; return 1
  fi
  if [[ ! -f "$CLAUDE_CONFIG_JSON" ]]; then
    _c_err "No ${C_DIM}$CLAUDE_CONFIG_JSON${C_RESET} — run ${C_BOLD}claude${C_RESET} once to initialise it."; return 1
  fi
  if _claude_running; then
    _c_err "A ${C_BOLD}claude${C_RESET} process is running — close it first."; return 1
  fi

  # 1. swap credentials (token)
  cp "$src/.credentials.json" "$CLAUDE_CREDS_LIVE"

  # 2. splice the raw oauthAccount object into .claude.json (atomic via mv)
  local tmp; tmp="$(mktemp)"
  if jq --slurpfile oa "$src/.account.json" \
       '.oauthAccount = $oa[0]' "$CLAUDE_CONFIG_JSON" > "$tmp"; then
    mv "$tmp" "$CLAUDE_CONFIG_JSON"
  else
    rm -f "$tmp"
    _c_err "Failed to splice oauthAccount into ${C_DIM}$CLAUDE_CONFIG_JSON${C_RESET}"; return 1
  fi

  local email; email="$(_claude_active_email)"
  _c_ok "Switched to profile $(_c_name "$prof")${email:+ ${C_DIM}(${C_RESET}$(_c_acct "$email")${C_DIM})${C_RESET}}"
}

# --- subcommand: list — show profiles, mark the active one -----------------
_claude_utils_list() {
  _claude_require_jq || return 1

  if [[ ! -d "$CLAUDE_PROFILES_DIR" ]]; then
    _c_warn "No profiles dir at ${C_DIM}$CLAUDE_PROFILES_DIR${C_RESET}. Create one with ${C_BOLD}claude-utils save <name>${C_RESET}."
    return 0
  fi

  local active_email; active_email="$(_claude_active_email)"
  local found=0 d prof email

  print -r -- "${C_BOLD}  PROFILE      ACCOUNT${C_RESET}"
  for d in "$CLAUDE_PROFILES_DIR"/*(N/); do
    found=1
    prof="${d:t}"
    if [[ -f "$d/.account.json" ]]; then
      email="$(jq -r '.emailAddress // .email // empty' "$d/.account.json" 2>/dev/null)"
    else
      email=""
    fi
    if [[ -n "$active_email" && "$email" == "$active_email" ]]; then
      # active row: green dot, bold name, highlighted account
      printf "%s %s%-12s%s %s\n" \
        "${C_GREEN}${G_DOT}${C_RESET}" \
        "${C_BOLD}${C_GREEN}" "$prof" "${C_RESET}" \
        "${C_GREEN}${email}${C_RESET}"
    else
      local acct_disp
      if [[ -n "$email" ]]; then
        acct_disp="${C_CYAN}${email}${C_RESET}"
      else
        acct_disp="${C_DIM}(no .account.json)${C_RESET}"
      fi
      printf "%s %s%-12s%s %s\n" \
        " " \
        "${C_MAGENTA}" "$prof" "${C_RESET}" \
        "$acct_disp"
    fi
  done

  if [[ "$found" -eq 0 ]]; then
    _c_warn "No profiles found. Create one with ${C_BOLD}claude-utils save <name>${C_RESET}."
  fi
}

# --- subcommand: status — show the currently-active account ----------------
_claude_utils_status() {
  _claude_require_jq || return 1
  print -r -- "${C_BOLD}claude-utils${C_RESET} ${C_DIM}status${C_RESET}"
  printf "  %sConfig dir:   %s %s%s\n" \
    "${C_DIM}" "${C_RESET}" "$CLAUDE_HOME" \
    "${CLAUDE_CONFIG_DIR:+  ${C_YELLOW}(from CLAUDE_CONFIG_DIR)${C_RESET}}"
  printf "  %sIdentity file:%s ${C_DIM}%s${C_RESET}\n" "${C_DIM}" "${C_RESET}" "$CLAUDE_CONFIG_JSON"
  printf "  %sToken file:   %s ${C_DIM}%s${C_RESET}\n" "${C_DIM}" "${C_RESET}" "$CLAUDE_CREDS_LIVE"
  local email; email="$(_claude_active_email)"
  if [[ -n "$email" ]]; then
    printf "  %sActive account:%s %s%s%s\n" \
      "${C_DIM}" "${C_RESET}" "${C_BOLD}${C_GREEN}" "$email" "${C_RESET}"
  else
    printf "  %sActive account:%s %s(none found)%s\n" \
      "${C_DIM}" "${C_RESET}" "${C_RED}" "${C_RESET}"
  fi
}

# --- usage -----------------------------------------------------------------
_claude_utils_help() {
  cat <<USAGE
${C_BOLD}${C_MAGENTA}claude-utils${C_RESET} ${C_DIM}— Claude Code multi-account switcher${C_RESET}

${C_BOLD}Usage:${C_RESET}
  ${C_CYAN}claude-utils save${C_RESET}   ${C_DIM}<profile>${C_RESET}   capture the current live login into a profile
                              ${C_DIM}(init is an alias). Creates if new; if the${C_RESET}
                              ${C_DIM}profile holds a different account, asks first.${C_RESET}
  ${C_CYAN}claude-utils init${C_RESET}   ${C_DIM}<profile>${C_RESET}   alias for ${C_BOLD}save${C_RESET}
  ${C_CYAN}claude-utils switch${C_RESET} ${C_DIM}<profile>${C_RESET}   load a profile into the active config dir
  ${C_CYAN}claude-utils list${C_RESET}              list profiles ${C_DIM}(active one marked ${C_GREEN}${G_DOT}${C_RESET}${C_DIM})${C_RESET}
  ${C_CYAN}claude-utils status${C_RESET}            show the active account and resolved paths
  ${C_CYAN}claude-utils help${C_RESET}              show this help

${C_BOLD}Typical setup:${C_RESET}
  ${C_DIM}claude                       # log in as account 1, then exit${C_RESET}
  claude-utils save ${C_MAGENTA}pro${C_RESET}
  ${C_DIM}claude                       # /login as account 2, then exit${C_RESET}
  claude-utils save ${C_MAGENTA}max${C_RESET}
  claude-utils switch ${C_MAGENTA}pro${C_RESET} && claude
USAGE
}

# --- dispatcher ------------------------------------------------------------
claude-utils() {
  local cmd="$1"
  shift 2>/dev/null

  # Resolve live paths + colours now (honour CLAUDE_CONFIG_DIR / NO_COLOR).
  _claude_resolve_paths
  _claude_init_colors

  case "$cmd" in
    save)    _claude_utils_save   "$@" ;;
    init)    _claude_utils_save   "$@" ;;   # alias for save
    switch)  _claude_utils_switch "$@" ;;
    list)    _claude_utils_list   "$@" ;;
    status)  _claude_utils_status "$@" ;;
    help|-h|--help|"") _claude_utils_help ;;
    *)
      _c_err "unknown command ${C_BOLD}'$cmd'${C_RESET}"
      _c_info "Run ${C_BOLD}claude-utils help${C_RESET} for usage."
      return 1
      ;;
  esac
}