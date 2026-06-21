#!/bin/zsh
# ============================================================================
# ai-sweeper — clear AI agent caches, logs, and dead sessions
# ============================================================================
#
# INSTALL (add to ~/.zshrc):
#   source ~/Documents/gizmos/ai-sweeper.sh
#
# COMMANDS:
#   ai-sweeper status              disk usage per agent
#   ai-sweeper list [AGENT]        preview targets (all agents if omitted)
#   ai-sweeper clean [AGENT]        delete one agent's junk (no arg = all agents)
#
# FLAGS:
#   --dry-run                    preview only, delete nothing
#
# AGENTS:
#   claude-code       Claude Code CLI  (~/.claude/projects, statsig, logs …)
#   claude-desktop    Claude Desktop   (~/Library/Application Support/Claude/)
#   codex-cli         Codex CLI        (~/.codex/sessions, XDG cache/state)
#   codex-desktop     Codex Desktop    (~/Library/Application Support/Codex/)
#   opencode          OpenCode         (~/.local/share/opencode/logs …)
#   pi                Pi Coding Agent  (~/.pi/agent/sessions/)
#
# macOS-primary. XDG paths included as Linux fallbacks.
# Config files (~/.claude/settings.json, ~/.codex/config, etc.) are NOT touched.
# ============================================================================

# --- colour + glyphs (TTY + NO_COLOR aware) ---------------------------------
_aac_init_colors() {
  if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    C_RESET=$'\e[0m'; C_BOLD=$'\e[1m'; C_DIM=$'\e[2m'
    C_RED=$'\e[31m'; C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'
    C_BLUE=$'\e[34m'; C_MAGENTA=$'\e[35m'; C_CYAN=$'\e[36m'
    G_OK="✓"; G_FAIL="✗"; G_WARN="!"; G_ASK="?"; G_ARROW="▸"
  else
    C_RESET=""; C_BOLD=""; C_DIM=""
    C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_MAGENTA=""; C_CYAN=""
    G_OK=""; G_FAIL=""; G_WARN=""; G_ASK="?"; G_ARROW="*"
  fi
}

# Absolute path to this file, captured at source time (zsh %x = current file).
# Used by the help text so the install hint reflects the real location.
_AAC_SELF="${${(%):-%x}:A}"

# --- print helpers ----------------------------------------------------------
_c_ok()   { printf '  %s%-5s%s %s\n' "${C_GREEN}"  "${G_OK} OK"   "${C_RESET}" "$*"; }
_c_err()  { printf '  %s%-5s%s %s\n' "${C_RED}"    "${G_FAIL} FAIL" "${C_RESET}" "$*" >&2; }
_c_warn() { printf '  %s%-5s%s %s\n' "${C_YELLOW}" "${G_WARN} WARN" "${C_RESET}" "$*"; }
_c_info() { printf '  %s%s%s\n'      "${C_DIM}"    "$*"             "${C_RESET}"; }
_c_head() {
  printf '\n%s%s %s%s\n' "${C_BOLD}${C_BLUE}" "${G_ARROW}" "$*" "${C_RESET}"
}

# --- disk usage helper ------------------------------------------------------
_aac_du() {
  [[ -e "$1" ]] && du -sh "$1" 2>/dev/null | awk '{print $1}' || printf '%s' "-"
}

# ============================================================================
# Target definitions — one function per agent.
# Sets _AAC_LABEL (display name) and _AAC_TARGETS (array of paths).
# Paths evaluated at call time so env changes after sourcing are honoured.
# Config/settings files are deliberately excluded from all target lists.
# ============================================================================

_aac_targets_claude_code() {
  _AAC_LABEL="Claude Code CLI"
  _AAC_TARGETS=(
    # Project-scoped session transcripts — the biggest space consumer
    "$HOME/.claude/projects"
    # Statsig feature-flag + analytics local cache
    "$HOME/.claude/statsig"
    # IDE extension handshake/state files (VS Code, JetBrains)
    "$HOME/.claude/ide"
    # MCP server logs (present on some installs)
    "$HOME/.claude/mcp-logs"
    # General log files directory
    "$HOME/.claude/logs"
    # TodoWrite tool cache
    "$HOME/.claude/todos"
  )
}

