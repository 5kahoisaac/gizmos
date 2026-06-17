#!/bin/zsh
# ============================================================================
# killport — kill processes (and optionally containers) listening on ports
# ============================================================================
#
# A shell-function reimplementation of jkfran/killport (the Rust CLI), covering
# the practical core: multiple ports, signal control, dry-run, no-fail, and
# matching exit codes. Container support is best-effort via Docker.
#
# INSTALL (add to ~/.zshrc):
#   source ~/path/to/killport.sh
#
# USAGE:
#   killport [OPTIONS] <port>...
#
# OPTIONS:
#   -s, --signal <SIG>   signal to send (default: TERM). e.g. KILL, INT, HUP
#   -m, --mode <MODE>    auto (default) | process | container
#       --dry-run        show what would be killed, kill nothing
#       --no-fail        exit 0 even when nothing is found (default exit 2)
#   -h, --help           this help
#
# EXIT CODES:
#   0  target(s) found and killed (or --no-fail)
#   1  error (bad input, missing tool, kill failed)
#   2  nothing found on the given port(s)
#
# EXAMPLES:
#   killport 8080
#   killport 3000 8080 9090
#   killport -s KILL 8080
#   killport --dry-run 8080
#   killport --mode container 5432
# ============================================================================

function killport() {
  emulate -L zsh
  setopt local_options

  # --- colours (TTY + NO_COLOR aware; glyphs degrade to ASCII) -------------
  local C_RESET C_BOLD C_DIM C_RED C_GREEN C_YELLOW C_CYAN
  local G_OK G_ERR G_WARN G_DRY G_BOX
  if [[ -t 1 && -z "$NO_COLOR" ]]; then
    C_RESET=$'\e[0m'; C_BOLD=$'\e[1m'; C_DIM=$'\e[2m'
    C_RED=$'\e[31m'; C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'; C_CYAN=$'\e[36m'
    G_OK="✓"; G_ERR="✗"; G_WARN="!"; G_DRY="◦"; G_BOX="▸"
  else
    C_RESET=""; C_BOLD=""; C_DIM=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_CYAN=""
    G_OK="[ok]"; G_ERR="[x]"; G_WARN="[!]"; G_DRY="[-]"; G_BOX="*"
  fi

  local _emit_err
  _emit_err() { print -r -- "${C_RED}${G_ERR}${C_RESET} $*" >&2; }

  # --- help ----------------------------------------------------------------
  _kp_help() {
    print -r -- "${C_BOLD}${C_CYAN}killport${C_RESET} ${C_DIM}— kill processes/containers on ports${C_RESET}"
    print -r -- ""
    print -r -- "${C_BOLD}Usage:${C_RESET} killport [options] <port>..."
    print -r -- ""
    print -r -- "${C_BOLD}Options:${C_RESET}"
    print -r -- "  ${C_CYAN}-s, --signal <SIG>${C_RESET}  signal to send ${C_DIM}(default: TERM)${C_RESET}"
    print -r -- "  ${C_CYAN}-m, --mode <MODE>${C_RESET}   auto ${C_DIM}(default)${C_RESET} | process | container"
    print -r -- "  ${C_CYAN}    --dry-run${C_RESET}       preview, kill nothing"
    print -r -- "  ${C_CYAN}    --no-fail${C_RESET}       exit 0 even if nothing found"
    print -r -- "  ${C_CYAN}-h, --help${C_RESET}          this help"
    print -r -- ""
    print -r -- "${C_BOLD}Examples:${C_RESET}"
    print -r -- "  ${C_DIM}killport 8080${C_RESET}"
    print -r -- "  ${C_DIM}killport 3000 8080 9090${C_RESET}"
    print -r -- "  ${C_DIM}killport -s KILL 8080${C_RESET}"
    print -r -- "  ${C_DIM}killport --dry-run 5432${C_RESET}"
  }

  # --- parse args ----------------------------------------------------------
  local signal="TERM" mode="auto" dry=0 no_fail=0
  local -a ports
  while (($#)); do
    case "$1" in
      -h|--help) _kp_help; return 0 ;;
      -s|--signal)
        [[ $# -ge 2 ]] || { _emit_err "--signal needs a value"; return 1; }
        signal="${2#SIG}"; shift 2 ;;
      --signal=*) signal="${1#*=}"; signal="${signal#SIG}"; shift ;;
      -m|--mode)
        [[ $# -ge 2 ]] || { _emit_err "--mode needs a value"; return 1; }
        mode="$2"; shift 2 ;;
      --mode=*) mode="${1#*=}"; shift ;;
      --dry-run) dry=1; shift ;;
      --no-fail) no_fail=1; shift ;;
      --) shift; while (($#)); do ports+=("$1"); shift; done ;;
      -*) _emit_err "unknown option: $1"; return 1 ;;
      *) ports+=("$1"); shift ;;
    esac
  done

  if [[ ${#ports[@]} -eq 0 ]]; then
    _emit_err "usage: ${C_BOLD}killport <port>...${C_RESET}"
    return 1
  fi
  case "$mode" in
    auto|process|container) ;;
    *) _emit_err "invalid mode: $mode (use auto|process|container)"; return 1 ;;
  esac

  # uppercase signal for display
  local signal_disp="${(U)signal}"

  # --- helpers: discovery + actions ----------------------------------------
  # process PIDs listening on a tcp port
  _kp_pids() { lsof -ti tcp:"$1" 2>/dev/null; }
  _kp_pname() {
    local n; n="$(ps -p "$1" -o comm= 2>/dev/null | sed 's#^.*/##' | tr -d ' ')"
    [[ -z "$n" ]] && n="?"
    print -r -- "$n"
  }
  # docker container ids publishing a host port
  _kp_containers() {
    command -v docker >/dev/null 2>&1 || return 0
    docker ps --format '{{.ID}} {{.Names}} {{.Ports}}' 2>/dev/null \
      | awk -v p=":$1->" '$0 ~ p {print $1" "$2}'
  }

  # require lsof only if we might touch processes
  if [[ "$mode" != container ]] && ! command -v lsof >/dev/null 2>&1; then
    _emit_err "${C_BOLD}lsof${C_RESET} is required but not found in PATH."
    return 1
  fi

  local total_found=0 total_killed=0 had_error=0 port
  # declare loop-locals once up front; re-using `local` inside the for-loop
  # makes zsh echo the variable on each iteration.
  local cline cid cname pid name found_here

  for port in "${ports[@]}"; do
    if [[ "$port" != <-> ]]; then
      _emit_err "not a valid port: ${C_BOLD}$port${C_RESET}"
      had_error=1
      continue
    fi

    print -r -- "${C_BOLD}${C_CYAN}${G_BOX} port $port${C_RESET}"

    found_here=0

    # ---- containers (auto or container mode) ----
    if [[ "$mode" == container || "$mode" == auto ]]; then
      while IFS= read -r cline; do
        [[ -z "$cline" ]] && continue
        cid="${cline%% *}"; cname="${cline#* }"
        found_here=1; total_found=$((total_found + 1))
        if [[ "$dry" -eq 1 ]]; then
          print -r -- "  ${C_DIM}${G_DRY}${C_RESET} would stop container ${C_BOLD}${C_CYAN}$cname${C_RESET} ${C_DIM}($cid)${C_RESET}"
        elif docker stop "$cid" >/dev/null 2>&1; then
          print -r -- "  ${C_GREEN}${G_OK}${C_RESET} stopped container ${C_BOLD}${C_CYAN}$cname${C_RESET} ${C_DIM}($cid)${C_RESET}"
          total_killed=$((total_killed + 1))
        else
          _emit_err "  could not stop container $cname ($cid)"
          had_error=1
        fi
      done < <(_kp_containers "$port")
    fi

    # ---- processes (auto when no container found, or process mode) ----
    if [[ "$mode" == process || ( "$mode" == auto && "$found_here" -eq 0 ) ]]; then
      while IFS= read -r pid; do
        [[ -z "$pid" ]] && continue
        name="$(_kp_pname "$pid")"
        found_here=1; total_found=$((total_found + 1))
        if [[ "$dry" -eq 1 ]]; then
          print -r -- "  ${C_DIM}${G_DRY}${C_RESET} would kill ${C_BOLD}${C_CYAN}$name${C_RESET} ${C_DIM}(pid $pid, SIG$signal_disp)${C_RESET}"
        elif kill -"$signal" "$pid" 2>/dev/null; then
          print -r -- "  ${C_GREEN}${G_OK}${C_RESET} killed ${C_BOLD}${C_CYAN}$name${C_RESET} ${C_DIM}(pid $pid, SIG$signal_disp)${C_RESET}"
          total_killed=$((total_killed + 1))
        else
          _emit_err "  could not kill $name (pid $pid)"
          had_error=1
        fi
      done < <(_kp_pids "$port")
    fi

    if [[ "$found_here" -eq 0 ]]; then
      print -r -- "  ${C_YELLOW}${G_WARN}${C_RESET} nothing found on port ${C_BOLD}$port${C_RESET}."
    fi
  done

  # --- final report + exit code --------------------------------------------
  if [[ "$had_error" -eq 1 ]]; then
    return 1
  fi
  if [[ "$total_found" -eq 0 ]]; then
    if [[ "$no_fail" -eq 1 ]]; then
      return 0
    fi
    return 2
  fi
  if [[ "$dry" -eq 1 ]]; then
    print -r -- "${C_DIM}${G_DRY}${C_RESET} dry run — ${C_BOLD}$total_found${C_RESET} target(s) would be killed."
  else
    print -r -- "${C_GREEN}${G_OK}${C_RESET} done — killed ${C_BOLD}$total_killed${C_RESET} of ${C_BOLD}$total_found${C_RESET} target(s)."
  fi
  return 0
}