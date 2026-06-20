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
#   claude-utils switch <profile>   load a profile into the active config dir.
#                                   No name = rotate to next. Also accepts
#                                   --best (most 5h quota left) or
#                                   --next-available (first under the limit).
#   claude-utils list               list profiles + access-token expiry
#                                   (--usage also shows 5h/7d quota + reset)
#   claude-utils status             show active account and resolved paths
#   claude-utils delete <profile>   remove a stored profile (rm/remove aliases)
#   claude-utils help               show usage
#
# RULE: never switch while a claude CLI session is running (guarded below).
# NOTE: switching swaps the stored token into the live store. If a profile's
#       token has expired, claude will prompt /login; afterwards run
#       'claude-utils save <profile>' to refresh the stored copy. Token refresh
#       from outside the official client does NOT work (Anthropic rate-limits
#       it), so re-login is the supported recovery — there is no refresh cmd.
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
# Credential store abstraction.
#
# On macOS, Claude Code's real token lives in the login Keychain
# (service "Claude Code-credentials", account = $USER), NOT in
# .credentials.json — which is only a fallback used over SSH / when Keychain
# is unavailable. So on macOS we must read/write the Keychain, or a switch has
# no visible effect (wrong account / wrong usage keeps showing).
#
# On Linux/WSL the file IS the source of truth.
#
# These helpers present one interface:
#   _cred_read  -> prints the live token JSON to stdout (empty if none)
#   _cred_write -> reads token JSON from stdin, stores it live
# Each also keeps .credentials.json in sync as a portable fallback.
# ---------------------------------------------------------------------------
CLAUDE_KEYCHAIN_SERVICE="Claude Code-credentials"

_claude_is_macos() { [[ "$(uname -s 2>/dev/null)" == "Darwin" ]]; }

# True when the macOS Keychain is the live credential store (macOS + `security`).
# Single predicate so read/write/present stay consistent about where creds live.
_cred_use_keychain() { _claude_is_macos && command -v security >/dev/null 2>&1; }

# Read the live token JSON.
_cred_read() {
  if _cred_use_keychain; then
    security find-generic-password -s "$CLAUDE_KEYCHAIN_SERVICE" -a "$USER" -w 2>/dev/null
    return 0
  fi
  [[ -f "$CLAUDE_CREDS_LIVE" ]] && cat "$CLAUDE_CREDS_LIVE"
}

# Write the live token JSON (from stdin) to the live store(s).
_cred_write() {
  local json; json="$(cat)"
  [[ -z "$json" ]] && return 1

  # Always refresh the file fallback too (used by SSH / non-GUI sessions).
  local dir; dir="$(dirname "$CLAUDE_CREDS_LIVE")"
  [[ -d "$dir" ]] || mkdir -p "$dir"
  printf '%s' "$json" > "$CLAUDE_CREDS_LIVE"
  chmod 600 "$CLAUDE_CREDS_LIVE" 2>/dev/null

  if _cred_use_keychain; then
    # -U updates the existing item in place (Claude reads this at startup).
    security add-generic-password -U \
      -s "$CLAUDE_KEYCHAIN_SERVICE" -a "$USER" -w "$json" 2>/dev/null
  fi
  return 0
}