_aac_targets_claude_desktop() {
  _AAC_LABEL="Claude Desktop"
  local base="$HOME/Library/Application Support/Claude"
  _AAC_TARGETS=(
    # Electron GPU shader and V8 bytecode caches
    "${base}/GPUCache"
    "${base}/Code Cache"
    "${base}/DawnCache"
    "${base}/blob_storage"
    "${base}/cache"
    # Chromium-embedded renderer logs
    "${base}/logs"
    # Auto-updater leftovers
    "${base}/claude_app_updater"
    # macOS-level caches and logs (separate locations from app support)
    "$HOME/Library/Caches/Claude"
    "$HOME/Library/Logs/Claude"
  )
}

_aac_targets_codex_cli() {
  _AAC_LABEL="Codex CLI"
  local xdg_cache="${XDG_CACHE_HOME:-$HOME/.cache}"
  local xdg_state="${XDG_STATE_HOME:-$HOME/.local/state}"
  local xdg_data="${XDG_DATA_HOME:-$HOME/.local/share}"
  _AAC_TARGETS=(
    # Dead session transcripts — prime SSD killer
    "$HOME/.codex/sessions"
    "$HOME/.codex/logs"
    "$HOME/.codex/logs_2.sqlite"
    "$HOME/.codex/logs_2.sqlite-wal"
    "$HOME/.codex/logs_2.sqlite-shm"
    # XDG paths used on some installs and on Linux
    "${xdg_cache}/codex"
    "${xdg_state}/codex"
    "${xdg_data}/codex/sessions"
    "${xdg_data}/codex/logs"
    # Sandbox dirs created per-run (may land in /tmp)
    "/tmp/codex-sandbox"
    "/tmp/codex"
  )
}

_aac_targets_codex_desktop() {
  _AAC_LABEL="Codex Desktop"
  local base="$HOME/Library/Application Support/Codex"
  _AAC_TARGETS=(
    # Electron caches (same structure as Claude Desktop — both are Electron)
    "${base}/GPUCache"
    "${base}/Code Cache"
    "${base}/DawnCache"
    "${base}/blob_storage"
    "${base}/cache"
    "${base}/logs"
    # macOS-level caches — bundle ID varies, cover common variants
    "$HOME/Library/Caches/Codex"
    "$HOME/Library/Caches/com.openai.codex"
    "$HOME/Library/Logs/Codex"
  )
}

_aac_targets_pi() {
  _AAC_LABEL="Pi Coding Agent"
  local session_dir="${PI_CODING_AGENT_SESSION_DIR:-${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}/sessions}"
  _AAC_TARGETS=(
    # Session files organised by working directory — the only safe target
    "$session_dir"
  )
  # ~/.pi/agent/{AGENTS.md,SYSTEM.md,settings.json,trust.json} are config — never touched
}

_aac_targets_opencode() {
  _AAC_LABEL="OpenCode"
  local xdg_data="${XDG_DATA_HOME:-$HOME/.local/share}"
  local xdg_cache="${XDG_CACHE_HOME:-$HOME/.cache}"
  _AAC_TARGETS=(
    # Logs that accumulate indefinitely — the main offender per issue #12934
    "${xdg_data}/opencode/logs"
    "${xdg_data}/opencode/sessions"
    "${xdg_cache}/opencode"
    # macOS Application Support fallback (some builds use this instead of XDG)
    "$HOME/Library/Application Support/opencode/logs"
    "$HOME/Library/Logs/opencode"
  )
}

# --- agent registry ---------------------------------------------------------
_AAC_AGENTS=(claude-code claude-desktop codex-cli codex-desktop opencode pi)

_aac_load_targets() {
  _AAC_LABEL=""
  _AAC_TARGETS=()
  case "$1" in
    claude-code)    _aac_targets_claude_code ;;
    claude-desktop) _aac_targets_claude_desktop ;;
    codex-cli)      _aac_targets_codex_cli ;;
    codex-desktop)  _aac_targets_codex_desktop ;;
    opencode)       _aac_targets_opencode ;;
    pi)             _aac_targets_pi ;;
    *)
      _c_err "unknown agent: $1  (available: ${_AAC_AGENTS[*]})"
      return 1
      ;;
  esac
}

# ============================================================================
# Subcommands
# ============================================================================

