#!/usr/bin/env bash

# Example: COMMAND_NAME="ai"
COMMAND_NAME="ai-updater"

OUTPUT_HEAD_LINES="${OUTPUT_HEAD_LINES:-20}"
OUTPUT_TAIL_LINES="${OUTPUT_TAIL_LINES:-20}"

# ---------------------------------------------------------------------------
# Colour palette. Enabled only when stdout is a TTY and NO_COLOR is unset, so
# piping/redirecting stays clean. Glyphs degrade to ASCII when colour is off.
# ---------------------------------------------------------------------------
_ak_init_colors() {
  if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    C_RESET=$'\e[0m'; C_BOLD=$'\e[1m'; C_DIM=$'\e[2m'
    C_RED=$'\e[31m'; C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'
    C_BLUE=$'\e[34m'; C_MAGENTA=$'\e[35m'; C_CYAN=$'\e[36m'
    G_OK="✓"; G_FAIL="✗"; G_SKIP="•"; G_CMD="›"; G_ARROW="▸"
  else
    C_RESET=""; C_BOLD=""; C_DIM=""
    C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_MAGENTA=""; C_CYAN=""
    G_OK=""; G_FAIL=""; G_SKIP=""; G_CMD=""; G_ARROW="*"
  fi
}
_ak_init_colors

# ---------------------------------------------------------------------------
# Standardized output helpers. Consistent 8-col tag column, then the message.
# ---------------------------------------------------------------------------

usage() {
  cat <<USAGE
${C_BOLD}${C_MAGENTA}${COMMAND_NAME}${C_RESET} ${C_DIM}— update your AI coding tools${C_RESET}

${C_BOLD}Usage:${C_RESET}
  ${C_CYAN}${COMMAND_NAME} update [TOOL …]${C_RESET}

${C_BOLD}Tools:${C_RESET}
  ${C_CYAN}claude${C_RESET}           Claude Code
  ${C_CYAN}claude-swap${C_RESET}      claude-swap (multi-account switcher, binary: cswap)
  ${C_CYAN}opencode${C_RESET}         OpenCode
  ${C_CYAN}codex${C_RESET}            OpenAI Codex CLI
  ${C_CYAN}pi${C_RESET}               Pi Coding Agent (CLI + extensions)

${C_BOLD}Options:${C_RESET}
  ${C_CYAN}-h, --help${C_RESET}        Show this help.

${C_BOLD}Notes:${C_RESET}
  ${C_DIM}Omitting TOOL (or passing "all") updates every tool.${C_RESET}

${C_BOLD}In ~/.zshrc:${C_RESET}
  ${C_DIM}source ~/ai-updater.sh${C_RESET}
USAGE
}

# Section header — a colored banner introducing each tool.
log() {
  printf '\n%s%s %s%s\n' "${C_BOLD}${C_BLUE}" "${G_ARROW}" "$*" "${C_RESET}"
}

warn() {
  printf '  %s%-5s%s %s\n' "${C_YELLOW}" "${G_SKIP} SKIP" "${C_RESET}" "$*" >&2
}

ok() {
  printf '  %s%-5s%s %s\n' "${C_GREEN}" "${G_OK} OK" "${C_RESET}" "$*"
}

fail() {
  printf '  %s%-5s%s %s\n' "${C_RED}" "${G_FAIL} FAIL" "${C_RESET}" "$*" >&2
}

print_output() {
  local output_file line_count max_lines omitted

  output_file="$1"
  line_count="$(wc -l <"$output_file" | tr -d ' ')"
  max_lines=$((OUTPUT_HEAD_LINES + OUTPUT_TAIL_LINES))

  if (( line_count <= max_lines )); then
    sed "s/^/        ${C_DIM}/; s/\$/${C_RESET}/" "$output_file"
    return 0
  fi

  head -n "$OUTPUT_HEAD_LINES" "$output_file" | sed "s/^/        ${C_DIM}/; s/\$/${C_RESET}/"
  omitted=$((line_count - max_lines))
  printf '        %s... %s lines omitted ...%s\n' "${C_DIM}" "$omitted" "${C_RESET}"
  tail -n "$OUTPUT_TAIL_LINES" "$output_file" | sed "s/^/        ${C_DIM}/; s/\$/${C_RESET}/"
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1
}

run() {
  local output_file _exit_code _arg

  # Echo the command, dim and %q-quoted, behind a CMD tag.
  printf '  %s%-5s%s' "${C_CYAN}" "${G_CMD} CMD" "${C_RESET}"
  for _arg in "$@"; do
    printf ' %s%q%s' "${C_DIM}" "$_arg" "${C_RESET}"
  done
  printf '\n'

  output_file="$(mktemp "${TMPDIR:-/tmp}/ai-updater.XXXXXX")" || return 1

  if "$@" >"$output_file" 2>&1; then
    if [[ -s "$output_file" ]]; then
      print_output "$output_file"
    fi
    rm -f "$output_file"
    return 0
  else
    _exit_code=$?
  fi

  if [[ -s "$output_file" ]]; then
    print_output "$output_file" >&2
  fi
  rm -f "$output_file"
  fail "command failed with exit code $_exit_code"
  return "$_exit_code"
}