# True if a live credential exists in either store.
_cred_present() {
  if _cred_use_keychain; then
    security find-generic-password -s "$CLAUDE_KEYCHAIN_SERVICE" -a "$USER" -w \
      >/dev/null 2>&1 && return 0
  fi
  [[ -s "$CLAUDE_CREDS_LIVE" ]]
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

# Print the PIDs of running claude CLI processes (one per line, deduped).
_claude_running_pids() {
  { pgrep -x claude 2>/dev/null; pgrep -f 'claude$' 2>/dev/null; } | sort -un
}

# True if a claude CLI process appears to be running.
_claude_running() { [[ -n "$(_claude_running_pids)" ]]; }

# --- internal: report the currently-active account email ------------------
_claude_active_email() {
  [[ -f "$CLAUDE_CONFIG_JSON" ]] || { echo ""; return; }
  jq -r '.oauthAccount.emailAddress // .oauthAccount.email // empty' \
     "$CLAUDE_CONFIG_JSON" 2>/dev/null
}

# Read a profile's stored account email from its .account.json ($1 = file path).
# Empty if the file is missing or has no email.
_claude_profile_email() {
  [[ -f "$1" ]] || { echo ""; return; }
  jq -r '.emailAddress // .email // empty' "$1" 2>/dev/null
}

# Find the profile name whose stored account email matches $1. Empty if none.
_claude_find_profile_by_email() {
  local want="$1" d
  [[ -z "$want" || ! -d "$CLAUDE_PROFILES_DIR" ]] && { echo ""; return; }
  for d in "$CLAUDE_PROFILES_DIR"/*(N/); do
    [[ "$(_claude_profile_email "$d/.account.json")" == "$want" ]] && { echo "${d:t}"; return; }
  done
  echo ""
}

# Right-pad a (possibly colour-coded) cell to a visible width.
# $1 = cell text (may contain ANSI), $2 = target visible width.
_claude_pad_cell() {
  local cell="$1" width="$2" plain pad
  plain="$(_claude_strip_ansi "$cell")"
  pad=$(( width - ${#plain} ))
  (( pad < 0 )) && pad=0
  print -rn -- "${cell}${(l:pad:: :)}"
}

# --- subcommand: save — capture current live login into a profile ----------
# Creates the profile if new. If it exists and the stored account email
# differs from the current live account, prompts before overwriting.
# 'init' is an alias for this in the dispatcher.
_claude_utils_save() {
  _claude_require_jq || return 1

  if ! _cred_present; then
    _c_err "No live credentials found — run ${C_BOLD}claude${C_RESET} and ${C_BOLD}/login${C_RESET} first."
    return 1
  fi
  if [[ ! -f "$CLAUDE_CONFIG_JSON" ]]; then
    _c_err "No ${C_DIM}$CLAUDE_CONFIG_JSON${C_RESET} found — run ${C_BOLD}claude${C_RESET} and ${C_BOLD}/login${C_RESET} first."
    return 1
  fi

  local live_email; live_email="$(_claude_active_email)"
  local prof="$1"

  # No name given: match the live account to an existing profile by email.
  # Matched -> reuse that profile (no prompt). Not matched -> ask for a name.
  if [[ -z "$prof" ]]; then
    prof="$(_claude_find_profile_by_email "$live_email")"
    if [[ -n "$prof" ]]; then
      _c_info "Matched current account ${C_GREEN}${live_email}${C_RESET} to profile $(_c_name "$prof")."
    else
      _c_info "Current account ${C_GREEN}${live_email:-(unknown)}${C_RESET} doesn't match any saved profile."
      printf "%s New profile name: %s" "${C_CYAN}${G_ASK}${C_RESET}" "${C_BOLD}${C_MAGENTA}"
      read -r prof; printf "%s" "${C_RESET}"
      prof="${prof## }"; prof="${prof%% }"          # trim surrounding spaces
      if [[ -z "$prof" ]]; then
        _c_info "Aborted — no name given."; return 1
      fi
    fi
  fi

  local src="$CLAUDE_PROFILES_DIR/$prof"

  # If the profile already exists, compare stored vs live account email.
  if [[ -f "$src/.account.json" ]]; then
    local stored_email
    stored_email="$(_claude_profile_email "$src/.account.json")"

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
  # capture the live token from the real store (Keychain on macOS, file on Linux)
  _cred_read > "$src/.credentials.json"
  chmod 600 "$src/.credentials.json" 2>/dev/null
  jq '.oauthAccount' "$CLAUDE_CONFIG_JSON" > "$src/.account.json"

  _c_ok "Saved profile $(_c_name "$prof")${live_email:+ ${C_DIM}(${C_RESET}$(_c_acct "$live_email")${C_DIM})${C_RESET}}."
}

# --- subcommand: switch — load a profile into the active config dir --------
# Usage: claude-utils switch [profile]
#   With no profile, rotates to the next profile after the active one.
_claude_utils_switch() {
  _claude_require_jq || return 1

  local prof="$1"

  # Quota-based auto-pick (reads the read-only usage API, not the token endpoint).
  #   --best            switch to the profile with the most 5h quota left
  #   --next-available  switch to the first profile under the rate-limit threshold
  if [[ "$prof" == "--best" || "$prof" == "--next-available" ]]; then
    local strategy="best"
    [[ "$prof" == "--next-available" ]] && strategy="next-available"
    _c_info "Checking quota across profiles…"
    local picked; picked="$(_claude_pick_profile "$strategy")"
    if [[ -z "$picked" ]]; then
      if [[ "$strategy" == "next-available" ]]; then
        _c_err "No profile is under the quota threshold right now. ${C_DIM}All accounts may be near their 5h limit — check 'claude-utils list --usage'.${C_RESET}"
      else
        _c_err "Couldn't read usage for any profile ${C_DIM}(network issue, or no profiles have a valid token).${C_RESET}"
      fi
      return 1
    fi
    _c_info "Selected profile $(_c_name "$picked") ${C_DIM}(strategy: ${strategy}).${C_RESET}"
    prof="$picked"
  fi

  # No name given -> rotate to the next profile (alphabetical) after active.
  if [[ -z "$prof" ]]; then
    local -a all
    local d
    for d in "$CLAUDE_PROFILES_DIR"/*(N/); do all+=("${d:t}"); done
    if [[ ${#all[@]} -eq 0 ]]; then
      _c_err "No profiles to rotate. Create one with ${C_BOLD}claude-utils save <name>${C_RESET}."
      return 1
    fi
    if [[ ${#all[@]} -eq 1 ]]; then
      prof="${all[1]}"
    else
      # find the active profile by matching its account email
      local active_email; active_email="$(_claude_active_email)"
      local i active_idx=0 e
      for i in {1..${#all[@]}}; do
        e="$(_claude_profile_email "$CLAUDE_PROFILES_DIR/${all[$i]}/.account.json")"
        if [[ -n "$active_email" && "$e" == "$active_email" ]]; then
          active_idx=$i; break
        fi
      done
      # next index (wrap); if active not found, start at first
      local next_idx=$(( active_idx % ${#all[@]} + 1 ))
      prof="${all[$next_idx]}"
    fi
    _c_info "Rotating to next profile: $(_c_name "$prof")"
  fi

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
  local killed_running=0
  if _claude_running; then
    local -a rpids
    rpids=(${(f)"$(_claude_running_pids)"})
    _c_warn "A ${C_BOLD}claude${C_RESET} process is running ${C_DIM}(it would keep the old account until restarted)${C_RESET}:"
    local rp pname
    for rp in "${rpids[@]}"; do
      [[ -z "$rp" ]] && continue
      pname="$(ps -p "$rp" -o comm= 2>/dev/null | sed 's#^.*/##' | tr -d ' ')"
      print -r -- "    ${C_DIM}pid${C_RESET} ${C_BOLD}$rp${C_RESET} ${C_DIM}${pname}${C_RESET}"
    done
    printf "%s Kill %sthese process(es)%s and continue switching? %s[y/N]%s " \
      "${C_YELLOW}${G_ASK}${C_RESET}" "${C_BOLD}" "${C_RESET}" "${C_DIM}" "${C_RESET}"
    local kreply; read -r kreply
    case "$kreply" in
      y|Y|yes|YES)
        for rp in "${rpids[@]}"; do
          [[ -z "$rp" ]] && continue
          if kill -9 "$rp" 2>/dev/null; then
            _c_ok "killed pid ${C_BOLD}$rp${C_RESET}"
          else
            _c_err "could not kill pid $rp (try with sudo?)"
            return 1
          fi
        done
        killed_running=1
        ;;
      *)
        _c_info "Aborted — no processes killed, no switch performed."
        return 1
        ;;
    esac
  fi

  # 1. swap credentials (token) into the real store: Keychain on macOS,
  #    file on Linux. _cred_write keeps both in sync.
  if ! _cred_write < "$src/.credentials.json"; then
    _c_err "Failed to write credentials to the live store."; return 1
  fi

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
  # Claude Code reads credentials only at startup (and caches the Keychain for
  # ~30s on macOS), so a running session keeps the old account until restarted.
  if [[ "$killed_running" -eq 1 ]]; then
    _c_info "Previous session was killed — relaunch ${C_BOLD}claude${C_RESET} for the new account."
  else
    _c_info "Restart any running ${C_BOLD}claude${C_RESET} session to pick up the new account."
  fi
}