# --- status -----------------------------------------------------------------
_aac_status() {
  printf '\n%s%s ai-sweeper status%s\n' "${C_BOLD}${C_MAGENTA}" "${G_ARROW}" "${C_RESET}"
  printf '%s─────────────────────%s\n' "${C_DIM}" "${C_RESET}"
  local agent label size p
  local existing=()
  for agent in "${_AAC_AGENTS[@]}"; do
    _aac_load_targets "$agent" || continue
    label="$_AAC_LABEL"
    existing=()
    for p in "${_AAC_TARGETS[@]}"; do
      [[ -e "$p" ]] && existing+=("$p")
    done
    if (( ${#existing[@]} > 0 )); then
      size=$(du -shc "${existing[@]}" 2>/dev/null | tail -1 | awk '{print $1}')
      printf "  ${C_BOLD}%-22s${C_RESET}  ${C_YELLOW}%s${C_RESET}\n" "$label" "$size"
    else
      printf "  ${C_BOLD}%-22s${C_RESET}  ${C_DIM}(nothing found)${C_RESET}\n" "$label"
    fi
  done
  print -r -- ""
  _c_info "Run ${C_BOLD}ai-sweeper list [AGENT]${C_RESET} to preview exact targets."
}

# --- list -------------------------------------------------------------------
_aac_list() {
  local filter="${1:-}"
  local agents_to_list
  if [[ -n "$filter" ]]; then
    agents_to_list=("$filter")
  else
    agents_to_list=("${_AAC_AGENTS[@]}")
  fi
  local agent p size found_any
  for agent in "${agents_to_list[@]}"; do
    _aac_load_targets "$agent" || return 1
    _c_head "$_AAC_LABEL"
    found_any=0
    for p in "${_AAC_TARGETS[@]}"; do
      if [[ -e "$p" ]]; then
        size=$(_aac_du "$p")
        printf "  ${C_YELLOW}%6s${C_RESET}  %s\n" "$size" "$p"
        found_any=1
      else
        printf "  ${C_DIM}%6s  %s${C_RESET}\n" "--" "$p"
      fi
    done
  done
  print -r -- ""
  if (( _AAC_DRY_RUN )); then _c_warn "dry-run mode: nothing will be deleted."; fi
  return 0
}

# --- clean one agent --------------------------------------------------------
_aac_clean_one() {
  local agent="$1"
  _aac_load_targets "$agent" || return 1
  _c_head "Cleaning $_AAC_LABEL"

  local p size
  local existing=()
  for p in "${_AAC_TARGETS[@]}"; do
    [[ -e "$p" ]] && existing+=("$p")
  done

  if (( ${#existing[@]} == 0 )); then
    _c_info "nothing to clean"
    return 0
  fi

  size=$(du -shc "${existing[@]}" 2>/dev/null | tail -1 | awk '{print $1}')
  print -r -- "  ${C_BOLD}${#existing[@]}${C_RESET} path(s) totalling ${C_YELLOW}${size}${C_RESET}:"
  for p in "${existing[@]}"; do
    printf "    %s  ${C_DIM}(%s)${C_RESET}\n" "$p" "$(_aac_du "$p")"
  done
  print -r -- ""

  if (( _AAC_DRY_RUN )); then
    _c_warn "dry-run: skipping deletion of $_AAC_LABEL."
    return 0
  fi

  printf "%s Delete? %s[y/N]%s " "${C_YELLOW}${G_ASK}${C_RESET}" "${C_DIM}" "${C_RESET}"
  local reply
  read -r reply
  case "$reply" in
    y|Y|yes|YES)
      for p in "${existing[@]}"; do
        if rm -rf "$p" 2>/dev/null; then
          _c_ok "removed $p"
        else
          _c_err "failed to remove $p"
        fi
      done
      ;;
    *)
      _c_info "Aborted."
      return 1
      ;;
  esac
}

# --- codex archived sessions ------------------------------------------------
# Parses ~/.codex/archived_sessions/*.jsonl, extracts the cwd recorded in each
# session, and removes the corresponding project folder before deleting the
# JSONL. Folder removal is gated by two safety rules:
#   1. No *active* (non-archived) session may reference the same cwd.
#   2. The cwd must live under $HOME/Documents/Codex (throwaway chat scratch
#      dirs only — never an arbitrary path or a real git repo).
# The archived JSONL itself is always deleted regardless of the folder decision.

# Populate the global _AAC_ACTIVE_CWDS map from live Codex sessions.
# Called directly (not via $()) so the global survives.
_aac_codex_active_cwds() {
  typeset -gA _AAC_ACTIVE_CWDS=()
  local dirs=("$HOME/.codex/sessions"
              "${XDG_DATA_HOME:-$HOME/.local/share}/codex/sessions")
  local d f cwd
  for d in "${dirs[@]}"; do
    [[ -d "$d" ]] || continue
    for f in "$d"/**/*.jsonl(N); do
      cwd=$(jq -r 'select(.type == "session_meta") | .payload.cwd' "$f" 2>/dev/null | head -1)
      [[ -n "$cwd" ]] && _AAC_ACTIVE_CWDS[$cwd]=1
    done
  done
}

# Classify a candidate cwd for folder removal.
# Echoes one of: remove | skip-active | skip-path | skip-missing | no-cwd.
# Reads _AAC_ACTIVE_CWDS (inherited by the $() subshell as a read-only view).
_aac_codex_classify_cwd() {
  local cwd="$1"
  local codex_root="$HOME/Documents/Codex"
  if [[ -z "$cwd" ]]; then
    echo "no-cwd"; return
  fi
  if (( ${+_AAC_ACTIVE_CWDS[$cwd]} )); then
    echo "skip-active"; return
  fi
  # Resolve symlinks on both sides so the prefix check is robust.
  local resolved="${cwd:A}" root_resolved="${codex_root:A}"
  if [[ "$resolved" != "$root_resolved"/* ]]; then
    echo "skip-path"; return
  fi
  if [[ ! -d "$cwd" ]]; then
    echo "skip-missing"; return
  fi
  echo "remove"
}

_aac_clean_codex_archived() {
  command -v jq >/dev/null 2>&1 || {
    _c_err "${C_BOLD}jq${C_RESET} is required for archived session parsing but not found in PATH."
    return 1
  }

  local archived_dir="$HOME/.codex/archived_sessions"
  [[ -d "$archived_dir" ]] || return 0

  _c_head "Codex — archived sessions"

  local f cwd action reason
  local files=()
  for f in "$archived_dir"/*.jsonl(N); do
    files+=("$f")
  done

  if (( ${#files[@]} == 0 )); then
    _c_info "no archived sessions found"
    return 0
  fi

  # Rule 1 — scan active sessions so we never rm a folder still in use.
  _c_info "scanning active sessions for in-use cwds…"
  _aac_codex_active_cwds

  print -r -- "  ${C_BOLD}${#files[@]}${C_RESET} archived session(s):"
  for f in "${files[@]}"; do
    cwd=$(jq -r 'select(.type == "session_meta") | .payload.cwd' "$f" 2>/dev/null | head -1)
    action=$(_aac_codex_classify_cwd "$cwd")
    case "$action" in
      remove)
        printf "    ${C_YELLOW}%s${C_RESET}  ${C_DIM}(%s) → project dir will be removed${C_RESET}\n" \
          "$cwd" "$(_aac_du "$cwd")"
        ;;
      skip-active)  reason="referenced by an active session" ;;
      skip-path)    reason="outside \$HOME/Documents/Codex" ;;
      skip-missing) reason="folder not found" ;;
      no-cwd)
        printf "    ${C_DIM}%s  (no cwd in session)${C_RESET}\n" "$f"
        ;;
    esac
    if [[ "$action" == skip-* ]]; then
      printf "    ${C_DIM}%s  (%s — folder kept)${C_RESET}\n" "$cwd" "$reason"
    fi
    printf "    ${C_DIM}  %s → jsonl will be deleted${C_RESET}\n" "$f"
  done
  print -r -- ""

  if (( _AAC_DRY_RUN )); then
    _c_warn "dry-run: skipping deletion."
    return 0
  fi

  printf "%s Delete (folders under \$HOME/Documents/Codex only) + session files? %s[y/N]%s " \
    "${C_YELLOW}${G_ASK}${C_RESET}" "${C_DIM}" "${C_RESET}"
  local reply
  read -r reply
  case "$reply" in
    y|Y|yes|YES) ;;
    *) _c_info "Aborted."; return 1 ;;
  esac

  for f in "${files[@]}"; do
    cwd=$(jq -r 'select(.type == "session_meta") | .payload.cwd' "$f" 2>/dev/null | head -1)
    action=$(_aac_codex_classify_cwd "$cwd")
    if [[ "$action" == "remove" ]]; then
      if rm -rf "$cwd" 2>/dev/null; then
        _c_ok "removed project $cwd"
      else
        _c_err "failed to remove $cwd"
      fi
    fi
    if rm -f "$f" 2>/dev/null; then
      _c_ok "deleted $f"
    else
      _c_err "failed to delete $f"
    fi
  done
  return 0
}

# --- clean ------------------------------------------------------------------
_aac_clean() {
  local target="${1:-}"

  # No agent named → clean every agent in turn.
  if [[ -z "$target" ]]; then
    local agent
    for agent in "${_AAC_AGENTS[@]}"; do
      _aac_clean_one "$agent"
      [[ "$agent" == "codex-desktop" ]] && _aac_clean_codex_archived
    done
    print -r -- ""
    _c_ok "all done"
    return 0
  fi

  # Otherwise validate against the known agent list.
  local valid=0 a
  for a in "${_AAC_AGENTS[@]}"; do
    [[ "$a" == "$target" ]] && { valid=1; break; }
  done
  if (( ! valid )); then
    _c_err "unknown agent: $target  (available: ${_AAC_AGENTS[*]})"
    return 1
  fi

  _aac_clean_one "$target"
  [[ "$target" == "codex-desktop" ]] && _aac_clean_codex_archived
}

# --- help -------------------------------------------------------------------
_aac_help() {
  local self_path="${_AAC_SELF/#$HOME/~}"
  cat <<USAGE
${C_BOLD}${C_MAGENTA}ai-sweeper${C_RESET} ${C_DIM}— clear AI agent caches, logs, and dead sessions${C_RESET}

${C_BOLD}Usage:${C_RESET}
  ${C_CYAN}ai-sweeper status${C_RESET}              disk usage per agent
  ${C_CYAN}ai-sweeper list${C_RESET} ${C_DIM}[AGENT]${C_RESET}        preview targets (all agents if omitted)
  ${C_CYAN}ai-sweeper clean${C_RESET} ${C_DIM}[AGENT]${C_RESET}       delete one agent's junk (all agents if omitted)

${C_BOLD}Flags:${C_RESET}
  ${C_DIM}--dry-run${C_RESET}                      preview only, delete nothing

${C_BOLD}Agents:${C_RESET}
  ${C_CYAN}claude-code${C_RESET}      Claude Code CLI  (~/.claude/projects, statsig, ide, logs)
  ${C_CYAN}claude-desktop${C_RESET}   Claude Desktop   (~/Library/Application Support/Claude/ + Caches/)
  ${C_CYAN}codex-cli${C_RESET}        Codex CLI        (~/.codex/sessions, XDG cache/state, /tmp/codex*)
  ${C_CYAN}codex-desktop${C_RESET}    Codex Desktop    (~/Library/Application Support/Codex/ + archived/)
  ${C_CYAN}opencode${C_RESET}         OpenCode         (~/.local/share/opencode/logs, XDG cache)
  ${C_CYAN}pi${C_RESET}               Pi Coding Agent  (~/.pi/agent/sessions/)

${C_BOLD}Examples:${C_RESET}
  ai-sweeper status
  ai-sweeper list codex-cli
  ai-sweeper --dry-run clean
  ai-sweeper clean codex-desktop

${C_DIM}Config files (settings.json, .codex/config, etc.) are never touched.${C_RESET}

${C_BOLD}In ~/.zshrc:${C_RESET}
  ${C_DIM}source ${self_path}${C_RESET}
USAGE
}

# --- dispatcher -------------------------------------------------------------
ai-sweeper() {
  _aac_init_colors
  _AAC_DRY_RUN=0

  local args=() a
  for a in "$@"; do
    case "$a" in
      --dry-run) _AAC_DRY_RUN=1 ;;
      *) args+=("$a") ;;
    esac
  done

  local cmd="${args[1]:-}"
  local rest=("${args[@]:1}")

  case "$cmd" in
    status)         _aac_status ;;
    list)           _aac_list "${rest[1]:-}" ;;
    clean)          _aac_clean "${rest[1]:-}" ;;
    -h|--help|"")   _aac_help ;;
    *)
      _c_err "unknown command: $cmd"
      _aac_help >&2
      return 2
      ;;
  esac
}