has_global_npm_package() {
  need_cmd npm && npm ls -g --depth=0 "$1" >/dev/null 2>&1
}

has_brew_cask() {
  need_cmd brew && brew list --cask "$1" >/dev/null 2>&1
}

update_claude() {
  log "Claude Code"

  if has_brew_cask claude-code@latest; then
    run brew upgrade --cask claude-code@latest
  elif has_brew_cask claude-code; then
    run brew upgrade --cask claude-code
  elif has_global_npm_package @anthropic-ai/claude-code; then
    run npm install -g @anthropic-ai/claude-code@latest
  elif need_cmd claude; then
    run claude update
  else
    warn "Claude Code not found. Install it first, or add your install method here."
    return 0
  fi

  need_cmd claude && run claude --version || true
  ok "Claude Code update finished"
}

update_opencode() {
  log "OpenCode"

  if need_cmd opencode; then
    run opencode upgrade
  elif has_global_npm_package opencode-ai; then
    run npm install -g opencode-ai@latest
  else
    warn "OpenCode not found. Install it first, or add your install method here."
    return 0
  fi

  need_cmd opencode && run opencode --version || true
  ok "OpenCode update finished"
}

update_codex() {
  log "OpenAI Codex CLI"

  if need_cmd npm; then
    run npm install -g @openai/codex@latest
  else
    warn "npm not found. Install Node.js/npm first, then run: npm install -g @openai/codex@latest"
    return 0
  fi

  need_cmd codex && run codex --version || true
  ok "OpenAI Codex CLI update finished"
}

update_pi() {
  log "Pi Coding Agent"

  if need_cmd pi; then
    run pi update
  elif need_cmd bun; then
    run bun add -g --ignore-scripts @earendil-works/pi-coding-agent@latest
  elif need_cmd npm; then
    run npm install -g --ignore-scripts @earendil-works/pi-coding-agent@latest
  else
    warn "bun/npm not found. Install Bun, then run: bun add -g --ignore-scripts @earendil-works/pi-coding-agent@latest"
    return 0
  fi

  # Extensions live alongside the CLI and are versioned separately.
  if need_cmd pi; then
    run pi update --extensions
  fi

  need_cmd pi && run pi --version || true
  ok "Pi Coding Agent update finished"
}

update_claude_swap() {
  log "claude-swap"

  if need_cmd pipx && pipx list 2>/dev/null | grep -q claude-swap; then
    run pipx upgrade claude-swap
  elif need_cmd uv && uv tool list 2>/dev/null | grep -q claude-swap; then
    run uv tool upgrade claude-swap
  elif need_cmd cswap; then
    run cswap --upgrade
  else
    warn "claude-swap not found. Install it: uv tool install claude-swap  (or pipx install claude-swap)"
    return 0
  fi

  need_cmd cswap && run cswap --version || true
  ok "claude-swap update finished"
}

_ai_tools_update() (
  set -euo pipefail

  local -a targets=()

  while (($#)); do
    case "$1" in
      -h|--help)
        usage; exit 0 ;;
      claude|claude-swap|opencode|codex|pi)
        targets+=("$1"); shift ;;
      *)
        fail "unknown tool: $1  (available: claude claude-swap opencode codex pi)"
        usage >&2; exit 2 ;;
    esac
  done

  [[ ${#targets[@]} -eq 0 ]] && targets=(claude claude-swap opencode codex pi)

  printf '\n%s%s ai-updater update%s\n' "${C_BOLD}${C_MAGENTA}" "${G_ARROW}" "${C_RESET}"
  printf '%s─────────────────────%s\n' "${C_DIM}" "${C_RESET}"

  for _tool in "${targets[@]}"; do
    case "$_tool" in
      claude)             update_claude ;;
      claude-swap)        update_claude_swap ;;
      opencode)           update_opencode ;;
      codex)              update_codex ;;
      pi)                 update_pi ;;
    esac
  done

  log "Done"
  ok "All requested updates finished"
)

_ai_tools_dispatch() {
  case "${1:-}" in
    update)
      shift
      _ai_tools_update "$@"
      ;;
    -h|--help|"")
      usage
      ;;
    *)
      fail "unknown command: $1"
      usage >&2
      return 2
      ;;
  esac
}

_ai_tools_define_command() {
  case "$COMMAND_NAME" in
    ""|replace_me)
      return 0
      ;;
    [0-9-]*|*[!A-Za-z0-9_-]*)
      fail "invalid COMMAND_NAME: $COMMAND_NAME"
      return 2
      ;;
  esac

  eval "${COMMAND_NAME}() { _ai_tools_dispatch \"\$@\"; }"
}

_ai_tools_is_sourced() {
  if [[ -n "${ZSH_EVAL_CONTEXT:-}" ]]; then
    [[ "$ZSH_EVAL_CONTEXT" == *:file:* ]]
  elif [[ -n "${BASH_SOURCE:-}" ]]; then
    [[ "${BASH_SOURCE[0]}" != "$0" ]]
  else
    return 1
  fi
}

if _ai_tools_is_sourced; then
  _ai_tools_define_command
else
  if [[ "${1:-}" == "" ]]; then
    usage
    exit 0
  fi
  COMMAND_NAME="$1"
  shift
  _ai_tools_dispatch "$@"
fi