# --- internal: fetch 5h/7d usage for a profile's token --------------------
# Reads the access token from a profile's .credentials.json and queries the
# (undocumented) OAuth usage endpoint. Prints "5h%|7d%|reset" or "" on failure.
# Network call — only invoked by `list --usage`.
_claude_profile_usage() {
  local credfile="$1"
  [[ -f "$credfile" ]] || { echo ""; return; }
  command -v curl >/dev/null 2>&1 || { echo ""; return; }

  local token
  token="$(jq -r '.claudeAiOauth.accessToken // .accessToken // empty' "$credfile" 2>/dev/null)"
  [[ -z "$token" ]] && { echo ""; return; }

  local resp
  resp="$(curl -s --max-time 8 \
            -H "Authorization: Bearer $token" \
            -H "Content-Type: application/json" \
            https://api.anthropic.com/api/oauth/usage 2>/dev/null)"
  [[ -z "$resp" ]] && { echo ""; return; }

  # Emit a 5-field TSV:
  #   1 5h pct (display, "?" if unknown)   2 7d pct (display)
  #   3 5h reset (ISO or "")               4 5h utilization (0..100, "" if unknown)
  #   5 7d utilization (0..100, "")
  # NOTE: the API's `utilization` is already a PERCENT (0..100), not a 0..1
  # fraction — do not multiply. Fields 4/5 feed quota-based selection.
  echo "$resp" | jq -r '
    def pct(x): if x == null then "?" else ((x | floor | tostring) + "%") end;
    def raw(x): if x == null then "" else (x | tostring) end;
    ( .five_hour.utilization  // .fiveHour.utilization )  as $u5 |
    ( .seven_day.utilization // .sevenDay.utilization )   as $u7 |
    [ pct($u5), pct($u7),
      (.five_hour.resets_at // .fiveHour.resetsAt // ""),
      raw($u5), raw($u7)
    ] | @tsv' 2>/dev/null
}

# Pick the best profile to switch to, by remaining quota.
# Strategy: "best" = lowest 5h utilization; "next-available" = first profile
# under the rate-limit threshold (default 98, i.e. 98%), skipping any at/over it.
# Utilization values are 0..100 (percent), matching the usage API.
# Prints the chosen profile name to stdout, or empty if none qualifies.
# Reads the usage API (read-only, NOT the token endpoint) once per profile.
_claude_pick_profile() {
  local strategy="${1:-best}" threshold="${2:-98}"
  [[ -d "$CLAUDE_PROFILES_DIR" ]] || { echo ""; return; }

  local d prof u u5 best_prof="" best_u5=999
  for d in "$CLAUDE_PROFILES_DIR"/*(N/); do
    prof="${d:t}"
    [[ -f "$d/.credentials.json" ]] || continue
    u="$(_claude_profile_usage "$d/.credentials.json")"
    [[ -z "$u" ]] && continue
    u5="$(print -r -- "$u" | cut -f4)"          # 5h utilization, 0..100
    [[ -z "$u5" ]] && continue
    if [[ "$strategy" == "next-available" ]]; then
      if awk "BEGIN{exit !($u5 < $threshold)}"; then echo "$prof"; return; fi
    else  # best = lowest utilization
      if awk "BEGIN{exit !($u5 < $best_u5)}"; then best_u5="$u5"; best_prof="$prof"; fi
    fi
  done
  echo "$best_prof"
}

# Read the access-token expiry (epoch ms) from a creds JSON file. Empty if none.
_claude_creds_expiry() {
  local credfile="$1"
  [[ -f "$credfile" ]] || { echo ""; return; }
  jq -r '.claudeAiOauth.expiresAt // .expiresAt // empty' "$credfile" 2>/dev/null
}

# --- internal: strip ANSI colour codes (for column-width math) -------------
# Uses local options so enabling extended_glob doesn't leak into the caller's
# shell. Needed because the ## match below requires EXTENDED_GLOB.
_claude_strip_ansi() {
  emulate -L zsh
  setopt extended_glob
  local s="$1"
  print -rn -- "${s//$'\e'\[[0-9;]##m/}"
}

# --- internal: compact access-token expiry cell for `list` -----------------
# Reads expiresAt from a creds file and returns a short, coloured cell like
# "2h", "3d", "-1h" (expired 1h ago), or "—" (unknown). Local-only, no network.
#
# NOTE: this is the ACCESS token's expiry (the short-lived ~8h token). There is
# NO readable expiry for the REFRESH token — that lifetime is server-side and
# isn't in the file. If a token has expired, claude prompts /login on next use;
# token refresh from outside the official client does not work (rate-limited).
_claude_expiry_cell() {
  local cf="$1"
  local exp; exp="$(_claude_creds_expiry "$cf")"
  if [[ -z "$exp" || "$exp" == "null" ]]; then
    print -rn -- "${C_DIM}—${C_RESET}"; return
  fi
  local now=$(( $(date +%s) ))
  local exp_s=$(( exp/1000 ))
  local s=$(( exp_s - now )) neg=0
  (( s < 0 )) && { neg=1; s=$(( -s )); }
  local d=$(( s/86400 )) h=$(( (s%86400)/3600 )) m=$(( (s%3600)/60 ))
  local v
  if   (( d > 0 )); then v="${d}d$(( h ))h"
  elif (( h > 0 )); then v="${h}h${m}m"
  else                   v="${m}m"
  fi
  if (( neg )); then
    print -rn -- "${C_RED}-${v}${C_RESET}"      # expired this long ago
  else
    print -rn -- "${C_GREEN}${v}${C_RESET}"     # valid for this long
  fi
}

# --- subcommand: list — show profiles, mark the active one -----------------
# Usage: claude-utils list [--usage]
#   Always shows a local, no-network EXPIRES column (access-token time left;
#   green = valid for, red "-" = expired ago, — = unknown).
#   --usage  also query and show each account's 5h / 7d quota (network call)
_claude_utils_list() {
  _claude_require_jq || return 1

  local show_usage=0
  [[ "$1" == "--usage" || "$1" == "-u" ]] && show_usage=1

  if [[ ! -d "$CLAUDE_PROFILES_DIR" ]]; then
    _c_warn "No profiles dir at ${C_DIM}$CLAUDE_PROFILES_DIR${C_RESET}. Create one with ${C_BOLD}claude-utils save <name>${C_RESET}."
    return 0
  fi

  local active_email; active_email="$(_claude_active_email)"
  local found=0 d prof email
  # declare loop-locals once; re-using `local` inside the loop makes zsh echo them
  local use5 use7 use_reset reset_iso u is_active name_col acct_col mark acct_disp exp_disp

  if [[ "$show_usage" -eq 1 ]]; then
    print -r -- "${C_BOLD}  PROFILE      ACCOUNT                        EXPIRES    5H     7D    RESET(5H)${C_RESET}"
  else
    print -r -- "${C_BOLD}  PROFILE      ACCOUNT                        EXPIRES${C_RESET}"
  fi

  for d in "$CLAUDE_PROFILES_DIR"/*(N/); do
    found=1
    prof="${d:t}"
    email="$(_claude_profile_email "$d/.account.json")"

    # optional usage columns
    use5=""; use7=""; use_reset=""
    if [[ "$show_usage" -eq 1 ]]; then
      u="$(_claude_profile_usage "$d/.credentials.json")"
      if [[ -n "$u" ]]; then
        use5="${u%%	*}"
        use7="$(print -r -- "$u" | cut -f2)"
        reset_iso="$(print -r -- "$u" | cut -f3)"
        if [[ -n "$reset_iso" ]]; then
          # ISO8601 -> local HH:MM (GNU date, then BSD/macOS date fallback)
          use_reset="$(python3 -c "from datetime import datetime; import os; os.environ['TZ']='Asia/Hong_Kong'; import time; time.tzset(); print(datetime.fromisoformat('${reset_iso}').astimezone().strftime('%H:%M'))" 2>/dev/null || echo "?")"
        else
          use_reset="—"
        fi
      else
        use5="—"; use7="—"; use_reset="—"
      fi
    fi

    # local, no-network expiry cell (coloured), padded to width 8
    exp_disp="$(_claude_pad_cell "$(_claude_expiry_cell "$d/.credentials.json")" 8)"

    is_active=0
    [[ -n "$active_email" && "$email" == "$active_email" ]] && is_active=1

    if [[ "$is_active" -eq 1 ]]; then
      mark="${C_GREEN}${G_DOT}${C_RESET}"
      name_col="${C_BOLD}${C_GREEN}"
      acct_col="${C_GREEN}"
    else
      mark=" "
      name_col="${C_MAGENTA}"
      acct_col="${C_CYAN}"
    fi

    # Build the account cell, padded to a visible width of 30 (colour-safe).
    if [[ -n "$email" ]]; then
      acct_disp="$(_claude_pad_cell "${acct_col}${email}${C_RESET}" 30)"
    else
      acct_disp="$(_claude_pad_cell "${C_DIM}(no .account.json)${C_RESET}" 30)"
    fi

    if [[ "$show_usage" -eq 1 ]]; then
      printf "%s %s%-12s%s %s %s %s%5s%s  %s%5s%s   %s%s%s\n" \
        "$mark" "$name_col" "$prof" "${C_RESET}" \
        "$acct_disp" \
        "$exp_disp" \
        "${C_YELLOW}" "$use5" "${C_RESET}" \
        "${C_YELLOW}" "$use7" "${C_RESET}" \
        "${C_DIM}" "$use_reset" "${C_RESET}"
    else
      printf "%s %s%-12s%s %s %s\n" \
        "$mark" "$name_col" "$prof" "${C_RESET}" "$acct_disp" "$exp_disp"
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
  # Where the real token lives differs by platform.
  local store
  if _cred_use_keychain; then
    store="macOS Keychain (\"$CLAUDE_KEYCHAIN_SERVICE\") + file fallback"
  else
    store="$CLAUDE_CREDS_LIVE"
  fi
  printf "  %sToken store:  %s ${C_DIM}%s${C_RESET}\n" "${C_DIM}" "${C_RESET}" "$store"
  local email; email="$(_claude_active_email)"
  if [[ -n "$email" ]]; then
    printf "  %sActive account:%s %s%s%s\n" \
      "${C_DIM}" "${C_RESET}" "${C_BOLD}${C_GREEN}" "$email" "${C_RESET}"
  else
    printf "  %sActive account:%s %s(none found)%s\n" \
      "${C_DIM}" "${C_RESET}" "${C_RED}" "${C_RESET}"
  fi
}

# --- subcommand: delete — remove a stored profile --------------------------
# Usage: claude-utils delete <profile>
#   Destructive: removes the profile dir (token + account). Defaults to No.
#   If the profile is the currently-active account, requires an extra
#   confirmation, since the live login keeps working but its backup is gone.
# 'remove'/'rm' are aliases for this in the dispatcher.
_claude_utils_delete() {
  local prof="$1"
  if [[ -z "$prof" ]]; then
    _c_info "usage: ${C_BOLD}claude-utils delete <profile>${C_RESET}"; return 1
  fi

  local src="$CLAUDE_PROFILES_DIR/$prof"
  if [[ ! -d "$src" ]]; then
    _c_err "No profile $(_c_name "$prof")  ${C_DIM}(see 'claude-utils list')${C_RESET}"; return 2
  fi

  # Look up the stored account email (best effort) to show what's affected.
  local stored_email=""
  if [[ -f "$src/.account.json" ]] && command -v jq >/dev/null 2>&1; then
    stored_email="$(_claude_profile_email "$src/.account.json")"
  fi

  # Is this the currently-active account?
  local active_email; active_email="$(_claude_active_email 2>/dev/null)"
  local is_active=0
  [[ -n "$stored_email" && "$stored_email" == "$active_email" ]] && is_active=1

  _c_warn "About to ${C_BOLD}${C_RED}delete${C_RESET} profile $(_c_name "$prof")${stored_email:+ ${C_DIM}(${C_RESET}$(_c_acct "$stored_email")${C_DIM})${C_RESET}}:"
  print -r -- "    ${C_DIM}path:${C_RESET} ${C_DIM}$src${C_RESET}"
  if [[ "$is_active" -eq 1 ]]; then
    _c_warn "This is the ${C_BOLD}${C_YELLOW}currently-active${C_RESET} account. Your live login keeps working,"
    _c_warn "but its saved backup will be gone — you'd need to ${C_BOLD}save${C_RESET} it again to restore it."
  fi

  printf "%s Delete profile %s%s%s? %s[y/N]%s " \
    "${C_YELLOW}${G_ASK}${C_RESET}" \
    "${C_BOLD}${C_MAGENTA}" "$prof" "${C_RESET}" \
    "${C_DIM}" "${C_RESET}"
  local reply; read -r reply
  case "$reply" in
    y|Y|yes|YES) ;;                                          # proceed
    *) _c_info "Aborted — profile $(_c_name "$prof") left unchanged."; return 1 ;;
  esac

  if rm -rf -- "$src"; then
    _c_ok "Deleted profile $(_c_name "$prof")."
  else
    _c_err "Failed to delete ${C_DIM}$src${C_RESET}"; return 1
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
  ${C_CYAN}claude-utils switch${C_RESET} ${C_DIM}[profile]${C_RESET}   load a profile ${C_DIM}(no name = rotate; --best / --next-available pick by quota)${C_RESET}
  ${C_CYAN}claude-utils list${C_RESET} ${C_DIM}[--usage]${C_RESET}     list profiles + token expiry ${C_DIM}(--usage adds 5h/7d quota + reset)${C_RESET}
  ${C_CYAN}claude-utils delete${C_RESET} ${C_DIM}<profile>${C_RESET}   delete a stored profile ${C_DIM}(rm is an alias; asks first)${C_RESET}
  ${C_CYAN}claude-utils status${C_RESET}            show the active account and resolved paths
  ${C_CYAN}claude-utils help${C_RESET}              show this help

${C_BOLD}Typical setup:${C_RESET}
  ${C_DIM}claude                       # log in as account 1, then exit${C_RESET}
  claude-utils save ${C_MAGENTA}pro${C_RESET}
  ${C_DIM}claude                       # /login as account 2, then exit${C_RESET}
  claude-utils save ${C_MAGENTA}max${C_RESET}
  claude-utils switch ${C_MAGENTA}pro${C_RESET} && claude

${C_BOLD}When you hit a quota limit:${C_RESET}
  ${C_DIM}# see each account's 5h / 7d usage and when the 5h window resets:${C_RESET}
  claude-utils list --usage
  ${C_DIM}# jump to whichever account has the most 5h quota left, then launch:${C_RESET}
  claude-utils switch --best && claude
  ${C_DIM}# or just skip to the first account under the rate limit:${C_RESET}
  claude-utils switch --next-available && claude

${C_DIM}Note: after switching, restart any running claude session for it to take effect.${C_RESET}
${C_DIM}If a profile's token has expired, claude will prompt /login; then run 'save' to${C_RESET}
${C_DIM}refresh the stored copy. Token refresh outside the official client does not work${C_RESET}
${C_DIM}(Anthropic rate-limits it), so re-login is the supported recovery.${C_RESET}
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
    delete)  _claude_utils_delete "$@" ;;
    remove)  _claude_utils_delete "$@" ;;   # alias for delete
    rm)      _claude_utils_delete "$@" ;;   # alias for delete
    status)  _claude_utils_status "$@" ;;
    help|-h|--help|"") _claude_utils_help ;;
    *)
      _c_err "unknown command ${C_BOLD}'$cmd'${C_RESET}"
      _c_info "Run ${C_BOLD}claude-utils help${C_RESET} for usage."
      return 1
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Convenience wrapper: cc [profile] [--danger] [claude_args...]
#
# Switch to named profile (if given), then launch claude. One command
# for the daily "come back after days, use account X" flow.
#
#   cc pro                   # switch to pro, open claude
#   cc max --danger -p "..." # switch to max, skip permissions, run prompt
#   cc                       # use the ACTIVE profile, just open claude
#   cc --danger -p "..."     # use the active profile, no switch
#
# A leading-dash first arg (or no arg) means "no profile" -> don't switch,
# launch claude with the active account. The first arg is treated as a
# profile name only when it doesn't look like a flag.
#
# If refresh fails because the refresh token was revoked, this still switches
# and launches — claude will prompt /login, after which run: claude-utils save <p>
# ---------------------------------------------------------------------------
cc() {
  # First arg is a profile only if present and not a flag (no leading dash).
  # Otherwise: skip the switch and use the currently-active account.
  if [[ -n "$1" && "$1" != -* ]]; then
    claude-utils switch "$1" || return 1
    shift   # drop the profile name; the rest goes to claude
  fi

  local final_args=()
  # Loop through remaining arguments to detect and translate custom flags
  while [[ $# -gt 0 ]]; do
    if [[ "$1" == "--danger" ]]; then
      # Replace human-friendly --danger with Claude's official bypass flag
      final_args+=("--dangerously-skip-permissions")
    else
      # Keep all other flags and prompt texts exactly as typed
      final_args+=("$1")
    fi
    shift
  done

  # Launch Claude with the processed arguments array safely preserved
  headroom wrap claude --no-serena "${final_args[@]}"
}