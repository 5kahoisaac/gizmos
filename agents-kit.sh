#!/usr/bin/env bash

# Example: DEFAULT_ECC_REPO="$HOME/src/everything-claude-code"
# DEFAULT_ECC_REPO="$HOME/Documents/ECC"

# Example: COMMAND_NAME="ai"
COMMAND_NAME="agents-kit"

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
    G_OK="✓"; G_FAIL="✗"; G_SKIP="•"; G_CMD="›"; G_PATH="📁"; G_ARROW="▸"
  else
    C_RESET=""; C_BOLD=""; C_DIM=""
    C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_MAGENTA=""; C_CYAN=""
    G_OK=""; G_FAIL=""; G_SKIP=""; G_CMD=""; G_PATH=""; G_ARROW="*"
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
  ${C_CYAN}${COMMAND_NAME} update${C_RESET}
  ${C_CYAN}${COMMAND_NAME} update --ecc-repo PATH${C_RESET}

${C_BOLD}Updates:${C_RESET}
  ${C_DIM}${G_ARROW}${C_RESET} Claude Code
  ${C_DIM}${G_ARROW}${C_RESET} OpenCode
  ${C_DIM}${G_ARROW}${C_RESET} OpenAI Codex CLI
  ${C_DIM}${G_ARROW}${C_RESET} Pi Coding Agent
  ${C_DIM}${G_ARROW}${C_RESET} LazyCodex
  ${C_DIM}${G_ARROW}${C_RESET} ECC repo (only if a repo path is set): git fetch, git reset --hard origin/main, ./install.sh --profile full

${C_BOLD}Options:${C_RESET}
  ${C_CYAN}--ecc-repo PATH${C_RESET}   Set the ECC repo path. Can also use ECC_REPO=PATH or DEFAULT_ECC_REPO.
  ${C_CYAN}--yes${C_RESET}             Accepted for old muscle memory; not required.
  ${C_CYAN}--skip-ecc${C_RESET}        Update tools only; skip ECC repo reset/install.
  ${C_CYAN}-h, --help${C_RESET}        Show this help.

${C_BOLD}Notes:${C_RESET}
  ${C_DIM}If no ECC repo path is set, the ECC step is skipped automatically.${C_RESET}
  ${C_YELLOW}The ECC reset discards all uncommitted and local-only tracked changes.${C_RESET}

${C_BOLD}In ~/.zshrc:${C_RESET}
  ${C_DIM}COMMAND_NAME="${COMMAND_NAME}"${C_RESET}
  ${C_DIM}source ~/agents-kit.sh${C_RESET}
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
  local output_file status _arg

  # Echo the command, dim and %q-quoted, behind a CMD tag.
  printf '  %s%-5s%s' "${C_CYAN}" "${G_CMD} CMD" "${C_RESET}"
  for _arg in "$@"; do
    printf ' %s%q%s' "${C_DIM}" "$_arg" "${C_RESET}"
  done
  printf '\n'

  output_file="$(mktemp "${TMPDIR:-/tmp}/agents-kit.XXXXXX")" || return 1

  if "$@" >"$output_file" 2>&1; then
    if [[ -s "$output_file" ]]; then
      print_output "$output_file"
    fi
    rm -f "$output_file"
    return 0
  else
    status=$?
  fi

  if [[ -s "$output_file" ]]; then
    print_output "$output_file" >&2
  fi
  rm -f "$output_file"
  fail "command failed with exit code $status"
  return "$status"
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

  if has_brew_cask codex; then
    run brew upgrade --cask codex
  elif has_global_npm_package @openai/codex; then
    run npm install -g @openai/codex@latest
  elif need_cmd curl; then
    run sh -c 'curl -fsSL https://chatgpt.com/codex/install.sh | CODEX_NON_INTERACTIVE=1 sh'
  else
    warn "curl not found, so the Codex standalone installer cannot run."
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

  need_cmd pi && run pi --version || true
  ok "Pi Coding Agent update finished"
}

update_lazycodex() {
  log "LazyCodex"

  if ! need_cmd npx; then
    warn "npx not found. Install Node.js/npm first, then run: npx lazycodex-ai install"
    return 0
  fi

  run npx --yes lazycodex-ai install --no-tui --codex-autonomous
  run npx --yes lazycodex-ai doctor
  ok "LazyCodex update finished"
}

update_ecc_repo() {
  log "ECC repo"

  # No path configured -> nothing to do; skip cleanly.
  if [[ -z "${ECC_REPO:-}" ]]; then
    warn "No ECC repo path set (DEFAULT_ECC_REPO / ECC_REPO / --ecc-repo). Skipping."
    return 0
  fi

  if [[ ! -d "$ECC_REPO/.git" ]]; then
    fail "not a git repo: $ECC_REPO"
    exit 2
  fi

  printf '  %s%-5s%s %s%s%s\n' "${C_MAGENTA}" "${G_PATH} PATH" "${C_RESET}" "${C_DIM}" "$ECC_REPO" "${C_RESET}"
  run git -C "$ECC_REPO" fetch origin main
  run git -C "$ECC_REPO" reset --hard origin/main

  if [[ -x "$ECC_REPO/install" ]]; then
    (cd "$ECC_REPO" && run ./install)
  elif [[ -f "$ECC_REPO/install.sh" ]]; then
    (cd "$ECC_REPO" && run bash ./install.sh --profile full)
  else
    fail "install script is missing: $ECC_REPO/install or $ECC_REPO/install.sh"
    exit 2
  fi

  ok "ECC repo update finished"
}

_ai_tools_update() (
  set -euo pipefail

  ECC_REPO="${ECC_REPO:-${DEFAULT_ECC_REPO:-}}"
  SKIP_ECC=0

  while (($#)); do
    case "$1" in
      --ecc-repo)
        [[ $# -ge 2 ]] || {
          fail "--ecc-repo needs a path"
          exit 2
        }
        ECC_REPO="$2"
        shift 2
        ;;
      --yes)
        shift
        ;;
      --skip-ecc)
        SKIP_ECC=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        fail "unknown argument: $1"
        usage >&2
        exit 2
        ;;
    esac
  done

  printf '\n%s%s agents-kit update%s\n' "${C_BOLD}${C_MAGENTA}" "${G_ARROW}" "${C_RESET}"
  printf '%s─────────────────────%s\n' "${C_DIM}" "${C_RESET}"

  update_claude
  update_opencode
  update_codex
  update_pi
  update_lazycodex

  if [[ "$SKIP_ECC" == "1" ]]; then
    log "ECC repo"
    warn "Skipped by --skip-ecc"
  elif [[ -z "${ECC_REPO:-}" ]]; then
    log "ECC repo"
    warn "No ECC repo path set. Skipping (set DEFAULT_ECC_REPO, ECC_REPO, or pass --ecc-repo)."
  else
    update_ecc_repo
  fi

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