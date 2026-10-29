#!/bin/bash
set -Eeuo pipefail

# Paxel upload script
# ===================
#
# What this does (up to 17 steps):
#   On your machine
#     First, install or update the paxel-remote-setup agent skill in the
#     skills folder of each coding agent found (--no-skill skips it once,
#     export PAXEL_NO_SKILL=1 skips it on every upload)
#     1. Check Docker is installed and running
#     2. Sign you in (browser-based device auth)
#     3. Pull or build the Paxel Docker image
#
#   Inside the container — file bodies stay local; only aggregate metrics +
#   metadata (paths, commit numstat, session events) are uploaded
#     4. Discover projects and sessions (Claude Code, Codex CLI, Cursor)
#     5. Read your git history
#     6. Parse transcripts
#     7. Summarize each session (cloud Haiku via YC proxy)
#     8. Group git commits by session
#     9. Group sessions into multi-day work streams
#    10. Extract steering traces
#    11. Extract decision exchanges (cloud Haiku)
#    12. Redact code before upload (regex pattern redaction)
#    13. Link decisions to outcomes
#    14. Analyze code quality (L1 deterministic)
#    15. Score episodes across 5 axes (cloud Haiku)
#    16. Assemble your report
#    17. Upload redacted summaries + scores to the server
#
#   Then: opens your results in the browser
#
# Some steps are skipped when there's nothing to do (no new sessions, no
# work streams, no server to upload to). 17 is the ceiling; fewer can run.
#
# What stays on this machine:
#   File bodies (source code contents), full raw transcripts, and raw plan
#   file contents. Diffs never leave — only aggregate line counts do.
# What gets uploaded:
#   Scores, behavioral summaries, narrative outputs, redacted decision
#   records, session metadata (including file paths your agent Read/Edited/
#   Created and bash commands it ran), per-commit numstat (touched paths
#   with added/deleted line counts), git commit metadata (sha, author,
#   date, subject), aggregate velocity/LOC stats, and pipeline telemetry.
#   Transcript excerpts (including snippets of tool calls) flow to Claude
#   through the YC LLM proxy for narrative analysis — the proxy logs
#   request/response to our Postgres for anti-gaming verification. See
#   /data-handling for the field-by-field breakdown.
#
# Caches and re-runs:
#   LLM call results cache in a local Docker volume (paxel-cache-<uid>).
#   Re-running on the same repo (or after a mid-pipeline failure) typically
#   hits 95%+ cache and finishes in minutes instead of re-doing every step.
#   The container itself is --rm — nothing persists inside. Only the LLM
#   cache survives between runs.
#
# After the upload:
#   The server runs one more pass — cohort anomaly detection, cross-session
#   analysis via embeddings, narrative synthesis, and (after 3+ uploads)
#   builder profile updates. That takes ~1-5 minutes after the container
#   finishes. The results page polls automatically.
#
# Review it or ask your agent before running:
#   curl -fsSL 'https://paxel.ycombinator.com/paxel.sh' -o paxel-upload.sh && less paxel-upload.sh
#   curl -fsSL 'https://paxel.ycombinator.com/paxel.sh' | claude -p "explain what this bash script does"
#   curl -fsSL 'https://paxel.ycombinator.com/paxel.sh' | codex exec "walk me through this script"
#
# Usage:
#   upload                                        # Docker mode: analyze locally, upload scores
#   upload --project NAME                         # select project by repo name
#   upload --since 2m                             # sessions from last 2 months (recommended)
#   upload --all                                  # skip auto-detect; analyze every project
#   upload --no-repo                              # skip repo mount (transcripts only)
#   upload --no-sentry                            # disable client-side error reporting for this run
#   upload --clear-cache                          # clear project-remote cache
#   upload --verbose                              # list each session with its source (when a transcript store is found)
#   upload --no-skill                             # do not install or update the paxel-remote-setup agent skill
#   PAXEL_NO_SKILL=1 upload                       # same; export PAXEL_NO_SKILL=1 to skip it on every upload
#   upload --skill                                # first argument only: install or update only that skill, then exit (no Docker, no sign-in)
#   upload --create-store                         # first argument only: create your private transcript store, then exit (no setup, no upload)


# cloud-init runcmd and some image builds run with no HOME; `paxel setup`
# must still start there. With HOME unset, ~ expands from the passwd entry.
if [ -z "${HOME:-}" ]; then unset HOME; HOME=~; export HOME; fi

CACHE_DIR="${HOME}/.paxel/cache"
# Store commands report their own problems and setup always exits 0, so an
# unwritable HOME (a sudo that keeps the caller's HOME, HOME=/nonexistent)
# must not stop them here.
case "${1:-}" in
  skill|--skill|create-store|--create-store) ;;
  setup|push|status) mkdir -p "$CACHE_DIR" 2>/dev/null || true ;;
  *) mkdir -p "$CACHE_DIR" ;;
esac
# Owner-only on the ~/.paxel dirs is the real protection: a 0700 directory
# blocks other users on a shared host from traversing to ANY file inside
# (cache, logs, data, git_metrics.txt, the LLM cache + pending-upload stash on
# the data mount), regardless of each file's own mode. On native Linux, the
# client runs with the invoking user's uid/gid so it can traverse these dirs;
# Docker Desktop handles host bind-mount identity mapping on macOS and Windows.
chmod 700 "${HOME}/.paxel" "$CACHE_DIR" 2>/dev/null || true

cleanup_temp_dirs() {
  rm -f "${HOME}/.paxel/git_metrics.txt"
  rm -rf "${HOME}/.paxel/cache/filtered-transcripts-$$"
  rm -rf "${HOME}/.paxel/cache/cursor_extracted-$$"
  rm -rf "${HOME}/.paxel/cache/codex_extracted-$$"
  rm -rf "${HOME}/.paxel/cache/opencode_extracted-$$"
  rm -rf "${HOME}/.paxel/cache/gemini_extracted-$$"
  rm -rf "${HOME}/.paxel/cache/vscode_extracted-$$"
  rm -rf "${HOME}/.paxel/cache/filtered-codex-$$"
  rm -rf "${HOME}/.paxel/cache/store_sessions-$$"
  rm -f "${HOME}/.paxel/cache/store_sessions-$$.sources"
  if declare -F _paxel_pull_unlock >/dev/null 2>&1; then _paxel_pull_unlock; fi
  # Use the same helper the scan + bind-mount consult, so a future
  # override of _DOCKER_ALL_SIDECAR_DIR (or a relocation of the path
  # convention) stays consistent across all three call sites.
  if declare -f _docker_all_sidecar_dir >/dev/null 2>&1; then
    rm -rf "$(_docker_all_sidecar_dir)"
  fi
  [ -n "${_RMDC_LOG_FILE:-}" ] && rm -f "$_RMDC_LOG_FILE"
}
trap cleanup_temp_dirs EXIT

# ERR trap: fires only on unhandled command failures (not on explicit `exit N`
# after a user-friendly banner, and not on `|| true`-protected commands).
# Prints exit code, failing command, line number, and a function stack so the
# user has something concrete to send us. `set -E` above propagates this into
# functions and subshells.
_paxel_on_error() {
  local ec=$?
  local failed_line="${BASH_LINENO[0]:-?}"
  local failed_cmd="${BASH_COMMAND:-?}"
  {
    echo ""
    echo "────────────────────────────────────────────────────────"
    echo "Paxel upload hit an unexpected error."
    echo ""
    echo "  exit code: $ec"
    echo "  line:      $failed_line"
    echo "  command:   $failed_cmd"
    if [ "${#FUNCNAME[@]}" -gt 1 ]; then
      echo "  stack:"
      local i=0
      while [ "$i" -lt "${#FUNCNAME[@]}" ]; do
        local fn="${FUNCNAME[$i]:-main}"
        local ln="${BASH_LINENO[$i]:-?}"
        echo "    at ${fn} (line ${ln})"
        i=$((i + 1))
      done
    fi
    echo ""
    echo "Please email paxel@ycombinator.com with the above (and the"
    echo "last ~30 lines of output) so we can fix it."
    echo "────────────────────────────────────────────────────────"
  } >&2
}
trap _paxel_on_error ERR

find "${HOME}/.paxel/cache" -maxdepth 1 -name "filtered-transcripts-*" -mmin +1440 -exec rm -rf {} + 2>/dev/null || true
find "${HOME}/.paxel/cache" -maxdepth 1 -name "cursor_extracted-*" -mmin +1440 -exec rm -rf {} + 2>/dev/null || true
find "${HOME}/.paxel/cache" -maxdepth 1 -name "codex_extracted-*" -mmin +1440 -exec rm -rf {} + 2>/dev/null || true
find "${HOME}/.paxel/cache" -maxdepth 1 -name "opencode_extracted-*" -mmin +1440 -exec rm -rf {} + 2>/dev/null || true
find "${HOME}/.paxel/cache" -maxdepth 1 -name "gemini_extracted-*" -mmin +1440 -exec rm -rf {} + 2>/dev/null || true
find "${HOME}/.paxel/cache" -maxdepth 1 -name "vscode_extracted-*" -mmin +1440 -exec rm -rf {} + 2>/dev/null || true
find "${HOME}/.paxel/cache" -maxdepth 1 -name "filtered-codex-*" -mmin +1440 -exec rm -rf {} + 2>/dev/null || true
find "${HOME}/.paxel/cache" -maxdepth 1 -name "docker-all-sidecar-*" -mmin +1440 -exec rm -rf {} + 2>/dev/null || true
find "${HOME}/.paxel/cache" -maxdepth 1 -name "store_sessions-*" -mmin +1440 -exec rm -rf {} + 2>/dev/null || true
# Sweep stale run logs (timestamped replay-*.log + per-run extract logs) after
# 14 days — they persist for debugging but shouldn't accumulate forever.
find "${HOME}/.paxel/logs" -maxdepth 1 -type f -mtime +14 -exec rm -f {} + 2>/dev/null || true
CACHE_FILE="$CACHE_DIR/transcripts.tar.gz"

UPLOAD_URL="${UPLOAD_URL:-https://paxel.ycombinator.com/upload}"
CLAUDE_DIR="${TRANSCRIPT_DIR:-${CLAUDE_DIR:-$HOME/.claude/projects}}"
CODEX_DIR="${CODEX_DIR:-$HOME/.codex/sessions}"
# >>> paxel-cursor-os-paths (also exercised by dev_upload_spec.bats)
case "$(uname -s)" in
  Darwin)
    CURSOR_DIR="${CURSOR_DIR:-$HOME/Library/Application Support/Cursor/User/workspaceStorage}"
    CURSOR_GLOBAL_DB="${CURSOR_GLOBAL_DB:-$HOME/Library/Application Support/Cursor/User/globalStorage/state.vscdb}"
    ;;
  MINGW*|MSYS*|CYGWIN*)
    # Windows (Git Bash / MSYS2 / Cygwin). Cursor lives under %APPDATA%\Cursor, NOT
    # ~/.config — without this branch every Cursor workspace is skipped on Windows
    # (PAXEL: "28 Cursor workspaces completely skipped", report 2026-06-06). $APPDATA
    # is a native path with backslashes (C:\Users\..\AppData\Roaming); normalize to
    # forward slashes so the MSYS find/sqlite3 read it, and fall back to the
    # HOME-relative location if APPDATA is unset.
    _paxel_appdata="${APPDATA:-$HOME/AppData/Roaming}"
    _paxel_appdata="${_paxel_appdata//\\//}"
    CURSOR_DIR="${CURSOR_DIR:-$_paxel_appdata/Cursor/User/workspaceStorage}"
    CURSOR_GLOBAL_DB="${CURSOR_GLOBAL_DB:-$_paxel_appdata/Cursor/User/globalStorage/state.vscdb}"
    ;;
  *)
    CURSOR_DIR="${CURSOR_DIR:-$HOME/.config/Cursor/User/workspaceStorage}"
    CURSOR_GLOBAL_DB="${CURSOR_GLOBAL_DB:-$HOME/.config/Cursor/User/globalStorage/state.vscdb}"
    # WSL: a user who runs Cursor on the WINDOWS side keeps its data under the mounted
    # Windows %APPDATA% (/mnt/c/Users/<u>/AppData/Roaming/Cursor), NOT the Linux
    # ~/.config — so the default above finds nothing (PAXEL: sutaniese, /mnt/c/dev).
    # Only repoint when the default dir is still in play (no explicit CURSOR_DIR env)
    # AND it has no USABLE data (no state.vscdb under it and no global DB — an empty
    # ~/.config/Cursor from a one-off Linux install must not block the WSL path, per
    # review) AND we're under WSL AND the Windows side has data. Every probe
    # lives inside the `if` condition or is guarded — this block runs at top level
    # under `set -Eeuo pipefail` with the ERR trap armed, so a bare non-zero (e.g.
    # grep finding no "microsoft", the case for every non-WSL Linux user) must never
    # escape. (cmd.exe %APPDATA% would pin the exact current Windows user but adds
    # interop failure modes; the glob is robust for the common single-user box.)
    if [ "$CURSOR_DIR" = "$HOME/.config/Cursor/User/workspaceStorage" ] \
       && [ -z "$(find "$CURSOR_DIR" -maxdepth 2 -name state.vscdb -print -quit 2>/dev/null || true)" ] \
       && [ ! -f "$CURSOR_GLOBAL_DB" ] \
       && grep -qi microsoft /proc/version 2>/dev/null; then
      for _paxel_win_cursor in /mnt/c/Users/*/AppData/Roaming/Cursor/User; do
        [ -d "$_paxel_win_cursor/workspaceStorage" ] || continue
        CURSOR_DIR="$_paxel_win_cursor/workspaceStorage"
        CURSOR_GLOBAL_DB="$_paxel_win_cursor/globalStorage/state.vscdb"
        # The agent-transcripts tree lives under the Windows user profile
        # (~/.cursor/projects), a sibling of AppData — repoint it alongside the
        # DB paths so a WSL user's current-Cursor sessions are found too.
        if [ -z "${CURSOR_PROJECTS_DIR:-}" ] && [ ! -d "$HOME/.cursor/projects" ] \
           && [ -d "${_paxel_win_cursor%/AppData/*}/.cursor/projects" ]; then
          CURSOR_PROJECTS_DIR="${_paxel_win_cursor%/AppData/*}/.cursor/projects"
        fi
        break
      done
    fi
    ;;
esac
# Current Cursor versions write agent chats as plain JSONL under
# ~/.cursor/projects/<encoded-cwd>/agent-transcripts/ (the SQLite composerData
# rows above stop being written). Same location on every OS ($HOME resolves to
# the user profile on Git Bash). collect_cursor_project_transcripts reads this
# tree; override for the test harness like the other *_DIR vars.
CURSOR_PROJECTS_DIR="${CURSOR_PROJECTS_DIR:-$HOME/.cursor/projects}"
# <<< paxel-cursor-os-paths
# opencode stores sessions in a SQLite DB under the XDG data dir on BOTH macOS
# and Linux (it uses the xdg-basedir convention, not ~/Library on macOS).
# collect_opencode_sessions scans OPENCODE_DIR for opencode*.db (covers channel
# DBs like opencode-beta.db; WAL files end in -wal/-shm and don't match).
# Set OPENCODE_DB to point at a single DB explicitly (used by the test harness).
OPENCODE_DIR="${OPENCODE_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/opencode}"
# Gemini CLI stores one JSONL transcript per session under ~/.gemini/tmp/<slug>/chats/
# on BOTH macOS and Linux (its home dir is always ~/.gemini — there is no env-var
# override in gemini-cli). Each <slug> dir has a .project_root naming the repo.
# collect_gemini_sessions copies these raw (the server GeminiNormalizer reconstructs
# them). Override GEMINI_DIR to point at a fixture tree (used by the test harness).
GEMINI_DIR="${GEMINI_DIR:-$HOME/.gemini/tmp}"
# Google Antigravity (the agy CLI, the standalone IDE, and the 2.0 hub app) renders
# every conversation to a plaintext transcript at
# ~/.gemini/<surface>/brain/<uuid>/.system_generated/logs/transcript.jsonl, where
# <surface> is antigravity | antigravity-ide | antigravity-cli — all under ~/.gemini
# (no env override in the app). Attribution (workspace path + git remote) lives in
# the sibling ~/.gemini/<surface>/conversations/<uuid>.db (SQLite). collect_antigravity_sessions
# copies the transcript raw with a synthetic meta line (server AntigravityNormalizer
# reconstructs it). Override ANTIGRAVITY_DIR to point at a fixture tree (test harness).
ANTIGRAVITY_DIR="${ANTIGRAVITY_DIR:-$HOME/.gemini}"
# VS Code Copilot stores one big JSON object per chat session under
# <userDataDir>/User/workspaceStorage/<hash>/chatSessions/*.json, with a sibling
# workspace.json naming the workspace folder. The user-data dir differs by OS and
# by channel (stable "Code" vs "Code - Insiders"); Cursor lives under its own
# "Cursor" dir and is a SEPARATE source, so it is NOT included here. VSCODE_DIR is
# a newline-separated LIST of workspaceStorage base dirs the collector iterates;
# override it (single dir or newline list) to point at a fixture tree.
if [ -z "${VSCODE_DIR:-}" ]; then
  case "$(uname -s)" in
    Darwin)
      VSCODE_DIR="$HOME/Library/Application Support/Code/User/workspaceStorage
$HOME/Library/Application Support/Code - Insiders/User/workspaceStorage"
      ;;
    MINGW*|MSYS*|CYGWIN*)
      _paxel_vscode_appdata="${APPDATA:-$HOME/AppData/Roaming}"
      _paxel_vscode_appdata="${_paxel_vscode_appdata//\\//}"
      VSCODE_DIR="$_paxel_vscode_appdata/Code/User/workspaceStorage
$_paxel_vscode_appdata/Code - Insiders/User/workspaceStorage"
      ;;
    *)
      VSCODE_DIR="$HOME/.config/Code/User/workspaceStorage
$HOME/.config/Code - Insiders/User/workspaceStorage"
      ;;
  esac
fi
DRY_RUN="${DRY_RUN:-0}"
PAXEL_SERVER="${PAXEL_SERVER:-https://paxel.ycombinator.com}"
PAXEL_LLM_PROXY="${PAXEL_LLM_PROXY:-https://paxel-llm.ycombinator.com}"
PAXEL_TOKEN_FILE="${HOME}/.paxel/token"
PAXEL_CLIENT_IMAGE="${PAXEL_CLIENT_IMAGE:-ghcr.io/yc-software/paxel-client:latest}"
PAXEL_REPO_ROOT="${PAXEL_REPO_ROOT:-}"
PAXEL_BAKED_TOKEN=""
PAXEL_SCRIPT_VERSION="0.3.92.0"

# Defaults
PROJECT_NAME=""
ALL_PROJECTS=0
SINCE_EPOCH=""
OLDEST_SESSION_EPOCH=""
NO_REPO=0

# Grouped project data (parallel arrays for bash 3.2 compat)
GROUP_REMOTES=()
GROUP_DISPLAYS=()
GROUP_DIRS=()       # pipe-separated dir names per group
GROUP_COUNTS=()     # session count per group
GROUP_DIR_COUNTS=() # workspace count per group

# Selected project dirs (set by auto-detect or interactive selection)
PROJECT_DIRS=()

# Multi-repo mode state
MULTI_REPO_RUNNING=0
MULTI_REPO_MODE=""
MULTI_REPO_SELECTED=0
# Zero-based indices into the CHILD_REPO_* arrays for the selected subset.
# Populated by show_child_repo_menu; consumed by run_selected_child_repos.
MULTI_REPO_SELECTED_LIST=()
CHILD_REPO_DIRS=()
CHILD_REPO_REMOTES=()
CHILD_REPO_NAMES=()
CHILD_REPO_SESSIONS=()
# 1 = repo has only Cursor sessions (no cheap count); picker labels it accordingly.
CHILD_REPO_CURSOR_ONLY=()
CHILD_TRANSCRIPT_DIRS=()
CHILD_CODEX_DIRS=()

# --- Functions ---

PAXEL_EXIT_STORAGE_FULL=8
# Kept in sync with ClientPipeline::EXIT_REGION_BLOCKED by cross-reference
# comment only.
PAXEL_EXIT_REGION_BLOCKED=9
PAXEL_DOCKER_LOW_SPACE_MB=256
PAXEL_DOCKER_STORAGE_ERROR_PATTERN='no space left on device|disk quota exceeded|not enough space (is )?available|not enough space on (the )?disk'

# Determine whether to emit ANSI escape codes. Evaluated ONCE here at module
# load so `[ -t 1 ]` sees the script's actual stdout — evaluating inside a
# function via `$(...)` would inherit the subshell's pipe and always be false.
# NO_COLOR (https://no-color.org/) disables color regardless of TTY.
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  _IS_TTY=1
else
  _IS_TTY=0
fi

# Semantic color helpers. Scope is narrow on purpose: decision moments only.
# Informational output stays uncolored so the color itself is a signal —
# "your attention is wanted here."
# Takes a color name and text; returns text unchanged when stdout isn't a tty
# or NO_COLOR is set. osascript/notifier strings and any var that flows into
# non-tty surfaces (logs, telemetry) MUST NOT be wrapped in these helpers —
# wrap only at echo time.
_color() {
  if [ "${_IS_TTY:-0}" != "1" ]; then
    printf '%s' "$2"
    return
  fi
  local code
  case "$1" in
    yellow) code='33' ;;
    green)  code='32' ;;
    *)      printf '%s' "$2"; return ;;
  esac
  printf '\033[%sm%s\033[0m' "$code" "$2"
}

_bold() {
  if [ "${_IS_TTY:-0}" != "1" ]; then
    printf '%s' "$1"
    return
  fi
  printf '\033[1m%s\033[0m' "$1"
}

# Build a copy-pasteable re-run command with flags
rerun_cmd() {
  local flags="$*"
  # Always TOKENLESS. The live API token is never baked into a URL we echo to
  # the terminal — that would put a credential into scrollback, screen-shares,
  # teed logs, CI output, and pasted issue reports (the token-in-query-string
  # form is already known to land in Cloudflare request logs). A re-run picks up
  # the saved token from ${PAXEL_TOKEN_FILE} (chmod 600); a fresh user with no
  # saved token falls through to the normal interactive auth flow.
  if [ "${PAXEL_LAUNCHER:-}" = "1" ]; then
    local launcher="~/.paxel/bin/paxel" on_path
    on_path=$(command -v paxel 2>/dev/null || true)
    [ "$on_path" = "${HOME}/.paxel/bin/paxel" ] && launcher="paxel"
    echo "${launcher}${flags:+ ${flags}}"
    return
  fi
  echo "curl -fsSL '${PAXEL_SERVER}/upload.sh' | bash -s -- ${flags}"
}

# Env-aware remediation phrase for user-facing messages. Mirrors
# AnthropicClient#rebuild_user_action / #auth_user_action
# (app/models/concerns/anthropic_client.rb:581-598): bin/upload exports
# PAXEL_CLIENT_MODE=dev, so devs get `bin/upload`-style commands; public
# curl|bash runs leave it unset and get copy-pasteable curl commands via
# rerun_cmd.
#
# `reauth` intentionally does NOT delegate to rerun_cmd in prod — a tokenless
# rerun_cmd re-loads the SAVED token (${PAXEL_TOKEN_FILE}), which on an
# AUTH_REQUIRED failure is exactly the credential we want the user to REPLACE.
# The user needs a fresh login from their dashboard.
rerun_phrase() {
  local kind="$1"
  local dev=0
  [ "${PAXEL_CLIENT_MODE:-}" = "dev" ] && dev=1
  case "$kind" in
    fresh)
      if [ "$dev" = 1 ]; then
        echo "Run bin/upload again for a fresh analysis."
      else
        echo "To re-run: $(rerun_cmd)"
      fi
      ;;
    next_upload)
      if [ "$dev" = 1 ]; then
        echo "Will retry on next bin/upload."
      else
        echo "Will retry on your next upload."
      fi
      ;;
    reauth)
      if [ "$dev" = 1 ]; then
        echo "Run bin/upload interactively to refresh your token."
      else
        echo "Re-login on your Paxel dashboard for a fresh upload command; pending uploads will retry on the next run."
      fi
      ;;
    bypass_replay)
      if [ "$dev" = 1 ]; then
        echo "Bypass with bin/upload --no-replay."
      else
        echo "To bypass: $(rerun_cmd --no-replay)"
      fi
      ;;
    *)
      echo "Re-run the upload command from your Paxel dashboard."
      echo "[paxel] internal: rerun_phrase called with unknown kind '$kind'" >&2
      return 2
      ;;
  esac
}

# After a replay-and-exit, hint that re-running analyzes any repo that didn't
# finish. The replay gate runs BEFORE child-repo detection, so when a multi-repo
# run leaves one repo's upload stashed and a sibling crashed mid-analysis (before
# it could stash), the next run replays-and-exits and the crashed sibling is never
# re-picked — the user thinks "re-running fixed it" while a report is still missing.
# Only emitted when this directory actually holds >=2 child repos, so single-repo
# replays stay quiet. Cheap: stat-only on immediate children, no git/cache scan.
multi_repo_replay_hint() {
  local _n=0
  local _c
  for _c in ./*/; do
    [ -d "$_c" ] || continue
    if [ -e "${_c}.git" ] || [ -e "${_c}.jj" ]; then
      _n=$((_n + 1))
      [ "$_n" -ge 2 ] && break
    fi
  done
  [ "$_n" -ge 2 ] || return 0
  echo "[paxel] Multiple repos here — re-run from this directory to analyze any that didn't finish."
}

# Detect a copy-on-write cp flag ONCE: --reflink=auto on GNU coreutils
# (Linux/btrfs+XFS), -c (clonefile) on BSD/macOS+APFS. Both share storage instead
# of byte-copying. --reflink=auto silently falls back to a byte copy when CoW
# isn't possible; macOS `cp -c` does NOT — it errors "clonefile failed:
# Cross-device link" (per file) when the copy crosses a volume boundary. The flag
# is PROBED on a same-volume throwaway, so `-c` can be selected even when the real
# copy will cross volumes (a symlinked ~/.claude subtree on another disk, a
# redirected ~/.paxel); _paxel_cp_transcripts retries without the flag to cover
# that. Probing (vs inferring from `cp --version`) also keeps a flag the local cp
# rejects (pre-coreutils-7.5 GNU, pre-10.12 BSD, BusyBox) from ever reaching the
# real copy. Always returns 0 (never aborts the caller).
_paxel_detect_cp_cow() {
  [ -n "${_PAXEL_CP_COW_DETECTED:-}" ] && return 0
  _PAXEL_CP_COW_DETECTED=1
  _PAXEL_CP_COW_FLAG=""
  local _t
  _t=$(mktemp -d 2>/dev/null) || return 0
  if : > "$_t/probe" 2>/dev/null; then
    if cp --reflink=auto "$_t/probe" "$_t/r" 2>/dev/null; then
      _PAXEL_CP_COW_FLAG="--reflink=auto"   # GNU coreutils
    elif cp -c "$_t/probe" "$_t/c" 2>/dev/null; then
      _PAXEL_CP_COW_FLAG="-c"               # BSD/macOS clonefile
    fi
  fi
  rm -rf "$_t" 2>/dev/null || true
  return 0
}

# Recursively copy a transcript dir, preferring the CoW clone above. Keeps -RLp on
# every path: recurse, DEREF source symlinks (-L — the trees are deliberately
# symlinked, so -a/-al would dangle them and the container would silently drop
# those sessions), preserve mtime (-p, for the container's --since File.mtime
# check). CoW makes 'analyze all' over a multi-GB ~/.claude stop byte-copying every
# repo's sessions. Returns cp's exit status verbatim so callers fail loud (the
# single-repo sites are bare under active errexit; the multi-repo site wraps it in
# `if` and routes failure to failed_repos).
_paxel_cp_transcripts() {
  _paxel_detect_cp_cow
  # Try the CoW clone, then fall back to a plain copy. macOS `cp -c` does not fall
  # back across volumes (the flag was probed same-volume), so a cross-device
  # source/dest would otherwise fail the whole repo. The retry guarantees a correct
  # copy; the plain cp's exit status is returned verbatim so callers still fail loud
  # on a genuine error.
  if [ -n "${_PAXEL_CP_COW_FLAG:-}" ]; then
    cp -RLp "${_PAXEL_CP_COW_FLAG}" "$1" "$2" 2>/dev/null && return 0
    # The CoW clone can fail PART-WAY: macOS `cp -c` creates "$2" and copies some
    # files, then errors per-file on the first cross-device clonefile. Remove the
    # partial dest before the plain retry — otherwise the plain copy sees an existing
    # dir and nests the source under "$2/$(basename "$1")", silently dropping every
    # session. Callers always pass a not-yet-existing "$2".
    rm -rf "$2" 2>/dev/null || true
  fi
  cp -RLp "$1" "$2"
}

# Count JSONL session files in a directory (excludes subagents, _git, _metadata).
# Counts Claude-style JSONLs only (one file per session, flat layout). Codex
# sessions use YYYY/MM/DD subdirs and are counted by the collect_* paths that
# write them into the upload archive.
count_sessions() {
  local dir="$1"
  # Guard a missing dir (e.g. a Codex/Cursor-only user with no ~/.claude/projects):
  # `find` on a nonexistent path exits non-zero, which under `set -Eeuo pipefail`
  # aborts the whole upload (CLIENT-F / kalyanprakash). `|| true` also absorbs a
  # mid-walk permission error on an existing tree.
  [ -d "$dir" ] || { echo 0; return 0; }
  { claude_session_files "$dir" || true; } | wc -l | tr -d ' '
}

# The Claude session files under a directory; extra arguments are find actions.
claude_session_files() {
  local dir="$1"
  shift
  find "$dir" -maxdepth 3 -name "*.jsonl" -not -name "_*" -not -path "*/_git/*" -not -path "*/subagents/*" "$@" 2>/dev/null
}

count_subagent_sessions() {
  local dir="$1"
  [ -d "$dir" ] || { echo 0; return 0; }
  { find "$dir" -path "*/subagents/*.jsonl" -maxdepth 5 2>/dev/null || true; } | wc -l | tr -d ' '
}

# Returns data size in MB for display
get_data_size() {
  local dir="$1"
  du -sm "$dir" 2>/dev/null | cut -f1 || echo "0"
}

# Estimate client-side pipeline time in minutes from session count.
# Cloud-only model calibrated 2026-04-25 (cloud Haiku via proxy, no Ollama).
# Dominant cost is 3 LLM steps (summarize, decisions, scoring) at 20-thread
# parallelism. ~0.85s/session fresh, near-zero when cached.
# Calibration: 1082 sessions → 947s actual (15m 47s).
#
# Segments (continuous at boundaries):
#   s <= 30:       30 + s*3        overhead dominates (parsing, git, upload)
#   30 < s <= 200: 120 + (s-30)*1  LLM parallelism kicks in
#   s > 200:       290 + (s-200)*1 sustained ~1s/session
#
# SYNC: keep in sync with estimate_processing_time() in results_helper.rb
estimate_time() {
  local s=$1
  local total_secs
  if [ "$s" -le 30 ]; then
    total_secs=$((30 + s * 3))
  elif [ "$s" -le 200 ]; then
    total_secs=$((120 + (s - 30) * 1))
  else
    total_secs=$((290 + (s - 200) * 1))
  fi

  local minutes=$(( (total_secs + 59) / 60 ))
  [ "$minutes" -lt 2 ] && minutes=2
  echo "$minutes"
}

# Print time estimate with session count, data size, and email notice.
# `codex_count` here is standalone Codex (the user invoked `codex` directly).
# `codex_cross_tool_count` is Codex sessions launched by Claude via codex-companion
# (or other tool); the caller folds these into `subagent_count` so the header math
# (Found N sessions + M subagents) does not double-count.
print_estimate() {
  local sessions=$1
  local data_mb=$2
  local claude_count=${3:-0}
  local codex_count=${4:-0}
  local codex_cross_tool_count=${5:-0}
  local project_name=${6:-}
  local subagent_count=${7:-0}
  local total=$((sessions + subagent_count))
  local minutes
  minutes=$(estimate_time "$total")
  ESTIMATED_MINUTES="$minutes"
  echo ""
  local label=""
  if [ -n "$project_name" ]; then
    label=" for ${project_name}"
  fi
  local session_word="sessions"
  [ "$sessions" -eq 1 ] && session_word="session"
  local prefix="Found ${sessions} ${session_word}"
  if [ "$subagent_count" -gt 0 ]; then
    local sub_word="subagent"
    [ "$subagent_count" -gt 1 ] && sub_word="subagents"
    prefix="${prefix} + ${subagent_count} ${sub_word}"
  fi
  prefix="${prefix}${label} (${data_mb}MB)."
  echo "${prefix} Estimated time: ~${minutes} minutes."
  if [ "$claude_count" -gt 0 ]; then
    echo "  Claude Code: ${claude_count} sessions"
  fi
  if [ "$codex_count" -gt 0 ]; then
    echo "  Codex CLI: ${codex_count} sessions"
  fi
  if [ "$codex_cross_tool_count" -gt 0 ]; then
    echo "  Codex launched by Claude: ${codex_cross_tool_count} sessions"
  fi
  echo ""
  echo "  ★  You'll get an email when your report is ready."
  echo ""
}

user_read() {
  read "$@" </dev/tty
}

require_tty() {
  if [ ! -c /dev/tty ]; then
    echo "Error: No terminal available for interactive selection." >&2
    echo "  $(rerun_cmd --project NAME)" >&2
    echo "  $(rerun_cmd --all)" >&2
    exit 1
  fi
}

# Run "$@" with a wall-clock cap so a pathological repo (a single giant or
# minified file makes `git log --numstat` compute an enormous diff) can't hang
# the whole upload forever. Prefers coreutils timeout/gtimeout; on stock macOS
# (neither present) falls back to a portable background-kill. Returns the
# command's exit status; callers append `|| true`, so a timeout degrades to a
# partial/empty metrics file rather than aborting. Override the cap with
# PAXEL_GIT_TIMEOUT. Called in `|| true` context, so set -e / the ERR trap are
# suspended inside the body (no abort on the 124/143 timeout status).
PAXEL_GIT_TIMEOUT="${PAXEL_GIT_TIMEOUT:-120}"
_run_with_timeout() {
  local _secs="$1"; shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$_secs" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$_secs" "$@"
  else
    "$@" &
    local _cmd_pid=$!
    # The watcher's sleeps run in the background so its TERM trap fires at
    # once and takes them down; a foreground sleep would outlive the watcher
    # and pile up, one per call, in a long-running caller.
    (
      _sleep_pid=""
      trap '[ -z "$_sleep_pid" ] || kill "$_sleep_pid" 2>/dev/null || true; exit 0' TERM
      sleep "$_secs" & _sleep_pid=$!
      wait "$_sleep_pid" || true
      kill -TERM "$_cmd_pid" 2>/dev/null || true
      sleep 3 & _sleep_pid=$!
      wait "$_sleep_pid" || true
      kill -KILL "$_cmd_pid" 2>/dev/null || true
    ) >/dev/null 2>&1 &
    local _watch_pid=$!
    local _rc=0
    wait "$_cmd_pid" 2>/dev/null || _rc=$?
    kill -TERM "$_watch_pid" 2>/dev/null || true
    wait "$_watch_pid" 2>/dev/null || true
    return "$_rc"
  fi
}

# Per-day/per-author commit counts shipped for the YC git-activity heatmap.
# Independent of --commits (which caps the numstat); narrowed by --since.
PAXEL_ACTIVITY_WINDOW_DAYS="${PAXEL_ACTIVITY_WINDOW_DAYS:-365}"

# Parse --since value to epoch threshold
parse_since() {
  local since_str="$1"
  local now_epoch
  now_epoch=$(date +%s)

  # Match relative durations: 6h, 7d, 2w, 1m
  case "$since_str" in
    *h)
      local hours="${since_str%h}"
      echo $(($now_epoch - $hours * 3600))
      ;;
    *d)
      local days="${since_str%d}"
      echo $(($now_epoch - $days * 86400))
      ;;
    *w)
      local weeks="${since_str%w}"
      echo $(($now_epoch - $weeks * 7 * 86400))
      ;;
    *m)
      local months="${since_str%m}"
      echo $(($now_epoch - $months * 30 * 86400))
      ;;
    *)
      # Try as absolute date (YYYY-MM-DD), interpreted as MIDNIGHT local time.
      # GNU `date -d YYYY-MM-DD` already means midnight; BSD `date -j -f "%Y-%m-%d"`
      # (no time component) fills in the CURRENT time-of-day — wrong (the cutoff
      # drifts by up to a day) and non-deterministic — so pin BSD to 00:00:00 with a
      # full format. BSD/GNU syntaxes are mutually incompatible (each exits 1 on the
      # other's flags); GNU is tried first to match the stat-order convention here.
      local epoch
      epoch=$(date -d "$since_str" "+%s" 2>/dev/null) \
        || epoch=$(date -j -f "%Y-%m-%d %H:%M:%S" "$since_str 00:00:00" "+%s" 2>/dev/null)
      if [ -n "$epoch" ]; then
        echo "$epoch"
        return
      fi
      echo "Error: Invalid --since format: $since_str (use 6h, 7d, 2w, 1m, or YYYY-MM-DD)" >&2
      exit 1
      ;;
  esac
}

# Extract human-readable repo name from remote URL
remote_display_name() {
  local remote_url="$1"
  # "git@github.com:example-org/example-repo.git" -> "example-repo"
  # "https://github.com/user/repo.git" -> "repo"
  local name
  name=$(echo "$remote_url" | sed 's/\.git$//' | sed 's|.*[/:]||')
  echo "$name"
}

# Extract real filesystem path from a project directory
get_project_cwd() {
  local project_dir_name="$1"
  local project_dir="$CLAUDE_DIR/$project_dir_name"
  local index_file="$project_dir/sessions-index.json"

  # 1. Try sessions-index.json originalPath
  if [ -f "$index_file" ]; then
    local original_path=""
    if command -v jq &>/dev/null; then
      # Handle both array format and {version, entries} format
      original_path=$(jq -r '
        if type == "array" then
          .[0].originalPath // empty
        elif type == "object" then
          (.entries // [])[0].originalPath // empty
        else empty end
      ' "$index_file" 2>/dev/null || true)
    fi
    if [ -z "$original_path" ]; then
      # grep fallback
      original_path=$(grep -o '"originalPath":"[^"]*"' "$index_file" 2>/dev/null | head -1 | sed 's/"originalPath":"//;s/"$//' || true)
    fi
    if [ -n "$original_path" ]; then
      echo "$original_path"
      return
    fi
  fi

  # 2. Scan first JSONL for cwd field (skip queue-operation lines)
  local first_jsonl
  first_jsonl=$(find "$project_dir" -name "*.jsonl" -maxdepth 1 -size +0 -print -quit 2>/dev/null || true)
  if [ -n "$first_jsonl" ]; then
    local cwd=""
    while IFS= read -r line; do
      # Skip queue-operation lines
      case "$line" in
        *'"type":"queue-operation"'*) continue ;;
      esac
      # Try to extract cwd
      local maybe_cwd
      maybe_cwd=$(echo "$line" | grep -o '"cwd":"[^"]*"' | head -1 | sed 's/"cwd":"//;s/"$//' || true)
      if [ -n "$maybe_cwd" ]; then
        cwd="$maybe_cwd"
        break
      fi
    done < "$first_jsonl"
    if [ -n "$cwd" ]; then
      echo "$cwd"
      return
    fi
  fi

  # 3. Fallback: decode from dir name
  echo ""
}

# Returns 0 when this Codex session should count toward the picker's session
# total (N), 1 when it should count toward the subagent total (M).
#
# Picker semantics deliberately differ from cross_tool_linker.rb#STANDALONE_ORIGINATORS:
# only "Claude Code"-originated Codex sessions are bucketed as cross-tool,
# because CrossToolLinker only assigns triggered_by_id for Claude-origin
# parents (cross_tool_linker.rb:113-127). Cursor / unknown / future launchers
# stay as logical_roots server-side, so the picker must count them as sessions
# to avoid undercounting + the zero-abort path on Cursor-only Codex users.
#
# Implicit accept list (catch-all): "" (empty, pre-detector-fix sessions),
# codex_cli_rs / codex_exec / codex-tui (server STANDALONE_ORIGINATORS),
# codex_cli (v0.92 flat format), Cursor, unknown.
codex_originator_is_standalone() {
  case "$1" in
    "Claude Code") return 1 ;;
    *) return 0 ;;
  esac
}

# Read originator from a Codex JSONL first line. Independent helper — does NOT
# refactor get_codex_session_remote / get_codex_session_cwd, which are on the
# upload-extraction critical path (collect_codex_sessions). Reads
# .payload.originator OR top-level .originator (v0.92 flat format).
get_codex_session_originator() {
  local jsonl_file="$1"
  local first_line=""
  IFS= read -r first_line < "$jsonl_file" 2>/dev/null || true
  [ -z "$first_line" ] && echo "" && return
  if command -v jq >/dev/null 2>&1; then
    # jq <1.7 on Windows emits CRLF like sqlite3.exe; strip the \r $() keeps.
    local _orig
    _orig=$(printf '%s' "$first_line" | jq -r '(.payload // .).originator // empty' 2>/dev/null || echo "")
    printf '%s\n' "${_orig//$'\r'/}"
  else
    # grep fallback — handles both nested and top-level originator since
    # the field key is the same. The trailing `|| true` mirrors sibling
    # helpers (get_codex_session_remote line ~514) and is critical: without
    # it, a Codex JSONL whose first line lacks `"originator":"…"` makes grep
    # exit 1 → pipeline fails under set -o pipefail → _paxel_on_error ERR
    # trap fires → upload aborts. Exact failure mode for jq-absent users
    # with even one malformed/partial session file in ~/.codex/sessions/.
    printf '%s' "$first_line" | grep -o '"originator":"[^"]*"' 2>/dev/null \
      | head -1 | sed 's/.*":"//;s/"$//' || true
  fi
}

# Extract git remote URL from a Codex JSONL file's session_meta (first line).
# Falls through to the session's cwd if repository_url is absent: live cwd
# uses git-remote directly; dead cwd routes through resolve_remote_for_dead_cwd
# so orphan Codex sessions group under their real repo.
get_codex_session_remote() {
  local jsonl_file="$1"
  local first_line=""
  IFS= read -r first_line < "$jsonl_file" 2>/dev/null || true
  [ -z "$first_line" ] && echo "" && return

  local remote=""
  if command -v jq &>/dev/null; then
    remote=$(echo "$first_line" | jq -r '(.payload // .).git.repository_url // empty' 2>/dev/null || true)
    remote=${remote//$'\r'/}  # jq <1.7 on Windows emits CRLF; a \r-only value would skip the cwd fallback
  fi
  if [ -z "$remote" ]; then
    # grep fallback for repository_url
    remote=$(echo "$first_line" | grep -o '"repository_url":"[^"]*"' | sed 's/"repository_url":"//;s/"$//' 2>/dev/null || true)
  fi

  if [ -z "$remote" ]; then
    local cwd
    cwd=$(get_codex_session_cwd "$jsonl_file")
    if [ -n "$cwd" ]; then
      if [ -e "$cwd" ]; then
        remote=$(get_git_remote "$cwd")
      else
        remote=$(resolve_remote_for_dead_cwd "$cwd")
      fi
    fi
  fi

  # Normalize raw repository_url paths (jq/grep above); get_git_remote and
  # resolve_remote_for_dead_cwd already return normalized, so this is a no-op
  # for those branches.
  normalize_remote "$remote"
}

# Extract working directory from a Codex JSONL file's session_meta (first line)
get_codex_session_cwd() {
  local jsonl_file="$1"
  local first_line=""
  IFS= read -r first_line < "$jsonl_file" 2>/dev/null || true
  [ -z "$first_line" ] && echo "" && return

  if command -v jq &>/dev/null; then
    local cwd
    cwd=$(echo "$first_line" | jq -r '(.payload // .).cwd // empty' 2>/dev/null || true)
    cwd=${cwd//$'\r'/}  # jq <1.7 on Windows emits CRLF
    if [ -n "$cwd" ]; then
      echo "$cwd"
      return
    fi
  fi

  # grep fallback
  local cwd
  cwd=$(echo "$first_line" | grep -o '"cwd":"[^"]*"' | sed 's/"cwd":"//;s/"$//' 2>/dev/null || true)
  echo "$cwd"
}

# True (0) when a session's cwd is within scope_cwd (equal, or a descendant). Lets a
# no-remote scoped run (a home/parent-dir auto-detect — C6) keep only the sessions
# actually under that dir (the home SUBTREE), instead of pulling every machine-wide
# orphan. String-prefix on the recorded cwd (cheap, dead-cwd-safe); scope_cwd is
# canonical ($(pwd -P)). Returns 1 (out of scope) when either side is empty. Stays
# inside `case`/explicit returns so it's safe under set -Eeuo pipefail + the ERR trap.
_paxel_cwd_in_scope() {
  local session_cwd="$1" scope="$2"
  [ -n "$scope" ] || return 1
  [ -n "$session_cwd" ] || return 1
  case "$session_cwd" in
    "$scope") return 0 ;;
    "$scope"/*) return 0 ;;
    *) return 1 ;;
  esac
}

# Emit 6 chars of stable hex over $1. Tries md5sum (Linux) then md5 (macOS),
# falls back to "000000" if neither is available. Used to disambiguate
# per-remote / per-workspace bucket directories that share a basename.
stable_hash6() {
  if command -v md5sum >/dev/null 2>&1; then
    printf '%s' "$1" | md5sum | cut -c1-6
  elif command -v md5 >/dev/null 2>&1; then
    printf '%s' "$1" | md5 | cut -c1-6
  else
    echo "000000"
  fi
}

repository_git_key() {
  local remote
  remote=$(normalize_remote "$1")
  local cwd="${2:-}"
  local identity="${remote:-$cwd}"
  local slug
  slug=$(basename "$identity" .git)
  slug=$(printf '%s' "$slug" | tr -c 'A-Za-z0-9_.-' '-' | sed 's/--*/-/g; s/^-//; s/-$//')
  [ -z "$slug" ] && slug="repo"
  echo "_repo_${slug}_$(stable_hash6 "$identity")"
}

# Compute a stable per-remote bucket dir name for a Codex session.
# Returns "_codex_unattributed" when the remote is empty, otherwise
# "_codex_<slug>_<hash6>" where <slug> is a sanitized repo basename and
# <hash6> is 6 chars of md5 over the raw remote (stable across runs,
# collision-safe across different repos that share a basename).
# codex_bucket_name <remote> [session_cwd] [scope_cwd]
# With a remote → "_codex_<slug>_<hash6(remote)>" (groups by repo). With no remote:
# in a SCOPED run (scope_cwd set + the session cwd in scope) → "_codex_<basename>_
# <hash6(cwd)>" so the no-remote session surfaces as a real cwd-named Project (the
# server reads the sidecar cwd for its path); otherwise (--all machine-wide orphans)
# → "_codex_unattributed" (the dropped catch-all — anti-scatter).
codex_bucket_name() {
  local remote="$1"
  local session_cwd="${2:-}"
  local scope_cwd="${3:-}"
  if [ -n "$remote" ]; then
    local slug
    slug=$(basename "$remote" .git)
    # Sanitize to filesystem-safe chars, collapse runs of '-'
    slug=$(printf '%s' "$slug" | tr -c 'A-Za-z0-9_.-' '-' | sed 's/--*/-/g; s/^-//; s/-$//')
    [ -z "$slug" ] && slug="repo"
    echo "_codex_${slug}_$(stable_hash6 "$remote")"
    return
  fi
  if [ -n "$scope_cwd" ] && [ -n "$session_cwd" ] && _paxel_cwd_in_scope "$session_cwd" "$scope_cwd"; then
    local cslug
    cslug=$(basename "$session_cwd")
    cslug=$(printf '%s' "$cslug" | tr -c 'A-Za-z0-9_.-' '-' | sed 's/--*/-/g; s/^-//; s/-$//')
    [ -z "$cslug" ] && cslug="repo"
    echo "_codex_${cslug}_$(stable_hash6 "$session_cwd")"
    return
  fi
  echo "_codex_unattributed"
}

# ── Cursor IDE helpers ──

# Resolve workspace path from a Cursor workspaceStorage directory.
# Each workspace dir has a workspace.json with a "folder" URI (file:///path/to/project).
get_cursor_workspace_path() {
  local ws_dir="$1"
  local ws_json="$ws_dir/workspace.json"
  [ ! -f "$ws_json" ] && echo "" && return

  if command -v jq &>/dev/null; then
    local folder
    folder=$(jq -r '.folder // empty' "$ws_json" 2>/dev/null || true)
    folder=${folder//$'\r'/}  # jq <1.7 on Windows emits CRLF
    if [ -n "$folder" ]; then
      # Strip file:// prefix
      echo "$folder" | sed 's|^file://||'
      return
    fi
  fi

  # grep fallback
  local folder
  folder=$(grep -o '"folder":"[^"]*"' "$ws_json" | sed 's/"folder":"//;s/"$//' 2>/dev/null || true)
  echo "$folder" | sed 's|^file://||'
}

# ── Cursor agent-transcripts (~/.cursor/projects) helpers ──
#
# Current Cursor versions no longer write chats to state.vscdb's cursorDiskKV
# table (extract_cursor_db reports "Your version of Cursor may store data
# differently"); they write one JSONL transcript per agent session under
# ~/.cursor/projects/<encoded-cwd>/agent-transcripts/. Two layouts exist:
#   flat:   agent-transcripts/<session-id>.jsonl              (current)
#   nested: agent-transcripts/<session-id>/<session-id>.jsonl (older mirror)
# Subagent transcripts live at agent-transcripts/<parent>/subagents/<child>.jsonl
# and are re-laid like Claude/opencode subagent files, never counted as main
# sessions. Transcript lines are near-Anthropic content blocks
# ({"role","message":{"content":[…]}}) plus {"type":"turn_ended"} markers; they
# carry NO tool results and NO timestamps (file mtime is the only time signal),
# so the state.vscdb extraction stays the primary source and wins the
# per-session-id dedupe — this path only adds sessions the DBs don't have.

# Cursor encodes a workspace path into its ~/.cursor/projects dir name by
# collapsing every run of non-alphanumeric characters to a single "-" and
# dropping the leading one (probed on Cursor 3.10: /a/b---c -> a-b-c). The
# encoding is LOSSY ("a---b" and "a-b" collide), so decoding a dir name alone
# can't be authoritative — matching known workspace paths comes first.
cursor_projects_encode() {
  printf '%s' "$1" | sed -E 's|[^A-Za-z0-9]+|-|g; s|^-||; s|-$||'
}

# Minimal %XX decoder for workspace.json folder URIs (spaces arrive as %20).
_cursor_urldecode() {
  case "$1" in
    *%*) printf '%b' "${1//\%/\\x}" 2>/dev/null || printf '%s' "$1" ;;
    *) printf '%s' "$1" ;;
  esac
}

# Map ~/.cursor/projects dir names back to workspace paths by encoding every
# path Cursor's workspaceStorage knows (workspace.json is still written per
# window on current Cursor versions, even though composerData is not) and
# matching the dir name exactly. "enc<TAB>path" lines in a global (bash 3.2 —
# no associative arrays). MEMO CAVEAT: cursor_project_dir_to_workspace is
# always invoked in $(...) subshells, where globals set on a miss die with
# the subshell — every loop that resolves project dirs MUST warm the map by
# calling load_cursor_workspace_map in the PARENT shell first, or the map is
# rebuilt (one jq per workspace.json) per project dir. Same footgun as the
# prescan memo below (grep "must be called as a condition").
_CURSOR_PROJ_MAP=""
_CURSOR_PROJ_MAP_LOADED=0
# Every composerId the state.vscdb extraction has SEEN this collection run
# (recorded pre --since/--project filtering; "|id|id|" set, reset at the top
# of collect_cursor_sessions). The transcripts tree defers to the DBs for any
# id in here — see collect_cursor_project_transcripts.
_CURSOR_DB_SEEN_IDS="|"
load_cursor_workspace_map() {
  [ "$_CURSOR_PROJ_MAP_LOADED" -eq 1 ] && return 0
  _CURSOR_PROJ_MAP_LOADED=1
  [ -d "${CURSOR_DIR:-}" ] || return 0
  local ws_dir p enc tab
  tab=$(printf '\t')
  for ws_dir in "$CURSOR_DIR"/*/; do
    [ -f "${ws_dir}workspace.json" ] || continue
    p=$(get_cursor_workspace_path "${ws_dir%/}")
    [ -z "$p" ] && continue
    p=$(_cursor_urldecode "$p")
    # "/c:/Users/.." (Windows drive path with a leading slash) -> "c:/Users/.."
    # so downstream [ -e ] / git -C checks work under Git Bash. Mirrors
    # _vscode_decode_folder_uri. The ENCODED form is identical either way
    # (the collapse eats "/" and ":" alike), so only the map VALUE needs it.
    case "$p" in
      /[A-Za-z]:/*) p="${p#/}" ;;
    esac
    enc=$(cursor_projects_encode "$p")
    [ -z "$enc" ] && continue
    _CURSOR_PROJ_MAP="${_CURSOR_PROJ_MAP}${enc}${tab}${p}
"
  done
  return 0
}

# Reverse the lossy dir-name encoding by walking the live filesystem: each "-"
# either extends the current path segment ("-", "_", ".") or starts a new one
# ("/"). Prefix candidates that match nothing on disk are pruned, so the
# branching stays cheap. Dead paths can't be decoded this way — those are
# covered by the workspace.json map above.
_cursor_decode_walk() {
  local cur="$1" rest="$2"
  if [ -z "$rest" ]; then
    if [ -d "$cur" ]; then printf '%s\n' "$cur"; return 0; fi
    return 1
  fi
  local head="${rest%%-*}" tail="" sep cand probe
  [ "$rest" != "$head" ] && tail="${rest#*-}"
  for sep in / - _ .; do
    cand="${cur}${sep}${head}"
    probe=""
    for probe in "$cand"*; do break; done
    [ -e "$probe" ] || continue
    if _cursor_decode_walk "$cand" "$tail"; then return 0; fi
  done
  return 1
}

# Resolve a ~/.cursor/projects dir name to its workspace path. Empty output =
# unattributable (numeric window ids, "empty-window", deleted paths that
# workspaceStorage never saw).
cursor_project_dir_to_workspace() {
  local enc="$1"
  [ -z "$enc" ] && return 0
  case "$enc" in
    empty-window) return 0 ;;
    *[!A-Za-z0-9-]*) return 0 ;;
  esac
  # All-digit names are windows that never had a folder open.
  case "$enc" in *[!0-9]*) : ;; *) return 0 ;; esac
  load_cursor_workspace_map
  local hit
  hit=$(printf '%s' "$_CURSOR_PROJ_MAP" | awk -F '\t' -v e="$enc" '$1 == e { print $2; exit }' || true)
  if [ -n "$hit" ]; then
    printf '%s\n' "$hit"
    return 0
  fi
  _cursor_decode_walk "" "$enc" || true
}

# Conductor dead-workspace cache fallback shared by the state.vscdb and
# agent-transcripts paths. resolve_remote_for_dead_cwd short-circuits
# */conductor/workspaces/* and */.conductor/* paths (Conductor recovery needs
# sibling-workspace data, not an ancestor walk); list_projects_grouped's
# backfill_conductor_remotes pre-pass writes sibling remotes into the project
# cache. Scan it for a TRUE sibling (exact parent-dir match — the Claude
# encoding `[/.]→-` is lossy, so a prefix match would conflate sibling
# Conductor projects with shared prefixes like "paxel" vs "paxel-v2").
_cursor_conductor_cache_remote() {
  local ws="$1"
  local _normalized_ws="${ws%/}"
  local _ws_parent=""
  case "$_normalized_ws" in
    */conductor/workspaces/*/*) _ws_parent="${_normalized_ws%/*}" ;;
    */.conductor/*) _ws_parent="${_normalized_ws%%/.conductor/*}/.conductor" ;;
  esac
  [ -z "$_ws_parent" ] && return 0
  local _cache_file="${HOME}/.paxel/cache/project-remotes-v2.tsv"
  [ -f "$_cache_file" ] || return 0
  local _dir _key _rest _row_cwd
  while IFS=$'\t' read -r _dir _key _rest; do
    [ -z "$_key" ] && continue
    case "$_key" in name:*|local:*|unknown) continue ;; esac
    _row_cwd=$(get_project_cwd "$_dir" 2>/dev/null || true)
    [ -z "$_row_cwd" ] && continue
    if [ "${_row_cwd%/*}" = "$_ws_parent" ]; then
      printf '%s\n' "$_key"
      return 0
    fi
  done < "$_cache_file"
  return 0
}

# Resolve the git remote for a Cursor workspace path — live paths via
# get_git_remote (already normalized), dead ones via the recovery resolver
# plus the Conductor cache fallback.
cursor_workspace_remote() {
  local ws="$1"
  [ -z "$ws" ] && return 0
  if [ -e "$ws" ]; then
    get_git_remote "$ws"
    return 0
  fi
  local r
  r=$(resolve_remote_for_dead_cwd "$ws" || true)
  [ -z "$r" ] && r=$(_cursor_conductor_cache_remote "$ws")
  [ -n "$r" ] && printf '%s\n' "$r"
  return 0
}

# Print the MAIN session transcripts under one agent-transcripts dir, covering
# both layouts. Anything under subagents/ is excluded (re-laid per-parent by
# the collector); a nested file that isn't self-named isn't a session.
list_cursor_project_transcripts() {
  local at_dir="$1" f sid pd
  find "$at_dir" -maxdepth 1 -name '*.jsonl' 2>/dev/null || true
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    sid=$(basename "$f" .jsonl)
    pd=$(basename "$(dirname "$f")")
    [ "$pd" = "$sid" ] && printf '%s\n' "$f"
  done < <(find "$at_dir" -mindepth 2 -maxdepth 2 -name '*.jsonl' ! -path '*/subagents/*' 2>/dev/null || true)
  return 0
}

# Cheap main-session count for one project dir's agent-transcripts tree.
# Used by the picker group fold in list_projects_grouped.
cursor_project_transcript_count() {
  list_cursor_project_transcripts "$1" | { grep -c . || true; }
}

# Recover a workspace for transcripts whose project dir can't be mapped
# (numeric window ids, "empty-window"): walk each Shell tool call's
# working_directory up to its git/jj root and adopt the root ONLY if every
# command agrees on it — the same all-must-agree rule as the state.vscdb
# path's fileSelections walk, so a stray cross-repo command can't
# mis-attribute the session.
_cursor_transcript_guess_ws() {
  local f="$1"
  local _cand_root="" _wd _p _prev_p _root
  while IFS= read -r _wd; do
    [ -z "$_wd" ] && continue
    _p="$_wd" _root="" _prev_p=""
    while [ -n "$_p" ] && [ "$_p" != "/" ] && [ "$_p" != "." ] && [ "$_p" != "$_prev_p" ]; do
      if [ -e "$_p/.git" ] || [ -d "$_p/.jj" ]; then _root="$_p"; break; fi
      _prev_p="$_p"
      _p=$(dirname "$_p")
    done
    [ -z "$_root" ] && continue
    if [ -z "$_cand_root" ]; then
      _cand_root="$_root"
    elif [ "$_cand_root" != "$_root" ]; then
      return 0
    fi
  done < <(jq -r -R 'fromjson? | objects | select(.role == "assistant") | .message.content[]? | objects | select(.type == "tool_use") | (.input | objects | .working_directory) // empty | strings' "$f" 2>/dev/null | tr -d '\r' | sort -u || true)
  [ -n "$_cand_root" ] && printf '%s\n' "$_cand_root"
  return 0
}

# Find a session's transcript in the ~/.cursor/projects tree (flat or nested,
# never subagents/). Empty when the tree doesn't have it.
_cursor_mirror_transcript_for_session() {
  local cid="$1"
  [ -n "$cid" ] || return 0
  [ -d "${CURSOR_PROJECTS_DIR:-}" ] || return 0
  case "$cid" in *[!A-Za-z0-9._-]*) return 0 ;; esac
  # depth 3 = flat <enc>/agent-transcripts/<sid>.jsonl,
  # depth 4 = nested <enc>/agent-transcripts/<sid>/<sid>.jsonl
  find "$CURSOR_PROJECTS_DIR" -maxdepth 4 -name "${cid}.jsonl" ! -path '*/subagents/*' -print -quit 2>/dev/null || true
}

# Workspace recovery via the transcript tree, for DB sessions whose
# workspaceIdentifier is null and whose fileSelections walk failed: the
# transcript's project dir NAMES the workspace (map match / decode), and
# failing that the transcript content may (Shell working_directory
# agreement). Called BEFORE extract_cursor_db's selected_remote filter, so
# --project uploads keep the full-fidelity DB extraction instead of losing
# the session (it would otherwise stay unattributed and be filtered out).
_cursor_mirror_ws_for_session() {
  local cid="$1"
  local mf enc ws
  mf=$(_cursor_mirror_transcript_for_session "$cid")
  [ -z "$mf" ] && return 0
  enc="${mf#"${CURSOR_PROJECTS_DIR:-}/"}"
  enc="${enc%%/*}"
  ws=$(cursor_project_dir_to_workspace "$enc" || true)
  [ -z "$ws" ] && ws=$(_cursor_transcript_guess_ws "$mf" || true)
  [ -n "$ws" ] && printf '%s\n' "$ws"
  return 0
}

# Re-lay one session's tree subagent transcripts
# (agent-transcripts/<sid>/subagents/*.jsonl) at
# <bucket_dir>/<sid>/subagents/<child>.jsonl — the layout Claude/opencode/
# Gemini subagent files use, so the server links them as children with zero
# changes. Also runs for sessions the DB extraction already emitted (the DBs
# never carry these children); ws/remote stamp the children's _cursor_meta.
_cursor_relay_subagents() {
  local at_dir="$1" sid="$2" bucket_dir="$3" ws="$4" remote="$5"
  [ -d "$at_dir/$sid/subagents" ] || return 0
  local sub_src sub_sid sub_mtime
  while IFS= read -r sub_src; do
    [ -z "$sub_src" ] && continue
    sub_sid=$(basename "$sub_src" .jsonl)
    case "$sub_sid" in *[!A-Za-z0-9._-]*) continue ;; esac
    [ -f "$bucket_dir/$sid/subagents/${sub_sid}.jsonl" ] && continue
    sub_mtime=$(stat -c %Y "$sub_src" 2>/dev/null || stat -f %m "$sub_src" 2>/dev/null || echo 0)
    mkdir -p "$bucket_dir/$sid/subagents"
    _cursor_emit_project_transcript "$sub_src" "$bucket_dir/$sid/subagents/${sub_sid}.jsonl" \
      "$sub_sid" "$ws" "$remote" "$sub_mtime" \
      || rm -f "$bucket_dir/$sid/subagents/${sub_sid}.jsonl"
  done < <(find "$at_dir/$sid/subagents" -maxdepth 1 -name '*.jsonl' 2>/dev/null || true)
  return 0
}

# Convert one agent-transcripts JSONL into the same canonical Claude-native
# shape extract_cursor_db emits (first line carries _cursor_meta; user turns
# are string-content; assistant turns are content-block arrays), so the
# server-side path — detector fall-through to claude_code, discoverer
# _cursor_meta branch, chunker — needs zero changes. The transcript tool
# names differ from the composerData ones (Shell/StrReplace vs
# run_terminal_command_v2/search_replace), hence the separate toolmap.
# $mtime (epoch seconds) stamps every line: these files carry no timestamps.
_cursor_emit_project_transcript() {
  local src="$1" dest="$2" sid="$3" ws="$4" remote="$5" mtime="$6"
  local out
  out=$(jq -c -Rs \
    --arg cid "$sid" \
    --arg ws "$ws" \
    --arg remote "$remote" \
    --arg mt "$mtime" '
    def toolmap: {
      "Shell":"Bash","Terminal":"Bash",
      "StrReplace":"Edit","MultiStrReplace":"Edit","SearchReplace":"Edit","ApplyPatch":"Edit",
      "Create":"Write",
      "ListDir":"LS"
    };
    def canon($n): if ($n|type)=="string" and ($n|length)>0 then (toolmap[$n] // $n) else "tool" end;
    def remap($name; $p):
      ($p // {}) | (if type=="object" then . else {} end)
      | if ($name=="Read" or $name=="Edit" or $name=="Write") and .path and (has("file_path")|not) then . + {file_path:.path}
        elif $name=="Glob" and .glob_pattern and (has("pattern")|not) then . + {pattern:.glob_pattern}
        else . end;
    def usertext($c):
      (if ($c|type)=="string" then $c
       elif ($c|type)=="array" then ([ $c[]? | objects | select(.type=="text") | (.text // "") | strings ] | join("\n"))
       else "" end)
      | sub("^\\s*<user_query>\\s*"; "") | sub("\\s*</user_query>\\s*$"; "");
    def ablocks($c):
      (if ($c|type)=="array" then $c else [] end)
      | [ .[]? | objects
          | if .type=="text" then (if (((.text // "")|tostring)|length) > 0 then {type:"text", text:.text} else empty end)
            elif .type=="thinking" then (if ((((.thinking // .text) // "")|tostring)|length) > 0 then {type:"thinking", thinking:(.thinking // .text)} else empty end)
            elif .type=="tool_use" then
              (canon(.name)) as $tn
              | ({type:"tool_use", name:$tn, input:remap($tn; .input)} + (if .id then {id:.id} else {} end))
            else empty end ];
    (($mt | tonumber? // 0) | todate) as $ts
    | split("\n")
    # fromjson? drops unparseable lines; `objects` drops valid-JSON scalars/arrays
    # (e.g. a bare "turn_ended" string) — without it one such line aborts the
    # whole slurped program and silently drops the ENTIRE session.
    | [ .[] | fromjson? | objects
        | if (.role=="user") and ((.message|type)=="object") then
            (usertext(.message.content // "")) as $t
            | if ($t|length) > 0 then {type:"user", message:{role:"user", content:$t}, timestamp:$ts} else empty end
          elif (.role=="assistant") and ((.message|type)=="object") then
            (ablocks(.message.content // [])) as $b
            | if ($b|length) > 0 then {type:"assistant", message:{role:"assistant", content:$b}, timestamp:$ts} else empty end
          else empty end ]
    | if length == 0 then empty
      else (.[0] += {_cursor_meta:{composerId:$cid, workspace:$ws, git_remote:$remote, agent_type:"cursor"}}) | .[]
      end
  ' "$src" 2>/dev/null || true)
  [ -z "$out" ] && return 1
  printf '%s\n' "$out" > "$dest"
}

# Collect Cursor sessions from the ~/.cursor/projects agent-transcripts tree.
# Runs AFTER the state.vscdb extraction inside collect_cursor_sessions: the DB
# rows carry tool results these transcripts lack, so when both sources have a
# session (same id — the transcript filename IS the composerId) the DB version
# wins and the transcript is skipped. Needs jq only (no sqlite3).
collect_cursor_project_transcripts() {
  local output_dir="$1"
  local selected_remote="${2:-}"

  [ -d "${CURSOR_PROJECTS_DIR:-}" ] || return 0
  command -v jq &>/dev/null || return 0

  # Warm the workspace map in THIS shell — cursor_project_dir_to_workspace
  # runs in $(...) subshells where a miss-triggered load dies with the
  # subshell, and rebuilding it per project dir is quadratic in jq forks.
  load_cursor_workspace_map

  local proj_dir at_dir enc proj_ws src sid ws remote bucket dest existing mtime
  local ex_ws ex_remote
  for proj_dir in "$CURSOR_PROJECTS_DIR"/*/; do
    [ -d "$proj_dir" ] || continue
    at_dir="${proj_dir%/}/agent-transcripts"
    [ -d "$at_dir" ] || continue
    enc=$(basename "${proj_dir%/}")
    proj_ws=$(cursor_project_dir_to_workspace "$enc" || true)

    while IFS= read -r src; do
      [ -z "$src" ] && continue
      sid=$(basename "$src" .jsonl)
      case "$sid" in *[!A-Za-z0-9._-]*) continue ;; esac

      # Already emitted (by the DB extraction, or by this tree's other
      # layout)? Keep that copy — but still relay tree subagents onto it
      # (the DBs never carry these children). The children's meta comes from
      # the emitted parent's first line so attribution stays consistent.
      existing=$(find "$output_dir" -maxdepth 2 -path "*/_cursor_*/${sid}.jsonl" -print -quit 2>/dev/null || true)
      if [ -n "$existing" ]; then
        ex_ws=$(head -1 "$existing" | jq -r '._cursor_meta.workspace // empty' 2>/dev/null || true)
        ex_remote=$(head -1 "$existing" | jq -r '._cursor_meta.git_remote // empty' 2>/dev/null || true)
        # jq <1.7 on Windows emits CRLF; these stamp the children's _cursor_meta
        ex_ws=${ex_ws//$'\r'/}; ex_remote=${ex_remote//$'\r'/}
        _cursor_relay_subagents "$at_dir" "$sid" "$(dirname "$existing")" "${ex_ws:-}" "${ex_remote:-}"
        continue
      fi

      # The DBs know this session but chose not to emit it (--since window on
      # createdAt, or the --project filter). Their verdict is authoritative —
      # never resurrect a DB-known session as a degraded tree copy.
      case "${_CURSOR_DB_SEEN_IDS:-|}" in *"|${sid}|"*) continue ;; esac

      # --since: no timestamps exist inside these files; mtime is the signal
      # (same semantics as the Codex/Gemini/VS Code collectors).
      mtime=$(stat -c %Y "$src" 2>/dev/null || stat -f %m "$src" 2>/dev/null || echo 0)
      if [ -n "${SINCE_EPOCH:-}" ] && [ "$mtime" -lt "$SINCE_EPOCH" ] 2>/dev/null; then
        continue
      fi

      ws="$proj_ws"
      [ -z "$ws" ] && ws=$(_cursor_transcript_guess_ws "$src" || true)
      remote=""
      [ -n "$ws" ] && remote=$(cursor_workspace_remote "$ws")

      if [ -n "${selected_remote:-}" ]; then
        if [ -z "$remote" ] || [ "$remote" != "${selected_remote:-}" ]; then
          continue
        fi
      fi

      bucket="_cursor_unattributed"
      [ -n "$ws" ] && bucket="_cursor_$(basename "$ws")_$(stable_hash6 "$ws")"

      mkdir -p "$output_dir/$bucket"
      dest="$output_dir/$bucket/${sid}.jsonl"
      if ! _cursor_emit_project_transcript "$src" "$dest" "$sid" "${ws:-}" "${remote:-}" "$mtime"; then
        rm -f "$dest"
        continue
      fi

      # Subagent children are excluded from the main-session count by depth
      # (the count find is -maxdepth 2 over the buckets).
      _cursor_relay_subagents "$at_dir" "$sid" "$output_dir/$bucket" "${ws:-}" "${remote:-}"
    done < <(list_cursor_project_transcripts "$at_dir")
  done
  return 0
}

# Extract Cursor sessions from a state.vscdb SQLite database into canonical JSONL.
# Writes one JSONL file per composer session to $output_dir.
# Requires sqlite3 and jq.
extract_cursor_db() {
  local db_path="$1"
  local output_dir="$2"
  local selected_remote="${3:-}"
  local ws_dir
  ws_dir=$(dirname "$db_path")

  # Return codes: 0 = extracted sessions, 1 = no data (not an error), 2 = real error

  # Validate schema
  local tables
  tables=$(sqlite3 "$db_path" ".tables" 2>/dev/null || true)
  if ! echo "$tables" | grep -q "cursorDiskKV"; then
    echo "  Warning: Could not read Cursor chat data in $(basename "$ws_dir")." >&2
    echo "  Your version of Cursor may store data differently. Skipping." >&2
    return 2
  fi

  # Check for composerData entries
  local composer_count
  composer_count=$(sqlite3 "$db_path" "SELECT COUNT(*) FROM cursorDiskKV WHERE key LIKE 'composerData:%'" 2>/dev/null || echo "0")
  composer_count=${composer_count//$'\r'/}  # Windows sqlite3.exe emits CRLF; $() keeps the \r
  if [ "$composer_count" -eq 0 ] 2>/dev/null; then
    return 1
  fi

  # Resolve workspace path and git remote
  local workspace_path
  workspace_path=$(get_cursor_workspace_path "$ws_dir")
  local git_remote=""
  if [ -n "$workspace_path" ]; then
    if [ -e "$workspace_path" ]; then
      git_remote=$(get_git_remote "$workspace_path")
    else
      # workspace.json's folder points at a deleted path; route through
      # the resolver so the ancestor / sibling-worktree recovery strategies
      # can still attribute sessions. Mirrors the per-session site below
      # (see its comment block for the full rationale).
      git_remote=$(resolve_remote_for_dead_cwd "$workspace_path" || true)
    fi
  fi

  local extracted=0

  # Dump composer rows to temp file to avoid subshell variable loss from piping
  local sqlite_out="$output_dir/.sqlite_dump"
  if ! sqlite3 "$db_path" "SELECT key, value FROM cursorDiskKV WHERE key LIKE 'composerData:%'" > "$sqlite_out"; then
    echo "  Warning: Failed to read Cursor data from $(basename "$(dirname "$db_path")")" >&2
    rm -f "$sqlite_out"
    return 2
  fi

  # Iterate over composer sessions (reading from file, not pipe)
  while IFS='|' read -r key value; do
    [ -z "$value" ] && continue

    local composer_id
    composer_id=$(echo "$value" | jq -r '.composerId // empty' 2>/dev/null || true)
    # jq <1.7 on Windows emits CRLF; a CR-tainted id poisons the output
    # filename AND the bubble key-range below (zero bubbles fetched -> the
    # whole session silently dropped).
    composer_id=${composer_id//$'\r'/}
    [ -z "$composer_id" ] && continue

    # Record the id BEFORE the --since/--project filters: the transcripts
    # tree must treat a DB-known-but-filtered session as settled, not
    # re-emit a degraded tree copy of it (see _CURSOR_DB_SEEN_IDS).
    case "$_CURSOR_DB_SEEN_IDS" in
      *"|${composer_id}|"*) ;;
      *) _CURSOR_DB_SEEN_IDS="${_CURSOR_DB_SEEN_IDS}${composer_id}|" ;;
    esac

    # Filter by --since using createdAt (milliseconds epoch)
    if [ -n "$SINCE_EPOCH" ]; then
      local created_at_ms
      created_at_ms=$(echo "$value" | jq -r '.createdAt // 0' 2>/dev/null || echo "0")
      created_at_ms=${created_at_ms//$'\r'/}  # a \r here is a FATAL arithmetic error
      local created_at_s
      created_at_s=$(( created_at_ms / 1000 )) 2>/dev/null || created_at_s=0
      if [ "$created_at_s" -lt "$SINCE_EPOCH" ] 2>/dev/null; then
        continue
      fi
    fi

    # Resolve per-session workspace from composerData (global DB has mixed workspaces)
    local session_ws=""
    session_ws=$(echo "$value" | jq -r '.workspaceIdentifier.uri.fsPath // empty' 2>/dev/null || true)
    session_ws=${session_ws//$'\r'/}  # a \r fails [ -e ] for a live workspace
    # Recover the workspace when Cursor didn't record workspaceIdentifier.uri.fsPath
    # (common for global-DB sessions that outlived their workspace, so they got
    # silently dropped — PAXEL cursor-missed). Walk each file the session
    # referenced up to its enclosing git/jj root; adopt a root ONLY if every
    # referenced file agrees on it, so a stray cross-repo file selection can't
    # mis-attribute the session to the wrong repo (Opus review).
    if [ -z "$session_ws" ]; then
      local _cand_root="" _agree=1 _c
      while IFS= read -r _c; do
        [ -z "$_c" ] && continue
        # Stop at "/", "." and any idempotent root (Git Bash `dirname C:` == `C:`)
        # so a Windows drive-root path can't spin this walk forever.
        local _p="$_c" _root="" _prev_p=""
        while [ -n "$_p" ] && [ "$_p" != "/" ] && [ "$_p" != "." ] && [ "$_p" != "$_prev_p" ]; do
          if [ -e "$_p/.git" ] || [ -d "$_p/.jj" ]; then _root="$_p"; break; fi
          _prev_p="$_p"
          _p=$(dirname "$_p")
        done
        [ -z "$_root" ] && continue
        if [ -z "$_cand_root" ]; then
          _cand_root="$_root"
        elif [ "$_cand_root" != "$_root" ]; then
          _agree=0
          break
        fi
      done < <(echo "$value" | jq -r '(.context.fileSelections[]?.uri.fsPath // empty), (.allAttachedFileCodeChunksUris[]? | sub("^file://"; ""))' 2>/dev/null | tr -d '\r' || true)
      [ "$_agree" -eq 1 ] && session_ws="$_cand_root"
    fi
    # Current-Cursor fallback: the ~/.cursor/projects transcript tree can
    # name this session's workspace when the DB row can't — its project dir
    # encodes the cwd (and the transcript content carries working
    # directories). Runs before the selected_remote filter below so a
    # --project upload keeps the full-fidelity DB extraction instead of
    # dropping the session as unattributed.
    if [ -z "$session_ws" ]; then
      session_ws=$(_cursor_mirror_ws_for_session "$composer_id")
    fi
    [ -z "$session_ws" ] && session_ws="$workspace_path"

    local session_remote="$git_remote"
    if [ -n "$session_ws" ] && [ "$session_ws" != "$workspace_path" ]; then
      if [ -e "$session_ws" ]; then
        session_remote=$(get_git_remote "$session_ws")
      else
        # session_ws is a non-empty path but not on disk (deleted workspace,
        # moved repo). Ancestor-walk / sibling-worktree recovery via
        # resolve_remote_for_dead_cwd. Non-Conductor scope only — Conductor
        # paths short-circuit inside the resolver. get_git_remote (called
        # inside the resolver on live parents) already normalizes, so the
        # return value matches the normalized $selected_remote directly.
        # Stderr NOT suppressed: the resolver's `[paxel] Recovered remote`
        # log is load-bearing debug signal for users troubleshooting "why
        # didn't my Cursor session match?" — matches other call sites.
        session_remote=$(resolve_remote_for_dead_cwd "$session_ws" || true)
      fi

      # Conductor dead-workspace cache fallback — see
      # _cursor_conductor_cache_remote (shared with the agent-transcripts path).
      if [ -z "$session_remote" ] && [ ! -e "$session_ws" ]; then
        session_remote=$(_cursor_conductor_cache_remote "$session_ws")
      fi
    fi

    # Filter by selected_remote (per-session, not per-DB)
    if [ -n "${selected_remote:-}" ]; then
      if [ -z "$session_remote" ] || [ "$session_remote" != "${selected_remote:-}" ]; then
        continue
      fi
    fi

    # Get bubble IDs from fullConversationHeadersOnly
    local bubble_ids
    bubble_ids=$(echo "$value" | jq -r '.fullConversationHeadersOnly[]? | .bubbleId' 2>/dev/null || true)
    [ -z "$bubble_ids" ] && continue

    # Write to per-workspace subdirectory (use path hash to avoid basename collisions)
    local ws_bucket="_cursor_unattributed"
    if [ -n "$session_ws" ]; then
      ws_bucket="_cursor_$(basename "$session_ws")_$(stable_hash6 "$session_ws")"
    fi
    mkdir -p "$output_dir/$ws_bucket"
    local session_file="$output_dir/$ws_bucket/${composer_id}.jsonl"
    [ -f "$session_file" ] && continue  # dedupe: per-workspace DB wins over global DB
    # Batch the per-bubble work into ONE sqlite3 + ONE jq for the whole session.
    # The per-bubble version ran 2 sqlite3 + 2 jq + 1 date PER bubble; on a large
    # global DB (1.5GB, 1000+ bubbles/session) that was ~5 forks * tens of thousands
    # of bubbles, each sqlite3 re-opening the whole DB — it crawled to an effective
    # hang (PAXEL: Cursor extraction hangs, vanshgupta027). Output is byte-identical
    # to the per-bubble path (validated vs real Cursor DBs). The fallback bare-key
    # lookup (bubbleId:<id> without composer prefix) is preserved below.
    local bubbles_dump="$output_dir/.cursor_bubbles_dump"
    # Fetch all of this composer's bubbles in TWO statements (one per key form), NOT a
    # single OR'd query. Two key forms exist: the modern composer-scoped
    # 'bubbleId:<composer>:<bubble>' and the legacy bare 'bubbleId:<bubble>' (the
    # per-bubble path looked up both). NEITHER statement needs the SQLite JSON1
    # extension — important because a single OR'd json_each query would fail to PREPARE
    # on a JSON1-less sqlite build and, under 2>/dev/null, silently drop the WHOLE
    # session (the old per-bubble path never needed JSON1 — it already had the ids).
    #
    # Modern form: a key RANGE (NOT LIKE/GLOB): LIKE is case-insensitive so SQLite can't
    # use the BINARY UNIQUE index and full-scans the whole DB; a >=/< range uses the
    # index, and ';' (0x3B) is the byte just after ':' (0x3A) so it's the exclusive
    # upper bound for the prefix.
    #
    # Legacy bare keys: build the id list HOST-side from the parsed session headers
    # (jq on the composerData $value we already hold), then look them up with a literal
    # IN(...) — no json_each, so no JSON1 dependency. ' is the SQL string quote,
    # written as a jq escape so no literal ' breaks this bash-single-quoted jq program.
    # Cursor bubble ids are UUIDs (no quotes); the SELECT goes over STDIN (printf is a
    # bash builtin → no argv, and sqlite3 reads SQL from stdin), so a huge id list can't
    # hit ARG_MAX. Both statements stay index-driven (~0.02s even on a 1.5GB DB).
    # (Edge: since all bare ids share one IN(...) statement, a single id carrying a '
    # would make the whole statement a SQL error → 2>/dev/null drops this session's bare
    # keys as a set. Impossible for UUID ids; the modern range path is unaffected.)
    #
    # TAB-separated output, NOT -json: `sqlite3 -json` JSON-encodes the BLOB column in a
    # way that is pathologically slow (~9s to encode one large session's bubbles vs
    # ~0.02s to read them raw) — that, plus per-bubble fork overhead, was the real
    # "hang" (PAXEL: Cursor extraction hangs, vanshgupta027). Cursor stores each bubble
    # value as single-line minified JSON with no embedded tabs/newlines (verified across
    # all bubbles), so 'key<TAB>value' is one safe, parseable line per row. Caveat: a
    # value that ever did carry an embedded TAB/newline would split wrong and that one
    # bubble would be silently dropped (try/fromjson/catch null in the reduce below) —
    # graceful degradation of a single bubble, never a crash or a dropped session.
    sqlite3 -separator "$(printf '\t')" "$db_path" \
      "SELECT key, value FROM cursorDiskKV WHERE key >= 'bubbleId:${composer_id}:' AND key < 'bubbleId:${composer_id};'" \
      > "$bubbles_dump" 2>/dev/null || true
    local bare_in
    bare_in=$(printf '%s' "$value" | jq -r '
      [ (.fullConversationHeadersOnly // [])[]? | .bubbleId | select(. != null)
        | "bubbleId:" + (. | tostring) ]
      | if length == 0 then empty else (map("\u0027" + . + "\u0027") | join(",")) end
    ' 2>/dev/null || true)
    if [ -n "$bare_in" ]; then
      printf 'SELECT key, value FROM cursorDiskKV WHERE key IN (%s);\n' "$bare_in" \
        | sqlite3 -separator "$(printf '\t')" "$db_path" >> "$bubbles_dump" 2>/dev/null || true
    fi
    [ -f "$bubbles_dump" ] || : > "$bubbles_dump"

    local now_iso
    now_iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    # composerData ($value) via stdin (avoids ARG_MAX on large sessions); the bubble
    # rows via --rawfile (parsed from the TAB-separated dump in jq below).
    local session_out
    session_out=$(printf '%s' "$value" | jq -c \
      --rawfile brows "$bubbles_dump" \
      --arg cid "$composer_id" \
      --arg ws "${session_ws:-}" \
      --arg remote "${session_remote:-}" \
      --arg now "$now_iso" '
      def toolmap: {
        "run_terminal_command_v2":"Bash","run_terminal_cmd":"Bash",
        "read_file_v2":"Read","read_file":"Read",
        "edit_file_v2":"Edit","edit_file":"Edit","search_replace":"Edit","apply_patch":"Edit","reapply":"Edit",
        "task_v2":"Task",
        "ripgrep_raw_search":"Grep","grep_search":"Grep","grep":"Grep",
        "glob_file_search":"Glob","file_search":"Glob","list_dir":"LS"
      };
      def canon($n): if ($n|type)=="string" and ($n|length)>0 then (toolmap[$n] // $n) else "tool" end;
      def remap($name; $p):
        ($p // {}) | (if type=="object" then . else {} end)
        | del(.streamingContent)
        | if $name=="Read" and .targetFile then . + {file_path:.targetFile}
          elif $name=="Edit" and .relativeWorkspacePath then . + {file_path:.relativeWorkspacePath}
          else . end;
      def tsof($b): (($b.timingInfo.clientEndTime) // ($b.createdAt)) as $t
        | if ($t|type)=="number" then (($t/1000)|floor|todate)
          elif ($t|type)=="string" then (if ($t|test("^[0-9]+$")) then ((($t|tonumber)/1000)|floor|todate) else $t end)
          else $now end;
      def bubble2objs($b):
        tsof($b) as $ts
        | ($b.toolFormerData) as $tfd
        | ($tfd.toolCallId // null) as $tcid
        | (if (($b.type)|tostring)=="2" then "assistant" else "user" end) as $role
        | if $role=="user" and ($tfd==null) then
            (if (($b.text)//"")=="" then empty
             else {type:"user", message:{role:"user", content:($b.text)}, timestamp:$ts} end)
          else
            ( (if (($b.thinking)//"")!="" then [{type:"thinking",thinking:($b.thinking)}] else [] end)
              + (if (($b.text)//"")!="" then [{type:"text",text:($b.text)}] else [] end)
              + (if $tfd then
                   (if (($tfd.params)|type)=="string" then (try (($tfd.params)|fromjson) catch null) else ($tfd.params) end) as $p
                   | (canon($tfd.name)) as $tn
                   | [ ({type:"tool_use", name:$tn, input:remap($tn;$p)} + (if $tcid then {id:$tcid} else {} end)) ]
                 else [] end) ) as $content
            | if ($content|length)==0 then empty
              else
                ( {type:"assistant", message:{role:"assistant", content:$content}, timestamp:$ts} ),
                ( if $tfd and ((($tfd.result)//"")!="") then
                    (if (($tfd.result)|type)=="string" then (try (($tfd.result)|fromjson) catch null) else ($tfd.result) end) as $rj
                    | (if ($rj|type)=="object" then (($rj.output)//($rj.contents)//($rj.result)//($tfd.result)) else ($tfd.result) end) as $rt
                    | {type:"user", message:{role:"user", content:[ ({type:"tool_result", content:(($rt|tostring)[0:4000])} + (if $tcid then {tool_use_id:$tcid} else {} end)) ]}, timestamp:$ts}
                  else empty end )
              end
          end;
      . as $cd
      | ($brows | split("\n") | map(select(length > 0) | split("\t"))) as $rows
      # Build id->bubble. Both key forms normalize to the bare bubble id, so a session
      # carrying BOTH a composer-scoped key and a bare key for the same id must PREFER
      # the scoped row (matching the per-bubble path order). Scoped rows always
      # overwrite; bare rows fill only ids not already present.
      | (reduce $rows[] as $r ({};
          ($r[0]) as $k
          | ($k | sub("^bubbleId:[^:]*:"; "") | sub("^bubbleId:"; "")) as $bid
          | ($k | test("^bubbleId:[^:]+:")) as $scoped
          | if $scoped then .[$bid] = (try ($r[1]|fromjson) catch null)
            elif (.[$bid] == null) then .[$bid] = (try ($r[1]|fromjson) catch null)
            else . end)) as $bmap
      | {composerId:$cid, workspace:$ws, git_remote:$remote, agent_type:"cursor"} as $meta
      | [ ($cd.fullConversationHeadersOnly // [])[]? | .bubbleId | select(. != null) ]
      | [ .[] as $bid | ($bmap[$bid] // null) | select(. != null) | bubble2objs(.) ]
      | if length == 0 then empty
        else (.[0] += {_cursor_meta: $meta}) | .[]
        end
      ' 2>/dev/null || true)

    if [ -n "$session_out" ]; then
      printf '%s\n' "$session_out" >> "$session_file"
      extracted=$((extracted + 1))
    fi
  done < "$sqlite_out"
  rm -f "$sqlite_out"
  rm -f "$output_dir/.cursor_bubbles_dump"

  [ "$extracted" -gt 0 ] && return 0 || return 1
}

# Collect Cursor IDE sessions into the archive tmpdir.
# Discovers all state.vscdb files, extracts sessions matching --since filter,
# and writes canonical JSONL to $tmpdir/_cursor/.
collect_cursor_sessions() {
  local tmpdir="$1"
  local selected_remote="${2:-}"

  # Dependency check. jq gates BOTH sources; sqlite3 gates only the legacy
  # state.vscdb path — the ~/.cursor/projects transcripts are plain JSONL, so
  # a host without sqlite3 (Windows Git Bash) can still read those.
  if ! command -v jq &>/dev/null; then
    echo "  Cursor: jq not found. Install with: brew install jq (macOS), apt install jq (Linux), or winget install jqlang.jq (Windows Git Bash)" >&2
    return 0
  fi
  local _have_sqlite=1
  if ! command -v sqlite3 &>/dev/null; then
    _have_sqlite=0
    if [ -d "$CURSOR_DIR" ] || [ -f "$CURSOR_GLOBAL_DB" ]; then
      if [ -d "${CURSOR_PROJECTS_DIR:-}" ]; then
        echo "  Cursor: sqlite3 not found — reading only ~/.cursor/projects transcripts. For the full history install it: brew install sqlite3 (macOS), apt install sqlite3 (Linux), or winget install sqlite.sqlite (Windows Git Bash)" >&2
      else
        echo "  Cursor: sqlite3 not found. Install with: brew install sqlite3 (macOS), apt install sqlite3 (Linux), or winget install sqlite.sqlite (Windows Git Bash)" >&2
      fi
    fi
  fi

  if [ ! -d "$CURSOR_DIR" ] && [ ! -f "$CURSOR_GLOBAL_DB" ] && [ ! -d "${CURSOR_PROJECTS_DIR:-}" ]; then
    return 0
  fi

  # Warm the workspace map in THIS shell (subshell callers can't persist it)
  # and reset the DB-seen id set for this collection run.
  load_cursor_workspace_map
  _CURSOR_DB_SEEN_IDS="|"

  local cursor_count=0
  local cursor_bytes=0
  local _cursor_errors=0

  # 1. Extract from per-workspace state.vscdb files
  if [ "$_have_sqlite" -eq 1 ] && [ -d "$CURSOR_DIR" ]; then
    while IFS= read -r db_file; do
      [ -z "$db_file" ] && continue
      local _erc=0
      extract_cursor_db "$db_file" "$tmpdir" "$selected_remote" || _erc=$?
      [ "$_erc" -eq 2 ] && _cursor_errors=$((_cursor_errors + 1))
    done < <(find "$CURSOR_DIR" -name "state.vscdb" -maxdepth 2 2>/dev/null)
  fi

  # 2. Extract from globalStorage/state.vscdb (most composer data lives here)
  if [ "$_have_sqlite" -eq 1 ] && [ -f "$CURSOR_GLOBAL_DB" ]; then
    local _erc=0
    extract_cursor_db "$CURSOR_GLOBAL_DB" "$tmpdir" "$selected_remote" || _erc=$?
    [ "$_erc" -eq 2 ] && _cursor_errors=$((_cursor_errors + 1))
  fi

  # 3. Collect ~/.cursor/projects agent transcripts (current Cursor versions
  # stop writing composerData entirely — this is their only source). Runs
  # last so the richer DB extraction wins the per-session-id dedupe.
  collect_cursor_project_transcripts "$tmpdir" "$selected_remote"

  # Count extracted files across all _cursor_* subdirs (main sessions only —
  # subagent files sit deeper than -maxdepth 2)
  cursor_count=$(find "$tmpdir" -maxdepth 2 -path "*/_cursor_*/*.jsonl" 2>/dev/null | wc -l | tr -d ' ')
  if [ "$cursor_count" -gt 0 ]; then
    cursor_bytes=$(find "$tmpdir" -maxdepth 2 -path "*/_cursor_*/*.jsonl" -exec cat {} + 2>/dev/null | wc -c | tr -d ' ')
    local ws_count unattributed_count session_label repo_label unattr_note
    ws_count=$(find "$tmpdir" -maxdepth 1 -type d -name "_cursor_*" ! -name "_cursor_unattributed" 2>/dev/null | wc -l | tr -d ' ')
    unattributed_count=$({ find "$tmpdir/_cursor_unattributed" -maxdepth 1 -name '*.jsonl' 2>/dev/null || true; } | wc -l | tr -d ' ')
    session_label="sessions"
    [ "$cursor_count" -eq 1 ] && session_label="session"
    repo_label="repos"
    [ "$ws_count" -eq 1 ] && repo_label="repo"
    unattr_note=""
    [ "$unattributed_count" -gt 0 ] && unattr_note=", ${unattributed_count} not matched to a repo"
    echo "  Cursor IDE: ${cursor_count} ${session_label} across ${ws_count} ${repo_label}${unattr_note} ($(($cursor_bytes / 1024))KB)" >&2
    # Sessions from the transcripts tree can make the run look clean while a
    # state.vscdb was still unreadable — keep that failure visible (the
    # per-database warnings above carry the detail).
    if [ "$_cursor_errors" -gt 0 ]; then
      echo "  Cursor: ${_cursor_errors} database(s) could not be read — included the ~/.cursor/projects transcripts instead" >&2
    fi

    # Add per-workspace entries to sidecar metadata
    [ ! -f "$tmpdir/_metadata.json" ] && echo '{"directories":{}}' > "$tmpdir/_metadata.json"
    if command -v jq &>/dev/null && [ -f "$tmpdir/_metadata.json" ]; then
      for ws_dir in "$tmpdir"/_cursor_*/; do
        [ -d "$ws_dir" ] || continue
        local bucket_name
        bucket_name=$(basename "$ws_dir")
        local first_file
        first_file=$(find "$ws_dir" -name "*.jsonl" -maxdepth 1 -print -quit 2>/dev/null || true)
        [ -z "$first_file" ] && continue
        local bucket_remote
        bucket_remote=$(head -1 "$first_file" | jq -r '._cursor_meta.git_remote // empty' 2>/dev/null || true)
        local bucket_cwd
        bucket_cwd=$(head -1 "$first_file" | jq -r '._cursor_meta.workspace // empty' 2>/dev/null || true)
        local updated
        updated=$(jq \
          --arg bucket "$bucket_name" \
          --arg remote "${bucket_remote:-}" \
          --arg cwd "${bucket_cwd:-}" \
          '.directories[$bucket] = {"git_remote": $remote, "cwd": $cwd}' \
          "$tmpdir/_metadata.json" 2>/dev/null)
        [ -n "$updated" ] && echo "$updated" > "$tmpdir/_metadata.json"
      done
    fi
  else
    # Clean up empty directories
    rmdir "$tmpdir"/_cursor_* 2>/dev/null || true
  fi

  # If we tried extractions but got zero files, signal failure to caller
  if [ "$cursor_count" -eq 0 ] && [ "$_cursor_errors" -gt 0 ]; then
    echo "  Cursor: extraction failed for $_cursor_errors database(s)" >&2
    return 1
  fi
}

# Collect Codex sessions from $CODEX_DIR (~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl)
# into per-remote buckets at $tmpdir/_codex_<slug>_<hash>/ (or _codex_unattributed/
# for sessions without a repository_url). Writes _metadata.json sidecar entries so
# TranscriptDiscoverer merges each bucket into the Claude project with a matching
# git_remote (one Project per repo, not one per agent).
#
# Signature mirrors collect_cursor_sessions:
#   collect_codex_sessions <output_tmpdir> [selected_remote]
#
# When selected_remote is set (single-project / multi-repo single-child), only
# sessions whose get_codex_session_remote normalizes to selected_remote are
# included — the others belong to different Claude projects and would widen the
# upload's scope beyond what the user asked for.
#
# When selected_remote is empty (--all mode), every Codex session is bucketed by
# its own remote. Sessions without a remote land in _codex_unattributed/.
#
# Reusable from:
#   * run_docker_analysis — produces the dir mounted as /codex_sessions:ro
#     (the container's analyze_local.rake merges _codex_* dirs into
#     transcript_dir, mirroring the Cursor merge).
#   * dev/test archive staging (via collect_all_projects /
#     collect_project_group / collect_single_project) — those paths still
#     have inline Codex logic today; consolidating onto this helper is a
#     separate cleanup (not scoped here to keep the Docker fix minimal).
collect_codex_sessions() {
  local tmpdir="$1"
  local selected_remote="${2:-}"
  # scope_cwd (C6): when set (a no-remote home/parent-dir scoped run) and
  # selected_remote is empty, keep only sessions whose cwd is under scope_cwd —
  # group those by their own recovered remote, and cwd-bucket the remote-less ones.
  local scope_cwd="${3:-}"

  [ -d "$CODEX_DIR" ] || return 0

  local selected_remote_norm=""
  if [ -n "$selected_remote" ]; then
    selected_remote_norm=$(normalize_remote "$selected_remote")
  fi

  local codex_count=0
  while IFS= read -r f; do
    [ -z "$f" ] && continue

    local remote
    remote=$(get_codex_session_remote "$f")
    local scwd=""

    # Scope filter. selected_remote (single specific repo) and scope_cwd (a
    # no-remote dir scope) are alternatives: at most one is set.
    if [ -n "$selected_remote_norm" ]; then
      # Single-project filter: skip sessions whose remote doesn't match.
      local remote_norm
      remote_norm=$(normalize_remote "$remote")
      [ "$remote_norm" != "$selected_remote_norm" ] && continue
    elif [ -n "$scope_cwd" ]; then
      # Scoped no-remote run: keep only sessions whose cwd is under scope_cwd.
      scwd=$(get_codex_session_cwd "$f")
      _paxel_cwd_in_scope "$scwd" "$scope_cwd" || continue
    fi

    # Apply --since filter via file mtime (parity with DRY_RUN archive path
    # at collect_project_group:2616-2620).
    if [ -n "$SINCE_EPOCH" ]; then
      local file_mtime
      file_mtime=$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || echo "0")
      [ "$file_mtime" -lt "$SINCE_EPOCH" ] 2>/dev/null && continue
    fi

    local bucket
    bucket=$(codex_bucket_name "$remote" "$scwd" "$scope_cwd")
    mkdir -p "$tmpdir/$bucket"
    cp "$f" "$tmpdir/$bucket/"
    codex_count=$((codex_count + 1))
  done < <(find "$CODEX_DIR" -name "*.jsonl" -maxdepth 6 2>/dev/null)

  if [ "$codex_count" -eq 0 ]; then
    return 0
  fi

  local repo_bucket_count
  repo_bucket_count=$(find "$tmpdir" -maxdepth 1 -type d -name "_codex_*" -not -name "_codex_unattributed" 2>/dev/null | wc -l | tr -d ' ')
  echo "  Codex: ${codex_count} sessions (${repo_bucket_count} repos)" >&2

  # Write per-bucket sidecar so TranscriptDiscoverer reads git_remote + cwd
  # for each Codex bucket and merges it with the matching Claude project.
  # Without jq, skip silently — the bucketed dirs still ship, but each
  # Codex repo becomes its own Project (graceful degradation).
  command -v jq &>/dev/null || return 0
  [ ! -f "$tmpdir/_metadata.json" ] && echo '{"version":1,"directories":{}}' > "$tmpdir/_metadata.json"
  local bucket_dir
  for bucket_dir in "$tmpdir"/_codex_*/; do
    [ -d "$bucket_dir" ] || continue
    local bname
    bname=$(basename "$bucket_dir")
    local first_file
    first_file=$(find "$bucket_dir" -name "*.jsonl" -maxdepth 1 -print -quit 2>/dev/null || true)
    [ -z "$first_file" ] && continue
    local bremote
    bremote=$(get_codex_session_remote "$first_file")
    local bcwd
    bcwd=$(get_codex_session_cwd "$first_file")
    local updated
    updated=$(jq \
      --arg bucket "$bname" \
      --arg remote "${bremote:-}" \
      --arg cwd "${bcwd:-}" \
      '.directories[$bucket] = {"git_remote": $remote, "cwd": $cwd}' \
      "$tmpdir/_metadata.json" 2>/dev/null)
    [ -n "$updated" ] && echo "$updated" > "$tmpdir/_metadata.json"
  done
}

# Write one opencode-native JSONL file (meta line + message lines) for a single
# opencode session. Shared by extract_opencode_db's top-level and child
# (subagent) passes. Returns 1 (and removes the file) if the meta line fails.
#   args: <db_path> <session_id> <out_file> <directory> <title> <version> <agent> <model_raw> <git_remote>
_opencode_write_session_jsonl() {
  local db_path="$1" sid="$2" out_file="$3" directory="$4" title="$5" version="$6" agent="$7" model_raw="$8" remote="$9"

  # first_prompt = first user text part. JSON paths are escaped (\$) so bash
  # leaves them literal for sqlite. Truncated server-side; title is the
  # server-side fallback when this is empty.
  local first_prompt
  first_prompt=$(sqlite3 "$db_path" "SELECT json_extract(p.data,'\$.text') FROM part p JOIN message m ON p.message_id=m.id WHERE m.session_id='$sid' AND json_extract(m.data,'\$.role')='user' AND json_extract(p.data,'\$.type')='text' ORDER BY m.time_created, p.time_created LIMIT 1" 2>/dev/null || true)
  first_prompt=${first_prompt//$'\r'/}  # Windows sqlite3.exe emits CRLF; $() keeps the \r

  # Informational model string "<providerID>/<id>" from the session model JSON.
  local model=""
  if [ -n "$model_raw" ]; then
    model=$(printf '%s' "$model_raw" | jq -r 'if type=="object" then ((.providerID // "") + "/" + (.id // "")) else "" end' 2>/dev/null || true)
    model="${model#/}"; model="${model%/}"
  fi

  # Line 1: opencode_session_meta marker.
  if ! jq -cn \
    --arg id "$sid" --arg title "$title" --arg fp "${first_prompt}" \
    --arg dir "$directory" --arg remote "${remote:-}" \
    --arg model "$model" --arg agent "$agent" --arg version "$version" \
    '{type:"opencode_session_meta", id:$id, title:$title, first_prompt:($fp[0:1000]), directory:$dir, git_remote:$remote, model:$model, agent:$agent, version:$version}' \
    > "$out_file" 2>/dev/null; then
    rm -f "$out_file"
    return 1
  fi

  # Message lines: one per message, parts inlined with DB time_created (`t`).
  sqlite3 "$db_path" "SELECT json_object('type','opencode_message','message',json(m.data),'parts',(SELECT json_group_array(json_object('t',p.time_created,'p',json(p.data))) FROM part p WHERE p.message_id=m.id)) FROM message m WHERE m.session_id='$sid' ORDER BY m.time_created" >> "$out_file" 2>/dev/null || true
  return 0
}

# Build a SELECT column expression that tolerates opencode session-table columns
# added across versions. opencode grows the session schema over time (agent +
# model landed 2026-05-01 in the "next_venus" migration; metadata 2026-05-11), so
# a SELECT that hard-references a column dies with "no such column: agent" on any
# older DB -> extract_opencode_db returns 2 -> "extraction failed for N
# database(s)" even though the session is perfectly readable. Given a |-delimited
# column list and a column name, emit COALESCE(<name>,<default>) when present,
# else just <default>. See SESSION_DETECTION.md §3d.
_oc_coalesce_col() {
  local cols="$1" name="$2" default="$3"
  case "$cols" in
    *"|$name|"*) printf 'COALESCE(%s,%s)' "$name" "$default" ;;
    *) printf '%s' "$default" ;;
  esac
}

# Extract opencode sessions from a SQLite DB into "opencode-native" JSONL.
# opencode stores sessions relationally (session/message/part tables, content in
# JSON columns), not as JSONL like Claude/Codex. We dump each top-level session
# to one file per bucket: line 1 is an opencode_session_meta marker (drives
# server-side format detection + the discoverer index + the sidecar), then one
# opencode_message line per message with its parts inlined. Each part carries
# its DB time_created as `t`; the server-side OpencodeNormalizer sorts by `t`
# and converts to canonical (SQLite's json_group_array does NOT reliably sort
# aggregate input, so we deliberately do NOT order parts in SQL).
#
# opencode `task`-tool subagents are child sessions (parent_id set). We emit each
# one at <bucket>/<parent_id>/subagents/<child_id>.jsonl — the SAME layout Claude
# subagents use — so TranscriptDiscoverer + find_jsonl link them as is_subagent
# children with ZERO server changes. Children are only emitted when their parent
# top-level session was extracted (its <bucket>/<parent_id>.jsonl exists), which
# keeps --since / --project scoping consistent.
#
# Buckets are keyed by the session's workspace directory (like Cursor), so two
# opencode workspaces in the same repo don't collide; the sidecar maps each
# bucket to a git_remote and the server collapses same-remote buckets into one
# Project. Requires sqlite3 (with JSON1) + jq.
# Return codes: 0 = extracted sessions, 1 = no data (not an error), 2 = real error.
extract_opencode_db() {
  local db_path="$1"
  local output_dir="$2"
  local selected_remote="${3:-}"

  # Validate schema (opencode 1.x: session/message/part tables).
  local tables
  tables=$(sqlite3 "$db_path" ".tables" 2>/dev/null || true)
  if ! echo "$tables" | grep -q "session" || ! echo "$tables" | grep -q "message" || ! echo "$tables" | grep -q "part"; then
    echo "  Warning: $(basename "$db_path") is not a recognized opencode database. Skipping." >&2
    return 2
  fi

  # JSON1 probe — extraction relies on json_object/json_group_array/json().
  local json_ok
  json_ok=$(sqlite3 "$db_path" "SELECT json_valid('{}')" 2>/dev/null || echo "0")
  # Windows sqlite3.exe emits CRLF; without the strip this probe captured
  # "1\r" != "1" and every opencode DB on Windows was skipped with a bogus
  # "lacks JSON support" warning.
  json_ok=${json_ok//$'\r'/}
  if [ "$json_ok" != "1" ]; then
    echo "  Warning: this sqlite3 build lacks JSON support; cannot read opencode data. Skipping." >&2
    return 2
  fi

  # Probe the session table's actual columns so the SELECTs below degrade across
  # opencode schema versions instead of failing whole-DB (see _oc_coalesce_col).
  # opencode adds session columns over time (agent + model arrived 2026-05-01 in
  # the "next_venus" migration); directory/title/version/time_created — and the
  # id/parent_id structural keys — are baseline since its first SQLite schema.
  # Wrapped in leading/trailing '|' for substring membership tests.
  local oc_cols
  oc_cols=$(sqlite3 "$db_path" "SELECT '|'||COALESCE(group_concat(name,'|'),'')||'|' FROM pragma_table_info('session')" 2>/dev/null || true)
  oc_cols=${oc_cols//$'\r'/}  # Windows sqlite3.exe emits CRLF; $() keeps the \r
  if [ -z "$oc_cols" ] || [ "$oc_cols" = "||" ]; then
    echo "  Warning: could not read the opencode session schema from $(basename "$db_path"). Skipping." >&2
    return 2
  fi

  # Resolve each content column against the probe so older DBs (e.g. pre-agent/model)
  # still read. id + parent_id stay hard-referenced as structural invariants, so the
  # top-level vs subagent split below matches count_opencode_sessions exactly.
  local sel_dir sel_title sel_ver sel_agent sel_model sel_tc
  sel_dir=$(_oc_coalesce_col "$oc_cols" directory "''")
  sel_title=$(_oc_coalesce_col "$oc_cols" title "''")
  sel_ver=$(_oc_coalesce_col "$oc_cols" version "''")
  sel_agent=$(_oc_coalesce_col "$oc_cols" agent "''")
  sel_model=$(_oc_coalesce_col "$oc_cols" model "''")
  sel_tc=$(_oc_coalesce_col "$oc_cols" time_created 0)

  local session_count
  session_count=$(sqlite3 "$db_path" "SELECT COUNT(*) FROM session WHERE parent_id IS NULL" 2>/dev/null || echo "0")
  session_count=${session_count//$'\r'/}  # Windows sqlite3.exe emits CRLF; $() keeps the \r
  [ "$session_count" -eq 0 ] 2>/dev/null && return 1

  local selected_remote_norm=""
  [ -n "$selected_remote" ] && selected_remote_norm=$(normalize_remote "$selected_remote")

  # Dump one JSON object per top-level session. Using json_object avoids
  # separator pitfalls with arbitrary directory/title text; model stays raw
  # text (model_raw) for jq to parse below.
  local sqlite_out="$output_dir/.opencode_sessions.$$"
  if ! sqlite3 "$db_path" "SELECT json_object('id',id,'directory',$sel_dir,'title',$sel_title,'version',$sel_ver,'agent',$sel_agent,'model_raw',$sel_model,'time_created',$sel_tc) FROM session WHERE parent_id IS NULL" > "$sqlite_out" 2>/dev/null; then
    echo "  Warning: failed to read opencode sessions from $(basename "$db_path")" >&2
    rm -f "$sqlite_out"
    return 2
  fi

  local extracted=0
  local row
  while IFS= read -r row; do
    [ -z "$row" ] && continue

    local sid directory title version agent model_raw created_ms
    sid=$(printf '%s' "$row" | jq -r '.id // empty' 2>/dev/null || true)
    sid=${sid//$'\r'/}  # jq <1.7 on Windows emits CRLF; a \r here taints the filename
    [ -z "$sid" ] && continue
    directory=$(printf '%s' "$row" | jq -r '.directory // empty' 2>/dev/null || true)
    directory=${directory//$'\r'/}  # a \r fails [ -e ] for a live directory
    title=$(printf '%s' "$row" | jq -r '.title // empty' 2>/dev/null || true)
    version=$(printf '%s' "$row" | jq -r '.version // empty' 2>/dev/null || true)
    agent=$(printf '%s' "$row" | jq -r '.agent // empty' 2>/dev/null || true)
    model_raw=$(printf '%s' "$row" | jq -r '.model_raw // empty' 2>/dev/null || true)
    created_ms=$(printf '%s' "$row" | jq -r '.time_created // 0' 2>/dev/null || echo "0")
    created_ms=${created_ms//$'\r'/}  # a \r here is a FATAL arithmetic error

    # --since filter (createdAt is milliseconds epoch).
    if [ -n "${SINCE_EPOCH:-}" ]; then
      local created_s=$(( created_ms / 1000 )) 2>/dev/null || created_s=0
      [ "$created_s" -lt "$SINCE_EPOCH" ] 2>/dev/null && continue
    fi

    # Resolve remote from the session directory (cwd). Live dir -> get_git_remote;
    # deleted dir -> resolve_remote_for_dead_cwd (ancestor / sibling-worktree
    # walk), then a Conductor dead-workspace cache fallback. Mirrors
    # extract_cursor_db's per-session resolution (see its comment block).
    local session_remote=""
    if [ -n "$directory" ]; then
      if [ -e "$directory" ]; then
        session_remote=$(get_git_remote "$directory")
      else
        session_remote=$(resolve_remote_for_dead_cwd "$directory" || true)
        if [ -z "$session_remote" ]; then
          local _normalized_ws="${directory%/}"
          local _ws_parent=""
          case "$_normalized_ws" in
            */conductor/workspaces/*/*) _ws_parent="${_normalized_ws%/*}" ;;
            */.conductor/*) _ws_parent="${_normalized_ws%%/.conductor/*}/.conductor" ;;
          esac
          if [ -n "$_ws_parent" ]; then
            local _cache_file="${HOME}/.paxel/cache/project-remotes-v2.tsv"
            if [ -f "$_cache_file" ]; then
              local _dir _key _rest _row_cwd
              while IFS=$'\t' read -r _dir _key _rest; do
                [ -z "$_key" ] && continue
                case "$_key" in name:*|local:*|unknown) continue ;; esac
                _row_cwd=$(get_project_cwd "$_dir" 2>/dev/null || true)
                [ -z "$_row_cwd" ] && continue
                if [ "${_row_cwd%/*}" = "$_ws_parent" ]; then
                  session_remote="$_key"
                  break
                fi
              done < "$_cache_file"
            fi
          fi
        fi
      fi
    fi

    # Per-session --project filter.
    if [ -n "$selected_remote_norm" ]; then
      local rn
      rn=$(normalize_remote "$session_remote")
      [ "$rn" != "$selected_remote_norm" ] && continue
    fi

    # Bucket by workspace directory path (md5[:6] keeps same-repo workspaces apart).
    local bucket="_opencode_unattributed"
    if [ -n "$directory" ]; then
      bucket="_opencode_$(basename "$directory")_$(stable_hash6 "$directory")"
    fi
    mkdir -p "$output_dir/$bucket"
    local session_file="$output_dir/$bucket/${sid}.jsonl"
    [ -f "$session_file" ] && continue  # dedupe across multiple DBs

    if _opencode_write_session_jsonl "$db_path" "$sid" "$session_file" "$directory" "$title" "$version" "$agent" "$model_raw" "$session_remote"; then
      extracted=$((extracted + 1))
    fi
  done < "$sqlite_out"
  rm -f "$sqlite_out"

  # Pass 2: child (subagent) sessions, emitted at
  # <bucket>/<parent_id>/subagents/<child_id>.jsonl. A child is bucketed by its
  # own workspace directory (= the parent's, in practice); we only emit it if the
  # parent's top-level file already exists in that bucket (so filtered-out parents
  # don't leave orphan subagents, and grandchildren whose parent is itself a child
  # are skipped). No --since filter on children — they belong to an included parent.
  local child_out="$output_dir/.opencode_children.$$"
  if sqlite3 "$db_path" "SELECT json_object('id',id,'parent_id',COALESCE(parent_id,''),'directory',$sel_dir,'title',$sel_title,'version',$sel_ver,'agent',$sel_agent,'model_raw',$sel_model) FROM session WHERE parent_id IS NOT NULL" > "$child_out" 2>/dev/null; then
    local crow
    while IFS= read -r crow; do
      [ -z "$crow" ] && continue
      local c_sid c_parent c_dir c_title c_ver c_agent c_model_raw
      c_sid=$(printf '%s' "$crow" | jq -r '.id // empty' 2>/dev/null || true)
      c_parent=$(printf '%s' "$crow" | jq -r '.parent_id // empty' 2>/dev/null || true)
      # jq <1.7 on Windows emits CRLF; these three feed paths/filenames.
      c_sid=${c_sid//$'\r'/}; c_parent=${c_parent//$'\r'/}
      [ -z "$c_sid" ] && continue
      [ -z "$c_parent" ] && continue
      c_dir=$(printf '%s' "$crow" | jq -r '.directory // empty' 2>/dev/null || true)
      c_dir=${c_dir//$'\r'/}
      [ -z "$c_dir" ] && continue

      local c_bucket="_opencode_$(basename "$c_dir")_$(stable_hash6 "$c_dir")"
      # Gate on the parent's extracted top-level file existing in this bucket.
      [ -f "$output_dir/$c_bucket/${c_parent}.jsonl" ] || continue

      local sub_dir="$output_dir/$c_bucket/$c_parent/subagents"
      mkdir -p "$sub_dir"
      local child_file="$sub_dir/${c_sid}.jsonl"
      [ -f "$child_file" ] && continue

      c_title=$(printf '%s' "$crow" | jq -r '.title // empty' 2>/dev/null || true)
      c_ver=$(printf '%s' "$crow" | jq -r '.version // empty' 2>/dev/null || true)
      c_agent=$(printf '%s' "$crow" | jq -r '.agent // empty' 2>/dev/null || true)
      c_model_raw=$(printf '%s' "$crow" | jq -r '.model_raw // empty' 2>/dev/null || true)

      # git_remote left empty on children: the discoverer links them to the
      # parent by path, not by remote, so it's unused for subagents.
      if _opencode_write_session_jsonl "$db_path" "$c_sid" "$child_file" "$c_dir" "$c_title" "$c_ver" "$c_agent" "$c_model_raw" ""; then
        extracted=$((extracted + 1))
      fi
    done < "$child_out"
  fi
  rm -f "$child_out"

  [ "$extracted" -gt 0 ] && return 0 || return 1
}

# Collect opencode sessions into the archive/extraction tmpdir. Scans
# OPENCODE_DIR for opencode*.db (or honors an explicit OPENCODE_DB override),
# extracts each, and writes per-bucket sidecar entries so TranscriptDiscoverer
# merges each bucket into the Project with the matching git_remote.
# Signature mirrors collect_cursor_sessions / collect_codex_sessions:
#   collect_opencode_sessions <output_tmpdir> [selected_remote]
collect_opencode_sessions() {
  local tmpdir="$1"
  local selected_remote="${2:-}"

  if ! command -v sqlite3 &>/dev/null; then
    echo "  opencode: sqlite3 not found. Install with: brew install sqlite3 (macOS), apt install sqlite3 (Linux), or winget install sqlite.sqlite (Windows Git Bash)" >&2
    return 0
  fi
  if ! command -v jq &>/dev/null; then
    echo "  opencode: jq not found. Install with: brew install jq (macOS), apt install jq (Linux), or winget install jqlang.jq (Windows Git Bash)" >&2
    return 0
  fi

  # Candidate DBs: a non-empty OPENCODE_DB is AUTHORITATIVE — if it's set we use
  # only it (and warn + bail if it's missing rather than silently scanning the
  # user's real default DBs). Otherwise scan OPENCODE_DIR for every opencode*.db
  # (multi-channel; WAL/shm end in -wal/-shm, not .db).
  local -a dbs=()
  if [ -n "${OPENCODE_DB:-}" ]; then
    if [ -f "${OPENCODE_DB}" ]; then
      dbs+=("$OPENCODE_DB")
    else
      echo "  opencode: OPENCODE_DB set but not found: ${OPENCODE_DB}" >&2
      return 0
    fi
  elif [ -d "$OPENCODE_DIR" ]; then
    local db
    while IFS= read -r db; do
      [ -n "$db" ] && dbs+=("$db")
    done < <(find "$OPENCODE_DIR" -maxdepth 1 -name 'opencode*.db' 2>/dev/null)
  fi
  [ "${#dbs[@]}" -eq 0 ] && return 0

  local _oc_errors=0
  local db
  for db in "${dbs[@]}"; do
    local _erc=0
    extract_opencode_db "$db" "$tmpdir" "$selected_remote" || _erc=$?
    [ "$_erc" -eq 2 ] && _oc_errors=$((_oc_errors + 1))
  done

  local oc_count
  oc_count=$(find "$tmpdir" -maxdepth 2 -path "*/_opencode_*/*.jsonl" 2>/dev/null | wc -l | tr -d ' ')
  if [ "$oc_count" -gt 0 ]; then
    local oc_bytes ws_count
    oc_bytes=$(find "$tmpdir" -maxdepth 2 -path "*/_opencode_*/*.jsonl" -exec cat {} + 2>/dev/null | wc -c | tr -d ' ')
    ws_count=$(find "$tmpdir" -maxdepth 1 -type d -name "_opencode_*" 2>/dev/null | wc -l | tr -d ' ')
    echo "  opencode: ${oc_count} sessions, $(($oc_bytes / 1024))KB (${ws_count} workspaces)" >&2

    [ ! -f "$tmpdir/_metadata.json" ] && echo '{"version":1,"directories":{}}' > "$tmpdir/_metadata.json"
    local ws_dir
    for ws_dir in "$tmpdir"/_opencode_*/; do
      [ -d "$ws_dir" ] || continue
      local bucket_name first_file bremote bcwd updated
      bucket_name=$(basename "$ws_dir")
      first_file=$(find "$ws_dir" -name "*.jsonl" -maxdepth 1 -print -quit 2>/dev/null || true)
      [ -z "$first_file" ] && continue
      bremote=$(head -1 "$first_file" | jq -r '.git_remote // empty' 2>/dev/null || true)
      bcwd=$(head -1 "$first_file" | jq -r '.directory // empty' 2>/dev/null || true)
      updated=$(jq \
        --arg bucket "$bucket_name" \
        --arg remote "${bremote:-}" \
        --arg cwd "${bcwd:-}" \
        '.directories[$bucket] = {"git_remote": $remote, "cwd": $cwd}' \
        "$tmpdir/_metadata.json" 2>/dev/null)
      [ -n "$updated" ] && echo "$updated" > "$tmpdir/_metadata.json"
    done

    # The resolver may have logged dead-cwd recoveries during extraction; keep
    # the sidecar's orphan_recovery_count honest (mirrors collect_cursor_sessions).
    if declare -f _refresh_orphan_recovery_count >/dev/null 2>&1; then
      _refresh_orphan_recovery_count "$tmpdir/_metadata.json"
    fi
  else
    rmdir "$tmpdir"/_opencode_* 2>/dev/null || true
  fi

  if [ "$oc_count" -eq 0 ] && [ "$_oc_errors" -gt 0 ]; then
    echo "  opencode: extraction failed for $_oc_errors database(s)" >&2
    return 1
  fi
  return 0
}

# Count top-level opencode sessions for the time estimate + the single-dir
# zero-session guard. With a selected_remote, counts only sessions whose
# workspace directory resolves to that remote (each distinct directory resolved
# once). Prelude display only — no downstream gate beyond avoiding a false
# "No sessions found" abort for an opencode-only user. Echoes 0 on any problem.
count_opencode_sessions() {
  local selected_remote="${1:-}"
  command -v sqlite3 &>/dev/null || { echo 0; return; }
  command -v jq &>/dev/null || { echo 0; return; }

  # Non-empty OPENCODE_DB is authoritative (kept in sync with
  # collect_opencode_sessions): a set-but-missing override counts 0 rather than
  # scanning the user's real DBs.
  local -a dbs=()
  if [ -n "${OPENCODE_DB:-}" ]; then
    if [ -f "${OPENCODE_DB}" ]; then
      dbs+=("$OPENCODE_DB")
    else
      echo 0; return
    fi
  elif [ -d "$OPENCODE_DIR" ]; then
    local db
    while IFS= read -r db; do
      [ -n "$db" ] && dbs+=("$db")
    done < <(find "$OPENCODE_DIR" -maxdepth 1 -name 'opencode*.db' 2>/dev/null)
  fi
  [ "${#dbs[@]}" -eq 0 ] && { echo 0; return; }

  local sel_norm=""
  [ -n "$selected_remote" ] && sel_norm=$(normalize_remote "$selected_remote")

  # --since filter: mirror extract_opencode_db (time_created is a baseline ms-epoch
  # column). Without it the count over-reports sessions older than --since that the
  # extractor drops, which can make an opencode-only repo wrongly visible/selectable.
  local _oc_since=""
  [ -n "${SINCE_EPOCH:-}" ] && _oc_since="AND time_created >= $((SINCE_EPOCH * 1000))"

  local total=0
  local db
  for db in "${dbs[@]}"; do
    sqlite3 "$db" "SELECT 1 FROM session LIMIT 1" >/dev/null 2>&1 || continue
    if [ -z "$sel_norm" ]; then
      local c
      c=$(sqlite3 "$db" "SELECT COUNT(*) FROM session WHERE parent_id IS NULL $_oc_since" 2>/dev/null || echo 0)
      # Windows-native sqlite3.exe emits CRLF even when piped, and $(...) only
      # strips the trailing \n — an unstripped \r in an arithmetic operand
      # aborts the whole upload via the ERR trap (MINGW64 user report,
      # 2026-07-17). Same reason for the tr in the loop below.
      c=${c//$'\r'/}
      [ -n "$c" ] && total=$((total + c)) || true
    else
      # Resolve each distinct workspace directory once, then add the session
      # count for directories whose remote matches.
      local line dir n remote rn
      while IFS=$'\t' read -r dir n; do
        [ -z "$dir" ] && continue
        if [ -e "$dir" ]; then
          remote=$(get_git_remote "$dir")
        else
          remote=$(resolve_remote_for_dead_cwd "$dir" || true)
        fi
        rn=$(normalize_remote "$remote")
        [ "$rn" = "$sel_norm" ] && total=$((total + n))
      done < <(sqlite3 -separator "$(printf '\t')" "$db" "SELECT directory, COUNT(*) FROM session WHERE parent_id IS NULL AND directory IS NOT NULL AND directory <> '' $_oc_since GROUP BY directory" 2>/dev/null | tr -d '\r')
    fi
  done
  echo "$total"
}

# Copy one Gemini CLI chats/ dir into a bucket, keyed by the real sessionId so the
# discoverer's <parent>/subagents/<child> linking lines up. Reads sessionId via sed
# (no jq/sqlite3 dependency — gemini sessions are plain JSONL we copy verbatim; the
# server GeminiNormalizer does all reconstruction). Returns 0 if anything emitted.
_gemini_extract_chats() {
  local chats_dir="$1"
  local bucket_out="$2"
  [ -d "$chats_dir" ] || return 1
  mkdir -p "$bucket_out"
  local emitted=0

  # Top-level sessions: session-<ISO>-<short>.jsonl. Name the copy by the full
  # sessionId from the header (the filename only carries an 8-char prefix), so the
  # subagent dirs below — named by the parent's full sessionId — match the parent
  # file's basename, which is how TranscriptDiscoverer pairs parent <-> subagent.
  local f sid dest fm
  for f in "$chats_dir"/session-*.jsonl; do
    [ -f "$f" ] || continue
    # --since filter via file mtime (portable: GNU stat -c, then BSD stat -f).
    # Parity with the Codex/Cursor/opencode collectors. Only top-level sessions
    # are filtered; an included parent's subagents come along (the gate below
    # requires the parent's file to exist).
    if [ -n "${SINCE_EPOCH:-}" ]; then
      fm=$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || echo "0")
      [ "$fm" -lt "$SINCE_EPOCH" ] 2>/dev/null && continue
    fi
    sid=$(sed -n '1s/.*"sessionId":"\([^"]*\)".*/\1/p' "$f" 2>/dev/null || true)
    [ -z "$sid" ] && continue  # fail-closed: never emit a stray _gemini_/.jsonl
    dest="$bucket_out/${sid}.jsonl"
    [ -f "$dest" ] && continue  # dedupe across slug dirs
    cp "$f" "$dest" && emitted=$((emitted + 1))
  done

  # Subagents: chats/<parentSessionId>/<childSessionId>.jsonl -> re-laid at
  # <bucket>/<parentSessionId>/subagents/<childSessionId>.jsonl (the Claude layout
  # the discoverer links). Gated on the parent's top-level file existing, so a
  # filtered-out parent leaves no orphan subagents (mirrors extract_opencode_db).
  local pdir parent cf c_sid sub_dir cdest
  for pdir in "$chats_dir"/*/; do
    [ -d "$pdir" ] || continue
    parent=$(basename "$pdir")
    [ -f "$bucket_out/${parent}.jsonl" ] || continue
    sub_dir="$bucket_out/$parent/subagents"
    for cf in "$pdir"*.jsonl; do
      [ -f "$cf" ] || continue
      c_sid=$(sed -n '1s/.*"sessionId":"\([^"]*\)".*/\1/p' "$cf" 2>/dev/null || true)
      [ -z "$c_sid" ] && c_sid=$(basename "$cf" .jsonl)
      [ -z "$c_sid" ] && continue
      mkdir -p "$sub_dir"
      cdest="$sub_dir/${c_sid}.jsonl"
      [ -f "$cdest" ] && continue
      cp "$cf" "$cdest" && emitted=$((emitted + 1))
    done
  done

  [ "$emitted" -gt 0 ] && return 0 || return 1
}

# Write the per-bucket remote into the sidecar so TranscriptDiscoverer merges the
# bucket onto the matching repo Project. jq-OPTIONAL: without jq the sessions still
# upload and analyze — they just attribute to a bucket-named Project instead of
# collapsing onto the git remote (the discoverer's no-sidecar fallback).
_gemini_write_sidecar() {
  local tmpdir="$1" bucket="$2" remote="${3:-}" cwd="${4:-}"
  command -v jq >/dev/null 2>&1 || return 0
  [ ! -f "$tmpdir/_metadata.json" ] && echo '{"version":1,"directories":{}}' > "$tmpdir/_metadata.json"
  local updated
  updated=$(jq --arg bucket "$bucket" --arg remote "$remote" --arg cwd "$cwd" \
    '.directories[$bucket] = {"git_remote": $remote, "cwd": $cwd}' \
    "$tmpdir/_metadata.json" 2>/dev/null)
  [ -n "$updated" ] && echo "$updated" > "$tmpdir/_metadata.json"
}

# Collect Gemini CLI sessions into the archive/extraction tmpdir. Each
# ~/.gemini/tmp/<slug>/ dir is one project (its .project_root names the repo);
# we resolve the remote, bucket as _gemini_<basename>_<hash>, copy sessions +
# subagents, and write a sidecar entry. Signature mirrors collect_opencode_sessions:
#   collect_gemini_sessions <output_tmpdir> [selected_remote]
# No sqlite3/jq hard dependency (extraction is sed/cp).
collect_gemini_sessions() {
  local tmpdir="$1"
  local selected_remote="${2:-}"
  [ -d "$GEMINI_DIR" ] || return 0

  local sel_norm=""
  [ -n "$selected_remote" ] && sel_norm=$(normalize_remote "$selected_remote")

  local slug_dir
  for slug_dir in "$GEMINI_DIR"/*/; do
    [ -d "${slug_dir}chats" ] || continue

    local project_root=""
    [ -f "${slug_dir}.project_root" ] && project_root=$(head -1 "${slug_dir}.project_root" 2>/dev/null || true)
    project_root=${project_root//$'\r'/}  # CRLF-edited file: a \r fails [ -e ]

    # Resolve remote from the project root: live -> get_git_remote, deleted ->
    # ancestor/sibling-worktree recovery (mirrors the SQLite collectors).
    local session_remote=""
    if [ -n "$project_root" ]; then
      if [ -e "$project_root" ]; then
        session_remote=$(get_git_remote "$project_root")
      else
        session_remote=$(resolve_remote_for_dead_cwd "$project_root" || true)
      fi
    fi

    # Per-project filter.
    if [ -n "$sel_norm" ]; then
      local rn
      rn=$(normalize_remote "$session_remote")
      [ "$rn" != "$sel_norm" ] && continue
    fi

    local bucket="_gemini_unattributed"
    [ -n "$project_root" ] && bucket="_gemini_$(basename "$project_root")_$(stable_hash6 "$project_root")"

    _gemini_extract_chats "${slug_dir}chats" "$tmpdir/$bucket" || true

    if [ -n "$(find "$tmpdir/$bucket" -maxdepth 1 -name '*.jsonl' -print -quit 2>/dev/null)" ]; then
      _gemini_write_sidecar "$tmpdir" "$bucket" "$session_remote" "$project_root"
    fi
  done

  local g_count
  g_count=$(find "$tmpdir" -maxdepth 2 -path "*/_gemini_*/*.jsonl" 2>/dev/null | wc -l | tr -d ' ')
  if [ "$g_count" -gt 0 ]; then
    local g_bytes ws_count
    g_bytes=$(find "$tmpdir" -path "*/_gemini_*/*.jsonl" -exec cat {} + 2>/dev/null | wc -c | tr -d ' ')
    ws_count=$(find "$tmpdir" -maxdepth 1 -type d -name "_gemini_*" 2>/dev/null | wc -l | tr -d ' ')
    echo "  Gemini CLI: ${g_count} sessions, $(($g_bytes / 1024))KB (${ws_count} workspaces)" >&2
    if declare -f _refresh_orphan_recovery_count >/dev/null 2>&1; then
      _refresh_orphan_recovery_count "$tmpdir/_metadata.json"
    fi
  else
    rmdir "$tmpdir"/_gemini_* 2>/dev/null || true
  fi
  return 0
}

# Count top-level Gemini sessions for the time estimate + zero-session guard.
# With a selected_remote, counts only slug dirs whose .project_root resolves to it.
# Prelude display only. Echoes 0 on any problem. No jq/sqlite3 needed.
count_gemini_sessions() {
  local selected_remote="${1:-}"
  [ -d "$GEMINI_DIR" ] || { echo 0; return; }

  local sel_norm=""
  [ -n "$selected_remote" ] && sel_norm=$(normalize_remote "$selected_remote")

  local total=0 slug_dir
  for slug_dir in "$GEMINI_DIR"/*/; do
    [ -d "${slug_dir}chats" ] || continue
    if [ -n "$sel_norm" ]; then
      local project_root="" remote rn
      [ -f "${slug_dir}.project_root" ] && project_root=$(head -1 "${slug_dir}.project_root" 2>/dev/null || true)
      project_root=${project_root//$'\r'/}  # CRLF-edited file: a \r fails [ -e ]
      [ -z "$project_root" ] && continue
      if [ -e "$project_root" ]; then
        remote=$(get_git_remote "$project_root")
      else
        remote=$(resolve_remote_for_dead_cwd "$project_root" || true)
      fi
      rn=$(normalize_remote "$remote")
      [ "$rn" != "$sel_norm" ] && continue
    fi
    # Count top-level sessions, honoring --since via file mtime (parity with the
    # extraction filter above, so the estimate matches what actually uploads).
    local c=0 sf fm
    while IFS= read -r sf; do
      [ -z "$sf" ] && continue
      if [ -n "${SINCE_EPOCH:-}" ]; then
        fm=$(stat -c %Y "$sf" 2>/dev/null || stat -f %m "$sf" 2>/dev/null || echo "0")
        [ "$fm" -lt "$SINCE_EPOCH" ] 2>/dev/null && continue
      fi
      c=$((c + 1))
    done < <(find "${slug_dir}chats" -maxdepth 1 -name 'session-*.jsonl' 2>/dev/null)
    total=$((total + c))
  done
  echo "$total"
}

# --- Antigravity (Google) --------------------------------------------------
# Antigravity renders every conversation to a plaintext transcript.jsonl under
# ~/.gemini/<surface>/brain/<uuid>/.system_generated/logs/ and stores attribution
# (workspace URI + captured git remote, both plaintext) in the sibling
# ~/.gemini/<surface>/conversations/<uuid>.db SQLite blob trajectory_metadata_blob.
# We copy the transcript raw with a synthetic antigravity_session_meta line 1; the
# server AntigravityNormalizer does the step->canonical conversion. sqlite3 is
# REQUIRED for attribution (like Cursor/opencode); strings extracts the plaintext
# substrings out of the blob (avoids protobuf decoding).

# Sidecar writer — identical body to _gemini_write_sidecar (jq-optional).
_antigravity_write_sidecar() {
  local tmpdir="$1" bucket="$2" remote="${3:-}" cwd="${4:-}"
  command -v jq >/dev/null 2>&1 || return 0
  [ ! -f "$tmpdir/_metadata.json" ] && echo '{"version":1,"directories":{}}' > "$tmpdir/_metadata.json"
  local updated
  updated=$(jq --arg bucket "$bucket" --arg remote "$remote" --arg cwd "$cwd" \
    '.directories[$bucket] = {"git_remote": $remote, "cwd": $cwd}' \
    "$tmpdir/_metadata.json" 2>/dev/null)
  [ -n "$updated" ] && echo "$updated" > "$tmpdir/_metadata.json"
}

# Read the workspace URI (first file://) + captured git remote out of a
# conversations/<uuid>.db trajectory_metadata_blob. Echoes "<cwd>\t<remote_raw>"
# (either field may be empty). Uses writefile so we read ONLY that blob (the
# whole-db dump would also surface per-step file paths, not the workspace root).
# `tr` splits on the blob's non-printable field separators — deliberately NOT
# `strings`, which is binutils and absent from Windows Git Bash.
_antigravity_db_attribution() {
  local db="$1"
  [ -f "$db" ] || { printf '\t'; return 0; }
  command -v sqlite3 >/dev/null 2>&1 || { printf '\t'; return 0; }
  local blob cwd_uri remote_raw
  blob=$(mktemp 2>/dev/null) || { printf '\t'; return 0; }
  sqlite3 "$db" "SELECT writefile('$blob', data) FROM trajectory_metadata_blob LIMIT 1;" >/dev/null 2>&1 || true
  cwd_uri=$(LC_ALL=C tr -c '[:print:]' '\n' < "$blob" 2>/dev/null | grep -aoE 'file:///[^"[:cntrl:]]+' | head -1 || true)
  remote_raw=$(LC_ALL=C tr -c '[:print:]' '\n' < "$blob" 2>/dev/null | grep -aoE 'git@[^"[:cntrl:] ]+|(https|ssh)://[^"[:cntrl:] ]+' | head -1 || true)
  rm -f "$blob"
  # Trim trailing whitespace: a printable run can still end in a stray space.
  cwd_uri="${cwd_uri%"${cwd_uri##*[![:space:]]}"}"
  printf '%s\t%s' "$(_vscode_decode_folder_uri "$cwd_uri")" "$remote_raw"
}

# Best-effort first_prompt: the first USER_INPUT step's <USER_REQUEST> text.
_antigravity_first_prompt() {
  local transcript="$1"
  grep -m1 '"type":"USER_INPUT"' "$transcript" 2>/dev/null \
    | perl -ne 'print "$1" if /<USER_REQUEST>\\n(.*?)\\n<\/USER_REQUEST>/' 2>/dev/null \
    | cut -c1-200 || true
}

# Fallback workspace when the .db has none (missing/unreadable/no sqlite3): the
# first run_command's Cwd, else the GENERIC "workspace access" note. Both carry the
# absolute workspace root; Cwd args are double-JSON-encoded ("Cwd":"\"/path\"").
_antigravity_transcript_cwd() {
  local transcript="$1" cwd=""
  cwd=$(grep -m1 '"Cwd"' "$transcript" 2>/dev/null \
    | perl -ne 'print "$1" if /"Cwd":"\\"([^\\"]+)\\""/' 2>/dev/null || true)
  if [ -z "$cwd" ]; then
    cwd=$(grep -m1 'read and write access to the following workspace' "$transcript" 2>/dev/null \
      | perl -ne 'print "$1" if /workspace\(s\):\\n- ([^\\"]+)/' 2>/dev/null || true)
  fi
  printf '%s' "$cwd"
}

# Best-effort session model: the first USER_SETTINGS_CHANGE "Model Selection"
# note (e.g. "... from None to Gemini 3.5 Flash (Medium). No need to comment").
# Feeds models_used server-side; empty when the session never records one.
_antigravity_session_model() {
  local transcript="$1"
  grep -m1 'Model Selection' "$transcript" 2>/dev/null \
    | perl -ne 'print "$1" if /changed setting `Model Selection` from .*? to (.+?)\.(?: No need| |\\n)/' 2>/dev/null \
    | cut -c1-100 || true
}

# Collect Antigravity sessions into the archive/extraction tmpdir. Iterates the
# three surface dirs' brain/<uuid> trees, resolves the remote (captured in the .db,
# else from the workspace cwd), buckets as _antigravity_<basename(cwd)>_<hash6>, and
# copies each transcript raw with a synthetic meta line 1.
#   collect_antigravity_sessions <output_tmpdir> [selected_remote]
# sqlite3 required for attribution; without it sessions still upload unattributed.
collect_antigravity_sessions() {
  local tmpdir="$1"
  local selected_remote="${2:-}"
  [ -d "$ANTIGRAVITY_DIR" ] || return 0

  if ! command -v sqlite3 >/dev/null 2>&1; then
    echo "  Antigravity: sqlite3 not found — using transcript-based repo matching (captured git remotes unavailable). For best results install: brew install sqlite3 (macOS), apt install sqlite3 (Linux), or winget install sqlite.sqlite (Windows Git Bash)" >&2
  fi

  local sel_norm=""
  [ -n "$selected_remote" ] && sel_norm=$(normalize_remote "$selected_remote")

  local surface brain_dir uuid transcript db attrib cwd remote_raw session_remote bucket out_file fm
  for surface in antigravity antigravity-ide antigravity-cli; do
    [ -d "$ANTIGRAVITY_DIR/$surface/brain" ] || continue
    for brain_dir in "$ANTIGRAVITY_DIR/$surface/brain"/*/; do
      transcript="${brain_dir}.system_generated/logs/transcript.jsonl"
      [ -f "$transcript" ] || continue
      uuid=$(basename "$brain_dir")
      [ -z "$uuid" ] && continue  # fail-closed: never emit a stray bucket file

      # --since filter via transcript mtime (portable: GNU stat -c, then BSD stat -f).
      if [ -n "${SINCE_EPOCH:-}" ]; then
        fm=$(stat -c %Y "$transcript" 2>/dev/null || stat -f %m "$transcript" 2>/dev/null || echo "0")
        [ "$fm" -lt "$SINCE_EPOCH" ] 2>/dev/null && continue
      fi

      db="$ANTIGRAVITY_DIR/$surface/conversations/${uuid}.db"
      attrib=$(_antigravity_db_attribution "$db")
      cwd="${attrib%%$'\t'*}"
      remote_raw="${attrib#*$'\t'}"
      # No workspace in the .db (missing/unreadable/no sqlite3) -> parse it from the
      # transcript's own tool args so attribution still works.
      [ -z "$cwd" ] && cwd=$(_antigravity_transcript_cwd "$transcript")

      # Prefer the captured remote; else resolve from the workspace cwd (live ->
      # get_git_remote, dead -> resolve_remote_for_dead_cwd + Conductor cache).
      session_remote=""
      if [ -n "$remote_raw" ]; then
        session_remote=$(normalize_remote "$remote_raw")
      elif [ -n "$cwd" ]; then
        if [ -e "$cwd" ]; then
          session_remote=$(get_git_remote "$cwd")
        else
          session_remote=$(resolve_remote_for_dead_cwd "$cwd" || true)
          if [ -z "$session_remote" ]; then
            local _normalized_ws="${cwd%/}" _ws_parent=""
            case "$_normalized_ws" in
              */conductor/workspaces/*/*) _ws_parent="${_normalized_ws%/*}" ;;
              */.conductor/*) _ws_parent="${_normalized_ws%%/.conductor/*}/.conductor" ;;
            esac
            if [ -n "$_ws_parent" ]; then
              local _cache_file="${HOME}/.paxel/cache/project-remotes-v2.tsv"
              if [ -f "$_cache_file" ]; then
                local _dir _key _rest _row_cwd
                while IFS=$'\t' read -r _dir _key _rest; do
                  [ -z "$_key" ] && continue
                  case "$_key" in name:*|local:*|unknown) continue ;; esac
                  _row_cwd=$(get_project_cwd "$_dir" 2>/dev/null || true)
                  [ -z "$_row_cwd" ] && continue
                  if [ "${_row_cwd%/*}" = "$_ws_parent" ]; then
                    session_remote="$_key"
                    break
                  fi
                done < "$_cache_file"
              fi
            fi
          fi
        fi
      fi

      # Per-session --project / selected_remote filter.
      if [ -n "$sel_norm" ]; then
        local rn
        rn=$(normalize_remote "$session_remote")
        [ "$rn" != "$sel_norm" ] && continue
      fi

      bucket="_antigravity_unattributed"
      [ -n "$cwd" ] && bucket="_antigravity_$(basename "$cwd")_$(stable_hash6 "$cwd")"
      mkdir -p "$tmpdir/$bucket"
      out_file="$tmpdir/$bucket/${uuid}.jsonl"
      [ -f "$out_file" ] && continue  # dedupe across surfaces

      local first_prompt session_model
      first_prompt=$(_antigravity_first_prompt "$transcript")
      session_model=$(_antigravity_session_model "$transcript")
      if command -v jq >/dev/null 2>&1; then
        jq -cn --arg id "$uuid" --arg fp "$first_prompt" --arg remote "${session_remote:-}" \
          --arg cwd "${cwd:-}" --arg surface "$surface" --arg model "$session_model" \
          '{type:"antigravity_session_meta", session_id:$id, first_prompt:$fp, model:$model, git_remote:$remote, cwd:$cwd, surface:$surface}' \
          > "$out_file" 2>/dev/null || { rm -f "$out_file"; continue; }
      else
        # jq-free fallback: minimal valid JSON (first_prompt/model omitted to dodge escaping).
        printf '{"type":"antigravity_session_meta","session_id":"%s","first_prompt":"","model":"","git_remote":"%s","cwd":"%s","surface":"%s"}\n' \
          "$uuid" "${session_remote:-}" "${cwd:-}" "$surface" > "$out_file"
      fi
      cat "$transcript" >> "$out_file"
      # Fail-closed: drop a body-less write.
      [ -s "$out_file" ] || { rm -f "$out_file"; continue; }

      _antigravity_write_sidecar "$tmpdir" "$bucket" "$session_remote" "$cwd"
    done
  done

  local a_count
  a_count=$(find "$tmpdir" -maxdepth 2 -path "*/_antigravity_*/*.jsonl" 2>/dev/null | wc -l | tr -d ' ')
  if [ "$a_count" -gt 0 ]; then
    local a_bytes ws_count
    a_bytes=$(find "$tmpdir" -path "*/_antigravity_*/*.jsonl" -exec cat {} + 2>/dev/null | wc -c | tr -d ' ')
    ws_count=$(find "$tmpdir" -maxdepth 1 -type d -name "_antigravity_*" 2>/dev/null | wc -l | tr -d ' ')
    echo "  Antigravity: ${a_count} sessions, $(($a_bytes / 1024))KB (${ws_count} workspaces)" >&2
    if declare -f _refresh_orphan_recovery_count >/dev/null 2>&1; then
      _refresh_orphan_recovery_count "$tmpdir/_metadata.json"
    fi
  else
    rmdir "$tmpdir"/_antigravity_* 2>/dev/null || true
  fi
  return 0
}

# Count Antigravity sessions for the time estimate + zero-session guard. Prelude
# display only; echoes 0 on any problem. sqlite3 only needed for the remote filter.
count_antigravity_sessions() {
  local selected_remote="${1:-}"
  [ -d "$ANTIGRAVITY_DIR" ] || { echo 0; return; }

  local sel_norm=""
  [ -n "$selected_remote" ] && sel_norm=$(normalize_remote "$selected_remote")

  local total=0 surface brain_dir transcript db attrib cwd remote_raw remote rn uuid fm
  local seen_uuids="|"
  for surface in antigravity antigravity-ide antigravity-cli; do
    [ -d "$ANTIGRAVITY_DIR/$surface/brain" ] || continue
    for brain_dir in "$ANTIGRAVITY_DIR/$surface/brain"/*/; do
      transcript="${brain_dir}.system_generated/logs/transcript.jsonl"
      [ -f "$transcript" ] || continue
      # Cross-surface dedupe by uuid (parity with collect's out_file dedupe).
      uuid=$(basename "$brain_dir")
      case "$seen_uuids" in *"|${uuid}|"*) continue ;; esac
      if [ -n "${SINCE_EPOCH:-}" ]; then
        fm=$(stat -c %Y "$transcript" 2>/dev/null || stat -f %m "$transcript" 2>/dev/null || echo "0")
        [ "$fm" -lt "$SINCE_EPOCH" ] 2>/dev/null && continue
      fi
      if [ -n "$sel_norm" ]; then
        db="$ANTIGRAVITY_DIR/$surface/conversations/${uuid}.db"
        attrib=$(_antigravity_db_attribution "$db")
        cwd="${attrib%%$'\t'*}"
        remote_raw="${attrib#*$'\t'}"
        [ -z "$cwd" ] && cwd=$(_antigravity_transcript_cwd "$transcript")
        if [ -n "$remote_raw" ]; then
          remote=$(normalize_remote "$remote_raw")
        elif [ -n "$cwd" ] && [ -e "$cwd" ]; then
          remote=$(get_git_remote "$cwd")
        else
          remote=$(resolve_remote_for_dead_cwd "$cwd" 2>/dev/null || true)
        fi
        rn=$(normalize_remote "$remote")
        [ "$rn" != "$sel_norm" ] && continue
      fi
      seen_uuids="${seen_uuids}${uuid}|"
      total=$((total + 1))
    done
  done
  echo "$total"
}

# Write the per-bucket remote into the sidecar so TranscriptDiscoverer merges the
# bucket onto the matching repo Project. Mirrors _gemini_write_sidecar. jq is
# REQUIRED for vscode extraction overall, so by the time this is called jq exists;
# the guard stays for symmetry + a clean no-op if it somehow doesn't.
_vscode_write_sidecar() {
  local tmpdir="$1" bucket="$2" remote="${3:-}" cwd="${4:-}"
  command -v jq >/dev/null 2>&1 || return 0
  [ ! -f "$tmpdir/_metadata.json" ] && echo '{"version":1,"directories":{}}' > "$tmpdir/_metadata.json"
  local updated
  updated=$(jq --arg bucket "$bucket" --arg remote "$remote" --arg cwd "$cwd" \
    '.directories[$bucket] = {"git_remote": $remote, "cwd": $cwd}' \
    "$tmpdir/_metadata.json" 2>/dev/null)
  [ -n "$updated" ] && echo "$updated" > "$tmpdir/_metadata.json"
}

# Decode a VS Code workspace.json `.folder` URI (a file:// URI) into a filesystem
# path. Strips the file:// scheme, percent-decodes %XX escapes, and turns a
# leading "/c:/Users/.." into "c:/Users/.." on Windows-style drive paths. Echoes
# the decoded path, or empty for a non-file scheme (vscode-remote / ssh-remote)
# or an empty input (which the caller treats as unattributed).
_vscode_decode_folder_uri() {
  local uri="$1"
  uri=${uri//$'\r'/}  # jq <1.7 on Windows emits CRLF; a \r fails [ -e ] downstream
  [ -z "$uri" ] && { echo ""; return; }
  case "$uri" in
    file://*) ;;
    *) echo ""; return ;;  # vscode-remote / ssh-remote / non-file -> unattributed
  esac
  local path="${uri#file://}"
  # Percent-decode %XX escapes (printf %b interprets the \x sequences).
  path=$(printf '%b' "${path//%/\\x}")
  # "/c:/Users/.." (Windows drive path with a leading slash) -> "c:/Users/..".
  case "$path" in
    /[A-Za-z]:/*) path="${path#/}" ;;
  esac
  echo "$path"
}

# Slim one raw VS Code Copilot chatSessions/*.json into the
# vscode_session_meta + vscode_request JSONL the server VscodeCopilotNormalizer
# reads. The jq filter is written once to $tmpdir/_vscode_slim.jq and reused for
# every session (a 93 MB raw -> a few MB slimmed). Requires jq.
#   args: <raw_json> <out_jsonl> <session_id> <git_remote> <cwd> <jq_filter_file>
_vscode_slim_session() {
  local raw_json="$1" out_jsonl="$2" sid="$3" remote="${4:-}" cwd="${5:-}" jq_file="$6"
  jq -c -f "$jq_file" --arg sid "$sid" --arg remote "$remote" --arg cwd "$cwd" \
    "$raw_json" > "$out_jsonl" 2>/dev/null
}

# Collect VS Code Copilot sessions into the archive/extraction tmpdir. Iterates
# the configured workspaceStorage base dirs (VSCODE_DIR is a newline-separated
# list), resolves each <hash>/'s workspace folder from the sibling workspace.json,
# resolves the git remote (live -> get_git_remote, dead -> resolve_remote_for_dead_cwd,
# then the Conductor project-cache fallback like extract_opencode_db), applies
# --since (file mtime) + --project/selected_remote filters, buckets as
# _vscode_<basename>_<hash6> (or _vscode_unattributed), and jq-slims each session.
# Signature mirrors collect_gemini_sessions / collect_opencode_sessions:
#   collect_vscode_copilot_sessions <output_tmpdir> [selected_remote]
# jq is REQUIRED (like Cursor) — without it we print the install hint and skip.
collect_vscode_copilot_sessions() {
  local tmpdir="$1"
  local selected_remote="${2:-}"

  if ! command -v jq &>/dev/null; then
    echo "  VS Code Copilot: jq not found. Install with: brew install jq (macOS), apt install jq (Linux), or winget install jqlang.jq (Windows Git Bash)" >&2
    return 0
  fi

  # Build the candidate base dirs from the newline-separated VSCODE_DIR list.
  local -a bases=()
  local _base
  while IFS= read -r _base; do
    [ -z "$_base" ] && continue
    [ -d "$_base" ] && bases+=("$_base")
  done <<< "$VSCODE_DIR"
  [ "${#bases[@]}" -eq 0 ] && return 0

  local sel_norm=""
  [ -n "$selected_remote" ] && sel_norm=$(normalize_remote "$selected_remote")

  # Write the slim jq filter once and reuse it for every session.
  local jq_file="$tmpdir/_vscode_slim.jq"
  cat > "$jq_file" <<'VSCODE_JQ_EOF'
def result_text($node):
  ( [ ($node // {}) | .. | objects | (.text?, (.value? | select(type == "string"))) | select(. != null and . != "") ]
    | join("\n") ) | .[0:4000];

def slim_args($name):
  ((.arguments // "{}") | (try fromjson catch {}))
  | if type != "object" then {} else . end
  | ( if $name == "apply_patch" and (.input | type) == "string"
      then .input_headers = ( .input | split("\n") | map(select(startswith("*** "))) | join("\n") )
      else . end )
  | ( if $name == "replace_string_in_file" and (has("oldString") or has("newString"))
      then .has_replacement = true else . end )
  | del(.input, .content, .code, .newCode, .content_charset, .oldString, .newString)
  | with_entries( .value |= ( if type == "string" and (length > 4000) then (.[0:4000]) else . end ) );

{ type: "vscode_session_meta",
  session_id: (.sessionId // $sid),
  first_prompt: ( (.requests[0]?.message?.text // "") | tostring | .[0:200] ),
  model: ( .requests[0]?.modelId // "" ),
  agent_id: ( .requests[0]?.result?.metadata?.agentId // "" ),
  git_remote: $remote,
  cwd: $cwd },
( .requests[]? as $req
  | { type: "vscode_request",
      ts: ($req.timestamp // null),
      model: ($req.modelId // ""),
      agent_id: ($req.result?.metadata?.agentId // ""),
      user: ( ($req.message?.text // "") | tostring ),
      thinking: [ $req.response[]? | select(type == "object" and .kind == "thinking") | .value | select(type == "string") ],
      text: ( [ $req.response[]? | select(type == "object" and (has("kind") | not)) | .value | select(type == "string") ] | join("\n") | .[0:8000] ),
      tools: [ $req.result?.metadata?.toolCallRounds[]?.toolCalls[]?
               | { name: .name, id: .id,
                   input: slim_args(.name),
                   result: result_text($req.result.metadata.toolCallResults[.id]) } ] } )
VSCODE_JQ_EOF

  local base hash_dir sessions_dir ws_json folder_uri cwd session_remote bucket sid raw out_file
  for base in "${bases[@]}"; do
    for hash_dir in "$base"/*/; do
      sessions_dir="${hash_dir}chatSessions"
      [ -d "$sessions_dir" ] || continue

      # Resolve the workspace folder from the sibling workspace.json. Multi-root
      # (.workspace), missing, or a non-file scheme -> unattributed (no cwd).
      ws_json="${hash_dir}workspace.json"
      cwd=""
      if [ -f "$ws_json" ]; then
        if [ -n "$(jq -r '.workspace // empty' "$ws_json" 2>/dev/null)" ]; then
          cwd=""  # multi-root workspace -> unattributed
        else
          folder_uri=$(jq -r '.folder // empty' "$ws_json" 2>/dev/null || true)
          cwd=$(_vscode_decode_folder_uri "$folder_uri")
        fi
      fi

      # Resolve remote from the workspace path: live -> get_git_remote; dead ->
      # resolve_remote_for_dead_cwd, then the Conductor project-cache fallback
      # (mirrors extract_opencode_db, since the resolver returns empty for
      # Conductor dead-workspace paths).
      session_remote=""
      if [ -n "$cwd" ]; then
        if [ -e "$cwd" ]; then
          session_remote=$(get_git_remote "$cwd")
        else
          session_remote=$(resolve_remote_for_dead_cwd "$cwd" || true)
          if [ -z "$session_remote" ]; then
            local _normalized_ws="${cwd%/}"
            local _ws_parent=""
            case "$_normalized_ws" in
              */conductor/workspaces/*/*) _ws_parent="${_normalized_ws%/*}" ;;
              */.conductor/*) _ws_parent="${_normalized_ws%%/.conductor/*}/.conductor" ;;
            esac
            if [ -n "$_ws_parent" ]; then
              local _cache_file="${HOME}/.paxel/cache/project-remotes-v2.tsv"
              if [ -f "$_cache_file" ]; then
                local _dir _key _rest _row_cwd
                while IFS=$'\t' read -r _dir _key _rest; do
                  [ -z "$_key" ] && continue
                  case "$_key" in name:*|local:*|unknown) continue ;; esac
                  _row_cwd=$(get_project_cwd "$_dir" 2>/dev/null || true)
                  [ -z "$_row_cwd" ] && continue
                  if [ "${_row_cwd%/*}" = "$_ws_parent" ]; then
                    session_remote="$_key"
                    break
                  fi
                done < "$_cache_file"
              fi
            fi
          fi
        fi
      fi

      # Per-project --project / selected_remote filter.
      if [ -n "$sel_norm" ]; then
        local rn
        rn=$(normalize_remote "$session_remote")
        [ "$rn" != "$sel_norm" ] && continue
      fi

      bucket="_vscode_unattributed"
      [ -n "$cwd" ] && bucket="_vscode_$(basename "$cwd")_$(stable_hash6 "$cwd")"

      for raw in "$sessions_dir"/*.json; do
        [ -f "$raw" ] || continue
        # --since filter via file mtime (portable: GNU stat -c, then BSD stat -f).
        if [ -n "${SINCE_EPOCH:-}" ]; then
          local fm
          fm=$(stat -c %Y "$raw" 2>/dev/null || stat -f %m "$raw" 2>/dev/null || echo "0")
          [ "$fm" -lt "$SINCE_EPOCH" ] 2>/dev/null && continue
        fi
        sid=$(jq -r '.sessionId // empty' "$raw" 2>/dev/null || true)
        sid=${sid//$'\r'/}  # jq <1.7 on Windows emits CRLF; a \r taints the filename
        [ -z "$sid" ] && continue  # fail-closed: never emit a stray _vscode_/.jsonl
        mkdir -p "$tmpdir/$bucket"
        out_file="$tmpdir/$bucket/${sid}.jsonl"
        [ -f "$out_file" ] && continue  # dedupe across base dirs / hash dirs
        if ! _vscode_slim_session "$raw" "$out_file" "$sid" "$session_remote" "$cwd" "$jq_file"; then
          rm -f "$out_file"
          continue
        fi
        # Fail-closed: drop an empty slim (jq produced nothing usable).
        [ -s "$out_file" ] || { rm -f "$out_file"; continue; }
      done

      if [ -n "$(find "$tmpdir/$bucket" -maxdepth 1 -name '*.jsonl' -print -quit 2>/dev/null)" ]; then
        _vscode_write_sidecar "$tmpdir" "$bucket" "$session_remote" "$cwd"
      fi
    done
  done

  rm -f "$jq_file"

  local v_count
  v_count=$(find "$tmpdir" -maxdepth 2 -path "*/_vscode_*/*.jsonl" 2>/dev/null | wc -l | tr -d ' ')
  if [ "$v_count" -gt 0 ]; then
    local v_bytes ws_count
    v_bytes=$(find "$tmpdir" -path "*/_vscode_*/*.jsonl" -exec cat {} + 2>/dev/null | wc -c | tr -d ' ')
    ws_count=$(find "$tmpdir" -maxdepth 1 -type d -name "_vscode_*" 2>/dev/null | wc -l | tr -d ' ')
    echo "  VS Code Copilot: ${v_count} sessions, $(($v_bytes / 1024))KB (${ws_count} workspaces)" >&2
    if declare -f _refresh_orphan_recovery_count >/dev/null 2>&1; then
      _refresh_orphan_recovery_count "$tmpdir/_metadata.json"
    fi
  else
    rmdir "$tmpdir"/_vscode_* 2>/dev/null || true
  fi
  return 0
}

# Count top-level VS Code Copilot sessions for the time estimate + zero-session
# guard. With a selected_remote, counts only workspaces whose resolved folder
# maps to that remote. Prelude display only. Echoes 0 on any problem. A fast
# find over chatSessions/*.json honoring --since (file mtime) — does NOT jq-slim.
count_vscode_copilot_sessions() {
  local selected_remote="${1:-}"
  command -v jq &>/dev/null || { echo 0; return; }

  local -a bases=()
  local _base
  while IFS= read -r _base; do
    [ -z "$_base" ] && continue
    [ -d "$_base" ] && bases+=("$_base")
  done <<< "$VSCODE_DIR"
  [ "${#bases[@]}" -eq 0 ] && { echo 0; return; }

  local sel_norm=""
  [ -n "$selected_remote" ] && sel_norm=$(normalize_remote "$selected_remote")

  local total=0 base hash_dir sessions_dir ws_json folder_uri cwd remote rn raw fm
  for base in "${bases[@]}"; do
    for hash_dir in "$base"/*/; do
      sessions_dir="${hash_dir}chatSessions"
      [ -d "$sessions_dir" ] || continue

      if [ -n "$sel_norm" ]; then
        ws_json="${hash_dir}workspace.json"
        cwd=""
        if [ -f "$ws_json" ]; then
          if [ -z "$(jq -r '.workspace // empty' "$ws_json" 2>/dev/null)" ]; then
            folder_uri=$(jq -r '.folder // empty' "$ws_json" 2>/dev/null || true)
            cwd=$(_vscode_decode_folder_uri "$folder_uri")
          fi
        fi
        [ -z "$cwd" ] && continue
        if [ -e "$cwd" ]; then
          remote=$(get_git_remote "$cwd")
        else
          remote=$(resolve_remote_for_dead_cwd "$cwd" || true)
        fi
        rn=$(normalize_remote "$remote")
        [ "$rn" != "$sel_norm" ] && continue
      fi

      for raw in "$sessions_dir"/*.json; do
        [ -f "$raw" ] || continue
        if [ -n "${SINCE_EPOCH:-}" ]; then
          fm=$(stat -c %Y "$raw" 2>/dev/null || stat -f %m "$raw" 2>/dev/null || echo "0")
          [ "$fm" -lt "$SINCE_EPOCH" ] 2>/dev/null && continue
        fi
        total=$((total + 1))
      done
    done
  done
  echo "$total"
}

# Fallback: read origin URL from a jj workspace when git's standard probe
# can't find it (non-colocated jj checkout with no .git dir).
get_jj_remote() {
  local cwd="$1"
  [ -z "$cwd" ] && echo "" && return
  [ ! -d "$cwd" ] && echo "" && return
  [ ! -d "$cwd/.jj" ] && echo "" && return
  command -v jj >/dev/null 2>&1 || { echo ""; return; }

  local jj_remotes
  jj_remotes=$(jj git remote list --repository "$cwd" 2>/dev/null || true)
  local remote
  remote=$(echo "$jj_remotes" | awk '$1 == "origin" { if ($2 == "<no" && $3 == "URL>") print "<no URL>"; else print $2; exit }')
  [ "$remote" = "<no URL>" ] && echo "" || echo "$remote"
}

# Get canonical git remote URL (passes through normalize_remote below so that
# every caller's grouping key is the same canonical form the server uses in
# Repository.normalize_remote). Falls back to jj when git has no origin.

get_git_remote() {
  local cwd="$1"
  [ -z "$cwd" ] && echo "" && return
  [ ! -d "$cwd" ] && echo "" && return

  local remote
  remote=$(git -C "$cwd" remote get-url origin 2>/dev/null || true)
  if [ -z "$remote" ]; then
    remote=$(get_jj_remote "$cwd")
  fi
  normalize_remote "$remote"
}

# Normalize a git remote URL to the same canonical form the server uses in
# Repository.normalize_remote (app/models/repository.rb). This lets the
# client's exact-string filters (Codex repository_url vs the selected project's
# origin) treat https:// and git@: as the same repo — otherwise a user with
# mixed https/ssh remotes silently loses Codex coverage for their project.
# Port of app/models/repository.rb:16-34. Returns the normalized form, or
# empty string when the input is blank.
normalize_remote() {
  local url="$1"
  [ -z "$url" ] && echo "" && return
  local n="$url"
  # Strip leading/trailing whitespace
  n=$(printf '%s' "$n" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  # Strip ssh:// and http(s):// schemes
  n="${n#ssh://}"
  n="${n#https://}"
  n="${n#http://}"
  # Convert git@host:path -> host/path
  n=$(printf '%s' "$n" | sed 's|^git@\([^:]*\):|\1/|')
  # Strip trailing .git
  n="${n%.git}"
  # Strip trailing /
  n="${n%/}"
  # Strip any remaining leading user@ (e.g. ssh://other-user@host/path after scheme strip)
  n=$(printf '%s' "$n" | sed 's|^[^@/]*@||')
  printf '%s' "$n"
}

# Encode an absolute path the way Claude Code names its project dirs: replace
# BOTH "/" AND "." with "-" (e.g. /Users/a/x70.one -> -Users-a-x70-one). Used by
# Strategy-2 auto-detect to match the current dir against ~/.claude/projects/.
# Matching only "/" silently broke detection for any cwd containing a dot
# (x70.one, qerdp.co.uk, macOS /var/folders/.../T/tmp.X) — see SESSION_DETECTION.md
# §3a. "." is a literal inside the [] bracket expression on BSD + GNU sed.
encode_claude_dir_name() {
  printf '%s' "$1" | sed 's|[/.]|-|g'
}

# Backfill missing remotes for Conductor workspaces by finding siblings.
# Conductor creates worktrees in two path patterns:
#   New: ~/conductor/workspaces/{project}/{workspace}
#   Old: {any_path}/.conductor/{workspace}
# When a workspace is cleaned up, the CWD no longer exists and git remote
# resolution fails. We recover by finding a sibling workspace for the same
# project that DID resolve and reusing its remote.
# Operates on global arrays: _bfc_cwds[], _bfc_remotes[]
# Mutates _bfc_remotes[] in place.
backfill_conductor_remotes() {
  local j=0
  local total=${#_bfc_cwds[@]}
  while [ $j -lt $total ]; do
    if [ -z "${_bfc_remotes[$j]}" ]; then
      local cwd="${_bfc_cwds[$j]}"
      local conductor_pattern=""

      if [[ "$cwd" == */conductor/workspaces/*/* ]]; then
        # New pattern: ~/conductor/workspaces/{project}/*
        conductor_pattern="*/conductor/workspaces/$(echo "$cwd" | sed 's|.*/conductor/workspaces/||; s|/.*||')/*"
      elif [[ "$cwd" == */.conductor/* ]]; then
        # Old pattern: {any_path}/.conductor/*
        local project_root="${cwd%%/.conductor/*}"
        conductor_pattern="${project_root}/.conductor/*"
      fi

      if [ -n "$conductor_pattern" ]; then
        local k=0
        while [ $k -lt $total ]; do
          if [ -n "${_bfc_remotes[$k]}" ] && [[ "${_bfc_cwds[$k]}" == ${conductor_pattern} ]]; then
            _bfc_remotes[$j]="${_bfc_remotes[$k]}"
            _log_recovery_source "$cwd" "conductor-backfill"
            break
          fi
          k=$((k + 1))
        done

        # For new pattern, also check for a non-Conductor dir with the same
        # project name (e.g., ~/infra for conductor/workspaces/infra/*)
        if [ -z "${_bfc_remotes[$j]}" ] && [[ "$cwd" == */conductor/workspaces/*/* ]]; then
          local project_name
          project_name=$(echo "$cwd" | sed 's|.*/conductor/workspaces/||; s|/.*||')
          local k=0
          while [ $k -lt $total ]; do
            if [ -n "${_bfc_remotes[$k]}" ]; then
              local sibling_basename
              sibling_basename=$(basename "${_bfc_cwds[$k]}")
              if [ "$sibling_basename" = "$project_name" ] && [[ "${_bfc_cwds[$k]}" != */conductor/workspaces/* ]]; then
                _bfc_remotes[$j]="${_bfc_remotes[$k]}"
                _log_recovery_source "$cwd" "conductor-backfill"
                break
              fi
            fi
            k=$((k + 1))
          done
        fi

        # For old pattern, also check the project root dir (e.g., ~/code)
        if [ -z "${_bfc_remotes[$j]}" ] && [[ "$cwd" == */.conductor/* ]]; then
          local project_root="${cwd%%/.conductor/*}"
          local k=0
          while [ $k -lt $total ]; do
            if [ -n "${_bfc_remotes[$k]}" ] && [ "${_bfc_cwds[$k]}" = "$project_root" ]; then
              _bfc_remotes[$j]="${_bfc_remotes[$k]}"
              _log_recovery_source "$cwd" "conductor-backfill"
              break
            fi
            k=$((k + 1))
          done
        fi
      fi
    fi
    j=$((j + 1))
  done
}

# Disk-backed dedup log for orphan-cwd recovery activity. The resolver
# runs inside `$(...)` subshells at every call site, so in-memory counters
# and assoc arrays can't survive across invocations. A file append does.
#
# Schema: `<cwd><TAB><source>` per line. `<source>` is one of:
#   ancestor, worktree-list, jj-workspace-list, project-cache,
#   conductor-backfill, unresolvable.
#
# Two readers consume this log:
#   - _rmdc_recovery_count_unique: counts unique cwds for the legacy
#     orphan_recovery_count metric. Filters out `unresolvable` rows
#     so the metric keeps its "successful recoveries" semantics.
#   - _recovery_source_breakdown: emits a per-source CSV for the
#     recovery_breakdown telemetry field (all sources including
#     unresolvable).
#
# Summary line in list_projects_grouped reads unique lines; sidecar
# writes (PR #566) can compute scoped deltas via snapshot-before/after.
# If mktemp fails, the log stays empty and the summary reports 0 — the
# per-recovery stderr lines still fire, so activity is visible.
#
# In the Functions section so bats `extract_functions` picks it up;
# cleanup trap lives at script top-level.
_RMDC_LOG_FILE=""
if _rmdc_tmp=$(mktemp -t paxel_recoveries.XXXXXX 2>/dev/null); then
  _RMDC_LOG_FILE="$_rmdc_tmp"
fi
unset _rmdc_tmp 2>/dev/null || true

# Docker --all sidecar staging path. Computed lazily at call time (not
# at script load) so bats tests that override $HOME after source see the
# correct per-test path. Deterministic $$-naming mirrors the existing
# $$-suffixed tmpdirs at cleanup_temp_dirs:82-86; both the parent shell
# and _docker_all_host_scan_for_recovery's ( ... ) subshell compute the
# same path independently. Tests override via `export
# _DOCKER_ALL_SIDECAR_DIR=...` before calling the helper.
_docker_all_sidecar_dir() {
  printf '%s' "${_DOCKER_ALL_SIDECAR_DIR:-${HOME}/.paxel/cache/docker-all-sidecar-$$}"
}

_jsonl_epoch_bounds() {
  local session_dirs="$1"
  local oldest=""
  local newest=""
  local session_dir
  while IFS= read -r session_dir; do
    [ -d "$session_dir" ] || continue
    local session_file
    while IFS= read -r session_file; do
      local mtime
      mtime=$(stat -c '%Y' "$session_file" 2>/dev/null || stat -f '%m' "$session_file" 2>/dev/null || echo 0)
      [ "$mtime" -gt 0 ] 2>/dev/null || continue
      if [ -n "${SINCE_EPOCH:-}" ] && [ "$mtime" -lt "$SINCE_EPOCH" ] 2>/dev/null; then
        continue
      fi
      if [ -z "$oldest" ] || [ "$mtime" -lt "$oldest" ] 2>/dev/null; then oldest="$mtime"; fi
      if [ -z "$newest" ] || [ "$mtime" -gt "$newest" ] 2>/dev/null; then newest="$mtime"; fi
    done < <(find "$session_dir" -type f \( -name '*.jsonl' -o -name '*.json' \) \
      ! -name '_metadata.json' ! -name 'sessions-index.json' ! -path '*/_git/*' 2>/dev/null)
  done <<< "$session_dirs"
  [ -n "$oldest" ] && printf '%s\t%s\n' "$oldest" "$newest"
}

# `--all` git extraction. Writes aggregate metrics plus repository-keyed author
# commits into the sidecar. The client maps those details back to Projects before
# grouping, so commits never cross repository boundaries.
_docker_all_extract_git_data() {
  local CLAUDE_DIR="$1"
  shift

  local git_out
  git_out="$(_docker_all_sidecar_dir)/_git"
  # mkdir our own _git/ — the recovery scan only creates the sidecar root when
  # jq is present, but git extraction needs no jq.
  mkdir -p "$git_out"

  local candidates="${git_out}/_repositories_candidates.tsv"
  : > "$candidates"
  local proj_dir
  if [ -d "$CLAUDE_DIR" ]; then
    for proj_dir in "$CLAUDE_DIR"/*/; do
      [ -d "$proj_dir" ] || continue
      local pname
      pname=$(basename "$proj_dir")
      local pcwd
      pcwd=$(get_project_cwd "$pname")
      local repo_root
      repo_root=$(git -C "$pcwd" rev-parse --show-toplevel 2>/dev/null || true)
      [ -n "$repo_root" ] || continue
      local premote
      premote=$(get_git_remote "$repo_root")
      local encoded
      encoded=$(repository_git_key "$premote" "$repo_root")
      printf '%s\t%s\t%s\t%s\n' "$encoded" "$premote" "$repo_root" "$proj_dir" >> "$candidates"
    done
  fi

  local source_dir
  for source_dir in "$@"; do
    [ -f "$source_dir/_metadata.json" ] || continue
    command -v jq >/dev/null 2>&1 || continue
    local source_key source_remote source_cwd
    while IFS=$'\t' read -r source_key source_remote source_cwd; do
      source_key=${source_key//$'\r'/}
      source_remote=${source_remote//$'\r'/}
      source_cwd=${source_cwd//$'\r'/}
      # Tab is IFS whitespace, so an EMPTY remote field would collapse and shift
      # cwd into $source_remote; jq emits "-" for a blank remote to keep 3 columns.
      [ "$source_remote" = "-" ] && source_remote=""
      [ -n "$source_cwd" ] || continue
      local repo_root
      repo_root=$(git -C "$source_cwd" rev-parse --show-toplevel 2>/dev/null || true)
      [ -n "$repo_root" ] || continue
      # Sidecar remotes arrive raw (git@…/.git) or blank (e.g. Codex without
      # repository_url); resolve from the live repo like the Claude-dir branch so
      # the key and the manifest carry one normalized form.
      if [ -n "$source_remote" ]; then
        source_remote=$(normalize_remote "$source_remote")
      else
        source_remote=$(get_git_remote "$repo_root")
      fi
      local encoded
      encoded=$(repository_git_key "$source_remote" "$repo_root")
      printf '%s\t%s\t%s\t%s\n' "$encoded" "$source_remote" "$repo_root" "$source_dir/$source_key" >> "$candidates"
    done < <(jq -r '(.directories // {}) | to_entries[] | [.key, ((.value.git_remote // "") | if . == "" then "-" else . end), (.value.cwd // "")] | @tsv' "$source_dir/_metadata.json" 2>/dev/null || true)
  done
  if [ -n "${PAXEL_STORE_STAGE_DIR:-}" ]; then
    paxel_pull_add_author_dirs "$candidates"
  fi

  local manifest="${git_out}/repositories.tsv"
  : > "$manifest"
  local extracted=0
  local encoded
  while IFS= read -r encoded; do
    [ -n "$encoded" ] || continue
    local premote repo_root session_dirs
    premote=$(awk -F '\t' -v key="$encoded" '$1 == key { print $2; exit }' "$candidates")
    repo_root=$(awk -F '\t' -v key="$encoded" '$1 == key { print $3; exit }' "$candidates")
    session_dirs=$(awk -F '\t' -v key="$encoded" '$1 == key { print $4 }' "$candidates")
    local bounds oldest_epoch newest_epoch
    bounds=$(_jsonl_epoch_bounds "$session_dirs" || true)
    oldest_epoch=$(printf '%s' "$bounds" | cut -f1)
    newest_epoch=$(printf '%s' "$bounds" | cut -f2)
    if [ -n "$oldest_epoch" ]; then
      # File mtime is the session's last write, so include the prior day for
      # commits made earlier in a long-running session.
      oldest_epoch=$((oldest_epoch - 86400))
      [ "$oldest_epoch" -lt 0 ] && oldest_epoch=0
      newest_epoch=$((newest_epoch + 86400))
      collect_repository_git_data "$repo_root" "$git_out" "$encoded" "$session_dirs" \
        "$oldest_epoch" "repository_aware" "$newest_epoch"
    else
      collect_repository_git_data "$repo_root" "$git_out" "$encoded" "$session_dirs" "" "aggregate"
    fi
    # Every repo with an origin gets a manifest row, sessions or not, so the
    # summed carrier can still name the repos it covers.
    if [ -n "$premote" ]; then
      printf '%s\t%s\n' "$encoded" "$premote" >> "$manifest"
    fi
    extracted=$((extracted + 1))
  done < <(cut -f1 "$candidates" | sort -u)
  if [ -n "${PAXEL_STORE_STAGE_DIR:-}" ]; then
    paxel_pull_add_store_git "$candidates" "$git_out" "$manifest"
  fi
  rm -f "$candidates"
  if [ ! -s "$manifest" ]; then
    rm -f "$manifest"
  fi

  if [ "$extracted" -gt 0 ]; then
    local _rl="repos"
    [ "$extracted" -eq 1 ] && _rl="repo"
    echo "  Extracted git history from ${extracted} ${_rl}"
  fi
  # Always succeed — a zero-repo result (all dead cwds) must NOT return 1, or the
  # caller's `set -Eeuo pipefail` would fire the ERR trap and abort the upload.
  return 0
}

# Append a recovery-source row to _RMDC_LOG_FILE. Single writer for
# the log; resolver, backfill, project-cache and P1's unresolvable-warning
# all flow through here.
#
# Init-order dependency: _RMDC_LOG_FILE is set at top-level load time
# above. The empty-var guard returns 0 silently if the helper is called
# before init (e.g. when sourced by bats), so tests can pre-set
# _RMDC_LOG_FILE themselves without the mktemp path firing.
#
# Source names must match [a-z_-]+ — downstream CSV/JSON transforms
# split on ':' and ',' and use a hyphen→underscore rewrite. A source
# name containing ':' or ',' silently corrupts the sidecar's
# recovery_breakdown JSON. Keep additions lowercase with hyphens.
_log_recovery_source() {
  local cwd="$1"
  local source="$2"
  [ -z "${_RMDC_LOG_FILE:-}" ] && return 0
  [ -z "$cwd" ] && return 0
  [ -z "$source" ] && return 0
  printf '%s\t%s\n' "$cwd" "$source" >> "$_RMDC_LOG_FILE" 2>/dev/null || true
}

# Record a Conductor dead-cwd that exhausted every attribution strategy
# (resolver short-circuits Conductor paths, sibling walks + ancestor probe
# don't apply, project-cache had no prior row) in this run's unattributed
# log. Closes the §9d support-triage gap documented in
# docs/designs/SESSION_DETECTION.md — without this, the dir's sessions
# silently land under an encoded-name orphan Project, and the recovery
# path (run from a live workspace to warm the cache) is undiscoverable.
# Many deleted workspaces would each print a 5-line block, so the terminal
# gets one _print_unattributed_summary line instead; PAXEL_VERBOSE=1 (or a
# log that can't be written) still prints the blocks.
#
# Mode-neutral phrasing ("re-run this upload") works for both
# `curl | bash` and `bin/upload` invocation paths.
#
# Suppresses entirely under PAXEL_NO_ORPHAN_RECOVERY=1. The project-cache
# fallback that would have populated the cache is also gated on that
# flag, so when the user opts out the cache was never consulted —
# emitting "no cached remote" would misrepresent state. The opt-out is
# a power-user escape hatch; honor "be quiet."
#
# Gated on the Conductor path pattern. Standalone ~/code/foo deletions
# hit the same premote-empty/pcwd-dead shape but are expected to orphan
# silently (encoded_name grouping is working as designed for those).
#
# Logs `<pcwd>\tunresolvable` to _RMDC_LOG_FILE so
# _recovery_source_breakdown includes an `unresolvable` bucket.
_warn_unresolvable_conductor_cwd() {
  [ "${PAXEL_NO_ORPHAN_RECOVERY:-0}" = "1" ] && return 0
  local pname="$1"
  local pcwd="$2"
  case "$pcwd" in
    */conductor/workspaces/*/*|*/.conductor/*) ;;
    *) return 0 ;;
  esac
  _log_recovery_source "$pcwd" "unresolvable"
  if _append_unattributed_log "$pname" "$pcwd" && [ "${PAXEL_VERBOSE:-0}" != "1" ]; then
    return 0
  fi
  echo "[paxel] warning: couldn't attribute ${pname}'s sessions to a repo." >&2
  echo "  cwd: ${pcwd} (deleted)" >&2
  echo "  no cached remote for this project, and no live sibling workspace to" >&2
  echo "  infer from. To recover, re-run this upload from inside a live" >&2
  echo "  workspace of this project." >&2
}

# Set once at load so the scan's ( ... ) subshell and the parent shell
# build the same _unattributed_log_path.
_PAXEL_RUN_STAMP="$(date +%Y%m%d-%H%M%S)"

# Computed at call time, like _docker_all_sidecar_dir, so bats tests that
# set $HOME after source get a per-test path. Directly under ~/.paxel/logs
# so the 14-day sweep at the top of the script removes old ones.
_unattributed_log_path() {
  printf '%s' "${HOME}/.paxel/logs/unattributed-${_PAXEL_RUN_STAMP}.$$.log"
}

# Returns 1 when the log can't be written.
_append_unattributed_log() {
  local pname="$1"
  local pcwd="$2"
  local log_file
  log_file="$(_unattributed_log_path)"
  if [ ! -f "$log_file" ]; then
    mkdir -p "${log_file%/*}" 2>/dev/null || return 1
    { : > "$log_file" && chmod 600 "$log_file"; } 2>/dev/null || return 1
    {
      printf 'Paxel upload, %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
      printf '%s\n' \
        "Deleted Conductor workspaces whose sessions could not be matched to a repo." \
        "There is no cached remote for these projects, and no live sibling workspace" \
        "to infer one from. Their sessions are still analyzed, without repo data." \
        "To recover, re-run this upload from inside a live workspace of the same project." \
        ""
    } >> "$log_file" 2>/dev/null || return 1
  fi
  grep -qxF -- "  cwd: ${pcwd} (deleted)" "$log_file" 2>/dev/null && return 0
  printf '%s\n  cwd: %s (deleted)\n' "$pname" "$pcwd" >> "$log_file" 2>/dev/null || return 1
}

_unattributed_count() {
  local log_file
  log_file="$(_unattributed_log_path)"
  [ -f "$log_file" ] || { echo 0; return 0; }
  grep -c '^  cwd: ' "$log_file" 2>/dev/null || true
}

_print_unattributed_summary() {
  local count log_file
  count="$(_unattributed_count)"
  [ "${count:-0}" -gt 0 ] 2>/dev/null || return 0
  log_file="$(_unattributed_log_path)"
  if [ "$count" -eq 1 ]; then
    echo "[paxel] 1 deleted Conductor workspace could not be matched to a repo. Its sessions are analyzed without repo data. Details: ${log_file}" >&2
  else
    echo "[paxel] ${count} deleted Conductor workspaces could not be matched to a repo. Their sessions are analyzed without repo data. Details: ${log_file}" >&2
  fi
}

# Host-side recovery-detection pass for Docker --all mode. Mirrors the
# detection subset of collect_all_projects's Claude loop (:3220-3262):
# walk $CLAUDE_DIR's encoded project dirs, compute pcwd + try
# get_git_remote, and for dead cwds fall through resolve_remote_for_dead_cwd
# → project-cache fallback → _warn_unresolvable_conductor_cwd.
#
# Scope: detection ONLY. Does NOT write archive sidecars (run_docker_mode
# bind-mounts $CLAUDE_DIR into the container, which reads it directly
# without a sidecar handoff) and does NOT persist cache TSV rows
# (self-warming Docker --all is a separate design question — surprising
# behavior to have bin/upload mutate ~/.paxel/cache without opt-in).
#
# Writes to _RMDC_LOG_FILE via _log_recovery_source only, so the
# env-var passthrough at run_docker_analysis's PAXEL_RECOVERY_BREAKDOWN
# block can forward non-zero counts to the container.
#
# Drift risk: if collect_all_projects's recovery strategies change (new
# source, reordered gates), mirror the change here. Long-term, extract
# a shared detection helper — out of scope for this follow-up.
#
# Runs the detection walk in a ( ... ) subshell so the CLAUDE_DIR
# mutation is scoped — no manual save/restore, and exception-safe
# under set -Eeuo pipefail if a future edit adds a command that can
# trip set -e inside the loop. _RMDC_LOG_FILE writes propagate out of
# the subshell via the filesystem (same pattern as the resolver's
# $(...) callers); stderr warnings propagate via fd inheritance.
#
# Self-warming cache persistence (PR after-#690): every project dir
# (live OR recovered) writes a row to $_cache_rows_file, which is
# merged into ~/.paxel/cache/project-remotes-v2.tsv at the end of the
# scan. This closes the §9d first-run-after-delete gap for Docker
# --all users — a workspace that was live during a prior bin/upload
# is recoverable from the cache after it's deleted, symmetric with
# how legacy --all (collect_all_projects:3376) already warms the
# cache. Row format mirrors collect_all_projects:3371.
_docker_all_host_scan_for_recovery() {
  local claude_dir="${1:-${CLAUDE_DIR:-}}"
  [ -d "$claude_dir" ] || return 0
  # No jq guard: get_project_cwd has grep/JSONL fallbacks (:734, :754),
  # so jq-less hosts still resolve pcwd correctly. Verified by pre-ship
  # review of this change.

  (
    cd "$claude_dir" || return 0
    CLAUDE_DIR="$(pwd)"
    local _cache_rows_file
    _cache_rows_file=$(mktemp)

    # Sidecar for the container's TranscriptDiscoverer.read_sidecar
    # secondary-path fallback. Docker --all bind-mounts $CLAUDE_DIR
    # read-only, so the container has no archive sidecar; we write one
    # here to a host-side staging dir and run_docker_analysis bind-mounts
    # it at /paxel_sidecar:ro. jq-less hosts skip the write (container
    # falls back to encoded_name, same as today — no regression).
    local _sidecar_root="" _sidecar_tmp=""
    if command -v jq &>/dev/null; then
      _sidecar_root="$(_docker_all_sidecar_dir)"
      if mkdir -p "$_sidecar_root" 2>/dev/null; then
        _sidecar_tmp="$_sidecar_root/_metadata.json"
        printf '%s' '{"version":1,"directories":{}}' > "$_sidecar_tmp" 2>/dev/null || _sidecar_tmp=""
      fi
    fi

    local proj_dir pname pcwd premote _p_inferred
    for proj_dir in */; do
      [ -d "$proj_dir" ] || continue
      pname="${proj_dir%/}"
      pcwd=$(get_project_cwd "$pname")
      premote=$(get_git_remote "$pcwd")
      _p_inferred=0
      if [ -z "$premote" ] && [ -n "$pcwd" ] && [ ! -e "$pcwd" ]; then
        # resolve_remote_for_dead_cwd's "[paxel] Recovered remote ..."
        # stderr (ancestor/worktree-list/jj-workspace-list at :1766,
        # :1827, :1850) flows through — Docker --all now attributes
        # sessions end-to-end via the host-written sidecar, so the
        # message is accurate rather than misleading.
        premote=$(resolve_remote_for_dead_cwd "$pcwd" || true)
        [ -n "$premote" ] && _p_inferred=1
        if [ -z "$premote" ] && [ "${PAXEL_NO_ORPHAN_RECOVERY:-0}" != "1" ]; then
          case "$pcwd" in
            */conductor/workspaces/*/*|*/.conductor/*)
              # `|| true` matches resolve_remote_for_dead_cwd's style above
              # for defense-in-depth under set -Eeuo pipefail, even though
              # _project_cache_read_remote can't fail on its current impl.
              premote=$(_project_cache_read_remote "$pname" || true)
              if [ -n "$premote" ]; then
                echo "[paxel] Recovered remote for $pcwd via project-cache($pname) -> $premote" >&2
                _log_recovery_source "$pcwd" "project-cache"
                _p_inferred=1
              fi
              ;;
          esac
        fi
        if [ -z "$premote" ]; then
          _warn_unresolvable_conductor_cwd "$pname" "$pcwd"
        fi
      fi

      # Cache-row skip gates — preserve any existing cached row for this
      # dir when the scan couldn't fully evaluate the current state.
      # Without these, the merge in _project_cache_persist_rows would
      # overwrite a valid warmed remote with an empty one, erasing the
      # only recovery signal available to future runs.
      #
      # 1. Both pcwd + premote empty = no routing signal at all.
      #    Mirrors legacy collect_all_projects:3344's skip, which
      #    continues past this dir entirely.
      # 2. PAXEL_NO_ORPHAN_RECOVERY=1 + empty premote + DEAD cwd =
      #    recovery paths (resolver, cache fallback) were SKIPPED by the
      #    opt-out, so "empty" means "we didn't look" rather than
      #    "verified unresolvable". Writing empty here would clobber
      #    the user's warmed cache. Preserve existing rows.
      #
      #    Gate must be narrow: opt-out + empty premote + LIVE cwd
      #    means get_git_remote DID run and verified the live workspace
      #    has no origin — a legitimate clear-stale-cache case. Keep
      #    writing in that branch (matching the non-opt-out live path).
      #    Legacy collect_all_projects:3438 mirrors this exact gate (PR
      #    #712) so both --all paths converge on the same semantics.
      [ -z "$premote" ] && [ -z "$pcwd" ] && continue
      if [ "${PAXEL_NO_ORPHAN_RECOVERY:-0}" = "1" ] \
          && [ -z "$premote" ] \
          && [ -n "$pcwd" ] \
          && [ ! -e "$pcwd" ]; then
        continue
      fi

      # Record a cache row. Persist empty-remote rows ONLY when we
      # actually verified emptiness (non-opt-out, premote-tried-and-failed)
      # — they clear stale cache entries from a prior live run whose
      # remote has since disappeared; without this, a dir that loses
      # its remote would keep the stale one forever. Mirrors
      # collect_all_projects:3355-3371's row format.
      # BSD find/stat parse leading `-` of encoded Claude dir names
      # (`-Users-...`) as option flags; `./$pname` forces path interpretation.
      local _pd_sessions _pd_mtime
      _pd_sessions=$(find "./$pname" -maxdepth 3 -name "*.jsonl" -not -name "_*" 2>/dev/null | wc -l | tr -d ' ')
      _pd_mtime=$(stat -c %Y "./$pname" 2>/dev/null || stat -f %m "./$pname" 2>/dev/null || echo "0")
      printf '%s\t%s\t%s\t%s\t%s\n' "$pname" "$premote" "${_pd_sessions:-0}" "${_pd_mtime:-0}" "$_p_inferred" >> "$_cache_rows_file"

      # Sidecar entry for TranscriptDiscoverer.read_sidecar fallback.
      # Only write when we resolved a non-empty remote — empty-remote
      # dirs server-side already fall back to encoded_name, which is
      # correct for them. `|| true` on the jq invocation so a stubbed
      # jq (CJ10e) that exits non-zero doesn't abort the scan under
      # set -Eeuo pipefail. Mirrors the legacy sidecar write at :3412.
      if [ -n "$_sidecar_tmp" ] && [ -n "$premote" ]; then
        local _sc_updated
        _sc_updated=$(jq \
          --arg dir "$pname" \
          --arg remote "$premote" \
          --arg cwd "${pcwd:-}" \
          '.directories[$dir] = {"git_remote": $remote, "cwd": $cwd}' \
          "$_sidecar_tmp" 2>/dev/null || true)
        [ -n "$_sc_updated" ] && printf '%s' "$_sc_updated" > "$_sidecar_tmp"
      fi
    done

    # Merge collected rows into the project-remote cache. Same helper
    # collect_all_projects uses at :3376; unconditional of
    # PAXEL_NO_ORPHAN_RECOVERY (that flag gates READS from the cache,
    # not writes — consistent with legacy behavior).
    _project_cache_persist_rows "$_cache_rows_file"
    rm -f "$_cache_rows_file"
  )
}

# Recover a git or jj remote for a session whose cwd no longer exists on
# disk. Used for orphan Claude/Codex/Cursor sessions from deleted
# subdirectories or sibling worktrees. Returns "" on miss; callers decide
# fallback.
#
# Strategies, in order:
#   1. Ancestor walk — if a parent of $cwd is a live git repo (.git
#      present) or pure-jj workspace (.jj/ present), use its remote.
#      Low false-positive risk: a session inside a subdirectory usually
#      belongs to the enclosing repo. Pure-jj matches bypass
#      get_git_remote (which would walk past the marker via git's own
#      discovery) and call get_jj_remote directly, anchoring the lookup.
#   2. Sibling-worktree cross-reference — for stems of $(basename $cwd),
#      check if $parent/$stem is a git repo whose `git worktree list
#      --porcelain` still mentions $cwd. Catches worktrees removed with
#      `rm -rf` before `git worktree prune`. Git-only: jj's workspace
#      list semantics don't plug into this verifier directly.
#
# Conductor paths short-circuit at the top — those are handled by
# backfill_conductor_remotes, which understands fork/branch-specific
# remote semantics the ancestor walk would flatten.
#
# On successful recovery, appends $cwd to $_RMDC_LOG_FILE so callers can
# read a deduped count post-hoc. Counters-in-parent-scope don't work here:
# the resolver is invoked via $(...), which creates a subshell — in-function
# variable mutations don't propagate. A file append does.

# Cross-reference a dead cwd against a sibling jj repo's workspace list.
# Returns 0 if any of the sibling's workspaces has a root path matching the
# dead cwd (either as an on-disk root or via a resolved error-line path for
# a workspace whose dir was rm -rf'd without `jj workspace forget`).
#
# jj's workspace list template has no keyword for the stored relative path —
# `root` resolves it, and errors out inline when the path is missing. The
# error embeds the `../..` form (e.g. `<cand>/.jj/repo/../../../dead-ws`),
# which is bash-normalizable to the canonical path. Covers the
# non-Conductor dead-jj-sibling case: workspace dir deleted via filesystem
# rm, never through `jj workspace forget`. Conductor paths short-circuit at
# the top of `resolve_remote_for_dead_cwd` and route through
# PR #614's `project-remotes-v2.tsv` cache instead — this verifier is not
# reached for `*/conductor/workspaces/*` or `*/.conductor/*` cwds.
#
# Args: $1 = candidate jj repo dir, $2 = original dead cwd, $3 = canonical
# dead cwd. Returns 0/1. Silent on success; prints nothing (caller logs).
_jj_sibling_workspace_match() {
  local cand="$1"
  local cwd="$2"
  local canonical_cwd="$3"

  local out
  out=$(jj workspace list --repository "$cand" -T 'root ++ "\n"' 2>/dev/null) || return 1
  [ -z "$out" ] && return 1

  local line
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    case "$line" in
      /*)
        # Valid root line: exact match against dead cwd wins. (Prefix-matching
        # to catch "dead subdir of live workspace" is already handled by the
        # ancestor walk above, so we don't need it here.)
        if [ "$line" = "$cwd" ] || [ "$line" = "$canonical_cwd" ]; then
          return 0
        fi
        ;;
      *'<Error: Failed to resolve workspace root:'*)
        # Error line format (jj 0.40.x):
        #   <Error: Failed to resolve workspace root: <name>: <abs-path>: <os-err>>
        # Anchor on `: /` (workspace paths are always absolute) instead of
        # counting `: ` separators — jj allows workspace names containing
        # `: ` (e.g. `jj workspace add -n "feat: bugfix" path`), and a
        # separator-count parser drops the tail of the name into the extracted
        # path and produces a non-absolute string that silently misses.
        local raw
        raw=$(printf '%s' "$line" | awk '
          {
            i = index($0, "workspace root: ")
            if (i == 0) next
            rest = substr($0, i + length("workspace root: "))
            sub(/>$/, "", rest)  # trim trailing close-angle
            # Locate the `: ` whose RHS starts with `/` — that is the separator
            # right before the absolute path. Walk from the front; the first
            # occurrence is correct because a workspace name starting with `: /`
            # after a `: ` would itself begin with `/`, which is pathologically
            # rare enough not to worry about here.
            path_start = 0
            for (k = 1; k <= length(rest) - 2; k++) {
              if (substr(rest, k, 2) == ": " && substr(rest, k + 2, 1) == "/") {
                path_start = k + 2
                break
              }
            }
            if (path_start == 0) next
            tail = substr(rest, path_start)
            # The path ends at the FINAL `: ` (the one before the os-err tail).
            # os-err text comes from the std::io::Error Display impl — on Unix
            # it is single-line and has no `: ` inside, so last-match is safe.
            last = 0
            for (k = 1; k <= length(tail) - 1; k++) {
              if (substr(tail, k, 2) == ": ") last = k
            }
            if (last > 0) print substr(tail, 1, last - 1)
          }')
        [ -z "$raw" ] && continue
        local resolved
        resolved=$(_normpath_absolute "$raw")
        [ -z "$resolved" ] && continue
        if [ "$resolved" = "$cwd" ] || [ "$resolved" = "$canonical_cwd" ]; then
          return 0
        fi
        ;;
    esac
  done <<< "$out"
  return 1
}

# Collapse `.` and `..` components in an already-absolute path without
# consulting the filesystem (the target may not exist — the whole point
# of calling this from the jj sibling walk is that jj emits `../..` paths
# for removed workspaces). Returns empty if input isn't absolute.
_normpath_absolute() {
  local input="$1"
  case "$input" in
    /*) ;;
    *) return ;;
  esac
  printf '%s' "$input" | awk -F/ '
    {
      n = 0
      for (i = 1; i <= NF; i++) {
        if ($i == "" || $i == ".") continue
        if ($i == "..") { if (n > 0) n-- ; continue }
        parts[++n] = $i
      }
      if (n == 0) { printf "/" }
      else { for (i = 1; i <= n; i++) printf "/%s", parts[i] }
    }'
}

resolve_remote_for_dead_cwd() {
  local cwd="$1"
  [ -z "$cwd" ] && return 0
  [ -e "$cwd" ] && return 0
  [ "${PAXEL_NO_ORPHAN_RECOVERY:-0}" = "1" ] && return 0

  case "$cwd" in
    */conductor/workspaces/*|*/.conductor/*) return 0 ;;
  esac

  # _rmdc_source tracks which strategy succeeded so the single log
  # write at the function's exit can emit `<cwd>\t<source>`. Scoped
  # to this function's $(...) subshell — the file-append at the exit
  # escapes the subshell via fd inheritance (not via shell variable
  # propagation, which wouldn't work here).
  local recovered=""
  local _rmdc_source=""

  # Strategy 1: Ancestor walk. Matches on .git (dir or file — worktree/submodule
  # marker) or .jj (pure-jj workspace marker).
  #
  # For .git matches, get_git_remote's `git -C <p> remote get-url origin` is
  # repo-discovering and tolerates a .git at $p or at an enclosing ancestor —
  # either way it anchors to an actual git repo root. For .jj-only matches
  # (no .git at $p), get_git_remote would still run git's discovery and could
  # walk PAST $p to an enclosing git repo's origin, silently misattributing a
  # nested-jj-in-git layout. Call get_jj_remote directly for that branch to
  # anchor the lookup at $p.
  local p="$cwd"
  local home_guard="${HOME:-/nonexistent}"
  while :; do
    local _prev_p="$p"
    p="$(dirname "$p")"
    case "$p" in /|.|"$home_guard") break ;; esac
    # Stop at a root where dirname is idempotent: on Windows Git Bash
    # `dirname C:` returns `C:` (there is no leading "/"), so without this guard
    # the walk never reaches "/" and spins forever (PAXEL: aaryansr, Git Bash).
    [ "$p" = "$_prev_p" ] && break
    local r=""
    if [ -d "$p/.git" ] || [ -f "$p/.git" ]; then
      r=$(get_git_remote "$p")
    elif [ -d "$p/.jj" ]; then
      # Pure-jj ancestor: bypass get_git_remote to avoid git's repo-discovery
      # walking past $p. Normalize the raw URL to match the server's canonical
      # form (get_jj_remote does not normalize; get_git_remote does).
      local jj_raw
      jj_raw=$(get_jj_remote "$p")
      [ -n "$jj_raw" ] && r=$(normalize_remote "$jj_raw")
    fi
    if [ -n "$r" ]; then
      recovered="$r"
      _rmdc_source="ancestor"
      echo "[paxel] Recovered remote for $cwd via ancestor $p -> $r" >&2
      break
    fi
  done

  # Strategy 2: Sibling-worktree cross-reference.
  if [ -z "$recovered" ]; then
    local parent base
    parent="$(dirname "$cwd")"
    base="$(basename "$cwd")"
    # Canonicalize so the awk compare survives symlinked home dirs
    # (e.g. /home/x -> /data/x). The parent is still on-disk even when
    # the cwd itself is gone, so `cd && pwd -P` works.
    local canonical_cwd="$cwd"
    if [ -d "$parent" ]; then
      local real_parent
      real_parent=$(cd "$parent" 2>/dev/null && pwd -P 2>/dev/null) || real_parent=""
      [ -n "$real_parent" ] && canonical_cwd="$real_parent/$base"
    fi
    local -a stems=()
    # Digit strip: code1 -> code. %%[0-9]* removes longest trailing-digit run.
    local ds="${base%%[0-9]*}"
    [ -n "$ds" ] && [ "$ds" != "$base" ] && stems+=("$ds")
    # Dash walk: code-frontend-tests -> code-frontend -> code.
    # Longest-first order means a more-specific parent is tried before a
    # less-specific one if both exist (e.g. ~/code-frontend wins over ~/code
    # when the dead cwd is ~/code-frontend-tests).
    local ds2="$base"
    while [[ "$ds2" == *-* ]]; do
      ds2="${ds2%-*}"
      [ -n "$ds2" ] && stems+=("$ds2")
    done
    # Underscore walk: same pattern.
    local ds3="$base"
    while [[ "$ds3" == *_* ]]; do
      ds3="${ds3%_*}"
      [ -n "$ds3" ] && stems+=("$ds3")
    done

    local stem
    for stem in ${stems[@]+"${stems[@]}"}; do
      local cand="$parent/$stem"
      local has_git=0 has_jj=0
      { [ -d "$cand/.git" ] || [ -f "$cand/.git" ]; } && has_git=1
      [ -d "$cand/.jj" ] && has_jj=1
      [ "$has_git" -eq 0 ] && [ "$has_jj" -eq 0 ] && continue

      # Try git worktree list first when .git is present. Match full worktree
      # path, not awk $2 — paths can contain spaces. Compare against both the
      # original cwd and the symlink-resolved form.
      if [ "$has_git" -eq 1 ]; then
        if git -C "$cand" worktree list --porcelain 2>/dev/null \
            | awk -v t1="$cwd" -v t2="$canonical_cwd" '
                /^worktree / { sub(/^worktree /, ""); if ($0 == t1 || $0 == t2) { found=1; exit } }
                END { exit !found }
              '; then
          local r
          r=$(get_git_remote "$cand")
          if [ -n "$r" ]; then
            recovered="$r"
            _rmdc_source="worktree-list"
            echo "[paxel] Recovered remote for $cwd via worktree-list($stem) -> $r" >&2
            break
          fi
        fi
      fi

      # Fall through to jj workspace check when git didn't match. jj 0.40+
      # always creates `.git/` alongside `.jj/` on `jj git init`, so relying
      # on `.git`-absence to route to the jj branch fails in practice. The
      # jj check fires whenever .jj exists AND we haven't already recovered.
      # Covers non-Conductor rm -rf'd jj sibling workspaces: the removed
      # workspace is still in `jj workspace list` output as an inline
      # `<Error: …>` row whose path is bash-normalizable to the dead cwd.
      # Conductor cwds short-circuit above (see :1389-1391) and are handled
      # by PR #614's cache; this branch is unreachable for Conductor paths.
      if [ -z "$recovered" ] && [ "$has_jj" -eq 1 ]; then
        command -v jj >/dev/null 2>&1 || continue
        if _jj_sibling_workspace_match "$cand" "$cwd" "$canonical_cwd"; then
          local r
          r=$(get_jj_remote "$cand")
          if [ -n "$r" ]; then
            recovered=$(normalize_remote "$r")
            _rmdc_source="jj-workspace-list"
            echo "[paxel] Recovered remote for $cwd via jj-workspace-list($stem) -> $recovered" >&2
            break
          fi
        fi
      fi
    done
  fi

  if [ -n "$recovered" ]; then
    # Single write site for the resolver; fd inheritance propagates the
    # append out of the $(...) subshell so callers see a complete log.
    _log_recovery_source "$cwd" "$_rmdc_source"
  fi
  printf '%s' "$recovered"
}

# Count unique recovered cwds logged so far in this run. Preserves the
# legacy "successful recoveries" semantics: rows whose source is
# `unresolvable` (from P1's warning helper) are excluded — those are
# failures, not recoveries, and reporting them as recoveries would
# misrepresent the support-triage metric.
#
# Optional second arg: a previous-snapshot count, in which case we return
# the delta (unique cwds recovered since the snapshot was taken).
_rmdc_recovery_count_unique() {
  local prev="${1:-0}"
  local cur=0
  if [ -n "${_RMDC_LOG_FILE:-}" ] && [ -s "$_RMDC_LOG_FILE" ]; then
    cur=$(awk -F'\t' '$2 != "unresolvable" && !seen[$1]++' "$_RMDC_LOG_FILE" 2>/dev/null | wc -l | tr -d ' ')
  fi
  echo "$((cur - prev))"
}

# Emit a per-source CSV breakdown of recovery activity. Counts unique
# (cwd, source) pairs — since a cwd is resolved via at most one source
# in one run, this matches per-source cwd counts.
#
# Output shape: `ancestor:2,worktree_list:1,project_cache:3,unresolvable:1`
# Zero-count buckets are skipped; the server-side reader
# (ClientPipeline#read_recovery_breakdown) fills defaults for absent
# keys so downstream consumers always see the full 6-key hash.
#
# Hyphen→underscore transform happens inside the awk END block so
# future hyphenated source names (e.g. `docker-bind`) don't need a
# paired sed allowlist update. JSON-friendly keys without the
# character-brittleness of a fixed allowlist.
#
# Emits an empty string when the log is absent/empty — callers
# (_refresh_orphan_recovery_count, Docker env-var fallback) treat that
# as "no recoveries yet" and fall back to defaults.
_recovery_source_breakdown() {
  [ -z "${_RMDC_LOG_FILE:-}" ] && { echo ""; return 0; }
  [ ! -s "$_RMDC_LOG_FILE" ] && { echo ""; return 0; }
  awk -F'\t' '
    !seen[$1]++ { c[$2]++ }
    END {
      first = 1
      for (k in c) {
        key = k
        gsub(/-/, "_", key)
        if (!first) printf ","
        printf "%s:%d", key, c[k]
        first = 0
      }
    }
  ' "$_RMDC_LOG_FILE" 2>/dev/null
}

# Convert a `k1:v1,k2:v2` CSV to a `{"k1":v1,"k2":v2}` JSON object for
# jq --argjson consumption. Returns `{}` when given empty input.
_recovery_breakdown_csv_to_json() {
  local csv="$1"
  if [ -z "$csv" ]; then
    echo "{}"
    return 0
  fi
  printf '%s' "$csv" | awk -F',' '
    {
      printf "{"
      for (i = 1; i <= NF; i++) {
        split($i, kv, ":")
        if (i > 1) printf ","
        printf "\"%s\":%d", kv[1], kv[2]
      }
      printf "}"
    }
  '
}

# Refresh orphan_recovery_count in a sidecar to reflect resolver calls that
# fired AFTER the archive sidecar was initially written. The three archive
# write sites (collect_project_group, prepare_and_run_for_repo, run_docker_mode)
# all emit the counter BEFORE collect_cursor_sessions runs — but extract_cursor_db
# can call resolve_remote_for_dead_cwd for deleted Cursor workspaces, which
# appends to _RMDC_LOG_FILE after the snapshot. Callers invoke this helper
# after every collect_cursor_sessions so the on-disk counter stays honest.
#
# Semantics: aggregate run activity, NOT archive-exact. The resolver logs a
# recovery the moment it fires (inside extract_cursor_db, BEFORE the
# selected_remote filter at :980). Under `--project X`, a mixed Cursor DB
# can recover remotes for sessions that are then filtered out of the
# archive — the counter still increments. Matches the pre-existing comment
# near collect_project_group's initial write.
#
# Idempotent; safe to call with a non-existent sidecar path (no-op when
# the sidecar was never written, e.g. --all Docker mode which skips the
# archive sidecar entirely).
_refresh_orphan_recovery_count() {
  local sidecar="$1"
  [ -f "$sidecar" ] || return 0
  command -v jq &>/dev/null || return 0
  local total
  total=$(_rmdc_recovery_count_unique)
  local breakdown
  breakdown=$(_recovery_source_breakdown)
  local breakdown_json
  breakdown_json=$(_recovery_breakdown_csv_to_json "$breakdown")
  # _recovery_breakdown_csv_to_json always returns a valid JSON object
  # (empty-input path returns {}); no need for a default fallback.
  local updated
  updated=$(jq \
    --argjson r "${total:-0}" \
    --argjson b "$breakdown_json" \
    '.orphan_recovery_count = $r | .recovery_breakdown = $b' \
    "$sidecar" 2>/dev/null)
  [ -n "$updated" ] && printf '%s\n' "$updated" > "$sidecar"
}

# Group project directories by git remote
list_projects_grouped() {
  echo "Scanning projects..." >&2

  # Collect all Claude project dirs with jsonl files
  local all_dirs=()
  if [ -d "$CLAUDE_DIR" ]; then
    for dir in "$CLAUDE_DIR"/*/; do
      [ -d "$dir" ] || continue
      local name
      name=$(basename "$dir")
      local has_jsonl
      # `find -print -quit` SIGPIPEs on first match → ERR trap. Same family
      # as the OLDEST_SESSION_EPOCH fix (PR #389). See find_has_jsonl below.
      has_jsonl=$(find "$dir" -name "*.jsonl" -maxdepth 3 -print -quit 2>/dev/null || true)
      if [ -n "$has_jsonl" ]; then
        all_dirs+=("$name")
      fi
    done
  fi

  # Check for Codex sessions
  local has_codex=0
  if [ -d "$CODEX_DIR" ]; then
    local codex_check
    codex_check=$(find "$CODEX_DIR" -name "*.jsonl" -maxdepth 6 -print -quit 2>/dev/null || true)
    [ -n "$codex_check" ] && has_codex=1
  fi

  # Check for Cursor sessions (workspace DBs, global DB, or agent transcripts)
  local has_cursor=0
  local cursor_check
  if command -v sqlite3 &>/dev/null; then
    if [ -d "$CURSOR_DIR" ]; then
      cursor_check=$(find "$CURSOR_DIR" -name "state.vscdb" -maxdepth 2 -print -quit 2>/dev/null || true)
      [ -n "$cursor_check" ] && has_cursor=1
    fi
    [ -f "$CURSOR_GLOBAL_DB" ] && has_cursor=1
  fi
  # ~/.cursor/projects agent transcripts (current Cursor) need only jq —
  # probe presence unconditionally like VS Code so a missing sqlite3 can't
  # hide them; the tool hint below covers a missing jq.
  if [ "$has_cursor" -eq 0 ] && [ -d "${CURSOR_PROJECTS_DIR:-}" ]; then
    cursor_check=$(find "$CURSOR_PROJECTS_DIR" -maxdepth 4 -path '*/agent-transcripts/*' -name '*.jsonl' -print -quit 2>/dev/null || true)
    [ -n "$cursor_check" ] && has_cursor=1
  fi

  # Check for opencode sessions (any opencode*.db, or the explicit override).
  # Scan-only like Cursor: opencode sessions are upload-bucketed separately, not
  # surfaced as their own picker groups — but their presence must keep the
  # "no projects found" guard from blocking an opencode-only user.
  local has_opencode=0
  if command -v sqlite3 &>/dev/null; then
    if [ -n "${OPENCODE_DB:-}" ] && [ -f "${OPENCODE_DB:-}" ]; then
      has_opencode=1
    elif [ -d "$OPENCODE_DIR" ]; then
      local opencode_check
      opencode_check=$(find "$OPENCODE_DIR" -maxdepth 1 -name 'opencode*.db' -print -quit 2>/dev/null || true)
      [ -n "$opencode_check" ] && has_opencode=1
    fi
  fi

  # Check for Gemini CLI sessions (any chats/session-*.jsonl). Scan-only like
  # opencode — bucketed separately at upload time, but its presence must keep the
  # "no projects found" guard from blocking a Gemini-only user. No sqlite3 needed.
  local has_gemini=0
  if [ -d "$GEMINI_DIR" ]; then
    local gemini_check
    gemini_check=$(find "$GEMINI_DIR" -maxdepth 3 -name 'session-*.jsonl' -print -quit 2>/dev/null || true)
    [ -n "$gemini_check" ] && has_gemini=1
  fi

  # Check for VS Code Copilot sessions (any <hash>/chatSessions/*.json under one of
  # the workspaceStorage base dirs). Scan-only like opencode/Gemini — bucketed
  # separately at upload time, but its presence must keep the "no projects found"
  # guard from blocking a Copilot-only user. Reading the sessions needs jq, but the
  # presence probe is a plain find (so the jq-missing hint below still fires).
  local has_vscode=0
  local _vscode_base
  while IFS= read -r _vscode_base; do
    [ -z "$_vscode_base" ] && continue
    [ -d "$_vscode_base" ] || continue
    local vscode_check
    vscode_check=$(find "$_vscode_base" -maxdepth 2 -path '*/chatSessions/*.json' -print -quit 2>/dev/null || true)
    if [ -n "$vscode_check" ]; then has_vscode=1; break; fi
  done <<< "$VSCODE_DIR"

  # Check for Antigravity sessions (any brain/<uuid>/.../transcript.jsonl under one
  # of the three surface dirs). Plain find (no sqlite3), so its presence keeps the
  # "no projects" guard from blocking an Antigravity-only user + triggers the hint.
  local has_antigravity=0
  if [ -d "$ANTIGRAVITY_DIR" ]; then
    local antigravity_check
    antigravity_check=$(find "$ANTIGRAVITY_DIR"/antigravity*/brain -maxdepth 4 -name 'transcript.jsonl' -print -quit 2>/dev/null || true)
    [ -n "$antigravity_check" ] && has_antigravity=1
  fi

  if [ ${#all_dirs[@]} -eq 0 ] && [ "$has_codex" -eq 0 ] && [ "$has_cursor" -eq 0 ] && [ "$has_opencode" -eq 0 ] && [ "$has_gemini" -eq 0 ] && [ "$has_vscode" -eq 0 ] && [ "$has_antigravity" -eq 0 ]; then
    # Cursor + opencode need host sqlite3 + jq; VS Code Copilot needs jq. Git Bash
    # on Windows bundles neither, so a Cursor/Copilot-only user with the tools
    # missing looks empty here (their probes are gated on sqlite3/jq). Point them at
    # the fix instead of a bare "nothing found" (PAXEL: siddharth, Cursor-only on
    # Windows). has_vscode is a plain find (no jq), so its presence triggers the hint.
    if { [ -d "$CURSOR_DIR" ] || [ -f "$CURSOR_GLOBAL_DB" ] || [ -d "${CURSOR_PROJECTS_DIR:-}" ] || [ -d "$OPENCODE_DIR" ] || [ "$has_vscode" -eq 1 ] || [ "$has_antigravity" -eq 1 ]; } \
       && { ! command -v sqlite3 >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; }; then
      echo "Found Cursor/opencode/VS Code Copilot/Antigravity data but can't read it — sqlite3 and jq are required." >&2
      echo "Install them and re-run: brew install sqlite3 jq (macOS) · sudo apt install sqlite3 jq (Linux) · winget install sqlite.sqlite jqlang.jq (Windows Git Bash)" >&2
    fi
    echo "Error: No projects with transcripts found" >&2
    echo "Checked: $CLAUDE_DIR, $CODEX_DIR, $CURSOR_DIR, ${CURSOR_PROJECTS_DIR:-}, $OPENCODE_DIR, $GEMINI_DIR, $(printf '%s' "$VSCODE_DIR" | tr '\n' ' '), $ANTIGRAVITY_DIR" >&2
    exit 1
  fi

  # Resolve CWD and git remote for each dir
  local dir_cwds=()
  local dir_remotes=()
  for name in "${all_dirs[@]}"; do
    local cwd
    cwd=$(get_project_cwd "$name")
    dir_cwds+=("$cwd")
    local remote
    remote=$(get_git_remote "$cwd")
    dir_remotes+=("$remote")
  done

  # Backfill remotes for deleted Conductor workspaces
  _bfc_cwds=("${dir_cwds[@]}")
  _bfc_remotes=("${dir_remotes[@]}")
  backfill_conductor_remotes
  # Recover remotes for non-Conductor orphan cwds
  # (deleted subdirs of existing repos, sibling worktrees)
  local _bfc_j=0
  while [ $_bfc_j -lt ${#_bfc_cwds[@]} ]; do
    if [ -z "${_bfc_remotes[$_bfc_j]}" ]; then
      local _bfc_recovered
      _bfc_recovered=$(resolve_remote_for_dead_cwd "${_bfc_cwds[$_bfc_j]}")
      [ -n "$_bfc_recovered" ] && _bfc_remotes[$_bfc_j]="$_bfc_recovered"
    fi
    _bfc_j=$((_bfc_j + 1))
  done
  dir_remotes=("${_bfc_remotes[@]}")

  # Group by remote (or cwd for no-remote, or "unknown")
  GROUP_REMOTES=()
  GROUP_DISPLAYS=()
  GROUP_DIRS=()
  GROUP_COUNTS=()
  GROUP_DIR_COUNTS=()

  local i=0
  for name in "${all_dirs[@]}"; do
    local remote="${dir_remotes[$i]}"
    local cwd="${dir_cwds[$i]}"

    # Determine group key
    local group_key
    if [ -n "$remote" ]; then
      group_key="$remote"
    elif [ -n "$cwd" ]; then
      group_key="local:$cwd"
    else
      group_key="unknown"
    fi

    # Determine display name
    local display
    if [ -n "$remote" ]; then
      display=$(remote_display_name "$remote")
    elif [ -n "$cwd" ]; then
      display=$(basename "$cwd")
    else
      display="${name##*-}"
    fi

    # Count sessions in this dir
    local session_count
    session_count=$({ find "$CLAUDE_DIR/$name" -name "*.jsonl" -maxdepth 3 2>/dev/null || true; } | wc -l | tr -d ' ')

    # Find existing group or create new one
    local found=0
    local g=0
    while [ $g -lt ${#GROUP_REMOTES[@]} ]; do
      if [ "${GROUP_REMOTES[$g]}" = "$group_key" ]; then
        GROUP_DIRS[$g]="${GROUP_DIRS[$g]}|$name"
        GROUP_COUNTS[$g]=$((${GROUP_COUNTS[$g]} + $session_count))
        GROUP_DIR_COUNTS[$g]=$((${GROUP_DIR_COUNTS[$g]} + 1))
        found=1
        break
      fi
      g=$((g + 1))
    done

    if [ "$found" -eq 0 ]; then
      GROUP_REMOTES+=("$group_key")
      GROUP_DISPLAYS+=("$display")
      GROUP_DIRS+=("$name")
      GROUP_COUNTS+=("$session_count")
      GROUP_DIR_COUNTS+=("1")
    fi

    i=$((i + 1))
  done

  # Discover Codex sessions and merge into groups by git remote
  if [ "$has_codex" -eq 1 ]; then
    echo "Scanning Codex sessions..." >&2
    while IFS= read -r codex_file; do
      [ -z "$codex_file" ] && continue
      local remote
      remote=$(get_codex_session_remote "$codex_file")
      [ -z "$remote" ] && continue

      # Find existing group by remote or create new one
      local found=0
      local g=0
      while [ $g -lt ${#GROUP_REMOTES[@]} ]; do
        if [ "${GROUP_REMOTES[$g]}" = "$remote" ]; then
          GROUP_COUNTS[$g]=$((${GROUP_COUNTS[$g]} + 1))
          found=1
          break
        fi
        g=$((g + 1))
      done

      if [ "$found" -eq 0 ]; then
        local display
        display=$(remote_display_name "$remote")
        GROUP_REMOTES+=("$remote")
        GROUP_DISPLAYS+=("$display")
        GROUP_DIRS+=("")
        GROUP_COUNTS+=("1")
        GROUP_DIR_COUNTS+=("0")
      fi
    done < <(find "$CODEX_DIR" -name "*.jsonl" -maxdepth 6 2>/dev/null)
  fi

  # Discover Cursor agent-transcript sessions (~/.cursor/projects) and merge
  # into groups by git remote — same shape as the Codex merge above. Legacy
  # state.vscdb sessions stay presence-only (counting them means extracting
  # SQLite bubbles — too slow for the picker), but these transcripts are plain
  # files, so a repo worked ONLY in current Cursor finally shows up as its own
  # group instead of hiding behind the "no projects found" guard.
  if [ -d "${CURSOR_PROJECTS_DIR:-}" ] && command -v jq >/dev/null 2>&1; then
    # Warm the workspace map in THIS shell — the $(...) call below can't
    # persist it, and rebuilding it per project dir is quadratic in jq forks.
    load_cursor_workspace_map
    local _cpt_dir _cpt_at _cpt_ws _cpt_remote _cpt_n
    for _cpt_dir in "$CURSOR_PROJECTS_DIR"/*/; do
      [ -d "$_cpt_dir" ] || continue
      _cpt_at="${_cpt_dir%/}/agent-transcripts"
      [ -d "$_cpt_at" ] || continue
      _cpt_n=$(cursor_project_transcript_count "$_cpt_at")
      [ "$_cpt_n" -gt 0 ] 2>/dev/null || continue
      _cpt_ws=$(cursor_project_dir_to_workspace "$(basename "${_cpt_dir%/}")" || true)
      [ -z "$_cpt_ws" ] && continue
      _cpt_remote=$(cursor_workspace_remote "$_cpt_ws")
      [ -z "$_cpt_remote" ] && continue

      local found=0
      local g=0
      while [ $g -lt ${#GROUP_REMOTES[@]} ]; do
        if [ "${GROUP_REMOTES[$g]}" = "$_cpt_remote" ]; then
          GROUP_COUNTS[$g]=$((${GROUP_COUNTS[$g]} + _cpt_n))
          found=1
          break
        fi
        g=$((g + 1))
      done

      if [ "$found" -eq 0 ]; then
        local display
        display=$(remote_display_name "$_cpt_remote")
        GROUP_REMOTES+=("$_cpt_remote")
        GROUP_DISPLAYS+=("$display")
        GROUP_DIRS+=("")
        GROUP_COUNTS+=("$_cpt_n")
        GROUP_DIR_COUNTS+=("0")
      fi
    done
  fi

  local _rmdc_total
  _rmdc_total=$(_rmdc_recovery_count_unique)
  if [ "${_rmdc_total:-0}" -gt 0 ]; then
    echo "[paxel] Orphan recovery: ${_rmdc_total} dir(s) remapped via ancestor walk or sibling worktree (see '[paxel] Recovered' lines above for detail)" >&2
  fi
}

# Build or refresh the project-remote cache at ~/.paxel/cache/project-remotes-v2.tsv
# Each line: dir_name\tkey\tsession_count\tlatest_mtime
# Only re-resolves dirs whose newest JSONL changed since last cache write.
# After this function, CACHED_KEYS / CACHED_DIRS / CACHED_SESSIONS arrays are populated.
# v2 bumps the cache filename after keys switched from raw git URLs to
# normalized form (normalize_remote / Repository.normalize_remote parity).
# Old v1 rows would under-dedupe until every dir's mtime changed.
CACHED_KEYS=()
CACHED_DIRS=()
CACHED_SESSIONS=()
_cache_loaded=0

load_project_cache() {
  [ "$_cache_loaded" -eq 1 ] && return 0

  local cache_file="${HOME}/.paxel/cache/project-remotes-v2.tsv"
  mkdir -p "${HOME}/.paxel/cache"

  # Step 1: Get current dir listing with mtimes
  local has_cache=0
  [ -f "$cache_file" ] && [ -s "$cache_file" ] && has_cache=1

  if [ "$has_cache" -eq 1 ]; then
    echo "  Checking for new sessions..." >&2
  else
    echo "  Scanning your coding sessions (first run, this may take a minute)..." >&2
  fi

  local dir_list_file
  dir_list_file=$(mktemp)
  local _dcr_total=0
  for dir in "$CLAUDE_DIR"/*/; do
    [ -d "$dir" ] || continue
    _dcr_total=$((_dcr_total + 1))
    local dn
    dn=$(basename "$dir")
    local dm
    dm=$(stat -c %Y "$dir" 2>/dev/null || stat -f %m "$dir" 2>/dev/null || echo "0")
    printf '%s\t%s\n' "$dn" "$dm" >> "$dir_list_file"
  done

  # Step 2: awk joins dir listing against cache in one pass.
  # Outputs HIT lines (cached, mtime matches, non-empty key) and MISS lines
  # (need resolution). Empty-key rows always miss so they self-heal next run:
  # resolution can fail transiently (missing sessions-index.json, queue-only
  # jsonls) and stick forever if we trust them on matching mtime alone, which
  # silently orphans later-populated subpath projects (e.g. ~/code/bookface)
  # from their parent repo group.
  local hit_file miss_file
  hit_file=$(mktemp)
  miss_file=$(mktemp)

  if [ "$has_cache" -eq 1 ]; then
    # Schema: dir<TAB>key<TAB>sessions<TAB>mtime<TAB>inferred.
    # Inferred entries (key came from orphan resolver) always miss so we
    # re-verify: if the ancestor repo or sibling worktree has been removed
    # since the last run, the cached key becomes wrong. Memoization claim
    # (from an earlier revision) was wrong — the resolver runs in a
    # $(...) subshell, so its assoc-array cache dies with the subshell.
    # Every inferred row triggers a fresh ancestor walk each run; that's
    # a few stats + one git call per orphan, tolerable for the common
    # case of <50 orphans.
    # Miss-line format: dir<TAB>mtime<TAB>prior_inferred  (prior_inferred
    # lets the miss-resolution loop preserve the inferred flag on
    # transient misses, so one bad run doesn't permanently detach.)
    awk -F'\t' '
      NR==FNR { cache[$1] = $2 "\t" $3 "\t" $4 "\t" $5; next }
      {
        dir = $1; mtime = $2
        if (dir in cache) {
          split(cache[dir], c, "\t")
          if (c[3] == mtime && c[1] != "" && c[4] != "1") {
            print dir "\t" c[1] "\t" c[2] "\t" mtime "\t" c[4] > "'"$hit_file"'"
          } else {
            print dir "\t" mtime "\t" c[4] > "'"$miss_file"'"
          }
        } else {
          print dir "\t" mtime "\t" > "'"$miss_file"'"
        }
      }
    ' "$cache_file" "$dir_list_file"
  else
    # No cache: everything is a miss with empty prior_inferred.
    awk -F'\t' '{ print $0 "\t" }' "$dir_list_file" > "$miss_file"
  fi

  local hit_count miss_count
  hit_count=$(wc -l < "$hit_file" | tr -d ' ')
  miss_count=$(wc -l < "$miss_file" | tr -d ' ')

  if [ "$miss_count" -gt 0 ] && [ "$hit_count" -gt 0 ]; then
    echo "  ${miss_count} new or changed, ${hit_count} cached." >&2
  fi

  # Step 3: Load all cache hits into CACHED_KEYS/DIRS/SESSIONS
  local new_cache=""
  while IFS=$'\t' read -r _cn _ck _cs _cm _ci; do
    [ -z "$_cn" ] && continue
    new_cache="${new_cache}${_cn}	${_ck}	${_cs}	${_cm}	${_ci}
"
    [ -z "$_ck" ] || [ "${_cs:-0}" -le 0 ] 2>/dev/null && continue
    local found=0
    local k=0
    while [ $k -lt ${#CACHED_KEYS[@]} ]; do
      if [ "${CACHED_KEYS[$k]}" = "$_ck" ]; then
        CACHED_DIRS[$k]="${CACHED_DIRS[$k]}|$_cn"
        CACHED_SESSIONS[$k]=$((${CACHED_SESSIONS[$k]} + _cs))
        found=1
        break
      fi
      k=$((k + 1))
    done
    if [ "$found" -eq 0 ]; then
      CACHED_KEYS+=("$_ck")
      CACHED_DIRS+=("$_cn")
      CACHED_SESSIONS+=("$_cs")
    fi
  done < "$hit_file"

  # Step 4: Resolve only the misses (new or changed dirs)
  local _miss_i=0
  while IFS=$'\t' read -r dir_name dir_mtime prior_inferred; do
    [ -z "$dir_name" ] && continue
    _miss_i=$((_miss_i + 1))
    if [ $((_miss_i % 200)) -eq 0 ]; then
      echo "  ...${_miss_i}/${miss_count} resolved" >&2
    fi

    local dir="$CLAUDE_DIR/$dir_name"
    local has_jsonl
    # `find -print -quit` SIGPIPEs on first match → ERR trap. Same family
    # as the OLDEST_SESSION_EPOCH fix (PR #389).
    has_jsonl=$(find "$dir" -name "*.jsonl" -maxdepth 3 -print -quit 2>/dev/null || true)
    if [ -z "$has_jsonl" ]; then
      new_cache="${new_cache}${dir_name}		0	${dir_mtime}
"
      continue
    fi

    local cwd
    cwd=$(get_project_cwd "$dir_name")
    local remote
    remote=$(get_git_remote "$cwd")
    # Recover orphan remote BEFORE key assignment — otherwise
    # deleted-subdir cwds fall into name:<basename> at line ~1342 and
    # resolver never fires for the cached-run hot path.
    # _inferred="1" on a successful recovery so the cache re-verifies this
    # row next run (inferred rows always miss the awk hit predicate).
    # Preserves the inferred flag on a transient miss (prior_inferred=1 +
    # new resolve returns empty) so one bad run doesn't permanently detach
    # the session from its real repo.
    local _inferred=""
    if [ -z "$remote" ] && [ -n "$cwd" ] && [ ! -e "$cwd" ]; then
      remote=$(resolve_remote_for_dead_cwd "$cwd")
      if [ -n "$remote" ]; then
        _inferred="1"
      elif [ "${prior_inferred:-}" = "1" ]; then
        # Transient miss (e.g. --no-orphan-recovery, or filesystem hiccup).
        # Keep the row flagged so we retry next run.
        _inferred="1"
      fi
    fi

    local key=""
    if [ -n "$remote" ]; then
      key="$remote"
    elif [ -n "$cwd" ] && [ -d "$cwd" ]; then
      key="local:$cwd"
    elif [ -n "$cwd" ]; then
      local _proj_name=""
      if [[ "$cwd" == */conductor/workspaces/*/* ]]; then
        _proj_name=$(echo "$cwd" | sed 's|.*/conductor/workspaces/||' | sed 's|/.*||')
      elif [[ "$cwd" != */.gstack/* ]] && [[ "$cwd" != */.claude/* ]]; then
        _proj_name=$(basename "$cwd")
      fi
      [ -n "$_proj_name" ] && key="name:$_proj_name"
    fi

    if [ -z "$key" ]; then
      new_cache="${new_cache}${dir_name}		0	${dir_mtime}
"
      continue
    fi

    local session_count
    session_count=$({ find "$dir" -name "*.jsonl" -not -name "_*" -not -path "*/_git/*" -not -path "*/subagents/*" -maxdepth 3 2>/dev/null || true; } | wc -l | tr -d ' ')

    new_cache="${new_cache}${dir_name}	${key}	${session_count}	${dir_mtime}	${_inferred}
"

    if [ -n "$key" ] && [ "$session_count" -gt 0 ]; then
      local found=0
      local k=0
      while [ $k -lt ${#CACHED_KEYS[@]} ]; do
        if [ "${CACHED_KEYS[$k]}" = "$key" ]; then
          CACHED_DIRS[$k]="${CACHED_DIRS[$k]}|$dir_name"
          CACHED_SESSIONS[$k]=$((${CACHED_SESSIONS[$k]} + session_count))
          found=1
          break
        fi
        k=$((k + 1))
      done
      if [ "$found" -eq 0 ]; then
        CACHED_KEYS+=("$key")
        CACHED_DIRS+=("$dir_name")
        CACHED_SESSIONS+=("$session_count")
      fi
    fi
  done < "$miss_file"

  # Step 5: Write updated cache and clean up
  printf '%s' "$new_cache" > "$cache_file"
  rm -f "$dir_list_file" "$hit_file" "$miss_file"
  _cache_loaded=1

  if [ "$miss_count" -eq 0 ]; then
    echo "  All sessions cached, ready to go." >&2
  else
    local _total_sess=0
    local _si=0
    while [ $_si -lt ${#CACHED_SESSIONS[@]} ]; do
      _total_sess=$((_total_sess + ${CACHED_SESSIONS[$_si]}))
      _si=$((_si + 1))
    done
    local _repo_list=""
    local _ri=0
    while [ $_ri -lt ${#CACHED_KEYS[@]} ]; do
      [ -n "$_repo_list" ] && _repo_list="${_repo_list}, "
      _repo_list="${_repo_list}$(remote_display_name "${CACHED_KEYS[$_ri]}")"
      _ri=$((_ri + 1))
    done
    # This count is Claude Code only — CACHED_* never holds Codex/Cursor/opencode/
    # Gemini. For a Codex/opencode-only user it would otherwise print a misleading
    # "Resolved 0 sessions across 0 repos" before those tools are even scanned, so
    # suppress the line entirely when there are no Claude repos and let the
    # per-tool scans speak; otherwise label it as Claude-specific.
    if [ "${#CACHED_KEYS[@]}" -gt 0 ]; then
      echo "  Resolved ${_total_sess} Claude Code sessions across ${#CACHED_KEYS[@]} repos: ${_repo_list}" >&2
    fi
  fi
}

# Detect child git repos in the current directory that have transcript data.
# Populates CHILD_REPO_* parallel arrays. Returns 0 if any repos found.
detect_child_repos() {
  local current_dir
  current_dir=$(pwd)

  # Build/refresh the project cache (fast on subsequent runs)
  load_project_cache

  # Use cached data as t_keys/t_dirs/t_sessions. Use the empty-safe expansion
  # idiom (cf. :2494): on macOS's default bash 3.2, copying an empty array via
  # `("${CACHED_KEYS[@]}")` aborts under `set -u` ("unbound variable"), which
  # crashed detect_child_repos for any user with no Claude cache (Codex/opencode-
  # only). The `[@]+"..."` form yields a genuinely-empty array (NOT `("${a[@]:-}")`,
  # which on 3.2 yields a 1-element "" array → a spurious downstream child_key).
  local t_keys=("${CACHED_KEYS[@]+"${CACHED_KEYS[@]}"}")
  local t_dirs=("${CACHED_DIRS[@]+"${CACHED_DIRS[@]}"}")
  local t_sessions=("${CACHED_SESSIONS[@]+"${CACHED_SESSIONS[@]}"}")

  # Pre-compute Codex session remotes (key → pipe-separated file paths).
  # Phase 3.5 — track cross-tool subset alongside total count so the picker
  # can label "(N sessions, M Codex by Claude)" per child repo.
  local codex_keys=()
  local codex_file_lists=()
  local codex_counts=()
  local codex_cross_tool_counts=()
  if [ -d "$CODEX_DIR" ]; then
    while IFS= read -r codex_file; do
      [ -z "$codex_file" ] && continue
      local remote
      remote=$(get_codex_session_remote "$codex_file")
      [ -z "$remote" ] && continue

      local _origin
      _origin=$(get_codex_session_originator "$codex_file")
      local _is_cross_tool=0
      codex_originator_is_standalone "$_origin" || _is_cross_tool=1

      local found=0
      local k=0
      while [ $k -lt ${#codex_keys[@]} ]; do
        if [ "${codex_keys[$k]}" = "$remote" ]; then
          codex_file_lists[$k]="${codex_file_lists[$k]}|$codex_file"
          codex_counts[$k]=$((${codex_counts[$k]} + 1))
          [ "$_is_cross_tool" -eq 1 ] && codex_cross_tool_counts[$k]=$((${codex_cross_tool_counts[$k]} + 1))
          found=1
          break
        fi
        k=$((k + 1))
      done
      if [ "$found" -eq 0 ]; then
        codex_keys+=("$remote")
        codex_file_lists+=("$codex_file")
        codex_counts+=("1")
        codex_cross_tool_counts+=("$_is_cross_tool")
      fi
    done < <(find "$CODEX_DIR" -name "*.jsonl" -maxdepth 6 2>/dev/null)
  fi

  # Scan child directories for .git (use -e to catch worktrees where .git is a file)
  echo "  Looking for repos in ${current_dir}/" >&2
  CHILD_REPO_DIRS=()
  CHILD_REPO_REMOTES=()
  CHILD_REPO_NAMES=()
  CHILD_REPO_SESSIONS=()
  # Phase 3.5 — parallel array tracking cross-tool subset of CHILD_REPO_SESSIONS
  # so the --all picker can show "(N sessions, M Codex by Claude)".
  CHILD_REPO_CROSS_TOOL_SESSIONS=()
  CHILD_REPO_CURSOR_ONLY=()
  CHILD_TRANSCRIPT_DIRS=()
  CHILD_CODEX_DIRS=()

  local seen_remotes=""
  # Tracks name:<base> cache-group indices already claimed by an earlier child, so
  # the same unresolved (deleted-cwd) transcript group can't be attributed to two
  # same-basename children (e.g. 'my-app' + 'my_app', which both match name:my-app
  # via the _<->- alt-form) and uploaded under two reports. Delimited-token idiom,
  # same as seen_remotes / the per-repo failed-index set.
  local consumed_name_idx=""
  for child in "$current_dir"/*/; do
    [ -d "$child" ] || continue
    [ -e "$child/.git" ] || [ -e "$child/.jj" ] || continue

    local child_path
    child_path=$(cd "$child" && pwd)
    local child_remote
    child_remote=$(get_git_remote "$child_path")

    local child_key
    if [ -n "$child_remote" ]; then
      child_key="$child_remote"
    else
      child_key="local:$child_path"
    fi

    # Deduplicate by key
    case "$seen_remotes" in
      *"|$child_key|"*) continue ;;
    esac
    seen_remotes="${seen_remotes}|${child_key}|"

    # Match against pre-computed transcript dirs (by remote, local path, or project name)
    local matched_dirs=""
    local matched_sessions=0
    local child_basename
    child_basename=$(basename "$child_path")
    # Also try with underscores replaced by hyphens and vice versa
    local child_basename_alt
    child_basename_alt=$(echo "$child_basename" | tr '_' '-')
    local child_basename_alt2
    child_basename_alt2=$(echo "$child_basename" | tr '-' '_')

    local k=0
    while [ $k -lt ${#t_keys[@]} ]; do
      local match=0
      local is_name_match=0
      if [ "${t_keys[$k]}" = "$child_key" ]; then
        match=1
      elif [[ "${t_keys[$k]}" == name:* ]]; then
        # Name-based matching for unresolved (deleted-cwd) transcript dirs. Skip a
        # name: group already claimed by an earlier child so it isn't double-counted;
        # an exact (remote/local-key) match above is unaffected and a live repo still
        # inherits its own unclaimed name: group (the common Conductor case).
        case "$consumed_name_idx" in
          *"|$k|"*) : ;;  # already claimed by an earlier same-basename child
          *)
            local t_name="${t_keys[$k]#name:}"
            if [ "$t_name" = "$child_basename" ] || [ "$t_name" = "$child_basename_alt" ] || [ "$t_name" = "$child_basename_alt2" ]; then
              match=1
              is_name_match=1
            fi
            ;;
        esac
      fi
      if [ "$match" -eq 1 ]; then
        # Safe to mark consumed before the total_sessions==0 skip below: a name
        # match always adds t_sessions[k], and load_project_cache only emits
        # name: groups with sessions>0, so a name-matched child is never dropped
        # there — the index can't be consumed by a child that then disappears.
        [ "$is_name_match" -eq 1 ] && consumed_name_idx="${consumed_name_idx}|${k}|"
        if [ -z "$matched_dirs" ]; then
          matched_dirs="${t_dirs[$k]}"
        else
          matched_dirs="${matched_dirs}|${t_dirs[$k]}"
        fi
        matched_sessions=$((matched_sessions + ${t_sessions[$k]}))
      fi
      k=$((k + 1))
    done

    # Match Codex sessions
    local matched_codex=""
    local codex_session_count=0
    local codex_cross_tool_count=0
    local k=0
    while [ $k -lt ${#codex_keys[@]} ]; do
      if [ "${codex_keys[$k]}" = "$child_key" ]; then
        matched_codex="${codex_file_lists[$k]}"
        codex_session_count=${codex_counts[$k]}
        codex_cross_tool_count=${codex_cross_tool_counts[$k]:-0}
        break
      fi
      k=$((k + 1))
    done

    local total_sessions=$((matched_sessions + codex_session_count))
    # No Claude/Codex sessions? Check opencode/Gemini before skipping — otherwise a
    # repo worked ONLY in those tools is invisible in the picker, unlike single-repo
    # auto-detect which folds them in. Only zero-Claude/Codex children pay this, and
    # the count helpers return 0 immediately when the tool isn't installed. (Cursor
    # has no count helper anywhere — the single-repo prelude omits it too — so a
    # Cursor-only repo stays a known gap. A future prescan could also fold these into
    # the displayed count for MIXED repos, which today show Claude+Codex only.)
    if [ "$total_sessions" -eq 0 ] && [ -n "$child_remote" ]; then
      local _oc_n _gm_n _vs_n _ag_n
      _oc_n=$(count_opencode_sessions "$child_remote")
      _gm_n=$(count_gemini_sessions "$child_remote")
      _vs_n=$(count_vscode_copilot_sessions "$child_remote")
      _ag_n=$(count_antigravity_sessions "$child_remote")
      total_sessions=$((_oc_n + _gm_n + _vs_n + _ag_n))
    fi
    # Cursor has no cheap per-repo count (C3). If every counted tool came up empty,
    # fall back to a one-time presence prescan so a Cursor-only child (with a remote)
    # still shows in the picker — run_docker_analysis counts it inside the container.
    # Tracked separately so the menu labels it instead of showing a bogus "0 sessions".
    local _cursor_only=0
    if [ "$total_sessions" -eq 0 ] && [ -n "$child_remote" ] && remote_has_cursor_sessions "$child_remote"; then
      _cursor_only=1
    fi
    # Skip repos with no transcript data at all
    [ "$total_sessions" -eq 0 ] && [ "$_cursor_only" -eq 0 ] && continue

    local display_name
    if [ -n "$child_remote" ]; then
      display_name=$(remote_display_name "$child_remote")
    else
      display_name=$(basename "$child_path")
    fi

    CHILD_REPO_DIRS+=("$child_path")
    CHILD_REPO_REMOTES+=("$child_key")
    CHILD_REPO_NAMES+=("$display_name")
    CHILD_REPO_SESSIONS+=("$total_sessions")
    CHILD_REPO_CURSOR_ONLY+=("$_cursor_only")
    CHILD_REPO_CROSS_TOOL_SESSIONS+=("$codex_cross_tool_count")
    CHILD_TRANSCRIPT_DIRS+=("$matched_dirs")
    CHILD_CODEX_DIRS+=("$matched_codex")
  done

  [ ${#CHILD_REPO_DIRS[@]} -eq 0 ] && return 1

  # Sort by session count descending (bubble sort, fine for <50 items)
  local n=${#CHILD_REPO_DIRS[@]}
  local i=0
  while [ $i -lt $((n - 1)) ]; do
    local j=0
    while [ $j -lt $((n - i - 1)) ]; do
      local next=$((j + 1))
      if [ "${CHILD_REPO_SESSIONS[$j]}" -lt "${CHILD_REPO_SESSIONS[$next]}" ]; then
        # Swap all parallel arrays — keep CHILD_REPO_CROSS_TOOL_SESSIONS in
        # sync or `--all` mode display gets scrambled when sort reorders rows.
        local tmp
        tmp="${CHILD_REPO_DIRS[$j]}"; CHILD_REPO_DIRS[$j]="${CHILD_REPO_DIRS[$next]}"; CHILD_REPO_DIRS[$next]="$tmp"
        tmp="${CHILD_REPO_REMOTES[$j]}"; CHILD_REPO_REMOTES[$j]="${CHILD_REPO_REMOTES[$next]}"; CHILD_REPO_REMOTES[$next]="$tmp"
        tmp="${CHILD_REPO_NAMES[$j]}"; CHILD_REPO_NAMES[$j]="${CHILD_REPO_NAMES[$next]}"; CHILD_REPO_NAMES[$next]="$tmp"
        tmp="${CHILD_REPO_SESSIONS[$j]}"; CHILD_REPO_SESSIONS[$j]="${CHILD_REPO_SESSIONS[$next]}"; CHILD_REPO_SESSIONS[$next]="$tmp"
        tmp="${CHILD_REPO_CURSOR_ONLY[$j]}"; CHILD_REPO_CURSOR_ONLY[$j]="${CHILD_REPO_CURSOR_ONLY[$next]}"; CHILD_REPO_CURSOR_ONLY[$next]="$tmp"
        tmp="${CHILD_REPO_CROSS_TOOL_SESSIONS[$j]}"; CHILD_REPO_CROSS_TOOL_SESSIONS[$j]="${CHILD_REPO_CROSS_TOOL_SESSIONS[$next]}"; CHILD_REPO_CROSS_TOOL_SESSIONS[$next]="$tmp"
        tmp="${CHILD_TRANSCRIPT_DIRS[$j]}"; CHILD_TRANSCRIPT_DIRS[$j]="${CHILD_TRANSCRIPT_DIRS[$next]}"; CHILD_TRANSCRIPT_DIRS[$next]="$tmp"
        tmp="${CHILD_CODEX_DIRS[$j]}"; CHILD_CODEX_DIRS[$j]="${CHILD_CODEX_DIRS[$next]}"; CHILD_CODEX_DIRS[$next]="$tmp"
      fi
      j=$((j + 1))
    done
    i=$((i + 1))
  done

  return 0
}

# Show interactive menu for child repo selection
show_child_repo_menu() {
  require_tty

  local repo_count=${#CHILD_REPO_NAMES[@]}
  local repo_label="repos"
  [ "$repo_count" -eq 1 ] && repo_label="repo"
  local all_idx=$((repo_count + 1))
  local cancel_idx=$((repo_count + 2))

  echo ""
  echo "Found ${repo_count} ${repo_label} with transcript data in this directory:"
  echo ""

  local g=0
  while [ $g -lt ${#CHILD_REPO_NAMES[@]} ]; do
    local total="${CHILD_REPO_SESSIONS[$g]}"
    local cross_tool="${CHILD_REPO_CROSS_TOOL_SESSIONS[$g]:-0}"
    local main_total=$((total - cross_tool))
    local session_label="sessions"
    [ "$main_total" -eq 1 ] && session_label="session"
    if [ "${CHILD_REPO_CURSOR_ONLY[$g]:-0}" -eq 1 ] && [ "$total" -eq 0 ]; then
      # Cursor-only repo: no cheap host count, the real total is computed in the container.
      echo "  $((g + 1))) ${CHILD_REPO_NAMES[$g]} (Cursor sessions)"
    elif [ "$cross_tool" -gt 0 ]; then
      echo "  $((g + 1))) ${CHILD_REPO_NAMES[$g]} (${main_total} ${session_label} + ${cross_tool} Codex by Claude)"
    else
      echo "  $((g + 1))) ${CHILD_REPO_NAMES[$g]} (${main_total} ${session_label})"
    fi
    g=$((g + 1))
  done

  echo ""
  echo "  ${all_idx}) Analyze all repos (one report per repo)"
  echo "  ${cancel_idx}) Cancel"
  echo ""

  local choice
  user_read -rp "Choose [1-${cancel_idx}] (comma-separate for multiple, e.g. 1,3): " choice

  # Strip spaces so "1, 2" parses the same as "1,2".
  choice="${choice// /}"

  MULTI_REPO_SELECTED_LIST=()

  # Meta items first (exact string match, so they can't be mixed into a list).
  if [ "$choice" = "$all_idx" ]; then
    MULTI_REPO_MODE="all"
    local g=0
    while [ "$g" -lt "$repo_count" ]; do
      MULTI_REPO_SELECTED_LIST+=("$g")
      g=$((g + 1))
    done
    _confirm_selected_child_repos || { echo "Cancelled."; exit 0; }
    return 0
  fi

  if [ "$choice" = "$cancel_idx" ]; then
    echo "Cancelled."
    exit 0
  fi

  # One or more repo numbers, comma-separated. Each token bounded to 10 digits so
  # long digit-only paste (exceeds bash's 64-bit integer range) is rejected by
  # the regex rather than printing raw "integer expression expected" arithmetic.
  if ! [[ "$choice" =~ ^[0-9]{1,10}(,[0-9]{1,10})*$ ]]; then
    echo "Invalid choice." >&2
    exit 1
  fi

  local -a _toks
  IFS=',' read -ra _toks <<< "$choice"
  local tok
  for tok in "${_toks[@]}"; do
    if [ "$tok" -lt 1 ] || [ "$tok" -gt "$repo_count" ]; then
      echo "Invalid choice." >&2
      exit 1
    fi
    MULTI_REPO_SELECTED_LIST+=("$((tok - 1))")
  done

  # Dedup + sort the selected indices (process substitution keeps the array
  # write in the current shell — a `| while` subshell would lose it).
  local -a _uniq=()
  local i
  while IFS= read -r i; do
    [ -n "$i" ] && _uniq+=("$i")
  done < <(printf '%s\n' "${MULTI_REPO_SELECTED_LIST[@]}" | sort -n | uniq)
  MULTI_REPO_SELECTED_LIST=("${_uniq[@]}")

  if [ "${#MULTI_REPO_SELECTED_LIST[@]}" -eq 1 ]; then
    MULTI_REPO_MODE="single"
    MULTI_REPO_SELECTED="${MULTI_REPO_SELECTED_LIST[0]}"
    echo "Selected: ${CHILD_REPO_NAMES[${MULTI_REPO_SELECTED_LIST[0]}]}"
  else
    MULTI_REPO_MODE="subset"
    _confirm_selected_child_repos || { echo "Cancelled."; exit 0; }
  fi
}

# Show the combined time estimate for the repos in MULTI_REPO_SELECTED_LIST and
# ask the user to confirm. Returns 0 to proceed, 1 to cancel. Used by the "all"
# and multi-select subset paths; a single selection skips the estimate.
_confirm_selected_child_repos() {
  local sel_count=${#MULTI_REPO_SELECTED_LIST[@]}
  local label="repos"
  [ "$sel_count" -eq 1 ] && label="repo"
  local total_minutes=0
  echo ""
  echo "${sel_count} ${label} selected."
  local idx
  for idx in "${MULTI_REPO_SELECTED_LIST[@]}"; do
    local mins
    mins=$(estimate_time "${CHILD_REPO_SESSIONS[$idx]}")
    total_minutes=$((total_minutes + mins))
    local _ct="${CHILD_REPO_CROSS_TOOL_SESSIONS[$idx]:-0}"
    local _main=$((CHILD_REPO_SESSIONS[$idx] - _ct))
    if [ "$_ct" -gt 0 ]; then
      printf "  %-20s ~%d min (%d sessions + %d Codex by Claude)\n" "${CHILD_REPO_NAMES[$idx]}" "$mins" "$_main" "$_ct"
    else
      printf "  %-20s ~%d min (%d sessions)\n" "${CHILD_REPO_NAMES[$idx]}" "$mins" "$_main"
    fi
  done
  echo ""
  echo "Total estimated time: ~${total_minutes} minutes"
  echo ""
  local confirm
  user_read -rp "Continue? [Y/n]: " confirm
  case "$confirm" in
    [Nn]*) return 1 ;;
  esac
  return 0
}

# Run prepare_and_run_for_repo for each repo in MULTI_REPO_SELECTED_LIST
# (0-based indices into the CHILD_REPO_* arrays), print the multi-repo summary,
# and exit. Shared by the two child-repo entry points (auto-detect override and
# the Strategy 3 parent-dir picker) so they can't drift.
run_selected_child_repos() {
  pull_client_image
  if ! check_docker_storage; then exit 1; fi
  MULTI_REPO_RUNNING=1

  local original_claude_dir="$CLAUDE_DIR"
  local original_codex_dir="$CODEX_DIR"
  local success_count=0
  local failed_repos=""   # space-joined names, for the human-readable "Failed:" line
  local failed_idx=""     # "|idx|"-delimited, for exact per-repo ✓/✗ (no name-substring collision)
  local total=${#MULTI_REPO_SELECTED_LIST[@]}

  # Set expectations before the slow part (the single-repo reassurance in
  # run_docker_analysis is suppressed under MULTI_REPO_RUNNING). Steps 1-3 above
  # were one-time setup; each repo below re-runs steps 4-17 on the same /17 scale.
  echo ""
  echo "Analyzing ${total} repos — this is the slow part. Each repo runs steps 4-17 below."

  local n=0
  local idx
  for idx in "${MULTI_REPO_SELECTED_LIST[@]}"; do
    n=$((n + 1))
    echo ""
    echo "═══ [${n}/${total}] Analyzing: ${CHILD_REPO_NAMES[$idx]} ═══"
    local repo_status=0
    if prepare_and_run_for_repo "${CHILD_REPO_DIRS[$idx]}" "${CHILD_REPO_NAMES[$idx]}" "${CHILD_REPO_REMOTES[$idx]}" "${CHILD_TRANSCRIPT_DIRS[$idx]}" "${CHILD_CODEX_DIRS[$idx]}"; then
      success_count=$((success_count + 1))
    else
      repo_status=$?
      failed_repos="${failed_repos} ${CHILD_REPO_NAMES[$idx]}"
      failed_idx="${failed_idx}|${idx}|"
      if [ "$repo_status" -eq "$PAXEL_EXIT_STORAGE_FULL" ]; then
        echo ""
        echo "Docker storage is shared across this batch, so the remaining repos were not started."
        echo "  ✗ ${CHILD_REPO_NAMES[$idx]}"
        local remaining_idx after_current=0
        for remaining_idx in "${MULTI_REPO_SELECTED_LIST[@]}"; do
          if [ "$after_current" -eq 1 ]; then
            echo "  – ${CHILD_REPO_NAMES[$remaining_idx]} (skipped)"
          elif [ "$remaining_idx" = "$idx" ]; then
            after_current=1
          fi
        done
        echo ""
        echo "${success_count}/${total} repos analyzed successfully before Docker storage was exhausted."
        CLAUDE_DIR="$original_claude_dir"
        CODEX_DIR="$original_codex_dir"
        exit "$PAXEL_EXIT_STORAGE_FULL"
      fi
    fi
  done

  # End summary
  echo ""
  echo "═══ Multi-repo analysis complete ═══"
  for idx in "${MULTI_REPO_SELECTED_LIST[@]}"; do
    local status_icon="✓"
    # Match by exact index token, not a name substring — otherwise a succeeded
    # repo whose name is a substring of a failed one (e.g. "app" vs "app-web")
    # is wrongly shown as ✗.
    case "$failed_idx" in
      *"|${idx}|"*) status_icon="✗" ;;
    esac
    echo "  ${status_icon} ${CHILD_REPO_NAMES[$idx]}"
  done
  echo ""
  echo "${success_count}/${total} repos analyzed successfully."
  if [ -n "$failed_repos" ]; then
    echo "Failed:${failed_repos}"
    echo "  Per-repo logs: ${HOME}/.paxel/logs/<repo>-*.log"
  fi
  echo ""
  echo "Results: ${PAXEL_SERVER}/reports"
  paxel_skill_upload_hint "These reports cover the agent sessions on this machine only." || true

  # Single notification at the end
  printf '\a'
  if [ "$(uname -s)" = "Darwin" ]; then
    osascript -e "display notification \"${success_count}/${total} repos analyzed.\" with title \"Paxel\"" 2>/dev/null || true
  fi

  CLAUDE_DIR="$original_claude_dir"
  CODEX_DIR="$original_codex_dir"
  [ -z "$failed_repos" ] && exit 0 || exit 1
}

# Get sessions sorted by createdAt from sessions-index.json, falling back to mtime
get_sorted_sessions() {
  local project_dir="$1"
  local index_file="$project_dir/sessions-index.json"

  if [ -f "$index_file" ] && command -v jq &>/dev/null; then
    # Handle both array format and {version, entries} format
    jq -r '
      (if type == "array" then . elif type == "object" then (.entries // []) else [] end)
      | sort_by(.createdAt) | reverse | .[].sessionId
    ' "$index_file" 2>/dev/null
  else
    # Fallback: find .jsonl files sorted by mtime (newest first).
    # GNU stat first (BSD stat -f on Linux silently prints filesystem info).
    find "$project_dir" -name "*.jsonl" -maxdepth 1 2>/dev/null \
      | while read -r f; do
          local m
          m=$(stat -c '%Y' "$f" 2>/dev/null || stat -f '%m' "$f" 2>/dev/null || echo 0)
          printf '%s %s\n' "$m" "$f"
        done \
      | sort -rn \
      | awk '{print $2}' \
      | xargs -I{} basename {} .jsonl
  fi
}

# Get session timestamp (epoch) from sessions-index.json or file mtime
get_session_timestamp() {
  local project_dir="$1"
  local session_id="$2"
  local index_file="$project_dir/sessions-index.json"

  if [ -f "$index_file" ] && command -v jq &>/dev/null; then
    local ts
    ts=$(jq -r --arg sid "$session_id" '
      (if type == "array" then . elif type == "object" then (.entries // []) else [] end)
      | map(select(.sessionId == $sid)) | .[0].createdAt // empty
    ' "$index_file" 2>/dev/null || true)
    if [ -n "$ts" ]; then
      # Convert ISO date to epoch. GNU date first (exits cleanly on BSD),
      # then BSD date. Same order-sensitivity rule applies to stat.
      date -d "${ts%%.*}" "+%s" 2>/dev/null \
        || date -j -f "%Y-%m-%dT%H:%M:%S" "${ts%%.*}" "+%s" 2>/dev/null \
        || stat -c %Y "$project_dir/${session_id}.jsonl" 2>/dev/null \
        || stat -f %m "$project_dir/${session_id}.jsonl" 2>/dev/null \
        || echo "0"
      return
    fi
  fi

  # Fallback to file mtime. GNU -c %Y first (BSD stat -f with %m as literal
  # prints filesystem info and exits 0, poisoning the output), then BSD.
  stat -c %Y "$project_dir/${session_id}.jsonl" 2>/dev/null \
    || stat -f %m "$project_dir/${session_id}.jsonl" 2>/dev/null \
    || echo "0"
}

# Collect sessions across multiple dirs with merge-sort
collect_project_group() {
  local tmpdir="$1"
  shift
  local dirs=("$@")

  # Declared at function scope so collect_cursor_sessions "$tmpdir" "$selected_remote"
  # (line ~3066, outside the CODEX_DIR conditional that previously owned the
  # `local` declaration) has a defined value when CODEX_DIR is absent. Without
  # this, `set -u` trips with "selected_remote: unbound variable" under any
  # invocation path where the Claude project group has no Codex directory
  # to mirror. Exposed by the DRY_RUN staging path; also latent in legacy.
  local selected_remote=""

  # Build session list: (timestamp, dir_name, session_id, file_size)
  local session_list_file
  session_list_file=$(mktemp)

  for dir_name in "${dirs[@]}"; do
    local project_dir="$CLAUDE_DIR/$dir_name"
    [ -d "$project_dir" ] || continue

    # Copy sessions-index.json
    mkdir -p "$tmpdir/$dir_name"
    if [ -f "$project_dir/sessions-index.json" ]; then
      cp "$project_dir/sessions-index.json" "$tmpdir/$dir_name/"
    fi

    while IFS= read -r session_id; do
      [ -z "$session_id" ] && continue
      local jsonl_file="$project_dir/${session_id}.jsonl"
      [ -f "$jsonl_file" ] || continue

      local ts
      ts=$(get_session_timestamp "$project_dir" "$session_id")
      local file_size
      file_size=$(wc -c < "$jsonl_file" | tr -d ' ')

      echo "$ts $dir_name $session_id $file_size" >> "$session_list_file"
    done < <(get_sorted_sessions "$project_dir")
  done

  # Sort by timestamp (newest first) and process
  local sorted_file
  sorted_file=$(mktemp)
  sort -rn "$session_list_file" > "$sorted_file"

  local accumulated_bytes=0
  local session_count=0
  local pr_links_json="[]"
  local dir_metadata_json="{}"

  # Build directory metadata for sidecar
  for dir_name in "${dirs[@]}"; do
    local cwd
    cwd=$(get_project_cwd "$dir_name")
    local remote
    remote=$(get_git_remote "$cwd")
    # Orphan recovery: server-side TranscriptDiscoverer consumes this
    # remote to find-or-create the Project; empty means per-dir Project.
    if [ -z "$remote" ] && [ -n "$cwd" ] && [ ! -e "$cwd" ]; then
      remote=$(resolve_remote_for_dead_cwd "$cwd")
    fi
    if [ -n "$remote" ] || [ -n "$cwd" ]; then
      dir_metadata_json=$(echo "$dir_metadata_json" | jq \
        --arg dir "$dir_name" \
        --arg remote "$remote" \
        --arg cwd "$cwd" \
        '. + {($dir): {"git_remote": $remote, "cwd": $cwd}}' 2>/dev/null || echo "$dir_metadata_json")
    fi
  done

  while IFS=' ' read -r ts dir_name session_id file_size; do
    [ -z "$session_id" ] && continue

    # Apply --since filter
    if [ -n "$SINCE_EPOCH" ] && [ "$ts" -lt "$SINCE_EPOCH" ] 2>/dev/null; then
      continue
    fi

    # Track oldest session timestamp (post-filter) for author-filtered git collection
    if [ -z "$OLDEST_SESSION_EPOCH" ] || [ "$ts" -lt "$OLDEST_SESSION_EPOCH" ] 2>/dev/null; then
      OLDEST_SESSION_EPOCH="$ts"
    fi

    local project_dir="$CLAUDE_DIR/$dir_name"
    local jsonl_file="$project_dir/${session_id}.jsonl"

    mkdir -p "$tmpdir/$dir_name"
    cp "$jsonl_file" "$tmpdir/$dir_name/"
    accumulated_bytes=$(($accumulated_bytes + $file_size))
    session_count=$((session_count + 1))

    # Scan for PR links (grep for pr-link pattern in JSONL)
    # Claude Code JSONL uses camelCase: "prNumber", "prUrl", "prRepository"
    local pr_match
    pr_match=$(grep -o '"pr-link","sessionId":"[^"]*","prNumber":[0-9]*,"prUrl":"[^"]*","prRepository":"[^"]*"' "$jsonl_file" 2>/dev/null | head -1 || true)
    if [ -n "$pr_match" ]; then
      local pr_num pr_url pr_repo
      pr_num=$(echo "$pr_match" | grep -o '"prNumber":[0-9]*' | sed 's/"prNumber"://')
      pr_url=$(echo "$pr_match" | grep -o '"prUrl":"[^"]*"' | sed 's/"prUrl":"//;s/"$//')
      pr_repo=$(echo "$pr_match" | grep -o '"prRepository":"[^"]*"' | sed 's/"prRepository":"//;s/"$//')
      if [ -n "$pr_num" ] && command -v jq &>/dev/null; then
        pr_links_json=$(echo "$pr_links_json" | jq \
          --arg sid "$session_id" \
          --arg dir "$dir_name" \
          --argjson num "$pr_num" \
          --arg url "$pr_url" \
          --arg repo "$pr_repo" \
          '. + [{"session_id": $sid, "dir": $dir, "pr_number": $num, "pr_url": $url, "pr_repo": $repo}]' 2>/dev/null || echo "$pr_links_json")
      fi
    fi

    # Copy subagents directory if present
    local subagents_dir="$project_dir/${session_id}/subagents"
    if [ -d "$subagents_dir" ]; then
      mkdir -p "$tmpdir/$dir_name/${session_id}/subagents"
      cp "$subagents_dir"/*.jsonl "$tmpdir/$dir_name/${session_id}/subagents/" 2>/dev/null || true
    fi

    # Copy tool-results directory if present
    local tool_results_dir="$project_dir/${session_id}/tool-results"
    if [ -d "$tool_results_dir" ]; then
      mkdir -p "$tmpdir/$dir_name/${session_id}/tool-results"
      cp -r "$tool_results_dir/"* "$tmpdir/$dir_name/${session_id}/tool-results/" 2>/dev/null || true
    fi
  done < "$sorted_file"

  # Write _metadata.json sidecar. The recoveries count is the cumulative
  # unique orphan recoveries during this script run (via the dedup log);
  # for single-repo uploads this is exact, for multi-repo it over-counts
  # later children (acceptable — admins see aggregate run activity).
  local _rmdc_total
  _rmdc_total=$(_rmdc_recovery_count_unique)
  if command -v jq &>/dev/null; then
    jq -n \
      --argjson dirs "$dir_metadata_json" \
      --argjson prs "$pr_links_json" \
      --argjson recoveries "${_rmdc_total:-0}" \
      '{"version": 1, "directories": $dirs, "pr_links": $prs, "orphan_recovery_count": $recoveries}' \
      > "$tmpdir/_metadata.json"
  fi

  rm -f "$session_list_file" "$sorted_file"

  echo "  Claude Code: ${session_count} sessions across ${#dirs[@]} workspaces, $(($accumulated_bytes / 1024 / 1024))MB" >&2

  # Collect matching Codex sessions for the same git remote
  # Determine the selected project's git remote — used by BOTH Codex and
  # Cursor helpers below, so hoist out of any $CODEX_DIR guard.
  local selected_remote=""
  for dir_name in "${dirs[@]}"; do
    local cwd
    cwd=$(get_project_cwd "$dir_name")
    local remote
    remote=$(get_git_remote "$cwd")
    if [ -z "$remote" ] && [ -n "$cwd" ] && [ ! -e "$cwd" ]; then
      remote=$(resolve_remote_for_dead_cwd "$cwd")
    fi
    if [ -n "$remote" ]; then
      selected_remote="$remote"
      break
    fi
  done

  # Codex: gate on non-empty remote. An empty selected_remote tells the helper
  # to include every repo's sessions (--all mode), which would widen a scoped
  # upload. Handoff gotcha #5.
  if [ -n "$selected_remote" ]; then
    collect_codex_sessions "$tmpdir" "$selected_remote"
  fi

  # Collect matching Cursor IDE sessions for the same git remote
  collect_cursor_sessions "$tmpdir" "$selected_remote"
  # Collect matching opencode sessions for the same git remote
  collect_opencode_sessions "$tmpdir" "$selected_remote"
  # Collect matching Gemini CLI sessions for the same git remote
  collect_gemini_sessions "$tmpdir" "$selected_remote"
  # Collect matching VS Code Copilot sessions for the same git remote
  collect_vscode_copilot_sessions "$tmpdir" "$selected_remote"
  # Collect matching Antigravity sessions for the same git remote
  collect_antigravity_sessions "$tmpdir" "$selected_remote"
  _refresh_orphan_recovery_count "$tmpdir/_metadata.json"
}

list_projects() {
  if [ ! -d "$CLAUDE_DIR" ]; then
    echo "Error: Claude projects directory not found at $CLAUDE_DIR" >&2
    exit 1
  fi

  # List directories that contain .jsonl files
  local projects=()
  for dir in "$CLAUDE_DIR"/*/; do
    [ -d "$dir" ] || continue
    local name
    name=$(basename "$dir")
    # Check if directory has any .jsonl files.
    # `find -print -quit` SIGPIPEs on first match → ERR trap. Same family
    # as the OLDEST_SESSION_EPOCH fix (PR #389).
    local has_jsonl
    has_jsonl=$(find "$dir" -name "*.jsonl" -maxdepth 3 -print -quit 2>/dev/null || true)
    if [ -n "$has_jsonl" ]; then
      projects+=("$name")
    fi
  done

  if [ ${#projects[@]} -eq 0 ]; then
    echo "Error: No projects with transcripts found in $CLAUDE_DIR" >&2
    exit 1
  fi

  printf '%s\n' "${projects[@]}"
}



# Read a cached normalized remote for an encoded Claude dir from
# ~/.paxel/cache/project-remotes-v2.tsv. Skips the "name:*" / "local:*" /
# exact-match "unknown" fallback keys that list_projects_grouped writes for
# unresolvable dirs — anchor "unknown" at end (via `$2 != "unknown"`) so a
# real remote like "unknownhost.io/org/repo" isn't silently filtered out.
# Cursor's dead-ws fallback (:1016) uses shell glob `unknown)` with no
# trailing wildcard, matching this semantic.
#
# Used by collect_all_projects as a last-resort fallback for Conductor dead
# cwds, which short-circuit inside resolve_remote_for_dead_cwd and have no
# other local signal to recover from once all siblings are deleted.
_project_cache_read_remote() {
  local dir="$1"
  local cache="${HOME}/.paxel/cache/project-remotes-v2.tsv"
  [ -z "$dir" ] && return 0
  [ ! -f "$cache" ] && return 0
  awk -F'\t' -v d="$dir" '
    $1 == d && $2 != "" && $2 !~ /^(name:|local:)/ && $2 != "unknown" { print $2; exit }
  ' "$cache" 2>/dev/null || true
}

# Merge a TSV of (dir, remote, sessions, mtime, inferred) rows into the
# project-remote cache. Rows for dirs we saw this run overwrite any existing
# row; rows for dirs we didn't see are preserved (list_projects_grouped may
# have written them on an earlier --project run). Creates the cache if
# missing. Called at the end of collect_all_projects so the next --all run
# can recover a Conductor workspace whose dir has since been deleted.
_project_cache_persist_rows() {
  local new_rows_file="$1"
  [ ! -s "$new_rows_file" ] && return 0
  local cache="${HOME}/.paxel/cache/project-remotes-v2.tsv"
  mkdir -p "$(dirname "$cache")"
  local merged awk_ok=0
  merged=$(mktemp)
  if [ -f "$cache" ]; then
    if awk -F'\t' -v new_file="$new_rows_file" '
      BEGIN {
        while ((getline line < new_file) > 0) {
          n = split(line, f, "\t")
          if (n >= 1) new_rows[f[1]] = line
        }
        close(new_file)
      }
      {
        if ($1 in new_rows) {
          print new_rows[$1]
          delete new_rows[$1]
        } else {
          print $0
        }
      }
      END {
        for (d in new_rows) print new_rows[d]
      }
    ' "$cache" > "$merged" 2>/dev/null; then
      awk_ok=1
    fi
  else
    cp "$new_rows_file" "$merged" && awk_ok=1
  fi
  # Only overwrite the real cache if the merge succeeded AND produced non-
  # empty output. A mid-stream awk failure (signal, disk-full) could leave a
  # truncated $merged with data — swapping it in would corrupt the cache; bail.
  if [ "$awk_ok" = "1" ] && [ -s "$merged" ]; then
    mv "$merged" "$cache"
  else
    rm -f "$merged"
  fi
}

collect_all_projects() {
  local tmpdir="$1"

  # Collect Claude Code sessions
  if [ -d "$CLAUDE_DIR" ]; then
    cd "$CLAUDE_DIR"
    local claude_count=0
    find . \( -name "*.jsonl" -o -name "sessions-index.json" \) | while read -r f; do
      mkdir -p "$tmpdir/$(dirname "$f")"
      cp "$f" "$tmpdir/$f"
    done
    claude_count=$(find . -name "*.jsonl" -not -name "_*" -not -path "*/_git/*" -not -path "*/subagents/*" -maxdepth 3 2>/dev/null | wc -l | tr -d ' ')
    if [ "$claude_count" -gt 0 ]; then
      echo "  Claude Code: ${claude_count} sessions" >&2
    fi

    # Copy tool-results directories
    find . -type d -name "tool-results" | while read -r d; do
      mkdir -p "$tmpdir/$d"
      cp -r "$d/"* "$tmpdir/$d/" 2>/dev/null || true
    done
  fi

  # Write _metadata.json entries for each Claude project dir so the server's
  # TranscriptDiscoverer merges worktrees that share a git remote into one
  # Project (find_or_create_by!(git_remote: ...)) instead of scattering by
  # encoded_name. Without this, users with N Conductor worktrees of the same
  # repo see N separate Projects in --all uploads. Mirrors the pattern
  # collect_project_group already uses at line 2015-2032.
  #
  # `cd "$CLAUDE_DIR"` above has already run (claude_count > 0 implies the
  # Claude dir existed), so we pin CLAUDE_DIR to $PWD (absolute form) for the
  # duration of the loop — get_project_cwd reads $CLAUDE_DIR internally and
  # would double-resolve a relative value under the cd'd cwd.
  if [ "${claude_count:-0}" -gt 0 ] && command -v jq &>/dev/null; then
    [ ! -f "$tmpdir/_metadata.json" ] && echo '{"version":1,"directories":{}}' > "$tmpdir/_metadata.json"
    local _orig_claude_dir="$CLAUDE_DIR"
    CLAUDE_DIR="$PWD"
    local claude_sidecar_count=0
    # Cache rows to persist at end of loop. Populated with every dir whose
    # remote resolved (live OR via resolver/cache recovery). Persisted to
    # ~/.paxel/cache/project-remotes-v2.tsv so that if the workspace is
    # later deleted, the next --all run can still attribute its sessions.
    local _cache_rows_file
    _cache_rows_file=$(mktemp)
    for proj_dir in */; do
      [ -d "$proj_dir" ] || continue
      local pname pcwd premote _p_inferred=0
      # Parameter expansion over `basename "$proj_dir"` — Claude encoded
      # project dir names like `-Users-...` trip basename's leading-dash
      # flag parsing ("illegal option -- U").
      pname="${proj_dir%/}"
      pcwd=$(get_project_cwd "$pname")
      premote=$(get_git_remote "$pcwd")
      # Dead cwd recovery (deleted worktrees, removed subdirs)
      if [ -z "$premote" ] && [ -n "$pcwd" ] && [ ! -e "$pcwd" ]; then
        premote=$(resolve_remote_for_dead_cwd "$pcwd" 2>/dev/null || true)
        [ -n "$premote" ] && _p_inferred=1
        # Conductor dead-cwd cache fallback. resolve_remote_for_dead_cwd
        # short-circuits */conductor/workspaces/*|*/.conductor/* paths
        # (PR #647 comment: ancestor + sibling-walk strategies can't span
        # Conductor-project boundaries correctly). If the cache has a prior
        # remote for this encoded dir — written by a past run where the
        # workspace WAS live — use it. Unblocks the first-run-after-delete
        # Conductor+jj case that no other strategy can reach. Honor the
        # orphan-recovery opt-out: PAXEL_NO_ORPHAN_RECOVERY=1 disables this
        # fallback alongside the ancestor/sibling walks it already gates.
        if [ -z "$premote" ] && [ "${PAXEL_NO_ORPHAN_RECOVERY:-0}" != "1" ]; then
          case "$pcwd" in
            */conductor/workspaces/*/*|*/.conductor/*)
              premote=$(_project_cache_read_remote "$pname")
              if [ -n "$premote" ]; then
                echo "[paxel] Recovered remote for $pcwd via project-cache($pname) -> $premote" >&2
                _log_recovery_source "$pcwd" "project-cache"
                _p_inferred=1
              fi
              ;;
          esac
        fi
      fi
      # Unresolvable Conductor dead-cwd path: every strategy above
      # (resolver, sibling walks, project-cache) was tried and came back
      # empty. Tell the user what happened and how to recover; otherwise
      # the sessions ship under an encoded-name orphan Project and the
      # root cause is invisible to both user and support.
      if [ -z "$premote" ] && [ -n "$pcwd" ] && [ ! -e "$pcwd" ]; then
        _warn_unresolvable_conductor_cwd "$pname" "$pcwd"
      fi
      # Skip if we can't produce any routing signal at all
      [ -z "$premote" ] && [ -z "$pcwd" ] && continue
      local updated
      updated=$(jq \
        --arg dir "$pname" \
        --arg remote "${premote:-}" \
        --arg cwd "${pcwd:-}" \
        '.directories[$dir] = {"git_remote": $remote, "cwd": $cwd}' \
        "$tmpdir/_metadata.json" 2>/dev/null)
      [ -n "$updated" ] && echo "$updated" > "$tmpdir/_metadata.json"
      # Count every sidecar write so the status line matches what landed.
      claude_sidecar_count=$((claude_sidecar_count + 1))
      # Record for cache persistence so future --all runs can recover dead
      # Conductor cwds after the workspace is deleted. Persist empty-remote
      # rows too — they clear stale cache entries from a prior live run
      # whose remote has since disappeared (without this, a dir that loses
      # its remote would keep the stale one forever). _p_inferred tracks
      # whether $premote came from live resolution (0) or the resolver/
      # cache fallback (1) so load_project_cache can force a re-verify on
      # the next non-all run (matching list_projects_grouped:2057 semantics).
      #
      # Opt-out + empty premote + DEAD cwd: recovery paths (resolver + cache
      # fallback above) were SKIPPED by PAXEL_NO_ORPHAN_RECOVERY=1, so
      # "empty" means "we didn't look" rather than "verified unresolvable".
      # Writing empty here would clobber the user's warmed cache. Preserve
      # existing rows. Mirrors the Docker --all gate in
      # _docker_all_host_scan_for_recovery:1550-1555. Legacy's sidecar
      # write above already landed (the sidecar is the primary attribution
      # signal here; cache is best-effort for future-run recovery).
      local _legacy_skip_cache_write=0
      if [ "${PAXEL_NO_ORPHAN_RECOVERY:-0}" = "1" ] \
          && [ -z "$premote" ] \
          && [ -n "$pcwd" ] \
          && [ ! -e "$pcwd" ]; then
        _legacy_skip_cache_write=1
      fi

      if [ -n "$pname" ] && [ "$_legacy_skip_cache_write" != "1" ]; then
        # BSD find/stat on macOS parse leading `-` of encoded Claude dir
        # names (e.g. `-Users-...`, `-conductor-workspaces-...`) as option
        # flags; prefix with `./` to force path interpretation. Same family
        # of bug as the basename-leading-dash comment on the outer loop.
        local _pd_sessions _pd_mtime
        _pd_sessions=$(find "./$pname" -maxdepth 3 -name "*.jsonl" -not -name "_*" 2>/dev/null | wc -l | tr -d ' ')
        _pd_mtime=$(stat -c %Y "./$pname" 2>/dev/null || stat -f %m "./$pname" 2>/dev/null || echo "0")
        printf '%s\t%s\t%s\t%s\t%s\n' "$pname" "$premote" "${_pd_sessions:-0}" "${_pd_mtime:-0}" "$_p_inferred" >> "$_cache_rows_file"
      fi
    done
    CLAUDE_DIR="$_orig_claude_dir"
    # Merge newly-resolved rows into the project-remote cache.
    _project_cache_persist_rows "$_cache_rows_file"
    rm -f "$_cache_rows_file"
    [ "$claude_sidecar_count" -gt 0 ] && echo "  Sidecar: ${claude_sidecar_count} Claude workspaces with git_remote/cwd" >&2
  fi

  # Collect Codex sessions via collect_codex_sessions helper. Empty second
  # arg = --all mode: buckets per-session remote into _codex_<slug>_<hash>/
  # (or _codex_unattributed/ for sessions with no repository_url), writes
  # per-bucket sidecar entries, and applies --since filtering.
  collect_codex_sessions "$tmpdir"

  # Collect all Cursor IDE sessions (no remote filter — --all mode).
  # collect_cursor_sessions already buckets per-workspace (_cursor_<basename>_<hash>/)
  # and writes _metadata.json entries with each bucket's git_remote. Without this
  # call, the legacy archive flow missed Cursor entirely in --all uploads — the
  # Docker flow mounts /cursor_sessions separately but the archive didn't.
  #
  # Guard the call: collect_cursor_sessions returns 1 if every DB extraction
  # fails (stale/schema-changed state.vscdb). Under `set -e` that would abort
  # the whole upload and throw away the Claude/Codex data we already collected.
  # Docker mode does the same best-effort wrap at line 3670.
  if ! collect_cursor_sessions "$tmpdir" ""; then
    echo "  Warning: Cursor session extraction had errors. Continuing with other sessions." >&2
  fi
  if ! collect_opencode_sessions "$tmpdir" ""; then
    echo "  Warning: opencode session extraction had errors. Continuing with other sessions." >&2
  fi
  if ! collect_gemini_sessions "$tmpdir" ""; then
    echo "  Warning: Gemini session extraction had errors. Continuing with other sessions." >&2
  fi
  if ! collect_vscode_copilot_sessions "$tmpdir" ""; then
    echo "  Warning: VS Code Copilot session extraction had errors. Continuing with other sessions." >&2
  fi
  if ! collect_antigravity_sessions "$tmpdir" ""; then
    echo "  Warning: Antigravity session extraction had errors. Continuing with other sessions." >&2
  fi
  _refresh_orphan_recovery_count "$tmpdir/_metadata.json"
}

collect_single_project() {
  local tmpdir="$1"
  local project="$2"
  local project_dir="$CLAUDE_DIR/$project"

  if [ ! -d "$project_dir" ]; then
    echo "Error: Project directory not found: $project_dir"
    exit 1
  fi

  mkdir -p "$tmpdir/$project"

  # Copy sessions-index.json if present
  if [ -f "$project_dir/sessions-index.json" ]; then
    cp "$project_dir/sessions-index.json" "$tmpdir/$project/"
  fi

  local accumulated_bytes=0
  local session_count=0

  # Get sessions sorted by createdAt
  while IFS= read -r session_id; do
    [ -z "$session_id" ] && continue
    local jsonl_file="$project_dir/${session_id}.jsonl"
    [ -f "$jsonl_file" ] || continue

    local file_size
    file_size=$(wc -c < "$jsonl_file" | tr -d ' ')

    cp "$jsonl_file" "$tmpdir/$project/"
    accumulated_bytes=$(($accumulated_bytes + $file_size))
    session_count=$((session_count + 1))

    # Copy subagents directory if present
    local subagents_dir="$project_dir/${session_id}/subagents"
    if [ -d "$subagents_dir" ]; then
      mkdir -p "$tmpdir/$project/${session_id}/subagents"
      cp "$subagents_dir"/*.jsonl "$tmpdir/$project/${session_id}/subagents/" 2>/dev/null || true
    fi

    # Copy tool-results directory if present
    local tool_results_dir="$project_dir/${session_id}/tool-results"
    if [ -d "$tool_results_dir" ]; then
      mkdir -p "$tmpdir/$project/${session_id}/tool-results"
      cp -r "$tool_results_dir/"* "$tmpdir/$project/${session_id}/tool-results/" 2>/dev/null || true
    fi
  done < <(get_sorted_sessions "$project_dir")

  echo "  Collected: ${session_count} sessions, $(($accumulated_bytes / 1024 / 1024))MB"

  # Derive the selected project's git remote once for both Codex and Cursor
  # filtering below. Empty remote (unresolved cwd, no origin) means no filter
  # gets applied — Codex's `-n "$selected_remote"` guard below short-circuits,
  # and Cursor's extract_cursor_db treats empty as "match all" per its own logic.
  local cwd
  cwd=$(get_project_cwd "$project")
  local selected_remote
  selected_remote=$(get_git_remote "$cwd")
  # Dead cwd recovery (deleted subdirs, moved workspaces) — parity with
  # collect_project_group and collect_all_projects. Non-Conductor only
  # (resolve_remote_for_dead_cwd short-circuits */conductor/workspaces/*
  # and */.conductor/* at :1297 because those need sibling-worktree data,
  # not ancestor walk).
  if [ -z "$selected_remote" ] && [ -n "$cwd" ] && [ ! -e "$cwd" ]; then
    selected_remote=$(resolve_remote_for_dead_cwd "$cwd" 2>/dev/null || true)
  fi

  # Conductor dead-workspace fallback: list_projects_grouped's
  # backfill_conductor_remotes pre-pass walks sibling Conductor workspaces
  # and writes the recovered remote into ~/.paxel/cache/project-remotes-v2.tsv
  # (schema: dir<TAB>key<TAB>sessions<TAB>mtime<TAB>inferred). Single-line
  # awk lookup is cheap — avoids the full load_project_cache scan when
  # --project X is invoked directly. Skips fallback keys (name:/local:/unknown)
  # which would fail the exact-string Codex/Cursor filter downstream anyway.
  #
  # Gated on dead cwd (matching the upstream resolver gate above). A live
  # project with no origin shouldn't resurrect a stale cached key — the
  # correct behavior there is fail-closed, same as pre-PR.
  #
  # Staleness: load_project_cache revalidates `inferred=1` rows on its next
  # run by forcing them into the miss set. This fallback reads raw TSV
  # without revalidation. Accepted ceiling — the inferred remote was
  # correct at last backfill; users who suspect staleness can
  # `bin/upload --clear-cache` or run `--all` to refresh.
  if [ -z "$selected_remote" ] && [ -n "$cwd" ] && [ ! -e "$cwd" ]; then
    local _cache_file="${HOME}/.paxel/cache/project-remotes-v2.tsv"
    if [ -f "$_cache_file" ]; then
      local _cached_key
      _cached_key=$(awk -F'\t' -v d="$project" '$1==d{print $2; exit}' "$_cache_file" 2>/dev/null || true)
      case "$_cached_key" in
        name:*|local:*|unknown|'') ;;
        *) selected_remote="$_cached_key" ;;
      esac
    fi
  fi

  # Collect matching Codex sessions via collect_codex_sessions helper. Gate on
  # non-empty remote — an empty selected_remote tells the helper to include
  # every repo's sessions (--all mode), which would widen a scoped upload.
  # Handoff gotcha #5.
  if [ -n "$selected_remote" ]; then
    collect_codex_sessions "$tmpdir" "$selected_remote"
  fi

  # Write a _metadata.json entry for the selected Claude project dir so
  # the server's TranscriptDiscoverer merges it with the matching Codex
  # and Cursor buckets (all three discovered by shared git_remote) instead
  # of creating a separate Project keyed by encoded_name.
  if [ -n "$selected_remote" ] && command -v jq &>/dev/null; then
    [ ! -f "$tmpdir/_metadata.json" ] && echo '{"version":1,"directories":{}}' > "$tmpdir/_metadata.json"
    local claude_updated
    claude_updated=$(jq \
      --arg dir "$project" \
      --arg remote "$selected_remote" \
      --arg cwd "${cwd:-}" \
      '.directories[$dir] = {"git_remote": $remote, "cwd": $cwd}' \
      "$tmpdir/_metadata.json" 2>/dev/null)
    [ -n "$claude_updated" ] && echo "$claude_updated" > "$tmpdir/_metadata.json"
  fi

  # Collect matching Cursor IDE sessions for the same git remote. Skip
  # Cursor entirely when selected_remote is empty — empty here means the
  # project's cwd is resolvable-live but has no origin, OR is dead AND
  # the ancestor/sibling recovery above also failed (or was skipped for
  # Conductor paths). extract_cursor_db treats empty as "no filter, include
  # all workspaces", which would silently upload every Cursor workspace on
  # the machine to a scoped single-project archive. Codex is also skipped
  # in this case (:2822), keeping archive behavior consistent.
  if [ -n "$selected_remote" ]; then
    if ! collect_cursor_sessions "$tmpdir" "$selected_remote"; then
      echo "  Warning: Cursor session extraction had errors. Continuing with other sessions." >&2
    fi
    if ! collect_opencode_sessions "$tmpdir" "$selected_remote"; then
      echo "  Warning: opencode session extraction had errors. Continuing with other sessions." >&2
    fi
    if ! collect_gemini_sessions "$tmpdir" "$selected_remote"; then
      echo "  Warning: Gemini session extraction had errors. Continuing with other sessions." >&2
    fi
    if ! collect_vscode_copilot_sessions "$tmpdir" "$selected_remote"; then
      echo "  Warning: VS Code Copilot session extraction had errors. Continuing with other sessions." >&2
    fi
    if ! collect_antigravity_sessions "$tmpdir" "$selected_remote"; then
      echo "  Warning: Antigravity session extraction had errors. Continuing with other sessions." >&2
    fi
  fi
  _refresh_orphan_recovery_count "$tmpdir/_metadata.json"
}

# Resolve --project NAME to PROJECT_DIRS via grouped data
resolve_project_name() {
  local name="$1"

  # First try: match against group display names
  local g=0
  while [ $g -lt ${#GROUP_DISPLAYS[@]} ]; do
    if [ "${GROUP_DISPLAYS[$g]}" = "$name" ]; then
      IFS='|' read -ra PROJECT_DIRS <<< "${GROUP_DIRS[$g]}"
      return 0
    fi
    g=$((g + 1))
  done

  # Second try: match against encoded dir names (backward compat)
  g=0
  while [ $g -lt ${#GROUP_DIRS[@]} ]; do
    local dirs_str="${GROUP_DIRS[$g]}"
    IFS='|' read -ra check_dirs <<< "$dirs_str"
    for d in "${check_dirs[@]}"; do
      if [ "$d" = "$name" ]; then
        IFS='|' read -ra PROJECT_DIRS <<< "$dirs_str"
        return 0
      fi
    done
    g=$((g + 1))
  done

  return 1
}

# --- Docker orchestration ---

check_docker() {
  local os arch
  os="$(uname -s)"
  arch="$(uname -m)"

  # Step 1: Check Docker is installed
  if ! command -v docker &>/dev/null; then
    echo "Paxel runs analysis locally in a Docker container to keep your code private." >&2
    echo "" >&2
    echo "Error: Docker is not installed or not in PATH." >&2
    echo "" >&2
    case "$os" in
      Darwin)
        echo "Install Docker Desktop for Mac:" >&2
        if [ "$arch" = "arm64" ]; then
          echo "  https://desktop.docker.com/mac/main/arm64/Docker.dmg" >&2
        else
          echo "  https://desktop.docker.com/mac/main/amd64/Docker.dmg" >&2
        fi
        echo "" >&2
        echo "Or visit: https://www.docker.com/products/docker-desktop/" >&2
        if [ -c /dev/tty ]; then
          printf "Open download page in browser? [Y/n] " >&2
          local answer
          read -r answer </dev/tty
          case "$answer" in
            n|N|no|No) ;;
            *) open "https://www.docker.com/products/docker-desktop/" ;;
          esac
        fi
        ;;
      Linux)
        echo "Install Docker via the convenience script:" >&2
        echo "  curl -fsSL https://get.docker.com | sh" >&2
        echo "" >&2
        echo "Or install via your package manager:" >&2
        echo "  Ubuntu/Debian: sudo apt-get install docker.io" >&2
        echo "  Fedora:        sudo dnf install docker-ce" >&2
        echo "  Arch:          sudo pacman -S docker" >&2
        ;;
      *)
        echo "Install Docker: https://docs.docker.com/get-docker/" >&2
        ;;
    esac
    exit 1
  fi

  # Step 2: Check daemon is running — auto-launch on macOS
  if ! docker info &>/dev/null 2>&1; then
    case "$os" in
      Darwin)
        echo "Docker is installed but its daemon isn't running. Trying to start Docker Desktop..." >&2
        # `open -a Docker` fails when the docker CLI is present without the
        # Docker Desktop app — colima, OrbStack, Rancher Desktop, a Homebrew
        # docker client, or a partial install. Guard it in an `if` (exempt from
        # set -e / the ERR trap) so the failure prints an actionable message
        # instead of tripping the generic _paxel_on_error "unexpected error".
        if ! open -a Docker 2>/dev/null; then
          echo "" >&2
          echo "Error: Docker's daemon isn't running, and we couldn't auto-start Docker Desktop (the Docker app isn't installed)." >&2
          echo "" >&2
          echo "You have the docker CLI but no running engine. Start whichever Docker runtime you use, then re-run this script:" >&2
          echo "  Docker Desktop:   open from Applications, or install at https://www.docker.com/products/docker-desktop/" >&2
          echo "  colima:           colima start" >&2
          echo "  OrbStack:         open -a OrbStack" >&2
          echo "  Rancher Desktop:  open -a 'Rancher Desktop'" >&2
          exit 1
        fi
        local waited=0
        while [ $waited -lt 60 ]; do
          if docker info &>/dev/null 2>&1; then
            echo "" >&2
            break
          fi
          printf "." >&2
          sleep 2
          waited=$((waited + 2))
        done
        if [ $waited -ge 60 ]; then
          echo "" >&2
          echo "Error: Docker's daemon didn't come up within 60 seconds." >&2
          echo "Start your Docker runtime manually (Docker Desktop, colima, OrbStack, …) and re-run this script." >&2
          exit 1
        fi
        ;;
      Linux)
        echo "Error: Docker daemon is not running." >&2
        echo "Start it with: sudo systemctl start docker" >&2
        exit 1
        ;;
      MINGW*|MSYS*|CYGWIN*)
        # Windows (Git Bash / MSYS / Cygwin). `docker info` through the docker.exe
        # shim can transiently fail while Docker Desktop's engine is still starting
        # (steven, 2026-06-06: daemon up but first probe failed), so retry a few
        # times before giving up — and NEVER suggest `systemctl`, which doesn't exist
        # here (the old `*)` fallthrough did). All probes stay in `if`/`while`
        # conditions, exempt from set -e / the ERR trap.
        local _win_waited=0
        while [ $_win_waited -lt 30 ]; do
          if docker info >/dev/null 2>&1; then
            break
          fi
          printf "." >&2
          sleep 3
          _win_waited=$((_win_waited + 3))
        done
        if ! docker info >/dev/null 2>&1; then
          echo "" >&2
          echo "Error: Docker's daemon isn't responding." >&2
          echo "Open Docker Desktop (Start menu or system tray), wait until it says \"running\", then re-run this command." >&2
          exit 1
        fi
        echo "" >&2
        ;;
      *)
        echo "Error: Docker daemon is not running." >&2
        echo "Start Docker Desktop or run: sudo systemctl start docker" >&2
        exit 1
        ;;
    esac
  fi

  # Step 3: Check Docker version >= 20.10
  local docker_version
  docker_version=$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo "0.0")
  local major minor
  major=$(echo "$docker_version" | cut -d. -f1)
  minor=$(echo "$docker_version" | cut -d. -f2)
  if [ "${major:-0}" -lt 20 ] || { [ "${major:-0}" -eq 20 ] && [ "${minor:-0}" -lt 10 ]; }; then
    echo "Error: Docker version $docker_version is too old (minimum: 20.10)." >&2
    echo "Update Docker: https://docs.docker.com/engine/install/" >&2
    exit 1
  fi

  echo "[1/17] Checking prerequisites — Docker version $docker_version ✓"
}

save_token() {
  mkdir -p "$(dirname "$PAXEL_TOKEN_FILE")"
  echo "$YC_TOKEN" > "$PAXEL_TOKEN_FILE"
  chmod 600 "$PAXEL_TOKEN_FILE"
  echo "  Token saved to $PAXEL_TOKEN_FILE"
}

# Validate a token against /api/v1/token/check. Returns 0 on 200, 1 otherwise.
#
# Also sets `$_PAXEL_LAST_TOKEN_CHECK_CODE` to one of:
#   "skip"  — PAXEL_SKIP_TOKEN_VALIDATION=1 short-circuit
#   "empty" — empty token argument
#   "000"   — curl failure (DNS / connect / timeout)
#   <http>  — HTTP status code from /api/v1/token/check
# Callers can inspect this to tailor error messages (401 = invalid credentials,
# 403 = blocked access, 5xx/000 = server blip). The return value stays binary so the escape
# hatch (PAXEL_SKIP_TOKEN_VALIDATION=1) and the happy path stay simple.
#
# PAXEL_SKIP_TOKEN_VALIDATION=1 bypasses the curl. All three token sources
# (env-var, baked-from-URL, saved-file) now validate via this endpoint. Escape
# hatch mirrors PAXEL_SKIP_PREFLIGHT.
_PAXEL_LAST_TOKEN_CHECK_CODE=""
validate_token() {
  local token="$1"
  if [ "${PAXEL_SKIP_TOKEN_VALIDATION:-0}" = "1" ]; then
    _PAXEL_LAST_TOKEN_CHECK_CODE="skip"
    return 0
  fi
  if [ -z "$token" ]; then
    _PAXEL_LAST_TOKEN_CHECK_CODE="empty"
    return 1
  fi
  # The `|| http_code="000"` fallback has to live OUTSIDE the command
  # substitution: curl writes its `%{http_code}` output ("000" on
  # connection failure) to stdout AND exits non-zero. An `|| echo "000"`
  # INSIDE `$(...)` concatenates to "000000", which the 000) case arm
  # below would silently miss. PR #655 dual-review (Codex + Opus)
  # caught this after the initial commit — tests stubbed `return 7`
  # with no stdout, which didn't match real curl behavior.
  local http_code
  http_code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
    -H "X-YC-Token: ${token}" \
    "${PAXEL_SERVER}/api/v1/token/check" 2>/dev/null) || http_code="000"
  _PAXEL_LAST_TOKEN_CHECK_CODE="$http_code"
  [ "$http_code" = "200" ]
}

print_token_access_blocked() {
  echo "Error: Paxel access is blocked for this token." >&2
  echo "  Email paxel@ycombinator.com if this looks wrong." >&2
}

# Terminal: every other call would get the same answer from this network, so
# callers should exit right after printing this. The state line defaults to
# the pre-run case; the exit-9 banner overrides it because there the analysis
# already finished and only the upload was refused.
print_region_blocked() {
  local state="${1:-Nothing was analyzed or uploaded.}"
  echo "Error: Paxel isn't available in your country or region." >&2
  echo "  The server answered HTTP 451 for this network. ${state}" >&2
  echo "  There's nothing to fix on your end." >&2
}

# Exit status for a run stopped because the account's analysis budget is spent.
# Distinct from the container's codes (3 no analyzable sessions, 4 upload
# deferred, 5 upload failed) so a budget stop never reads as a crash, and 6 is
# left free for the container to signal a budget stop it hits mid-run.
PAXEL_EXIT_QUOTA_STOPPED=7

# First value for KEY in a small JSON body: strings come back unquoted, numbers
# and booleans verbatim, a missing key OR a null as "". Same shape as the
# device-auth poll parser, and it keeps jq off the dependency list. Assumes the
# compact, space-free output of the server's JSON renderer.
_paxel_json_value() {
  local match
  match=$(printf '%s' "$1" | grep -Eo "\"$2\":(\"[^\"]*\"|[^,}]*)" | head -1 || true)
  [ -z "$match" ] && return 0
  match="${match#*:}"
  match="${match#\"}"
  match="${match%\"}"
  [ "$match" = "null" ] && return 0
  printf '%s' "$match"
}

_paxel_is_uint() {
  case "${1:-}" in
    ""|*[!0-9]*) return 1 ;;
  esac
  return 0
}

_paxel_dollars() {
  printf '$%d.%02d' "$(($1 / 100))" "$(($1 % 100))"
}

# Shared tail for the two limits that a UTC-midnight reset actually clears.
_paxel_quota_reset_advice() {
  echo "  Re-run after the reset. Your cached analysis from earlier runs is kept, so it"
  echo "  picks up where this stopped instead of paying for the same work twice. A report"
  echo "  that finished but never uploaded still goes out on your next run."
  echo ""
  echo "  Need more today? Email paxel@ycombinator.com and say what you're analyzing."
}

# Read the account's daily analysis budget from token/check and stop the run
# with the real numbers if it's spent, instead of letting the user find out
# several paid minutes into the pipeline.
#
# FAILS OPEN on everything it cannot read — curl failure, any non-200, a server
# with no `quota` block, an unparseable field. This is advisory; the LLM proxy is
# what actually enforces the cap, so a hiccup reading a status endpoint must
# never be able to stop a run. Only a positively-parsed `"ok":false` stops
# anything. The fail-open paths are silent on purpose: "couldn't check your
# budget" would read as a fault on a run that is about to work fine.
check_daily_quota() {
  [ "${PAXEL_SKIP_TOKEN_VALIDATION:-0}" = "1" ] && return 0
  [ -z "${YC_TOKEN:-}" ] && return 0

  local response
  response=$(curl -s -w '\n%{http_code}' --max-time 5 \
    -H "X-YC-Token: ${YC_TOKEN}" \
    "${PAXEL_SERVER}/api/v1/token/check" 2>/dev/null) || return 0
  [ "$(printf '%s' "$response" | tail -1)" = "200" ] || return 0

  local body
  body=$(printf '%s' "$response" | sed '$d')
  [ "$(_paxel_json_value "$body" "ok")" = "false" ] || return 0

  local reason scope resets_at retry_after_reset spent cost_limit calls calls_limit
  reason=$(_paxel_json_value "$body" "reason")
  scope=$(_paxel_json_value "$body" "scope")
  resets_at=$(_paxel_json_value "$body" "resets_at")
  retry_after_reset=$(_paxel_json_value "$body" "retry_after_reset")
  spent=$(_paxel_json_value "$body" "daily_cost_cents")
  cost_limit=$(_paxel_json_value "$body" "daily_cost_limit_cents")
  calls=$(_paxel_json_value "$body" "daily_calls")
  calls_limit=$(_paxel_json_value "$body" "daily_calls_limit")

  local reset_display="midnight UTC"
  [ -n "$resets_at" ] && reset_display="$resets_at (midnight UTC)"

  local spend_today=""
  if _paxel_is_uint "$spent" && _paxel_is_uint "$cost_limit"; then
    spend_today="$(_paxel_dollars "$spent") of $(_paxel_dollars "$cost_limit")"
  fi

  case "$reason" in
    daily_cost_exceeded)
      if [ -z "$spend_today" ]; then return 0; fi
      {
        echo ""
        echo "Daily analysis budget spent — stopping before the container starts."
        echo ""
        echo "  Spent today:  $spend_today"
        echo "  Resets:       $reset_display"
        if [ "$scope" = "account" ]; then
          echo "  Every upload token on your account draws on this same budget, so signing in"
          echo "  again won't reset it."
        fi
        echo ""
        _paxel_quota_reset_advice
      } >&2
      ;;
    daily_calls_exceeded)
      if ! _paxel_is_uint "$calls" || ! _paxel_is_uint "$calls_limit"; then return 0; fi
      {
        echo ""
        echo "Daily analysis call limit reached — stopping before the container starts."
        echo ""
        echo "  Calls today:  $calls of $calls_limit"
        echo "  Resets:       $reset_display"
        if [ "$scope" = "account" ]; then
          echo "  Every upload token on your account draws on this same limit, so signing in"
          echo "  again won't reset it."
        fi
        echo ""
        _paxel_quota_reset_advice
      } >&2
      ;;
    exhausted|proxy_exhausted)
      # A per-token lifetime limit is the one quota a new credential legitimately
      # clears, and it is safe to clear it that way now: the daily budget follows
      # the ACCOUNT, so a replacement token inherits the same wallet and rotating
      # buys no extra spend. Drop the cached token so the next run signs in again
      # — without this the run would stop here on every retry, since token/check
      # now (correctly) reports the credential as valid.
      rm -f "${PAXEL_TOKEN_FILE:-$HOME/.paxel/token}" 2>/dev/null || true
      {
        echo ""
        echo "Upload token limit reached — stopping before the container starts."
        echo ""
        echo "  This upload token was issued with a fixed usage limit and has reached it."
        echo "  That limit doesn't reset at midnight, so waiting won't clear it."
        [ -n "$spend_today" ] && echo "  Today's spend is $spend_today, so the daily budget isn't what stopped you."
        echo ""
        if [ -n "${PAXEL_BAKED_TOKEN:-}" ]; then
          # The baked token takes precedence over the cached one, so clearing the
          # cache cannot help here — this user needs a new command.
          echo "  Grab a fresh upload command from your Paxel dashboard and run that."
        else
          echo "  Re-run and you'll be signed in again with a fresh token; your daily budget"
          echo "  is unchanged, and any report that finished but never uploaded still goes out."
        fi
        echo "  Still stuck? Email paxel@ycombinator.com."
      } >&2
      ;;
    *)
      {
        echo ""
        echo "Stopping before the container starts — the server won't admit new analysis"
        echo "for this account right now."
        echo ""
        echo "  Server reported: ${reason:-no reason given}"
        [ -n "$spend_today" ] && echo "  Spent today:     $spend_today"
        if [ "$retry_after_reset" = "true" ]; then
          echo "  Clears at:       $reset_display — re-run after that."
        else
          echo "  Waiting won't clear this one."
        fi
        echo ""
        echo "  Email paxel@ycombinator.com with the lines above and we'll sort it out."
      } >&2
      ;;
  esac

  exit "$PAXEL_EXIT_QUOTA_STOPPED"
}

# Try browser-based device auth flow. Opens browser, polls for token.
# Returns 0 on success (YC_TOKEN set), 1 on failure (fall back to manual).
try_device_auth() {
  # Generate 8-char alphanumeric code
  local code
  code=$(LC_ALL=C tr -dc 'A-Z0-9' < /dev/urandom 2>/dev/null | head -c 8 || true)
  if [ ${#code} -lt 8 ]; then
    return 1
  fi

  # Register the code with the server
  local register_response register_http
  register_response=$(curl -s -w "\n%{http_code}" -X POST \
    -H "Content-Type: application/json" \
    -d "{\"code\":\"${code}\"}" \
    "${PAXEL_SERVER}/auth/cli/register" 2>/dev/null)
  register_http=$(echo "$register_response" | tail -1)

  if [ "$register_http" = "451" ]; then
    # Falling back to manual token entry would send the user to a dashboard
    # page the fence also blocks. Stop here.
    print_region_blocked
    exit 1
  fi

  if [ "$register_http" != "201" ]; then
    return 1
  fi

  # Open browser
  local auth_url="${PAXEL_SERVER}/auth/cli?code=${code}"
  echo ""
  echo "[2/17] Signing you in — opening browser..."
  echo "  If the browser doesn't open, visit: $auth_url"
  echo "  Authorize the CLI in your browser. If you're asked to sign in, we'll email you a login link — check spam if it's slow."
  echo ""

  if command -v open &>/dev/null; then
    open "$auth_url"
  elif command -v xdg-open &>/dev/null; then
    xdg-open "$auth_url" &>/dev/null &
  else
    echo "  Open this URL in your browser: $auth_url"
  fi

  # Poll for token
  local poll_url="${PAXEL_SERVER}/auth/cli/poll?code=${code}"
  local waited=0
  local max_wait=600
  local poll_interval=2

  printf "  Waiting for browser authorization"
  while [ $waited -lt $max_wait ]; do
    local poll_response poll_body poll_http poll_status
    # -w adds the HTTP status on its own line so a 451 (geo-fence mid-poll)
    # stops the loop instead of dotting for the full 600s — a 451 body has no
    # "status" field, which the `*)` arm would otherwise read as "keep waiting".
    poll_response=$(curl -s -w "\n%{http_code}" "$poll_url" 2>/dev/null) || poll_response=""
    poll_http=$(echo "$poll_response" | tail -1)
    poll_body=$(echo "$poll_response" | sed '$d')
    if [ "$poll_http" = "451" ]; then
      echo ""
      print_region_blocked
      exit 1
    fi
    # || true: empty poll_status is expected while the user hasn't clicked yet;
    # the case `*)` branch below treats it as "keep waiting". grep no-match under
    # pipefail would otherwise fire a false ERR banner each poll.
    poll_status=$(echo "$poll_body" | grep -o '"status":"[^"]*"' | head -1 | cut -d'"' -f4 || true)

    case "$poll_status" in
      complete)
        # Server said complete but may have returned an unexpected shape. Use
        # || true so grep no-match doesn't fire the ERR banner, then check and
        # surface a specific message if the token is missing.
        YC_TOKEN=$(echo "$poll_response" | grep -o '"token":"[^"]*"' | head -1 | cut -d'"' -f4 || true)
        if [ -z "$YC_TOKEN" ]; then
          echo ""
          echo "  Server returned complete without a token — falling back to manual sign-in." >&2
          return 1
        fi
        echo ""
        echo "  Authenticated!"
        save_token
        return 0
        ;;
      expired|not_found)
        echo ""
        echo "  Session expired." >&2
        return 1
        ;;
      *)
        printf "."
        sleep $poll_interval
        waited=$((waited + poll_interval))
        ;;
    esac
  done

  echo ""
  echo "  Browser auth timed out." >&2
  return 1
}

# Manual fallback: prompt user to paste token
manual_token_entry() {
  echo ""
  echo "[2/17] Signing you in..."
  echo "  Get your upload token at: ${PAXEL_SERVER}/auth/login"
  echo "  After logging in, copy the upload token from your dashboard. It starts"
  echo "  with 'yk_' — don't paste the report-link token shown on a results page."
  echo ""

  # Validate the format before saving. Upload tokens are "yk_…"; the 24-char
  # report-link token (shown on results pages) is the common mis-paste and would
  # otherwise fail much later with a confusing "Token not recognized" once the
  # pipeline first hits the LLM proxy. Re-prompt so the user can correct it in
  # place instead of re-running the whole command. Capped so a non-tty / piped
  # stdin can't loop forever.
  local attempts=0
  while :; do
    printf "  Paste your token: "
    user_read -r YC_TOKEN
    YC_TOKEN=$(echo "$YC_TOKEN" | tr -d '[:space:]')
    attempts=$((attempts + 1))

    case "$YC_TOKEN" in
      "")
        echo "Error: No token provided." >&2
        ;;
      yk_*)
        break
        ;;
      *)
        echo "  That doesn't look like an upload token — those start with 'yk_'." >&2
        echo "  You may have copied a report-link token. Get your upload token at:" >&2
        echo "    ${PAXEL_SERVER}/auth/login" >&2
        ;;
    esac

    if [ "$attempts" -ge 3 ]; then
      echo "Error: No valid upload token provided." >&2
      exit 1
    fi
  done

  save_token
}

# Send local git identity to server for pre-matching
register_git_identity() {
  local git_name git_email
  git_name=$(git config user.name 2>/dev/null || true)
  git_email=$(git config user.email 2>/dev/null || true)
  [ -z "$git_name" ] && [ -z "$git_email" ] && return 0

  # Escape values for JSON safety (handles quotes, backslashes in git names)
  local json_name json_email
  json_name=$(printf '%s' "$git_name" | sed 's/\\/\\\\/g; s/"/\\"/g')
  json_email=$(printf '%s' "$git_email" | sed 's/\\/\\\\/g; s/"/\\"/g')

  curl -s -X POST "${PAXEL_SERVER}/api/v1/identity/register" \
    -H "X-YC-Token: ${YC_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{\"git_name\":\"${json_name}\",\"git_email\":\"${json_email}\"}" \
    >/dev/null 2>&1 || true
}

# Detect the user's git email(s) for a specific repo.
# Fully client-side — no data sent to server.
# Returns pipe-delimited list of emails, or empty string if none found.
#
# Three signals:
#   1. git config user.email — the configured email for this repo
#   2. Session SHAs — commits made during Claude Code sessions, cross-referenced
#      with git log to find the author email (definitively the user's commits)
#   3. Name match — all emails in git log where author name matches git config
#      user.name (case-insensitive), catching other emails used by the same person
detect_author_emails() {
  local dir_cwd="$1"
  local session_dirs="$2"
  local emails=()

  # Source 1: git config for THIS repo (not global cwd)
  local config_email
  config_email=$(git -C "$dir_cwd" config user.email 2>/dev/null || true)
  [ -n "$config_email" ] && emails+=("$config_email")

  # Source 2: Session SHAs → git log author email
  # Extract short SHAs from git_commit events in session transcripts,
  # then look up the author email for each from the local git repo.
  local sha_emails=""
  local session_dir
  while IFS= read -r session_dir; do
    [ -d "$session_dir" ] || continue
    local dir_sha_emails
    # || true: grep no-match exits 1 under pipefail, which fires the ERR trap
    # even though an empty result is expected here. Do not remove.
    dir_sha_emails=$(grep -roh '"type":"git_commit"[^}]*"sha":"[a-f0-9]*"' "$session_dir" 2>/dev/null \
      | grep -o '"sha":"[a-f0-9]*"' | sed 's/"sha":"//;s/"//' | sort -u \
      | while read -r sha; do
          git -C "$dir_cwd" log "$sha" -1 --format='%aE' 2>/dev/null
        done | sort -u || true)
    sha_emails="${sha_emails}"$'\n'"${dir_sha_emails}"
  done <<< "$session_dirs"
  local e
  for e in $sha_emails; do
    [ -n "$e" ] && emails+=("$e")
  done

  # Source 3: Name match — find all emails where git author name matches
  # the user's configured name (case-insensitive exact match).
  # Catches multi-email cases like alice@gmail.com when name is "Alice Example".
  # Assumes author names are unique per person in a repo (validated against prod data).
  local config_name
  config_name=$(git -C "$dir_cwd" config user.name 2>/dev/null || true)
  if [ -n "$config_name" ]; then
    # Escape regex special chars in the name for safe grep
    local escaped_name
    escaped_name=$(printf '%s' "$config_name" | sed 's/[.+*?^$[\]\\]/\\&/g')
    local name_emails
    # || true: grep no-match exits 1 under pipefail → false ERR banner when
    # no git author name matches user.name (e.g. brand-new repo). Do not remove.
    name_emails=$(git -C "$dir_cwd" log --format='%aN|%aE' 2>/dev/null | sort -u \
      | grep -i "^${escaped_name}|" | cut -d'|' -f2 | sort -u || true)
    for e in $name_emails; do
      [ -n "$e" ] && emails+=("$e")
    done
  fi

  # Deduplicate and return pipe-delimited
  if [ ${#emails[@]} -gt 0 ]; then
    printf '%s\n' "${emails[@]}" | sort -u | tr '\n' '|' | sed 's/|$//'
  fi
}

# Collect author-filtered commits for episode linking.
# Writes _author_commits.jsonl and _author_numstat.txt alongside existing files.
collect_author_commits() {
  local dir_cwd="$1"
  local git_data_dir="$2"
  local encoded="$3"
  local author_emails="$4"  # pipe-delimited
  local oldest_session_date="$5"  # ISO date or empty
  local commit_limit="${6:-}"
  local newest_session_date="${7:-}"

  [ -z "$author_emails" ] && return 0

  # Build --author flags with regex-safe escaping
  # git --author is a regex match on "Author Name <email>",
  # so we anchor to <email> to avoid partial matches on . and +
  local author_flags=()
  IFS='|' read -ra email_arr <<< "$author_emails"
  for email in "${email_arr[@]}"; do
    [ -z "$email" ] && continue
    local escaped
    escaped=$(printf '%s' "$email" | sed 's/[.+*?^$[\]\\]/\\&/g')
    author_flags+=(--author="<${escaped}>")
  done

  [ ${#author_flags[@]} -eq 0 ] && return 0

  local since_flag=""
  [ -n "$oldest_session_date" ] && since_flag="--since=$oldest_session_date"
  local limit_flag=()
  [ -n "$commit_limit" ] && limit_flag=("-${commit_limit}")

  # Author-filtered commits for episode linking. TAB-separated, subject
  # LAST: git's %s is raw, so a literal quote/backslash/control char in a commit
  # subject would corrupt a JSON line and silently drop that commit (audit C13).
  # A fixed-order TSV is robust to any subject content. Parsed by
  # ClientPipeline#parse_commits_tsv (the .jsonl extension is historical).
  if [ -n "$newest_session_date" ]; then
    git -C "$dir_cwd" log "${author_flags[@]}" --until="$newest_session_date" \
      --format='%H%x09%h%x09%aN%x09%aE%x09%aI%x09%s' 2>/dev/null \
      | awk -F '\t' -v since="$oldest_session_date" -v max="${commit_limit:-1000}" '
          substr($5, 1, 10) >= since { print; count++; if (count >= max) exit }
        ' > "${git_data_dir}/${encoded}_author_commits.jsonl" || true

    _run_with_timeout "$PAXEL_GIT_TIMEOUT" \
      git -C "$dir_cwd" log "${author_flags[@]}" --until="$newest_session_date" \
      --format='COMMIT_BOUNDARY %H %aI %aN <%aE>' --numstat 2>/dev/null \
      | awk -v since="$oldest_session_date" -v max="${commit_limit:-1000}" '
          /^COMMIT_BOUNDARY / {
            keep = substr($3, 1, 10) >= since && count < max
            if (keep) { print; count++ }
            next
          }
          keep { print }
        ' > "${git_data_dir}/${encoded}_author_numstat.txt" || true
  else
    git -C "$dir_cwd" log "${author_flags[@]}" "${limit_flag[@]}" $since_flag \
      --format='%H%x09%h%x09%aN%x09%aE%x09%aI%x09%s' \
      > "${git_data_dir}/${encoded}_author_commits.jsonl" 2>/dev/null || true

    _run_with_timeout "$PAXEL_GIT_TIMEOUT" \
      git -C "$dir_cwd" log "${author_flags[@]}" "${limit_flag[@]}" $since_flag \
      --format='COMMIT_BOUNDARY %H %aI %aN <%aE>' --numstat \
      > "${git_data_dir}/${encoded}_author_numstat.txt" 2>/dev/null || true
  fi

  # Log what we collected
  local author_count
  author_count=$(wc -l < "${git_data_dir}/${encoded}_author_commits.jsonl" 2>/dev/null | tr -d ' ')
  if [ "${author_count:-0}" -gt 5000 ]; then
    echo "  Warning: ${author_count} author commits collected (large)" >&2
  fi
  if [ "${author_count:-0}" -gt 0 ]; then
    local email_count=${#email_arr[@]}
    local email_label="email"
    [ "$email_count" -ne 1 ] && email_label="emails"
    local email_list
    email_list=$(IFS=', '; echo "${email_arr[*]}")
    echo "  Git: ${author_count} author-filtered commits (${email_count} ${email_label}: ${email_list})" >&2
  fi
}

# Resolve the activity window start: PAXEL_ACTIVITY_WINDOW_DAYS ago, or the
# --since date when that is later. Prints YYYY-MM-DD (empty if date failed).
# SINCE_EPOCH is local midnight (parse_since), so it is rendered in local time
# like the numstat since_flag; a UTC render would start UTC+ users a day early.
_activity_since_date() {
  local window_start since_date
  window_start=$(date -u -v-"${PAXEL_ACTIVITY_WINDOW_DAYS}"d '+%Y-%m-%d' 2>/dev/null \
    || date -u -d "${PAXEL_ACTIVITY_WINDOW_DAYS} days ago" '+%Y-%m-%d' 2>/dev/null || echo '')
  if [ -n "${SINCE_EPOCH:-}" ]; then
    since_date=$(date -r "$SINCE_EPOCH" '+%Y-%m-%d' 2>/dev/null || date -d "@$SINCE_EPOCH" '+%Y-%m-%d' 2>/dev/null || echo '')
    if [ -n "$since_date" ] && [[ "$since_date" > "$window_start" ]]; then
      window_start="$since_date"
    fi
  fi
  printf '%s' "$window_start"
}

# <key>_activity.tsv: "# since=DATE" then "day \t email \t name \t count", plus
# a fifth column with the commit's Co-authored-by trailers (\x1f-separated)
# when it has any, aggregated here so the file stays a few KB regardless of
# repo size. Rows split on the trailers so the client can credit a coding
# agent's commits to the human named in them; it re-merges the rest. Author
# date, author-local calendar day (same convention the numstat parser uses).
# git --since filters on committer date and anchors a date-only value at the
# current time of day, so the bound is the earliest instant at which `since`
# has begun anywhere (UTC+14); the awk guard then trims by author-local day,
# which also drops rebased commits whose author day predates the window.
# A failed or timed-out git leaves a header-only file: partial rows would
# otherwise be preferred over the numstat and pass for a full window.
_collect_repository_activity() {
  local dir_cwd="$1" out="$2"
  local since
  since=$(_activity_since_date)
  [ -n "$since" ] || return 0
  local raw="${out}.raw.$$"
  if _run_with_timeout "$PAXEL_GIT_TIMEOUT" \
       git -C "$dir_cwd" log --since="${since}T00:00:00+14:00" \
         --format='%aI%x09%aE%x09%aN%x09%(trailers:key=Co-authored-by,valueonly,separator=%x1f)' > "$raw" 2>/dev/null; then
    {
      printf '# since=%s\n' "$since"
      awk -F'\t' -v since="$since" '
          NF >= 3 && substr($1, 1, 10) >= since { k = substr($1, 1, 10) "\t" tolower($2) "\t" $3; c[k "\t" $4]++ }
          END { for (k in c) { n = split(k, p, "\t"); row = p[1] "\t" p[2] "\t" p[3] "\t" c[k]; if (n > 3 && p[4] != "") row = row "\t" p[4]; print row } }
        ' < "$raw" \
      | LC_ALL=C sort
    } > "$out" 2>/dev/null || true
  else
    printf '# since=%s\n' "$since" > "$out" 2>/dev/null || true
  fi
  rm -f "$raw" 2>/dev/null || true
  return 0
}

collect_repository_git_data() {
  local dir_cwd="$1"
  local git_data_dir="$2"
  local encoded="$3"
  local session_dir="$4"
  local oldest_epoch="${5:-}"
  local mode="${6:-scoped}"
  local newest_epoch="${7:-}"

  local repo_root
  repo_root=$(git -C "$dir_cwd" rev-parse --show-toplevel 2>/dev/null || true)
  [ -n "$repo_root" ] || return 0
  dir_cwd="$repo_root"
  mkdir -p "$git_data_dir"

  local since_flag=""
  if [ -n "${SINCE_EPOCH:-}" ]; then
    since_flag="--since=$(date -r "$SINCE_EPOCH" '+%Y-%m-%d' 2>/dev/null || date -d "@$SINCE_EPOCH" '+%Y-%m-%d' 2>/dev/null || echo '')"
  fi

  git -C "$dir_cwd" rev-list --count HEAD \
    > "${git_data_dir}/${encoded}_commit_count.txt" 2>/dev/null || true
  # COAUTHORS sits on its own line so older client images skip it. Git before
  # 2.23 prints the trailer placeholder literally, which the client ignores.
  _run_with_timeout "$PAXEL_GIT_TIMEOUT" \
    git -C "$dir_cwd" log -${COMMIT_LIMIT:-1000} $since_flag \
    --format='COMMIT_BOUNDARY %H %aI %aN <%aE>%nCOAUTHORS %(trailers:key=Co-authored-by,valueonly,separator=%x1f)' --numstat \
    > "${git_data_dir}/${encoded}_numstat.txt" 2>/dev/null || true

  _collect_repository_activity "$dir_cwd" "${git_data_dir}/${encoded}_activity.tsv"

  [ "$mode" = "aggregate" ] && return 0

  if [ "$mode" != "repository_aware" ]; then
    git -C "$dir_cwd" log -${COMMIT_LIMIT:-1000} $since_flag \
      --format='%H%x09%h%x09%aN%x09%aE%x09%aI%x09%s' \
      > "${git_data_dir}/${encoded}_commits.jsonl" 2>/dev/null || true
  fi

  local author_emails
  author_emails=$(detect_author_emails "$dir_cwd" "$session_dir")
  if [ -n "$author_emails" ]; then
    if [ -n "${SINCE_EPOCH:-}" ]; then
      if [ -z "$oldest_epoch" ] || [ "$oldest_epoch" -lt "$SINCE_EPOCH" ]; then
        oldest_epoch="$SINCE_EPOCH"
      fi
    fi
    local oldest_date=""
    if [ -n "$oldest_epoch" ]; then
      oldest_date=$(date -r "$oldest_epoch" '+%Y-%m-%d' 2>/dev/null || date -d "@$oldest_epoch" '+%Y-%m-%d' 2>/dev/null || echo '')
    fi
    local newest_date=""
    if [ -n "$newest_epoch" ]; then
      newest_date=$(date -r "$newest_epoch" '+%Y-%m-%d' 2>/dev/null || date -d "@$newest_epoch" '+%Y-%m-%d' 2>/dev/null || echo '')
    fi
    collect_author_commits "$dir_cwd" "$git_data_dir" "$encoded" "$author_emails" "$oldest_date" "${COMMIT_LIMIT:-1000}" "$newest_date"
  fi
}

load_or_request_token() {
  # 1. Check environment variable. Validate against the server so an expired
  #    env var fails pre-Docker instead of 5 minutes into the pipeline.
  #    PAXEL_SKIP_TOKEN_VALIDATION=1 restores the pre-validation behavior for
  #    CI / tests / air-gapped runs where the server is unreachable by design.
  if [ -n "${YC_TOKEN:-}" ]; then
    if validate_token "$YC_TOKEN"; then
      echo "[2/17] Signed in via environment token ✓"
      return
    fi
    echo "" >&2
    # Copy reflects the actual failure mode — "invalid or expired" overpromises
    # diagnostic confidence when the real cause is a 5xx or network blip.
    case "$_PAXEL_LAST_TOKEN_CHECK_CODE" in
      401)
        echo "Error: YC_TOKEN env var is invalid or expired." >&2
        echo "  Refresh at: ${PAXEL_SERVER}/auth/login" >&2
        ;;
      403)
        print_token_access_blocked
        exit 1
        ;;
      451)
        print_region_blocked
        exit 1
        ;;
      000)
        echo "Error: Couldn't reach ${PAXEL_SERVER} to verify YC_TOKEN." >&2
        echo "  Check your network connection and try again." >&2
        ;;
      5[0-9][0-9])
        echo "Error: ${PAXEL_SERVER} couldn't verify YC_TOKEN (server returned ${_PAXEL_LAST_TOKEN_CHECK_CODE})." >&2
        echo "  This is usually temporary — wait a minute and try again." >&2
        ;;
      *)
        echo "Error: YC_TOKEN failed validation (code: ${_PAXEL_LAST_TOKEN_CHECK_CODE})." >&2
        echo "  Refresh at: ${PAXEL_SERVER}/auth/login" >&2
        ;;
    esac
    echo "  Or unset YC_TOKEN to use your saved token / browser auth." >&2
    echo "  CI / air-gapped: set PAXEL_SKIP_TOKEN_VALIDATION=1 to bypass." >&2
    exit 1
  fi

  # 2. Baked token from URL takes priority — it's the freshest, user-specific token.
  #    Validate before trusting: a stale URL (bookmarked `bin/upload` target, expired
  #    session, revoked token) can bake a dead token. On validation failure, fall
  #    through to the saved-token path — do NOT overwrite a valid saved token with
  #    an invalid baked one.
  if [ -n "${PAXEL_BAKED_TOKEN:-}" ]; then
    if validate_token "$PAXEL_BAKED_TOKEN"; then
      local saved_token=""
      [ -f "$PAXEL_TOKEN_FILE" ] && saved_token=$(cat "$PAXEL_TOKEN_FILE" | tr -d '[:space:]')

      if [ "$saved_token" = "$PAXEL_BAKED_TOKEN" ]; then
        # Saved token matches the URL token — use it
        YC_TOKEN="$PAXEL_BAKED_TOKEN"
        echo "[2/17] Signed in ✓"
        return
      elif [ -n "$saved_token" ] && [ "$saved_token" != "$PAXEL_BAKED_TOKEN" ]; then
        # Saved token is for a DIFFERENT account — replace it
        echo "[2/17] Switching to your account..."
        YC_TOKEN="$PAXEL_BAKED_TOKEN"
        save_token
        return
      else
        # No saved token — save the baked one
        YC_TOKEN="$PAXEL_BAKED_TOKEN"
        save_token
        echo "[2/17] Signed in ✓"
        return
      fi
    fi
    # Differentiate revoked-token from server-blip — "Sign-in link expired" is
    # misleading when the real cause is a 5xx or network failure.
    case "$_PAXEL_LAST_TOKEN_CHECK_CODE" in
      401)
        echo "[2/17] Sign-in link expired — trying saved token or browser auth..."
        ;;
      403)
        print_token_access_blocked
        exit 1
        ;;
      451)
        # Don't fall through to browser auth — the region block answers every
        # Paxel endpoint, so device auth would 451 too and then prompt the
        # user to paste a token from a page they can't load.
        print_region_blocked
        exit 1
        ;;
      000)
        echo "[2/17] Couldn't reach ${PAXEL_SERVER} to verify sign-in link — trying saved token or browser auth..."
        ;;
      5[0-9][0-9])
        echo "[2/17] Sign-in link check failed (server ${_PAXEL_LAST_TOKEN_CHECK_CODE}) — trying saved token or browser auth..."
        ;;
      *)
        echo "[2/17] Sign-in link check failed (code ${_PAXEL_LAST_TOKEN_CHECK_CODE}) — trying saved token or browser auth..."
        ;;
    esac
  fi

  # 3. Check for existing saved token — validate it against the current server
  if [ -f "$PAXEL_TOKEN_FILE" ]; then
    local saved_token
    saved_token=$(cat "$PAXEL_TOKEN_FILE" | tr -d '[:space:]')
    if [ -n "$saved_token" ]; then
      if validate_token "$saved_token"; then
        YC_TOKEN="$saved_token"
        echo "[2/17] Signed in ✓"
        return
      else
        case "$_PAXEL_LAST_TOKEN_CHECK_CODE" in
          401)
            echo "[2/17] Session expired, signing you in again..."
            rm -f "$PAXEL_TOKEN_FILE"
            ;;
          403)
            print_token_access_blocked
            exit 1
            ;;
          451)
            print_region_blocked
            exit 1
            ;;
          000)
            echo "Error: Couldn't reach ${PAXEL_SERVER} to verify your saved token." >&2
            echo "  Check your network connection and try again." >&2
            exit 1
            ;;
          5[0-9][0-9])
            echo "Error: ${PAXEL_SERVER} couldn't verify your saved token (server returned ${_PAXEL_LAST_TOKEN_CHECK_CODE})." >&2
            echo "  This is usually temporary — wait a minute and try again." >&2
            exit 1
            ;;
          *)
            echo "Error: Your saved token failed validation (code: ${_PAXEL_LAST_TOKEN_CHECK_CODE})." >&2
            exit 1
            ;;
        esac
      fi
    fi
  fi

  # 3. Try device auth flow (browser-based), fall back to manual paste
  require_tty
  if ! try_device_auth; then
    manual_token_entry
  fi
}

PAXEL_LAST_DOCKER_PULL_ERROR=""
PAXEL_LAST_DOCKER_PULL_STORAGE_FULL=0

docker_error_is_storage_full() {
  grep -qiE "$PAXEL_DOCKER_STORAGE_ERROR_PATTERN" <<< "$1"
}

docker_error_file_is_storage_full() {
  grep -qiE "$PAXEL_DOCKER_STORAGE_ERROR_PATTERN" "$1"
}

docker_pull_error_tail() {
  tail -c 4096 "$1" 2>/dev/null || true
}

docker_pull_error_line() {
  printf '%s\n' "$1" | awk 'NF { line=$0 } END { print line }'
}

print_docker_storage_error() {
  local reason="$1"
  local available_kb="${2:-}"
  local used_pct="${3:-}"
  echo "Error: Docker cannot allocate writable storage ${reason}." >&2
  if [[ "$available_kb" =~ ^[0-9]+$ ]]; then
    local available_mb=$(( (available_kb + 1023) / 1024 ))
    local usage=""
    [ -n "$used_pct" ] && usage=" and reports ${used_pct}% used"
    echo "  Docker has ${available_mb} MB available${usage}." >&2
  fi
  echo "  Free blocks can remain when Docker's inode or storage quota is exhausted." >&2
  echo "  Your project filesystem may differ from Docker's writable storage; Docker Desktop uses a separate VM disk." >&2
  echo "  Inspect usage: docker system df" >&2
  echo "  Remove unused Docker data with 'docker system prune', or increase Docker's disk allocation, then rerun Paxel." >&2
}

check_docker_storage() {
  local image="${PAXEL_CLIENT_IMAGE:-}"
  [ -z "$image" ] && return 0

  local error_file output error="" rc=0 storage_full=0 available_kb used_pct
  error_file=$(mktemp) || {
    echo "Warning: Could not create a temporary file to check Docker storage." >&2
    return 0
  }

  output=$(MSYS_NO_PATHCONV=1 docker run --rm --network none --entrypoint /bin/sh "$image" -c '
    set -e
    df -Pk /tmp
    probe=$(mktemp -d /tmp/paxel-storage-check.XXXXXX)
    trap '\''rm -rf "$probe"'\'' EXIT
    printf x > "$probe/probe"
    ln -s "$probe/probe" "$probe/link"
  ' 2>"$error_file") || rc=$?
  if [ "$rc" -ne 0 ]; then
    if docker_error_file_is_storage_full "$error_file"; then
      storage_full=1
    fi
    error=$(docker_pull_error_tail "$error_file")
  fi
  rm -f "$error_file"
  available_kb=$(printf '%s\n' "$output" | awk 'NR > 1 && $4 ~ /^[0-9]+$/ { available=$4 } END { print available }')
  used_pct=$(printf '%s\n' "$output" | awk 'NR > 1 && $5 ~ /^[0-9]+%$/ { used=$5 } END { sub(/%$/, "", used); print used }')

  if [ "$rc" -ne 0 ]; then
    if [ "$storage_full" -eq 1 ] || docker_error_is_storage_full "$error"; then
      print_docker_storage_error "to start Paxel" "$available_kb" "$used_pct"
      return 1
    fi
    echo "Warning: Could not verify Docker storage before analysis." >&2
    [ -n "$error" ] && echo "  Docker: $(docker_pull_error_line "$error")" >&2
    return 0
  fi

  if [[ "$available_kb" =~ ^[0-9]+$ ]] && [ "$available_kb" -eq 0 ]; then
    print_docker_storage_error "to run Paxel" "$available_kb" "$used_pct"
    return 1
  fi

  local low_space_kb=$((PAXEL_DOCKER_LOW_SPACE_MB * 1024))
  if [[ "$available_kb" =~ ^[0-9]+$ ]] && [ "$available_kb" -lt "$low_space_kb" ]; then
    echo "Warning: Docker has less than ${PAXEL_DOCKER_LOW_SPACE_MB} MB free; a large Paxel analysis may run out of storage." >&2
  fi
}

pull_client_image() {
  # In dev mode (localhost), build from local Dockerfile unless USE_LIVE_DOCKER=1
  if [ -n "$PAXEL_REPO_ROOT" ] && [ -f "$PAXEL_REPO_ROOT/Dockerfile.client" ] && [ "${USE_LIVE_DOCKER:-0}" != "1" ]; then
    if [ "${PAXEL_QUIET_PULL:-0}" = "1" ]; then
      echo "[paxel] Preparing replay container..."
    else
      echo "[3/17] Setting up analysis container..."
      echo "  Cloud: gpt-6-sol (via YC proxy) for summaries and scoring."
      echo "  YC covers all analysis costs — no API keys or subscriptions needed."
      echo "  File bodies stay local; aggregate scores + metadata (paths, commit numstat, session events) upload."
    fi
    echo "  Building from: $PAXEL_REPO_ROOT/Dockerfile.client"
    local build_log
    build_log=$(mktemp)
    if DOCKER_BUILDKIT=1 docker build --build-arg CACHE_BUST="$(date +%s)" -f "$PAXEL_REPO_ROOT/Dockerfile.client" -t paxel-client "$PAXEL_REPO_ROOT" > "$build_log" 2>&1; then
      grep -E '^(#[0-9]+ (DONE|exporting|naming)|Step |Successfully)' "$build_log" || true
      PAXEL_CLIENT_IMAGE="paxel-client"
      echo "  Built: paxel-client (local)"
    else
      if docker_error_file_is_storage_full "$build_log"; then
        print_docker_storage_error "while building the Paxel image"
        rm -f "$build_log"
        exit 1
      fi
      echo "Error: Docker build failed." >&2
      tail -20 "$build_log" >&2
      rm -f "$build_log"
      exit 1
    fi
    rm -f "$build_log"
  else
    pull_from_ghcr
  fi
}


# Pull our PUBLIC image without triggering a Docker credential helper / keychain
# prompt. `docker pull` resolves registry creds from ~/.docker/config.json: a
# `credsStore` ("osxkeychain" on macOS, "secretservice"/"pass" on Linux) makes the
# CLI shell out to that helper to look up creds for ghcr.io — popping a keychain
# prompt (or hanging) for anyone who has logged into ghcr.io before. Our image is
# public and needs no auth, so we pull with a THROWAWAY config that (a) drops the
# credsStore and (b) carries an explicit EMPTY `auths` entry for the image's
# registry. Dropping credsStore ALONE is not enough: OrbStack (and potentially
# other runtimes) fall back to the system keychain when a registry has no creds
# info in the config at all, so the prompt still fires. The empty `auths` entry
# tells docker "anonymous creds already exist for this registry," so it uses them
# and never consults any helper. We also carry over the active Docker context so
# the daemon connection is preserved. The real ~/.docker/config.json is never
# touched; portable across macOS and Linux — pure shell, no external JSON parser.
# Returns non-zero on any failure so the caller falls back.
docker_pull_credfree() {
  local src_cfg tmp ctx registry rc=0
  PAXEL_LAST_DOCKER_PULL_ERROR=""
  PAXEL_LAST_DOCKER_PULL_STORAGE_FULL=0
  src_cfg="${DOCKER_CONFIG:-$HOME/.docker}"
  # Throwaway scratch for the stripped-down config. mktemp -d is the right tool
  # here: it's 0700, created and removed within this one call, and the OS sweeps
  # it if we're killed mid-pull — so unlike the ~/.paxel/cache/*-$$ dirs this
  # needs no cleanup_temp_dirs / 24h-sweeper wiring. It lives only for one pull.
  tmp=$(mktemp -d) || return 1

  # Registry host the image lives on — the JSON `auths` key docker matches the
  # pull against. It's the first /-segment of the ref, but only when that segment
  # is actually a hostname (has a dot or port colon, or is localhost); a bare
  # `name` or `library/name` ref is on Docker Hub with no host prefix, and dev's
  # local `paxel-client` build never reaches this function. Hostnames are
  # [a-zA-Z0-9.:_-] only, so no JSON escaping needed.
  case "$PAXEL_CLIENT_IMAGE" in
    */*) registry="${PAXEL_CLIENT_IMAGE%%/*}"
         case "$registry" in *.*|*:*|localhost) ;; *) registry="" ;; esac ;;
    *)   registry="" ;;
  esac

  # currentContext + the contexts/ metadata dir are all docker needs to resolve
  # a named context (colima/orbstack/desktop-linux/...) and reach the daemon.
  # Context names are restricted to [a-zA-Z0-9_.+-], so no JSON escaping needed.
  ctx=$(docker context show 2>/dev/null || echo default)
  if [ -n "$registry" ]; then
    printf '{"currentContext":"%s","auths":{"%s":{}}}\n' "$ctx" "$registry" > "$tmp/config.json" || { rm -rf "$tmp"; return 1; }
  else
    printf '{"currentContext":"%s"}\n' "$ctx" > "$tmp/config.json" || { rm -rf "$tmp"; return 1; }
  fi
  cp -R "$src_cfg/contexts" "$tmp/" 2>/dev/null || true

  docker --config "$tmp" pull "$PAXEL_CLIENT_IMAGE" >/dev/null 2>"$tmp/pull.err" || rc=$?
  if [ "$rc" -ne 0 ]; then
    if docker_error_file_is_storage_full "$tmp/pull.err"; then
      PAXEL_LAST_DOCKER_PULL_STORAGE_FULL=1
    fi
    PAXEL_LAST_DOCKER_PULL_ERROR=$(docker_pull_error_tail "$tmp/pull.err")
  fi
  rm -rf "$tmp"
  return "$rc"
}


pull_from_ghcr() {
  if [ "${PAXEL_QUIET_PULL:-0}" = "1" ]; then
    echo "[paxel] Preparing replay container..."
  else
    echo "[3/17] Setting up analysis container..."
    echo "  Cloud: gpt-6-sol (via YC proxy) for summaries and scoring."
    echo "  YC covers all analysis costs — no API keys or subscriptions needed."
    echo "  File bodies stay local; aggregate scores + metadata (paths, commit numstat, session events) upload."
    echo "  LLM results are cached locally — reruns skip completed work and pick up where you left off."
    echo ""
  fi
  printf "  Downloading container image..."

  # Prefer a credential-helper-free pull (our image is public, so no auth is
  # needed). If it can't run or fails, fall back to a normal pull with your
  # default Docker config — same daemon and cached layers, so the first attempt
  # isn't wasted. The fallback can surface a credential prompt; it is the safe
  # last resort, not a failure.
  if docker_pull_credfree; then
    printf "\r  Downloaded: %s\n" "$PAXEL_CLIENT_IMAGE"
    return 0
  fi

  if [ "$PAXEL_LAST_DOCKER_PULL_STORAGE_FULL" -eq 1 ] \
    || docker_error_is_storage_full "$PAXEL_LAST_DOCKER_PULL_ERROR"; then
    printf "\n"
    print_docker_storage_error "while downloading the Paxel image"
    exit 1
  fi

  printf "\n"
  echo "  Retrying with your default Docker settings..."
  local fallback_error_file fallback_error="" fallback_rc=0 fallback_storage_full=0
  fallback_error_file=$(mktemp) || fallback_error_file=""
  if [ -n "$fallback_error_file" ]; then
    docker pull "$PAXEL_CLIENT_IMAGE" >/dev/null 2>"$fallback_error_file" || fallback_rc=$?
    if [ "$fallback_rc" -ne 0 ]; then
      if docker_error_file_is_storage_full "$fallback_error_file"; then
        fallback_storage_full=1
      fi
      fallback_error=$(docker_pull_error_tail "$fallback_error_file")
    fi
    rm -f "$fallback_error_file"
  else
    docker pull "$PAXEL_CLIENT_IMAGE" >/dev/null 2>&1 || fallback_rc=$?
  fi
  if [ "$fallback_rc" -eq 0 ]; then
    echo "  Downloaded: $PAXEL_CLIENT_IMAGE"
    return 0
  fi

  local pull_error="${fallback_error:-$PAXEL_LAST_DOCKER_PULL_ERROR}"
  if [ "$PAXEL_LAST_DOCKER_PULL_STORAGE_FULL" -eq 1 ] \
    || [ "$fallback_storage_full" -eq 1 ] \
    || docker_error_is_storage_full "${PAXEL_LAST_DOCKER_PULL_ERROR}"$'\n'"${fallback_error}"; then
    print_docker_storage_error "while downloading the Paxel image"
    exit 1
  fi

  echo "  Using cached image (pull failed)"
  [ -n "$pull_error" ] && echo "  Docker: $(docker_pull_error_line "$pull_error")"
  if ! docker image inspect "$PAXEL_CLIENT_IMAGE" &>/dev/null; then
    echo "Error: Docker could not download the image, and no cached copy is available." >&2
    exit 1
  fi
}

# Prepare filtered transcripts and run Docker analysis for a single repo.
# Used by the multi-repo Strategy 3 path.
# Args: repo_root repo_name repo_remote transcript_dirs_str codex_files_str
prepare_and_run_for_repo() {
  local repo_root="$1"
  local repo_name="$2"
  local repo_remote="$3"
  local transcript_dirs_str="$4"
  local codex_files_str="$5"

  # Save state
  local saved_claude_dir="$CLAUDE_DIR"
  local saved_codex_dir="$CODEX_DIR"
  local saved_repo_root="${REPO_ROOT:-}"
  local saved_estimate="${PAXEL_HOST_ESTIMATE_MINUTES:-}"
  local saved_estimated="${ESTIMATED_MINUTES:-}"
  local saved_selected_remote="${selected_remote:-}"

  # Create filtered transcript dir (PID-scoped to avoid races with concurrent runs)
  local filtered_dir="${HOME}/.paxel/cache/filtered-transcripts-$$"
  rm -rf "$filtered_dir"
  mkdir -p "$filtered_dir"

  # Copy matching transcript dirs
  local match_count=0
  local copy_failed=0
  if [ -n "$transcript_dirs_str" ]; then
    IFS='|' read -ra tdirs <<< "$transcript_dirs_str"
    for dir_name in "${tdirs[@]}"; do
      [ -z "$dir_name" ] && continue
      if [ -d "$saved_claude_dir/$dir_name" ]; then
        # _paxel_cp_transcripts: CoW clone where possible, preserving mtime (-p) so
        # the container's --since filter (File.mtime in analyze_local.rake) reflects
        # each session's real age, not the copy's. Guarded: this function runs
        # errexit-suppressed (called as `if prepare_and_run_for_repo`), so a bare cp
        # failure would be swallowed and the repo analyzed on partial data — track
        # it and fail loud below.
        if _paxel_cp_transcripts "$saved_claude_dir/$dir_name" "$filtered_dir/$dir_name"; then
          match_count=$((match_count + 1))
        else
          echo "  Failed to copy Claude transcripts for ${repo_name} (${dir_name})." >&2
          copy_failed=1
        fi
      fi
    done
  fi

  # Create filtered Codex dir (per-repo Codex filtering, Codex fix #2).
  # PID-suffixed so cleanup_temp_dirs EXIT trap + 24h stale sweeper cover it
  # (3-site rule per reference_extract_dir_three_site_cleanup.md).
  local filtered_codex_dir="${HOME}/.paxel/cache/filtered-codex-$$"
  rm -rf "$filtered_codex_dir"
  mkdir -p "$filtered_codex_dir"
  local codex_count=0
  local codex_cross_tool_count=0
  if [ -n "$codex_files_str" ]; then
    IFS='|' read -ra cfiles <<< "$codex_files_str"
    for codex_file in "${cfiles[@]}"; do
      [ -z "$codex_file" ] && continue
      [ -f "$codex_file" ] || continue
      local codex_basename
      codex_basename=$(basename "$codex_file")
      # -p preserves mtime so collect_codex_sessions's --since filter
      # (compares file mtime vs SINCE_EPOCH) reflects the session's actual
      # age, not the copy's recency. Without -p, every file ends up with
      # "now" as its mtime and --since is effectively a no-op.
      if cp -p "$codex_file" "$filtered_codex_dir/$codex_basename"; then
        codex_count=$((codex_count + 1))
        # Phase 3.5 — track cross-tool subset for honest session-count display
        # below (matches picker bucketing: only Claude-launched Codex counts
        # as subagent; standalone Codex counts as a main session).
        local _origin
        _origin=$(get_codex_session_originator "$codex_file")
        codex_originator_is_standalone "$_origin" || codex_cross_tool_count=$((codex_cross_tool_count + 1))
      else
        echo "  Failed to copy Codex session for ${repo_name}." >&2
        copy_failed=1
      fi
    done
  fi

  # Fail loud on a copy failure instead of silently analyzing incomplete data.
  # Nothing global is mutated yet (CLAUDE_DIR et al. are reassigned just below), so
  # a bare return is clean; the EXIT trap reaps the PID-scoped filtered dirs. The
  # caller (run_selected_child_repos) records the non-zero return as a failed repo.
  if [ "$copy_failed" -eq 1 ]; then
    echo "  ✗ ${repo_name}: session copy failed — skipping to avoid an incomplete report." >&2
    return 1
  fi

  CLAUDE_DIR="$filtered_dir"
  CLAUDE_MOUNT_SCOPE="filtered"
  CODEX_MOUNT_SCOPE="filtered"
  MOUNT_LABEL="$repo_name"
  if [ "$codex_count" -gt 0 ]; then
    CODEX_DIR="$filtered_codex_dir"
  else
    CODEX_DIR="${HOME}/.paxel/empty-codex"
    mkdir -p "$CODEX_DIR"
  fi

  # Count sessions. Phase 3.5 — Claude-launched Codex (cross-tool) counts
  # toward subagent_total (the "M" in "N sessions + M subagent"), not the
  # main session_count. session_count drives the time estimate + user-visible
  # "${session_count} sessions" line; subagent_total appears separately so
  # users see honest "N sessions + M subagent" math matching the picker.
  local claude_count
  claude_count=$({ find "$filtered_dir" -name "*.jsonl" -not -name "_*" -not -path "*/_git/*" -not -path "*/subagents/*" -maxdepth 3 2>/dev/null || true; } | wc -l | tr -d ' ')
  local codex_main_count=$((codex_count - codex_cross_tool_count))
  local session_count=$((claude_count + codex_main_count))
  # If no Claude/Codex sessions, fold in opencode/Gemini (same helpers + condition as
  # the picker) so an opencode/Gemini-only repo isn't dropped by the zero-session
  # early-return below; run_docker_analysis extracts them (scoped to repo_remote)
  # regardless. Helpers honor their own filters and return 0 for a local:/non-match.
  if [ "$session_count" -eq 0 ]; then
    local _oc_main _gm_main _vs_main _ag_main
    _oc_main=$(count_opencode_sessions "$repo_remote")
    _gm_main=$(count_gemini_sessions "$repo_remote")
    _vs_main=$(count_vscode_copilot_sessions "$repo_remote")
    _ag_main=$(count_antigravity_sessions "$repo_remote")
    session_count=$((_oc_main + _gm_main + _vs_main + _ag_main))
  fi
  # Project-scoped: scan filtered_dir (matched-to-this-repo only) NOT $CLAUDE_DIR
  # global; otherwise the per-repo display includes cross-project subagents.
  local subagent_count
  subagent_count=$(count_subagent_sessions "$filtered_dir")
  local subagent_total=$((subagent_count + codex_cross_tool_count))

  # Cursor presence floor (C3): a Cursor-only repo (with a remote) has no cheap
  # host count, so don't drop it — run_docker_analysis extracts Cursor scoped to
  # repo_remote (same as the auto-detect remote_has_agent_sessions branch and the
  # picker). The prescan is memoized, so this is a cheap global lookup when the
  # picker already ran it.
  local _repo_cursor_only=0
  if [ "$session_count" -eq 0 ] && [ "$subagent_total" -eq 0 ] \
    && [ -n "$repo_remote" ] && remote_has_cursor_sessions "$repo_remote"; then
    _repo_cursor_only=1
  fi

  if [ "$session_count" -eq 0 ] && [ "$subagent_total" -eq 0 ] && [ "$_repo_cursor_only" -eq 0 ]; then
    echo "  No sessions found for ${repo_name}, skipping."
    # Restore state
    CLAUDE_DIR="$saved_claude_dir"
    CODEX_DIR="$saved_codex_dir"
    REPO_ROOT="$saved_repo_root"
    PAXEL_HOST_ESTIMATE_MINUTES="$saved_estimate"
    ESTIMATED_MINUTES="$saved_estimated"
    return 0
  fi

  # Bound author-commit collection to this repo's session window. run_docker_mode
  # computes OLDEST_SESSION_EPOCH only on the single-repo path, so the picker path
  # left it empty and collect_author_commits ran UNBOUNDED over the uploader's full
  # history (payload bloat + spurious commit-group clusters). Compute a
  # function-local floor from the copied sessions' mtimes — the CoW transcript copy
  # (-p) and cp -p preserve them — like run_docker_mode's source-mtime scan (this one also covers Codex
  # sessions, which the single-repo scan does not). Trailing `|| true` swallows
  # head's SIGPIPE under set -o pipefail (same as run_docker_mode's computation).
  local oldest_epoch=""
  oldest_epoch=$(find "$filtered_dir" "$filtered_codex_dir" -name "*.jsonl" -not -name "_*" -maxdepth 3 2>/dev/null \
    | while read -r _f; do stat -c '%Y' "$_f" 2>/dev/null || stat -f '%m' "$_f" 2>/dev/null; done \
    | sort -n | head -1 || true)
  # When --since is active the host hasn't filtered the copied sessions yet (the
  # container applies SINCE_EPOCH via File.mtime), so the raw min-mtime floor can
  # predate the requested window. Clamp UP to SINCE_EPOCH so the author-commit
  # window matches the analyzed-session window, not the absolute-oldest session.
  if [ -n "$SINCE_EPOCH" ]; then
    if [ -z "$oldest_epoch" ] || [ "$oldest_epoch" -lt "$SINCE_EPOCH" ]; then
      oldest_epoch="$SINCE_EPOCH"
    fi
  fi

  # Collect git metadata
  local git_data_dir="${filtered_dir}/_git"
  mkdir -p "$git_data_dir"
  local docker_metadata="{}"

  for dir in "$filtered_dir"/*/; do
    [ -d "$dir" ] || continue
    local dir_name
    dir_name=$(basename "$dir")
    [ "$dir_name" = "_git" ] && continue
    local dir_cwd
    dir_cwd=$(get_project_cwd "$dir_name")
    local dir_remote
    dir_remote=$(get_git_remote "$dir_cwd")
    if [ -z "$dir_remote" ] && [ -n "$dir_cwd" ] && [ ! -e "$dir_cwd" ]; then
      dir_remote=$(resolve_remote_for_dead_cwd "$dir_cwd")
    fi

    if [ -n "$dir_remote" ] || [ -n "$dir_cwd" ]; then
      docker_metadata=$(echo "$docker_metadata" | jq \
        --arg dir "$dir_name" \
        --arg remote "$dir_remote" \
        --arg cwd "$dir_cwd" \
        '. + {($dir): {"git_remote": $remote, "cwd": $cwd}}' 2>/dev/null || echo "$docker_metadata")
    fi

  done

  local repository_key
  repository_key=$(repository_git_key "$repo_remote" "$repo_root")
  collect_repository_git_data "$repo_root" "$git_data_dir" "$repository_key" "$filtered_dir" "$oldest_epoch"

  # Write _metadata.json
  local _rmdc_total
  _rmdc_total=$(_rmdc_recovery_count_unique)
  if command -v jq &>/dev/null; then
    jq -n --argjson dirs "$docker_metadata" \
      --argjson recoveries "${_rmdc_total:-0}" \
      '{"version": 1, "directories": $dirs, "orphan_recovery_count": $recoveries}' \
      > "${filtered_dir}/_metadata.json" \
      || echo "  Warning: could not write attribution metadata for ${repo_name}; the container will fall back to name-based attribution." >&2
  fi

  # Set repo root for code quality
  if [ -d "$repo_root" ]; then
    export REPO_ROOT="$repo_root"
  else
    unset REPO_ROOT 2>/dev/null || true
  fi

  # Set selected_remote so Cursor extraction filters by this repo's remote.
  selected_remote="$repo_remote"
  # A remote-less child carries a "local:/abs/path" grouping key (detect_child_repos),
  # NOT a real git remote. The non-Claude collectors filter by normalize_remote,
  # and "local:…" normalizes to itself and matches no session — so leaving it set
  # makes Codex/Cursor/opencode/Gemini silently drop every session AND run wasted
  # work. Blank it so run_docker_analysis's "skipped (no resolved remote)" guards
  # fire instead — honest, and matching the single-repo path (which sets an empty
  # selected_remote for a no-origin repo). Full path-based scoping for remote-less
  # repos is a follow-up.
  case "$selected_remote" in
    local:*|"") selected_remote="" ;;
  esac

  # Estimate and pass to Docker. Match print_estimate's `sessions + subagent_count`
  # math (line 352): AnalyzeSessionJob runs every logical-root + subagent + cross-tool
  # session, so the wall-clock estimate must include the same set the user sees in
  # "${session_count} sessions + ${subagent_total} subagent" below.
  local mins
  mins=$(estimate_time $((session_count + subagent_total)))
  ESTIMATED_MINUTES="$mins"
  export PAXEL_HOST_ESTIMATE_MINUTES="$mins"
  if [ "$subagent_total" -gt 0 ]; then
    echo "  ${session_count} sessions + ${subagent_total} subagent, ~${mins} min"
  elif [ "$_repo_cursor_only" -eq 1 ] && [ "$session_count" -eq 0 ]; then
    echo "  Cursor sessions (counted inside the container), ~${mins} min"
  else
    echo "  ${session_count} sessions, ~${mins} min"
  fi

  # Run Docker
  run_docker_analysis
  local result=$?

  # Restore state
  CLAUDE_DIR="$saved_claude_dir"
  CODEX_DIR="$saved_codex_dir"
  if [ -n "$saved_repo_root" ]; then
    REPO_ROOT="$saved_repo_root"
  else
    unset REPO_ROOT 2>/dev/null || true
  fi
  PAXEL_HOST_ESTIMATE_MINUTES="$saved_estimate"
  ESTIMATED_MINUTES="$saved_estimated"
  selected_remote="$saved_selected_remote"

  return $result
}

# Does any non-Claude tool (Codex, Cursor, opencode, Gemini, VS Code Copilot) have a session for $remote?
# Lets single-project auto-detect scope a repo the user worked in WITHOUT Claude
# Code, instead of falling through to the "none of your sessions match" prompt.
# Reuses the real collectors against a throwaway probe dir (so per-remote
# matching has ONE source of truth), and only runs on the uncommon path where
# Claude produced no match. Recovery logging is redirected to a throwaway so the
# probe can't inflate orphan_recovery_count for the real run.
# Cursor presence floor (C3). Cursor has no cheap per-repo count — its workspace
# lives in a JSON `value` blob that is often absent, so a correct count needs a
# per-session filesystem walk (the documented extract hang). Instead we extract
# ALL Cursor sessions ONCE into a throwaway probe, harvest each session's recovered
# git_remote, normalize, and cache the set in a global. detect_child_repos /
# prepare_and_run_for_repo then do a cheap set-membership check so a Cursor-only
# repo (with a remote) is no longer dropped by the zero-session guards, without
# re-extracting per repo. Memoized: runs at most once per upload, and only when a
# repo actually came up empty on the cheaply-counted tools (Claude/Codex/opencode/
# Gemini). No-remote Cursor repos stay dropped (a separate, deferred follow-up).
_PAXEL_CURSOR_REMOTES=""
_PAXEL_CURSOR_PRESCAN_DONE=0
maybe_prescan_cursor_remotes() {
  [ "$_PAXEL_CURSOR_PRESCAN_DONE" -eq 1 ] && return 0
  _PAXEL_CURSOR_PRESCAN_DONE=1
  # jq gates BOTH Cursor sources; sqlite3 gates only the legacy DBs and is
  # handled inside collect_cursor_sessions — a jq-only host (Windows Git
  # Bash) still reads the ~/.cursor/projects transcripts, so the presence
  # floor must see those repos too.
  command -v jq >/dev/null 2>&1 || return 0
  [ -d "${CURSOR_DIR:-}" ] || [ -f "${CURSOR_GLOBAL_DB:-}" ] || [ -d "${CURSOR_PROJECTS_DIR:-}" ] || return 0
  echo "  Scanning Cursor sessions..." >&2
  local probe
  probe=$(mktemp -d 2>/dev/null) || return 0
  local _saved_rmdc="${_RMDC_LOG_FILE:-}"
  _RMDC_LOG_FILE="$probe/.rmdc"
  collect_cursor_sessions "$probe" "" >/dev/null 2>&1 || true
  _RMDC_LOG_FILE="$_saved_rmdc"
  local set="|" f r rn
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    r=$(head -1 "$f" | jq -r '._cursor_meta.git_remote // empty' 2>/dev/null || true)
    [ -z "$r" ] && continue
    rn=$(normalize_remote "$r")
    [ -z "$rn" ] && continue
    case "$set" in *"|${rn}|"*) ;; *) set="${set}${rn}|" ;; esac
  done < <(find "$probe" -path '*/_cursor_*/*.jsonl' 2>/dev/null)
  rm -rf "$probe"
  _PAXEL_CURSOR_REMOTES="$set"
}

# True if `remote` has any Cursor session (per the one-time prescan above). Must be
# called as a condition, NOT in $(...): it triggers the prescan, which sets a global
# that a subshell would discard.
remote_has_cursor_sessions() {
  local remote="$1"
  [ -z "$remote" ] && return 1
  maybe_prescan_cursor_remotes
  local rn
  rn=$(normalize_remote "$remote")
  [ -z "$rn" ] && return 1
  case "$_PAXEL_CURSOR_REMOTES" in *"|${rn}|"*) return 0 ;; *) return 1 ;; esac
}

remote_has_agent_sessions() {
  local remote="$1"
  [ -z "$remote" ] && return 1
  local probe
  probe=$(mktemp -d 2>/dev/null) || return 1

  local _saved_rmdc="${_RMDC_LOG_FILE:-}"
  _RMDC_LOG_FILE="$probe/.rmdc"

  local rc=1
  # Gemini probe FIRST — its extraction needs no jq (sed/cp), so a repo with only
  # Gemini sessions can still be scoped on a host without jq.
  collect_gemini_sessions "$probe" "$remote" >/dev/null 2>&1 || true
  [ -n "$(find "$probe" -path '*/_gemini_*/*.jsonl' -print -quit 2>/dev/null)" ] && rc=0

  # Codex/Cursor/opencode/VS Code Copilot probes require jq; only run them if we
  # haven't matched.
  if [ "$rc" -ne 0 ] && command -v jq >/dev/null 2>&1; then
    collect_codex_sessions "$probe" "$remote" >/dev/null 2>&1 || true
    collect_cursor_sessions "$probe" "$remote" >/dev/null 2>&1 || true
    collect_opencode_sessions "$probe" "$remote" >/dev/null 2>&1 || true
    collect_vscode_copilot_sessions "$probe" "$remote" >/dev/null 2>&1 || true
    if [ -n "$(find "$probe" -path '*/_codex_*/*.jsonl' -print -quit 2>/dev/null)" ] \
      || [ -n "$(find "$probe" -path '*/_cursor_*/*.jsonl' -print -quit 2>/dev/null)" ] \
      || [ -n "$(find "$probe" -path '*/_opencode_*/*.jsonl' -print -quit 2>/dev/null)" ] \
      || [ -n "$(find "$probe" -path '*/_vscode_*/*.jsonl' -print -quit 2>/dev/null)" ]; then
      rc=0
    fi
  fi

  # Antigravity probe — no tool gate: attribution prefers sqlite3 but falls back
  # to the transcript-parsed workspace, so the probe works either way.
  if [ "$rc" -ne 0 ]; then
    collect_antigravity_sessions "$probe" "$remote" >/dev/null 2>&1 || true
    [ -n "$(find "$probe" -path '*/_antigravity_*/*.jsonl' -print -quit 2>/dev/null)" ] && rc=0
  fi

  _RMDC_LOG_FILE="$_saved_rmdc"
  rm -rf "$probe"
  return $rc
}

run_docker_analysis() {
  if [ "$MULTI_REPO_RUNNING" -eq 0 ]; then
    echo "Analyzing your coding sessions — this is the slow part (steps 4-17 below):"
  fi

  # When PAXEL_SERVER points to localhost, the container can't reach the host's
  # localhost directly. Rewrite to host.docker.internal (works on macOS/Windows
  # Docker Desktop and Linux with --add-host).
  local docker_server="$PAXEL_SERVER"
  local host_os
  host_os=$(uname -s)
  local host_uid
  host_uid=$(id -u)
  local host_gid
  host_gid=$(id -g)
  local run_as_host_user=0
  [ "$host_os" = "Linux" ] && run_as_host_user=1
  # Mount logs directory for persistent output on the host
  local log_dir="${HOME}/.paxel/logs"
  # Mirror the label analyze_local.rake uses for the log filename — PAXEL_LOG_LABEL
  # (i.e. MOUNT_LABEL when set), else PROJECT_NAME, else "all" — with the SAME
  # sanitize, so the "Log: …" messages below point at the file actually written.
  # Without this the glob mismatches for --project runs (MOUNT_LABEL unset → file is
  # <project>-*.log, not all-*.log) and for labels with spaces/special chars.
  local _log_label
  _log_label=$(printf '%s' "${MOUNT_LABEL:-${PROJECT_NAME:-all}}" | tr -c 'A-Za-z0-9._-' '_')
  mkdir -p "$log_dir"

  # Pending-upload stash dir (resumable uploads). Stays a host bind mount so the
  # stash payload keeps its disclosed 0600-in-0700 posture in the user's home.
  local data_dir="${HOME}/.paxel/data"
  mkdir -p "$data_dir"
  # Honor the disclosed 0700 on ~/.paxel/data (and the logs dir) even if a
  # pre-change run created them 0755. The 0700 data dir is what shields the
  # pending-upload stash from other host users.
  chmod 700 "$log_dir" "$data_dir" 2>/dev/null || true

  # Persistent LLM result cache lives in a dedicated Docker named volume, not a
  # host bind mount. It is per-host-user by default; override with
  # PAXEL_CACHE_VOLUME.
  local cache_volume
  cache_volume="${PAXEL_CACHE_VOLUME:-paxel-cache-$(id -u)}"

  # --clean flag: drop cached LLM results to force fresh analysis. The cache has
  # its own volume (nothing else lives there), so removing the whole volume is
  # safe; guarded so a "volume in use" / missing-volume case can't trip the
  # global ERR trap. The next run creates and prepares a fresh volume.
  # Also clears any orphaned legacy cache file from the old ~/.paxel/data path.
  if [ "${CLEAN:-0}" = "1" ]; then
    docker volume rm "$cache_volume" >/dev/null 2>&1 || true
    rm -f "${data_dir}/llm_cache.sqlite3" "${data_dir}/llm_cache.sqlite3-wal" "${data_dir}/llm_cache.sqlite3-shm" 2>/dev/null || true
    echo "  Cleaned cached analysis data"
  fi

  local docker_args=(--rm -v "${log_dir}:/logs" -v "${data_dir}:/rails/data" -v "${cache_volume}:/rails/cache")
  if [ "$run_as_host_user" -eq 1 ]; then
    if ! MSYS_NO_PATHCONV=1 docker run --rm --user 0:0 --entrypoint /bin/sh \
      -v "${cache_volume}:/rails/cache" "$PAXEL_CLIENT_IMAGE" \
      -c ': > /rails/cache/.paxel-volume-owner && chown -R "$1:$2" /rails/cache' \
      paxel-cache-owner "$host_uid" "$host_gid"; then
      echo "Paxel could not prepare its cache for uid ${host_uid}." >&2
      return 1
    fi
    docker_args+=(
      --user "${host_uid}:${host_gid}"
      --tmpfs "/rails/tmp:rw,uid=${host_uid},gid=${host_gid},mode=0700"
      -e "HOME=/rails/tmp/home"
    )
  fi
  local cc_count=0

  # Mount Claude Code transcripts
  if [ -d "$CLAUDE_DIR" ]; then
    docker_args+=(-v "${CLAUDE_DIR}:/transcripts:ro")
    cc_count=$(count_sessions "$CLAUDE_DIR")
    if [ "${CLAUDE_MOUNT_SCOPE:-all}" = "filtered" ]; then
      echo "  Claude Code: ${cc_count} sessions (matched to ${MOUNT_LABEL})"
    else
      echo "  Claude Code: ${cc_count} sessions"
    fi
  else
    # Create empty mount point so container doesn't fail
    docker_args+=(-v "${HOME}/.paxel/empty:/transcripts:ro")
    mkdir -p "${HOME}/.paxel/empty"
  fi

  # Extract Codex sessions on host, mount extracted dir at /codex_sessions:ro.
  # Mirrors the Cursor pattern below: host walks $CODEX_DIR, buckets per-session
  # remote into _codex_<slug>_<hash>/ (or _codex_unattributed/ for sessions
  # without a repository_url), writes a _metadata.json sidecar, and mounts the
  # result. The container's analyze_local.rake merges /codex_sessions into
  # transcript_dir so TranscriptDiscoverer creates a Codex Project per remote.
  #
  # Historical note: PR #604 removed a prior $CODEX_DIR bind-mount because
  # analyze_local.rake had no merge logic — Codex sessions were silently dropped
  # in Docker mode from 2026-02 to 2026-04. Restored here with the missing
  # container-side consumer (see analyze_local.rake:~134).
  if [ -d "$CODEX_DIR" ]; then
    # Scope guard: in filtered (single-project) Docker mode, refuse to
    # extract Codex if we couldn't resolve the project's git_remote.
    # collect_codex_sessions treats an empty selected_remote as --all,
    # so without this guard an auto-detected single-project upload for a
    # repo with no origin would pull in every Codex session across every
    # repo on the machine, widening scope far beyond what the user asked
    # for. In --all mode (CLAUDE_MOUNT_SCOPE=all or unset), empty
    # selected_remote is correct — we want every session.
    if [ "${CLAUDE_MOUNT_SCOPE:-all}" = "filtered" ] && [ -z "${selected_remote:-}" ] && [ -z "${scope_cwd:-}" ]; then
      echo "  Codex CLI: skipped (single-project scope but no resolved remote)"
    else
      local codex_extract_dir="${HOME}/.paxel/cache/codex_extracted-$$"
      rm -rf "$codex_extract_dir"
      mkdir -p "$codex_extract_dir"
      local codex_log="${HOME}/.paxel/logs/codex-extract.log"
      mkdir -p "$(dirname "$codex_log")"
      # scope_cwd (C6): when the run dir resolved no remote (home/parent-dir
      # auto-detect), collect Codex sessions under that dir instead of skipping.
      if ! collect_codex_sessions "$codex_extract_dir" "${selected_remote:-}" "${scope_cwd:-}" 2>"$codex_log"; then
        echo "  Warning: Codex session extraction had errors. Continuing with other sessions."
        [ -s "$codex_log" ] && echo "  Details: $codex_log"
      fi
      local codex_jsonl_count
      codex_jsonl_count=$(find "$codex_extract_dir" -maxdepth 2 -path "*/_codex_*/*.jsonl" 2>/dev/null | wc -l | tr -d ' ')
      if [ "$codex_jsonl_count" -gt 0 ]; then
        docker_args+=(-v "${codex_extract_dir}:/codex_sessions:ro")
        # Phase 3.5 — split by originator so the prelude matches the picker
        # bucketing the user just saw. Standalone (user-launched Codex) =
        # "Codex CLI"; Claude-launched = "Codex launched by Claude".
        local codex_standalone_count=0
        local codex_cross_tool_count=0
        local _cef
        while IFS= read -r _cef; do
          [ -z "$_cef" ] && continue
          local _ceo
          _ceo=$(get_codex_session_originator "$_cef")
          if codex_originator_is_standalone "$_ceo"; then
            codex_standalone_count=$((codex_standalone_count + 1))
          else
            codex_cross_tool_count=$((codex_cross_tool_count + 1))
          fi
        done < <(find "$codex_extract_dir" -maxdepth 2 -path "*/_codex_*/*.jsonl" 2>/dev/null)

        local match_suffix=""
        [ "${CLAUDE_MOUNT_SCOPE:-all}" = "filtered" ] && match_suffix=" (matched to ${MOUNT_LABEL})"
        if [ "$codex_standalone_count" -gt 0 ]; then
          echo "  Codex CLI: ${codex_standalone_count} sessions${match_suffix}"
        fi
        if [ "$codex_cross_tool_count" -gt 0 ]; then
          echo "  Codex launched by Claude: ${codex_cross_tool_count} sessions${match_suffix}"
        fi
      fi
    fi
  fi

  # Loud hint when Cursor data exists but the host lacks the tools to read it —
  # the next `if` requires jq and otherwise skips Cursor with NO output (common
  # on Windows Git Bash, which bundles neither jq nor sqlite3; the container has
  # no sqlite3 CLI either). jq gates both Cursor sources; sqlite3 gates only the
  # legacy state.vscdb path (~/.cursor/projects transcripts are plain JSONL).
  if { [ -d "$CURSOR_DIR" ] || [ -f "$CURSOR_GLOBAL_DB" ] || [ -d "${CURSOR_PROJECTS_DIR:-}" ]; } \
     && ! command -v jq >/dev/null 2>&1; then
    echo "  Cursor IDE: found data but can't read it — install jq (and sqlite3 for older Cursor versions) and re-run" >&2
    echo "    (brew install sqlite3 jq · sudo apt install sqlite3 jq · winget install sqlite.sqlite jqlang.jq)" >&2
  elif { [ -d "$CURSOR_DIR" ] || [ -f "$CURSOR_GLOBAL_DB" ]; } \
     && ! command -v sqlite3 >/dev/null 2>&1; then
    if [ -d "${CURSOR_PROJECTS_DIR:-}" ]; then
      echo "  Cursor IDE: sqlite3 not found — reading only ~/.cursor/projects transcripts. Install sqlite3 for the full history" >&2
    else
      echo "  Cursor IDE: found data but can't read it — install sqlite3 and re-run" >&2
    fi
    echo "    (brew install sqlite3 · sudo apt install sqlite3 · winget install sqlite.sqlite)" >&2
  fi

  # Extract Cursor IDE sessions on host (SQLite + agent-transcripts JSONL →
  # canonical JSONL), mount extracted dir
  if { [ -d "$CURSOR_DIR" ] || [ -f "$CURSOR_GLOBAL_DB" ] || [ -d "${CURSOR_PROJECTS_DIR:-}" ]; } && command -v jq &>/dev/null; then
    # collect_cursor_sessions treats an empty selected_remote as --all, so without
    # this guard an auto-detected single-project upload for a repo with no resolved
    # remote would pull in every Cursor session on the machine. In --all mode
    # (CLAUDE_MOUNT_SCOPE=all/unset) empty is correct. Mirrors the Codex/opencode/
    # Gemini blocks (Cursor was the only collector missing this guard).
    if [ "${CLAUDE_MOUNT_SCOPE:-all}" = "filtered" ] && [ -z "${selected_remote:-}" ]; then
      echo "  Cursor IDE: skipped (single-project scope but no resolved remote)"
    else
      local cursor_extract_dir="${HOME}/.paxel/cache/cursor_extracted-$$"
      rm -rf "$cursor_extract_dir"
      mkdir -p "$cursor_extract_dir"
      echo "  Extracting Cursor IDE sessions..."
      local cursor_log="${HOME}/.paxel/logs/cursor-extract.log"
      mkdir -p "$(dirname "$cursor_log")"
      if ! collect_cursor_sessions "$cursor_extract_dir" "${selected_remote:-}" 2>"$cursor_log"; then
        echo "  Warning: Cursor session extraction had errors. Continuing with other sessions."
        [ -s "$cursor_log" ] && echo "  Details: $cursor_log"
      fi
      local cursor_jsonl_count
      cursor_jsonl_count=$(find "$cursor_extract_dir" -maxdepth 2 -path "*/_cursor_*/*.jsonl" 2>/dev/null | wc -l | tr -d ' ')
      if [ "$cursor_jsonl_count" -gt 0 ]; then
        docker_args+=(-v "${cursor_extract_dir}:/cursor_sessions:ro")
        if [ "${CLAUDE_MOUNT_SCOPE:-all}" = "filtered" ]; then
          echo "  Cursor IDE: ${cursor_jsonl_count} sessions (matched to ${MOUNT_LABEL})"
        else
          echo "  Cursor IDE: ${cursor_jsonl_count} sessions"
        fi
      fi
      # $filtered_dir is dynamic-scoped from prepare_and_run_for_repo / run_docker_mode
      # (the two functions that wrote the archive sidecar with orphan_recovery_count).
      # Cursor extraction above may have triggered resolver calls; update the counter
      # before the container reads the sidecar.
      _refresh_orphan_recovery_count "${filtered_dir:-}/_metadata.json"
    fi
  fi

  # Extract opencode sessions on host (SQLite → opencode-native JSONL), mount
  # extracted dir at /opencode_sessions. Mirrors the Cursor block above; the
  # container's analyze_local merge folds _opencode_* buckets into transcript_dir.
  if { [ -d "$OPENCODE_DIR" ] || { [ -n "${OPENCODE_DB:-}" ] && [ -f "${OPENCODE_DB:-}" ]; }; } && command -v sqlite3 &>/dev/null && command -v jq &>/dev/null; then
    # collect_opencode_sessions treats an empty selected_remote as --all, so
    # without this guard an auto-detected single-project upload for a repo with
    # no resolved remote would pull in every opencode session on the machine.
    # In --all mode (CLAUDE_MOUNT_SCOPE=all/unset) empty is correct. Mirrors the
    # Codex block above.
    if [ "${CLAUDE_MOUNT_SCOPE:-all}" = "filtered" ] && [ -z "${selected_remote:-}" ]; then
      echo "  opencode: skipped (single-project scope but no resolved remote)"
    else
      local opencode_extract_dir="${HOME}/.paxel/cache/opencode_extracted-$$"
      rm -rf "$opencode_extract_dir"
      mkdir -p "$opencode_extract_dir"
      echo "  Extracting opencode sessions..."
      local opencode_log="${HOME}/.paxel/logs/opencode-extract.log"
      mkdir -p "$(dirname "$opencode_log")"
      if ! collect_opencode_sessions "$opencode_extract_dir" "${selected_remote:-}" 2>"$opencode_log"; then
        echo "  Warning: opencode session extraction had errors. Continuing with other sessions."
        [ -s "$opencode_log" ] && echo "  Details: $opencode_log"
      fi
      local opencode_jsonl_count
      opencode_jsonl_count=$(find "$opencode_extract_dir" -maxdepth 2 -path "*/_opencode_*/*.jsonl" 2>/dev/null | wc -l | tr -d ' ')
      if [ "$opencode_jsonl_count" -gt 0 ]; then
        docker_args+=(-v "${opencode_extract_dir}:/opencode_sessions:ro")
        if [ "${CLAUDE_MOUNT_SCOPE:-all}" = "filtered" ]; then
          echo "  opencode: ${opencode_jsonl_count} sessions (matched to ${MOUNT_LABEL})"
        else
          echo "  opencode: ${opencode_jsonl_count} sessions"
        fi
      fi
      _refresh_orphan_recovery_count "${filtered_dir:-}/_metadata.json"
    fi
  fi

  # Extract Gemini CLI sessions on host (raw JSONL copy + subagent relayout), mount
  # at /gemini_sessions. Unlike the SQLite tools above, gemini sessions are plain
  # JSONL — extraction needs neither sqlite3 nor jq (jq only enriches the sidecar),
  # so the gate is just the dir existing.
  if [ -d "$GEMINI_DIR" ]; then
    # collect_gemini_sessions treats an empty selected_remote as --all; guard the
    # single-project-no-remote case so we don't pull every gemini session (mirrors
    # the Codex/opencode blocks).
    if [ "${CLAUDE_MOUNT_SCOPE:-all}" = "filtered" ] && [ -z "${selected_remote:-}" ]; then
      echo "  Gemini CLI: skipped (single-project scope but no resolved remote)"
    else
      local gemini_extract_dir="${HOME}/.paxel/cache/gemini_extracted-$$"
      rm -rf "$gemini_extract_dir"
      mkdir -p "$gemini_extract_dir"
      echo "  Extracting Gemini CLI sessions..."
      local gemini_log="${HOME}/.paxel/logs/gemini-extract.log"
      mkdir -p "$(dirname "$gemini_log")"
      if ! collect_gemini_sessions "$gemini_extract_dir" "${selected_remote:-}" 2>"$gemini_log"; then
        echo "  Warning: Gemini session extraction had errors. Continuing with other sessions."
        [ -s "$gemini_log" ] && echo "  Details: $gemini_log"
      fi
      local gemini_jsonl_count
      gemini_jsonl_count=$(find "$gemini_extract_dir" -maxdepth 2 -path "*/_gemini_*/*.jsonl" 2>/dev/null | wc -l | tr -d ' ')
      if [ "$gemini_jsonl_count" -gt 0 ]; then
        docker_args+=(-v "${gemini_extract_dir}:/gemini_sessions:ro")
        if [ "${CLAUDE_MOUNT_SCOPE:-all}" = "filtered" ]; then
          echo "  Gemini CLI: ${gemini_jsonl_count} sessions (matched to ${MOUNT_LABEL})"
        else
          echo "  Gemini CLI: ${gemini_jsonl_count} sessions"
        fi
      fi
      _refresh_orphan_recovery_count "${filtered_dir:-}/_metadata.json"
    fi
  fi

  # Extract VS Code Copilot sessions on host (big-JSON -> slimmed JSONL via jq),
  # mount at /vscode_sessions. jq is REQUIRED (like Cursor); the per-session raw
  # JSON can reach ~100 MB, so slimming on the host bounds archive + parse memory.
  # VSCODE_DIR is a newline list of workspaceStorage base dirs; gate on jq + at
  # least one base dir existing.
  local _vscode_any_base=0
  if command -v jq &>/dev/null; then
    local _vb
    while IFS= read -r _vb; do
      [ -z "$_vb" ] && continue
      if [ -d "$_vb" ]; then _vscode_any_base=1; break; fi
    done <<< "$VSCODE_DIR"
  fi
  if [ "$_vscode_any_base" -eq 1 ]; then
    # collect_vscode_copilot_sessions treats an empty selected_remote as --all;
    # guard the single-project-no-remote case so we don't pull every Copilot
    # session (mirrors the Codex/opencode/Gemini blocks).
    if [ "${CLAUDE_MOUNT_SCOPE:-all}" = "filtered" ] && [ -z "${selected_remote:-}" ]; then
      echo "  VS Code Copilot: skipped (single-project scope but no resolved remote)"
    else
      local vscode_extract_dir="${HOME}/.paxel/cache/vscode_extracted-$$"
      rm -rf "$vscode_extract_dir"
      mkdir -p "$vscode_extract_dir"
      echo "  Extracting VS Code Copilot sessions..."
      local vscode_log="${HOME}/.paxel/logs/vscode-extract.log"
      mkdir -p "$(dirname "$vscode_log")"
      if ! collect_vscode_copilot_sessions "$vscode_extract_dir" "${selected_remote:-}" 2>"$vscode_log"; then
        echo "  Warning: VS Code Copilot session extraction had errors. Continuing with other sessions."
        [ -s "$vscode_log" ] && echo "  Details: $vscode_log"
      fi
      local vscode_jsonl_count
      vscode_jsonl_count=$(find "$vscode_extract_dir" -maxdepth 2 -path "*/_vscode_*/*.jsonl" 2>/dev/null | wc -l | tr -d ' ')
      if [ "$vscode_jsonl_count" -gt 0 ]; then
        docker_args+=(-v "${vscode_extract_dir}:/vscode_sessions:ro")
        if [ "${CLAUDE_MOUNT_SCOPE:-all}" = "filtered" ]; then
          echo "  VS Code Copilot: ${vscode_jsonl_count} sessions (matched to ${MOUNT_LABEL})"
        else
          echo "  VS Code Copilot: ${vscode_jsonl_count} sessions"
        fi
      fi
      _refresh_orphan_recovery_count "${filtered_dir:-}/_metadata.json"
    fi
  fi

  # Extract Antigravity sessions on host (raw transcript copy + synthetic meta line),
  # mount at /antigravity_sessions. Attribution reads the sibling conversations/<uuid>.db
  # via sqlite3; without it sessions still copy (unattributed). Gate on the dir existing.
  if [ -d "$ANTIGRAVITY_DIR" ]; then
    if [ "${CLAUDE_MOUNT_SCOPE:-all}" = "filtered" ] && [ -z "${selected_remote:-}" ]; then
      echo "  Antigravity: skipped (single-project scope but no resolved remote)"
    else
      local antigravity_extract_dir="${HOME}/.paxel/cache/antigravity_extracted-$$"
      rm -rf "$antigravity_extract_dir"
      mkdir -p "$antigravity_extract_dir"
      echo "  Extracting Antigravity sessions..."
      local antigravity_log="${HOME}/.paxel/logs/antigravity-extract.log"
      mkdir -p "$(dirname "$antigravity_log")"
      if ! collect_antigravity_sessions "$antigravity_extract_dir" "${selected_remote:-}" 2>"$antigravity_log"; then
        echo "  Warning: Antigravity session extraction had errors. Continuing with other sessions."
        [ -s "$antigravity_log" ] && echo "  Details: $antigravity_log"
      fi
      local antigravity_jsonl_count
      antigravity_jsonl_count=$(find "$antigravity_extract_dir" -maxdepth 2 -path "*/_antigravity_*/*.jsonl" 2>/dev/null | wc -l | tr -d ' ')
      if [ "$antigravity_jsonl_count" -gt 0 ]; then
        docker_args+=(-v "${antigravity_extract_dir}:/antigravity_sessions:ro")
        if [ "${CLAUDE_MOUNT_SCOPE:-all}" = "filtered" ]; then
          echo "  Antigravity: ${antigravity_jsonl_count} sessions (matched to ${MOUNT_LABEL})"
        else
          echo "  Antigravity: ${antigravity_jsonl_count} sessions"
        fi
      fi
      _refresh_orphan_recovery_count "${filtered_dir:-}/_metadata.json"
    fi
  fi

  # Store sessions restaged by paxel_pull_stage. Multi-repo runs scope each
  # repo on its own and leave the store out.
  local store_jsonl_count=0
  if [ "${PAXEL_STORE_JSONL:-0}" -gt 0 ]; then
    if [ "$MULTI_REPO_RUNNING" -ne 0 ]; then
      echo "  Transcript store: not used when several repos are analyzed one by one. Run with --all, or from one repo, to include its $(paxel_sessions_text "$PAXEL_STORE_SESSIONS")."
      paxel_pull_discard
    elif paxel_pull_image_ready "$PAXEL_CLIENT_IMAGE"; then
      docker_args+=(-v "${PAXEL_STORE_STAGE_DIR}:/store_sessions:ro")
      docker_args+=(-e "PAXEL_STORE_BOX_COUNT=${PAXEL_STORE_BOXES:-}")
      store_jsonl_count="$PAXEL_STORE_JSONL"
      if [ "${CLAUDE_MOUNT_SCOPE:-all}" = "filtered" ]; then
        echo "  Transcript store: $(paxel_sessions_text "$PAXEL_STORE_SESSIONS") (matched to ${MOUNT_LABEL}, from ${PAXEL_STORE_LINK})"
      else
        echo "  Transcript store: $(paxel_sessions_text "$PAXEL_STORE_SESSIONS") (from ${PAXEL_STORE_LINK})"
      fi
    else
      paxel_pull_discard
    fi
  fi

  # Docker --all host-side recovery detection. Populates _RMDC_LOG_FILE
  # so the env-var passthrough below forwards non-zero project_cache /
  # unresolvable / ancestor / worktree_list / jj_workspace_list counts
  # to the container.
  #
  # ORDERING IS LOAD-BEARING: this scan MUST run before the
  # _rmdc_recovery_count_unique / _recovery_source_breakdown reads
  # below, or the env vars ship empty. Pinned by CJ10f bats test.
  if [ "${ALL_PROJECTS:-0}" -eq 1 ]; then
    _docker_all_host_scan_for_recovery "$CLAUDE_DIR"
    _print_unattributed_summary
  fi

  # Extract per-repo git history for --all so the container can sum it into one
  # combined git_metrics (collect_git_data_aggregate). --no-repo opts out, the
  # same way it suppresses the single-repo mount below.
  if [ "${ALL_PROJECTS:-0}" -eq 1 ] && [ "${NO_REPO:-0}" != "1" ]; then
    _docker_all_extract_git_data "$CLAUDE_DIR" \
      "${codex_extract_dir:-}" \
      "${cursor_extract_dir:-}" \
      "${opencode_extract_dir:-}" \
      "${gemini_extract_dir:-}" \
      "${vscode_extract_dir:-}" \
      "${antigravity_extract_dir:-}"
  fi

  # Pass orphan_recovery_count + recovery_breakdown as Docker env vars.
  # ClientPipeline's readers fall back to these env vars when the archive
  # sidecar lacks the fields. Host-side activity only — in-container
  # recoveries flow through the container's own path.
  #
  # The scan above also self-warms ~/.paxel/cache/project-remotes-v2.tsv
  # (via _project_cache_persist_rows) so future runs can recover a
  # deleted Conductor workspace that was live during this run.
  # Symmetric with legacy --all's behavior in collect_all_projects:3376.
  if [ -n "${_RMDC_LOG_FILE:-}" ]; then
    local _rmdc_for_env
    _rmdc_for_env=$(_rmdc_recovery_count_unique)
    docker_args+=(-e "PAXEL_ORPHAN_RECOVERY_COUNT=${_rmdc_for_env:-0}")
    local _rbrk_for_env
    _rbrk_for_env=$(_recovery_source_breakdown)
    docker_args+=(-e "PAXEL_RECOVERY_BREAKDOWN=${_rbrk_for_env}")
  fi

  # Bind-mount the host-written sidecar read-only into the container so
  # TranscriptDiscoverer.read_sidecar can resolve Claude workspace
  # git_remotes for Conductor dead-cwds (host-scan cache hits). Docker
  # --all bind-mounts $CLAUDE_DIR read-only at /transcripts, so there's
  # no archive sidecar to carry these; this secondary mount closes the
  # attribution gap end-to-end. Gated on ALL_PROJECTS=1 and existence of
  # the host-written file (jq-less hosts skip the write, and we skip the
  # mount here too — the container falls back to encoded_name, same as
  # the pre-sidecar baseline).
  if [ "${ALL_PROJECTS:-0}" -eq 1 ]; then
    local _dall_sidecar
    _dall_sidecar="$(_docker_all_sidecar_dir)"
    # OR _git/ so jq-less hosts (which skip the _metadata.json write) still ship aggregate git.
    if [ -f "${_dall_sidecar}/_metadata.json" ] || [ -d "${_dall_sidecar}/_git" ]; then
      docker_args+=(-v "${_dall_sidecar}:/paxel_sidecar:ro")
    fi
  fi

  # Repo mount for on-device code quality analysis (on by default, --no-repo to skip)
  if [ "${NO_REPO:-0}" != "1" ]; then
    local repo_root
    # `|| true` is LOAD-BEARING: when REPO_ROOT is unset (e.g. "Analyze ALL
    # projects" chosen from a non-repo dir like $HOME), git rev-parse exits 128.
    # `2>/dev/null` hides stderr but NOT the exit code, so under `set -Eeuo
    # pipefail` + `set -E` the failure fires the ERR trap (once inside the $()
    # subshell, once for the outer assignment) and aborts the whole upload. The
    # `|| true` keeps the substitution empty-on-failure so the `[ -n ]` guard
    # below simply skips the repo mount. See _paxel_on_error trap above.
    repo_root="${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || true)}"
    if [ -n "$repo_root" ]; then
      local mount_repo=1

      if [ "$mount_repo" = "1" ]; then
        echo "  Mounting repo from ${repo_root} (read-only)"
        docker_args+=(-v "${repo_root}:/repo:ro")

        # Extract git metrics on host (bounded to 5000 commits)
        local git_metrics_file="${HOME}/.paxel/git_metrics.txt"
        mkdir -p "${HOME}/.paxel"
        _run_with_timeout "$PAXEL_GIT_TIMEOUT" git -C "$repo_root" log -n 5000 --no-merges --numstat --format='%H|%aI|%s' > "$git_metrics_file" 2>/dev/null || true
        # No file-level chmod: the runtime user can read this bind mount, and the
        # 0700 ~/.paxel parent directory shields it from other host users.
        if [ -s "$git_metrics_file" ]; then
          docker_args+=(-v "${git_metrics_file}:/git_metrics.txt:ro")
          echo "  Extracted git metrics ($(wc -l < "$git_metrics_file" | tr -d ' ') lines)"
        fi
      fi
    fi
  fi

  # Where each mounted session comes from: this machine, or a box through the
  # transcript store.
  if [ "$MULTI_REPO_RUNNING" -eq 0 ] && declare -F paxel_pull_print_sources >/dev/null 2>&1; then
    local sources_sidecar="${CLAUDE_DIR}/_metadata.json"
    if [ "${ALL_PROJECTS:-0}" -eq 1 ]; then
      sources_sidecar="$(_docker_all_sidecar_dir)/_metadata.json"
    fi
    paxel_pull_print_sources "$CLAUDE_DIR" "$sources_sidecar" \
      Codex "${codex_extract_dir:-}" Cursor "${cursor_extract_dir:-}" opencode "${opencode_extract_dir:-}" \
      "Gemini CLI" "${gemini_extract_dir:-}" "VS Code Copilot" "${vscode_extract_dir:-}" \
      Antigravity "${antigravity_extract_dir:-}" || true
  fi

  local is_localhost=0
  if echo "$PAXEL_SERVER" | grep -qE 'https?://(localhost|127\.0\.0\.1)'; then
    docker_server=$(echo "$PAXEL_SERVER" | sed -E 's/(localhost|127\.0\.0\.1)/host.docker.internal/')
    # Linux needs explicit host mapping; macOS/Windows Docker Desktop has it built-in
    docker_args+=(--add-host=host.docker.internal:host-gateway)
    is_localhost=1
  fi

  # Match the container's SINCE_EPOCH filter so an empty time window is not
  # reported as a Docker mount failure.
  local claude_mounted_jsonl_count=0
  if [ -d "$CLAUDE_DIR" ]; then
    local _host_jsonl _host_mtime
    while IFS= read -r _host_jsonl; do
      [ -z "$_host_jsonl" ] && continue
      if [ -n "${SINCE_EPOCH:-}" ]; then
        _host_mtime=$(stat -c %Y "$_host_jsonl" 2>/dev/null || stat -f %m "$_host_jsonl" 2>/dev/null || echo "0")
        [ "$_host_mtime" -lt "$SINCE_EPOCH" ] 2>/dev/null && continue
      fi
      claude_mounted_jsonl_count=$((claude_mounted_jsonl_count + 1))
    done < <(find "$CLAUDE_DIR" -name "*.jsonl" -not -path "*/_git/*" 2>/dev/null)
  fi

  local host_jsonl_count
  host_jsonl_count=$((
    ${claude_mounted_jsonl_count:-0} + ${codex_jsonl_count:-0} +
    ${cursor_jsonl_count:-0} + ${opencode_jsonl_count:-0} + ${gemini_jsonl_count:-0} +
    ${vscode_jsonl_count:-0} + ${antigravity_jsonl_count:-0} + ${store_jsonl_count:-0}
  ))
  # LLM proxy URL: rewrite localhost to host.docker.internal for Docker networking
  local llm_proxy_url="${PAXEL_LLM_PROXY}"
  if [ "$is_localhost" -eq 1 ]; then
    llm_proxy_url=$(echo "$PAXEL_LLM_PROXY" | sed -E 's/(localhost|127\.0\.0\.1)/host.docker.internal/')
  fi

  # Allocate a pseudo-TTY when our OUTPUT is a terminal so the container can
  # render a live progress UI (sticky footer + animated bars). Gate on stdout
  # ([ -t 1 ]), NOT stdin ([ -t 0 ]): under `curl … | bash` stdin is the script
  # pipe and never a TTY, but stdout is the user's terminal. We pass -t only
  # (never -i) — the container never reads stdin; all prompts are host-side via
  # /dev/tty — so interactive selection is unaffected. Non-TTY output (CI,
  # `> file`, `| pipe`) skips -t and the pipeline falls back to plain logging.
  if [ -t 1 ]; then
    docker_args+=(-t)
  fi

  docker_args+=(
    -e "YC_TOKEN=${YC_TOKEN}"
    -e "YC_API_KEY=${YC_TOKEN}"
    -e "YC_LLM_PROXY_URL=${llm_proxy_url}"
    -e "YC_RESULTS_ENDPOINT=${docker_server}/api/v1/results"
    -e "PAXEL_LOG_DIR=/logs"
    -e "PAXEL_HOST_JSONL_COUNT=${host_jsonl_count}"
    -e "PAXEL_HOST_OS=${host_os}"
  )

  # Unified [Step N/17] counter on BOTH paths: bash owns steps 1-3
  # (prereq/sign-in/pull, printed once up front), the container owns steps 4-17.
  # Multi-repo runs the container once per repo, so each repo re-runs steps 4-17
  # under its own "═══ [n/total] Analyzing: NAME ═══" banner — same /17 scale as
  # the pull line. Previously multi-repo left the offset unset, so each repo reset
  # to a disjoint [Step 1/14]..[14/14] that clashed with the /17 pull line and read
  # like a restart/stall (risking a needless Ctrl-C mid-batch).
  docker_args+=(-e "PAXEL_STEP_OFFSET=3")

  # Localhost = dev mode, enable verbose logging
  if [ "$is_localhost" -eq 1 ]; then
    docker_args+=(-e "PAXEL_VERBOSE=1")
  fi

  # Propagate PAXEL_CLIENT_MODE into the container. AnthropicClient uses it to
  # pick env-aware remediation text (bin/upload for dev, `curl | bash` for
  # public users) when a Fatal LLM error hits the rake footer.
  # bin/upload sets this to "dev"; public curl|bash runs leave it unset.
  if [ -n "${PAXEL_CLIENT_MODE:-}" ]; then
    docker_args+=(-e "PAXEL_CLIENT_MODE=${PAXEL_CLIENT_MODE}")
  fi

  # Escape hatch for the preflight-signatures handshake (reviewed by
  # AnthropicClient.preflight_prompts!). Host-side env needs explicit
  # `docker -e` forwarding; without this line a host-side
  # `PAXEL_SKIP_PREFLIGHT=1 bin/upload` is a no-op because the container
  # never sees the value.
  if [ "${PAXEL_SKIP_PREFLIGHT:-0}" = "1" ]; then
    docker_args+=(-e "PAXEL_SKIP_PREFLIGHT=1")
  fi

  # Credential-scrub bypass (SecretScrubber + ToolInputSummarizer + related
  # EventExtractor hooks). Default on inside the container. Set
  # PAXEL_TOOL_OUTPUT_SCRUB=0 on the host before bin/upload to disable for
  # admin debugging — chunks.content then carries raw tool_use / text content
  # untouched. Not intended as a user-facing toggle; only forwarded when
  # explicitly set, otherwise container uses its own default (on).
  if [ -n "${PAXEL_TOOL_OUTPUT_SCRUB:-}" ]; then
    docker_args+=(-e "PAXEL_TOOL_OUTPUT_SCRUB=${PAXEL_TOOL_OUTPUT_SCRUB}")
  fi

  # Pass through optional filters
  if [ -n "$SINCE_EPOCH" ]; then
    docker_args+=(-e "SINCE_EPOCH=${SINCE_EPOCH}")
  fi

  if [ -n "$PROJECT_NAME" ]; then
    docker_args+=(-e "PROJECT_NAME=${PROJECT_NAME}")
  fi

  # Signal to the container that the host already filtered transcripts by
  # git remote (more accurate than the container's encoded-name substring
  # match) so analyze_local.rake skips its redundant in-container filter.
  # Without this, the sidecar has been getting dropped on re-filter.
  if [ "${CLAUDE_MOUNT_SCOPE:-all}" = "filtered" ]; then
    docker_args+=(-e "CLAUDE_MOUNT_SCOPE=filtered")
  fi

  # Per-repo log label so each multi-repo container writes an identifiable
  # ${MOUNT_LABEL}-<ts>.log instead of a colliding all-<ts>.log (analyze_local.rake
  # prefers PAXEL_LOG_LABEL over PROJECT_NAME for the filename).
  if [ -n "${MOUNT_LABEL:-}" ]; then
    docker_args+=(-e "PAXEL_LOG_LABEL=${MOUNT_LABEL}")
  fi

  # Pass host-side time estimate for telemetry calibration
  if [ -n "${PAXEL_HOST_ESTIMATE_MINUTES:-}" ]; then
    docker_args+=(-e "PAXEL_HOST_ESTIMATE_MINUTES=${PAXEL_HOST_ESTIMATE_MINUTES}")
  fi

  # Dev-tuning overrides: bump client-side concurrency for faster local runs.
  # Published defaults (20 / 20 / 20 / 20) are production-safe. The YC LLM
  # proxy + Anthropic tier still cap upstream rate, and AnthropicClient
  # retries 429s with backoff — so bumping these is safe, just effective.
  # DB_POOL must scale with concurrency because each worker checks out an
  # AR connection for session.update! / LlmCall writes.
  for var in PAXEL_NARRATIVE_CONCURRENCY PAXEL_EPISODE_CONCURRENCY \
             PAXEL_NARRATIVE_AGGREGATOR_CONCURRENCY PAXEL_CROSS_SESSION_CONCURRENCY \
             DB_POOL; do
    val="${!var:-}"
    if [ -n "$val" ]; then
      docker_args+=(-e "${var}=${val}")
    fi
  done

  # --no-sentry overrides the baked-in DSN with an empty string. The client
  # initializer returns early when CLIENT_SENTRY_DSN is empty, so no events
  # leave your machine. Without this flag, the image's baked DSN (set via
  # --build-arg during prod publish) is used.
  if [ "${NO_SENTRY:-0}" = "1" ]; then
    docker_args+=(-e "CLIENT_SENTRY_DSN=")
  elif [ -n "${CLIENT_SENTRY_DSN:-}" ]; then
    # Host env wins over baked default — useful for dev testing with a scratch DSN.
    docker_args+=(-e "CLIENT_SENTRY_DSN=${CLIENT_SENTRY_DSN}")
  fi

  # Run the client container and tee all output to a host log while preserving
  # docker's exit status through the pipeline.
  # MSYS_NO_PATHCONV=1: under Git Bash / MSYS on Windows, the MSYS layer rewrites the
  # container-side mount paths (e.g. -v host:/transcripts → host:C:/Program Files/Git/
  # transcripts), so the container can't see the data (PAXEL report 2026-06-06). Scoping
  # it to this docker invocation disables that rewrite for the mount args only; it's an
  # unused, harmless env var on macOS/Linux.
  local exit_code=0
  local console_log="${log_dir}/${_log_label}-$(date +%Y%m%d-%H%M%S)-console.$$.log"
  local pipeline_status=(0 0)
  if MSYS_NO_PATHCONV=1 docker run "${docker_args[@]}" "$PAXEL_CLIENT_IMAGE" 2>&1 | tee "$console_log"; then
    pipeline_status=("${PIPESTATUS[@]}")
  else
    pipeline_status=("${PIPESTATUS[@]}")
  fi
  exit_code="${pipeline_status[0]}"
  if [ "${pipeline_status[1]}" -ne 0 ]; then
    echo "Paxel could not save the container log to ${console_log}." >&2
    [ "$exit_code" -eq 0 ] && exit_code=1
  fi

  # Exit code 3 == ClientPipeline::EXIT_NO_ANALYZABLE_SESSIONS (kept in sync with
  # the Ruby constant by comment only). Benign: there were no transcript files,
  # or all sessions were too short to analyze.
  if [ $exit_code -eq 3 ]; then
    if [ "$MULTI_REPO_RUNNING" -eq 1 ]; then
      echo ""
      echo "Nothing to analyze for ${MOUNT_LABEL:-this project} — skipping."
      return 0
    fi
    paxel_skill_upload_hint "Paxel reads the agent sessions on this machine only." || true
    exit 0
  fi

  # exit 4 (EXIT_UPLOAD_DEFERRED): analysis finished, the upload failed, but it was
  # stashed for replay. Honest message instead of "Upload complete!" — the results
  # aren't lost and the next run auto-uploads them; nothing lands at /reports until then.
  if [ $exit_code -eq 4 ]; then
    echo ""
    echo "⚠  Analysis finished, but the upload to the server didn't go through — your results are saved locally."
    echo "   They'll upload automatically the next time you run, or re-run now to retry."
    echo "   Your report won't appear at ${PAXEL_SERVER}/reports until it uploads."
    if [ "$MULTI_REPO_RUNNING" -eq 1 ]; then return 0; fi
    exit 0
  fi

  # exit 5 (EXIT_UPLOAD_FAILED): analysis finished but the upload failed with no replay
  # artifact (a permanent rejection or an un-stashable result). There's nothing to
  # auto-retry, so tell the user to re-run rather than promising an automatic upload.
  if [ $exit_code -eq 5 ]; then
    echo ""
    echo "⚠  Analysis finished, but the upload to the server didn't go through and couldn't be queued for an automatic retry."
    echo "   Re-run to try the upload again. Your report won't appear at ${PAXEL_SERVER}/reports until it uploads."
    if [ "$MULTI_REPO_RUNNING" -eq 1 ]; then return 0; fi
    exit 0
  fi

  if [ "$exit_code" -eq "$PAXEL_EXIT_STORAGE_FULL" ]; then
    if [ "$MULTI_REPO_RUNNING" -eq 1 ]; then return "$PAXEL_EXIT_STORAGE_FULL"; fi
    exit "$PAXEL_EXIT_STORAGE_FULL"
  fi

  # The container already printed the specifics; keep the host summary
  # short and don't suggest a retry that can't work from here.
  # By this point the analysis may have finished — only the upload was
  # refused — so the state line differs from the pre-run blocks.
  if [ "$exit_code" -eq "$PAXEL_EXIT_REGION_BLOCKED" ]; then
    echo ""
    print_region_blocked "The analysis stopped and nothing was uploaded — your report won't appear at ${PAXEL_SERVER}/reports."
    if [ "$MULTI_REPO_RUNNING" -eq 1 ]; then return "$PAXEL_EXIT_REGION_BLOCKED"; fi
    exit "$PAXEL_EXIT_REGION_BLOCKED"
  fi

  if [ $exit_code -ne 0 ]; then
    echo ""
    # Name the repo + point to its (now per-repo-named) log so a mid-batch failure is
    # diagnosable — the "═══ Analyzing: NAME ═══" header scrolls away, and the
    # generic message used to give the user nothing to act on.
    echo "Analysis failed for ${MOUNT_LABEL:-this project} (exit code: $exit_code)." >&2
    echo "     Log: ${console_log}" >&2
    echo "Try again, or email paxel@ycombinator.com with that log if the problem persists." >&2
    if [ "$MULTI_REPO_RUNNING" -eq 1 ]; then
      return $exit_code
    fi
    exit $exit_code
  fi

  if [ "$MULTI_REPO_RUNNING" -eq 0 ]; then
    echo "Upload complete! Check your results at: ${PAXEL_SERVER}/reports"
    echo "     Logs saved to: ${log_dir}/"
    paxel_skill_upload_hint "This report covers the agent sessions on this machine only." || true
  else
    echo "  Done — log: ${log_dir}/${_log_label}-*.log"
  fi

  # Terminal bell + macOS notification on completion (skip in multi-repo mode, one at the end)
  if [ "$MULTI_REPO_RUNNING" -eq 0 ]; then
    printf '\a'
    if [ "$(uname -s)" = "Darwin" ]; then
      local notify_msg="Analysis uploaded."
      if [ -n "${ESTIMATED_MINUTES:-}" ]; then
        notify_msg="Analysis uploaded. Results in ~${ESTIMATED_MINUTES} minutes."
      fi
      osascript -e "display notification \"${notify_msg}\" with title \"Paxel\"" 2>/dev/null || true
    fi
  fi
}

run_docker_mode() {

  if [ "$(id -u)" -eq 0 ]; then
    echo "Error: Do not run Paxel as root or with sudo." >&2
    echo "Run the same command as your normal user." >&2
    exit 1
  fi

  echo ""
  echo "YC Paxel — coding agent analysis"
  echo "Scanning for coding agent transcripts (Claude Code, Codex, Cursor)..."
  echo ""

  if [ -z "${PAXEL_NO_SKILL:-}" ]; then
    paxel_skill_for_upload || true
  fi
  check_docker
  load_or_request_token
  register_git_identity

  # Pending-upload replay (from prior failed runs).
  # Replay-and-exit: if a stash exists, replay it and exit WITHOUT running
  # the fresh pipeline. The user re-runs `bin/upload` for a fresh analysis.
  # --no-replay (PAXEL_SKIP_REPLAY) bypasses.
  # PAXEL_IN_REPLAY guards against the rake task re-entering replay.
  if [ -z "${PAXEL_SKIP_REPLAY:-}" ] && [ -z "${PAXEL_IN_REPLAY:-}" ]; then
    local _pending_dir="$HOME/.paxel/data/pending-uploads"
    local _pending_count=0
    if [ -d "$_pending_dir" ]; then
      _pending_count=$(find "$_pending_dir" -maxdepth 1 -type f -name '*.meta.json' 2>/dev/null | wc -l | tr -d ' ')
    fi

    if [ "$_pending_count" -gt 0 ] || [ -n "${PAXEL_RESUME_PENDING_ONLY:-}" ]; then
      if [ "$_pending_count" -eq 0 ]; then
        # --resume-pending with nothing pending — explicit exit (no fresh pipeline).
        echo "[paxel] No pending uploads — nothing to resume."
        exit 0
      fi

      echo ""
      echo "[paxel] Found $_pending_count pending upload(s) from a prior failed run."
      # Pre-replay banner is intentionally neutral — the outcome-specific case
      # statement below emits the correct remediation command. Embedding
      # rerun_phrase here would show the user a pre-baked-token curl BEFORE
      # we know if the replay needs re-authentication (in which case that
      # token is the one to replace). Caught in review by both Codex and Opus.
      echo "[paxel] Replaying, then exiting."
      echo ""

      # Populate $PAXEL_CLIENT_IMAGE for this branch. Reuses the existing helper so
      # dev mode uses the locally-built tag and prod uses GHCR. PAXEL_QUIET_PULL=1
      # suppresses the step-indexed banner + cost-coverage blurb, which are
      # misleading during a replay-and-exit (no 17-step pipeline is about to run).
      PAXEL_QUIET_PULL=1 pull_client_image

      # Mirror the fresh-pipeline's localhost→host.docker.internal rewrite.
      # Uses sed -E for macOS/BSD compatibility (no \b word boundary).
      local _replay_endpoint="${YC_RESULTS_ENDPOINT:-${PAXEL_SERVER}/api/v1/results}"
      _replay_endpoint=$(printf '%s' "$_replay_endpoint" | sed -E 's/(localhost|127\.0\.0\.1)/host.docker.internal/')

      mkdir -p "$HOME/.paxel/logs"
      local _replay_log
      local _replay_exit
      local _reauth_attempted=0
      local _replay_os
      _replay_os=$(uname -s)
      local _replay_uid
      _replay_uid=$(id -u)
      local _replay_gid
      _replay_gid=$(id -g)

      # Loop runs at most twice: once with the cached/current token; if that
      # exits 2 (reauth_required), clear the cached token, re-prompt via
      # load_or_request_token, and retry ONCE. A second-attempt 2 falls
      # through to the normal case statement below (user intervention
      # required). PAXEL_SKIP_REAUTH_RETRY=1 disables the loop for CI /
      # scripted runs that prefer an explicit exit-2 signal over an
      # interactive prompt.
      while :; do
        # Token: prefer shell env, fall back to the token file (matches load_or_request_token).
        # Re-read each iteration because load_or_request_token on retry replaces it.
        # `|| true` is required: `2>/dev/null` suppresses cat's stderr but NOT
        # its non-zero exit. Under `set -E`, the ERR trap fires on cat failure
        # inside the command substitution even though `local var=$(…)` masks
        # set -e exit propagation. Without it, users whose token file was
        # deleted (or never created — YC_TOKEN env-only path) would see the
        # "email us" banner before the replay runs. Empty `_replay_token` is
        # a valid state: the replay container 401s, falls through to exit=2
        # (reauth), and the user gets the "re-authentication" message.
        local _replay_token="${YC_TOKEN:-$(cat "${PAXEL_TOKEN_FILE:-$HOME/.paxel/token}" 2>/dev/null || true)}"

        # Timestamped per-attempt so first-attempt output isn't clobbered on retry.
        # `.$$` (PID) suffix guards against a same-second collision if two
        # bin/upload invocations race each other — timestamp is second-resolution
        # alone, so concurrent runs would otherwise tee into the same file.
        if [ "$_reauth_attempted" = "1" ]; then
          _replay_log="$HOME/.paxel/logs/replay-$(date +%Y%m%d-%H%M%S)-retry.$$.log"
        else
          _replay_log="$HOME/.paxel/logs/replay-$(date +%Y%m%d-%H%M%S).$$.log"
        fi

        local _replay_args=(
          --rm
          -v "$HOME/.paxel/data:/rails/data:rw"
          -e YC_TOKEN="$_replay_token"
          -e YC_RESULTS_ENDPOINT="$_replay_endpoint"
          -e PAXEL_PENDING_UPLOAD_DIR=/rails/data/pending-uploads
          -e PAXEL_IN_REPLAY=1
        )
        if [ "$_replay_os" = "Linux" ]; then
          _replay_args+=(
            --user "${_replay_uid}:${_replay_gid}"
            --tmpfs "/rails/tmp:rw,uid=${_replay_uid},gid=${_replay_gid},mode=0700"
            -e "HOME=/rails/tmp/home"
          )
        fi
        # Propagate PAXEL_CLIENT_MODE into the replay container. Symmetric to
        # the fresh-pipeline forward at :4597 — AnthropicClient's env-aware
        # user_action helpers (rebuild / auth / input_too_large /
        # model_not_allowed / system_prompt_missing) need this to pick
        # dev-appropriate remediation text when a Fatal LLM error hits the
        # replay rake's log. (Added in PR #726.)
        if [ -n "${PAXEL_CLIENT_MODE:-}" ]; then
          _replay_args+=(-e "PAXEL_CLIENT_MODE=${PAXEL_CLIENT_MODE}")
        fi
        # Honor --no-sentry in the replay container (same policy as fresh-path at :4081).
        # The client initializer short-circuits when CLIENT_SENTRY_DSN is empty, so
        # forcing "" here disables telemetry even though the DSN is baked into the image.
        if [ "${NO_SENTRY:-0}" = "1" ]; then
          _replay_args+=(-e "CLIENT_SENTRY_DSN=")
        elif [ -n "${CLIENT_SENTRY_DSN:-}" ]; then
          _replay_args+=(-e "CLIENT_SENTRY_DSN=${CLIENT_SENTRY_DSN}")
        fi
        if [ "$_replay_os" = "Linux" ]; then
          _replay_args+=(--add-host=host.docker.internal:host-gateway)
        fi
        _replay_args+=(
          --entrypoint /bin/bash
          "$PAXEL_CLIENT_IMAGE"
          -c 'mkdir -p "$HOME" && bin/rails pending_uploads:replay'
        )

        # Run and preserve the docker exit code through the tee pipe.
        # `|| true` is LOAD-BEARING: without it, under `set -Eeuo pipefail`, a
        # non-zero docker exit (e.g. deferred=1 on HTTP 504, or a crashed daemon)
        # aborts the LHS group BEFORE `echo "__EXIT__:$?"` runs, skipping the
        # sentinel and firing the ERR trap's "email us" banner twice (once per
        # pipeline command). With `|| true`, bash's set-e exception suppresses
        # errexit for the whole pipeline AND inside the LHS group, so the
        # sentinel is emitted and the case statement below handles the exit code.
        # MSYS_NO_PATHCONV=1: same Windows mount-path fix as the main run above
        # (this run mounts -v …:/rails/data); no-op on macOS/Linux.
        { MSYS_NO_PATHCONV=1 docker run "${_replay_args[@]}"; echo "__EXIT__:$?"; } 2>&1 | tee "$_replay_log" || true
        # `2>/dev/null || true` guards the fallback below: if tee never wrote
        # the log (disk full, unwritable dir), awk returns non-zero and would
        # otherwise trip the ERR trap before the `-z` fallback can assign 99.
        _replay_exit=$(awk -F: '/^__EXIT__:/ { print $2; exit }' "$_replay_log" 2>/dev/null || true)
        # Defensive fallback — if the sentinel is missing (docker crashed before
        # printing, tee write failed, etc.), default to a generic failure code
        # rather than passing "" to `exit` (which bash rejects with "numeric
        # argument required" and leaves the user with a confusing error).
        [ -z "$_replay_exit" ] && _replay_exit=99
        # Strip the sentinel from the log for cleanliness.
        sed -i.bak '/^__EXIT__:/d' "$_replay_log" 2>/dev/null && rm -f "${_replay_log}.bak"

        if docker_error_file_is_storage_full "$_replay_log"; then
          echo ""
          print_docker_storage_error "while replaying a completed upload"
          exit "$PAXEL_EXIT_STORAGE_FULL"
        fi

        # Auto-re-auth on reauth_required (exit 2), once. Without this the
        # user has to manually re-run bin/upload after re-authing; the replay
        # itself already knows what needs fixing.
        if [ "$_replay_exit" = "2" ] \
           && [ "$_reauth_attempted" = "0" ] \
           && [ "${PAXEL_SKIP_REAUTH_RETRY:-0}" != "1" ]; then
          echo ""
          echo "[paxel] Your session expired — re-authenticating..."
          # Clear the invalid cached token so load_or_request_token falls
          # through to the baked-token / browser-auth paths. Unset the env
          # var too, since it takes precedence in that function.
          rm -f "${PAXEL_TOKEN_FILE:-$HOME/.paxel/token}" 2>/dev/null || true
          unset YC_TOKEN
          _reauth_attempted=1
          load_or_request_token
          echo ""
          echo "[paxel] Retrying replay with refreshed credentials..."
          continue
        fi
        break
      done

      echo ""
      case "$_replay_exit" in
        0)
          echo "[paxel] Replay complete. $(rerun_phrase fresh)"
          # All stashes cleared, so the next run skips this gate and reaches the
          # picker — re-analyzing any repo a prior multi-repo run didn't finish.
          multi_repo_replay_hint
          ;;
        1)
          echo "[paxel] Replay partial — some stashes deferred. $(rerun_phrase next_upload)"
          ;;
        2)
          if [ "$_reauth_attempted" = "1" ]; then
            echo "[paxel] Replay still needs re-authentication after one retry — your credentials may be revoked."
            echo "[paxel] Sign in again at: ${PAXEL_SERVER}/auth/login"
          else
            echo "[paxel] Replay needs re-authentication. $(rerun_phrase reauth)"
          fi
          ;;
        *)
          echo "[paxel] Replay failed with exit code $_replay_exit. $(rerun_phrase bypass_replay)"
          ;;
      esac
      echo "[paxel] Log: $_replay_log"
      exit "$_replay_exit"
    fi
  fi

  # Deliberately AFTER the replay-and-exit block above: a spent budget must never
  # block delivery of a report that already finished and was paid for. Only NEW
  # analysis is gated, and only here, before anything costs money.
  check_daily_quota

  # Before session detection, so the "no sessions here" paths below count the
  # sessions your remote machines pushed to your transcript store.
  if declare -F paxel_pull_stage_for_run >/dev/null 2>&1; then
    paxel_pull_stage_for_run
  fi

  local match_label=""

  # Auto-scope to current project unless --all was passed.
  # Filtering happens HERE on the host (not in Docker — the container can't
  # see host git repos, so it only has substring matching as a fallback).
  #
  # Even when --project is explicit, we still run this block when invoked
  # from inside a git repo. If the filter produces a match, the resulting
  # sidecar gives TranscriptDiscoverer the git_remote it needs to collapse
  # Conductor worktree scatter. If PROJECT_NAME is set but doesn't match
  # the matched repo's name (e.g. user ran --project yc-backend from inside
  # paxel), we discard the filter below and let the container substring-match.
  if [ "$ALL_PROJECTS" -eq 0 ]; then
    local filtered_dir="${HOME}/.paxel/cache/filtered-transcripts-$$"
    rm -rf "$filtered_dir"
    mkdir -p "$filtered_dir"
    local match_count=0
    match_label=""

    # Strategy 1: match by git remote URL (most accurate for repos with multiple workspaces)
    local cwd_remote
    cwd_remote=$(get_git_remote "$(pwd)")
    if [ -n "$cwd_remote" ]; then
      local repo_name
      repo_name=$(echo "$cwd_remote" | sed 's|.*[:/]||' | sed 's/\.git$//')
      match_label="$repo_name"

      if [ -d "$CLAUDE_DIR" ]; then
        # First pass: collect all dir names, CWDs, and remotes
        local _bfc_names=()
        _bfc_cwds=()
        _bfc_remotes=()
        local _scan_total=0
        local _scan_count=0
        for d in "$CLAUDE_DIR"/*/; do [ -d "$d" ] && _scan_total=$((_scan_total + 1)); done
        echo "  Finding your coding sessions..." >&2
        for dir in "$CLAUDE_DIR"/*/; do
          [ -d "$dir" ] || continue
          _scan_count=$((_scan_count + 1))
          if [ $((_scan_count % 500)) -eq 0 ]; then
            echo "  ...${_scan_count}/${_scan_total} checked" >&2
          fi
          local dir_name
          dir_name=$(basename "$dir")
          local dir_cwd
          dir_cwd=$(get_project_cwd "$dir_name")
          local dir_remote
          dir_remote=$(get_git_remote "$dir_cwd")
          _bfc_names+=("$dir_name")
          _bfc_cwds+=("$dir_cwd")
          _bfc_remotes+=("$dir_remote")
        done

        # Backfill remotes for deleted Conductor workspaces
        backfill_conductor_remotes
        # Recover remotes for non-Conductor orphan cwds
        local _orphan_j=0
        while [ $_orphan_j -lt ${#_bfc_cwds[@]} ]; do
          if [ -z "${_bfc_remotes[$_orphan_j]}" ]; then
            local _orphan_recovered
            _orphan_recovered=$(resolve_remote_for_dead_cwd "${_bfc_cwds[$_orphan_j]}")
            [ -n "$_orphan_recovered" ] && _bfc_remotes[$_orphan_j]="$_orphan_recovered"
          fi
          _orphan_j=$((_orphan_j + 1))
        done

        # Second pass: filter by matching remote
        local i=0
        while [ $i -lt ${#_bfc_names[@]} ]; do
          if [ "${_bfc_remotes[$i]}" = "$cwd_remote" ]; then
            # CoW clone, mtime-preserving (-p) so --since (container File.mtime
            # filter) works. Bare under active errexit → a copy failure aborts loud.
            _paxel_cp_transcripts "$CLAUDE_DIR/${_bfc_names[$i]}" "$filtered_dir/${_bfc_names[$i]}"
            match_count=$((match_count + 1))
          fi
          i=$((i + 1))
        done
      fi
    fi

    # Strategy 2: match by current directory path (works without git)
    if [ "$match_count" -eq 0 ]; then
      local current_dir
      current_dir=$(pwd)
      # Encode current path the same way Claude does: it replaces BOTH "/" AND
      # "." with "-" (e.g. /a/b.c -> -a-b-c). Matching only "/" (the old
      # `sed 's|/|-|g'`) silently broke Strategy-2 path matching for any cwd
      # containing a dot — a repo/domain/dir like x70.one or qerdp.co.uk, even a
      # macOS /var/folders/.../T/tmp.X path — so a no-remote repo fell through to
      # "None of your sessions match this directory." See SESSION_DETECTION.md
      # §3a. ("." is a literal inside the [] bracket expression on BSD + GNU sed.)
      local encoded_cwd
      encoded_cwd=$(encode_claude_dir_name "$current_dir")
      match_label="$(basename "$current_dir")"

      if [ -d "$CLAUDE_DIR" ]; then
        for dir in "$CLAUDE_DIR"/*/; do
          [ -d "$dir" ] || continue
          local dir_name
          dir_name=$(basename "$dir")
          # Exact match (this workspace) or prefix match (subdirectory)
          if [ "$dir_name" = "$encoded_cwd" ]; then
            # CoW clone, mtime-preserving (-p) so --since (container File.mtime
            # filter) works. Bare under active errexit → a copy failure aborts loud.
            _paxel_cp_transcripts "$dir" "$filtered_dir/$dir_name"
            match_count=$((match_count + 1))
          fi
        done
      fi
    fi

    # PROJECT_NAME override safety: if the user passed --project NAME and the
    # auto-filter matched a DIFFERENT repo (e.g. ran --project yc-backend from
    # inside paxel), discard the filter so the container's substring match can
    # pick the right thing. Matches repo_name loosely (case-insensitive, -/_
    # treated the same).
    if [ "$match_count" -gt 0 ] && [ -n "$PROJECT_NAME" ]; then
      local _pn_norm
      _pn_norm=$(echo "$PROJECT_NAME" | tr '[:upper:]' '[:lower:]' | tr '_' '-')
      local _rn_norm
      _rn_norm=$(echo "${match_label}" | tr '[:upper:]' '[:lower:]' | tr '_' '-')
      case "$_rn_norm" in
        *"$_pn_norm"*) : ;;  # matched project-name substring — keep the filter
        *)
          echo "  --project $PROJECT_NAME given, but current dir is '${match_label}'. Deferring to container substring match." >&2
          rm -rf "$filtered_dir"
          mkdir -p "$filtered_dir"
          match_count=0
          ;;
      esac
    fi

    if [ "$match_count" -gt 0 ]; then
      # Check: if match_count is low AND this directory has child repos with more data,
      # prefer the multi-repo picker over a weak single-project match.
      # This handles the case where ~/git itself is a repo but the user really wants
      # to analyze child repos inside ~/git.
      local child_repo_override=0
      if [ "$match_count" -le 2 ]; then
        local self_sessions
        self_sessions=$(count_sessions "$filtered_dir")
        # Store sessions staged for this repo count toward it too.
        self_sessions=$((self_sessions + ${PAXEL_STORE_SESSIONS:-0}))
        if detect_child_repos && [ ${#CHILD_REPO_NAMES[@]} -ge 2 ]; then
          # Sum child repo sessions
          local child_total=0
          local cr=0
          while [ $cr -lt ${#CHILD_REPO_SESSIONS[@]} ]; do
            child_total=$((child_total + ${CHILD_REPO_SESSIONS[$cr]}))
            cr=$((cr + 1))
          done
          # If child repos have significantly more data, prefer multi-repo
          if [ "$child_total" -gt $((self_sessions * 3)) ]; then
            child_repo_override=1
          fi
        fi
      fi

      if [ "$child_repo_override" -eq 1 ]; then
        # Discard the weak single-project match, use multi-repo path instead
        rm -rf "$filtered_dir"
        show_child_repo_menu
        run_selected_child_repos
      fi

      local orig_claude_dir="$CLAUDE_DIR"

      # Compute OLDEST_SESSION_EPOCH from source files (before cp changed mtime)
      # Uses original CLAUDE_DIR files, not filtered_dir copies
      if [ -z "$OLDEST_SESSION_EPOCH" ]; then
        local _oldest
        # Trailing `|| true` swallows the SIGPIPE (141) from `head -1` closing
        # upstream `stat` writes under `set -euo pipefail` — with 4000+ jsonls,
        # head reliably closes before stat drains and without this the whole
        # pipeline returns 141, killing the script mid-scan.
        # GNU stat -c %Y first: BSD stat -f on Linux exits 0 with filesystem
        # info, so BSD-first would silently poison the result on the CI runner.
        _oldest=$(find "$orig_claude_dir" -name "*.jsonl" -not -name "_*" -maxdepth 3 2>/dev/null \
          | while read -r f; do stat -c '%Y' "$f" 2>/dev/null || stat -f '%m' "$f" 2>/dev/null; done \
          | sort -n | head -1 || true)
        [ -n "$_oldest" ] && OLDEST_SESSION_EPOCH="$_oldest"
      fi
      if [ -n "${PAXEL_STORE_OLDEST_EPOCH:-}" ] \
        && { [ -z "$OLDEST_SESSION_EPOCH" ] || [ "$PAXEL_STORE_OLDEST_EPOCH" -lt "$OLDEST_SESSION_EPOCH" ]; }; then
        OLDEST_SESSION_EPOCH="$PAXEL_STORE_OLDEST_EPOCH"
      fi

      CLAUDE_DIR="$filtered_dir"
      CLAUDE_MOUNT_SCOPE="filtered"
      MOUNT_LABEL="$match_label"
      # Scope Cursor extraction to the same remote so cross-repo Cursor sessions
      # don't leak into a single-project upload. Without this, collect_cursor_sessions
      # gets an empty filter and pulls in every workspace's Cursor history.
      selected_remote="$cwd_remote"
      # C6: when the run dir has NO git remote (a home/parent / non-repo dir, e.g.
      # kelvin running from ~), an empty selected_remote made the no-remote-skip guards
      # gut Codex/etc. Instead, scope to this dir: the collectors keep only sessions
      # whose cwd is under it (the home SUBTREE, not the whole machine — /tmp, other
      # volumes are excluded), group them by their own recovered remote when possible,
      # and cwd-bucket the rest. Use the LOGICAL cwd ($PWD, not `pwd -P`) for the
      # descendant prefix match — tools record the logical cwd, so a symlinked home
      # (e.g. ~ -> /private/...) would miss against a physical path.
      if [ -z "$cwd_remote" ]; then
        scope_cwd="${PWD:-$(pwd 2>/dev/null || true)}"
      fi
      echo "Auto-detected project: ${match_label} (${match_count} workspaces)" >&2

      # Low-count warning: if we matched very few workspaces but there are many more available
      if [ "$match_count" -le 3 ]; then
        local total_dirs=0
        for d in "$orig_claude_dir"/*/; do
          [ -d "$d" ] && total_dirs=$((total_dirs + 1))
        done
        if [ "$total_dirs" -ge $((match_count * 3)) ]; then
          local total_sessions
          total_sessions=$(count_sessions "$orig_claude_dir" 2>/dev/null || echo "many")
          echo "" >&2
          echo "  Tip: You have ${total_sessions} total sessions across ${total_dirs} projects." >&2
          echo "  To include all:    $(rerun_cmd --all)" >&2
          echo "  To pick a different project: $(rerun_cmd --project NAME)" >&2
        fi
      fi

      # Collect git metadata for Docker mode (Docker can't see host git repos)
      # Write _metadata.json + _git/ dir with commits and numstat
      # Use backfill-resolved data from _bfc_* arrays when available (Strategy 1),
      # fall back to direct resolution for Strategy 2 matches.
      if [ -z "${_bfc_names+x}" ]; then _bfc_names=(); _bfc_cwds=(); _bfc_remotes=(); fi
      local git_data_dir="${filtered_dir}/_git"
      mkdir -p "$git_data_dir"
      local docker_metadata="{}"

      for dir in "$filtered_dir"/*/; do
        [ -d "$dir" ] || continue
        local dir_name
        dir_name=$(basename "$dir")

        # Look up resolved CWD/remote from backfill arrays if available
        local dir_cwd=""
        local dir_remote=""
        if [ -n "${_bfc_names+x}" ] && [ ${#_bfc_names[@]} -gt 0 ]; then
          local _lookup=0
          while [ $_lookup -lt ${#_bfc_names[@]} ]; do
            if [ "${_bfc_names[$_lookup]}" = "$dir_name" ]; then
              dir_cwd="${_bfc_cwds[$_lookup]}"
              dir_remote="${_bfc_remotes[$_lookup]}"
              break
            fi
            _lookup=$((_lookup + 1))
          done
        fi
        # Fall back to direct resolution (Strategy 2 matches)
        if [ -z "$dir_cwd" ]; then
          dir_cwd=$(get_project_cwd "$dir_name")
          dir_remote=$(get_git_remote "$dir_cwd")
          if [ -z "$dir_remote" ] && [ -n "$dir_cwd" ] && [ ! -e "$dir_cwd" ]; then
            dir_remote=$(resolve_remote_for_dead_cwd "$dir_cwd")
                fi
        fi

        # Build metadata sidecar
        if [ -n "$dir_remote" ] || [ -n "$dir_cwd" ]; then
          docker_metadata=$(echo "$docker_metadata" | jq \
            --arg dir "$dir_name" \
            --arg remote "$dir_remote" \
            --arg cwd "$dir_cwd" \
            '. + {($dir): {"git_remote": $remote, "cwd": $cwd}}' 2>/dev/null || echo "$docker_metadata")
        fi

      done

      local repository_key
      repository_key=$(repository_git_key "$cwd_remote" "$(pwd)")
      local git_session_dirs="$filtered_dir"
      if [ "${PAXEL_STORE_SESSIONS:-0}" -gt 0 ]; then
        git_session_dirs="${filtered_dir}"$'\n'"${PAXEL_STORE_STAGE_DIR}"
      fi
      collect_repository_git_data "$(pwd)" "$git_data_dir" "$repository_key" "$git_session_dirs" "$OLDEST_SESSION_EPOCH"

      # Write _metadata.json sidecar
      local _rmdc_total
      _rmdc_total=$(_rmdc_recovery_count_unique)
      if command -v jq &>/dev/null; then
        jq -n --argjson dirs "$docker_metadata" \
          --argjson recoveries "${_rmdc_total:-0}" \
          '{"version": 1, "directories": $dirs, "orphan_recovery_count": $recoveries}' \
          > "${filtered_dir}/_metadata.json"
      fi
    elif [ -n "$cwd_remote" ] \
      && { [ "${PAXEL_STORE_SESSIONS:-0}" -gt 0 ] || remote_has_agent_sessions "$cwd_remote"; }; then
      # No Claude Code history for this repo, but Codex/Cursor/opencode or the
      # transcript store have sessions here — set up a Claude-LESS filtered run
      # so they get scoped to this project and uploaded, instead of falling to
      # the "none match" prompt.
      # This makes auto-detect tool-agnostic: any tool or combination works
      # without Claude. The empty filtered_dir means no Claude transcripts;
      # run_docker_analysis still mounts it at /transcripts (0 sessions is fine),
      # extracts the agent tools filtered to selected_remote, and analyze_local
      # merges their buckets in. The cwd repo is mounted for code quality as usual.
      CLAUDE_DIR="$filtered_dir"
      CLAUDE_MOUNT_SCOPE="filtered"
      MOUNT_LABEL="$match_label"
      selected_remote="$cwd_remote"
      local repository_key
      repository_key=$(repository_git_key "$cwd_remote" "$(pwd)")
      local git_session_dirs="$filtered_dir"
      if [ "${PAXEL_STORE_SESSIONS:-0}" -gt 0 ]; then
        git_session_dirs="${filtered_dir}"$'\n'"${PAXEL_STORE_STAGE_DIR}"
      fi
      collect_repository_git_data "$(pwd)" "${filtered_dir}/_git" "$repository_key" "$git_session_dirs" "${SINCE_EPOCH:-}"
      if command -v jq >/dev/null 2>&1; then
        echo '{"version": 1, "directories": {}}' > "${filtered_dir}/_metadata.json"
      fi
      if [ "${PAXEL_STORE_SESSIONS:-0}" -gt 0 ]; then
        echo "Auto-detected project: ${match_label} (matched sessions in your transcript store; no Claude Code history on this machine)" >&2
      else
        echo "Auto-detected project: ${match_label} (matched Codex/Cursor/opencode/Gemini/VS Code Copilot sessions; no Claude Code history here)" >&2
      fi
    elif detect_child_repos; then
      # Strategy 3: parent directory with child repos that have transcript data
      rm -rf "$filtered_dir"
      show_child_repo_menu
      run_selected_child_repos
    else
      # No matches — confirm with user before processing everything
      rm -rf "$filtered_dir"
      echo "None of your sessions match this directory." >&2
      echo "  To analyze a specific project: $(rerun_cmd --project NAME)" >&2
      if [ -c /dev/tty ]; then
        echo "" >&2
        echo "Options:" >&2
        echo "  1) Analyze ALL projects" >&2
        echo "  2) Cancel" >&2
        echo "" >&2
        local choice
        user_read -rp "Choose [1-2]: " choice
        case "$choice" in
          1)
            ALL_PROJECTS=1
            if declare -F paxel_pull_stage_for_run >/dev/null 2>&1; then
              paxel_pull_stage_for_run
            fi
            ;;
          *) echo "Cancelled."; exit 0 ;;
        esac
      else
        echo "To specify what to analyze:" >&2
        echo "  $(rerun_cmd --project NAME)" >&2
        echo "  $(rerun_cmd --all)" >&2
        exit 1
      fi
    fi
  fi

  # Count sessions and show time estimate (or abort if zero)
  local claude_count
  claude_count=$(count_sessions "$CLAUDE_DIR")

  # Codex sessions split by originator: the user's mental model is "I ran
  # codex N times" (standalone), distinct from "Claude dispatched codex M
  # times" (cross-tool, looks like a subagent invocation). codex-companion
  # writes payload.originator="Claude Code" for the latter; codex_cli_rs etc.
  # for the former. Server picks up the same distinction post-link via
  # CrossToolLinker (cross_tool_origin column).
  local codex_standalone_count=0
  local codex_cross_tool_count=0
  if [ -d "$CODEX_DIR" ] && [ -z "${TRANSCRIPT_DIR:-}" ]; then
    if [ -n "${selected_remote:-}" ]; then
      # Single-project mode: count only sessions matching project remote
      # (mirrors collect_codex_sessions filter applied during extraction).
      # Keep get_codex_session_remote unchanged — it has cwd-fallback semantics
      # used by collect_codex_sessions; classify originator separately.
      local _sr_norm
      _sr_norm=$(normalize_remote "$selected_remote")
      while IFS= read -r _cf; do
        [ -z "$_cf" ] && continue
        if [ -n "$SINCE_EPOCH" ]; then
          local _fm
          _fm=$(stat -c %Y "$_cf" 2>/dev/null || stat -f %m "$_cf" 2>/dev/null || echo "0")
          [ "$_fm" -lt "$SINCE_EPOCH" ] 2>/dev/null && continue
        fi
        local _cr
        _cr=$(get_codex_session_remote "$_cf")
        [ "$_cr" != "$_sr_norm" ] && continue
        local _co
        _co=$(get_codex_session_originator "$_cf")
        if codex_originator_is_standalone "$_co"; then
          codex_standalone_count=$((codex_standalone_count + 1))
        else
          codex_cross_tool_count=$((codex_cross_tool_count + 1))
        fi
      done < <(find "$CODEX_DIR" -name "*.jsonl" -maxdepth 6 2>/dev/null)
    else
      # Orphan-cwd path: no remote to filter on, count every Codex JSONL
      # split by originator.
      while IFS= read -r _cf; do
        [ -z "$_cf" ] && continue
        local _co
        _co=$(get_codex_session_originator "$_cf")
        if codex_originator_is_standalone "$_co"; then
          codex_standalone_count=$((codex_standalone_count + 1))
        else
          codex_cross_tool_count=$((codex_cross_tool_count + 1))
        fi
      done < <(find "$CODEX_DIR" -name "*.jsonl" -maxdepth 6 2>/dev/null)
    fi
  fi

  # opencode sessions (SQLite-backed) matching this project's remote. Folded
  # into N so an opencode-only user isn't told "No sessions found".
  local opencode_count
  opencode_count=$(count_opencode_sessions "${selected_remote:-}")

  # Gemini CLI sessions matching this project's remote. Folded into N so a
  # Gemini-only user isn't told "No sessions found".
  local gemini_count
  gemini_count=$(count_gemini_sessions "${selected_remote:-}")

  # VS Code Copilot sessions matching this project's remote. Folded into N so a
  # Copilot-only user isn't told "No sessions found".
  local vscode_count
  vscode_count=$(count_vscode_copilot_sessions "${selected_remote:-}")

  # Antigravity sessions matching this project's remote. Folded into N so an
  # Antigravity-only user isn't told "No sessions found".
  local antigravity_count
  antigravity_count=$(count_antigravity_sessions "${selected_remote:-}")

  # Cross-tool Codex is folded into the subagent total below — it appears in
  # M (subagents), NOT in N (sessions). No double-count.
  local store_count="${PAXEL_STORE_SESSIONS:-0}"
  local session_count=$((claude_count + codex_standalone_count + opencode_count + gemini_count + vscode_count + antigravity_count + store_count))

  if [ "$session_count" -eq 0 ]; then
    echo ""
    echo "No sessions found in this directory."
    echo "Run from a project directory with coding agent sessions, or include all:"
    echo "  $(rerun_cmd --all)"
    paxel_skill_upload_hint "Paxel reads the agent sessions on this machine only." || true
    exit 1
  fi

  local subagent_count
  # NOTE — counts ALL subagents under $CLAUDE_DIR globally, not just this
  # project's. claude_count (line above) has the same global scope, so the
  # ratio is internally consistent for this prelude display. Project-scoping
  # requires mapping selected_remote → matched Claude project dirs (the same
  # mapping the multi-repo flow does in prepare_and_run_for_repo); deferred
  # to Phase 4 since neither subagent_count nor claude_count drive any
  # downstream gate — they're prelude display only. (Phase 3.5 callout)
  subagent_count=$(count_subagent_sessions "$CLAUDE_DIR")
  # Fold Codex-via-Claude into subagents — they look like subagent invocations
  # to the user. print_estimate displays each component on its own line so the
  # mix is legible.
  local store_subagent_count=$((${PAXEL_STORE_JSONL:-0} - store_count))
  local subagent_total=$((subagent_count + codex_cross_tool_count + store_subagent_count))

  local data_mb
  data_mb=$(get_data_size "$CLAUDE_DIR")
  ESTIMATED_MINUTES=""

  if [ -n "$PROJECT_NAME" ]; then
    echo ""
    echo "This usually takes a few minutes."
    echo ""
    echo "  ★  You'll get an email when your report is ready."
    echo ""
    ESTIMATED_MINUTES="5"
  else
    print_estimate "$session_count" "$data_mb" "$claude_count" "$codex_standalone_count" "$codex_cross_tool_count" "$match_label" "$subagent_total"
    # opencode sessions are folded into the $session_count total above; show
    # the per-tool line too so the breakdown sums (mirrors the Codex CLI line).
    [ "$opencode_count" -gt 0 ] && echo "  opencode: ${opencode_count} sessions"
    [ "$gemini_count" -gt 0 ] && echo "  Gemini CLI: ${gemini_count} sessions"
    [ "$vscode_count" -gt 0 ] && echo "  VS Code Copilot: ${vscode_count} sessions"
    [ "$store_count" -gt 0 ] && echo "  Transcript store: $(paxel_sessions_text "$store_count")"
  fi

  # Pass estimate to Docker for telemetry
  export PAXEL_HOST_ESTIMATE_MINUTES="${ESTIMATED_MINUTES:-}"

  # Set selected_remote so Cursor extraction filters by this project's remote
  selected_remote="${cwd_remote:-}"

  pull_client_image
  # The counts above include store sessions, which a cached image without
  # the store capability (a deploy window) would drop. With no other
  # sessions, stop here rather than start an empty analysis.
  if [ "${PAXEL_STORE_SESSIONS:-0}" -gt 0 ] && ! paxel_pull_image_ready "$PAXEL_CLIENT_IMAGE"; then
    paxel_pull_discard
    if [ "$session_count" -le "$store_count" ]; then
      echo ""
      echo "Every session in this run comes from your transcript store, so there is nothing to analyze until the newer image is pulled."
      exit 1
    fi
  fi
  if ! check_docker_storage; then exit 1; fi
  run_docker_analysis
}

# jq program rendered by the server from SecretScrubber::PATTERNS. Empty when
# the template is rendered outside HomeController; store push refuses then.
_paxel_scrub_program() {
  cat <<'PAXEL_SCRUB_JQ'
def _paxel_gsub($re; f): . as $in | reduce match($re; "g") as $m ({o: "", p: 0}; ($m.captures | map(select(.name != null) | {key: .name, value: .string}) | from_entries) as $c | .o += $in[.p:$m.offset] + ($c | f) | .p = $m.offset + $m.length) | .o + $in[.p:];
def paxel_scrub_string:
  _paxel_gsub("sk-ant-[A-Za-z0-9_-]{20,}"; "[REDACTED_ANTHROPIC_KEY]")
  | _paxel_gsub("(?<![A-Za-z0-9_])sk-(?:proj-|svcacct-|admin-)?[A-Za-z0-9_-]{20,}"; "[REDACTED_OPENAI_KEY]")
  | _paxel_gsub("(?<![A-Za-z0-9_])AKIA[A-Z0-9]{16,}"; "[REDACTED_AWS_ACCESS_KEY]")
  | _paxel_gsub("(?<![A-Za-z0-9_])gh[pousr]_[A-Za-z0-9_]{20,}"; "[REDACTED_GITHUB_TOKEN]")
  | _paxel_gsub("(?<![A-Za-z0-9_])AIza[A-Za-z0-9_-]{35}"; "[REDACTED_GOOGLE_API_KEY]")
  | _paxel_gsub("(?<![A-Za-z0-9_])eyJ[A-Za-z0-9_-]+\\.eyJ[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+"; "[REDACTED_JWT]")
  | _paxel_gsub("(?<![A-Za-z0-9_])[Bb]earer[\\t\\n\\x0B\\f\\r :=]+[A-Za-z0-9._\\-~+/=]{20,}"; "Bearer [REDACTED]")
  | _paxel_gsub("-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----[\\s\\S]+?-----END [A-Z0-9 ]*PRIVATE KEY-----"; "[REDACTED_PRIVATE_KEY]")
  | _paxel_gsub("(?<![A-Za-z0-9_])(?<g1>postgres(?:ql)?|redis|mongodb(?:\\+srv)?|mysql|mssql|amqps?)://[^\\t\\n\\x0B\\f\\r :@/]*:[^\\t\\n\\x0B\\f\\r @]+@[^\\t\\n\\x0B\\f\\r ]+"; "\(.g1 // "")://[REDACTED]@host")
  | _paxel_gsub("(?<![A-Za-z0-9_])(?:sk|rk)_(?:live|test)_[A-Za-z0-9]{20,}"; "[REDACTED_STRIPE_KEY]")
  | _paxel_gsub("(?<![A-Za-z0-9_])(?:xox[baprs]|xapp)-[A-Za-z0-9-]{10,}"; "[REDACTED_SLACK_TOKEN]")
  | _paxel_gsub("(?<![A-Za-z0-9_])hf_[A-Za-z0-9]{20,}"; "[REDACTED_HF_TOKEN]")
  | _paxel_gsub("(?<![A-Za-z0-9_])npm_[A-Za-z0-9]{30,}"; "[REDACTED_NPM_TOKEN]")
  | _paxel_gsub("(?<![A-Za-z0-9_])pypi-[A-Za-z0-9_-]{20,}"; "[REDACTED_PYPI_TOKEN]")
  | _paxel_gsub("(?<![A-Za-z0-9_])(?:sb_secret_[A-Za-z0-9_-]{20,}|sbp_[A-Za-z0-9]{40,})"; "[REDACTED_SUPABASE_KEY]")
  | _paxel_gsub("(?<![A-Za-z0-9_])yk_[0-9a-f]{16,}"; "[REDACTED_YC_TOKEN]")
  | _paxel_gsub("(?<![A-Za-z0-9_])(?:AC|SK)[0-9a-f]{32}(?![A-Za-z0-9_])"; "[REDACTED_TWILIO_KEY]")
  | _paxel_gsub("(?<![A-Za-z0-9_])1//0[A-Za-z0-9_-]{20,}"; "[REDACTED_GOOGLE_OAUTH]")
  | _paxel_gsub("GOCSPX-[A-Za-z0-9_-]{24,}"; "[REDACTED_GOOGLE_CLIENT_SECRET]")
  | _paxel_gsub("(?<![A-Za-z0-9_])AccountKey=[A-Za-z0-9+/=]{40,}"; "AccountKey=[REDACTED]")
  | _paxel_gsub("(?<![A-Za-z0-9_])v1\\.0-[0-9a-f]{24,}-[0-9a-f]{24,}"; "[REDACTED_CLOUDFLARE_ORIGIN_CA_KEY]")
  | _paxel_gsub("(?<![A-Za-z0-9_])cf(?:oat|at|ut|k)_[A-Za-z0-9]{20,}"; "[REDACTED_CLOUDFLARE_TOKEN]")
  | _paxel_gsub("(?i:(?<![A-Za-z0-9_])(?<g1>X-Auth-(?:Key|Email|User-Service-Key))[\\t\\n\\x0B\\f\\r ]*:[\\t\\n\\x0B\\f\\r ]*[^\\t\\n\\x0B\\f\\r \"',;]+)"; "\(.g1 // ""): [REDACTED]")
  | _paxel_gsub("(?i:(?<![A-Za-z0-9_])(?<g1>oauth_token|refresh_token)(?![A-Za-z0-9_])[\\t\\n\\x0B\\f\\r ]*[:=][\\t\\n\\x0B\\f\\r ]*[\"']?[A-Za-z0-9_~+/=-]{8,})"; "\(.g1 // "")=[REDACTED]")
  | _paxel_gsub("(?<![A-Za-z0-9_])github_pat_[A-Za-z0-9_]{22,}"; "[REDACTED_GITHUB_TOKEN]")
  | _paxel_gsub("(?<![A-Za-z0-9_])gl(?:pat|oas|rt|dt|cbt|ptt|ft|imt|agent|soat|ffct)-[A-Za-z0-9_-]{20,}"; "[REDACTED_GITLAB_TOKEN]")
  | _paxel_gsub("(?<g1>[A-Za-z][A-Za-z0-9+.-]{0,31})://(?:[^\\t\\n\\x0B\\f\\r /:@\"'<>?#\\\\]*:[^\\t\\n\\x0B\\f\\r /\"'<>?#\\\\]+|[A-Za-z0-9_-]{32,})@"; "\(.g1 // "")://[REDACTED]@")
  | _paxel_gsub("(?<g1>(?s-six:(?:(?<![A-Za-z0-9_])|(?<=\\\\[nrt]))(?=[A-Z])(?:[A-Z][A-Z0-9_]*?)?(?:SECRET|TOKEN|PASSWORD|PASSWD|CREDENTIAL|KEY)S?))(?<g2>(?s-six:(?:\\\\?[\"']\\]?)?[\\t\\n\\x0B\\f\\r ]*=>?(?![>=])[\\t\\n\\x0B\\f\\r ]*|\\\\?[\"'][\\t\\n\\x0B\\f\\r ]*:[\\t\\n\\x0B\\f\\r ]*|[\\t\\n\\x0B\\f\\r ]*:[\\t\\n\\x0B\\f\\r ]+))(?<g3>\\\\?[\"'])(?!\\[REDACTED|\\./\\k<g3>)(?:(?!\\k<g3>)(?:\\\\.|[^\\n\\\\]))+\\k<g3>"; "\(.g1 // "")\(.g2 // "")\(.g3 // "")[REDACTED]\(.g3 // "")")
  | _paxel_gsub("-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----(?=(?:[\\t\\n\\x0B\\f\\r ]|\\\\+[rnt])+(?:[A-Za-z0-9+/=]{16}|Proc-Type:))(?:(?:[\\t\\n\\x0B\\f\\r ]|\\\\+[rnt])+(?:Proc-Type|DEK-Info):[^\\r\\n\\\\]*)*(?:(?:[\\t\\n\\x0B\\f\\r ]|\\\\+[rnt])+[A-Za-z0-9+/=]{16}[A-Za-z0-9+/=]*(?s-six:(?:(?s-six:(?:[ \\t]|\\\\+t)*(?:\\r?\\n|(?:\\\\+r)?\\\\+n)(?:[ \\t]|\\\\+t)*)[A-Za-z0-9+\\/=]{16}[A-Za-z0-9+\\/=]*(?=[ \\t]*(?![^\"'\\\\\\r\\n])))*(?:(?s-six:(?:[ \\t]|\\\\+t)*(?:\\r?\\n|(?:\\\\+r)?\\\\+n)(?:[ \\t]|\\\\+t)*)[A-Za-z0-9+\\/=]+(?=(?:[ \\t]|\\\\+t)*\\\\*(?![^\"'])))?))?"; "[REDACTED_PRIVATE_KEY]")
  | _paxel_gsub("(?:(?<![A-Za-z0-9+/=\\\\])|(?<=\\\\[nrt]))(?=[A-Za-z0-9+/=])(?>(?:[A-Za-z0-9+/=]{64}(?:[A-Za-z0-9+/=]{6})?(?s-six:(?:[ \\t]|\\\\+t)*(?:\\r?\\n|(?:\\\\+r)?\\\\+n)(?:[ \\t]|\\\\+t)*)){0,63})(?:(?>[A-Za-z0-9+/=]+)(?s-six:(?:[ \\t]|\\\\+t)*(?:\\r?\\n|(?:\\\\+r)?\\\\+n)(?:[ \\t]|\\\\+t)*))?-----END [A-Z0-9 ]*PRIVATE KEY-----"; "[REDACTED_PRIVATE_KEY]")
  | _paxel_gsub("(?<g1>(?s-six:(?:(?<![A-Za-z0-9_])|(?<=\\\\[nrt]))(?=[A-Z])(?:[A-Z][A-Z0-9_]*?)?(?:SECRET|TOKEN|PASSWORD|PASSWD|CREDENTIAL|KEY)S?))(?<g2>(?s-six:(?:\\\\?[\"']\\]?)?[\\t\\n\\x0B\\f\\r ]*=>?(?![>=])[\\t\\n\\x0B\\f\\r ]*|\\\\?[\"'][\\t\\n\\x0B\\f\\r ]*:[\\t\\n\\x0B\\f\\r ]*|[\\t\\n\\x0B\\f\\r ]*:[\\t\\n\\x0B\\f\\r ]+))(?!\\[REDACTED)`?(?s-six:(?:[^\\t\\n\\x0B\\f\\r \"'`\\\\,;.]|\\\\(?![\\\\\"'nrtu]))+)(?:\\.(?s-six:(?:[^\\t\\n\\x0B\\f\\r \"'`\\\\,;.]|\\\\(?![\\\\\"'nrtu]))+))*"; "\(.g1 // "")\(.g2 // "")[REDACTED]")
  ;
def _paxel_has_match: test("(?:sk-ant-[A-Za-z0-9_-]{20,})|(?:(?<![A-Za-z0-9_])sk-(?:proj-|svcacct-|admin-)?[A-Za-z0-9_-]{20,})|(?:(?<![A-Za-z0-9_])AKIA[A-Z0-9]{16,})|(?:(?<![A-Za-z0-9_])gh[pousr]_[A-Za-z0-9_]{20,})|(?:(?<![A-Za-z0-9_])AIza[A-Za-z0-9_-]{35})|(?:(?<![A-Za-z0-9_])eyJ[A-Za-z0-9_-]+\\.eyJ[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+)|(?:(?<![A-Za-z0-9_])[Bb]earer[\\t\\n\\x0B\\f\\r :=]+[A-Za-z0-9._\\-~+/=]{20,})|(?:-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----[\\s\\S]+?-----END [A-Z0-9 ]*PRIVATE KEY-----)|(?:(?<![A-Za-z0-9_])(?<p8g1>postgres(?:ql)?|redis|mongodb(?:\\+srv)?|mysql|mssql|amqps?)://[^\\t\\n\\x0B\\f\\r :@/]*:[^\\t\\n\\x0B\\f\\r @]+@[^\\t\\n\\x0B\\f\\r ]+)|(?:(?<![A-Za-z0-9_])(?:sk|rk)_(?:live|test)_[A-Za-z0-9]{20,})|(?:(?<![A-Za-z0-9_])(?:xox[baprs]|xapp)-[A-Za-z0-9-]{10,})|(?:(?<![A-Za-z0-9_])hf_[A-Za-z0-9]{20,})|(?:(?<![A-Za-z0-9_])npm_[A-Za-z0-9]{30,})|(?:(?<![A-Za-z0-9_])pypi-[A-Za-z0-9_-]{20,})|(?:(?<![A-Za-z0-9_])(?:sb_secret_[A-Za-z0-9_-]{20,}|sbp_[A-Za-z0-9]{40,}))|(?:(?<![A-Za-z0-9_])yk_[0-9a-f]{16,})|(?:(?<![A-Za-z0-9_])(?:AC|SK)[0-9a-f]{32}(?![A-Za-z0-9_]))|(?:(?<![A-Za-z0-9_])1//0[A-Za-z0-9_-]{20,})|(?:GOCSPX-[A-Za-z0-9_-]{24,})|(?:(?<![A-Za-z0-9_])AccountKey=[A-Za-z0-9+/=]{40,})|(?:(?<![A-Za-z0-9_])v1\\.0-[0-9a-f]{24,}-[0-9a-f]{24,})|(?:(?<![A-Za-z0-9_])cf(?:oat|at|ut|k)_[A-Za-z0-9]{20,})|(?:(?i:(?<![A-Za-z0-9_])(?<p22g1>X-Auth-(?:Key|Email|User-Service-Key))[\\t\\n\\x0B\\f\\r ]*:[\\t\\n\\x0B\\f\\r ]*[^\\t\\n\\x0B\\f\\r \"',;]+))|(?:(?i:(?<![A-Za-z0-9_])(?<p23g1>oauth_token|refresh_token)(?![A-Za-z0-9_])[\\t\\n\\x0B\\f\\r ]*[:=][\\t\\n\\x0B\\f\\r ]*[\"']?[A-Za-z0-9_~+/=-]{8,}))|(?:(?<![A-Za-z0-9_])github_pat_[A-Za-z0-9_]{22,})|(?:(?<![A-Za-z0-9_])gl(?:pat|oas|rt|dt|cbt|ptt|ft|imt|agent|soat|ffct)-[A-Za-z0-9_-]{20,})|(?:(?<p26g1>[A-Za-z][A-Za-z0-9+.-]{0,31})://(?:[^\\t\\n\\x0B\\f\\r /:@\"'<>?#\\\\]*:[^\\t\\n\\x0B\\f\\r /\"'<>?#\\\\]+|[A-Za-z0-9_-]{32,})@)|(?:(?<p27g1>(?s-six:(?:(?<![A-Za-z0-9_])|(?<=\\\\[nrt]))(?=[A-Z])(?:[A-Z][A-Z0-9_]*?)?(?:SECRET|TOKEN|PASSWORD|PASSWD|CREDENTIAL|KEY)S?))(?<p27g2>(?s-six:(?:\\\\?[\"']\\]?)?[\\t\\n\\x0B\\f\\r ]*=>?(?![>=])[\\t\\n\\x0B\\f\\r ]*|\\\\?[\"'][\\t\\n\\x0B\\f\\r ]*:[\\t\\n\\x0B\\f\\r ]*|[\\t\\n\\x0B\\f\\r ]*:[\\t\\n\\x0B\\f\\r ]+))(?<p27g3>\\\\?[\"'])(?!\\[REDACTED|\\./\\k<p27g3>)(?:(?!\\k<p27g3>)(?:\\\\.|[^\\n\\\\]))+\\k<p27g3>)|(?:-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----(?=(?:[\\t\\n\\x0B\\f\\r ]|\\\\+[rnt])+(?:[A-Za-z0-9+/=]{16}|Proc-Type:))(?:(?:[\\t\\n\\x0B\\f\\r ]|\\\\+[rnt])+(?:Proc-Type|DEK-Info):[^\\r\\n\\\\]*)*(?:(?:[\\t\\n\\x0B\\f\\r ]|\\\\+[rnt])+[A-Za-z0-9+/=]{16}[A-Za-z0-9+/=]*(?s-six:(?:(?s-six:(?:[ \\t]|\\\\+t)*(?:\\r?\\n|(?:\\\\+r)?\\\\+n)(?:[ \\t]|\\\\+t)*)[A-Za-z0-9+\\/=]{16}[A-Za-z0-9+\\/=]*(?=[ \\t]*(?![^\"'\\\\\\r\\n])))*(?:(?s-six:(?:[ \\t]|\\\\+t)*(?:\\r?\\n|(?:\\\\+r)?\\\\+n)(?:[ \\t]|\\\\+t)*)[A-Za-z0-9+\\/=]+(?=(?:[ \\t]|\\\\+t)*\\\\*(?![^\"'])))?))?)|(?:(?:(?<![A-Za-z0-9+/=\\\\])|(?<=\\\\[nrt]))(?=[A-Za-z0-9+/=])(?>(?:[A-Za-z0-9+/=]{64}(?:[A-Za-z0-9+/=]{6})?(?s-six:(?:[ \\t]|\\\\+t)*(?:\\r?\\n|(?:\\\\+r)?\\\\+n)(?:[ \\t]|\\\\+t)*)){0,63})(?:(?>[A-Za-z0-9+/=]+)(?s-six:(?:[ \\t]|\\\\+t)*(?:\\r?\\n|(?:\\\\+r)?\\\\+n)(?:[ \\t]|\\\\+t)*))?-----END [A-Z0-9 ]*PRIVATE KEY-----)|(?:(?<p30g1>(?s-six:(?:(?<![A-Za-z0-9_])|(?<=\\\\[nrt]))(?=[A-Z])(?:[A-Z][A-Z0-9_]*?)?(?:SECRET|TOKEN|PASSWORD|PASSWD|CREDENTIAL|KEY)S?))(?<p30g2>(?s-six:(?:\\\\?[\"']\\]?)?[\\t\\n\\x0B\\f\\r ]*=>?(?![>=])[\\t\\n\\x0B\\f\\r ]*|\\\\?[\"'][\\t\\n\\x0B\\f\\r ]*:[\\t\\n\\x0B\\f\\r ]*|[\\t\\n\\x0B\\f\\r ]*:[\\t\\n\\x0B\\f\\r ]+))(?!\\[REDACTED)`?(?s-six:(?:[^\\t\\n\\x0B\\f\\r \"'`\\\\,;.]|\\\\(?![\\\\\"'nrtu]))+)(?:\\.(?s-six:(?:[^\\t\\n\\x0B\\f\\r \"'`\\\\,;.]|\\\\(?![\\\\\"'nrtu]))+))*)");
def _paxel_has_match_each: test("(?:sk-ant-[A-Za-z0-9_-]{20,})") or test("(?:(?<![A-Za-z0-9_])sk-(?:proj-|svcacct-|admin-)?[A-Za-z0-9_-]{20,})") or test("(?:(?<![A-Za-z0-9_])AKIA[A-Z0-9]{16,})") or test("(?:(?<![A-Za-z0-9_])gh[pousr]_[A-Za-z0-9_]{20,})") or test("(?:(?<![A-Za-z0-9_])AIza[A-Za-z0-9_-]{35})") or test("(?:(?<![A-Za-z0-9_])eyJ[A-Za-z0-9_-]+\\.eyJ[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+)") or test("(?:(?<![A-Za-z0-9_])[Bb]earer[\\t\\n\\x0B\\f\\r :=]+[A-Za-z0-9._\\-~+/=]{20,})") or test("(?:-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----[\\s\\S]+?-----END [A-Z0-9 ]*PRIVATE KEY-----)") or test("(?:(?<![A-Za-z0-9_])(?<p8g1>postgres(?:ql)?|redis|mongodb(?:\\+srv)?|mysql|mssql|amqps?)://[^\\t\\n\\x0B\\f\\r :@/]*:[^\\t\\n\\x0B\\f\\r @]+@[^\\t\\n\\x0B\\f\\r ]+)") or test("(?:(?<![A-Za-z0-9_])(?:sk|rk)_(?:live|test)_[A-Za-z0-9]{20,})") or test("(?:(?<![A-Za-z0-9_])(?:xox[baprs]|xapp)-[A-Za-z0-9-]{10,})") or test("(?:(?<![A-Za-z0-9_])hf_[A-Za-z0-9]{20,})") or test("(?:(?<![A-Za-z0-9_])npm_[A-Za-z0-9]{30,})") or test("(?:(?<![A-Za-z0-9_])pypi-[A-Za-z0-9_-]{20,})") or test("(?:(?<![A-Za-z0-9_])(?:sb_secret_[A-Za-z0-9_-]{20,}|sbp_[A-Za-z0-9]{40,}))") or test("(?:(?<![A-Za-z0-9_])yk_[0-9a-f]{16,})") or test("(?:(?<![A-Za-z0-9_])(?:AC|SK)[0-9a-f]{32}(?![A-Za-z0-9_]))") or test("(?:(?<![A-Za-z0-9_])1//0[A-Za-z0-9_-]{20,})") or test("(?:GOCSPX-[A-Za-z0-9_-]{24,})") or test("(?:(?<![A-Za-z0-9_])AccountKey=[A-Za-z0-9+/=]{40,})") or test("(?:(?<![A-Za-z0-9_])v1\\.0-[0-9a-f]{24,}-[0-9a-f]{24,})") or test("(?:(?<![A-Za-z0-9_])cf(?:oat|at|ut|k)_[A-Za-z0-9]{20,})") or test("(?:(?i:(?<![A-Za-z0-9_])(?<p22g1>X-Auth-(?:Key|Email|User-Service-Key))[\\t\\n\\x0B\\f\\r ]*:[\\t\\n\\x0B\\f\\r ]*[^\\t\\n\\x0B\\f\\r \"',;]+))") or test("(?:(?i:(?<![A-Za-z0-9_])(?<p23g1>oauth_token|refresh_token)(?![A-Za-z0-9_])[\\t\\n\\x0B\\f\\r ]*[:=][\\t\\n\\x0B\\f\\r ]*[\"']?[A-Za-z0-9_~+/=-]{8,}))") or test("(?:(?<![A-Za-z0-9_])github_pat_[A-Za-z0-9_]{22,})") or test("(?:(?<![A-Za-z0-9_])gl(?:pat|oas|rt|dt|cbt|ptt|ft|imt|agent|soat|ffct)-[A-Za-z0-9_-]{20,})") or test("(?:(?<p26g1>[A-Za-z][A-Za-z0-9+.-]{0,31})://(?:[^\\t\\n\\x0B\\f\\r /:@\"'<>?#\\\\]*:[^\\t\\n\\x0B\\f\\r /\"'<>?#\\\\]+|[A-Za-z0-9_-]{32,})@)") or test("(?:(?<p27g1>(?s-six:(?:(?<![A-Za-z0-9_])|(?<=\\\\[nrt]))(?=[A-Z])(?:[A-Z][A-Z0-9_]*?)?(?:SECRET|TOKEN|PASSWORD|PASSWD|CREDENTIAL|KEY)S?))(?<p27g2>(?s-six:(?:\\\\?[\"']\\]?)?[\\t\\n\\x0B\\f\\r ]*=>?(?![>=])[\\t\\n\\x0B\\f\\r ]*|\\\\?[\"'][\\t\\n\\x0B\\f\\r ]*:[\\t\\n\\x0B\\f\\r ]*|[\\t\\n\\x0B\\f\\r ]*:[\\t\\n\\x0B\\f\\r ]+))(?<p27g3>\\\\?[\"'])(?!\\[REDACTED|\\./\\k<p27g3>)(?:(?!\\k<p27g3>)(?:\\\\.|[^\\n\\\\]))+\\k<p27g3>)") or test("(?:-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----(?=(?:[\\t\\n\\x0B\\f\\r ]|\\\\+[rnt])+(?:[A-Za-z0-9+/=]{16}|Proc-Type:))(?:(?:[\\t\\n\\x0B\\f\\r ]|\\\\+[rnt])+(?:Proc-Type|DEK-Info):[^\\r\\n\\\\]*)*(?:(?:[\\t\\n\\x0B\\f\\r ]|\\\\+[rnt])+[A-Za-z0-9+/=]{16}[A-Za-z0-9+/=]*(?s-six:(?:(?s-six:(?:[ \\t]|\\\\+t)*(?:\\r?\\n|(?:\\\\+r)?\\\\+n)(?:[ \\t]|\\\\+t)*)[A-Za-z0-9+\\/=]{16}[A-Za-z0-9+\\/=]*(?=[ \\t]*(?![^\"'\\\\\\r\\n])))*(?:(?s-six:(?:[ \\t]|\\\\+t)*(?:\\r?\\n|(?:\\\\+r)?\\\\+n)(?:[ \\t]|\\\\+t)*)[A-Za-z0-9+\\/=]+(?=(?:[ \\t]|\\\\+t)*\\\\*(?![^\"'])))?))?)") or test("(?:(?:(?<![A-Za-z0-9+/=\\\\])|(?<=\\\\[nrt]))(?=[A-Za-z0-9+/=])(?>(?:[A-Za-z0-9+/=]{64}(?:[A-Za-z0-9+/=]{6})?(?s-six:(?:[ \\t]|\\\\+t)*(?:\\r?\\n|(?:\\\\+r)?\\\\+n)(?:[ \\t]|\\\\+t)*)){0,63})(?:(?>[A-Za-z0-9+/=]+)(?s-six:(?:[ \\t]|\\\\+t)*(?:\\r?\\n|(?:\\\\+r)?\\\\+n)(?:[ \\t]|\\\\+t)*))?-----END [A-Z0-9 ]*PRIVATE KEY-----)") or test("(?:(?<p30g1>(?s-six:(?:(?<![A-Za-z0-9_])|(?<=\\\\[nrt]))(?=[A-Z])(?:[A-Z][A-Z0-9_]*?)?(?:SECRET|TOKEN|PASSWORD|PASSWD|CREDENTIAL|KEY)S?))(?<p30g2>(?s-six:(?:\\\\?[\"']\\]?)?[\\t\\n\\x0B\\f\\r ]*=>?(?![>=])[\\t\\n\\x0B\\f\\r ]*|\\\\?[\"'][\\t\\n\\x0B\\f\\r ]*:[\\t\\n\\x0B\\f\\r ]*|[\\t\\n\\x0B\\f\\r ]*:[\\t\\n\\x0B\\f\\r ]+))(?!\\[REDACTED)`?(?s-six:(?:[^\\t\\n\\x0B\\f\\r \"'`\\\\,;.]|\\\\(?![\\\\\"'nrtu]))+)(?:\\.(?s-six:(?:[^\\t\\n\\x0B\\f\\r \"'`\\\\,;.]|\\\\(?![\\\\\"'nrtu]))+))*)");
def paxel_walk(f): def w: if type == "object" then reduce to_entries[] as $e ({}; . + {($e.key | f): ($e.value | w)}) elif type == "array" then map(w) else . end | f; w;
def _paxel_line_has_match: [.. | strings, (objects | keys_unsorted[])] | any(.[] | select(length > 65536); _paxel_has_match_each) or (map(select(length <= 65536) | . + "\n") | add // "" | _paxel_has_match);
def paxel_scrub_lines: inputs | [try fromjson catch empty] | if length == 1 then .[0] | if _paxel_line_has_match then paxel_walk(if type == "string" then paxel_scrub_string else . end) else . end else empty end;
def paxel_scrub_text_lines: inputs | paxel_scrub_string;
def _paxel_image_removed: "[image removed]";
def _paxel_generated_image: .type == "image_generation_call" or .type == "image_generation_end";
def _paxel_drop_image: if type == "string" then (if test("\\Adata:image/[^,;]*(?:;[^,;]*)*;base64,[A-Za-z0-9+/=]++\\z") then _paxel_image_removed else . end) elif _paxel_generated_image then (if (.result | type) == "string" and .result != "" then .result = _paxel_image_removed else . end) elif (.source | type) == "object" and .source.type == "base64" and (.source.data | type) == "string" then .source.data = _paxel_image_removed elif (.file | type) == "object" and (.file.base64 | type) == "string" then .file.base64 = _paxel_image_removed else . end;
def paxel_drop_images: reduce path(.. | select(if type == "object" then .type == "image" or _paxel_generated_image elif type == "string" then startswith("data:image/") else false end)) as $p (.; setpath($p; getpath($p) | _paxel_drop_image));
def paxel_scrub_lines_without_images: inputs | . as $raw | [try fromjson catch empty] | if length == 1 then .[0] | if ($raw | contains("\"image") or contains("data:image/")) then paxel_drop_images else . end | if _paxel_line_has_match then paxel_walk(if type == "string" then paxel_scrub_string else . end) else . end else empty end;
# paxel-scrub patterns=31 digest=f7000ab6009b
PAXEL_SCRUB_JQ
}

# --- Paxel transcript store: shared helpers (setup, push, status, upload) ---

PAXEL_STORE_SCHEMA_VERSION=1
PAXEL_HOME_DIR="${HOME}/.paxel"
PAXEL_CONFIG_FILE="${PAXEL_HOME_DIR}/config"
PAXEL_STORE_GIT_TIMEOUT="${PAXEL_STORE_GIT_TIMEOUT:-300}"

# ~/.paxel/config holds one key=value per line. It is read with sed and never
# sourced, so a hostile value cannot run code. A symlinked config is ignored:
# root setting up another account would otherwise copy whatever file it
# points at into a config that account then owns.
paxel_config_get() {
  local key="$1"
  [ -f "$PAXEL_CONFIG_FILE" ] && [ ! -L "$PAXEL_CONFIG_FILE" ] || return 0
  sed -n "s/^${key}=//p" "$PAXEL_CONFIG_FILE" | tail -n 1
}

paxel_config_set() {
  local key="$1" value="$2" tmp
  case "$key" in ''|*[!a-z0-9_]*) return 1 ;; esac
  case "$value" in *$'\n'*) return 1 ;; esac
  # mkdir, chmod and mv follow a linked ~/.paxel or config.
  [ ! -L "$PAXEL_HOME_DIR" ] && [ ! -L "$PAXEL_CONFIG_FILE" ] || return 1
  mkdir -p "$PAXEL_HOME_DIR"
  chmod 700 "$PAXEL_HOME_DIR" 2>/dev/null || true
  # mktemp, not a pid name: root setting up another account writes here, and
  # that account could plant a symlink at a name it can guess.
  tmp=$(mktemp "${PAXEL_CONFIG_FILE}.tmp.XXXXXX" || exit $?) || return 1
  {
    if [ -f "$PAXEL_CONFIG_FILE" ]; then grep -v "^${key}=" "$PAXEL_CONFIG_FILE" || true; fi
    printf '%s=%s\n' "$key" "$value"
  } > "$tmp"
  chmod 600 "$tmp"
  mv "$tmp" "$PAXEL_CONFIG_FILE"
}

paxel_now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
paxel_now_epoch() { date +%s; }
paxel_epoch_iso() {
  date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null
}

# A time paxel_now_iso wrote, as an epoch; status 1 for anything else.
paxel_iso_epoch() {
  local e t
  case "${1:-}" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) ;;
    *) return 1 ;;
  esac
  t="${1#*T}"
  # busybox date (Alpine) reads "YYYY-MM-DD hh:mm:ss" but not the T and Z form.
  e=$(date -u -d "${1%%T*} ${t%Z}" +%s 2>/dev/null ||
    date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%s 2>/dev/null || exit $?) || return 1
  paxel_is_uint "$e" || return 1
  printf '%s\n' "$e"
}

paxel_is_uint() {
  case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac
  return 0
}

# Names from the store (tool, session id, file name, box id) end up in paths.
paxel_valid_name() {
  case "${1:-}" in ''|.|..|*[!A-Za-z0-9._-]*) return 1 ;; esac
  return 0
}

# Store values must never reach bash arithmetic or [[ ]] comparisons as raw
# strings: `(( v ))` on "a[$(cmd)]" runs cmd. These getters let jq type-check
# first, and print nothing (status 1) for anything else.
#
# `|| exit $?` sits inside each substitution: bash 3.2 runs the inherited ERR
# trap in the subshell when its last command fails, even when the caller
# handles the status.
paxel_json_int() {
  local file="$1" filter="$2" out
  out=$(jq -r "(${filter}) | if type == \"number\" and . == floor and . >= 0 then tostring else empty end" "$file" 2>/dev/null || exit $?) || return 1
  # jq 1.7 keeps integer literals past int64; bash would wrap or refuse them.
  paxel_is_uint "$out" && [ "${#out}" -le 18 ] || return 1
  printf '%s\n' "$out"
}

# REGEX is an Oniguruma pattern anchored with \A and \z: jq's `$` also
# matches before a final newline.
paxel_json_str() {
  local file="$1" filter="$2" regex="$3" out
  out=$(jq -r --arg re "$regex" "(${filter}) | if type == \"string\" and test(\$re) then . else empty end" "$file" 2>/dev/null || exit $?) || return 1
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
}

# BIN is jq 1.6 or later built with regex support, which the scrub needs.
# Neither call may read stdin: under curl | bash it is the rest of the script.
paxel_jq_usable() {
  local v rest major minor
  v=$("$1" --version 2>/dev/null </dev/null) || return 1
  rest="${v#jq-}"
  major="${rest%%.*}"
  rest="${rest#*.}"
  minor="${rest%%[!0-9]*}"
  paxel_is_uint "$major" && paxel_is_uint "$minor" || return 1
  [ "$major" -gt 1 ] || { [ "$major" -eq 1 ] && [ "$minor" -ge 6 ]; } || return 1
  "$1" -n '"a" | test("a")' >/dev/null 2>&1 </dev/null
}

# When the jq on PATH cannot run the scrub, puts a folder with one that can
# first on PATH, so every jq call takes it, through timeout and env too:
# ~/.paxel/bin, where setup installs the official jq, else a tool folder
# setup saved, which the launcher adds only after the agents' own PATH.
paxel_use_own_jq() {
  local own="$PAXEL_HOME_DIR/bin" d
  if paxel_jq_usable jq; then return 0; fi
  while IFS= read -r d; do
    case "$d" in /*) ;; *) continue ;; esac
    [ "$d" != "$own" ] || [ ! -L "$d/jq" ] || continue
    if [ -f "$d/jq" ] && paxel_jq_usable "$d/jq"; then
      PATH="$d:$PATH"
      export PATH
      return 0
    fi
  done <<PAXEL_JQ_DIRS
$own
$(paxel_config_get tool_path | tr ':' '\n')
PAXEL_JQ_DIRS
}

paxel_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | cut -d' ' -f1
  else
    shasum -a 256 | cut -d' ' -f1
  fi
}

# Derived on every run, never stored: boxes cloned from one image, or sharing
# a network home, must not share an id. Containers made from one image share
# a machine id, and a host name taken from a private IP comes back on a later
# box, so the container and the cloud instance are part of the fingerprint.
paxel_box_id() {
  local mid="" host
  if [ -r /etc/machine-id ]; then mid=$(cat /etc/machine-id 2>/dev/null || true); fi
  if [ -z "$mid" ] && [ -r /var/lib/dbus/machine-id ]; then mid=$(cat /var/lib/dbus/machine-id 2>/dev/null || true); fi
  if [ -z "$mid" ] && command -v ioreg >/dev/null 2>&1; then
    mid=$(ioreg -rd1 -c IOPlatformExpertDevice 2>/dev/null | awk -F'"' '/IOPlatformUUID/ {print $4}' || true)
  fi
  host=$(hostname 2>/dev/null || uname -n)
  printf 'b-%s\n' "$(printf '%s|%s|%s|%s' "$mid" "$host" "$(_paxel_box_container_id)" "$(_paxel_box_instance_id)" \
    | paxel_sha256 | cut -c1-12)"
}

# Docker, Podman and Kubernetes bind-mount /etc/hostname from a folder named
# after the container or pod, so its source path names this container. Empty
# outside a container.
_paxel_box_container_id() {
  awk '$5 == "/etc/hostname" { print $4; exit }' "${1:-/proc/self/mountinfo}" 2>/dev/null || true
}

# The cloud instance id: cloud-init's record, else the EC2 Nitro asset tag.
# Both are readable without root, so root and the agents' account agree.
_paxel_box_instance_id() {
  local id=""
  if [ -r "${1:-/var/lib/cloud/data/instance-id}" ]; then
    id=$(head -n 1 "${1:-/var/lib/cloud/data/instance-id}" 2>/dev/null || true)
  fi
  case "$id" in *[!A-Za-z0-9._-]*) id="" ;; esac
  if [ -z "$id" ] && [ -r "${2:-/sys/class/dmi/id/board_asset_tag}" ]; then
    id=$(head -n 1 "${2:-/sys/class/dmi/id/board_asset_tag}" 2>/dev/null || true)
    case "$id" in i-*) ;; *) id="" ;; esac
    case "$id" in *[!a-z0-9-]*) id="" ;; esac
  fi
  printf '%s\n' "$id"
}

PAXEL_SSH_BATCH_OPTS="-o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=15 -o ServerAliveCountMax=4"

# Every store git call: no repo hooks, no signing prompt, no credential prompt,
# no tracing (it would log auth headers), bounded run time. A push's time
# limit grows with its size, so ssh keepalives and git's https low-speed limit
# end a dead connection within about a minute instead.
# _PAXEL_GIT_BOX_AUTH=1 (no gh or glab login) lets git use this machine's own
# login too, next to the credential helpers and SSH agent git always keeps:
# Coder's GIT_ASKPASS (the agent's coder binary; an editor's askpass asks the
# user in its window), and an inherited GIT_SSH_COMMAND that is ssh or
# Coder's "coder gitssh --", with Paxel's ssh options after it. Any other ssh
# command could prompt, so Paxel's ssh replaces it, as it does one that sets
# BatchMode: ssh keeps the first value an option gets.
paxel_git() {
  local askpass=/bin/false ssh_cmd="${PAXEL_GIT_SSH_COMMAND:-ssh $PAXEL_SSH_BATCH_OPTS${_PAXEL_SSH_OPTS:-}}"
  if [ "${_PAXEL_GIT_BOX_AUTH:-}" = 1 ]; then
    case "${GIT_ASKPASS:-}" in coder|*/coder) askpass="$GIT_ASKPASS" ;; esac
    case "${GIT_SSH_COMMAND:-}" in
      *[Bb][Aa][Tt][Cc][Hh][Mm][Oo][Dd][Ee]*) ;;
      ssh|*/ssh|"ssh "*|*"/ssh "*|*" gitssh --")
        [ -n "${PAXEL_GIT_SSH_COMMAND:-}" ] || ssh_cmd="$GIT_SSH_COMMAND $PAXEL_SSH_BATCH_OPTS${_PAXEL_SSH_OPTS:-}"
        ;;
    esac
  fi
  _run_with_timeout "$PAXEL_STORE_GIT_TIMEOUT" \
    env -u GIT_TRACE -u GIT_TRACE_CURL -u GIT_CURL_VERBOSE -u GIT_TRACE_PACKET \
    GIT_TERMINAL_PROMPT=0 GIT_ASKPASS="$askpass" SSH_ASKPASS=/bin/false GIT_SSH_COMMAND="$ssh_cmd" \
    git -c core.hooksPath=/dev/null -c commit.gpgsign=false -c tag.gpgsign=false \
    -c http.lowSpeedLimit=1024 -c http.lowSpeedTime=60 "$@"
}

# Push and setup logs: counts, durations and error classes only. Never URLs,
# tokens or transcript content.
paxel_log() {
  local dir="${PAXEL_HOME_DIR}/logs" file
  # mkdir and >> follow links, and root setup appends here for another account.
  [ ! -L "$PAXEL_HOME_DIR" ] && [ ! -L "$dir" ] || return 0
  mkdir -p "$dir" 2>/dev/null || return 0
  file="${dir}/push-$(date -u +%Y%m%d).log"
  [ ! -L "$file" ] || return 0
  printf '%s %s\n' "$(paxel_now_iso)" "$*" >> "$file" 2>/dev/null || true
}

paxel_say() { printf '%s\n' "$*" >&2; }

# --- Paxel transcript store: credential scrub (push, dev archive) ---
#
# Runs the jq program the server renders from SecretScrubber::PATTERNS
# (`_paxel_scrub_program`) on parsed JSON values, so a pattern can span a
# newline inside a value and every output line stays valid JSON.

# Caps jq's data size, so a runaway scrub fails instead of driving the box
# into the OOM killer. Not `ulimit -v`: an address-space cap crashes Go
# launchers such as snap's jq.
_PAXEL_SCRUB_MAX_DATA_KB=2097152

# The program ends with a `#` trailer comment, so EXPR goes on its own line.
_paxel_scrub_filter() {
  printf '%s\n%s\n' "$(_paxel_scrub_program)" "$1"
}

_paxel_scrub_jq() {
  (
    ulimit -d "$_PAXEL_SCRUB_MAX_DATA_KB" 2>/dev/null || true
    _run_with_timeout "${PAXEL_SCRUB_TIMEOUT:-600}" jq "$@"
  )
}

_paxel_scrub_trailer() {
  local program trailer
  program=$(_paxel_scrub_program 2>/dev/null || true)
  trailer="${program##*$'\n'}"
  case "$trailer" in
    "# paxel-scrub patterns="*" digest="*) printf '%s\n' "$trailer" ;;
    *) return 1 ;;
  esac
}

paxel_scrub_ready() {
  local version rest major minor probe
  if ! _paxel_scrub_trailer >/dev/null; then
    paxel_say "The credential scrub program is missing from this script. Download the script again."
    return 1
  fi
  if ! command -v jq >/dev/null 2>&1; then
    paxel_say "jq is not installed. Install jq 1.6 or later."
    return 1
  fi
  version=$(jq --version 2>/dev/null || true)
  rest="${version#jq-}"
  major="${rest%%.*}"
  rest="${rest#*.}"
  minor="${rest%%[!0-9]*}"
  if paxel_is_uint "$major" && paxel_is_uint "$minor"; then
    if [ "$major" -lt 1 ] || { [ "$major" -eq 1 ] && [ "$minor" -lt 6 ]; }; then
      paxel_say "jq ${major}.${minor} is too old for the credential scrub. Install jq 1.6 or later."
      return 1
    fi
  fi
  # Reads no input (a jq wrapper may drain stdin): with no lines, the line
  # drivers only prove they compile.
  probe=$(jq -n "$(_paxel_scrub_filter '[paxel_scrub_lines, paxel_scrub_lines_without_images] as $none | {"a": ["x"]} | select(tojson | _paxel_has_match | not) | paxel_walk(if type == "string" then paxel_scrub_string else . end) | .a[0]')" < /dev/null 2>/dev/null || true)
  if [ "$probe" != '"x"' ]; then
    paxel_say "jq cannot run the credential scrub program. It needs jq 1.6 or later built with regex support."
    return 1
  fi
}

paxel_scrub_digest() {
  local trailer digest
  trailer=$(_paxel_scrub_trailer || exit $?) || return 1
  digest="${trailer##* digest=}"
  case "$digest" in ''|*[!0-9a-z]*) return 1 ;; esac
  printf 'jq1:%s\n' "$digest"
}

# Scrubs the complete lines in bytes [START, END) of IN_FILE and appends them
# to OUT_FILE. END must sit just after a newline. DRIVER is the program's line
# driver: paxel_scrub_lines (the default) or paxel_scrub_lines_without_images.
# Prints the number of lines dropped as unparseable. On failure OUT_FILE keeps
# its previous content, and the message ends with "reason=WORD)." for the push
# log.
paxel_scrub_range() {
  local in="$1" start="$2" end="$3" out="$4" driver="${5:-paxel_scrub_lines}" work rc=0
  # Over 18 digits would overflow bash arithmetic.
  if ! paxel_is_uint "$start" || ! paxel_is_uint "$end" || [ "${#start}" -gt 18 ] || [ "${#end}" -gt 18 ]; then
    paxel_say "Scrub: invalid byte range (reason=bad_range)."
    return 2
  fi
  # A leading zero would otherwise read as octal.
  start=$((10#$start))
  end=$((10#$end))
  if [ "$start" -gt "$end" ]; then
    paxel_say "Scrub: invalid byte range (reason=bad_range)."
    return 2
  fi
  if [ "$start" -eq "$end" ]; then
    printf '0\n'
    return 0
  fi
  # The unscrubbed copy of the range goes in a private folder, never next to
  # OUT_FILE, which may sit in a tree that gets committed.
  if ! work=$(mktemp -d "${TMPDIR:-/tmp}/paxel-scrub.XXXXXX"); then
    paxel_say "Scrub: could not create a temporary folder (reason=local_io)."
    return 1
  fi
  ( trap 'rm -rf "$work"' EXIT; _paxel_scrub_range_in "$work" "$in" "$start" "$end" "$out" "$driver" ) || rc=$?
  return "$rc"
}

_paxel_scrub_range_in() {
  local work="$1" in="$2" start="$3" end="$4" out="$5" driver="$6" len range scrubbed in_lines out_lines rc=0
  len=$((end - start))
  range="$work/range"
  scrubbed="$work/scrubbed"
  # head stops reading at END, so tail may die of SIGPIPE; the length and
  # last-byte checks below catch a real short read.
  { tail -c +"$((start + 1))" "$in" 2>/dev/null || true; } | head -c "$len" > "$range" 2>/dev/null || true
  if [ "$(wc -c < "$range" | tr -d ' ')" != "$len" ] \
      || [ "$(tail -c 1 "$range" | od -An -tx1 | tr -d ' \n')" != "0a" ]; then
    paxel_say "Scrub: the file changed while it was read, or the range does not end at a line break (reason=file_changed)."
    return 2
  fi
  in_lines=$(wc -l < "$range" | tr -d ' ')
  # jq reads the file by name: without a timeout binary, _run_with_timeout
  # backgrounds the command, and a background job's stdin is /dev/null.
  _paxel_scrub_jq -n -R -c "$(_paxel_scrub_filter "$driver")" "$range" > "$scrubbed" 2> "$work/jq.err" || rc=$?
  rm -f "$range"
  if [ "$rc" -ne 0 ]; then
    paxel_say "Scrub: jq failed (exit ${rc}, reason=$(_paxel_scrub_jq_reason "$rc" "$work/jq.err"))."
    return 1
  fi
  out_lines=$(wc -l < "$scrubbed" | tr -d ' ')
  if ! _paxel_scrub_append "$scrubbed" "$out"; then
    paxel_say "Scrub: could not write the scrubbed lines (reason=local_io)."
    return 1
  fi
  printf '%s\n' "$((in_lines - out_lines))"
}

# One word, never jq's message: a jq error can quote transcript text.
_paxel_scrub_jq_reason() {
  case "$1" in
    124|143) echo timeout; return 0 ;;
    137) echo killed; return 0 ;;
  esac
  if grep -qE '^jq: error \(at [^)]*\): Regex failure: retry-limit' "$2" 2>/dev/null; then
    echo regex_limit
  # bash itself can hit the data cap in the subshell: "xmalloc: cannot
  # allocate N bytes", exit 2.
  elif grep -qE '^(jq: )?error: cannot allocate memory|: xmalloc: cannot allocate ' "$2" 2>/dev/null; then
    echo memory
  else
    echo jq_error
  fi
}

# An append cut short (disk full) is cut back to OUT's previous length, so
# the next append does not land after a partial line.
_paxel_scrub_append() {
  local src="$1" out="$2" before
  if [ ! -e "$out" ]; then
    cat "$src" > "$out" && return 0
    rm -f "$out"
    return 1
  fi
  before=$(wc -c < "$out" | tr -d ' ')
  cat "$src" >> "$out" && return 0
  # dd truncates OF at SEEK, with no copy, so it works on a full disk too.
  dd if=/dev/null of="$out" bs=1 seek="$before" 2>/dev/null \
    || paxel_say "Scrub: could not undo a partial write to ${out}."
  return 1
}

# Line-by-line string scrub for text that is not JSON (git snapshot files).
paxel_scrub_text_file() {
  local in="$1" out="$2" tmp rc=0
  tmp=$(mktemp "${out}.scrub-out.XXXXXX" || exit $?) || return 1
  _paxel_scrub_jq -n -R -r "$(_paxel_scrub_filter paxel_scrub_text_lines)" "$in" > "$tmp" 2>/dev/null || rc=$?
  if [ "$rc" -ne 0 ]; then
    rm -f "$tmp"
    paxel_say "Scrub: jq failed (exit ${rc})."
    return 1
  fi
  mv "$tmp" "$out" || { rm -f "$tmp"; return 1; }
}

# --- Paxel transcript store: spec parsing, discovery, creation, transport ---

PAXEL_STORE_DEFAULT_NAME="paxel-transcripts"
_PAXEL_STORE_TAB=$'\t'
PAXEL_STORE_API_TIMEOUT="${PAXEL_STORE_API_TIMEOUT:-30}"
PAXEL_STORE_DESCRIPTION="Paxel transcript store: coding-agent sessions from your remote machines. Keep this repository private."

# bash 3.2 (macOS /bin/bash) drops the caller's `||` inside $(...), so a
# non-zero status in there runs the upload's ERR trap. Every substitution in
# this file that can fail ends in `|| exit $?`: the caller still gets the
# status, and the trap stays quiet.

# Owner and name end up in CLI argv and API paths: a leading "-" would read
# as a flag, so it is refused on top of paxel_valid_name.
_paxel_store_valid_part() {
  paxel_valid_name "${1:-}" || return 1
  case "$1" in -*|.*) return 1 ;; esac
  return 0
}

# A dot is required so "owner/name/extra" can never parse as a host.
_paxel_store_valid_host() {
  case "${1:-}" in
    ''|-*|.*|*.|*[!a-z0-9.-]*|*..*) return 1 ;;
    *.*) return 0 ;;
  esac
  return 1
}

# git check-ref-format's rules, for the characters allowed here.
_paxel_store_valid_branch() {
  case "${1:-}" in
    ''|-*|/*|*/|.*|*/.*|*.|*..*|*//*|*.lock|*.lock/*|*[!A-Za-z0-9._/-]*) return 1 ;;
  esac
  return 0
}

paxel_store_parse_spec() {
  local spec="${1:-}" rest host owner name
  case "$spec" in
    https://*) rest="${spec#https://}" ;;
    ssh://git@*) rest="${spec#ssh://git@}" ;;
    git@*:*)
      rest="${spec#git@}"
      rest="${rest%%:*}/${rest#*:}"
      ;;
    *://*|*@*|*:*) return 1 ;;
    *) rest="$spec" ;;
  esac
  rest="${rest%/}"
  rest="${rest%.git}"
  case "$rest" in
    */*/*/*) return 1 ;;
    */*/*) ;;
    *) return 1 ;;
  esac
  host="${rest%%/*}"
  rest="${rest#*/}"
  owner="${rest%%/*}"
  name="${rest#*/}"
  host=$(printf '%s' "$host" | tr '[:upper:]' '[:lower:]' || exit $?) || return 1
  _paxel_store_valid_host "$host" || return 1
  _paxel_store_valid_part "$owner" || return 1
  _paxel_store_valid_part "$name" || return 1
  printf '%s\t%s\t%s\n' "$host" "$owner" "$name"
}

_paxel_store_default_host() {
  case "${1:-}" in
    gh) printf 'github.com\n' ;;
    glab) printf 'gitlab.com\n' ;;
    *) return 1 ;;
  esac
}

_paxel_store_cli_for_host() {
  case "${1:-}" in
    github.com|*.ghe.com|*github*) printf 'gh\n' ;;
    gitlab.com|*gitlab*) printf 'glab\n' ;;
    *) printf 'none\n' ;;
  esac
}

# GET an API endpoint through the CLI and print `jq -r FILTER` of the body.
# Status: 1 for HTTP 404, 4 when the CLI is missing or has no usable login,
# 2 for anything else (network, rate limit, 5xx, timeout, unreadable body).
_paxel_store_api_get() {
  local cli="$1" host="$2" endpoint="$3" filter="$4" err body rc=0
  case "$cli" in gh|glab) ;; *) return 2 ;; esac
  command -v "$cli" >/dev/null 2>&1 || return 4
  err=$(mktemp "${TMPDIR:-/tmp}/paxel-store-api.XXXXXX" || exit $?) || return 2
  case "$cli" in
    gh)
      body=$(_run_with_timeout "$PAXEL_STORE_API_TIMEOUT" env GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1 \
        gh api --hostname "$host" "$endpoint" 2>"$err" </dev/null || exit $?) || rc=$?
      ;;
    glab)
      body=$(_run_with_timeout "$PAXEL_STORE_API_TIMEOUT" \
        glab api --hostname "$host" "$endpoint" 2>"$err" </dev/null || exit $?) || rc=$?
      ;;
  esac
  if [ "$rc" -ne 0 ]; then
    if grep -q '(HTTP 404)' "$err" 2>/dev/null; then
      rc=1
    elif [ "$cli" = gh ] && [ "$rc" -eq 4 ]; then
      rc=4
    elif grep -q '(HTTP 401)' "$err" 2>/dev/null; then
      rc=4
    else
      rc=2
    fi
    rm -f "$err"
    return "$rc"
  fi
  rm -f "$err"
  printf '%s' "$body" | jq -r "$filter" 2>/dev/null || return 2
}

# Offline: does the CLI hold a credential for HOST? The token goes to a pipe
# or /dev/null, never to a variable or argv.
_paxel_store_cli_has_token() {
  local cli="$1" host="$2"
  case "$cli" in
    gh) gh auth token -h "$host" >/dev/null 2>&1 </dev/null ;;
    glab)
      [ -z "${GITLAB_TOKEN:-}${GITLAB_ACCESS_TOKEN:-}${OAUTH_TOKEN:-}" ] || return 0
      glab config get token --host "$host" 2>/dev/null </dev/null | grep . >/dev/null
      ;;
    *) return 1 ;;
  esac
}

# Like _paxel_store_cli_has_token, but only a login stored on disk counts:
# the token variables of this environment are left out.
_paxel_store_cli_stored_token() {
  local cli="$1" host="$2"
  case "$cli" in
    gh)
      env -u GH_TOKEN -u GITHUB_TOKEN -u GH_ENTERPRISE_TOKEN -u GITHUB_ENTERPRISE_TOKEN \
        gh auth token -h "$host" >/dev/null 2>&1 </dev/null
      ;;
    glab)
      env -u GITLAB_TOKEN -u GITLAB_ACCESS_TOKEN -u OAUTH_TOKEN \
        glab config get token --host "$host" 2>/dev/null </dev/null | grep . >/dev/null
      ;;
    *) return 1 ;;
  esac
}

# Prints the login of CLI on HOST (default: the CLI's public host). Status 1
# when the CLI is missing or logged out, 2 when it holds a credential but the
# host could not be reached. A logged-out CLI behind a blocked network reads
# as logged out, so it cannot stall resolution for the other CLI.
paxel_store_cli_login() {
  local cli="${1:-}" host="${2:-}" login rc=0 filter
  case "$cli" in
    gh) filter='.login // empty' ;;
    glab) filter='.username // empty' ;;
    *) return 1 ;;
  esac
  command -v "$cli" >/dev/null 2>&1 || return 1
  [ -n "$host" ] || host=$(_paxel_store_default_host "$cli" || exit $?) || return 1
  login=$(_paxel_store_api_get "$cli" "$host" user "$filter" || exit $?) || rc=$?
  case "$rc" in
    0) ;;
    4) return 1 ;;
    *)
      _paxel_store_cli_has_token "$cli" "$host" || return 1
      return 2
      ;;
  esac
  _paxel_store_valid_part "$login" || return 2
  printf '%s\n' "$login"
}

# Same contract as paxel_store_lookup, plus status 4 when the CLI is missing
# or has no usable login on HOST.
_paxel_store_lookup() {
  local cli="${1:-}" owner="${2:-}" name="${3:-}" host="${4:-}" endpoint filter out rc=0 vis branch
  _paxel_store_valid_part "$owner" || return 2
  _paxel_store_valid_part "$name" || return 2
  _paxel_store_valid_host "$host" || return 2
  case "$cli" in
    gh)
      endpoint="repos/${owner}/${name}"
      filter='[(.visibility // (if .private == true then "private" elif .private == false then "public" else "" end)), (.default_branch // "")] | @tsv'
      ;;
    glab)
      endpoint="projects/${owner}%2F${name}"
      filter='[(.visibility // ""), (.default_branch // "")] | @tsv'
      ;;
    *) return 2 ;;
  esac
  out=$(_paxel_store_api_get "$cli" "$host" "$endpoint" "$filter" || exit $?) || rc=$?
  case "$rc" in
    0) ;;
    1|4) return "$rc" ;;
    *) return 2 ;;
  esac
  vis="${out%%${_PAXEL_STORE_TAB}*}"
  branch="${out#*${_PAXEL_STORE_TAB}}"
  case "$vis" in private|internal|public) ;; *) return 2 ;; esac
  if [ -n "$branch" ]; then
    _paxel_store_valid_branch "$branch" || return 2
  fi
  printf '%s\t%s\n' "$vis" "$branch"
}

# Prints "visibility<TAB>default_branch" (branch may be empty for an empty
# GitLab project). HOST is required: a store on GitHub Enterprise or a
# self-hosted GitLab must never be checked on the public host. Status 1 when
# the repo does not exist, 2 when unknown.
paxel_store_lookup() {
  local rc=0
  _paxel_store_lookup "$@" || rc=$?
  case "$rc" in
    0|1) return "$rc" ;;
    *) return 2 ;;
  esac
}

# Prints the names at the root of BRANCH, one per line; an empty repo prints
# nothing. Status 2 when the host could not be read.
paxel_store_root_names() {
  local cli="${1:-}" owner="${2:-}" name="${3:-}" host="${4:-}" branch="${5:-}" endpoint out rc=0
  case "$cli" in
    gh) endpoint="repos/${owner}/${name}/contents?ref=${branch}" ;;
    glab) endpoint="projects/${owner}%2F${name}/repository/tree?ref=${branch}&per_page=100" ;;
    *) return 2 ;;
  esac
  out=$(_paxel_store_api_get "$cli" "$host" "$endpoint" '.[].name' || exit $?) || rc=$?
  case "$rc" in
    0) [ -z "$out" ] || printf '%s\n' "$out" ;;
    1) ;;
    *) return 2 ;;
  esac
}

_paxel_store_print_resolved() {
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "${5:--}" "$6"
}

# Never echoes PAXEL_STORE back: a pasted URL can carry a token.
_paxel_store_resolve_explicit() {
  local parsed host owner name cli login="" state=existing rc=0
  if ! parsed=$(paxel_store_parse_spec "$1" || exit $?); then
    paxel_say "PAXEL_STORE must name a repo as host/owner/name, https://host/owner/name or git@host:owner/name, with no credentials in it."
    return 1
  fi
  host="${parsed%%${_PAXEL_STORE_TAB}*}"
  parsed="${parsed#*${_PAXEL_STORE_TAB}}"
  owner="${parsed%%${_PAXEL_STORE_TAB}*}"
  name="${parsed#*${_PAXEL_STORE_TAB}}"
  cli=$(_paxel_store_cli_for_host "$host")
  if [ "$cli" != none ]; then
    login=$(paxel_store_cli_login "$cli" "$host" || exit $?) || rc=$?
    case "$rc" in
      0) ;;
      1) cli=none; login="" ;;
      *)
        paxel_say "Could not reach ${host} through ${cli} to check https://${host}/${owner}/${name}. Try again when the network is back."
        return 2
        ;;
    esac
  fi
  if [ "$cli" != none ]; then
    rc=0
    paxel_store_lookup "$cli" "$owner" "$name" "$host" >/dev/null || rc=$?
    case "$rc" in
      0) state=existing ;;
      1) state=new ;;
      *)
        paxel_say "Could not check https://${host}/${owner}/${name} through ${cli} (network error or rate limit). Try again later."
        return 2
        ;;
    esac
  fi
  _paxel_store_print_resolved "$host" "$owner" "$name" "$cli" "$login" "$state"
}

# Prints "state<TAB>login" for the convention store under one CLI. state is
# absent (CLI missing or logged out), existing, new, unreachable (login
# unknown) or unchecked (lookup unknown); login is "-" when not known.
_paxel_store_convention_state() {
  local cli="$1" host login rc=0
  host=$(_paxel_store_default_host "$cli" || exit $?) || return 1
  login=$(paxel_store_cli_login "$cli" "$host" || exit $?) || rc=$?
  case "$rc" in
    0) ;;
    1) printf 'absent\t-\n'; return 0 ;;
    *) printf 'unreachable\t-\n'; return 0 ;;
  esac
  rc=0
  paxel_store_lookup "$cli" "$login" "$PAXEL_STORE_DEFAULT_NAME" "$host" >/dev/null || rc=$?
  case "$rc" in
    0) printf 'existing\t%s\n' "$login" ;;
    1) printf 'new\t%s\n' "$login" ;;
    *) printf 'unchecked\t%s\n' "$login" ;;
  esac
}

_paxel_store_say_unknown() {
  local cli="$1" state="$2" login="$3" host
  host=$(_paxel_store_default_host "$cli" || exit $?) || return 0
  case "$state" in
    unreachable) paxel_say "Could not reach ${host} through ${cli} to look for your transcript store. Try again when the network is back." ;;
    unchecked) paxel_say "Could not check https://${host}/${login}/${PAXEL_STORE_DEFAULT_NAME} through ${cli} (network error or rate limit). Try again later." ;;
  esac
}

# Both CLIs are checked before deciding, and an unknown side only blocks the
# result when it could change it: GitHub wins whenever its store exists, so
# a GitLab outage cannot turn off an existing GitHub store.
_paxel_store_resolve_convention() {
  local name="$PAXEL_STORE_DEFAULT_NAME" gh glab gh_state gh_login glab_state glab_login
  PAXEL_STORE_LOGGED_OUT_CLIS=""
  gh=$(_paxel_store_convention_state gh || exit $?) || return 2
  glab=$(_paxel_store_convention_state glab || exit $?) || return 2
  gh_state="${gh%%${_PAXEL_STORE_TAB}*}"
  gh_login="${gh#*${_PAXEL_STORE_TAB}}"
  glab_state="${glab%%${_PAXEL_STORE_TAB}*}"
  glab_login="${glab#*${_PAXEL_STORE_TAB}}"
  # The installed CLIs with no login, for a caller that names them without
  # asking each host again (the upload). Set only when not run in $(...).
  if [ "$gh_state" = absent ] && command -v gh >/dev/null 2>&1; then PAXEL_STORE_LOGGED_OUT_CLIS="gh"; fi
  if [ "$glab_state" = absent ] && command -v glab >/dev/null 2>&1; then
    PAXEL_STORE_LOGGED_OUT_CLIS="${PAXEL_STORE_LOGGED_OUT_CLIS:+$PAXEL_STORE_LOGGED_OUT_CLIS }glab"
  fi

  case "$gh_state" in
    existing)
      case "$glab_state" in
        existing)
          paxel_say "Found a transcript store on both GitHub and GitLab. Using https://github.com/${gh_login}/${name}; https://gitlab.com/${glab_login}/${name} is not used. Set PAXEL_STORE to choose the other one."
          ;;
        unreachable|unchecked)
          paxel_say "Using https://github.com/${gh_login}/${name}. Could not check gitlab.com for another transcript store."
          ;;
      esac
      _paxel_store_print_resolved github.com "$gh_login" "$name" gh "$gh_login" existing
      return 0
      ;;
    unreachable|unchecked)
      _paxel_store_say_unknown gh "$gh_state" "$gh_login"
      _paxel_store_say_unknown glab "$glab_state" "$glab_login"
      return 2
      ;;
  esac

  case "$glab_state" in
    existing)
      _paxel_store_print_resolved gitlab.com "$glab_login" "$name" glab "$glab_login" existing
      ;;
    unreachable|unchecked)
      _paxel_store_say_unknown glab "$glab_state" "$glab_login"
      return 2
      ;;
    *)
      if [ "$gh_state" = new ]; then
        _paxel_store_print_resolved github.com "$gh_login" "$name" gh "$gh_login" new
      elif [ "$glab_state" = new ]; then
        _paxel_store_print_resolved gitlab.com "$glab_login" "$name" glab "$glab_login" new
      else
        return 1
      fi
      ;;
  esac
}

# Prints "host<TAB>owner<TAB>name<TAB>cli<TAB>login<TAB>existing|new"; login
# is "-" when cli is none, so a tab-split read keeps every field. Status 1:
# no CLI logged in (or an unusable PAXEL_STORE); 2: a host could not be
# checked; 3: PAXEL_STORE is set and empty (store off).
paxel_store_resolve() {
  if [ -n "${PAXEL_STORE+x}" ]; then
    [ -n "$PAXEL_STORE" ] || return 3
    _paxel_store_resolve_explicit "$PAXEL_STORE" || return $?
    return 0
  fi
  _paxel_store_resolve_convention || return $?
}

_paxel_store_readme() {
  cat <<'PAXEL_STORE_README'
# Paxel transcript store

This repository holds coding-agent sessions (Claude Code and Codex) that
`paxel push` copied from your remote machines, plus git history snapshots of
the repos you worked in there. Known credential formats are removed before
anything is written here, and the base64 data of images pasted into a prompt,
returned by a tool (a screenshot, an image file the agent read) or generated
by the agent is replaced with "[image removed]". Everything else in a session
stays: prompts, tool output, file contents, paths, and any image written into
other text, such as command output.

Keep this repository private. Paxel never reads it. When you run a Paxel
upload on your main machine (a laptop, a desktop or a dev box), the script
there reads this repository with your own git credentials and treats these
sessions like local ones. What an upload sends to Paxel is described at
https://paxel.ycombinator.com/data-handling.

To stop capture on a machine, run `paxel setup --off` on it. To delete
everything: remove the setup line from your provisioning scripts, turn capture
off on machines that are still running, then delete this repository. A
credential the scrub missed stays in the history until you delete the
repository or rewrite its history.
PAXEL_STORE_README
}

_paxel_store_marker() {
  jq -cn --argjson v "$PAXEL_STORE_SCHEMA_VERSION" --arg b "$1" \
    --arg by "paxel setup${PAXEL_SCRIPT_VERSION:+ $PAXEL_SCRIPT_VERSION}" \
    '{schema_version: $v, branch: $b, created_by: $by}'
}

# The exact bytes of each seeded file.
_paxel_store_seed_content() {
  case "$1" in
    .gitattributes) printf '* -text -diff\n' ;;
    README.md) _paxel_store_readme ;;
    paxel-store.json) _paxel_store_marker "$2" ;;
    *) return 1 ;;
  esac
}

_paxel_store_b64() { base64 | tr -d '\n'; }

# The CLI's own reason, minus update and telemetry notices glab mixes in.
_paxel_store_first_line() {
  { grep -v -i -E 'update available|release notes|telemetry|^[[:space:]]*$' "$1" 2>/dev/null || true; } | head -n 1 | cut -c1-200
}

# Why a CLI call failed. A call stopped by the time limit prints nothing, so
# that is said instead (124 from timeout, 143/137 from the fallback kill).
_paxel_store_reason() {
  local err="$1" rc="$2" line
  case "$rc" in
    124|137|143)
      printf 'no answer after %ss' "$PAXEL_STORE_API_TIMEOUT"
      return 0
      ;;
  esac
  line=$(_paxel_store_first_line "$err")
  line="${line%.}"
  if [ -n "$line" ]; then
    printf '%s' "$line"
  else
    printf 'the command exited with status %s and printed no reason' "$rc"
  fi
}

# Git blob id of stdin, the id the contents API reports as `sha`. Run from /
# so a SHA-256 checkout around setup cannot change the hash.
_paxel_store_blob_sha() { (cd / && git hash-object --stdin); }

# A rerun after a half-finished seed skips the files it already wrote. A file
# with other content means someone else's repo, which is never marked.
# Status 0 present, 3 missing, 1 refused or unreadable.
_paxel_store_seed_gh_check() {
  local owner="$1" name="$2" host="$3" branch="$4" path="$5" display have want rc=0
  display="${host}/${owner}/${name}"
  have=$(_paxel_store_api_get gh "$host" "repos/${owner}/${name}/contents/${path}?ref=${branch}" '.sha // empty' || exit $?) || rc=$?
  case "$rc" in
    0)
      [ "$path" != paxel-store.json ] || return 0
      want=$(_paxel_store_seed_content "$path" "$branch" | _paxel_store_blob_sha || exit $?) || return 1
      [ "$have" != "$want" ] || return 0
      paxel_say "REFUSED: https://${display} already has a ${path} that Paxel did not write, so it was not made a transcript store. Use a new or empty repo."
      return 1
      ;;
    1) return 3 ;;
    *)
      paxel_say "Could not check ${path} in https://${display} (network error or rate limit). Run ${_PAXEL_STORE_RERUN:-paxel setup} again."
      return 1
      ;;
  esac
}

_paxel_store_seed_gh_file() {
  local owner="$1" name="$2" host="$3" branch="$4" path="$5" display content err attempt rc=0
  display="${host}/${owner}/${name}"
  content=$(_paxel_store_seed_content "$path" "$branch" | _paxel_store_b64 || exit $?) || return 1
  err=$(mktemp "${TMPDIR:-/tmp}/paxel-store-seed.XXXXXX" || exit $?) || return 1
  for attempt in 1 2; do
    rc=0
    _run_with_timeout "$PAXEL_STORE_API_TIMEOUT" env GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1 \
      gh api --hostname "$host" -X PUT "repos/${owner}/${name}/contents/${path}" \
      -f message="paxel setup: add ${path}" -f content="$content" -f branch="$branch" \
      >/dev/null 2>"$err" </dev/null || rc=$?
    [ "$rc" -ne 0 ] || break
    # Writes in quick succession can race GitHub's branch update (409).
    if [ "$attempt" -eq 1 ] && grep -q '(HTTP 409)' "$err" 2>/dev/null; then
      sleep 1
      continue
    fi
    break
  done
  if [ "$rc" -ne 0 ]; then
    paxel_say "Could not write ${path} to https://${display}: $(_paxel_store_reason "$err" "$rc"). Run ${_PAXEL_STORE_RERUN:-paxel setup} again."
    rm -f "$err"
    return 1
  fi
  rm -f "$err"
}

# Contents API, one commit per file. Every file is checked before the first
# write, so a repo that is refused gets nothing. The marker goes last so a
# half-seeded repo has no marker, and push refuses it.
_paxel_store_seed_gh() {
  local owner="$1" name="$2" host="$3" branch="$4" path missing="" rc
  for path in .gitattributes README.md paxel-store.json; do
    rc=0
    _paxel_store_seed_gh_check "$owner" "$name" "$host" "$branch" "$path" || rc=$?
    case "$rc" in
      0) ;;
      3) missing="$missing $path" ;;
      *) return 1 ;;
    esac
  done
  for path in $missing; do
    _paxel_store_seed_gh_file "$owner" "$name" "$host" "$branch" "$path" || return 1
  done
}

# One commits API call creates all three files in a single commit.
_paxel_store_seed_glab() {
  local owner="$1" name="$2" host="$3" branch="$4" err body attrs readme marker rc=0
  attrs=$(_paxel_store_seed_content .gitattributes "$branch" || exit $?) || return 1
  readme=$(_paxel_store_seed_content README.md "$branch" || exit $?) || return 1
  marker=$(_paxel_store_seed_content paxel-store.json "$branch" || exit $?) || return 1
  err=$(mktemp "${TMPDIR:-/tmp}/paxel-store-seed.XXXXXX" || exit $?) || return 1
  body=$(mktemp "${TMPDIR:-/tmp}/paxel-store-body.XXXXXX" || exit $?) || { rm -f "$err"; return 1; }
  if ! jq -n --arg branch "$branch" --arg gitattributes "$attrs" --arg readme "$readme" --arg marker "$marker" \
    '{branch: $branch, commit_message: "paxel setup: seed transcript store",
      actions: [
        {action: "create", file_path: ".gitattributes", content: ($gitattributes + "\n")},
        {action: "create", file_path: "README.md", content: ($readme + "\n")},
        {action: "create", file_path: "paxel-store.json", content: ($marker + "\n")}
      ]}' > "$body"; then
    rm -f "$err" "$body"
    return 1
  fi
  _run_with_timeout "$PAXEL_STORE_API_TIMEOUT" \
    glab api --hostname "$host" -X POST "projects/${owner}%2F${name}/repository/commits" \
    -H "Content-Type: application/json" --input "$body" >/dev/null 2>"$err" </dev/null || rc=$?
  if [ "$rc" -ne 0 ]; then
    paxel_say "Could not write the store files to https://${host}/${owner}/${name}: $(_paxel_store_reason "$err" "$rc"). Run ${_PAXEL_STORE_RERUN:-paxel setup} again."
  fi
  rm -f "$err" "$body"
  [ "$rc" -eq 0 ]
}

# Seeds paxel-store.json, .gitattributes and README.md on BRANCH of a new
# repo on HOST. Status 1 on failure.
paxel_store_seed() {
  local cli="${1:-}" owner="${2:-}" name="${3:-}" branch="${4:-}" host="${5:-}"
  _paxel_store_valid_part "$owner" && _paxel_store_valid_part "$name" || return 1
  _paxel_store_valid_branch "$branch" || return 1
  _paxel_store_valid_host "$host" || return 1
  case "$cli" in
    gh) _paxel_store_seed_gh "$owner" "$name" "$host" "$branch" || return 1 ;;
    glab) _paxel_store_seed_glab "$owner" "$name" "$host" "$branch" || return 1 ;;
    *) return 1 ;;
  esac
}

# GitHub and GitLab answer reads right after a create, but not always on
# the first try.
_paxel_store_read_back() {
  local cli="$1" owner="$2" name="$3" host="$4" attempt out rc
  for attempt in 1 2 3; do
    rc=0
    out=$(paxel_store_lookup "$cli" "$owner" "$name" "$host" || exit $?) || rc=$?
    if [ "$rc" -eq 0 ]; then
      printf '%s\n' "$out"
      return 0
    fi
    [ "$attempt" -eq 3 ] || sleep "$attempt"
  done
  return 1
}

# Runs a create command from an empty directory: setup often runs inside a
# dotfiles or project checkout, and neither CLI may add a remote there.
_paxel_store_run_create() {
  local err="$1" dir rc=0
  shift
  dir=$(mktemp -d "${TMPDIR:-/tmp}/paxel-store-create.XXXXXX" || exit $?) || return 1
  (cd "$dir" && _run_with_timeout "$PAXEL_STORE_API_TIMEOUT" "$@" >/dev/null 2>"$err" </dev/null) || rc=$?
  rm -rf "$dir"
  return "$rc"
}

# Creates OWNER/NAME on HOST as a private repo with no local checkout,
# confirms it reads back as private, seeds it and prints the branch. HOST is
# required, so a store on GitHub Enterprise or a self-hosted GitLab is never
# created on the public host. Status 1 on any failure; a repo that was
# created is left in place.
paxel_store_create() {
  local cli="${1:-}" owner="${2:-}" name="${3:-}" host="${4:-}" display err rc=0 login info vis branch
  _paxel_store_valid_part "$owner" && _paxel_store_valid_part "$name" || return 1
  if ! _paxel_store_valid_host "$host"; then
    paxel_say "Cannot create ${owner}/${name}: no store host was given."
    return 1
  fi
  display="${host}/${owner}/${name}"
  err=$(mktemp "${TMPDIR:-/tmp}/paxel-store-create.XXXXXX" || exit $?) || return 1
  case "$cli" in
    gh)
      _paxel_store_run_create "$err" env GH_HOST="$host" GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1 \
        gh repo create "${owner}/${name}" --private --disable-issues --disable-wiki \
        --description "$PAXEL_STORE_DESCRIPTION" || rc=$?
      ;;
    glab)
      login=$(paxel_store_cli_login glab "$host" || exit $?) || rc=$?
      case "$rc" in
        0) ;;
        1)
          rm -f "$err"
          paxel_say "Could not create https://${display}: glab is not logged in to ${host}. Run: glab auth login --hostname ${host}"
          return 1
          ;;
        *)
          rm -f "$err"
          paxel_say "Could not create https://${display}: could not reach ${host} through glab. Try again when the network is back."
          return 1
          ;;
      esac
      if [ "$owner" = "$login" ]; then
        _paxel_store_run_create "$err" env GITLAB_HOST="$host" \
          glab repo create "$name" --private --skipGitInit \
          --description "$PAXEL_STORE_DESCRIPTION" || rc=$?
      else
        _paxel_store_run_create "$err" env GITLAB_HOST="$host" \
          glab repo create "$name" --private --skipGitInit \
          --description "$PAXEL_STORE_DESCRIPTION" --group "$owner" || rc=$?
      fi
      ;;
    *)
      rm -f "$err"
      paxel_say "Cannot create https://${display}: creating a store needs gh (GitHub) or glab (GitLab) logged in."
      return 1
      ;;
  esac
  if [ "$rc" -ne 0 ]; then
    paxel_say "Could not create https://${display}: $(_paxel_store_reason "$err" "$rc"). Check whether the repo exists on ${host}, then run ${_PAXEL_STORE_RERUN:-paxel setup} again."
    rm -f "$err"
    return 1
  fi
  rm -f "$err"

  if ! info=$(_paxel_store_read_back "$cli" "$owner" "$name" "$host" || exit $?); then
    paxel_say "Created https://${display}, but could not read its visibility back, so nothing was written to it. Check that it is private, then run ${_PAXEL_STORE_RERUN:-paxel setup} again."
    return 1
  fi
  vis="${info%%${_PAXEL_STORE_TAB}*}"
  branch="${info#*${_PAXEL_STORE_TAB}}"
  if [ "$vis" != private ]; then
    paxel_say "REFUSED: https://${display} was created as ${vis}, not private. Paxel will not write transcripts to it. Make it private in the repo settings, then run ${_PAXEL_STORE_RERUN:-paxel setup} again."
    return 1
  fi
  _paxel_store_valid_branch "$branch" || branch=main
  paxel_store_seed "$cli" "$owner" "$name" "$branch" "$host" || return 1
  printf '%s\n' "$branch"
}

# Reads host/owner/name from the config. Status 1 when any part is missing
# or would be unsafe in a URL or path.
_paxel_store_configured() {
  _PAXEL_STORE_HOST=$(paxel_config_get store_host)
  _PAXEL_STORE_OWNER=$(paxel_config_get store_owner)
  _PAXEL_STORE_NAME=$(paxel_config_get store_name)
  _paxel_store_valid_host "$_PAXEL_STORE_HOST" || return 1
  _paxel_store_valid_part "$_PAXEL_STORE_OWNER" || return 1
  _paxel_store_valid_part "$_PAXEL_STORE_NAME" || return 1
}

# An unauthenticated probe sees public repos only: a 200 is public, and a 404
# cannot tell private from internal or missing, so it prints public or
# unknown.
_paxel_store_probe_visibility() {
  local host="$1" owner="$2" name="$3" url code rc=0
  case "$host" in
    github.com) url="https://api.github.com/repos/${owner}/${name}" ;;
    gitlab.com|*gitlab*) url="https://${host}/api/v4/projects/${owner}%2F${name}" ;;
    *) printf 'unknown\n'; return 0 ;;
  esac
  code=$(curl --proto '=https' --tlsv1.2 -sS -o /dev/null -w '%{http_code}' \
    --connect-timeout 5 --max-time 15 -A "paxel-store/1" "$url" 2>/dev/null || exit $?) || rc=$?
  if [ "$rc" -ne 0 ]; then
    printf 'unknown\n'
    return 0
  fi
  case "$code" in
    200) printf 'public\n' ;;
    *) printf 'unknown\n' ;;
  esac
}

# Prints private, internal, public or unknown for the configured store.
paxel_store_visibility() {
  local cli out probed rc=0
  if ! _paxel_store_configured; then
    printf 'unknown\n'
    return 0
  fi
  cli=$(paxel_config_get store_cli)
  case "$cli" in
    gh|glab)
      out=$(_paxel_store_lookup "$cli" "$_PAXEL_STORE_OWNER" "$_PAXEL_STORE_NAME" "$_PAXEL_STORE_HOST" || exit $?) || rc=$?
      case "$rc" in
        0) printf '%s\n' "${out%%${_PAXEL_STORE_TAB}*}" ;;
        4)
          # The CLI has no login here (a token only the provisioning shell
          # had, an expired one, a PATH without the CLI). The anonymous probe
          # still sees a public repo.
          probed=$(_paxel_store_probe_visibility "$_PAXEL_STORE_HOST" "$_PAXEL_STORE_OWNER" "$_PAXEL_STORE_NAME" || exit $?) || probed=unknown
          printf '%s\n' "$probed"
          ;;
        *) printf 'unknown\n' ;;
      esac
      ;;
    none)
      _paxel_store_probe_visibility "$_PAXEL_STORE_HOST" "$_PAXEL_STORE_OWNER" "$_PAXEL_STORE_NAME"
      ;;
    *) printf 'unknown\n' ;;
  esac
}

# BatchMode as in paxel_git, so a missing key or an unknown host key fails
# here the way it would fail a push. ssh exits 255 on its own errors; after a
# login GitLab exits 0 and GitHub 1.
_paxel_store_ssh_login_works() {
  local host="$1" rc=0
  _paxel_store_valid_host "$host" || return 1
  command -v ssh >/dev/null 2>&1 || return 1
  _run_with_timeout 20 ssh -o BatchMode=yes -o ConnectTimeout=10 -T "git@${host}" \
    </dev/null >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 0 ] || [ "$rc" -eq 1 ]
}

# With no CLI there is no https credential helper to inject, and an SSH key
# is the credential such a box has. A logged-in CLI always has its https
# helper, so its ssh setting is used only when ssh logs in: glab answers ssh
# when nothing is set, and a token-only box has no key. Setup probes a box
# with no CLI with paxel_store_box_probe instead.
paxel_store_transport() {
  local cli="${1:-}" host="${2:-}" proto=""
  case "$cli" in
    gh) proto=$(gh config get git_protocol -h "$host" 2>/dev/null </dev/null || exit $?) || proto="" ;;
    glab) proto=$(glab config get git_protocol --host "$host" 2>/dev/null </dev/null || exit $?) || proto="" ;;
    *) printf 'ssh\n'; return 0 ;;
  esac
  if printf '%s\n' "$proto" | grep -qx ssh && _paxel_store_ssh_login_works "$host"; then
    printf 'ssh\n'
  else
    printf 'https\n'
  fi
}

# With no gh or glab login, git reaches the store with this machine's own
# login: https first (credential helpers, Coder's GIT_ASKPASS), then ssh
# (Coder's `coder gitssh`, an SSH agent or key). Prints the transport and what it found: "<t><TAB>found",
# "<t><TAB>missing" when the host said this login sees no such repo (it may
# not exist yet), or "ssh<TAB>denied" when neither transport got in. Each try
# is a bounded ls-remote that never prompts.
paxel_store_box_probe() {
  local host="${1:-}" owner="${2:-}" name="${3:-}" t url err missing="" rc PAXEL_STORE_GIT_TIMEOUT="${PAXEL_SETUP_GIT_TIMEOUT:-30}"
  _paxel_store_valid_host "$host" && _paxel_store_valid_part "$owner" && _paxel_store_valid_part "$name" || return 1
  paxel_is_uint "$PAXEL_STORE_GIT_TIMEOUT" || PAXEL_STORE_GIT_TIMEOUT=30
  err=$(mktemp "${TMPDIR:-/tmp}/paxel-store-probe.XXXXXX" || exit $?) || return 1
  for t in https ssh; do
    if [ "$t" = https ]; then url="https://${host}/${owner}/${name}.git"; else url="git@${host}:${owner}/${name}.git"; fi
    # The test seam paxel_store_url honors.
    case "${PAXEL_STORE_URL_OVERRIDE:-}" in file://*) url="$PAXEL_STORE_URL_OVERRIDE" ;; esac
    rc=0
    _PAXEL_GIT_BOX_AUTH=1 paxel_git ls-remote --heads -- "$url" >/dev/null 2>"$err" </dev/null || rc=$?
    if [ "$rc" -eq 0 ]; then
      rm -f "$err"
      printf '%s\tfound\n' "$t"
      return 0
    fi
    if [ -z "$missing" ] && grep -qiE "repository not found|repository '.*' not found|could not be found" "$err" 2>/dev/null; then
      missing="$t"
    fi
  done
  rm -f "$err"
  if [ -n "$missing" ]; then
    printf '%s\tmissing\n' "$missing"
  else
    printf 'ssh\tdenied\n'
  fi
}

paxel_store_url() {
  if [ -n "${PAXEL_STORE_URL_OVERRIDE:-}" ]; then
    # Test seam: points the store at a local bare repo, never at a host.
    case "$PAXEL_STORE_URL_OVERRIDE" in
      file://*) printf '%s\n' "$PAXEL_STORE_URL_OVERRIDE"; return 0 ;;
      *) return 1 ;;
    esac
  fi
  _paxel_store_configured || return 1
  case "$(paxel_config_get store_transport)" in
    ssh) printf 'git@%s:%s/%s.git\n' "$_PAXEL_STORE_HOST" "$_PAXEL_STORE_OWNER" "$_PAXEL_STORE_NAME" ;;
    https) printf 'https://%s/%s/%s.git\n' "$_PAXEL_STORE_HOST" "$_PAXEL_STORE_OWNER" "$_PAXEL_STORE_NAME" ;;
    *) return 1 ;;
  esac
}

paxel_store_display() {
  _paxel_store_configured || return 1
  printf '%s/%s/%s\n' "$_PAXEL_STORE_HOST" "$_PAXEL_STORE_OWNER" "$_PAXEL_STORE_NAME"
}

# Over https the CLI's own credential helper is used inline, so pushes work
# without `gh auth setup-git` and no token appears in git's argv or in any
# config file. A store setup reached with no CLI (store_auth=git) uses this
# machine's own git login.
paxel_store_git() {
  local helper="" cli
  cli=$(paxel_config_get store_cli)
  if [ "$(paxel_config_get store_transport)" = https ]; then
    case "$cli" in
      gh) helper='!gh auth git-credential' ;;
      glab) helper='!glab auth git-credential' ;;
    esac
  fi
  if [ -n "$helper" ]; then
    paxel_git -c credential.helper= -c "credential.helper=${helper}" "$@" || return $?
  elif [ "$cli" = none ] && [ "$(paxel_config_get store_auth)" = git ]; then
    _PAXEL_GIT_BOX_AUTH=1 paxel_git "$@" || return $?
  else
    paxel_git "$@" || return $?
  fi
}

# --- Paxel transcript store: push (worker, lock, incremental scrub, commits) ---

PAXEL_PUSH_DIR="${PAXEL_HOME_DIR}/push"
PAXEL_PUSH_LOCK_DIR="${PAXEL_PUSH_DIR}/lock"
PAXEL_STORE_CLONE_DIR="${PAXEL_HOME_DIR}/store.git"
PAXEL_PUSH_LOCK_HELD=0
PAXEL_PUSH_HEARTBEAT_PID=""
_PXP_TAB=$'\t'
_PXP_HOST=""
_PXP_WORK=""
_PXP_SHOW_PROGRESS=0
_PXP_NOW=0
PAXEL_STORE_RETRY_SECS=3600

# Prints the env var named $1 when it is a plain unsigned integer, else $2.
_paxel_push_uint_env() {
  local v="${!1:-}"
  if paxel_is_uint "$v" && [ "${#v}" -le 12 ]; then
    printf '%s\n' "$v"
  else
    printf '%s\n' "$2"
  fi
}

# GNU and BSD stat take different flags, and GNU `stat -f` means
# file-system mode, so the flavor is chosen up front rather than by fallback.
_paxel_stat_is_gnu() {
  if [ -z "${_PXP_STAT_GNU:-}" ]; then
    if stat -c %s / >/dev/null 2>&1; then _PXP_STAT_GNU=1; else _PXP_STAT_GNU=0; fi
  fi
  [ "$_PXP_STAT_GNU" = 1 ]
}

# Prints 0 for a missing file, so callers can do arithmetic on the result.
_paxel_mtime() {
  local m
  if _paxel_stat_is_gnu; then
    m=$(stat -c %Y "$1" 2>/dev/null || true)
  else
    m=$(stat -f %m "$1" 2>/dev/null || true)
  fi
  paxel_is_uint "$m" || m=0
  printf '%s\n' "$m"
}

_paxel_push_host() {
  if [ -z "$_PXP_HOST" ]; then
    _PXP_HOST=$(hostname 2>/dev/null || uname -n 2>/dev/null || echo unknown)
  fi
  printf '%s\n' "$_PXP_HOST"
}

_paxel_push_off() {
  [ -n "$(paxel_config_get off_at)" ]
}

_paxel_push_has_trigger() {
  [ -e "$PAXEL_PUSH_DIR/pending" ] || [ -e "$PAXEL_PUSH_DIR/first_pending" ]
}

# Plumbing on the local store clone that never reads a missing blob, so it
# never touches the network and skips paxel_git's time limit: without a
# timeout binary that wrapper backgrounds the command, which takes away its
# stdin and leaves a sleep running per call. Calls that can fetch (clone,
# fetch, push, cat-file on a blob) keep paxel_store_git.
_paxel_local_git() {
  env -u GIT_TRACE -u GIT_TRACE_CURL -u GIT_CURL_VERBOSE -u GIT_TRACE_PACKET \
    GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=/bin/false SSH_ASKPASS=/bin/false \
    GIT_SSH_COMMAND="${PAXEL_GIT_SSH_COMMAND:-ssh -o BatchMode=yes -o ConnectTimeout=15}" \
    git -c core.hooksPath=/dev/null -c commit.gpgsign=false -c tag.gpgsign=false "$@"
}

# ---- Lock: one worker per home directory, across hosts sharing that home ----

_paxel_push_write_owner() {
  local tmp="${PAXEL_PUSH_LOCK_DIR}/owner.tmp.$$"
  printf '%s\t%s\t%s\n' "$(_paxel_push_host)" "$$" "$(paxel_now_epoch)" > "$tmp" 2>/dev/null || return 1
  mv "$tmp" "${PAXEL_PUSH_LOCK_DIR}/owner" 2>/dev/null
}

_paxel_push_lock_owned() {
  local line host pid rest
  line=$(head -n 1 "${PAXEL_PUSH_LOCK_DIR}/owner" 2>/dev/null || true)
  IFS="$_PXP_TAB" read -r host pid rest <<< "$line"
  [ "$host" = "$(_paxel_push_host)" ] && [ "$pid" = "$$" ]
}

# Status 0 when a live worker holds the lock: its heartbeat is younger than
# PAXEL_LOCK_STALE_SECS and, on this host, its pid is running. A live worker
# refreshes the heartbeat every 30 s, so a stale one also catches a pid that
# was reused after a reboot or SIGKILL. Another host (a home on a network
# share) is judged on the heartbeat alone.
paxel_push_lock_alive() {
  local line host pid hb rest now age stale
  [ -d "$PAXEL_PUSH_LOCK_DIR" ] || return 1
  line=$(head -n 1 "${PAXEL_PUSH_LOCK_DIR}/owner" 2>/dev/null || true)
  if [ -z "$line" ]; then
    # The owner file is written right after mkdir; a lock that just appeared
    # is live, one that never got an owner is not.
    now=$(paxel_now_epoch)
    age=$((now - $(_paxel_mtime "$PAXEL_PUSH_LOCK_DIR")))
    [ "$age" -lt 30 ]
    return
  fi
  IFS="$_PXP_TAB" read -r host pid hb rest <<< "$line"
  paxel_is_uint "$pid" && paxel_is_uint "$hb" && [ "${#hb}" -le 12 ] || return 1
  stale=$(_paxel_push_uint_env PAXEL_LOCK_STALE_SECS 300)
  now=$(paxel_now_epoch)
  [ $((now - hb)) -lt "$stale" ] || return 1
  if [ "$host" = "$(_paxel_push_host)" ]; then
    kill -0 "$pid" 2>/dev/null
  fi
}

# Takeovers are serialized by a second mkdir, and a stale lock directory is
# never removed: only its owner file is replaced. Removing it would let a
# plain mkdir acquirer slip in between the rm and our own mkdir.
_paxel_push_lock_takeover() {
  local mutex="${PAXEL_PUSH_DIR}/lock.takeover" rc=1 age before
  if [ -d "$mutex" ]; then
    age=$(( $(paxel_now_epoch) - $(_paxel_mtime "$mutex") ))
    [ "$age" -lt 60 ] || rmdir "$mutex" 2>/dev/null || true
  fi
  mkdir "$mutex" 2>/dev/null || return 1
  if [ ! -d "$PAXEL_PUSH_LOCK_DIR" ]; then
    if mkdir "$PAXEL_PUSH_LOCK_DIR" 2>/dev/null && _paxel_push_write_owner; then rc=0; fi
  else
    before=$(head -n 1 "${PAXEL_PUSH_LOCK_DIR}/owner" 2>/dev/null || true)
    if ! paxel_push_lock_alive \
       && [ "$(head -n 1 "${PAXEL_PUSH_LOCK_DIR}/owner" 2>/dev/null || true)" = "$before" ] \
       && _paxel_push_write_owner; then
      rc=0
      paxel_log "push lock_takeover"
    fi
  fi
  rmdir "$mutex" 2>/dev/null || true
  return "$rc"
}

# Status 0: lock taken. 1: a live worker holds it. 2: the lock cannot be created.
paxel_push_lock_acquire() {
  mkdir -p "$PAXEL_PUSH_DIR" 2>/dev/null || return 2
  # A failed mkdir of the lock below reads as "held" otherwise (a push folder
  # left root-owned by sudo, a read-only home).
  [ -w "$PAXEL_PUSH_DIR" ] || return 2
  if mkdir "$PAXEL_PUSH_LOCK_DIR" 2>/dev/null; then
    if ! _paxel_push_write_owner; then
      rm -rf "$PAXEL_PUSH_LOCK_DIR"
      return 2
    fi
  elif paxel_push_lock_alive || ! _paxel_push_lock_takeover; then
    return 1
  fi
  PAXEL_PUSH_LOCK_HELD=1
  _paxel_push_heartbeat_start
  return 0
}

paxel_push_lock_release() {
  [ "$PAXEL_PUSH_LOCK_HELD" = 1 ] || return 0
  # Stop the heartbeat first: a refresh racing the rm could recreate the
  # owner file inside a lock another worker has just taken.
  _paxel_push_heartbeat_stop
  if _paxel_push_lock_owned; then
    rm -rf "$PAXEL_PUSH_LOCK_DIR"
  fi
  PAXEL_PUSH_LOCK_HELD=0
}

# Single git calls and scrubs can outlast the stale threshold, so the
# heartbeat runs beside the push instead of between its steps.
_paxel_push_heartbeat_start() {
  local secs
  secs=$(_paxel_push_uint_env PAXEL_LOCK_HEARTBEAT_SECS 30)
  [ "$secs" -ge 1 ] || secs=1
  (
    trap - ERR EXIT
    while sleep "$secs"; do
      kill -0 "$$" 2>/dev/null || exit 0
      _paxel_push_lock_owned || exit 0
      _paxel_push_write_owner || exit 0
    done
  ) </dev/null >/dev/null 2>&1 &
  PAXEL_PUSH_HEARTBEAT_PID=$!
}

_paxel_push_heartbeat_stop() {
  [ -n "$PAXEL_PUSH_HEARTBEAT_PID" ] || return 0
  kill "$PAXEL_PUSH_HEARTBEAT_PID" 2>/dev/null || true
  wait "$PAXEL_PUSH_HEARTBEAT_PID" 2>/dev/null || true
  PAXEL_PUSH_HEARTBEAT_PID=""
}

# ---- Command ----

paxel_cmd_push() {
  local mode=now
  while [ $# -gt 0 ]; do
    case "$1" in
      --now) mode=now ;;
      --worker) mode=worker ;;
      -h|--help)
        paxel_say "Usage: paxel push [--now]"
        paxel_say "  Copies new agent sessions on this machine to your transcript store, with known credential formats removed and the data of pasted, tool and generated images replaced."
        paxel_say "  --now  push right away; if a push is already running, wait for it first"
        return 0
        ;;
      *)
        paxel_say "Unknown option for paxel push: $1"
        paxel_say "Usage: paxel push [--now]"
        return 2
        ;;
    esac
    shift
  done

  _PXP_HOST=$(hostname 2>/dev/null || uname -n 2>/dev/null || echo unknown)
  _paxel_stat_is_gnu || true
  mkdir -p "$PAXEL_PUSH_DIR" 2>/dev/null || true
  chmod 700 "$PAXEL_HOME_DIR" 2>/dev/null || true
  # Hook-started workers are the only launcher runs on most boxes, so this is
  # where a newer launcher text reaches them.
  paxel_refresh_launcher
  trap '_paxel_push_on_exit' EXIT
  trap 'exit 143' TERM
  trap 'exit 130' INT

  if [ "$mode" = worker ]; then
    _paxel_push_worker || true
    return 0
  fi
  _paxel_push_now || return $?
}

_paxel_push_on_exit() {
  paxel_push_lock_release
  if [ -n "$_PXP_WORK" ]; then rm -rf "$_PXP_WORK"; fi
  if [ -n "${_RMDC_LOG_FILE:-}" ]; then rm -f "$_RMDC_LOG_FILE"; fi
  return 0
}

_paxel_push_worker() {
  local loops=0 max_loops rc
  max_loops=$(_paxel_push_uint_env PAXEL_PUSH_MAX_LOOPS 20)
  renice -n 10 -p $$ >/dev/null 2>&1 || true
  while :; do
    rc=0
    paxel_push_lock_acquire || rc=$?
    if [ "$rc" -ne 0 ]; then
      [ "$rc" -eq 1 ] || paxel_log "push lock_unavailable"
      return 0
    fi
    while :; do
      # A run that crashed leaves its marker, which would show this wait as a push.
      rm -f "$PAXEL_PUSH_DIR/running" 2>/dev/null || true
      _paxel_push_debounce || true
      rm -f "$PAXEL_PUSH_DIR/pending" "$PAXEL_PUSH_DIR/first_pending" "$PAXEL_PUSH_DIR/now_requested" 2>/dev/null || true
      paxel_push_run || true
      loops=$((loops + 1))
      [ "$loops" -lt "$max_loops" ] || break
      _paxel_push_has_trigger || break
    done
    paxel_push_lock_release
    [ "$loops" -lt "$max_loops" ] || return 0
    # A hook that fired after the last check saw a live worker and started
    # none, so look once more after letting go of the lock.
    _paxel_push_has_trigger || return 0
  done
}

# Waits until no trigger arrived for PAXEL_DEBOUNCE_SECS, or
# PAXEL_DEBOUNCE_MAX_SECS passed since the first one. Quiet is judged by
# polling the marker's mtime once a second, because mtimes and epochs have
# one-second resolution.
_paxel_push_debounce() {
  local quiet max waited=0 quiet_for=0 seen="" m first now
  quiet=$(_paxel_push_quiet_secs)
  max=$(_paxel_push_max_wait_secs)
  while :; do
    _paxel_push_has_trigger || return 0
    [ ! -e "$PAXEL_PUSH_DIR/now_requested" ] || return 0
    ! _paxel_push_off || return 0
    m=$(_paxel_mtime "$PAXEL_PUSH_DIR/pending")
    now=$(paxel_now_epoch)
    if [ "$m" = "$seen" ]; then quiet_for=$((quiet_for + 1)); else quiet_for=0; seen="$m"; fi
    [ "$quiet_for" -lt "$quiet" ] || return 0
    [ $((now - m)) -le "$quiet" ] || return 0
    first=$(_paxel_mtime "$PAXEL_PUSH_DIR/first_pending")
    [ "$first" != 0 ] || first="$m"
    [ $((now - first)) -lt "$max" ] || return 0
    [ "$waited" -lt "$max" ] || return 0
    sleep 1
    waited=$((waited + 1))
  done
}

_paxel_push_quiet_secs() { _paxel_push_uint_env PAXEL_DEBOUNCE_SECS 60; }
_paxel_push_max_wait_secs() { _paxel_push_uint_env PAXEL_DEBOUNCE_MAX_SECS 600; }

# The epoch at which the debounce stops waiting for the triggers so far: quiet
# after the last one, or the max wait after the first, whichever is sooner.
paxel_push_expected_start() {
  local m first quiet_end max_end
  m=$(_paxel_mtime "$PAXEL_PUSH_DIR/pending")
  first=$(_paxel_mtime "$PAXEL_PUSH_DIR/first_pending")
  [ "$first" != 0 ] || first="$m"
  quiet_end=$((m + $(_paxel_push_quiet_secs)))
  max_end=$((first + $(_paxel_push_max_wait_secs)))
  if [ "$max_end" -lt "$quiet_end" ]; then printf '%s\n' "$max_end"; else printf '%s\n' "$quiet_end"; fi
}

_paxel_push_now() {
  local timeout poll waited=0 rc said=0 before="" others=0 other="that was already running"
  timeout=$(_paxel_push_uint_env PAXEL_PUSH_NOW_TIMEOUT 900)
  poll=$(_paxel_push_uint_env PAXEL_PUSH_NOW_POLL_SECS 2)
  [ "$poll" -ge 1 ] || poll=1
  while :; do
    rc=0
    paxel_push_lock_acquire || rc=$?
    [ "$rc" -ne 0 ] || break
    if [ "$rc" -ne 1 ]; then
      paxel_say "Push did not run: could not create the lock directory $PAXEL_PUSH_LOCK_DIR. Check that $PAXEL_HOME_DIR exists and is writable by you."
      return 1
    fi
    if [ "$said" -eq 0 ]; then
      before=$(_paxel_push_total)
      if [ -e "$PAXEL_PUSH_DIR/running" ]; then
        paxel_say "Another push is running on this machine. Waiting for it to finish..."
      else
        paxel_say "A push was waiting for agent activity to stop. Starting it now..."
        other="that was waiting"
      fi
      # Tells a debouncing worker to push now instead of waiting for quiet.
      touch "$PAXEL_PUSH_DIR/now_requested" 2>/dev/null || true
      said=1
    fi
    if [ "$waited" -ge "$timeout" ]; then
      rm -f "$PAXEL_PUSH_DIR/now_requested" 2>/dev/null || true
      paxel_say "Gave up after ${waited}s: the other push is still running. It keeps going on its own; run 'paxel push --now' again to confirm everything reached the store."
      return 1
    fi
    sleep "$poll"
    waited=$((waited + poll))
    if [ $((waited % 30)) -lt "$poll" ]; then paxel_say "Still waiting (${waited}s)..."; fi
  done
  rm -f "$PAXEL_PUSH_DIR/pending" "$PAXEL_PUSH_DIR/first_pending" "$PAXEL_PUSH_DIR/now_requested" 2>/dev/null || true
  if [ -n "$before" ]; then
    others=$(( $(_paxel_push_total) - before ))
    [ "$others" -ge 0 ] || others=0
  fi
  rc=0
  _PXP_SHOW_PROGRESS=1
  _PXP_NOW=1
  paxel_push_run || rc=$?
  paxel_push_lock_release
  # A hook that fired during this push saw the lock held and started no
  # worker, so start one, as the worker loop looks again after letting go.
  if _paxel_push_has_trigger; then _paxel_push_start_worker; fi
  _paxel_push_report "$others" "$other"
  return "$rc"
}

# Starts a detached `push --worker` through the launcher, the way a hook does.
_paxel_push_start_worker() {
  local launcher="$PAXEL_HOME_DIR/bin/paxel" log
  [ -x "$launcher" ] || return 0
  mkdir -p "$PAXEL_HOME_DIR/logs" 2>/dev/null || return 0
  log="$PAXEL_HOME_DIR/logs/push-$(date -u +%Y%m%d).log"
  [ ! -L "$log" ] || return 0
  if command -v setsid >/dev/null 2>&1; then
    setsid "$launcher" push --worker </dev/null >>"$log" 2>&1 &
  else
    nohup "$launcher" push --worker </dev/null >>"$log" 2>&1 &
  fi
  return 0
}

# How many sessions pushes from this home have written, so `push --now` can
# say what the push it waited for wrote. Only lock holders add to it.
_paxel_push_total() {
  local n=""
  { read -r n < "$PAXEL_PUSH_DIR/sessions_total"; } 2>/dev/null || true
  if ! paxel_is_uint "$n" || [ "${#n}" -gt 15 ]; then n=0; fi
  printf '%s\n' "$n"
}

_paxel_push_total_add() {
  local tmp="$PAXEL_PUSH_DIR/sessions_total.tmp.$$"
  [ "$1" -gt 0 ] || return 0
  printf '%s\n' "$(( $(_paxel_push_total) + $1 ))" > "$tmp" 2>/dev/null \
    && mv -f "$tmp" "$PAXEL_PUSH_DIR/sessions_total" 2>/dev/null || rm -f "$tmp"
}

# ---- One push run. The caller holds the lock. ----

_paxel_push_reset() {
  _PXP_RESULT=""
  _PXP_ERROR=""
  _PXP_DETAIL=""
  _PXP_WARNINGS=""
  _PXP_WRITTEN=0
  _PXP_REMAINING=0
  _PXP_TOO_LARGE=""
  _PXP_SCRUB_FAILED=""
  _PXP_FAIL_REASON=""
  _PXP_FLOOR=""
  _PXP_OUTSIDE=0
  _PXP_QUARANTINED_NEW=""
  _PXP_STORE=""
  _PXP_BRANCH=""
  _PXP_BOX=""
  _PXP_BOX_NAME=""
  _PXP_DIGEST=""
  _PXP_CLONE="$PAXEL_STORE_CLONE_DIR"
  _PXP_TIP=""
  _PXP_PUSHED=0
  _PXP_UNIT_SEQ=0
  _PXP_CHUNK_BYTES=0
  _PXP_CHUNK_LIMIT=$(_paxel_push_uint_env PAXEL_PUSH_CHUNK_BYTES 16777216)
  _PXP_PUSHED_BYTES=0
  _PXP_PLAN_SESSIONS=0
  _PXP_PLAN_BYTES=0
  _PXP_WATCHDOG_OFF_AT=""
  _PXP_MAX_BYTES=$(_paxel_push_uint_env PAXEL_PUSH_MAX_BYTES 99614720)
}

paxel_push_run() {
  local started
  started=$(paxel_now_epoch)
  _paxel_push_reset
  mkdir -p "$PAXEL_PUSH_DIR" 2>/dev/null || true
  printf '%s\n' "$started" > "$PAXEL_PUSH_DIR/running" 2>/dev/null || true
  find "$PAXEL_PUSH_DIR" -maxdepth 1 -name 'run.*' -mmin +1440 -exec rm -rf {} + 2>/dev/null || true
  _paxel_push_run_steps || true
  if [ -n "$_PXP_WORK" ]; then rm -rf "$_PXP_WORK"; fi
  _PXP_WORK=""
  _PXP_RESULT=$(_paxel_push_result)
  _paxel_push_write_last
  rm -f "$PAXEL_PUSH_DIR/running" 2>/dev/null || true
  _paxel_push_total_add "$_PXP_WRITTEN"
  paxel_log "push result=${_PXP_RESULT} sessions=${_PXP_WRITTEN} error=${_PXP_ERROR:-none} secs=$(( $(paxel_now_epoch) - started ))"
  [ "$_PXP_RESULT" != error ]
}

_paxel_push_run_steps() {
  local reason
  if _paxel_push_off; then
    _PXP_RESULT=off
    return 0
  fi
  # A saved store keeps store_missing_at while its seed is unfinished, and
  # push then goes on to its own marker check when the retry cannot finish it.
  if [ -z "$(paxel_config_get store_host)" ] || [ -z "$(paxel_config_get store_name)" ] ||
     [ -n "$(paxel_config_get store_missing_at)" ]; then
    _paxel_push_store_retry || true
    if [ -z "$(paxel_config_get store_host)" ] || [ -z "$(paxel_config_get store_name)" ]; then
      _PXP_RESULT=skipped
      _PXP_ERROR=store_not_configured
      return 0
    fi
  fi
  _PXP_STORE=$(paxel_store_display 2>/dev/null || true)
  # An empty display would read as a new store and drop the local push state.
  if [ -z "$_PXP_STORE" ]; then
    _PXP_ERROR=store_not_configured
    return 1
  fi
  # A floor that is not a time could let older history through.
  _PXP_FLOOR=$(paxel_config_get history_since)
  if [ -n "$_PXP_FLOOR" ] && { ! paxel_is_uint "$_PXP_FLOOR" || [ "${#_PXP_FLOOR}" -gt 12 ]; }; then
    _PXP_ERROR=history_invalid
    return 1
  fi
  if ! command -v git >/dev/null 2>&1; then
    _PXP_ERROR=git_missing
    return 1
  fi
  if ! reason=$(paxel_scrub_ready 2>&1 >/dev/null); then
    _PXP_ERROR=scrub_unavailable
    _PXP_DETAIL=$(printf '%s' "$reason" | head -n 1)
    return 1
  fi
  _PXP_DIGEST=$(paxel_scrub_digest 2>/dev/null || true)
  if [ -z "$_PXP_DIGEST" ]; then
    _PXP_ERROR=scrub_unavailable
    _PXP_DETAIL="the scrub program has no version trailer"
    return 1
  fi
  _PXP_BRANCH=$(paxel_config_get store_branch)
  [ -n "$_PXP_BRANCH" ] || _PXP_BRANCH=main
  if ! _paxel_store_valid_branch "$_PXP_BRANCH"; then
    _PXP_ERROR=store_not_configured
    return 1
  fi
  _PXP_BOX=$(paxel_box_id)
  _PXP_BOX_NAME=$(_paxel_push_host)
  if ! _PXP_WORK=$(mktemp -d "${PAXEL_PUSH_DIR}/run.XXXXXX" 2>/dev/null); then
    _PXP_WORK=""
    _paxel_push_local_error workdir
    return 1
  fi
  mkdir -p "$_PXP_WORK/u"
  : > "$_PXP_WORK/chunk.units"
  : > "$_PXP_WORK/free.state"
  : > "$_PXP_WORK/repos.tsv"
  : > "$_PXP_WORK/scrub_failed.new"

  _paxel_push_store_identity
  _paxel_push_visibility_gate || return 1
  _paxel_push_ensure_clone || return 1
  _paxel_push_fetch || return 1
  _paxel_push_check_marker || return 1
  _paxel_push_store_seeded
  _paxel_push_check_digest
  if ! _paxel_push_reconcile; then
    _paxel_push_local_error store_copy
    return 1
  fi
  if ! _paxel_push_plan; then
    _paxel_push_local_error scan
    return 1
  fi
  if _paxel_push_in_parts; then
    paxel_say "Pushing $_PXP_PLAN_SESSIONS sessions ($(_paxel_push_mb "$_PXP_PLAN_BYTES") MB) to $_PXP_STORE in parts of about $(_paxel_push_mb "$_PXP_CHUNK_LIMIT") MB. Each part shows up in the store as it lands."
  fi
  if ! _paxel_push_sessions; then
    _paxel_push_scrub_failed_save
    return 1
  fi
  _paxel_push_scrub_failed_save
  _paxel_push_git_snapshots || return 1
  _paxel_push_flush || return 1
  _paxel_push_state_merge "$_PXP_WORK/free.state"
  _paxel_push_compact
  return 0
}

# Setup found no store (no gh or glab login yet, a network error, a failed
# create), so push runs setup's store step again, without a prompt: at most
# once an hour from the worker, every time from push --now. A user's no to
# setup's question is never asked again.
_paxel_push_store_retry() {
  local out rc=0 next
  [ -n "$(paxel_config_get setup_at)" ] && [ -n "$(paxel_config_get store_missing_at)" ] || return 1
  [ -z "$(paxel_config_get store_declined_at)" ] || return 1
  # A PAXEL_STORE in the agents' environment names a store (or none) that
  # the convention lookup must not replace.
  [ "${PAXEL_STORE+set}" != set ] || [ -n "$(_paxel_setup_saved_store)" ] || return 1
  if [ "$_PXP_NOW" != 1 ] && next=$(paxel_store_retry_next) && [ "$(paxel_now_epoch)" -lt "$next" ]; then
    return 1
  fi
  paxel_config_set store_retry_at "$(paxel_now_iso)" || return 1
  out=$( (unset PAXEL_STORE; _paxel_setup_store 1) 2>&1 ) || rc=$?
  [ "$_PXP_NOW" != 1 ] || [ -z "$out" ] || printf '%s\n' "$out" >&2
  if [ "$rc" -ne 0 ] || [ -z "$(_paxel_setup_saved_store)" ] || [ -n "$(paxel_config_get store_missing_at)" ]; then
    paxel_log "push store_retry result=missing"
    return 1
  fi
  paxel_log "push store_retry result=found"
}

# The marker proves the seed is done, also when the lookup that would have
# said so failed, so a working store stops the hourly retry.
_paxel_push_store_seeded() {
  [ -n "$(paxel_config_get store_missing_at)" ] || return 0
  _paxel_setup_config_clear store_missing_at
  _paxel_setup_config_clear store_retry_at
  paxel_log "push store_retry cleared=marker"
}

# The epoch after which push looks for a missing store again, or status 1
# when it never looked (or the time is unreadable), so it looks now.
paxel_store_retry_next() {
  local last
  last=$(paxel_iso_epoch "$(paxel_config_get store_retry_at)") || return 1
  printf '%s\n' "$((last + PAXEL_STORE_RETRY_SECS))"
}

_paxel_push_result() {
  if [ -n "$_PXP_RESULT" ]; then
    printf '%s\n' "$_PXP_RESULT"
  elif [ -n "$_PXP_ERROR" ]; then
    echo error
  elif [ -n "$_PXP_SCRUB_FAILED" ] || [ -n "$(_paxel_push_too_large_list)" ] || [ -n "$(_paxel_push_quarantined_list)" ]; then
    echo partial
  else
    echo ok
  fi
}

# A failed local step (disk full, no permission). STEP names it in the log
# and picks the message.
_paxel_push_local_error() {
  _PXP_ERROR=local_io
  _PXP_DETAIL="$1"
  paxel_log "push local_io step=$1"
}

# Sessions with a file left out for its size: the ones found this run, and
# the ones recorded in state.tsv by earlier runs whose files are still there.
_paxel_push_too_large_list() {
  {
    awk -F '\t' '$4 == "too_large" { n = split($5, p, "/"); if (n >= 4) print p[2] "/" p[3] }' \
      "$PAXEL_PUSH_DIR/state.tsv" 2>/dev/null || true
    printf '%s' "$_PXP_TOO_LARGE"
  } | awk 'NF && !seen[$0]++'
}

# Quarantined sessions, plus this box's git snapshots the host rejected
# (skipped until that repo's HEAD moves).
_paxel_push_quarantined_list() {
  {
    cut -f1 "$PAXEL_PUSH_DIR/quarantine.tsv" 2>/dev/null || true
    awk -F '\t' -v b="$_PXP_BOX" '$1 == b { print "git/" $2 }' "$PAXEL_PUSH_DIR/git_rejected.tsv" 2>/dev/null || true
    printf '%s' "$_PXP_QUARANTINED_NEW"
  } | awk 'NF && !seen[$0]++'
}

# Push state belongs to one store: offsets, snapshot heads and quarantines
# describe what that store holds, so a different store starts over.
_paxel_push_store_identity() {
  local id stored
  id="${_PXP_STORE}#${_PXP_BRANCH}"
  stored=$(head -n 1 "$PAXEL_PUSH_DIR/store_id" 2>/dev/null || true)
  [ "$stored" != "$id" ] || return 0
  rm -rf "$_PXP_CLONE"
  rm -f "$PAXEL_PUSH_DIR/state.tsv" "$PAXEL_PUSH_DIR/git_heads.tsv" "$PAXEL_PUSH_DIR/quarantine.tsv" \
    "$PAXEL_PUSH_DIR/git_rejected.tsv" "$PAXEL_PUSH_DIR/visibility" "$PAXEL_PUSH_DIR/scrub_digest" \
    "$PAXEL_PUSH_DIR/scrub_failed.tsv"
  printf '%s\n' "$id" > "$PAXEL_PUSH_DIR/store_id"
}

_paxel_push_record_visibility() {
  local tmp="$PAXEL_PUSH_DIR/visibility.tmp.$$"
  case "${1:-}" in private|internal|public) ;; *) return 1 ;; esac
  mkdir -p "$PAXEL_PUSH_DIR" 2>/dev/null || return 1
  printf '%s\t%s\n' "$(paxel_now_epoch)" "$1" > "$tmp" 2>/dev/null || return 1
  mv "$tmp" "$PAXEL_PUSH_DIR/visibility"
}

# A private answer is trusted for a day. Anything but private stops pushes,
# and is asked again on every run (pushes are stopped anyway), so a store
# made private again resumes on the next push. An unknown answer (rate
# limit, 5xx, timeout) is not a check: the push goes ahead and the next run
# asks again, unless the last definite answer was not private.
_paxel_push_visibility_gate() {
  local line at value now vis
  line=$(head -n 1 "$PAXEL_PUSH_DIR/visibility" 2>/dev/null || true)
  at=${line%%"$_PXP_TAB"*}
  value=${line#*"$_PXP_TAB"}
  now=$(paxel_now_epoch)
  if [ "$value" = private ] && paxel_is_uint "$at" && [ "${#at}" -le 12 ] \
     && [ $((now - at)) -ge 0 ] && [ $((now - at)) -lt 86400 ]; then
    return 0
  fi
  vis=$(paxel_store_visibility 2>/dev/null || true)
  case "$vis" in
    private)
      _paxel_push_record_visibility private || true
      return 0
      ;;
    public|internal)
      _paxel_push_record_visibility "$vis" || true
      _PXP_ERROR=store_not_private
      _PXP_DETAIL="$vis"
      return 1
      ;;
  esac
  case "$value" in
    public|internal)
      _PXP_ERROR=store_not_private
      _PXP_DETAIL="$value"
      return 1
      ;;
  esac
  _PXP_WARNINGS="${_PXP_WARNINGS}visibility_unchecked"$'\n'
  paxel_log "push visibility_unchecked"
  return 0
}

# State says what this box already pushed. A store deleted and made again
# under the same name, or a session folder removed by hand, no longer holds
# it, so rows whose store path is missing from the tip are dropped and their
# files pushed again in full. Rows for files over the size limit never had a
# store path and are kept.
_paxel_push_reconcile() {
  local tip_paths="$_PXP_WORK/tip_paths" state="$PAXEL_PUSH_DIR/state.tsv" heads="$PAXEL_PUSH_DIR/git_heads.tsv"
  local tmp before after
  if ! _paxel_local_git -C "$_PXP_CLONE" ls-tree -r --name-only "$_PXP_TIP" -- sessions "git/$_PXP_BOX/meta" \
       > "$tip_paths" 2>/dev/null; then
    return 1
  fi
  if [ -s "$state" ]; then
    tmp="$state.tmp.$$"
    before=$(wc -l < "$state" | tr -d ' ')
    awk -F '\t' 'FILENAME == ARGV[1] { t[$0] = 1; next } $4 == "too_large" || ($5 in t)' \
      "$tip_paths" "$state" > "$tmp" && mv "$tmp" "$state" || return 1
    after=$(wc -l < "$state" | tr -d ' ')
    [ "$before" = "$after" ] || paxel_log "push store_missing_files rows=$((before - after))"
  fi
  if [ -s "$heads" ]; then
    tmp="$heads.tmp.$$"
    awk -F '\t' -v b="$_PXP_BOX" 'FILENAME == ARGV[1] { t[$0] = 1; next } $1 != b || (("git/" b "/meta/" $2 ".json") in t)' \
      "$tip_paths" "$heads" > "$tmp" && mv "$tmp" "$heads" || return 1
  fi
}

_paxel_push_classify_remote_error() {
  if grep -qiE "remote branch .* not found|couldn't find remote ref" "$1" 2>/dev/null; then
    _PXP_ERROR=not_a_paxel_store
  elif grep -qiE 'authentication|permission denied|could not read (username|password)|repository not found|access denied|returned error: 40[13]' "$1" 2>/dev/null; then
    _PXP_ERROR=store_access_denied
  else
    _PXP_ERROR=store_unreachable
  fi
}

_paxel_push_ensure_clone() {
  local url tmp err="$_PXP_WORK/clone.err"
  if ! url=$(paxel_store_url 2>/dev/null) || [ -z "$url" ]; then
    _PXP_ERROR=store_not_configured
    return 1
  fi
  if [ -f "$_PXP_CLONE/HEAD" ] && _paxel_local_git -C "$_PXP_CLONE" rev-parse --is-bare-repository >/dev/null 2>&1; then
    if ! _paxel_local_git -C "$_PXP_CLONE" config remote.origin.url "$url"; then
      _paxel_push_local_error store_copy
      return 1
    fi
    return 0
  fi
  tmp="${_PXP_CLONE}.tmp.$$"
  rm -rf "$_PXP_CLONE" "$tmp"
  if ! paxel_store_git clone --quiet --bare --depth 1 --filter=blob:none --single-branch \
       --branch "$_PXP_BRANCH" -- "$url" "$tmp" >/dev/null 2>"$err"; then
    rm -rf "$tmp"
    _paxel_push_classify_remote_error "$err"
    return 1
  fi
  # Bitmaps cannot be written in a partial clone, and a background auto-gc
  # would race the worker's own prune.
  _paxel_local_git -C "$tmp" config repack.writeBitmaps false || true
  _paxel_local_git -C "$tmp" config gc.auto 0 || true
  if ! mv "$tmp" "$_PXP_CLONE"; then
    rm -rf "$tmp"
    _paxel_push_local_error store_copy
    return 1
  fi
}

_paxel_push_fetch() {
  local err="$_PXP_WORK/fetch.err"
  if ! paxel_store_git -C "$_PXP_CLONE" fetch --quiet --depth 1 --filter=blob:none origin \
       "+refs/heads/${_PXP_BRANCH}:refs/heads/${_PXP_BRANCH}" >/dev/null 2>"$err"; then
    _paxel_push_classify_remote_error "$err"
    return 1
  fi
  if ! _PXP_TIP=$(_paxel_local_git -C "$_PXP_CLONE" rev-parse --verify --quiet "refs/heads/${_PXP_BRANCH}^{commit}" 2>/dev/null) \
     || [ -z "$_PXP_TIP" ]; then
    _PXP_ERROR=store_unreachable
    return 1
  fi
}

# The marker stops a mistyped store from receiving transcripts. It is
# untrusted input: only a jq-checked integer reaches the shell.
_paxel_push_check_marker() {
  local entry marker="$_PXP_WORK/marker.json" v
  entry=$(_paxel_local_git -C "$_PXP_CLONE" ls-tree "$_PXP_TIP" -- paxel-store.json 2>/dev/null || true)
  if [ -z "$entry" ]; then
    _PXP_ERROR=not_a_paxel_store
    return 1
  fi
  case "$entry" in
    "100644 blob "*) ;;
    *) _PXP_ERROR=store_marker_invalid; return 1 ;;
  esac
  if ! paxel_store_git -C "$_PXP_CLONE" cat-file blob "${_PXP_TIP}:paxel-store.json" > "$marker" 2>/dev/null; then
    _PXP_ERROR=store_unreachable
    return 1
  fi
  if ! v=$(paxel_json_int "$marker" '.schema_version'); then
    _PXP_ERROR=store_marker_invalid
    return 1
  fi
  [ "$v" != "$PAXEL_STORE_SCHEMA_VERSION" ] || return 0
  if [ "${#v}" -le 9 ] && [ "$v" -gt "$PAXEL_STORE_SCHEMA_VERSION" ]; then
    _PXP_ERROR=store_schema_newer
  else
    _PXP_ERROR=store_marker_invalid
  fi
  return 1
}

# Lines pushed under another scrub version are not appended to: each such
# file is scrubbed again in full the next time its session changes.
_paxel_push_check_digest() {
  local f="$PAXEL_PUSH_DIR/scrub_digest" state="$PAXEL_PUSH_DIR/state.tsv" old tmp
  old=$(head -n 1 "$f" 2>/dev/null || true)
  if [ -n "$old" ] && [ "$old" != "$_PXP_DIGEST" ] && [ -s "$state" ]; then
    tmp="$state.tmp.$$"
    awk -F '\t' -v OFS='\t' '$4 != "too_large" { $4 = "rescrub" } { print }' "$state" > "$tmp" && mv "$tmp" "$state"
    paxel_log "push scrub_version_changed"
  fi
  printf '%s\n' "$_PXP_DIGEST" > "$f"
}

# ---- Change detection ----

# NUL-separated paths on stdin -> "size<TAB>mtime<TAB>path" lines.
_paxel_push_stat() {
  if _paxel_stat_is_gnu; then
    xargs -0 stat -c "%s${_PXP_TAB}%Y${_PXP_TAB}%n" 2>/dev/null || true
  else
    xargs -0 stat -f '%z%t%m%t%N' 2>/dev/null || true
  fi
}

# Lists this machine's session files in SCANNED, one per line: tool sid
# rel src size mtime. Links below the agent dirs are never followed, and
# names that are unsafe in a store path are skipped.
_paxel_push_scan() {
  local scanned="$1" raw="$1.raw" claude_dir codex_dir
  claude_dir="${CLAUDE_DIR:-$HOME/.claude/projects}"
  claude_dir="${claude_dir%/}"
  codex_dir="${CODEX_DIR:-$HOME/.codex/sessions}"
  codex_dir="${codex_dir%/}"
  : > "$raw"
  if [ -d "$claude_dir" ]; then
    { find -H "$claude_dir" -mindepth 2 -maxdepth 2 -type f -name '*.jsonl' -print0 2>/dev/null || true; } \
      | _paxel_push_stat | LC_ALL=C sort -t "$_PXP_TAB" -k3 | awk '{ print "M\t" $0 }' >> "$raw"
    { find -H "$claude_dir" -mindepth 4 -maxdepth 4 -type f -path '*/subagents/agent-*.jsonl' -print0 2>/dev/null || true; } \
      | _paxel_push_stat | LC_ALL=C sort -t "$_PXP_TAB" -k3 | awk '{ print "S\t" $0 }' >> "$raw"
  fi
  if [ -d "$codex_dir" ]; then
    { find -H "$codex_dir" -maxdepth 6 -type f -name 'rollout-*.jsonl' -print0 2>/dev/null || true; } \
      | _paxel_push_stat | LC_ALL=C sort -t "$_PXP_TAB" -k3 | awk '{ print "X\t" $0 }' >> "$raw"
  fi

  awk -F '\t' -v OFS='\t' -v cdir="$claude_dir" -v xdir="$codex_dir" '
    function ok(n) { return n ~ /^[A-Za-z0-9._-]+$/ && n != "." && n != ".." }
    NF != 4 || $2 !~ /^[0-9]+$/ || $3 !~ /^[0-9]+$/ { next }
    $1 == "M" || $1 == "S" {
      if (index($4, cdir "/") != 1) next
      n = split(substr($4, length(cdir) + 2), p, "/")
      if ($1 == "M") {
        if (n != 2 || p[2] !~ /\.jsonl$/) next
        sid = substr(p[2], 1, length(p[2]) - 6)
        # One session id in two project dirs: the first by path wins, so
        # the choice is stable from run to run.
        if (!ok(sid) || (sid in owner)) next
        owner[sid] = p[1]
        print "claude", sid, sid ".jsonl", $4, $2, $3
      } else {
        if (n != 4 || p[3] != "subagents" || p[4] !~ /^agent-.*\.jsonl$/ || !ok(p[4])) next
        if (!(p[2] in owner) || owner[p[2]] != p[1]) next
        print "claude", p[2], "subagents/" p[4], $4, $2, $3
      }
      next
    }
    $1 == "X" {
      if (index($4, xdir "/") != 1) next
      n = split($4, p, "/")
      f = p[n]
      if (!ok(f) || f !~ /^rollout-.*\.jsonl$/ || length(f) < 51) next
      u = substr(f, length(f) - 41, 36)
      if (substr(f, length(f) - 42, 1) != "-" || u !~ /^[0-9A-Fa-f-]+$/) next
      if (substr(u, 9, 1) != "-" || substr(u, 14, 1) != "-" || substr(u, 19, 1) != "-" || substr(u, 24, 1) != "-") next
      if (u in seen_codex) next
      seen_codex[u] = 1
      print "codex", u, f, $4, $2, $3
    }
  ' "$raw" > "$scanned" || return 1
  rm -f "$raw"
}

# Writes rows/<tool>.<sid> for each changed session (every file of it, main
# file first: tool sid rel src size mtime changed offset prefix lines
# dropped, "-" when there is no state) and sessions.tsv (tool sid mtime
# pending_bytes bytes, newest first). Sessions last active before the
# history floor (setup --since) are left out.
#
# A session whose scrub failed (scrub_failed.tsv: session bytes mtime digest
# epoch reason) waits, so a failure that repeats is not paid for on every
# push: it is tried again when the scrub program changes, on the next push
# when the file changed while it was read, and otherwise at most once a day,
# then only when the session changed or the reason may pass (a timeout).
_paxel_push_plan() {
  local scanned="$_PXP_WORK/scanned.tsv" kept="$_PXP_WORK/kept.tsv" outside
  local state="$PAXEL_PUSH_DIR/state.tsv" quar="$PAXEL_PUSH_DIR/quarantine.tsv"
  local failed="$PAXEL_PUSH_DIR/scrub_failed.tsv" waiting
  _paxel_push_scan "$scanned" || return 1

  [ -f "$state" ] || : > "$state"
  [ -f "$quar" ] || : > "$quar"
  [ -f "$failed" ] || : > "$failed"
  # A file left out for its size stays listed only while it exists.
  if grep -q "${_PXP_TAB}too_large${_PXP_TAB}" "$state"; then
    awk -F '\t' 'FILENAME == ARGV[1] { live[$4] = 1; next } $4 != "too_large" || ($1 in live)' \
      "$scanned" "$state" > "$state.tmp.$$" && mv "$state.tmp.$$" "$state" || return 1
  fi
  outside=$(_paxel_history_split "$_PXP_FLOOR" "$scanned" "$state" "$kept") || return 1
  _PXP_OUTSIDE=${outside%% *}
  mkdir -p "$_PXP_WORK/rows" || return 1
  awk -F '\t' -v OFS='\t' -v rows="$_PXP_WORK/rows" -v sessions="$_PXP_WORK/sessions.unsorted" \
      -v waiting="$_PXP_WORK/scrub_waiting.tsv" -v digest="$_PXP_DIGEST" -v now="$(paxel_now_epoch)" '
    FILENAME == ARGV[1] { st[$1] = $0; next }
    FILENAME == ARGV[2] { quar[$1] = 1; next }
    FILENAME == ARGV[3] { if (NF == 6) fail[$1] = $0; next }
    {
      key = $1 "/" $2
      bytes[key] += $5
      if (key in quar) next
      sp = "sessions/" key "/" $3
      changed = 1; off = "-"; pre = "-"; ln = "-"; dr = "-"; full = 0
      if ($4 in st) {
        split(st[$4], s, "\t")
        if (s[5] == sp) {
          off = s[3]; pre = s[4]; ln = s[6]; dr = s[7]
          # Same size but a new mtime is a rewrite in place (a user redacting
          # a token with same-length text): scrub it again in full. Rows
          # from before the mtime column count as unchanged.
          if (s[2] == $5) {
            if (s[8] == "" || s[8] == $6 || pre == "too_large") changed = 0
            else { pre = "rescrub"; full = 1 }
          }
        }
      }
      row[++n] = $0 OFS changed OFS off OFS pre OFS ln OFS dr
      rkey[n] = key
      if ($6 + 0 > mt[key] + 0) mt[key] = $6
      if (changed) {
        hot[key] = 1
        pend[key] += (!full && off != "-" && off + 0 <= $5 + 0) ? $5 - off : $5
      }
    }
    END {
      printf "" > waiting
      for (k in hot) {
        if (!(k in fail)) continue
        split(fail[k], fr, "\t")
        if (fr[4] != digest || fr[6] == "file_changed") continue
        if (now - fr[5] >= 86400 && (fr[2] != bytes[k] || fr[3] != mt[k] || fr[6] ~ /^(timeout|killed|memory|local_io|unknown)$/)) continue
        wait[k] = 1
        print fail[k] > waiting
      }
      printf "" > sessions
      for (i = 1; i <= n; i++) {
        if (!(rkey[i] in hot) || (rkey[i] in wait)) continue
        f = rkey[i]
        sub(/\//, ".", f)
        print row[i] >> (rows "/" f)
        close(rows "/" f)
      }
      for (k in hot) {
        if (k in wait) continue
        split(k, kk, "/")
        printf "%s\t%s\t%s\t%.0f\t%.0f\n", kk[1], kk[2], mt[k], pend[k], bytes[k] > sessions
      }
    }
  ' "$state" "$quar" "$failed" "$kept" || return 1
  waiting=$(cut -f1 "$_PXP_WORK/scrub_waiting.tsv")
  if [ -n "$waiting" ]; then
    _PXP_SCRUB_FAILED="${_PXP_SCRUB_FAILED}${waiting}"$'\n'
    paxel_log "push scrub_waiting sessions=$(printf '%s\n' "$waiting" | wc -l | tr -d ' ')"
  fi
  LC_ALL=C sort -t "$_PXP_TAB" -k3,3nr "$_PXP_WORK/sessions.unsorted" > "$_PXP_WORK/sessions.tsv" || return 1
  _PXP_REMAINING=$(awk -F '\t' '{ s += $4 } END { printf "%.0f\n", s }' "$_PXP_WORK/sessions.tsv")
  paxel_is_uint "$_PXP_REMAINING" || _PXP_REMAINING=0
  _PXP_PLAN_BYTES=$_PXP_REMAINING
  _PXP_PLAN_SESSIONS=$(wc -l < "$_PXP_WORK/sessions.tsv" | tr -d ' ')
}

# Copies to KEPT the rows of SCANNED whose session was active at or after
# FLOOR (an epoch; empty keeps every row): its newest file is not older.
# Prints "<sessions> <bytes>" for the sessions left out that STATE has no
# file of, the history this machine keeps to itself.
_paxel_history_split() {
  local floor="$1" scanned="$2" state="$3" kept="$4"
  [ -f "$state" ] || state=/dev/null
  : > "$kept" || return 1
  awk -F '\t' -v floor="$floor" -v kept="$kept" '
    FILENAME == ARGV[1] { st[$1] = 1; next }
    FNR == 1 { pass++ }
    pass == 1 {
      k = $1 "/" $2
      if ($6 + 0 > m[k] + 0) m[k] = $6
      size[k] += $5
      if ($4 in st) pushed[k] = 1
      next
    }
    floor == "" || m[$1 "/" $2] + 0 >= floor + 0 { print > kept }
    END {
      for (k in m) if (floor != "" && m[k] + 0 < floor + 0 && !(k in pushed)) { n++; b += size[k] }
      printf "%d %.0f\n", n, b
    }
  ' "$state" "$scanned" "$scanned"
}

# Keeps the sessions still waiting and adds this run's failures; a session
# that was tried and pushed, or is gone, drops out.
_paxel_push_scrub_failed_save() {
  local f="$PAXEL_PUSH_DIR/scrub_failed.tsv"
  cat "$_PXP_WORK/scrub_waiting.tsv" "$_PXP_WORK/scrub_failed.new" > "$f.tmp.$$" 2>/dev/null \
    && mv "$f.tmp.$$" "$f" 2>/dev/null || rm -f "$f.tmp.$$"
}

# ---- Sessions ----

_paxel_push_sessions() {
  local tool sid mt pend bytes rc started
  while IFS="$_PXP_TAB" read -r tool sid mt pend bytes <&3; do
    if ! _paxel_push_lock_owned; then
      _PXP_ERROR=lock_lost
      return 1
    fi
    paxel_is_uint "$pend" && [ "${#pend}" -le 15 ] || pend=0
    _paxel_push_make_room "$pend" || return 1
    rc=0
    _PXP_FAIL_REASON=unknown
    started=$(paxel_now_epoch)
    _paxel_push_session "$tool" "$sid" "$mt" || rc=$?
    case "$rc" in
      0) _PXP_CHUNK_BYTES=$((_PXP_CHUNK_BYTES + pend)) ;;
      4) ;;
      2)
        _PXP_SCRUB_FAILED="${_PXP_SCRUB_FAILED}${tool}/${sid}"$'\n'
        printf '%s/%s\t%s\t%s\t%s\t%s\t%s\n' "$tool" "$sid" "$bytes" "$mt" "$_PXP_DIGEST" "$(paxel_now_epoch)" "$_PXP_FAIL_REASON" \
          >> "$_PXP_WORK/scrub_failed.new"
        paxel_log "push scrub_failed session=${tool}/${sid} reason=${_PXP_FAIL_REASON} bytes=${bytes} secs=$(( $(paxel_now_epoch) - started ))"
        ;;
      *) [ -n "$_PXP_ERROR" ] || _paxel_push_local_error stage; return 1 ;;
    esac
    if [ "$pend" -le "$_PXP_REMAINING" ]; then
      _PXP_REMAINING=$((_PXP_REMAINING - pend))
    fi
  done 3< "$_PXP_WORK/sessions.tsv"
}

# Pushes the part first when it holds something and BYTES more would take it
# past PAXEL_PUSH_CHUNK_BYTES, so only an item larger than that on its own
# makes a part larger. Parts count raw bytes: an append to a pushed file goes
# out as a delta against the copy the store has.
_paxel_push_make_room() {
  [ -s "$_PXP_WORK/chunk.units" ] && [ $((_PXP_CHUNK_BYTES + $1)) -gt "$_PXP_CHUNK_LIMIT" ] || return 0
  _paxel_push_flush
}

_paxel_push_in_parts() {
  [ "$_PXP_SHOW_PROGRESS" = 1 ] && [ "$_PXP_PLAN_SESSIONS" -gt 1 ] && [ "$_PXP_PLAN_BYTES" -gt "$_PXP_CHUNK_LIMIT" ]
}

_paxel_push_mb() {
  LC_ALL=C awk -v b="$1" 'BEGIN { m = b / 1048576; f = "%.0f\n"; if (m < 10) f = "%.1f\n"; printf f, m }'
}

# Stages one session as a unit: scrubbed files, manifest, and the state rows
# to record once its commit is pushed. Status 0 staged, 2 scrub failed,
# 4 nothing new, 1 local failure.
_paxel_push_session() {
  local tool="$1" sid="$2" smt="$3" seq unit sdir main_src="" any_new=0 sha dropped
  local t s rel src size mt changed off pre ln dr force rc root
  seq=$((_PXP_UNIT_SEQ + 1))
  _PXP_UNIT_SEQ=$seq
  unit="$_PXP_WORK/u/$seq"
  sdir="sessions/$tool/$sid"
  : > "$unit.index"
  : > "$unit.state"
  : > "$unit.entries"
  paxel_is_uint "$smt" || smt=0

  while IFS="$_PXP_TAB" read -r t s rel src size mt changed off pre ln dr <&4; do
    case "$rel" in subagents/*) ;; *) main_src="$src" ;; esac
    force=0
    if [ "$changed" = 0 ]; then
      if [ "$pre" = too_large ]; then
        _paxel_push_keep_large "$unit" "$tool/$sid" "$rel" "$sdir/$rel" "$off" "$ln" "$dr" || true
        continue
      fi
      if [ "$pre" != rescrub ] && _paxel_push_tip_size "$sdir/$rel" && paxel_is_uint "$ln" && paxel_is_uint "$dr"; then
        _paxel_push_entry "$rel" "$_PXF_BYTES" "$ln" "$dr" >> "$unit.entries"
        continue
      fi
      force=1
    fi
    rc=0
    _paxel_push_file "$src" "$size" "$sdir/$rel" "$off" "$pre" "$ln" "$dr" "$force" || rc=$?
    case "$rc" in
      0) ;;
      3)
        if ! _paxel_push_keep_large "$unit" "$tool/$sid" "$rel" "$sdir/$rel" "$off" "$ln" "$dr"; then
          off=-; ln=-; dr=-
        fi
        printf '%s\t%s\t%s\ttoo_large\t%s\t%s\t%s\t%s\n' "$src" "$size" "$off" "$sdir/$rel" "$ln" "$dr" "$mt" >> "$_PXP_WORK/free.state"
        continue
        ;;
      5) continue ;;
      *) rm -f "$unit".*; return "$rc" ;;
    esac
    _paxel_push_entry "$rel" "$_PXF_BYTES" "$_PXF_LINES" "$_PXF_DROPPED" >> "$unit.entries"
    printf '%s\t%s\n' "$_PXF_STATE" "$mt" >> "$unit.state"
    if [ -n "$_PXF_SHA" ]; then
      printf '100644 %s\t%s\n' "$_PXF_SHA" "$sdir/$rel" >> "$unit.index"
      any_new=1
    fi
  done 4< "$_PXP_WORK/rows/$tool.$sid"

  if [ "$any_new" = 0 ]; then
    # Only sizes moved (a half-written line, a file over the limit); the
    # store copy is unchanged.
    cat "$unit.state" >> "$_PXP_WORK/free.state"
    rm -f "$unit".*
    return 4
  fi

  _paxel_push_session_meta "$tool" "$main_src"
  if ! jq -n -c \
      --argjson v "$PAXEL_STORE_SCHEMA_VERSION" --arg tool "$tool" --arg sid "$sid" \
      --slurpfile files "$unit.entries" --arg remote "$_PXS_REMOTE" --arg cwd "$_PXS_CWD" \
      --arg branch "$_PXS_BRANCH" --argjson mtime "$smt" --arg at "$(paxel_now_iso)" \
      --arg box "$_PXP_BOX" --arg box_name "$_PXP_BOX_NAME" --arg scrub "$_PXP_DIGEST" \
      --arg ver "${PAXEL_SCRIPT_VERSION:-unknown}" \
      '{schema_version: $v, tool: $tool, session_id: $sid, files: $files, git_remote: $remote,
        cwd: $cwd, branch: $branch, source_mtime: $mtime, pushed_at: $at, box_id: $box,
        box_name: $box_name, scrub: $scrub, paxel_version: $ver}' > "$unit.manifest.raw" 2>/dev/null; then
    rm -f "$unit".*
    return 1
  fi
  # The remote, cwd and branch come from the transcript and the box, so the
  # manifest is scrubbed like the files it lists.
  if ! dropped=$(_paxel_push_scrub_json "$unit.manifest.raw" "$unit.manifest"); then
    _PXP_FAIL_REASON=manifest
    rm -f "$unit".*
    return 2
  fi
  if ! sha=$(_paxel_local_git -C "$_PXP_CLONE" hash-object -w --no-filters -- "$unit.manifest" 2>/dev/null); then
    rm -f "$unit".*
    return 1
  fi
  printf '100644 %s\t%s/manifest.json\n' "$sha" "$sdir" >> "$unit.index"
  printf '%s\t%s\n' "$seq" "$tool/$sid" >> "$_PXP_WORK/chunk.units"

  if [ -n "$_PXS_REMOTE" ] && [ -n "$_PXS_CWD" ] && [ -d "$_PXS_CWD" ]; then
    root=$(git -C "$_PXS_CWD" rev-parse --show-toplevel 2>/dev/null || true)
    if [ -n "$root" ]; then
      printf '%s\t%s\t%s\n' "$_PXS_REMOTE" "$root" "$(dirname "$main_src")" >> "$_PXP_WORK/repos.tsv"
    fi
  fi
  return 0
}

# A file over the size limit is left out on its own; the rest of its session
# still goes, and its state row (marked too_large, with the size) holds it
# back until it changes. A copy pushed before it grew past the limit stays
# in the store and keeps its manifest entry. Status 1 when there is none.
_paxel_push_keep_large() {
  local unit="$1" key="$2" rel="$3" sp="$4" off="$5" ln="$6" dr="$7"
  _PXP_TOO_LARGE="${_PXP_TOO_LARGE}${key}"$'\n'
  paxel_is_uint "$off" && paxel_is_uint "$ln" && paxel_is_uint "$dr" && _paxel_push_tip_size "$sp" || return 1
  _paxel_push_entry "$rel" "$_PXF_BYTES" "$ln" "$dr" >> "$unit.entries"
}

# Scrubs a one-line JSON file (a manifest or snapshot meta) into OUT. Fails
# closed: a scrub error or a dropped line is a failure.
_paxel_push_scrub_json() {
  local in="$1" out="$2" bytes dropped
  bytes=$(wc -c < "$in" | tr -d ' ')
  : > "$out"
  dropped=$(paxel_scrub_range "$in" 0 "$bytes" "$out" 2>>"$_PXP_WORK/scrub.err") || return 1
  [ "$dropped" = 0 ] && [ -s "$out" ]
}

# Store paths and numbers here come from this machine, never from the store.
_paxel_push_entry() {
  printf '{"path":"%s","bytes":%s,"lines":%s,"dropped_lines":%s}\n' "$1" "$2" "$3" "$4"
}

_paxel_push_tip_size() {
  local b
  b=$(paxel_store_git -C "$_PXP_CLONE" cat-file -s "${_PXP_TIP}:$1" 2>/dev/null) || return 1
  paxel_is_uint "$b" || return 1
  _PXF_BYTES=$b
}

# Byte offset just after the last newline in [START, SIZE) of FILE, or
# START when that range holds no newline.
_paxel_complete_end() {
  local f="$1" start="$2" size="$3" partial
  if [ "$size" -le "$start" ]; then
    printf '%s\n' "$start"
    return 0
  fi
  if [ "$({ tail -c +"$size" "$f" 2>/dev/null || true; } | head -c 1 | wc -l | tr -d ' ')" = 1 ]; then
    printf '%s\n' "$size"
    return 0
  fi
  partial=$({ tail -c +$((start + 1)) "$f" 2>/dev/null || true; } | head -c $((size - start)) | tail -n 1 | wc -c | tr -d ' ')
  paxel_is_uint "$partial" || partial=$((size - start))
  printf '%s\n' $((size - partial))
}

# sha256 of the 64 KiB of FILE before byte END.
_paxel_prefix_sha() {
  local f="$1" end="$2" from=0
  [ "$end" -le 65536 ] || from=$((end - 65536))
  { tail -c +$((from + 1)) "$f" 2>/dev/null || true; } | head -c $((end - from)) | paxel_sha256
}

# Scrubs one file into a blob, with each image's base64 data replaced.
# Appends only the new complete lines to the copy pushed last time when the
# pushed prefix is unchanged and that copy is intact; otherwise scrubs the
# whole file again. Sets _PXF_SHA (empty when the store copy does not
# change), _PXF_BYTES, _PXF_LINES, _PXF_DROPPED and _PXF_STATE. Status 0 ok,
# 2 scrub failed, 3 too large, 5 a new file with no complete line yet, 1
# local failure.
_paxel_push_file() {
  local src="$1" size="$2" sp="$3" off="$4" pre="$5" ln="$6" dr="$7" force="$8"
  local out="$_PXP_WORK/file.out" mode=full end start=0 base_dropped=0 had_row=0
  local newpre dropped=0 bytes lines sha
  _PXF_SHA=""
  _PXF_BYTES=0
  _PXF_LINES=0
  _PXF_DROPPED=0
  _PXF_STATE=""
  if paxel_is_uint "$off" && paxel_is_uint "$ln" && paxel_is_uint "$dr"; then had_row=1; fi

  if [ "$had_row" = 1 ] && [ "$force" = 0 ] && [ "$off" -le "$size" ] \
     && [ "$pre" = "$(_paxel_prefix_sha "$src" "$off")" ]; then
    mode=incremental
    end=$(_paxel_complete_end "$src" "$off" "$size")
    if [ "$end" = "$off" ]; then
      if _paxel_push_tip_size "$sp"; then
        _PXF_LINES=$ln
        _PXF_DROPPED=$dr
        _PXF_STATE="${src}${_PXP_TAB}${size}${_PXP_TAB}${off}${_PXP_TAB}${pre}${_PXP_TAB}${sp}${_PXP_TAB}${ln}${_PXP_TAB}${dr}"
        return 0
      fi
      mode=full
    elif ! paxel_store_git -C "$_PXP_CLONE" cat-file blob "${_PXP_TIP}:${sp}" > "$out" 2>/dev/null \
         || [ "$(wc -l < "$out" | tr -d ' ')" != "$ln" ]; then
      mode=full
    fi
  fi

  if [ "$mode" = full ]; then
    end=$(_paxel_complete_end "$src" 0 "$size")
    if [ "$end" = 0 ] && [ "$had_row" = 0 ]; then return 5; fi
    : > "$out"
  else
    start=$off
    base_dropped=$dr
  fi
  # A full scrub of a source already over the limit is skipped without
  # spending CPU on it, even one whose images would fit once removed. An
  # incremental one scrubs only the new lines, so the check after the scrub
  # decides, and a pushed copy keeps growing while its scrubbed size fits.
  [ "$mode" = incremental ] || [ "$end" -le "$_PXP_MAX_BYTES" ] || return 3
  # Taken before the scrub reads the file: a rewrite after this point then
  # fails the next run's prefix check and forces a full scrub.
  newpre=$(_paxel_prefix_sha "$src" "$end")
  if [ "$end" -gt "$start" ]; then
    if ! dropped=$(paxel_scrub_range "$src" "$start" "$end" "$out" paxel_scrub_lines_without_images 2> "$_PXP_WORK/scrub.err"); then
      _PXP_FAIL_REASON=$(sed -n 's/.*reason=\([a-z_]*\))\.$/\1/p' "$_PXP_WORK/scrub.err" | tail -n 1)
      [ -n "$_PXP_FAIL_REASON" ] || _PXP_FAIL_REASON=unknown
      return 2
    fi
    paxel_is_uint "$dropped" || return 2
  fi
  bytes=$(wc -c < "$out" | tr -d ' ')
  lines=$(wc -l < "$out" | tr -d ' ')
  [ "$bytes" -le "$_PXP_MAX_BYTES" ] || return 3
  sha=$(_paxel_local_git -C "$_PXP_CLONE" hash-object -w --no-filters -- "$out" 2>/dev/null) || return 1
  _PXF_SHA=$sha
  _PXF_BYTES=$bytes
  _PXF_LINES=$lines
  _PXF_DROPPED=$((base_dropped + dropped))
  _PXF_STATE="${src}${_PXP_TAB}${size}${_PXP_TAB}${end}${_PXP_TAB}${newpre}${_PXP_TAB}${sp}${_PXP_TAB}${lines}${_PXP_TAB}${_PXF_DROPPED}"
}

# Sets _PXS_REMOTE (normalized, credentials stripped), _PXS_CWD and
# _PXS_BRANCH for a session's main file. The box resolves the remote while
# the repo is still in front of it; the laptop never resolves box paths.
_paxel_push_session_meta() {
  local tool="$1" src="$2"
  _PXS_REMOTE=""
  _PXS_CWD=""
  _PXS_BRANCH=""
  [ -n "$src" ] && [ -f "$src" ] || return 0
  if [ "$tool" = claude ]; then
    _PXS_CWD=$(grep -m 1 -o '"cwd":"[^"]*"' "$src" 2>/dev/null | head -n 1 | sed 's/^"cwd":"//; s/"$//' || true)
    _PXS_BRANCH=$(grep -o '"gitBranch":"[^"]*"' "$src" 2>/dev/null | tail -n 1 | sed 's/^"gitBranch":"//; s/"$//' || true)
    if [ -n "$_PXS_CWD" ] && [ -d "$_PXS_CWD" ]; then
      _PXS_REMOTE=$(get_git_remote "$_PXS_CWD" 2>/dev/null || true)
    elif [ -n "$_PXS_CWD" ]; then
      # The same recovery the local upload applies to a deleted cwd (an
      # enclosing clone, a sibling's worktree list). Its stderr names paths.
      _PXS_REMOTE=$(resolve_remote_for_dead_cwd "$_PXS_CWD" 2>/dev/null || true)
    fi
    [ -n "$_PXS_REMOTE" ] || _PXS_REMOTE=$(_paxel_push_pr_remote "$src")
  else
    _PXS_CWD=$(get_codex_session_cwd "$src" 2>/dev/null || true)
    _PXS_REMOTE=$(get_codex_session_remote "$src" 2>/dev/null || true)
    _PXS_BRANCH=$(head -n 1 "$src" 2>/dev/null | jq -r '(.payload // .).git.branch // empty | strings' 2>/dev/null || true)
  fi
  _PXS_REMOTE=$(normalize_remote "${_PXS_REMOTE//$'\r'/}")
  # normalize_remote keeps the scheme and userinfo of schemes it does not
  # know (git+https://user:token@host/…). Left in, the manifest scrub would
  # put brackets in the remote, and the laptop rejects such a remote.
  case "$_PXS_REMOTE" in
    *://*@*) _PXS_REMOTE=$(printf '%s' "$_PXS_REMOTE" | sed 's#^\([A-Za-z][A-Za-z0-9+.-]*://\)[^/@]*@#\1#' || true) ;;
  esac
  case "$_PXS_REMOTE" in *[!A-Za-z0-9._~:/@+-]*) _PXS_REMOTE="" ;; esac
  _PXS_CWD=${_PXS_CWD//$'\r'/}
  _PXS_BRANCH=${_PXS_BRANCH//$'\r'/}
}

# Deleted worktrees are common on boxes; Claude records the PR repository in
# pr-link lines, and the last one names the repo the session ended in.
_paxel_push_pr_remote() {
  local line url repo host=github.com
  line=$(grep '"type":"pr-link"' "$1" 2>/dev/null | tail -n 1 || true)
  [ -n "$line" ] || return 0
  url=$(printf '%s\n' "$line" | jq -r '.prUrl // empty | strings' 2>/dev/null || true)
  repo=$(printf '%s\n' "$line" | jq -r '.prRepository // empty | strings' 2>/dev/null || true)
  case "$url" in
    https://*/*)
      host=${url#https://}
      host=${host%%/*}
      ;;
  esac
  case "$host" in ''|*[!A-Za-z0-9.-]*) return 0 ;; esac
  case "$repo" in ''|/*|*/|*[!A-Za-z0-9._/-]*) return 0 ;; */*) ;; *) return 0 ;; esac
  normalize_remote "$host/$repo"
}

# ---- Git snapshots ----

_paxel_push_git_snapshots() {
  local heads="$PAXEL_PUSH_DIR/git_heads.tsv" keyed="$_PXP_WORK/repos.keyed" remote root sdir key dirs
  [ -s "$_PXP_WORK/repos.tsv" ] || return 0
  [ -f "$heads" ] || : > "$heads"
  awk -F '\t' -v OFS='\t' -v b="$_PXP_BOX" '$1 == b { print $2, $3 }' "$heads" > "$_PXP_WORK/repo_rows.tsv"
  : > "$keyed"
  while IFS="$_PXP_TAB" read -r remote root sdir <&5; do
    key=$(repository_git_key "$remote" "$root")
    printf '%s\t%s\t%s\t%s\n' "$key" "$remote" "$root" "$sdir" >> "$keyed"
  done 5< "$_PXP_WORK/repos.tsv"
  cut -f1 "$keyed" | LC_ALL=C sort -u > "$_PXP_WORK/repo_keys"
  while IFS= read -r key <&7; do
    paxel_valid_name "$key" || continue
    remote=$(awk -F '\t' -v k="$key" '$1 == k { print $2; exit }' "$keyed")
    root=$(awk -F '\t' -v k="$key" '$1 == k { print $3; exit }' "$keyed")
    dirs=$(awk -F '\t' -v k="$key" '$1 == k { print $4 }' "$keyed" | LC_ALL=C sort -u)
    _paxel_push_git_unit "$key" "$remote" "$root" "$dirs" || true
    # A snapshot that does not fit pushes the part before it; only that push sets an error here.
    [ -z "$_PXP_ERROR" ] || return 1
  done 7< "$_PXP_WORK/repo_keys"
  return 0
}

# Stages one repository snapshot in this box's own git/<box_id>/ directory,
# in the `--all` _git format, when HEAD moved since the last pushed one.
_paxel_push_git_unit() {
  local key="$1" remote="$2" root="$3" dirs="$4"
  local head recorded rejected shallow=false raw seq unit base suffix f path sha zero limit bounds oldest="" newest="" mode=aggregate now bytes
  head=$(git -C "$root" rev-parse --verify --quiet HEAD 2>/dev/null) || return 0
  recorded=$(awk -F '\t' -v b="$_PXP_BOX" -v k="$key" '$1 == b && $2 == k { h = $4 } END { print h }' "$PAXEL_PUSH_DIR/git_heads.tsv")
  [ "$head" != "$recorded" ] || return 0
  rejected=$(awk -F '\t' -v b="$_PXP_BOX" -v k="$key" '$1 == b && $2 == k { h = $3 } END { print h }' "$PAXEL_PUSH_DIR/git_rejected.tsv" 2>/dev/null || true)
  [ "$head" != "$rejected" ] || return 0
  # In a partial (blobless) clone the numstat would fetch every blob it reads
  # from the user's origin, in the background and against the git time
  # limit. A clone with its blobs (the laptop, another box) supplies this
  # repository's git data instead.
  [ -z "$(git -C "$root" config --get extensions.partialclone 2>/dev/null || true)" ] || return 0
  [ "$(git -C "$root" rev-parse --is-shallow-repository 2>/dev/null || true)" != true ] || shallow=true
  limit=$(_paxel_push_uint_env PAXEL_PUSH_COMMIT_LIMIT 1000)
  raw="$_PXP_WORK/git-$key"
  rm -rf "$raw"
  mkdir -p "$raw"
  bounds=$(_jsonl_epoch_bounds "$dirs" 2>/dev/null || true)
  if [ -n "$bounds" ]; then
    oldest=$(printf '%s' "$bounds" | cut -f1)
    newest=$(printf '%s' "$bounds" | cut -f2)
  fi
  if paxel_is_uint "$oldest" && paxel_is_uint "$newest"; then
    # Same window as the --all upload: a session file's mtime is its last
    # write, so the day before covers commits from earlier in the session.
    oldest=$((oldest - 86400))
    [ "$oldest" -ge 0 ] || oldest=0
    newest=$((newest + 86400))
    mode=repository_aware
  else
    oldest=""
    newest=""
  fi
  # Its stderr names author emails, which the push log must not hold.
  ( SINCE_EPOCH=""; COMMIT_LIMIT="$limit"
    collect_repository_git_data "$root" "$raw" "$key" "$dirs" "$oldest" "$mode" "$newest" ) </dev/null >/dev/null 2>&1 || true
  # A failed or timed-out collection must not replace a good snapshot with an
  # empty or cut-short one, which the laptop would take as full history;
  # HEAD is not recorded, so the next run tries again.
  _paxel_push_git_complete "$raw" "$key" "$limit" || { rm -rf "$raw"; return 0; }
  if [ "$shallow" = true ]; then _paxel_push_drop_boundary "$root" "$raw" "$key"; fi

  seq=$((_PXP_UNIT_SEQ + 1))
  _PXP_UNIT_SEQ=$seq
  unit="$_PXP_WORK/u/$seq"
  base="git/$_PXP_BOX"
  zero=$(printf '%0*d' "${#head}" 0)
  : > "$unit.index"
  for suffix in commit_count.txt numstat.txt activity.tsv author_commits.jsonl author_numstat.txt; do
    f="$raw/${key}_$suffix"
    path="$base/_git/${key}_$suffix"
    if [ ! -f "$f" ]; then
      printf '0 %s\t%s\n' "$zero" "$path" >> "$unit.index"
      continue
    fi
    if ! paxel_scrub_text_file "$f" "$f.scrubbed" 2>>"$_PXP_WORK/scrub.err"; then
      _PXP_SCRUB_FAILED="${_PXP_SCRUB_FAILED}git/${key}"$'\n'
      rm -f "$unit".*
      return 1
    fi
    sha=$(_paxel_local_git -C "$_PXP_CLONE" hash-object -w --no-filters -- "$f.scrubbed" 2>/dev/null) || { rm -f "$unit".*; return 1; }
    printf '100644 %s\t%s\n' "$sha" "$path" >> "$unit.index"
  done

  now=$(paxel_now_iso)
  jq -n -c --argjson v "$PAXEL_STORE_SCHEMA_VERSION" --arg remote "$remote" --arg head "$head" \
    --argjson shallow "$shallow" --arg at "$now" --argjson limit "$limit" \
    '{schema_version: $v, git_remote: $remote, head: $head, shallow: $shallow, captured_at: $at, commit_limit: $limit}' \
    > "$unit.meta.raw" 2>/dev/null || { rm -f "$unit".*; return 1; }
  if ! _paxel_push_scrub_json "$unit.meta.raw" "$unit.meta"; then
    _PXP_SCRUB_FAILED="${_PXP_SCRUB_FAILED}git/${key}"$'\n'
    rm -f "$unit".*
    return 1
  fi
  sha=$(_paxel_local_git -C "$_PXP_CLONE" hash-object -w --no-filters -- "$unit.meta" 2>/dev/null) || { rm -f "$unit".*; return 1; }
  printf '100644 %s\t%s/meta/%s.json\n' "$sha" "$base" "$key" >> "$unit.index"

  awk -F '\t' -v OFS='\t' -v k="$key" -v r="$remote" '{ m[$1] = $0 } END { m[k] = k OFS r; for (x in m) print m[x] }' \
    "$_PXP_WORK/repo_rows.tsv" | LC_ALL=C sort > "$unit.repos"
  if ! paxel_scrub_text_file "$unit.repos" "$unit.repos.scrubbed" 2>>"$_PXP_WORK/scrub.err"; then
    _PXP_SCRUB_FAILED="${_PXP_SCRUB_FAILED}git/${key}"$'\n'
    rm -f "$unit".*
    return 1
  fi
  sha=$(_paxel_local_git -C "$_PXP_CLONE" hash-object -w --no-filters -- "$unit.repos.scrubbed" 2>/dev/null) || { rm -f "$unit".*; return 1; }
  printf '100644 %s\t%s/_git/repositories.tsv\n' "$sha" "$base" >> "$unit.index"
  cp "$unit.repos" "$_PXP_WORK/repo_rows.tsv"

  printf '%s\t%s\t%s\t%s\t%s\n' "$_PXP_BOX" "$key" "$remote" "$head" "$now" > "$unit.heads"
  bytes=$(cat "$raw"/*.scrubbed 2>/dev/null | wc -c | tr -d ' ')
  paxel_is_uint "$bytes" || bytes=0
  rm -rf "$raw"
  _paxel_push_make_room "$bytes" || { rm -f "$unit".*; return 1; }
  printf '%s\t%s\n' "$seq" "git/$key" >> "$_PXP_WORK/chunk.units"
  _PXP_CHUNK_BYTES=$((_PXP_CHUNK_BYTES + bytes))
}

# The numstat holds one COMMIT_BOUNDARY per commit, so a complete one has
# min(LIMIT, commit count) of them.
_paxel_push_git_complete() {
  local raw="$1" key="$2" limit="$3" count got
  [ -s "$raw/${key}_numstat.txt" ] || return 1
  count=$(tr -d ' \n' < "$raw/${key}_commit_count.txt" 2>/dev/null || true)
  paxel_is_uint "$count" && [ "${#count}" -le 9 ] || return 1
  [ "$count" -le "$limit" ] || count=$limit
  got=$(grep -c '^COMMIT_BOUNDARY ' "$raw/${key}_numstat.txt" 2>/dev/null || true)
  paxel_is_uint "$got" && [ "$got" -ge "$count" ]
}

# In a shallow clone the boundary commit looks like one commit adding the
# whole tree, and the commit count equals the depth. Drop boundary commits
# from every snapshot file.
_paxel_push_drop_boundary() {
  local root="$1" raw="$2" key="$3" shallow_file bset="$2/.boundary" sha f tmp="$2/.tmp"
  shallow_file=$(git -C "$root" rev-parse --git-path shallow 2>/dev/null || true)
  [ -n "$shallow_file" ] || return 0
  case "$shallow_file" in /*) ;; *) shallow_file="$root/$shallow_file" ;; esac
  [ -s "$shallow_file" ] || return 0
  : > "$bset"
  while IFS= read -r sha; do
    case "$sha" in ''|*[!0-9a-f]*) continue ;; esac
    if git -C "$root" cat-file -e "${sha}^{commit}" 2>/dev/null; then printf '%s\n' "$sha" >> "$bset"; fi
  done < "$shallow_file"
  [ -s "$bset" ] || return 0

  for f in "$raw/${key}_numstat.txt" "$raw/${key}_author_numstat.txt"; do
    [ -f "$f" ] || continue
    awk 'FILENAME == ARGV[1] { b[$1] = 1; next } /^COMMIT_BOUNDARY / { skip = ($2 in b) } !skip' "$bset" "$f" > "$tmp" && mv "$tmp" "$f"
  done
  f="$raw/${key}_author_commits.jsonl"
  if [ -f "$f" ]; then
    awk -F '\t' 'FILENAME == ARGV[1] { b[$1] = 1; next } !($1 in b)' "$bset" "$f" > "$tmp" && mv "$tmp" "$f"
  fi
  f="$raw/${key}_commit_count.txt"
  if [ -f "$f" ]; then
    { echo HEAD; sed 's/^/^/' "$bset"; } | git -C "$root" rev-list --count --stdin > "$f" 2>/dev/null || true
  fi
  f="$raw/${key}_activity.tsv"
  if [ -f "$f" ]; then
    git -C "$root" log --no-walk=unsorted --stdin \
      --format='%aI%x09%aE%x09%aN%x09%(trailers:key=Co-authored-by,valueonly,separator=%x1f)' \
      < "$bset" > "$raw/.boundary_activity" 2>/dev/null || : > "$raw/.boundary_activity"
    awk -F '\t' -v OFS='\t' '
      FILENAME == ARGV[1] { d[substr($1, 1, 10) "\t" tolower($2) "\t" $3 "\t" $4]++; next }
      /^#/ { print; next }
      {
        k = $1 "\t" $2 "\t" $3 "\t" (NF > 4 ? $5 : "")
        if (k in d) { $4 = $4 - d[k]; if ($4 <= 0) next }
        print
      }
    ' "$raw/.boundary_activity" "$f" > "$tmp" && mv "$tmp" "$f"
  fi
}

# ---- Commits ----

# Builds a commit on the current tip from index-info lines. Prints its sha,
# or nothing when the tree would not change (and ALLOW_EMPTY is not 1).
_paxel_push_commit_index() {
  local lines="$1" msg="$2" allow_empty="${3:-0}" idx="$_PXP_WORK/index" err="$_PXP_WORK/commit.err" tree ptree
  rm -f "$idx"
  : > "$err"
  GIT_INDEX_FILE="$idx" _paxel_local_git -C "$_PXP_CLONE" read-tree "$_PXP_TIP" 2>>"$err" || return 1
  if [ -s "$lines" ]; then
    GIT_INDEX_FILE="$idx" _paxel_local_git -C "$_PXP_CLONE" update-index --index-info < "$lines" 2>>"$err" || return 1
  fi
  # --missing-ok: other boxes' blobs are never downloaded into this clone.
  tree=$(GIT_INDEX_FILE="$idx" _paxel_local_git -C "$_PXP_CLONE" write-tree --missing-ok 2>>"$err") || return 1
  ptree=$(_paxel_local_git -C "$_PXP_CLONE" rev-parse "${_PXP_TIP}^{tree}" 2>>"$err") || return 1
  if [ "$tree" = "$ptree" ] && [ "$allow_empty" != 1 ]; then return 0; fi
  GIT_AUTHOR_NAME="paxel push" GIT_AUTHOR_EMAIL="push@paxel.invalid" \
    GIT_COMMITTER_NAME="paxel push" GIT_COMMITTER_EMAIL="push@paxel.invalid" \
    _paxel_local_git -C "$_PXP_CLONE" commit-tree "$tree" -p "$_PXP_TIP" -m "$msg" 2>>"$err"
}

# The first error line git printed, for the log and the message, with URLs
# and user@host parts removed: the store is shown as host/owner/name only.
_paxel_push_git_reason() {
  local line
  line=$({ grep -E '^(fatal|error|remote): ' "$1" 2>/dev/null || true; } | { grep -v 'failed to push some refs' || true; } | head -n 1)
  [ -n "$line" ] || line=$({ grep -E '^(fatal|error|remote): ' "$1" 2>/dev/null || true; } | head -n 1)
  printf '%s\n' "$line" \
    | sed -E 's#[A-Za-z][A-Za-z0-9+.-]*://[^[:space:]]*#<url>#g; s#[^[:space:]]*@[^[:space:]]*#<url>#g' \
    | LC_ALL=C tr -d "'\"" | LC_ALL=C tr -c 'A-Za-z0-9 ._:,;()<>/=+\n-' '_' | cut -c1-200
}

# The push sends a whole part, so its time limit grows with the part: 300 s
# plus one second per PAXEL_PUSH_MIN_BYTES_PER_SEC, the slowest link that
# still lands it.
_paxel_push_scaled_secs() {
  local base rate secs
  base=$(_paxel_push_uint_env PAXEL_STORE_GIT_TIMEOUT 300)
  rate=$(_paxel_push_uint_env PAXEL_PUSH_MIN_BYTES_PER_SEC 32768)
  [ "$rate" -ge 1 ] || rate=1
  secs=$((300 + _PXP_CHUNK_BYTES / rate))
  [ "$secs" -ge "$base" ] || secs=$base
  printf '%s\n' "$secs"
}

# Measured from a box to GitHub, a connection stays clean (MB/s) or lossy
# (a tenth of that) for its whole life, and about 1 in 3 is lossy. Twice the
# time a clean one needs tells them apart, so a push stopped at this deadline
# goes again on a new connection. Never past LIMIT, the last attempt's.
_paxel_push_watchdog_secs() {
  local limit="$1" rate min secs
  rate=$(_paxel_push_uint_env PAXEL_PUSH_WATCHDOG_BYTES_PER_SEC 8388608)
  [ "$rate" -ge 1 ] || rate=1
  min=$(_paxel_push_uint_env PAXEL_PUSH_WATCHDOG_MIN_SECS 10)
  secs=$((2 * (2 + _PXP_CHUNK_BYTES / rate)))
  [ "$secs" -ge "$min" ] || secs=$min
  [ "$secs" -le "$limit" ] || secs=$limit
  printf '%s\n' "$secs"
}

# 124 is timeout's own stop at the deadline. TERM or KILL (143, 137) stops
# the push in the fallback and in busybox timeout, but also comes from the OOM
# killer or a shutdown, so it counts only once SECS have passed.
_paxel_push_stopped_at_deadline() {
  local rc="$1" elapsed="$2" secs="$3"
  case "$rc" in
    124) return 0 ;;
    137|143) [ "$elapsed" -ge "$secs" ] ;;
    *) return 1 ;;
  esac
}

# paxel_git reads the limit when it runs. No ssh connection sharing: a push
# stopped on a slow connection must get a new one, even when ~/.ssh/config
# sets ControlMaster.
_paxel_push_git_push() {
  local PAXEL_STORE_GIT_TIMEOUT="$1" _PAXEL_SSH_OPTS=" -o ControlMaster=no -o ControlPath=none"
  shift
  paxel_store_git "$@"
}

# Status 0 pushed, 10 the tip moved (another box pushed first), 11 the host
# rejected the content, 1 anything else. Every attempt but the last
# (PAXEL_PUSH_WATCHDOG_TRIES) gets the watchdog deadline, and the last gets
# the scaled limit, so a link that is slow on every connection still lands
# the part. A retry of a push the store already took is up to date.
# A part that lands only on its last attempt turns the watchdog off for the
# rest of the run: on a link slow on every connection, each early attempt
# only adds its deadline and sends the part again.
_paxel_push_send() {
  local c="$1" parent="$_PXP_TIP" out="$_PXP_WORK/push.out" err="$_PXP_WORK/push.err" raw reason rc tries attempt=1 limit secs started
  tries=$(_paxel_push_uint_env PAXEL_PUSH_WATCHDOG_TRIES 3)
  [ "$tries" -ge 1 ] || tries=1
  [ -z "$_PXP_WATCHDOG_OFF_AT" ] || tries=1
  limit=$(_paxel_push_scaled_secs)
  while :; do
    secs=$limit
    [ "$attempt" -ge "$tries" ] || secs=$(_paxel_push_watchdog_secs "$limit")
    rc=0
    started=$SECONDS
    _paxel_push_git_push "$secs" -C "$_PXP_CLONE" push --porcelain origin "${c}:refs/heads/${_PXP_BRANCH}" > "$out" 2> "$err" || rc=$?
    if [ "$rc" = 0 ]; then
      if [ "$attempt" -gt 1 ] && [ "$attempt" -ge "$tries" ]; then
        _PXP_WATCHDOG_OFF_AT=$(paxel_now_epoch)
        paxel_log "push watchdog_off attempts=${attempt} bytes=${_PXP_CHUNK_BYTES}"
      fi
      return 0
    fi
    _paxel_push_stopped_at_deadline "$rc" "$((SECONDS - started))" "$secs" || break
    if [ "$attempt" -ge "$tries" ]; then
      _PXP_ERROR=push_timeout
      _PXP_DETAIL="about $(_paxel_push_mb "$_PXP_CHUNK_BYTES") MB, stopped after ${secs}s"
      [ "$attempt" -lt 2 ] || _PXP_DETAIL="${_PXP_DETAIL} on the last of ${attempt} connections"
      paxel_log "push push_timeout bytes=${_PXP_CHUNK_BYTES} secs=${secs}"
      return 1
    fi
    attempt=$((attempt + 1))
    paxel_log "push slow_retry attempt=${attempt} bytes=${_PXP_CHUNK_BYTES} secs=${secs}"
    if [ "$_PXP_SHOW_PROGRESS" = 1 ]; then
      paxel_say "The connection to ${_PXP_STORE%%/*} was slow: the push of about $(_paxel_push_mb "$_PXP_CHUNK_BYTES") MB did not finish in ${secs}s. Trying again on a new connection (attempt ${attempt} of ${tries})..."
    fi
  done
  _paxel_push_fetch || return 1
  [ "$_PXP_TIP" = "$parent" ] || return 10
  if grep -q 'remote rejected' "$out" "$err" 2>/dev/null; then
    raw=$(sed -n 's/.*\[remote rejected\] *(\(.*\)).*/\1/p' "$out" "$err" 2>/dev/null | head -n 1 || true)
    case "$raw" in
      # Another write holds the ref, such as a stopped attempt the store is
      # still applying: not a content rule, so no content check.
      *"cannot lock ref"*|*"failed to lock"*|*"failed to update ref"*)
        _PXP_ERROR=push_failed
        _PXP_DETAIL=$(printf 'remote rejected: %s\n' "$raw" | LC_ALL=C tr -d "'\"" | LC_ALL=C tr -c 'A-Za-z0-9 ._:,;()<>/=+\n-' '_' | cut -c1-200)
        paxel_log "push push_failed reason=ref_locked"
        return 1
        ;;
    esac
    reason=""
    [ -z "$raw" ] || reason=$(printf '%s\n' "$raw" | tr -c 'A-Za-z0-9 ._-' '_')
    paxel_log "push host_rejected reason=${reason:-unknown}"
    return 11
  fi
  # Reading worked a moment ago, so an auth error here means no write access.
  _paxel_push_classify_remote_error "$err"
  [ "$_PXP_ERROR" = store_access_denied ] || _PXP_ERROR=push_failed
  _PXP_DETAIL=$(_paxel_push_git_reason "$err")
  paxel_log "push ${_PXP_ERROR} reason=${_PXP_DETAIL:-none}"
  return 1
}

# Commits LINES on the tip and pushes it, rebuilding on the new tip when
# another box pushed first. Paths are unique per session and per box, so a
# rebuild never conflicts. Status 0, 11 (content rejected) or 1.
_paxel_push_commit_and_send() {
  local lines="$1" msg="$2" allow_empty="${3:-0}" attempt=1 c rc jitter
  jitter=$(_paxel_push_uint_env PAXEL_PUSH_RETRY_JITTER_SECS 3)
  while :; do
    if ! c=$(_paxel_push_commit_index "$lines" "$msg" "$allow_empty"); then
      _PXP_ERROR=commit_failed
      _PXP_DETAIL=$(_paxel_push_git_reason "$_PXP_WORK/commit.err")
      paxel_log "push commit_failed reason=${_PXP_DETAIL:-none}"
      return 1
    fi
    [ -n "$c" ] || return 0
    rc=0
    _paxel_push_send "$c" || rc=$?
    case "$rc" in
      0)
        _paxel_local_git -C "$_PXP_CLONE" update-ref "refs/heads/${_PXP_BRANCH}" "$c" "$_PXP_TIP" >/dev/null 2>&1 || true
        _PXP_TIP=$c
        _PXP_PUSHED=1
        return 0
        ;;
      10)
        if [ "$attempt" -ge 5 ]; then
          _PXP_ERROR=push_conflict
          return 1
        fi
        attempt=$((attempt + 1))
        paxel_log "push retry attempt=$attempt"
        if [ "$jitter" -gt 0 ]; then sleep $((RANDOM % jitter + 1)); fi
        ;;
      11) return 11 ;;
      *) [ -n "$_PXP_ERROR" ] || _PXP_ERROR=push_failed; return 1 ;;
    esac
  done
}

# Pushes the staged units (a part) as one commit and records their state.
# Each part is pushed and recorded before the next is staged, so a dropped
# connection loses one part at most.
_paxel_push_flush() {
  local list="$_PXP_WORK/chunk.units" all="$_PXP_WORK/chunk.index" seq name n rc=0
  [ -s "$list" ] || return 0
  : > "$all"
  while IFS="$_PXP_TAB" read -r seq name <&6; do
    cat "$_PXP_WORK/u/$seq.index" >> "$all"
  done 6< "$list"
  n=$(wc -l < "$list" | tr -d ' ')
  _paxel_push_commit_and_send "$all" "paxel push from ${_PXP_BOX}: ${n} item(s)" || rc=$?
  case "$rc" in
    0)
      while IFS="$_PXP_TAB" read -r seq name <&6; do
        _paxel_push_record_unit "$seq" "$name"
      done 6< "$list"
      ;;
    11)
      rc=0
      _paxel_push_bisect "$list" || rc=1
      ;;
  esac
  # A git snapshot that did not fit is staged already and waits for the next part.
  while IFS="$_PXP_TAB" read -r seq name <&6; do
    rm -f "$_PXP_WORK/u/$seq".*
  done 6< "$list"
  : > "$list"
  [ "$rc" != 0 ] || _PXP_PUSHED_BYTES=$((_PXP_PUSHED_BYTES + _PXP_CHUNK_BYTES))
  _PXP_CHUNK_BYTES=0
  _PXP_RESULT=$(_paxel_push_result)
  _paxel_push_write_last
  _PXP_RESULT=""
  [ "$rc" = 0 ] || return 1
  if _paxel_push_in_parts && [ "$_PXP_REMAINING" -gt 0 ]; then
    paxel_say "Pushed $_PXP_WRITTEN of $_PXP_PLAN_SESSIONS sessions ($(_paxel_push_mb "$_PXP_PUSHED_BYTES") of $(_paxel_push_mb "$_PXP_PLAN_BYTES") MB)..."
  fi
  return 0
}

# The host rejected a chunk for its content (secret push protection). A
# commit with no new content is pushed first: if that is rejected too, the
# rule is not about content. Otherwise each unit is pushed alone and the
# rejected ones are quarantined.
_paxel_push_bisect() {
  local list="$1" seq name rc empty="$_PXP_WORK/empty.index"
  : > "$empty"
  rc=0
  _paxel_push_commit_and_send "$empty" "paxel push from ${_PXP_BOX}: content check" 1 || rc=$?
  case "$rc" in
    0) ;;
    11) _PXP_ERROR=push_rejected; return 1 ;;
    *) return 1 ;;
  esac
  while IFS="$_PXP_TAB" read -r seq name <&6; do
    rc=0
    _paxel_push_commit_and_send "$_PXP_WORK/u/$seq.index" "paxel push from ${_PXP_BOX}: ${name}" || rc=$?
    case "$rc" in
      0) _paxel_push_record_unit "$seq" "$name" ;;
      11) _paxel_push_quarantine "$seq" "$name" ;;
      *) return 1 ;;
    esac
  done 6< "$list"
}

# Sessions are quarantined until the line is removed from quarantine.tsv. A
# rejected git snapshot is recorded with its HEAD in git_rejected.tsv and is
# skipped until that repo's HEAD moves.
_paxel_push_quarantine() {
  local u="$_PXP_WORK/u/$1" name="$2" box key remote head rest
  _PXP_QUARANTINED_NEW="${_PXP_QUARANTINED_NEW}${name}"$'\n'
  case "$name" in
    git/*)
      IFS="$_PXP_TAB" read -r box key remote head rest < "$u.heads" || true
      if [ -n "$key" ] && [ -n "$head" ]; then
        _paxel_push_rejected_drop "$box" "$key"
        printf '%s\t%s\t%s\n' "$box" "$key" "$head" >> "$PAXEL_PUSH_DIR/git_rejected.tsv"
      fi
      ;;
    *) printf '%s\t%s\n' "$name" "$(paxel_now_epoch)" >> "$PAXEL_PUSH_DIR/quarantine.tsv" ;;
  esac
  paxel_log "push quarantined $name"
}

_paxel_push_rejected_drop() {
  local f="$PAXEL_PUSH_DIR/git_rejected.tsv" tmp
  [ -s "$f" ] || return 0
  tmp="$f.tmp.$$"
  awk -F '\t' -v b="$1" -v k="$2" '!($1 == b && $2 == k)' "$f" > "$tmp" && mv "$tmp" "$f"
}

_paxel_push_record_unit() {
  local u="$_PXP_WORK/u/$1" box key rest
  if [ -s "$u.state" ]; then _paxel_push_state_merge "$u.state"; fi
  if [ -s "$u.heads" ]; then
    _paxel_push_heads_merge "$u.heads"
    IFS="$_PXP_TAB" read -r box key rest < "$u.heads" || true
    _paxel_push_rejected_drop "$box" "$key"
  fi
  case "$2" in git/*) ;; *) _PXP_WRITTEN=$((_PXP_WRITTEN + 1)) ;; esac
}

_paxel_push_state_merge() {
  local rows="$1" state="$PAXEL_PUSH_DIR/state.tsv" tmp
  [ -s "$rows" ] || return 0
  [ -f "$state" ] || : > "$state"
  tmp="$state.tmp.$$"
  awk -F '\t' 'FILENAME == ARGV[1] { n[$1] = $0; next } !($1 in n) { print } END { for (k in n) print n[k] }' \
    "$rows" "$state" > "$tmp" && mv "$tmp" "$state"
}

_paxel_push_heads_merge() {
  local rows="$1" heads="$PAXEL_PUSH_DIR/git_heads.tsv" tmp
  [ -f "$heads" ] || : > "$heads"
  tmp="$heads.tmp.$$"
  awk -F '\t' 'FILENAME == ARGV[1] { n[$1 "\t" $2] = $0; next } !(($1 "\t" $2) in n) { print } END { for (k in n) print n[k] }' \
    "$rows" "$heads" > "$tmp" && mv "$tmp" "$heads"
}

# After a push, cut the clone back to depth 1 and drop unreachable objects,
# so old versions of growing transcripts do not pile up on the box.
_paxel_push_compact() {
  local counts loose packs
  [ "$_PXP_PUSHED" = 1 ] || return 0
  _paxel_push_fetch || { _PXP_ERROR=""; return 0; }
  _paxel_local_git -C "$_PXP_CLONE" prune --expire=now >/dev/null 2>&1 || true
  counts=$(_paxel_local_git -C "$_PXP_CLONE" count-objects -v 2>/dev/null || true)
  loose=$(printf '%s\n' "$counts" | sed -n 's/^count: //p')
  packs=$(printf '%s\n' "$counts" | sed -n 's/^packs: //p')
  if { paxel_is_uint "$packs" && [ "$packs" -gt 20 ]; } || { paxel_is_uint "$loose" && [ "$loose" -gt 5000 ]; }; then
    _paxel_local_git -C "$_PXP_CLONE" gc --quiet --prune=now >/dev/null 2>&1 || true
  fi
}

# ---- Results ----

_paxel_push_write_last() {
  local f="$PAXEL_PUSH_DIR/last.json" tmp quarantined too_large
  tmp="$f.tmp.$$"
  quarantined=$(_paxel_push_quarantined_list)
  too_large=$(_paxel_push_too_large_list)
  if command -v jq >/dev/null 2>&1; then
    jq -n --argjson v "$PAXEL_STORE_SCHEMA_VERSION" --arg at "$(paxel_now_iso)" --arg result "$_PXP_RESULT" \
      --arg store "$_PXP_STORE" --argjson written "$_PXP_WRITTEN" --argjson remaining "$_PXP_REMAINING" \
      --arg too "$too_large" --arg quar "$quarantined" --arg failed "$_PXP_SCRUB_FAILED" \
      --arg err "$_PXP_ERROR" --arg warn "$_PXP_WARNINGS" '
      def lst: split("\n") | map(select(length > 0));
      {schema_version: $v, at: $at, result: $result, store: $store, sessions_written: $written,
       catchup_remaining_bytes: $remaining, skipped_too_large: ($too | lst), quarantined: ($quar | lst),
       scrub_failed: ($failed | lst), error_class: (if $err == "" then null else $err end),
       warnings: ($warn | lst)}' > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 0; }
  else
    printf '{"schema_version":%s,"at":"%s","result":"%s","store":"%s","sessions_written":%s,"catchup_remaining_bytes":%s,"skipped_too_large":[],"quarantined":[],"scrub_failed":[],"error_class":%s,"warnings":[]}\n' \
      "$PAXEL_STORE_SCHEMA_VERSION" "$(paxel_now_iso)" "$_PXP_RESULT" "$_PXP_STORE" "$_PXP_WRITTEN" "$_PXP_REMAINING" \
      "$( [ -n "$_PXP_ERROR" ] && printf '"%s"' "$_PXP_ERROR" || printf 'null' )" > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 0; }
  fi
  mv "$tmp" "$f" 2>/dev/null || rm -f "$tmp"
}

_paxel_push_list() {
  printf '%s' "$1" | awk 'NF' | paste -sd ' ' - | sed 's/ /, /g'
}

# The sessions in LIST, each with the reason scrub_failed.tsv records.
_paxel_push_scrub_failed_text() {
  local f="$PAXEL_PUSH_DIR/scrub_failed.tsv"
  [ -f "$f" ] || f=/dev/null
  printf '%s' "$1" | awk -F '\t' '
    FILENAME == ARGV[1] { if ($6 ~ /^[a-z_]+$/) r[$1] = $6; next }
    NF { out = out (out == "" ? "" : ", ") $0 (($0 in r) ? " (" r[$0] ")" : "") }
    END { print out }
  ' "$f" -
}

# OTHERS: sessions the push that `push --now` waited for wrote; OTHER: which
# push that was.
_paxel_push_report() {
  local others="${1:-0}" other="${2:-}" store="${_PXP_STORE:-your transcript store}" n="$_PXP_WRITTEN" s=s max_mb too_large quarantined
  [ "$n" != 1 ] || s=""
  if [ "$others" -gt 0 ]; then
    if [ "$others" = 1 ]; then
      paxel_say "The push $other pushed 1 session to $store."
    else
      paxel_say "The push $other pushed $others sessions to $store."
    fi
  fi
  case "$_PXP_RESULT" in
    ok)
      if [ "$n" -gt 0 ]; then
        paxel_say "Pushed $n session$s to $store."
      elif [ "$others" -gt 0 ]; then
        paxel_say "Nothing else new to push. $store is up to date."
      else
        paxel_say "Nothing new to push. $store is up to date."
      fi
      ;;
    partial)
      paxel_say "Pushed $n session$s to $store. Some of this machine's sessions are not fully in the store:"
      too_large=$(_paxel_push_too_large_list)
      if [ -n "$too_large" ]; then
        max_mb=$((_PXP_MAX_BYTES / 1048576))
        paxel_say "  A file over ${max_mb} MB after scrubbing, too large for the store host (GitHub rejects files over 100 MB), was left out; the rest of the session was pushed: $(_paxel_push_list "$too_large")"
      fi
      if [ -n "$_PXP_SCRUB_FAILED" ]; then
        paxel_say "  Credential scrub failed, so nothing from these was written: $(_paxel_push_scrub_failed_text "$_PXP_SCRUB_FAILED"). Push tries each again after a scrub update, on the next push after file_changed, once a day after timeout, killed, memory, local_io or unknown, and otherwise once a day while the session changes."
      fi
      quarantined=$(_paxel_push_quarantined_list)
      if [ -n "$quarantined" ]; then
        paxel_say "  Rejected by the store host for their content (for example secret push protection), now skipped: $(_paxel_push_list "$quarantined")"
        paxel_say "  To retry a session, delete its line from $PAXEL_PUSH_DIR/quarantine.tsv. A git snapshot is tried again when that repo's HEAD moves."
      fi
      ;;
    off)
      paxel_say "Capture is off on this machine (set by 'paxel setup --off'). Nothing was pushed. Run 'paxel setup' to turn it back on."
      ;;
    skipped)
      paxel_say "No transcript store is set up on this machine, so nothing was pushed. Run 'paxel setup' first."
      ;;
    error)
      paxel_say "$(_paxel_push_error_text "$store")"
      ;;
  esac
  if [ "$_PXP_OUTSIDE" -gt 0 ] 2>/dev/null; then
    if [ "$_PXP_OUTSIDE" = 1 ]; then
      paxel_say "1 session last active before $(paxel_epoch_iso "$_PXP_FLOOR") stays on this machine, as setup --since chose. To push it too: $PAXEL_HOME_DIR/bin/paxel setup --since all"
    else
      paxel_say "$_PXP_OUTSIDE sessions last active before $(paxel_epoch_iso "$_PXP_FLOOR") stay on this machine, as setup --since chose. To push them too: $PAXEL_HOME_DIR/bin/paxel setup --since all"
    fi
  fi
  case "$_PXP_WARNINGS" in
    *visibility_unchecked*)
      if [ "$(paxel_config_get store_cli)" = none ]; then
        paxel_say "Could not confirm that $store is private: with no gh or glab login, only a public repo can be detected. The next push checks again."
      else
        paxel_say "Could not confirm that $store is private this time (the host did not answer); the next push checks again."
      fi
      ;;
  esac
}

# " (git said: …)" when git printed an error line.
_paxel_push_git_said() {
  [ -z "${_PXP_DETAIL:-}" ] || printf ' (git said: %s)' "$_PXP_DETAIL"
}

_paxel_push_error_text() {
  local store="$1"
  case "$_PXP_ERROR" in
    not_a_paxel_store)
      echo "Push refused: $store has no paxel-store.json on branch ${_PXP_BRANCH:-main}, so it may not be a transcript store. Nothing was written. Check the store with 'paxel status', or rerun 'paxel setup'." ;;
    store_marker_invalid)
      echo "Push refused: paxel-store.json in $store is not valid (schema_version must be a whole number). Nothing was written. Restore the file from the repo history, or set up a new store." ;;
    store_schema_newer)
      echo "Push refused: $store uses a newer store format than this script writes. Nothing was written. Rerun 'paxel setup' to get the current script." ;;
    store_not_private)
      echo "Push stopped: $store is ${_PXP_DETAIL:+${_PXP_DETAIL}, }not private. Nothing was written. Make the repo private; the next push checks again and resumes." ;;
    store_access_denied)
      echo "Push failed: git on this machine could not access $store (authentication or permission)$(_paxel_push_git_said). Your sessions are still here and push next time. Run 'paxel status' to check read and write access." ;;
    store_unreachable)
      echo "Push failed: could not reach $store. Your sessions are still here and push on the next run. Check the network, or run 'paxel status' to check read and write access." ;;
    store_not_configured)
      echo "Push did not run: the store settings in $PAXEL_CONFIG_FILE are incomplete. Rerun 'paxel setup'." ;;
    history_invalid)
      echo "Push did not run: history_since in $PAXEL_CONFIG_FILE is not a time, so push cannot tell which sessions to leave out. Nothing was written. Run 'paxel setup --since 7d' (or all, or none) to set it again." ;;
    scrub_unavailable)
      echo "Push refused: the credential scrubber cannot run (${_PXP_DETAIL:-unknown reason}). Nothing was written. Install jq 1.6 or later, then run 'paxel push' again." ;;
    git_missing)
      echo "Push refused: git is not installed. Install git 2.27 or later, then run 'paxel push' again." ;;
    push_rejected)
      echo "Push rejected: $store refused a commit with no new content, so a push rule (for example branch protection) blocks this machine. Nothing new was written. Check the repo's push rules for branch ${_PXP_BRANCH:-main}." ;;
    push_conflict)
      echo "Push failed: other machines pushed to $store at the same moment five times in a row. Your sessions push on the next run." ;;
    push_failed)
      echo "Push failed: git could not send the new commit to $store$(_paxel_push_git_said). Your sessions are still here and push on the next run. Run 'paxel status' to check write access." ;;
    push_timeout)
      echo "Push stopped: the link to $store was too slow for one part of the push${_PXP_DETAIL:+ (${_PXP_DETAIL})}. Parts that landed before it stay in the store, and the next push continues with the rest. If this repeats, push from a faster network, or give each part more time with 'PAXEL_PUSH_MIN_BYTES_PER_SEC=8192 paxel push --now' (the limit assumes at least 32768 bytes per second)." ;;
    commit_failed)
      echo "Push failed: git could not build the commit in this machine's copy of the store, $PAXEL_STORE_CLONE_DIR$(_paxel_push_git_said). Your sessions are still here and push on the next run. If this repeats, delete that folder; the next push makes a fresh copy." ;;
    local_io)
      echo "Push failed: $(_paxel_push_local_step_text). Your sessions are still here and push on the next run. Check free disk space, and that $PAXEL_HOME_DIR belongs to you." ;;
    lock_lost)
      echo "Push stopped: another machine sharing this home directory took over the push lock in $PAXEL_PUSH_DIR. It continues the push." ;;
    *)
      echo "Push failed for a reason this script does not recognize. Your sessions are still here and push on the next run." ;;
  esac
}

_paxel_push_local_step_text() {
  case "${_PXP_DETAIL:-}" in
    workdir) echo "could not create a working folder in $PAXEL_PUSH_DIR" ;;
    scan) echo "could not write the list of this machine's agent session files in $PAXEL_PUSH_DIR" ;;
    store_copy) echo "could not update this machine's copy of the store, $PAXEL_STORE_CLONE_DIR (if this repeats, delete that folder; the next push makes a fresh copy)" ;;
    *) echo "could not stage the scrubbed session files in $PAXEL_PUSH_DIR or $PAXEL_STORE_CLONE_DIR" ;;
  esac
}

# --- Paxel transcript store: setup, launcher and agent hooks ---

PAXEL_LAUNCHER_STATE=""
_PX_SETUP_USER=""
_PX_SETUP_CHOWN=0
_PX_SETUP_NEW_DIRS=""
_PX_SETUP_SHIM_DIR=""
_PX_SETUP_JQ_DIR=""
_PX_JQ_STATE=""
_PX_JQ_WHY=""
_PX_SETUP_CHANGED=0
_PX_SETUP_LOG=""
_PX_STORE_STATE=""
_PX_STORE_USABLE=1
_PX_CODEX_RESTART=0
_PX_MARKER=""
_PX_MARKER_BRANCH=""
_PX_MARKER_SCHEMA=""
_PX_SEED_PROBLEM=""
_PX_WAS_OFF=""
_PX_FLOOR_BEFORE=""
_PX_FLOOR_SET=0

# Where gh, glab and git's credential helper write their own state. Run as
# root for another account, they create these root-owned in its home.
_PX_CLI_STATE_DIRS=".config .config/gh .config/glab-cli .local .local/state .local/state/gh .local/share .cache"

# A Paxel hook is any command that runs <some home>/.paxel/bin/paxel hook
# <agent>, so an entry written for an old home path is still recognized.
_PX_CLAUDE_HOOK_RE='\.paxel/bin/paxel'"'"'?\s+hook\s+claude\s*$'
_PX_CODEX_HOOK_RE='\.paxel/bin/paxel'"'"'?\s+hook\s+codex\s*$'
_PX_NOTIFY_OURS_RE='^[[:space:]]*notify[[:space:]]*=[[:space:]]*\[[[:space:]]*"[^"]*/\.paxel/bin/paxel"[[:space:]]*,[[:space:]]*"hook"[[:space:]]*,[[:space:]]*"codex"[[:space:]]*\][[:space:]]*$'

_PX_JQ_HOOK_DEFS='
def is_paxel: type == "object" and ((.command // "") | type == "string" and test($re));
def has_paxel: type == "object" and (.hooks | type) == "array" and any(.hooks[]; is_paxel);
'

# Updates Paxel entries in place, appends a group for any event that has
# none, and leaves every other key and entry where it was.
_PX_JQ_CLAUDE_ADD='
def want: {type: "command", command: $cmd, timeout: 10};
def upsert($e):
  if any((.hooks[$e] // [])[]; has_paxel) then
    .hooks[$e] |= map(if has_paxel then .hooks |= map(if is_paxel then . + want else . end) else . end)
  else
    .hooks[$e] = ((.hooks[$e] // []) + [{hooks: [want]}])
  end;
.hooks = (.hooks // {}) | upsert("Stop") | upsert("StopFailure") | upsert("SessionEnd")
'

_PX_JQ_CLAUDE_REMOVE='
.hooks |= (to_entries | map(
  if (.value | type) == "array" and any(.value[]; has_paxel) then
    .value |= map(if has_paxel then (.hooks |= map(select(is_paxel | not))) | select(.hooks | length > 0) else . end)
    | select(.value | length > 0)
  else . end) | from_entries)
| if .hooks == {} then del(.hooks) else . end
'

# Codex keys hook trust to a group's position, so an emptied group keeps its
# place unless it is last; dropping it would shift later groups and void
# their trust.
_PX_JQ_CODEX_REMOVE='
def empty_group: type == "object" and (.hooks | type) == "array" and (.hooks | length) == 0;
.hooks |= (to_entries | map(
  if (.value | type) == "array" and any(.value[]; has_paxel) then
    .value |= (map(if has_paxel then .hooks |= map(select(is_paxel | not)) else . end)
               | until(length == 0 or (.[-1] | empty_group | not); .[:-1]))
    | select(.value | length > 0)
  else . end) | from_entries)
'

# Only an entry for the launcher's current path counts: the entry is frozen
# once written, so one for an old path is left alone and a new one appended.
_PX_JQ_CODEX_HAS_CMD='any((.hooks.Stop? // [])[]?; any((.hooks? // [])[]?; .command? == $cmd))'

# Setup runs inside provisioning (cloud-init, image builds, dotfiles
# installs): it reports every problem but always exits 0 so it never fails
# the script that called it.
paxel_cmd_setup() {
  _paxel_setup_main "$@" || true
  return 0
}

_paxel_setup_main() {
  local requested_user="" off=0 yes=0 since="" since_given=0 floor=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --user)
        if [ $# -lt 2 ] || [ -z "$2" ]; then
          _paxel_setup_warn "--user needs the name of the account the agents run as. Nothing was installed."
          return 1
        fi
        requested_user="$2"
        shift 2
        ;;
      --user=*) requested_user="${1#--user=}"; shift ;;
      --since)
        if [ $# -lt 2 ] || [ -z "$2" ]; then
          _paxel_setup_warn "--since needs a value: 7d, 2w, 1m, a date (YYYY-MM-DD), all or none. Nothing was installed."
          return 1
        fi
        since="$2"
        since_given=1
        shift 2
        ;;
      --since=*) since="${1#--since=}"; since_given=1; shift ;;
      --off) off=1; shift ;;
      --yes|-y) yes=1; shift ;;
      -h|--help) _paxel_setup_usage; return 0 ;;
      *)
        _paxel_setup_warn "unknown setup option '$1'. Nothing was installed."
        _paxel_setup_usage
        return 1
        ;;
    esac
  done
  if [ "$since_given" = 1 ] && ! floor=$(_paxel_setup_since_floor "$since"); then
    _paxel_setup_warn "--since takes 7d, 2w, 1m (any whole number up to 6 digits, with h, d, w or m for 30 days), a past date (YYYY-MM-DD), all or none, not '$since'. Nothing was installed."
    return 1
  fi
  _paxel_setup_pick_user "$requested_user" || return 1
  if ! _paxel_setup_safe_dir .paxel/bin || ! _paxel_setup_safe_dir .paxel/logs; then
    _paxel_setup_warn "$HOME/.paxel (or a folder in it) is a symbolic link or belongs to another account. Running as root, setup does not write through it. Remove it, or run setup as $_PX_SETUP_USER. Nothing was installed."
    return 1
  fi
  if [ -L "$PAXEL_CONFIG_FILE" ]; then
    _paxel_setup_warn "$PAXEL_CONFIG_FILE is a symbolic link, and setup does not read or write through one. Remove it and run setup again. Nothing was installed."
    return 1
  fi
  _paxel_setup_note_new_dirs
  _paxel_setup_ssh_as_user
  # Saved before any hook is registered, so no push can copy older history.
  if [ "$since_given" = 1 ] && ! _paxel_setup_save_floor "$floor"; then
    _paxel_setup_warn "could not save --since in $PAXEL_CONFIG_FILE. Nothing was installed."
    return 1
  fi
  if [ "$off" = 1 ]; then
    printf 'Paxel capture off for %s (%s)\n' "$_PX_SETUP_USER" "$HOME"
    paxel_refresh_launcher
    [ "$_PX_SETUP_CHOWN" = 1 ] || paxel_use_own_jq
    _paxel_setup_turn_off "You ran setup --off."
  else
    _paxel_setup_install "$yes"
  fi
  _paxel_setup_chown
  [ -z "$_PX_SETUP_SHIM_DIR" ] || rm -rf "$_PX_SETUP_SHIM_DIR"
  [ -z "$_PX_SETUP_JQ_DIR" ] || rm -rf "$_PX_SETUP_JQ_DIR"
}

_paxel_setup_usage() {
  cat <<'PAXEL_SETUP_USAGE'
Usage: paxel setup [--user NAME] [--since WHEN] [--off] [--yes]
  --user NAME  install for NAME, the account Claude Code and Codex run as (needed when running as root)
  --since WHEN push only sessions active since WHEN: 7d, 2w, 1m, a date (YYYY-MM-DD), all (the first setup's
               default) or none (only sessions from now on); a later setup without it keeps the saved choice
  --off        remove the Paxel agent hooks and stop pushes; run setup again to turn capture back on
  --yes        create a missing store without asking
PAXEL_SETUP_USAGE
}

_paxel_setup_install() {
  local yes="$1" problems store_rc=0 installed="Only the launcher was installed."
  printf 'Paxel setup (alpha) for %s (%s)\n' "$_PX_SETUP_USER" "$HOME"
  if ! paxel_write_launcher "$(_paxel_setup_server)"; then
    if _paxel_launcher_server_ok "$(_paxel_setup_server)"; then
      _paxel_setup_warn "could not write $HOME/.paxel/bin/paxel. Check that $HOME exists and $_PX_SETUP_USER can write to it. Nothing was installed."
    else
      _paxel_setup_warn "could not write $HOME/.paxel/bin/paxel for server '${PAXEL_SERVER:-}': it needs an https:// server (or http://localhost for development). Nothing was installed."
    fi
    return 1
  fi
  _paxel_setup_item launcher "$PAXEL_LAUNCHER_STATE" "~/.paxel/bin/paxel"
  _paxel_setup_jq || true
  problems=$(_paxel_setup_preflight)
  if [ -n "$problems" ]; then
    [ "$_PX_JQ_STATE" != installed ] || installed="Only the launcher and jq were installed."
    _paxel_setup_warn "capture needs $problems.${_PX_JQ_WHY:+ Setup could not install jq $PAXEL_JQ_VERSION in ~/.paxel/bin: $_PX_JQ_WHY.} $installed Install the missing tools, then run: $HOME/.paxel/bin/paxel setup"
    return 1
  fi

  if _paxel_setup_cli_dirs_safe; then
    _paxel_setup_store "$yes" || store_rc=$?
  else
    _paxel_setup_store_missing "a gh or glab settings folder in $HOME (.config, .local or .cache) is a symbolic link or belongs to another account. Running as root, setup does not let gh or glab write through it. Run $HOME/.paxel/bin/paxel setup as $_PX_SETUP_USER.$(_paxel_setup_retry_hint)"
  fi
  if [ "$store_rc" = 3 ]; then
    _paxel_setup_turn_off "PAXEL_STORE is set and empty."
    return 0
  fi
  _PX_WAS_OFF=$(paxel_config_get off_at)
  _paxel_setup_config_put off_at ""
  _paxel_setup_claude_hooks || true
  _paxel_setup_codex_hooks || true
  # Root installing for another account sees root's environment, not the
  # agents'.
  [ "$_PX_SETUP_CHOWN" = 1 ] || _paxel_setup_agent_dir_warnings
  _paxel_setup_check_store_access
  if [ -n "${PAXEL_NO_SKILL:-}" ]; then
    _paxel_setup_item skill skipped "PAXEL_NO_SKILL is set"
  elif declare -F paxel_install_skill >/dev/null; then
    paxel_install_skill "$HOME" || true
  fi
  _paxel_setup_config_put target_user "$_PX_SETUP_USER"
  _paxel_setup_config_put launcher_server "$(_paxel_setup_server)"
  _paxel_setup_config_put tool_path "$(_paxel_setup_tool_path)"
  if [ "$_PX_SETUP_CHANGED" = 1 ] || [ -z "$(paxel_config_get setup_at)" ]; then
    paxel_config_set setup_at "$(paxel_now_iso)"
  fi
  paxel_log "setup$_PX_SETUP_LOG"
  _paxel_setup_footer
}

# --- History floor ---

# WHEN -> the history floor as an epoch, or nothing for all history. Reads
# what the upload's --since reads (Nh, Nd, Nw, Nm as 30 days, YYYY-MM-DD at
# local midnight), plus none (now). Status 1 for anything else.
_paxel_setup_since_floor() {
  local v="$1" n now e
  now=$(paxel_now_epoch)
  case "$v" in
    all) return 0 ;;
    none) printf '%s\n' "$now"; return 0 ;;
    [0-9]*[hdwm])
      n=${v%?}
      paxel_is_uint "$n" && [ "${#n}" -le 6 ] || return 1
      n=$((10#$n))
      case "$v" in
        *h) n=$((n * 3600)) ;;
        *d) n=$((n * 86400)) ;;
        *w) n=$((n * 604800)) ;;
        *m) n=$((n * 2592000)) ;;
      esac
      # A span reaching back before 1970 is all history.
      [ "$n" -lt "$now" ] || return 0
      printf '%s\n' "$((now - n))"
      ;;
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9])
      e=$(date -d "$v" +%s 2>/dev/null || date -j -f '%Y-%m-%d %H:%M:%S' "$v 00:00:00" +%s 2>/dev/null || true)
      paxel_is_uint "$e" && [ "${#e}" -le 12 ] && [ "$e" -le "$now" ] || return 1
      printf '%s\n' "$e"
      ;;
    *) return 1 ;;
  esac
}

_paxel_setup_save_floor() {
  _PX_FLOOR_BEFORE=$(paxel_config_get history_since)
  _paxel_setup_config_put history_since "$1" || return 1
  _PX_FLOOR_SET=1
  _PX_SETUP_LOG="$_PX_SETUP_LOG history_since=${1:-all}"
}

# Prints the footer line for a floor this run moved earlier, or nothing.
_paxel_setup_floor_widened() {
  local new old="$_PX_FLOOR_BEFORE"
  new=$(paxel_config_get history_since)
  [ "$_PX_FLOOR_SET" = 1 ] && paxel_is_uint "$old" || return 0
  if [ -z "$new" ]; then
    printf 'The next push also copies the sessions last active before %s, now that all history is pushed.\n' "$(paxel_epoch_iso "$old")"
  elif paxel_is_uint "$new" && [ "${#new}" -le 12 ] && [ "${#old}" -le 12 ] && [ "$new" -lt "$old" ]; then
    printf 'The next push also copies the sessions last active between %s and %s.\n' "$(paxel_epoch_iso "$new")" "$(paxel_epoch_iso "$old")"
  fi
}

_paxel_setup_server() {
  local server="${PAXEL_SERVER:-}"
  printf '%s\n' "${server%/}"
}

# --- Target user ---

# Sets the target account and points HOME (and the Paxel paths) at its home.
_paxel_setup_pick_user() {
  local requested="$1" uid me user home
  uid=$(id -u 2>/dev/null || true)
  me=$(id -un 2>/dev/null || printf '%s' "${USER:-}")
  if [ -n "$requested" ] && ! _paxel_setup_valid_user "$requested"; then
    _paxel_setup_warn "'$requested' is not a valid account name. Nothing was installed."
    return 1
  fi
  if [ "$uid" = 0 ]; then
    user="$requested"
    if [ -z "$user" ] && [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ]; then
      user="$SUDO_USER"
    fi
    if [ -z "$user" ]; then
      _paxel_setup_warn "running as root with no --user, so nothing was installed. Run setup again with --user <account> (the account that runs Claude Code or Codex), or --user root if the agents run as root."
      return 1
    fi
    home=$(_paxel_setup_user_home "$user") || home=""
    if [ -z "$home" ] && [ "$user" = "$me" ]; then home="${HOME:-}"; fi
    if [ -z "$home" ]; then
      _paxel_setup_warn "could not find the home directory of '$user'. Create the account first, or check the name. Nothing was installed."
      return 1
    fi
    [ "$user" = root ] || _PX_SETUP_CHOWN=1
  else
    if [ -n "$requested" ] && [ "$requested" != "$me" ]; then
      _paxel_setup_warn "only root can install for another account ('$requested'); you are '$me'. Nothing was installed."
      return 1
    fi
    user="$me"
    home="$HOME"
  fi
  _PX_SETUP_USER="$user"
  if [ "$home" != "${HOME:-}" ]; then
    export HOME="$home"
    unset XDG_CONFIG_HOME XDG_STATE_HOME XDG_CACHE_HOME XDG_DATA_HOME
  fi
  # git run as root would read that account's ~/.gitconfig, whose url and
  # protocol settings can make git run a command. Setup needs none of it.
  [ "$_PX_SETUP_CHOWN" != 1 ] || export GIT_CONFIG_GLOBAL=/dev/null
  # Root runs the jq and ssh it stages in temp folders. In a TMPDIR another
  # account owns, that account could rename one and swap in its own; /tmp is
  # sticky, so it cannot.
  [ "$_PX_SETUP_CHOWN" != 1 ] || export TMPDIR=/tmp
  PAXEL_HOME_DIR="$HOME/.paxel"
  PAXEL_CONFIG_FILE="$PAXEL_HOME_DIR/config"
}

_paxel_setup_valid_user() {
  case "${1:-}" in ''|-*|*[!A-Za-z0-9._-]*) return 1 ;; esac
  return 0
}

# PAXEL_TEST_USER_HOME stands in for the passwd lookup in bats.
_paxel_setup_user_home() {
  local user="$1" home=""
  if [ -n "${PAXEL_TEST_USER_HOME:-}" ]; then
    home="$PAXEL_TEST_USER_HOME"
  elif command -v getent >/dev/null 2>&1; then
    home=$(getent passwd "$user" 2>/dev/null | cut -d: -f6)
  elif command -v dscl >/dev/null 2>&1; then
    home=$(dscl . -read "/Users/$user" NFSHomeDirectory 2>/dev/null | sed -n 's/^NFSHomeDirectory: *//p')
  fi
  case "$home" in /*) ;; *) return 1 ;; esac
  [ -d "$home" ] || return 1
  printf '%s\n' "$home"
}

# Root writing into another account's home must not follow a link that
# account planted (say ~/.claude -> /root/.claude). Each folder of REL below
# HOME must be missing (setup creates it) or a real folder owned by that
# account or by root. A link swapped in after this check is not caught; no
# bash write can refuse to follow one.
_paxel_setup_safe_dir() {
  local rest="$1" path="$HOME" part uid
  [ "$_PX_SETUP_CHOWN" = 1 ] || return 0
  uid=$(id -u "$_PX_SETUP_USER" 2>/dev/null) || return 1
  paxel_is_uint "$uid" || return 1
  while [ -n "$rest" ]; do
    part="${rest%%/*}"
    if [ "$part" = "$rest" ]; then rest=""; else rest="${rest#*/}"; fi
    path="$path/$part"
    [ ! -L "$path" ] || return 1
    [ -e "$path" ] || return 0
    [ -d "$path" ] || return 1
    [ -n "$(find "$path" -maxdepth 0 \( -user "$uid" -o -user 0 \) -print 2>/dev/null)" ] || return 1
  done
}

_paxel_setup_cli_dirs_safe() {
  local p
  for p in $_PX_CLI_STATE_DIRS; do
    _paxel_setup_safe_dir "$p" || return 1
  done
}

# FILE: a new empty temp file next to FILE, named so no one can guess it.
_paxel_setup_tmp() {
  mktemp "$1.paxel-tmp.XXXXXX" 2>/dev/null
}

# gh and glab stay root here: the store part hands them root-only temp files
# (a commits API body, for one). So setup notes which of their state folders
# are missing now, and gives the ones they create to the account at the end.
_paxel_setup_note_new_dirs() {
  local p
  _PX_SETUP_NEW_DIRS=""
  [ "$_PX_SETUP_CHOWN" = 1 ] || return 0
  for p in $_PX_CLI_STATE_DIRS; do
    [ -e "$HOME/$p" ] || [ -L "$HOME/$p" ] || _PX_SETUP_NEW_DIRS="$_PX_SETUP_NEW_DIRS $p"
  done
}

# ssh reads the keys of the account it runs as, whatever HOME says, so the
# store transport check (and git over ssh) must run ssh as the target
# account. A shim early on PATH does that for every ssh call setup makes.
_paxel_setup_ssh_as_user() {
  local real runner dir
  [ "$_PX_SETUP_CHOWN" = 1 ] || return 0
  real=$(command -v ssh 2>/dev/null) || return 0
  case "$real" in /*) ;; *) return 0 ;; esac
  if command -v runuser >/dev/null 2>&1; then
    runner="runuser -u $_PX_SETUP_USER --"
  elif command -v sudo >/dev/null 2>&1; then
    runner="sudo -n -H -u $_PX_SETUP_USER --"
  else
    return 0
  fi
  dir=$(mktemp -d "${TMPDIR:-/tmp}/paxel-setup-bin.XXXXXX") || return 0
  printf '#!/bin/bash\nexec %s %q "$@"\n' "$runner" "$real" > "$dir/ssh" && chmod 755 "$dir/ssh" || { rm -rf "$dir"; return 0; }
  _PX_SETUP_SHIM_DIR="$dir"
  PATH="$dir:$PATH"
}

# Files root writes into another account's home must belong to that account,
# or the agents and the push worker cannot update them later.
_paxel_setup_chown() {
  local owner="$_PX_SETUP_USER" group p
  [ "$_PX_SETUP_CHOWN" = 1 ] || return 0
  group=$(id -gn "$_PX_SETUP_USER" 2>/dev/null || true)
  [ -z "$group" ] || owner="$owner:$group"
  # The skill part hands over the skill folders it creates itself.
  for p in .paxel $_PX_SETUP_NEW_DIRS; do
    _paxel_setup_safe_parent "$p" || continue
    if [ -e "$HOME/$p" ] && [ ! -L "$HOME/$p" ]; then chown -R -h "$owner" "$HOME/$p" 2>/dev/null || true; fi
  done
  for p in .claude .claude/settings.json .claude/settings.json.paxel.bak \
           .codex .codex/config.toml .codex/config.toml.paxel.bak \
           .codex/hooks.json .codex/hooks.json.paxel.bak; do
    _paxel_setup_safe_parent "$p" || continue
    if [ -e "$HOME/$p" ] || [ -L "$HOME/$p" ]; then chown -h "$owner" "$HOME/$p" 2>/dev/null || true; fi
  done
}

# chown -h leaves the last part of a path alone if it is a link, but follows
# a link anywhere above it.
_paxel_setup_safe_parent() {
  case "$1" in
    */*) _paxel_setup_safe_dir "${1%/*}" ;;
    *) return 0 ;;
  esac
}

# --- Preflight ---

# Prints the missing or too-old tools as one phrase, or nothing.
_paxel_setup_preflight() {
  local problems="" v
  if ! command -v git >/dev/null 2>&1; then
    problems="git 2.27 or later (not installed)"
  else
    v=$(git --version 2>/dev/null || true)
    _paxel_setup_version_ge "$v" 2 27 || problems="git 2.27 or later (found ${v:-no version})"
  fi
  if ! command -v jq >/dev/null 2>&1; then
    problems="${problems:+$problems; }jq 1.6 or later (not installed)"
  else
    v=$(jq --version 2>/dev/null || true)
    if ! _paxel_setup_version_ge "$v" 1 6; then
      problems="${problems:+$problems; }jq 1.6 or later (found ${v:-no version})"
    elif ! jq -n '"a" | test("a")' >/dev/null 2>&1; then
      problems="${problems:+$problems; }jq with regex support (this jq was built without it)"
    fi
  fi
  command -v curl >/dev/null 2>&1 || problems="${problems:+$problems; }curl (not installed)"
  printf '%s' "$problems"
}

# The folders setup found gh, glab, jq and git in, joined like PATH, for the
# launcher to add to a push's PATH. Root's copy of jq lives in a folder setup
# deletes, so it is left out.
_paxel_setup_tool_path() {
  local tool p dir out=""
  for tool in gh glab jq git; do
    p=$(command -v "$tool" 2>/dev/null) || continue
    case "$p" in /*) ;; *) continue ;; esac
    dir=${p%/*}
    [ -n "$dir" ] || dir=/
    [ -z "$_PX_SETUP_JQ_DIR" ] || [ "$dir" != "$_PX_SETUP_JQ_DIR" ] || continue
    case "$dir" in *:*|*$'\n'*) continue ;; esac
    case ":$out:" in *":$dir:"*) ;; *) out="${out:+$out:}$dir" ;; esac
  done
  printf '%s\n' "$out"
}

# --- jq ---

# The official static jq that setup installs as ~/.paxel/bin/jq when the jq
# on PATH cannot run the scrub. The checksums are the release's sha256sum.txt.
PAXEL_JQ_VERSION=1.8.2

# Prints setup's jq line. Status 1 when no usable jq is left on PATH, with
# _PX_JQ_WHY saying why setup could not install one.
_paxel_setup_jq() {
  local problem
  if paxel_jq_usable jq; then
    _paxel_setup_item jq unchanged "$(jq --version 2>/dev/null </dev/null || true) at $(command -v jq 2>/dev/null || true)"
    return 0
  fi
  problem=$(_paxel_setup_jq_problem)
  if _paxel_setup_jq_install; then
    _paxel_setup_item jq "$_PX_JQ_STATE" "jq-$PAXEL_JQ_VERSION at ~/.paxel/bin/jq ($problem)"
    return 0
  fi
  # A build an earlier setup installed still runs the scrub.
  [ "$_PX_SETUP_CHOWN" = 1 ] || paxel_use_own_jq
  if paxel_jq_usable jq; then
    _paxel_setup_item jq unchanged "$(jq --version 2>/dev/null </dev/null || true) at ~/.paxel/bin/jq ($problem; could not update to jq-$PAXEL_JQ_VERSION: $_PX_JQ_WHY)"
    _PX_JQ_WHY=""
    return 0
  fi
  _paxel_setup_item jq "not installed" "$problem"
  return 1
}

# Why the jq on PATH cannot run the scrub.
_paxel_setup_jq_problem() {
  local p v
  if ! p=$(command -v jq 2>/dev/null); then
    printf 'no jq on PATH'
    return 0
  fi
  v=$(jq --version 2>/dev/null </dev/null || true)
  if _paxel_setup_version_ge "$v" 1 6; then
    printf '%s at %s has no regex support' "$v" "$p"
  else
    printf '%s at %s is older than 1.6' "${v:-a jq with no version}" "$p"
  fi
}

# Makes ~/.paxel/bin/jq this script's pinned build, downloading it unless an
# earlier setup did, and puts it first on PATH for the rest of setup. Sets
# _PX_JQ_STATE to installed or unchanged, or _PX_JQ_WHY on failure.
_paxel_setup_jq_install() {
  local asset sha dir
  if ! asset=$(_paxel_setup_jq_asset); then
    _PX_JQ_WHY="jq publishes no build for $(uname -s 2>/dev/null || true) $(uname -m 2>/dev/null || true)"
    return 1
  fi
  sha=${asset#* }
  asset=${asset%% *}
  # Root's copy must sit where the account cannot rename it; anyone else's
  # stays off a /tmp that may be mounted noexec.
  if [ "$_PX_SETUP_CHOWN" = 1 ]; then
    dir=$(mktemp -d "${TMPDIR:-/tmp}/paxel-jq.XXXXXX" 2>/dev/null) || dir=""
  else
    dir=$(mktemp -d "$PAXEL_HOME_DIR/jq-download.XXXXXX" 2>/dev/null) || dir=""
  fi
  if [ -z "$dir" ]; then
    _PX_JQ_WHY="could not make a temporary folder for the download"
    return 1
  fi
  _PX_SETUP_JQ_DIR="$dir"
  if _paxel_setup_jq_current "$dir" "$sha"; then
    _PX_JQ_STATE=unchanged
  elif _paxel_setup_jq_download "$dir" "$asset" "$sha" && _paxel_setup_jq_save "$dir/jq"; then
    _PX_JQ_STATE=installed
  else
    return 1
  fi
  _PX_JQ_WHY=""
  # Root setting up another account runs its own checked copy, never the
  # file in that account's home, which the account could swap.
  if [ "$_PX_SETUP_CHOWN" = 1 ]; then
    PATH="$dir:$PATH"
  else
    PATH="$PAXEL_HOME_DIR/bin:$PATH"
  fi
  export PATH
}

# Prints "<asset> <sha256>" for this machine; status 1 when jq publishes no
# build for it.
_paxel_setup_jq_asset() {
  case "$(uname -s 2>/dev/null || true) $(uname -m 2>/dev/null || true)" in
    "Linux x86_64"|"Linux amd64") printf 'jq-linux-amd64 b1c22172dd303f3be49e935aa56aa48a8b7a46e0bc838b4997d3bb451495870f\n' ;;
    "Linux aarch64"|"Linux arm64") printf 'jq-linux-arm64 8b85c817833814ddca00a144c33705546355afccf0cf39b188f3cdb48b852309\n' ;;
    "Darwin x86_64") printf 'jq-macos-amd64 e94b266e3c26690550006abe63152b782280f4e14374accdf04cbde844f00bc0\n' ;;
    "Darwin arm64") printf 'jq-macos-arm64 2d75340ba57a4b4b4c8708a21c2dc8e958a48aaa8bba13b27f77f6e4c0eca07e\n' ;;
    *) return 1 ;;
  esac
}

# The jq an earlier setup saved is the pinned build. Checked on a copy in DIR.
_paxel_setup_jq_current() {
  local own="$PAXEL_HOME_DIR/bin/jq"
  [ -f "$own" ] && [ ! -L "$own" ] && cp "$own" "$1/jq" 2>/dev/null || return 1
  _paxel_setup_jq_verify "$1/jq" "$2"
}

_paxel_setup_jq_download() {
  local dir="$1" sha="$3" url err
  url="https://github.com/jqlang/jq/releases/download/jq-$PAXEL_JQ_VERSION/$2"
  rm -f "$dir/jq"
  if ! command -v curl >/dev/null 2>&1; then
    _PX_JQ_WHY="curl is not installed"
    return 1
  fi
  if ! curl -fsSL --proto '=https' --proto-redir '=https' --tlsv1.2 --connect-timeout 10 --max-time 120 \
       -o "$dir/jq" "$url" 2> "$dir/curl.err" < /dev/null; then
    rm -f "$dir/jq"
    err=$(sed -n '1s/^curl: //p' "$dir/curl.err" 2>/dev/null || true)
    _PX_JQ_WHY="downloading $url failed${err:+: $err}"
    return 1
  fi
  _paxel_setup_jq_verify "$dir/jq" "$sha"
}

# FILE has the pinned SHA256 and runs as the pinned jq with regex support;
# otherwise it is deleted and _PX_JQ_WHY says why.
_paxel_setup_jq_verify() {
  local file="$1" got="" why=""
  if command -v sha256sum >/dev/null 2>&1; then
    got=$(sha256sum < "$file" 2>/dev/null | cut -d' ' -f1 || true)
  elif command -v shasum >/dev/null 2>&1; then
    got=$(shasum -a 256 < "$file" 2>/dev/null | cut -d' ' -f1 || true)
  else
    why="neither sha256sum nor shasum is installed to check the download, so it was deleted"
  fi
  if [ -z "$why" ] && [ "$got" != "$2" ]; then
    why="its sha256 did not match the checksum this script pins for it, so it was deleted"
  fi
  if [ -z "$why" ]; then
    chmod 755 "$file" 2>/dev/null || true
    if [ "$("$file" --version 2>/dev/null </dev/null || true)" = "jq-$PAXEL_JQ_VERSION" ] && paxel_jq_usable "$file"; then
      return 0
    fi
    why="the downloaded jq did not run on this machine, so it was deleted"
  fi
  rm -f "$file"
  _PX_JQ_WHY="$why"
  return 1
}

_paxel_setup_jq_save() {
  local own="$PAXEL_HOME_DIR/bin/jq" tmp=""
  if tmp=$(mktemp "$own.tmp.XXXXXX" 2>/dev/null) && cp "$1" "$tmp" && chmod 755 "$tmp" && mv -f "$tmp" "$own"; then
    return 0
  fi
  [ -z "$tmp" ] || rm -f "$tmp"
  _PX_JQ_WHY="could not write $own"
  return 1
}

# VERSION_TEXT MAJOR MINOR: compares the first X.Y found in the text.
_paxel_setup_version_ge() {
  local mm maj min
  mm=$(printf '%s\n' "$1" | sed -n 's/^[^0-9]*\([0-9][0-9]*\)\.\([0-9][0-9]*\).*/\1 \2/p' | sed -n 1p)
  maj=${mm% *}
  min=${mm#* }
  paxel_is_uint "$maj" && paxel_is_uint "$min" || return 1
  [ "$maj" -gt "$2" ] || { [ "$maj" -eq "$2" ] && [ "$min" -ge "$3" ]; }
}

# --- Launcher ---

# SERVER_URL is baked into ~/.paxel/bin/paxel. Sets PAXEL_LAUNCHER_STATE to
# created, updated or unchanged; status 1 for an unusable URL or a failed
# write.
paxel_write_launcher() {
  local server="${1:-}" dir target tmp
  server=${server%/}
  _paxel_launcher_server_ok "$server" || return 1
  dir="$PAXEL_HOME_DIR/bin"
  target="$dir/paxel"
  mkdir -p "$dir" 2>/dev/null || return 1
  chmod 700 "$PAXEL_HOME_DIR" 2>/dev/null || true
  tmp=$(mktemp "$target.tmp.XXXXXX" 2>/dev/null) || return 1
  if ! _paxel_launcher_text "$server" > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  # Every hook runs this file, and a Claude Stop hook that exits 2 (bash's
  # status for a syntax error) blocks the agent from stopping.
  if ! bash -n "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    return 1
  fi
  chmod 755 "$tmp"
  if [ -f "$target" ] && [ ! -L "$target" ] && cmp -s "$tmp" "$target"; then
    rm -f "$tmp"
    chmod 755 "$target" 2>/dev/null || true
    PAXEL_LAUNCHER_STATE=unchanged
    return 0
  fi
  if [ -e "$target" ]; then PAXEL_LAUNCHER_STATE=updated; else PAXEL_LAUNCHER_STATE=created; fi
  # rename, never rewrite in place: a hook may be executing the old launcher
  mv -f "$tmp" "$target" || { rm -f "$tmp"; return 1; }
}

_paxel_launcher_server_ok() {
  case "$1" in
    https://?*|http://localhost|http://localhost:*|http://127.0.0.1|http://127.0.0.1:*) ;;
    *) return 1 ;;
  esac
  case "$1" in *[!A-Za-z0-9._~:/-]*) return 1 ;; esac
}

# Run by commands the launcher started (PAXEL_LAUNCHER=1): rewrites
# ~/.paxel/bin/paxel when this script carries a newer launcher text, so a
# fix to the launcher reaches boxes that never run setup again. Quiet, and
# never fails the command.
paxel_refresh_launcher() {
  local server
  [ "${PAXEL_LAUNCHER:-}" = 1 ] || return 0
  server=$(paxel_config_get launcher_server)
  [ -n "$server" ] || return 0
  paxel_write_launcher "$server" >/dev/null 2>&1 || true
  return 0
}

_paxel_launcher_text() {
  printf '#!/bin/bash\n# paxel-launcher v1 (written by `paxel setup`)\nPAXEL_LAUNCHER_SERVER="%s"\n' "$1"
  cat <<'PAXEL_LAUNCHER_EOF'
P="${HOME}/.paxel"
if [ "${1:-}" = "hook" ]; then
  case "${2:-}" in claude|codex) t="$2" ;; *) t=unknown ;; esac
  # Claude and a Codex hooks.json hook pass the hook input on a pipe of their
  # own; drain it so a large payload never blocks or breaks the agent's
  # write. Codex notify passes its payload as an argument and inherits
  # Codex's own stdin, which must never be read.
  if { [ "$t" = claude ] || { [ "$t" = codex ] && [ $# -eq 2 ]; }; } && [ ! -t 0 ]; then
    cat >/dev/null 2>&1 <&0 &
  fi
  paxel_hook_trigger() {
    [ "${PAXEL_CAPTURE:-1}" = "0" ] && return 0
    mkdir -p "$P/push" 2>/dev/null || return 0
    touch "$P/push/pending" "$P/push/last_trigger_$t" 2>/dev/null || return 0
    [ -e "$P/push/first_pending" ] || touch "$P/push/first_pending" 2>/dev/null
    # A live worker picks up the new pending marker itself.
    if [ -d "$P/push/lock" ]; then
      h="" pid="" hb=""
      [ -r "$P/push/lock/owner" ] && IFS=$'\t' read -r h pid hb < "$P/push/lock/owner"
      case "$pid" in ''|*[!0-9]*) pid="" ;; esac
      case "$hb" in ''|*[!0-9]*) hb="" ;; esac
      [ "${#hb}" -le 12 ] || hb=""
      stale="${PAXEL_LOCK_STALE_SECS:-300}"
      case "$stale" in ''|*[!0-9]*) stale=300 ;; esac
      # Same rule and host name as paxel_push_lock_alive: the heartbeat is
      # fresh and, on this host, the pid runs (a reused pid has no heartbeat).
      me=$(hostname 2>/dev/null || uname -n 2>/dev/null || echo unknown)
      if [ -n "$hb" ] && [ $(( $(date +%s) - 10#$hb )) -lt "$stale" ]; then
        if [ "$h" != "$me" ] || { [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; }; then
          return 0
        fi
      fi
    fi
    # The agents kill hook processes after a few seconds: detach the worker.
    # The subshell leaves it no parent, so a saved notify program the launcher
    # execs next never inherits it as a child.
    mkdir -p "$P/logs" 2>/dev/null
    log="$P/logs/push-$(date -u +%Y%m%d).log"
    if command -v setsid >/dev/null 2>&1; then
      ( setsid "$0" push --worker </dev/null >>"$log" 2>&1 & )
    else
      ( nohup "$0" push --worker </dev/null >>"$log" 2>&1 & )
    fi
  }
  paxel_hook_trigger
  # Codex runs one notify program, so setup saves the one Paxel's notify
  # replaced in codex-notify-chain (NUL-separated: a tag, its TOML text, its
  # argv). It runs after Paxel's step, whatever that did, with Codex's
  # payload argument and stdio. PAXEL_CODEX_CHAINED keeps a saved program
  # that calls this launcher again from looping.
  if [ "$t" = codex ] && [ $# -ge 3 ] && [ -f "$P/codex-notify-chain" ] && [ -z "${PAXEL_CODEX_CHAINED:-}" ]; then
    shift 2
    c=()
    { IFS= read -r -d '' a && [ "$a" = paxel-codex-notify-chain-v1 ] && IFS= read -r -d '' a &&
      while IFS= read -r -d '' a; do c[${#c[@]}]="$a"; done; } < "$P/codex-notify-chain" 2>/dev/null
    if [ "${#c[@]}" -gt 0 ] && [ -n "${c[0]}" ]; then
      PAXEL_CODEX_CHAINED=1 exec "${c[@]}" "$@"
    fi
  fi
  exit 0
fi
mkdir -p "$P" 2>/dev/null
dl="$P/paxel.sh.download.$$"
case "$PAXEL_LAUNCHER_SERVER" in
  http://localhost|http://localhost:*|http://127.0.0.1|http://127.0.0.1:*) proto="" ;;
  *) proto="--proto =https" ;;
esac
why=""
if curl -fsS --compressed $proto --tlsv1.2 --connect-timeout 5 --max-time 30 \
     -A paxel-launcher/1 -o "$dl" "$PAXEL_LAUNCHER_SERVER/paxel.sh" 2>/dev/null; then
  if [ "$(tail -n 1 "$dl" 2>/dev/null)" != "# paxel-script-end" ]; then
    why="the download was incomplete"
  elif ! bash -n "$dl" 2>/dev/null; then
    why="the download failed a syntax check"
  fi
else
  why="curl exit $?"
fi
if [ -z "$why" ]; then
  if [ -f "$P/paxel.sh" ] && ! cmp -s "$dl" "$P/paxel.sh"; then
    cp -p "$P/paxel.sh" "$P/paxel.sh.prev.$$" 2>/dev/null && mv -f "$P/paxel.sh.prev.$$" "$P/paxel.sh.prev"
  fi
  # rename, never rewrite in place: a running worker is still reading the old copy
  mv -f "$dl" "$P/paxel.sh"
else
  rm -f "$dl"
  if [ ! -f "$P/paxel.sh" ]; then
    echo "paxel: could not fetch $PAXEL_LAUNCHER_SERVER/paxel.sh ($why) and there is no cached copy. Check that this machine can reach $PAXEL_LAUNCHER_SERVER, then run the command again." >&2
    exit 1
  fi
  echo "paxel: could not fetch $PAXEL_LAUNCHER_SERVER/paxel.sh ($why); running the cached copy." >&2
fi
# Hook-started pushes inherit the agents' PATH, which a service or an app
# often starts shorter than setup's: add the tool folders setup saved.
if [ "${1:-}" = push ] && [ -f "$P/config" ] && [ ! -L "$P/config" ]; then
  while IFS= read -r d; do
    case "$d" in /*) ;; *) continue ;; esac
    case ":$PATH:" in *":$d:"*) continue ;; esac
    [ -d "$d" ] && PATH="$PATH:$d"
  done <<< "$(sed -n 's/^tool_path=//p' "$P/config" 2>/dev/null | tail -n 1 | tr ':' '\n')"
  export PATH
fi
PAXEL_LAUNCHER=1 exec bash "$P/paxel.sh" "$@"
PAXEL_LAUNCHER_EOF
}

# --- Store ---

# Resolves the store and saves it to the config. A store saved by an earlier
# run is checked again and kept unless PAXEL_STORE names another, so an org
# store given once still holds after `setup --off` and a rerun. Status 3:
# PAXEL_STORE turns capture off; status 1: no usable store yet (hooks are
# still registered, and push refuses to run until setup finds one).
_paxel_setup_store() {
  local yes="$1" out rc=0 saved
  saved=$(_paxel_setup_saved_store)
  if [ "${PAXEL_STORE+set}" != set ] && [ -n "$saved" ] && _paxel_setup_valid_display "$saved"; then
    out=$(PAXEL_STORE="$saved" paxel_store_resolve) || rc=$?
  else
    saved=""
    _paxel_setup_cli_notes
    out=$(paxel_store_resolve) || rc=$?
  fi
  case "$rc" in
    0) ;;
    3) return 3 ;;
    1)
      if [ -n "${PAXEL_STORE:-}" ]; then
        _paxel_setup_store_missing "PAXEL_STORE does not name a store setup can use. Set it to host/owner/name with no credentials in it (for example github.com/acme/paxel-transcripts), then run: $HOME/.paxel/bin/paxel setup"
      elif ! _paxel_setup_codespace_store_missing; then
        _paxel_setup_store_missing "no store: neither gh nor glab is logged in on this machine. Log in with 'gh auth login' (GitHub) or 'glab auth login' (GitLab), and push finds or creates the store on its own (it looks at most once an hour, after an agent turn), or run $HOME/.paxel/bin/paxel setup to do it now. For another repo, set PAXEL_STORE=host/owner/name and run setup."
      fi
      return 1
      ;;
    *)
      _paxel_setup_codespace_store_missing ||
        _paxel_setup_store_missing "could not check for a store (network error or rate limit). Run $HOME/.paxel/bin/paxel setup again once the network is back.$(_paxel_setup_retry_hint)"
      return 1
      ;;
  esac
  if ! _paxel_setup_parse_resolved "${out%%$'\n'*}"; then
    _paxel_setup_store_missing "the store lookup returned an unusable name. Set PAXEL_STORE=host/owner/name and run $HOME/.paxel/bin/paxel setup again.$(_paxel_setup_retry_hint)"
    return 1
  fi
  if [ "$_PX_RES_KIND" = new ]; then
    _paxel_setup_store_create "$yes" || return 1
  else
    _paxel_setup_store_existing
  fi
  _paxel_setup_save_store
  _paxel_setup_item store "$_PX_STORE_STATE" "$_PX_RES_DISPLAY ($(_paxel_setup_store_via))"
  if [ -n "$saved" ]; then
    printf '  note: kept the store an earlier setup saved. To use another one, run setup with PAXEL_STORE=host/owner/name.\n'
  fi
  _paxel_setup_env_token_note
  _paxel_setup_store_warnings
}

# Pushes that agent hooks start run in the agents' environment, not this
# shell's, so a CLI logged in here only through a token variable may have no
# login there. A codespace's secrets reach every process in it.
_paxel_setup_env_token_note() {
  local names v set_vars=""
  [ "$(paxel_config_get store_transport)" = https ] && [ "${CODESPACES:-}" != true ] || return 0
  case "$_PX_RES_CLI" in
    gh) names="GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN" ;;
    glab) names="GITLAB_TOKEN GITLAB_ACCESS_TOKEN OAUTH_TOKEN" ;;
    *) return 0 ;;
  esac
  for v in $names; do
    [ -z "${!v:-}" ] || set_vars="${set_vars:+$set_vars or }$v"
  done
  [ -n "$set_vars" ] || return 0
  if _paxel_store_cli_stored_token "$_PX_RES_CLI" "$_PX_RES_HOST"; then return 0; fi
  printf "  note: %s is logged in here only through %s. Pushes that agent hooks start run in the agents' environment, so the agents need %s too (for example as a platform secret), or log %s in on disk: run '%s auth login' with %s unset.\n" \
    "$_PX_RES_CLI" "$set_vars" "$set_vars" "$_PX_RES_CLI" "$_PX_RES_CLI" "$set_vars"
}

# Runs status's read and write probe on the saved transport. A store this
# machine cannot read or push to gets status's fix as a warning, and the
# footer then promises no first push.
_paxel_setup_check_store_access() {
  local problems p
  [ "$_PX_STORE_USABLE" = 1 ] || return 0
  _PS_DISPLAY=$(_paxel_setup_saved_store)
  [ -n "$_PS_DISPLAY" ] || return 0
  _PS_TOOL=$(paxel_config_get store_cli)
  [ "$_PS_TOOL" != none ] || _PS_TOOL=""
  _PS_BIN="$HOME/.paxel/bin/paxel"
  _PS_WRITABLE=null
  _paxel_status_probe_store "$(paxel_config_get store_branch)"
  # Setup read and warned about the marker itself, and a seed it just wrote
  # through the host API can take a moment to show up in git.
  _PS_MARKER=null
  problems=$(_paxel_status_access_problems)
  [ -n "$problems" ] || return 0
  _PX_STORE_USABLE=0
  while IFS= read -r p; do
    [ -z "$p" ] || _paxel_setup_warn "$p"
  done <<PAXEL_SETUP_ACCESS
$problems
PAXEL_SETUP_ACCESS
}

# Splits paxel_store_resolve's "host owner name cli login existing|new" line
# into _PX_RES_* fields. The store part prints "-" for an unknown login.
_paxel_setup_parse_resolved() {
  local line="$1"
  _PX_RES_HOST=$(printf '%s\n' "$line" | cut -f1)
  _PX_RES_OWNER=$(printf '%s\n' "$line" | cut -f2)
  _PX_RES_NAME=$(printf '%s\n' "$line" | cut -f3)
  _PX_RES_CLI=$(printf '%s\n' "$line" | cut -f4)
  _PX_RES_LOGIN=$(printf '%s\n' "$line" | cut -f5)
  _PX_RES_KIND=$(printf '%s\n' "$line" | cut -f6)
  _PX_RES_BRANCH=""
  _PX_RES_VIS=""
  case "$_PX_RES_CLI" in gh|glab) ;; *) _PX_RES_CLI=none ;; esac
  if [ "$_PX_RES_CLI" = none ] || [ "$_PX_RES_LOGIN" = - ]; then _PX_RES_LOGIN=""; fi
  case "$_PX_RES_LOGIN" in *[!A-Za-z0-9._-]*) _PX_RES_LOGIN="" ;; esac
  _paxel_store_valid_host "$_PX_RES_HOST" && paxel_valid_name "$_PX_RES_OWNER" && paxel_valid_name "$_PX_RES_NAME" || return 1
  _PX_RES_DISPLAY="$_PX_RES_HOST/$_PX_RES_OWNER/$_PX_RES_NAME"
}

_paxel_setup_valid_display() {
  local host="${1%%/*}" rest owner name
  rest="${1#*/}"
  owner="${rest%%/*}"
  name="${rest#*/}"
  _paxel_store_valid_host "$host" && paxel_valid_name "$owner" && paxel_valid_name "$name"
}

# The host reports visibility and its default branch; the branch actually
# saved is the one paxel-store.json names (read after the transport is
# saved, see _paxel_setup_save_store).
_paxel_setup_store_existing() {
  local info="" branch=""
  if [ "$_PX_RES_CLI" != none ]; then
    info=$(paxel_store_lookup "$_PX_RES_CLI" "$_PX_RES_OWNER" "$_PX_RES_NAME" "$_PX_RES_HOST" 2>/dev/null) || info=""
    _PX_RES_VIS=$(printf '%s\n' "$info" | cut -f1)
    branch=$(printf '%s\n' "$info" | cut -f2)
  fi
  _paxel_store_valid_branch "$branch" || branch=""
  if [ -z "$branch" ] && [ "$(_paxel_setup_saved_store)" = "$_PX_RES_DISPLAY" ]; then
    branch=$(paxel_config_get store_branch)
  fi
  _paxel_store_valid_branch "$branch" || branch=main
  _PX_RES_BRANCH="$branch"
}

# Reads paxel-store.json from the store's default branch through a blobless
# depth-1 clone. Sets _PX_MARKER to found, unseeded (no marker, and nothing
# but files a store seed writes, or an empty repo), missing (no valid
# marker) or unknown (the store could not be read), and on found
# _PX_MARKER_BRANCH and _PX_MARKER_SCHEMA. Every marker value is untrusted.
_paxel_setup_read_marker() {
  local url tmp repo names PAXEL_STORE_GIT_TIMEOUT="${PAXEL_SETUP_GIT_TIMEOUT:-30}"
  paxel_is_uint "$PAXEL_STORE_GIT_TIMEOUT" || PAXEL_STORE_GIT_TIMEOUT=30
  _PX_MARKER=unknown
  _PX_MARKER_BRANCH=""
  _PX_MARKER_SCHEMA=""
  url=$(paxel_store_url 2>/dev/null) || return 0
  [ -n "$url" ] || return 0
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/paxel-setup.XXXXXX") || return 0
  repo="$tmp/probe.git"
  if paxel_store_git clone -q --bare --depth 1 --filter=blob:none --template= "$url" "$repo" >/dev/null 2>&1; then
    names=""
    if git -C "$repo" rev-parse -q --verify 'HEAD^{commit}' >/dev/null 2>&1; then
      names=$(git -C "$repo" ls-tree --name-only HEAD 2>/dev/null || printf 'unreadable\n')
    fi
    if [ -z "$(printf '%s\n' "$names" | grep -vx -e '' -e .gitattributes -e README.md)" ]; then
      _PX_MARKER=unseeded
    elif ! printf '%s\n' "$names" | grep -qx paxel-store.json; then
      _PX_MARKER=missing
    elif paxel_store_git -C "$repo" cat-file blob HEAD:paxel-store.json > "$tmp/marker.json" 2>/dev/null; then
      _PX_MARKER_SCHEMA=$(paxel_json_int "$tmp/marker.json" '.schema_version') || _PX_MARKER_SCHEMA=""
      _PX_MARKER_BRANCH=$(paxel_json_str "$tmp/marker.json" '.branch' '\A[A-Za-z0-9._/-]+\z') || _PX_MARKER_BRANCH=""
      if [ -n "$_PX_MARKER_SCHEMA" ] && _paxel_store_valid_branch "$_PX_MARKER_BRANCH"; then
        _PX_MARKER=found
      else
        _PX_MARKER=missing
      fi
    fi
  fi
  rm -rf "$tmp"
}

# A create that stopped before the marker (seeded last) leaves an empty or
# half-seeded private repo, and the store failure told the user to run setup
# again: the store part's seed skips the files already written and refuses
# any file it did not write.
_paxel_setup_finish_seed() {
  _PX_MARKER=unfinished
  if [ "$_PX_RES_CLI" = none ]; then
    _PX_SEED_PROBLEM="finishing it needs gh or glab logged in"
    return 0
  fi
  if [ "$_PX_RES_VIS" != private ]; then
    _PX_SEED_PROBLEM="setup only seeds a repo it can confirm is private"
    return 0
  fi
  if ! declare -F paxel_store_seed >/dev/null; then
    _PX_MARKER=missing
    return 0
  fi
  if ! paxel_store_seed "$_PX_RES_CLI" "$_PX_RES_OWNER" "$_PX_RES_NAME" "$_PX_RES_BRANCH" "$_PX_RES_HOST"; then
    _PX_SEED_PROBLEM="the seed failed for the reason above"
    return 0
  fi
  _PX_MARKER=found
  _PX_MARKER_BRANCH="$_PX_RES_BRANCH"
  _PX_MARKER_SCHEMA="$PAXEL_STORE_SCHEMA_VERSION"
  printf '  note: %s had no paxel-store.json yet, so setup finished seeding it.\n' "$_PX_RES_DISPLAY"
}

_paxel_setup_store_create() {
  local yes="$1" out branch display="$_PX_RES_DISPLAY" cli="$_PX_RES_CLI"
  if [ "$cli" = none ]; then
    _paxel_setup_store_missing "$display does not exist and neither gh nor glab is logged in to create it. Log in with gh or glab (or create it yourself as a private repo), then run $HOME/.paxel/bin/paxel setup again."
    return 1
  fi
  if [ "$yes" != 1 ] && _paxel_setup_has_tty; then
    if ! _paxel_setup_ask "No Paxel store found. Create the private repo $display with $cli? [Y/n] "; then
      _paxel_setup_item store "not created" "$display"
      _PX_STORE_STATE="not_created"
      paxel_config_set store_declined_at "$(paxel_now_iso)" || true
      _paxel_setup_config_clear store_missing_at
      _paxel_setup_warn "no store, so nothing is pushed yet. Run $HOME/.paxel/bin/paxel setup again to create it, or set PAXEL_STORE=host/owner/name to use another repo."
      return 1
    fi
  fi
  if ! out=$(paxel_store_create "$cli" "$_PX_RES_OWNER" "$_PX_RES_NAME" "$_PX_RES_HOST"); then
    _paxel_setup_codespace_store_missing "$_PX_RES_OWNER/$_PX_RES_NAME" ||
      _paxel_setup_store_missing "could not create $display with $cli. Check '$cli auth status' (the login needs permission to create repos), then run $HOME/.paxel/bin/paxel setup again; it reuses the repo if it was created.$(_paxel_setup_retry_hint)"
    return 1
  fi
  branch=${out##*$'\n'}
  _paxel_store_valid_branch "$branch" || branch=main
  _PX_RES_BRANCH="$branch"
  _PX_RES_VIS=private
}

# --- Create store (main machine) ---

# Finds or creates the store setup would use. It writes no launcher or hooks
# and pushes nothing; the only thing it keeps on this machine is a store
# PAXEL_STORE chose, in ~/.paxel/config, so uploads here find it. Without a
# TTY, running it is the consent. Store failures say to run this again, not
# setup: setup on the main machine would copy its whole history.
paxel_cmd_create_store() {
  local yes=0 out rc=0 _PAXEL_STORE_RERUN=this
  while [ $# -gt 0 ]; do
    case "$1" in
      --yes|-y) yes=1; shift ;;
      -h|--help)
        printf 'Usage: paxel create-store [--yes]\n  Create your private transcript store (PAXEL_STORE, else <login>/paxel-transcripts through gh or glab).\n  A store PAXEL_STORE names is saved in ~/.paxel/config, so uploads on this machine find it with no PAXEL_STORE;\n  nothing else is written here: no launcher, no hooks, no push.\n'
        return 0
        ;;
      *) paxel_say "Unknown create-store option '$1'. Usage: paxel create-store [--yes]"; return 1 ;;
    esac
  done
  out=$(paxel_store_resolve || exit $?) || rc=$?
  case "$rc" in
    0) ;;
    1)
      [ -n "${PAXEL_STORE:-}" ] || paxel_say "No store created: neither gh nor glab is logged in on this machine. Run gh auth login or glab auth login, or set PAXEL_STORE=host/owner/name."
      return 1
      ;;
    3) paxel_say "No store created: PAXEL_STORE is set and empty, which turns the store off. Unset it, or set it to host/owner/name."; return 1 ;;
    *) return 1 ;;
  esac
  if ! _paxel_setup_parse_resolved "${out%%$'\n'*}"; then
    paxel_say "No store created: the store lookup returned an unusable name. Set PAXEL_STORE=host/owner/name."
    return 1
  fi
  if [ "$_PX_RES_CLI" = none ]; then
    paxel_say "Cannot check or create https://$_PX_RES_DISPLAY: no gh or glab login for $_PX_RES_HOST. Run gh auth login or glab auth login (with --hostname $_PX_RES_HOST)."
    return 1
  fi
  if [ "$_PX_RES_KIND" = new ]; then
    _paxel_create_store_new "$yes" || return 1
  else
    _paxel_create_store_existing || return 1
  fi
  _paxel_setup_warn_org_store
  if _paxel_create_store_remember && [ -n "${PAXEL_STORE:-}" ]; then
    printf 'PAXEL_STORE chose this store: set PAXEL_STORE=%s on your boxes too (in their setup line).\n' "$_PX_RES_DISPLAY"
  elif [ -n "${PAXEL_STORE:-}" ]; then
    printf 'PAXEL_STORE chose this store: set PAXEL_STORE=%s on your boxes (in their setup line) and for uploads on this machine too.\n' "$_PX_RES_DISPLAY"
  fi
}

# Saves a store PAXEL_STORE chose (one the convention would not find: not
# <login>/paxel-transcripts on the CLI's own host) where the upload's pull
# reads it, with store_saved_at marking it as this command's; creating the
# convention store drops one saved that way. A store setup saved for this
# machine's own pushes is left alone. Status 0 when this machine now saves
# the store.
_paxel_create_store_remember() {
  local saved transport keep_at k
  saved=$(_paxel_setup_saved_store)
  if [ -n "$saved" ] && [ -z "$(paxel_config_get store_saved_at)" ]; then
    if [ "$saved" != "$_PX_RES_DISPLAY" ]; then
      printf 'Uploads on this machine pull https://%s, which paxel setup saved here, unless PAXEL_STORE is set. It was left as is.\n' "$saved"
      return 1
    fi
    return 0
  fi
  if _paxel_create_store_is_convention; then
    [ -n "$saved" ] || [ -n "$(paxel_config_get store_saved_at)" ] || return 1
    for k in store_host store_owner store_name store_transport store_cli store_saved_at; do
      _paxel_setup_config_clear "$k"
    done
    if [ -n "$saved" ]; then
      printf 'Removed https://%s, which an earlier --create-store saved on this machine: uploads here now find https://%s with no PAXEL_STORE.\n' "$saved" "$_PX_RES_DISPLAY"
    else
      printf 'Removed the store an earlier --create-store did not finish saving on this machine: uploads here now find https://%s with no PAXEL_STORE.\n' "$_PX_RES_DISPLAY"
    fi
    return 1
  fi
  transport=$(paxel_store_transport "$_PX_RES_CLI" "$_PX_RES_HOST" 2>/dev/null) || transport=https
  case "$transport" in ssh|https) ;; *) transport=https ;; esac
  keep_at=""
  [ "$saved" != "$_PX_RES_DISPLAY" ] || keep_at=$(paxel_config_get store_saved_at)
  # The pull needs the transport and the CLI whose credential helper it runs.
  # store_saved_at goes first, so a save that stops partway is still this
  # command's to finish or remove.
  if paxel_config_set store_saved_at "${keep_at:-$(paxel_now_iso)}" &&
     paxel_config_set store_host "$_PX_RES_HOST" && paxel_config_set store_owner "$_PX_RES_OWNER" &&
     paxel_config_set store_name "$_PX_RES_NAME" && paxel_config_set store_transport "$transport" &&
     paxel_config_set store_cli "$_PX_RES_CLI"; then
    printf 'Saved https://%s on this machine: uploads here pull it with no PAXEL_STORE.\n' "$_PX_RES_DISPLAY"
    return 0
  fi
  paxel_say "Could not save https://$_PX_RES_DISPLAY in $PAXEL_CONFIG_FILE (is it or ~/.paxel a symbolic link?), so uploads on this machine need PAXEL_STORE set."
  return 1
}

# The store the upload finds on its own: <login>/paxel-transcripts on the
# CLI's public host. One on gitlab.com that PAXEL_STORE names is not, since
# the upload takes the GitHub one when both exist.
_paxel_create_store_is_convention() {
  [ "$_PX_RES_NAME" = "$PAXEL_STORE_DEFAULT_NAME" ] && [ -n "$_PX_RES_LOGIN" ] &&
    [ "$(_paxel_lower "$_PX_RES_OWNER")" = "$(_paxel_lower "$_PX_RES_LOGIN")" ] &&
    [ "$_PX_RES_HOST" = "$(_paxel_store_default_host "$_PX_RES_CLI" || true)" ] &&
    { [ -z "${PAXEL_STORE:-}" ] || [ "$_PX_RES_CLI" = gh ]; }
}

# A repo with no paxel-store.json is seeded only when it holds nothing but
# files a seed writes, as setup does: an earlier create that stopped before
# its marker left it.
_paxel_create_store_existing() {
  local info rc=0 vis branch names
  info=$(paxel_store_lookup "$_PX_RES_CLI" "$_PX_RES_OWNER" "$_PX_RES_NAME" "$_PX_RES_HOST" || exit $?) || rc=$?
  if [ "$rc" -ne 0 ]; then
    paxel_say "Could not read the visibility of https://$_PX_RES_DISPLAY through $_PX_RES_CLI (network error or rate limit). Try again later."
    return 1
  fi
  vis="${info%%${_PAXEL_STORE_TAB}*}"
  branch="${info#*${_PAXEL_STORE_TAB}}"
  if [ "$vis" != private ]; then
    paxel_say "REFUSED: https://$_PX_RES_DISPLAY exists but is $vis, not private. Paxel will not write transcripts to it. Make it private in its settings, then run this again."
    return 1
  fi
  _paxel_store_valid_branch "$branch" || branch=main
  names=$(paxel_store_root_names "$_PX_RES_CLI" "$_PX_RES_OWNER" "$_PX_RES_NAME" "$_PX_RES_HOST" "$branch" || exit $?) || rc=$?
  if [ "$rc" -ne 0 ]; then
    paxel_say "Could not read the files of https://$_PX_RES_DISPLAY through $_PX_RES_CLI (network error or rate limit). Try again later."
    return 1
  fi
  if printf '%s\n' "$names" | grep -qx paxel-store.json; then
    printf 'Store already exists: https://%s\n' "$_PX_RES_DISPLAY"
    return 0
  fi
  if [ -n "$(printf '%s\n' "$names" | grep -vx -e '' -e .gitattributes -e README.md)" ]; then
    paxel_say "REFUSED: https://$_PX_RES_DISPLAY exists but has no paxel-store.json and holds files Paxel did not write, so it is not a transcript store. Name another repo with PAXEL_STORE=host/owner/name."
    return 1
  fi
  paxel_store_seed "$_PX_RES_CLI" "$_PX_RES_OWNER" "$_PX_RES_NAME" "$branch" "$_PX_RES_HOST" || return 1
  printf 'Store already exists: https://%s (it had no paxel-store.json yet, so this run finished seeding it)\n' "$_PX_RES_DISPLAY"
}

# paxel_store_create says why when it fails, and checks that the new repo
# reads back as private before it seeds it.
_paxel_create_store_new() {
  local yes="$1"
  if [ "$yes" != 1 ] && _paxel_setup_has_tty; then
    if ! _paxel_setup_ask "Create the private repo $_PX_RES_DISPLAY with $_PX_RES_CLI (logged in as $_PX_RES_LOGIN)? [y/N] " no; then
      paxel_say "No store created. Run this again and answer y, or pass --yes."
      return 1
    fi
  fi
  paxel_store_create "$_PX_RES_CLI" "$_PX_RES_OWNER" "$_PX_RES_NAME" "$_PX_RES_HOST" >/dev/null || return 1
  printf 'Created private store: https://%s\n' "$_PX_RES_DISPLAY"
}

_paxel_setup_store_warnings() {
  case "$_PX_MARKER" in
    no_repo)
      _paxel_setup_warn "https://$_PX_RES_DISPLAY was not found with this machine's git login, and with no gh or glab login setup cannot create it here. Create it from your main machine: $(_paxel_setup_create_store_line). Push looks for it again on its own, at most once an hour after an agent turn, so this machine needs no new setup."
      ;;
    no_access)
      _paxel_setup_warn "this machine's git login could not read https://$_PX_RES_DISPLAY over https or ssh: no credential helper, GIT_ASKPASS or SSH key here got in. Give git a login for $_PX_RES_HOST, or log in with gh or glab. If the repo does not exist yet, create it from your main machine: $(_paxel_setup_create_store_line). Push tries again on its own, at most once an hour after an agent turn."
      ;;
    missing)
      _paxel_setup_warn "$_PX_RES_DISPLAY has no valid paxel-store.json, so it is not a Paxel store and push will not write to it. Run setup with PAXEL_STORE=host/owner/name naming your Paxel store."
      ;;
    unfinished)
      _paxel_setup_warn "$_PX_RES_DISPLAY has no paxel-store.json yet and $_PX_SEED_PROBLEM, so push will not write to it. Fix that, then run $HOME/.paxel/bin/paxel setup again. Push also tries to finish it on its own, at most once an hour after an agent turn."
      ;;
    unknown)
      printf '  note: could not read paxel-store.json from %s (network or access); push checks it before it writes anything.\n' "$_PX_RES_DISPLAY"
      ;;
  esac
  if [ "$_PX_MARKER" = found ] && [ "$_PX_MARKER_SCHEMA" != "$PAXEL_STORE_SCHEMA_VERSION" ]; then
    _paxel_setup_warn "$_PX_RES_DISPLAY uses store format $_PX_MARKER_SCHEMA and this script writes format $PAXEL_STORE_SCHEMA_VERSION, so push will not write to it until Paxel serves a script for that format."
  fi
  case "$_PX_RES_VIS" in
    ''|private) ;;
    *) _paxel_setup_warn "$_PX_RES_DISPLAY is $_PX_RES_VIS. Push stays stopped until it is private: change its visibility in the repo settings." ;;
  esac
  _paxel_setup_warn_org_store
}

# The main machine's command that creates the store this setup names.
_paxel_setup_create_store_line() {
  printf 'curl -fsSL %s/paxel.sh | PAXEL_STORE=%s bash -s -- --create-store --yes' "$(_paxel_setup_server)" "$_PX_RES_DISPLAY"
}

_paxel_setup_warn_org_store() {
  if [ -n "$_PX_RES_LOGIN" ] && [ "$(_paxel_lower "$_PX_RES_OWNER")" != "$(_paxel_lower "$_PX_RES_LOGIN")" ]; then
    _paxel_setup_warn "$_PX_RES_DISPLAY is not under your account ($_PX_RES_LOGIN): the owners and admins of '$_PX_RES_OWNER' can read every transcript in it."
  fi
}

# A store that was saved before stays saved when this run cannot check it.
# With none saved, store_missing_at lets push look again later, but only for
# the convention store: an explicit PAXEL_STORE is never traded for
# <login>/paxel-transcripts.
_paxel_setup_store_missing() {
  local saved
  saved=$(_paxel_setup_saved_store)
  if [ -n "$saved" ]; then
    _paxel_setup_item store unchanged "$saved (kept the saved store)"
  else
    _paxel_setup_item store missing "nothing is pushed until a store exists"
    _PX_STORE_STATE=missing
    if [ "${PAXEL_STORE+set}" = set ]; then
      _paxel_setup_config_clear store_missing_at
    else
      [ -n "$(paxel_config_get store_missing_at)" ] || paxel_config_set store_missing_at "$(paxel_now_iso)" || true
      _paxel_setup_config_clear store_declined_at
    fi
  fi
  _paxel_setup_warn "$1"
}

# In a GitHub codespace with no GH_TOKEN, gh uses the codespace's
# GITHUB_TOKEN, which reaches only the codespace's own repository, so a
# missing store has its own fix. Status 1 outside a codespace, once GH_TOKEN
# is set (the fix is done), or for a saved or explicit store.
_paxel_setup_codespace_store_missing() {
  local repo="${1:-<your GitHub login>/$PAXEL_STORE_DEFAULT_NAME}"
  [ "${CODESPACES:-}" = true ] && [ -z "${GH_TOKEN:-}" ] && [ "${PAXEL_STORE+set}" != set ] &&
    [ -z "$(_paxel_setup_saved_store)" ] || return 1
  _paxel_setup_store_missing "this is a GitHub codespace, and gh here uses the codespace's GITHUB_TOKEN, which reaches only the codespace's own repository, so setup could not find or create $repo. Create the store from your main machine: curl -fsSL $(_paxel_setup_server)/paxel.sh | bash -s -- --create-store --yes. Then add a Codespaces user secret named GH_TOKEN holding a fine-grained token with Contents read and write on $repo (gh prefers GH_TOKEN to GITHUB_TOKEN), and rebuild the codespace or run $HOME/.paxel/bin/paxel setup."
}

_paxel_setup_retry_hint() {
  if [ "${PAXEL_STORE+set}" != set ] && [ -z "$(_paxel_setup_saved_store)" ]; then
    printf ' Push also looks again on its own, at most once an hour after an agent turn.'
  fi
}

# The marker of an existing store is read through the saved transport and
# CLI, so the store is written to the config before its branch is final.
_paxel_setup_save_store() {
  local before after transport probe="" auth=""
  if [ "$_PX_RES_CLI" = none ]; then
    probe=$(paxel_store_box_probe "$_PX_RES_HOST" "$_PX_RES_OWNER" "$_PX_RES_NAME" 2>/dev/null) || probe=""
    transport="${probe%%${_PAXEL_STORE_TAB}*}"
    probe="${probe#*${_PAXEL_STORE_TAB}}"
    auth=git
  else
    transport=$(paxel_store_transport "$_PX_RES_CLI" "$_PX_RES_HOST" 2>/dev/null) || transport=""
  fi
  case "$transport" in ssh|https) ;; *) transport=https ;; esac
  before="$(_paxel_setup_saved_store)|$(paxel_config_get store_branch)|$(paxel_config_get store_transport)|$(paxel_config_get store_cli)|$(paxel_config_get store_login)|$(paxel_config_get store_auth)"
  _paxel_setup_config_put store_host "$_PX_RES_HOST"
  _paxel_setup_config_put store_owner "$_PX_RES_OWNER"
  _paxel_setup_config_put store_name "$_PX_RES_NAME"
  _paxel_setup_config_put store_transport "$transport"
  _paxel_setup_config_put store_cli "$_PX_RES_CLI"
  _paxel_setup_config_put store_login "$_PX_RES_LOGIN"
  if [ -n "$auth" ]; then _paxel_setup_config_put store_auth "$auth"; else _paxel_setup_config_clear store_auth; fi
  # This machine's pushes use the store now, so create-store leaves it alone.
  _paxel_setup_config_clear store_saved_at
  _PX_MARKER=""
  if [ "$_PX_RES_KIND" != new ]; then
    case "$probe" in
      missing) _PX_MARKER=no_repo ;;
      denied) _PX_MARKER=no_access ;;
      *)
        _paxel_setup_read_marker
        [ "$_PX_MARKER" != unseeded ] || _paxel_setup_finish_seed
        [ "$_PX_MARKER" != found ] || _PX_RES_BRANCH="$_PX_MARKER_BRANCH"
        ;;
    esac
  fi
  _paxel_setup_config_put store_branch "$_PX_RES_BRANCH"
  # A seed setup could not finish, or a store this machine's own git login
  # cannot reach yet, stays a missing store, so push tries it again. A marker
  # this run could not read leaves that state as it was.
  case "$_PX_MARKER" in
    unfinished|no_repo|no_access) [ -n "$(paxel_config_get store_missing_at)" ] || paxel_config_set store_missing_at "$(paxel_now_iso)" || true ;;
    unknown) ;;
    *)
      _paxel_setup_config_clear store_missing_at
      _paxel_setup_config_clear store_retry_at
      ;;
  esac
  _paxel_setup_config_clear store_declined_at
  after="$_PX_RES_DISPLAY|$_PX_RES_BRANCH|$transport|$_PX_RES_CLI|$_PX_RES_LOGIN|$auth"
  if [ "$_PX_MARKER" = found ] && [ "$_PX_MARKER_SCHEMA" != "$PAXEL_STORE_SCHEMA_VERSION" ]; then
    _PX_STORE_USABLE=0
  fi
  case "$_PX_MARKER" in
    missing) _PX_STORE_STATE="not a Paxel store"; _PX_STORE_USABLE=0 ;;
    unfinished) _PX_STORE_STATE="not seeded"; _PX_STORE_USABLE=0 ;;
    no_repo) _PX_STORE_STATE="not found"; _PX_STORE_USABLE=0 ;;
    no_access) _PX_STORE_STATE="no access"; _PX_STORE_USABLE=0 ;;
    *)
      if [ "$_PX_RES_KIND" = new ]; then
        _PX_STORE_STATE=created
      elif [ "$before" = "|||||" ]; then
        _PX_STORE_STATE=found
      elif [ "$before" = "$after" ]; then
        _PX_STORE_STATE=unchanged
      else
        _PX_STORE_STATE=updated
      fi
      ;;
  esac
}

_paxel_setup_saved_store() {
  local host owner name
  host=$(paxel_config_get store_host)
  owner=$(paxel_config_get store_owner)
  name=$(paxel_config_get store_name)
  [ -n "$host" ] && [ -n "$owner" ] && [ -n "$name" ] || return 0
  printf '%s/%s/%s\n' "$host" "$owner" "$name"
}

_paxel_setup_store_via() {
  if [ "$_PX_RES_CLI" != none ]; then
    printf 'via %s%s' "$_PX_RES_CLI" "${_PX_RES_LOGIN:+ as $_PX_RES_LOGIN}"
  elif [ "$_PX_MARKER" = no_repo ]; then
    printf 'no gh or glab login here to create it: create it from your main machine'
  elif [ "$_PX_MARKER" = no_access ]; then
    printf "no gh or glab login, and this machine's git login could not read it"
  else
    printf "no gh or glab login; git uses this machine's own login, over %s" "$(paxel_config_get store_transport)"
  fi
}

_paxel_setup_cli_notes() {
  local cli
  [ "${PAXEL_STORE+set}" = set ] && return 0
  for cli in $(_paxel_logged_out_clis); do
    printf '  note: %s is installed but not logged in, so %s was not searched for a store.\n' "$cli" "$(_paxel_cli_host_name "$cli")"
  done
}

# The convention lookup only sees logged-in CLIs, so setup and status name
# the installed ones it could not use. A CLI whose host did not answer
# (status 2) is logged in, so it is not named.
_paxel_logged_out_clis() {
  local cli rc
  for cli in gh glab; do
    command -v "$cli" >/dev/null 2>&1 || continue
    rc=0
    paxel_store_cli_login "$cli" >/dev/null 2>&1 || rc=$?
    [ "$rc" -ne 1 ] || printf '%s\n' "$cli"
  done
}

_paxel_cli_host_name() {
  if [ "$1" = gh ]; then echo GitHub; else echo GitLab; fi
}

_paxel_lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

_paxel_setup_agent_dir_warnings() {
  local p
  while IFS= read -r p; do
    [ -z "$p" ] || _paxel_setup_warn "$p"
  done <<PAXEL_AGENT_DIRS
$(_paxel_agent_dir_problems)
PAXEL_AGENT_DIRS
}

# Capture uses ~/.claude and ~/.codex only. Prints one line per agent whose
# override in this environment points elsewhere, since its sessions would be
# missed with nothing else saying so.
_paxel_agent_dir_problems() {
  local v
  v="${CLAUDE_CONFIG_DIR:-}"
  v="${v%/}"
  if [ -n "$v" ] && [ "$v" != "$HOME/.claude" ]; then
    printf 'CLAUDE_CONFIG_DIR is set to %s, but Paxel registers its hooks in ~/.claude/settings.json and copies sessions from ~/.claude/projects, so Claude Code sessions that use it are not captured. Unset it for Claude Code to capture them.\n' "$v"
  fi
  v="${CODEX_HOME:-}"
  v="${v%/}"
  if [ -n "$v" ] && [ "$v" != "$HOME/.codex" ]; then
    printf 'CODEX_HOME is set to %s, but Paxel registers notify in ~/.codex/config.toml and copies sessions from ~/.codex/sessions, so Codex sessions that use it are not captured. Unset it for Codex to capture them.\n' "$v"
  fi
}

# --- Agent hooks: shared ---

# The launcher path as one shell word (quoted only when the home needs it).
_paxel_hook_command() {
  local bin="$HOME/.paxel/bin/paxel"
  case "$bin" in
    *[!A-Za-z0-9._/-]*) bin="'$(printf '%s' "$bin" | sed "s/'/'\\\\''/g")'" ;;
  esac
  printf '%s hook %s\n' "$bin" "$1"
}

_paxel_codex_notify_line() {
  local bin="$HOME/.paxel/bin/paxel"
  bin=$(printf '%s' "$bin" | sed 's/\\/\\\\/g; s/"/\\"/g')
  printf 'notify = ["%s", "hook", "codex"]\n' "$bin"
}

# Prints the file's JSON object, or {} for a missing or blank file. Status 1
# when it is not exactly one JSON object.
_paxel_setup_json_input() {
  local file="$1" text=""
  if [ -e "$file" ]; then
    [ -f "$file" ] || return 1
    text=$(cat "$file") || return 1
  fi
  case "$text" in
    *[![:space:]]*) ;;
    *) printf '{}\n'; return 0 ;;
  esac
  printf '%s\n' "$text" | jq -e -s 'length == 1 and (.[0] | type == "object")' >/dev/null 2>&1 || return 1
  printf '%s\n' "$text"
}

# Moves NEW over FILE, keeping FILE's mode and owner, and keeps a copy of the
# original as FILE.paxel.bak the first time Paxel changes it.
_paxel_setup_replace_file() {
  local file="$1" new="$2" tmp
  tmp=$(_paxel_setup_tmp "$file") || { rm -f "$new"; return 1; }
  if [ -f "$file" ]; then
    if [ ! -e "$file.paxel.bak" ] && [ ! -L "$file.paxel.bak" ] && ! cp -p "$file" "$file.paxel.bak"; then
      rm -f "$new" "$tmp"
      return 1
    fi
    if ! { cp -p "$file" "$tmp" && cat "$new" > "$tmp"; }; then
      rm -f "$tmp" "$new"
      return 1
    fi
    rm -f "$new"
  else
    mv -f "$new" "$tmp" || { rm -f "$new" "$tmp"; return 1; }
  fi
  mv -f "$tmp" "$file"
}

_paxel_setup_write_json() {
  local file="$1" json="$2" new
  new=$(_paxel_setup_tmp "$file") || return 1
  printf '%s\n' "$json" > "$new" || { rm -f "$new"; return 1; }
  _paxel_setup_replace_file "$file" "$new"
}

# --- Agent hooks: Claude Code ---

_paxel_setup_claude_hooks() {
  local file="$HOME/.claude/settings.json" cmd input new had
  cmd=$(_paxel_hook_command claude)
  if ! _paxel_setup_safe_dir .claude; then
    _paxel_setup_item "Claude hooks" "not registered" "~/.claude is a symlink or belongs to another account; running as root, setup left it alone"
    _paxel_setup_claude_snippet "$cmd"
    return 1
  fi
  if [ -L "$file" ]; then
    if _paxel_claude_hooks_registered; then
      _paxel_setup_item "Claude hooks" unchanged "~/.claude/settings.json (a symlink that already has the Paxel hooks)"
      return 0
    fi
    _paxel_setup_item "Claude hooks" "not registered" "~/.claude/settings.json is a symlink, left alone"
    _paxel_setup_claude_snippet "$cmd"
    return 1
  fi
  if ! input=$(_paxel_setup_json_input "$file") ||
     ! new=$(printf '%s\n' "$input" | jq --arg cmd "$cmd" --arg re "$_PX_CLAUDE_HOOK_RE" "$_PX_JQ_HOOK_DEFS$_PX_JQ_CLAUDE_ADD" 2>/dev/null); then
    _paxel_setup_item "Claude hooks" "not registered" "~/.claude/settings.json is not valid JSON, left alone"
    _paxel_setup_claude_snippet "$cmd"
    return 1
  fi
  if [ -f "$file" ] && [ "$(printf '%s\n' "$input" | jq -c .)" = "$(printf '%s\n' "$new" | jq -c .)" ]; then
    _paxel_setup_item "Claude hooks" unchanged "~/.claude/settings.json"
    return 0
  fi
  had=$(printf '%s\n' "$input" | jq --arg re "$_PX_CLAUDE_HOOK_RE" "$_PX_JQ_HOOK_DEFS"'any(("Stop", "StopFailure", "SessionEnd") as $e | (.hooks[$e]? // [])[]?; has_paxel)')
  mkdir -p "$HOME/.claude"
  if ! _paxel_setup_write_json "$file" "$new"; then
    _paxel_setup_item "Claude hooks" "not registered" "could not write ~/.claude/settings.json"
    return 1
  fi
  if [ "$had" = true ]; then
    _paxel_setup_item "Claude hooks" updated "~/.claude/settings.json: Stop, StopFailure, SessionEnd"
  else
    _paxel_setup_item "Claude hooks" created "~/.claude/settings.json: Stop, StopFailure, SessionEnd"
  fi
}

_paxel_setup_claude_snippet() {
  printf '    Add these hooks to ~/.claude/settings.json yourself (merge them into its "hooks" object):\n'
  jq -n --arg cmd "$1" '[{hooks: [{type: "command", command: $cmd, timeout: 10}]}] as $g | {hooks: {Stop: $g, StopFailure: $g, SessionEnd: $g}}' | sed 's/^/      /'
}

_paxel_setup_claude_hooks_remove() {
  local file="$HOME/.claude/settings.json" input new
  if ! _paxel_setup_safe_dir .claude; then
    _paxel_setup_item "Claude hooks" "left alone" "~/.claude is a symlink or belongs to another account: remove the Paxel hook entries from ~/.claude/settings.json yourself"
    return 1
  fi
  if [ ! -e "$file" ] && [ ! -L "$file" ]; then
    _paxel_setup_item "Claude hooks" "not present" "~/.claude/settings.json"
    return 0
  fi
  if [ -L "$file" ] || ! input=$(_paxel_setup_json_input "$file"); then
    _paxel_setup_item "Claude hooks" "left alone" "~/.claude/settings.json is a symlink or not valid JSON: remove the Paxel hook entries from it yourself"
    return 1
  fi
  if ! printf '%s\n' "$input" | jq -e --arg re "$_PX_CLAUDE_HOOK_RE" "$_PX_JQ_HOOK_DEFS"'any((.hooks? // {} | objects | .[])[]?; has_paxel)' >/dev/null 2>&1; then
    _paxel_setup_item "Claude hooks" "not present" "~/.claude/settings.json"
    return 0
  fi
  if ! new=$(printf '%s\n' "$input" | jq --arg re "$_PX_CLAUDE_HOOK_RE" "$_PX_JQ_HOOK_DEFS$_PX_JQ_CLAUDE_REMOVE" 2>/dev/null) ||
     ! _paxel_setup_write_json "$file" "$new"; then
    _paxel_setup_item "Claude hooks" "left alone" "could not rewrite ~/.claude/settings.json"
    return 1
  fi
  _paxel_setup_item "Claude hooks" removed "~/.claude/settings.json"
}

# --- Agent hooks: Codex ---

# Codex runs the top-level `notify` program after every turn with no trust
# step. When notify runs another program, Paxel's notify takes its place and
# the launcher runs that program after Paxel. A Stop hook in hooks.json is
# the fallback only where setup cannot do that.
_paxel_setup_codex_hooks() {
  local cfg="$HOME/.codex/config.toml" line
  line=$(_paxel_codex_notify_line)
  if ! _paxel_setup_safe_dir .codex; then
    _paxel_setup_item "Codex notify" "not registered" "~/.codex is a symlink or belongs to another account; running as root, setup left it alone"
    _paxel_setup_notify_snippet "$line"
    return 1
  fi
  if [ -L "$cfg" ]; then
    _PX_NOTIFY_STATE=absent
    [ ! -f "$cfg" ] || _paxel_codex_notify_state "$cfg" "$line"
    case "$_PX_NOTIFY_STATE" in
      ours)
        _paxel_setup_item "Codex notify" unchanged "~/.codex/config.toml (a symlink that already has the Paxel notify)$(_paxel_codex_chain_note)"
        _paxel_setup_codex_drop_stop_hook
        return 0
        ;;
      foreign)
        _paxel_setup_codex_hooks_json "~/.codex/config.toml is a symlink that sets notify"
        return
        ;;
    esac
    _paxel_setup_item "Codex notify" "not registered" "~/.codex/config.toml is a symlink, left alone"
    _paxel_setup_notify_snippet "$line"
    return 1
  fi
  mkdir -p "$HOME/.codex"
  if [ ! -e "$cfg" ]; then
    if printf '%s\n' "$line" > "$cfg" && chmod 600 "$cfg"; then
      _paxel_codex_chain_forget
      _paxel_setup_item "Codex notify" created "~/.codex/config.toml"
      _PX_CODEX_RESTART=1
      return 0
    fi
  else
    _paxel_codex_notify_state "$cfg" "$line"
    case "$_PX_NOTIFY_STATE" in
      ours)
        _paxel_setup_item "Codex notify" unchanged "~/.codex/config.toml$(_paxel_codex_chain_note)"
        _paxel_setup_codex_drop_stop_hook
        return 0
        ;;
      foreign)
        if _paxel_setup_codex_chain "$cfg" "$line"; then
          _paxel_setup_codex_drop_stop_hook
          return 0
        fi
        _paxel_setup_codex_hooks_json "setup cannot copy the notify in ~/.codex/config.toml"
        return
        ;;
      stale|absent)
        # With no notify left, a program saved earlier is no longer the user's.
        [ "$_PX_NOTIFY_STATE" = stale ] || _paxel_codex_chain_forget
        if _paxel_setup_codex_notify_edit "$cfg" "$line"; then
          _paxel_setup_codex_drop_stop_hook
          return 0
        fi
        ;;
    esac
  fi
  _paxel_setup_item "Codex notify" "not registered" "could not edit ~/.codex/config.toml safely, left alone"
  _paxel_setup_notify_snippet "$line"
  return 1
}

# Writes the edit to a temp file, reads it back, and only then replaces the
# original. A stale Paxel line is replaced in place; otherwise notify goes
# right after the last top-level statement, which keeps it above the first
# table and keeps comments next to the table they describe.
_paxel_setup_codex_notify_edit() {
  local cfg="$1" line="$2" state="$_PX_NOTIFY_STATE" replaced=0 mode new
  new=$(_paxel_setup_tmp "$cfg") || return 1
  if [ "$state" = stale ]; then
    replaced="$_PX_NOTIFY_LINE"
    _paxel_toml_put_line "$cfg" "$new" replace "$replaced" "$line"
  else
    if [ "$_PX_TOML_LAST" != 0 ]; then mode=after
    elif [ "$_PX_TOML_HEADER" != 0 ]; then mode=top
    else mode=end
    fi
    _paxel_toml_put_line "$cfg" "$new" "$mode" "$_PX_TOML_LAST" "$line"
  fi
  if ! _paxel_codex_notify_verify "$cfg" "$new" "$line" "$replaced" || ! _paxel_setup_replace_file "$cfg" "$new"; then
    rm -f "$new"
    return 1
  fi
  if [ "$state" = stale ]; then
    _paxel_setup_item "Codex notify" updated "~/.codex/config.toml$(_paxel_codex_chain_note)"
  else
    _paxel_setup_item "Codex notify" created "~/.codex/config.toml"
  fi
  _PX_CODEX_RESTART=1
}

# --- Codex notify chain ---

# The launcher reads this tag literally (its hook path has no script).
PAXEL_CODEX_CHAIN_TAG=paxel-codex-notify-chain-v1

_paxel_codex_chain_file() { printf '%s/codex-notify-chain\n' "$PAXEL_HOME_DIR"; }

# Puts Paxel's notify in place of one that runs another program, after
# saving that program, which the launcher then runs after Paxel's step on
# every turn, and the exact notify text, which setup --off puts back. Status
# 1 when the value is not a list of strings this script reads, or a write
# fails; the config is then left as it was.
_paxel_setup_codex_chain() {
  local cfg="$1" line="$2" start="$_PX_TOML_NOTIFY_START" end="$_PX_TOML_NOTIFY_END" text argv new
  text=$(awk -v s="$start" -v e="$end" 'NR >= s && NR <= e' "$cfg") || return 1
  argv=$(_paxel_toml_notify_argv "$text") || return 1
  new=$(_paxel_setup_tmp "$cfg") || return 1
  _paxel_toml_put_line "$cfg" "$new" replace "$start" "$line" "$end"
  if ! _paxel_codex_notify_verify "$cfg" "$new" "$line" "$start" "$end"; then
    rm -f "$new"
    return 1
  fi
  # A Paxel notify for another home, spread over several lines.
  if printf '%s\n' "$argv" | jq -e 'length == 3 and (.[0] | endswith("/.paxel/bin/paxel")) and .[1] == "hook" and .[2] == "codex"' >/dev/null 2>&1; then
    _paxel_setup_replace_file "$cfg" "$new" || return 1
    _paxel_setup_item "Codex notify" updated "~/.codex/config.toml$(_paxel_codex_chain_note)"
    _PX_CODEX_RESTART=1
    return 0
  fi
  if ! _paxel_codex_chain_save "$text" "$argv"; then
    rm -f "$new"
    return 1
  fi
  if ! _paxel_setup_replace_file "$cfg" "$new"; then
    _paxel_codex_chain_forget
    return 1
  fi
  _paxel_setup_item "Codex notify" chained "~/.codex/config.toml$(_paxel_codex_chain_note)"
  _PX_CODEX_RESTART=1
}

# TEXT is a top-level `notify = [...]`, comments included. Prints its value
# as a JSON array of strings, or status 1 for anything else: a multi-line or
# \U-escaped string, a value that is not a list of strings.
_paxel_toml_notify_argv() {
  local json
  json=$(printf '%s\n' "$1" | LC_ALL=C awk '
    BEGIN { for (k = 1; k < 32; k++) if (k != 9 && k != 10) ctrl[sprintf("%c", k)] = 1; ctrl[sprintf("%c", 127)] = 1 }
    { sub(/\r$/, ""); s = s $0 "\n" }
    function gap() {
      while (i <= n) {
        c = substr(s, i, 1)
        if (c == " " || c == "\t" || c == "\n") { i++; continue }
        if (c == "#") { while (i <= n && substr(s, i, 1) != "\n") i++; continue }
        return
      }
    }
    END {
      n = length(s); i = 1
      while (substr(s, i, 1) == " " || substr(s, i, 1) == "\t") i++
      c = substr(s, i, 1)
      if (c == "\"" || c == "\047") { i++; while (i <= n && substr(s, i, 1) != c) i++; i++ }
      else while (substr(s, i, 1) ~ /[A-Za-z0-9_-]/) i++
      while (substr(s, i, 1) == " " || substr(s, i, 1) == "\t") i++
      if (substr(s, i, 1) != "=") exit 1
      i++
      while (substr(s, i, 1) == " " || substr(s, i, 1) == "\t") i++
      if (substr(s, i, 1) != "[") exit 1
      i++
      out = "["; sep = ""; want = 1
      while (1) {
        gap()
        if (i > n) exit 1
        c = substr(s, i, 1)
        if (c == "]") { i++; break }
        if (c == ",") { if (want) exit 1; want = 1; i++; continue }
        if (!want) exit 1
        q = c
        if (q != "\"" && q != "\047") exit 1
        if (substr(s, i, 3) == q q q) exit 1
        v = ""; i++
        while (1) {
          if (i > n) exit 1
          c = substr(s, i, 1)
          if (c == q) { i++; break }
          if (c == "\n" || (c in ctrl)) exit 1
          if (q == "\"" && c == "\\") {
            e = substr(s, i + 1, 1)
            if (e ~ /^[btnfr"\\]$/) { v = v "\\" e; i += 2; continue }
            if (e == "u" && substr(s, i + 2, 4) ~ /^[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]$/) { v = v "\\u" substr(s, i + 2, 4); i += 6; continue }
            exit 1
          }
          if (c == "\t") v = v "\\t"
          else if (c == "\\" || c == "\"") v = v "\\" c
          else v = v c
          i++
        }
        out = out sep "\"" v "\""; sep = ","; want = 0
      }
      gap()
      if (i <= n) exit 1
      print out "]"
    }
  ' || exit $?) || return 1
  printf '%s\n' "$json" | jq -c 'if type == "array" and all(.[]; type == "string" and (explode | all(. != 0))) then . else error("not a list of strings") end' 2>/dev/null
}

# NUL-separated records: the tag, TEXT, then each string of ARGV_JSON.
_paxel_codex_chain_save() {
  local file tmp
  file=$(_paxel_codex_chain_file)
  [ ! -L "$PAXEL_HOME_DIR" ] || return 1
  mkdir -p "$PAXEL_HOME_DIR" 2>/dev/null || return 1
  tmp=$(mktemp "$file.tmp.XXXXXX" 2>/dev/null) || return 1
  if { printf '%s\0%s\0' "$PAXEL_CODEX_CHAIN_TAG" "$1" && printf '%s\n' "$2" | jq -j '.[] | . + "\u0000"'; } > "$tmp" &&
     chmod 600 "$tmp" && mv -f "$tmp" "$file"; then
    return 0
  fi
  rm -f "$tmp"
  return 1
}

# Sets _PX_CHAIN_TEXT (the saved notify text) and _PX_CHAIN_PROG (the program
# it runs, empty for none). Status 1 for a missing, linked or foreign file:
# root setting up another account must not copy a linked file into its config.
_paxel_codex_chain_read() {
  local file tag="" text="" prog=""
  _PX_CHAIN_TEXT=""
  _PX_CHAIN_PROG=""
  file=$(_paxel_codex_chain_file)
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  { IFS= read -r -d '' tag && IFS= read -r -d '' text && { IFS= read -r -d '' prog || true; }; } < "$file" 2>/dev/null || return 1
  [ "$tag" = "$PAXEL_CODEX_CHAIN_TAG" ] || return 1
  _PX_CHAIN_TEXT="$text"
  _PX_CHAIN_PROG=$(printf '%s' "$prog" | LC_ALL=C tr -d '\001-\037\177')
}

_paxel_codex_chain_forget() {
  rm -f "$(_paxel_codex_chain_file)" 2>/dev/null || true
}

# " (runs PROGRAM after Paxel)" while a chained program is saved.
_paxel_codex_chain_note() {
  _paxel_codex_chain_read || return 0
  printf ' (runs %s after Paxel)' "${_PX_CHAIN_PROG:-no program}"
}

# A hooks.json Stop hook an earlier setup added while notify ran another
# program would now start Paxel twice a turn, and asks for trust on each box.
_paxel_setup_codex_drop_stop_hook() {
  local file="$HOME/.codex/hooks.json"
  [ -f "$file" ] || return 0
  jq -e --arg re "$_PX_CODEX_HOOK_RE" "$_PX_JQ_HOOK_DEFS"'any((.hooks? // {} | objects | .[])[]?; has_paxel)' "$file" >/dev/null 2>&1 || return 0
  _paxel_setup_codex_hooks_json_remove || true
}

# Puts back, byte for byte, the notify a chained setup replaced. Codex
# sessions already running keep calling Paxel's notify, which no longer runs
# the program once the chain file is gone.
_paxel_setup_codex_notify_restore() {
  local cfg="$1" n="$_PX_NOTIFY_LINE" new prog="${_PX_CHAIN_PROG:-no program}"
  if new=$(_paxel_setup_tmp "$cfg"); then
    _paxel_toml_put_line "$cfg" "$new" replace "$n" "$_PX_CHAIN_TEXT"
    if _paxel_codex_restore_verify "$cfg" "$new" "$n" "$_PX_CHAIN_TEXT" && _paxel_setup_replace_file "$cfg" "$new"; then
      _paxel_codex_chain_forget
      _paxel_setup_item "Codex notify" restored "~/.codex/config.toml (Codex runs $prog itself again; sessions already running skip it until restarted)"
      return 0
    fi
    rm -f "$new"
  fi
  _paxel_setup_item "Codex notify" "left alone" "could not put your notify back in ~/.codex/config.toml, so Paxel's notify stays and still runs $prog after each turn"
  return 1
}

# NEW must hold TEXT at line N as its only top-level notify, and every other
# line of ORIGINAL but its line N.
_paxel_codex_restore_verify() {
  local orig="$1" new="$2" n="$3" text="$4" m a b
  m=$(printf '%s\n' "$text" | wc -l | tr -d ' ')
  m=$((n + m - 1))
  _paxel_toml_read "$new"
  [ "$_PX_TOML_BAD" = 0 ] && [ "$_PX_TOML_NOTIFY_COUNT" = 1 ] &&
    [ "$_PX_TOML_NOTIFY_START" = "$n" ] && [ "$_PX_TOML_NOTIFY_END" = "$m" ] || return 1
  [ "$(awk -v n="$n" -v m="$m" 'NR >= n && NR <= m' "$new")" = "$text" ] || return 1
  a=$(awk -v n="$n" -v m="$m" 'NR < n || NR > m' "$new" | paxel_sha256)
  b=$(awk -v n="$n" 'NR != n' "$orig" | paxel_sha256)
  [ "$a" = "$b" ]
}

_paxel_setup_notify_snippet() {
  printf '    Add this line at the top of ~/.codex/config.toml yourself, above the first [table]:\n      %s\n' "$1"
}

# Reads a TOML file and sets _PX_TOML_HEADER (first table header line, 0 if
# none), _PX_TOML_LAST (last line of the last top-level statement before
# it), _PX_TOML_NOTIFY_START/_END/_COUNT for a top-level notify key (bare,
# "notify" or 'notify'), and _PX_TOML_BAD=1 when a multi-line string or array
# never closes or the file starts with a byte-order mark. Strings and
# brackets are tracked so a "[" inside a multi-line value is never taken for
# a table header.
_paxel_toml_read() {
  local scan kind a b
  _PX_TOML_HEADER=0
  _PX_TOML_LAST=0
  _PX_TOML_NOTIFY_START=0
  _PX_TOML_NOTIFY_END=0
  _PX_TOML_NOTIFY_COUNT=0
  _PX_TOML_BAD=0
  # A byte-order mark hides a first-line table header from the scan.
  if [ "$(head -c 3 "$1" 2>/dev/null | od -An -tx1 | tr -d ' \n')" = efbbbf ]; then
    _PX_TOML_BAD=1
    return 0
  fi
  scan=$(awk '
    BEGIN { ml = ""; depth = 0; header = 0; last = 0; start = 0; isnotify = 0; bad = 0 }
    {
      line = $0
      sub(/\r$/, "", line)
      if (ml == "" && depth == 0) {
        t = line
        sub(/^[ \t]+/, "", t)
        if (t == "" || substr(t, 1, 1) == "#") next
        if (substr(t, 1, 1) == "[") { header = NR; exit }
        start = NR
        isnotify = (t ~ /^("notify"|notify)[ \t]*=/)
        if (!isnotify && substr(t, 1, 8) == "\047notify\047") isnotify = (substr(t, 9) ~ /^[ \t]*=/)
      }
      n = length(line)
      i = 1
      while (i <= n) {
        c = substr(line, i, 1)
        if (ml == "b") {
          if (c == "\\") { i += 2; continue }
          if (substr(line, i, 3) == "\"\"\"") { ml = ""; i += 3; continue }
          i++; continue
        }
        if (ml == "l") {
          if (substr(line, i, 3) == "\047\047\047") { ml = ""; i += 3; continue }
          i++; continue
        }
        if (c == "#") break
        if (substr(line, i, 3) == "\"\"\"") { ml = "b"; i += 3; continue }
        if (substr(line, i, 3) == "\047\047\047") { ml = "l"; i += 3; continue }
        if (c == "\"") {
          i++
          while (i <= n) {
            c = substr(line, i, 1)
            if (c == "\\") { i += 2; continue }
            if (c == "\"") break
            i++
          }
          i++; continue
        }
        if (c == "\047") {
          i++
          while (i <= n && substr(line, i, 1) != "\047") i++
          i++; continue
        }
        if (c == "[" || c == "{") depth++
        else if (c == "]" || c == "}") depth--
        i++
      }
      if (depth < 0) { bad = 1; exit }
      if (ml == "" && depth == 0) {
        last = NR
        if (isnotify) { print "notify " start " " NR; isnotify = 0 }
      }
    }
    END {
      if (bad || ml != "" || depth != 0) { print "bad"; exit }
      print "header " header
      print "last " last
    }
  ' "$1" 2>/dev/null) || { _PX_TOML_BAD=1; return 0; }
  while read -r kind a b; do
    case "$kind" in
      bad) _PX_TOML_BAD=1 ;;
      header) _PX_TOML_HEADER="$a" ;;
      last) _PX_TOML_LAST="$a" ;;
      notify)
        _PX_TOML_NOTIFY_COUNT=$((_PX_TOML_NOTIFY_COUNT + 1))
        _PX_TOML_NOTIFY_START="$a"
        _PX_TOML_NOTIFY_END="$b"
        ;;
    esac
  done <<PAXEL_TOML_SCAN
$scan
PAXEL_TOML_SCAN
}

# Sets _PX_NOTIFY_STATE to ours (exactly LINE), stale (a Paxel notify for
# another path), foreign, absent or bad, and _PX_NOTIFY_LINE to its line.
_paxel_codex_notify_state() {
  local file="$1" want="$2" text
  _PX_NOTIFY_LINE=0
  _paxel_toml_read "$file"
  if [ "$_PX_TOML_BAD" = 1 ] || [ "$_PX_TOML_NOTIFY_COUNT" -gt 1 ]; then
    _PX_NOTIFY_STATE=bad
    return 0
  fi
  if [ "$_PX_TOML_NOTIFY_COUNT" = 0 ]; then
    _PX_NOTIFY_STATE=absent
    return 0
  fi
  _PX_NOTIFY_STATE=foreign
  [ "$_PX_TOML_NOTIFY_START" = "$_PX_TOML_NOTIFY_END" ] || return 0
  _PX_NOTIFY_LINE="$_PX_TOML_NOTIFY_START"
  text=$(sed -n "${_PX_NOTIFY_LINE}p" "$file")
  text=${text%$'\r'}
  if [ "$text" = "$want" ]; then
    _PX_NOTIFY_STATE=ours
  elif [[ "$text" =~ $_PX_NOTIFY_OURS_RE ]]; then
    _PX_NOTIFY_STATE=stale
  fi
}

# FILE NEW MODE N LINE [M]: writes FILE to NEW with LINE inserted after line
# N (after), at the top (top), at the end (end), in place of lines N to M
# (replace; M defaults to N), or with line N deleted (delete).
_paxel_toml_put_line() {
  PX_LINE="$5" awk -v mode="$3" -v n="$4" -v m="${6:-$4}" '
    mode == "top" && NR == 1 { print ENVIRON["PX_LINE"] }
    mode == "replace" && NR == n { print ENVIRON["PX_LINE"]; next }
    mode == "replace" && NR > n && NR <= m { next }
    mode == "delete" && NR == n { next }
    { print }
    mode == "after" && NR == n { print ENVIRON["PX_LINE"] }
    END { if (mode == "end" || (mode == "top" && NR == 0)) print ENVIRON["PX_LINE"] }
  ' "$1" > "$2"
}

# Reads NEW back: LINE must be its only top-level notify, above any table,
# and every other line must match ORIGINAL (minus lines REPLACED to END, if
# set).
_paxel_codex_notify_verify() {
  local orig="$1" new="$2" line="$3" replaced="${4:-0}" end="${5:-${4:-0}}" n a b
  _paxel_codex_notify_state "$new" "$line"
  [ "$_PX_NOTIFY_STATE" = ours ] || return 1
  n="$_PX_NOTIFY_LINE"
  if [ "$_PX_TOML_HEADER" != 0 ] && [ "$n" -ge "$_PX_TOML_HEADER" ]; then return 1; fi
  a=$(awk -v n="$n" 'NR != n' "$new" | paxel_sha256)
  b=$(awk -v n="$replaced" -v m="$end" 'NR < n || NR > m' "$orig" | paxel_sha256)
  [ "$a" = "$b" ]
}

# WHY says why notify cannot be Paxel's.
_paxel_setup_codex_hooks_json() {
  local why="$1" file="$HOME/.codex/hooks.json" cmd input new
  cmd=$(_paxel_hook_command codex)
  if [ -L "$file" ]; then
    _paxel_setup_item "Codex hook" "not registered" "$why, and ~/.codex/hooks.json is a symlink, left alone"
    _paxel_setup_codex_hook_snippet "$cmd"
    return 1
  fi
  if ! input=$(_paxel_setup_json_input "$file") ||
     ! printf '%s\n' "$input" | jq -e '(.hooks // {}) | type == "object" and ((.Stop // []) | type == "array")' >/dev/null 2>&1; then
    _paxel_setup_item "Codex hook" "not registered" "$why, and ~/.codex/hooks.json is not valid, left alone"
    _paxel_setup_codex_hook_snippet "$cmd"
    return 1
  fi
  if printf '%s\n' "$input" | jq -e --arg cmd "$cmd" "$_PX_JQ_CODEX_HAS_CMD" >/dev/null 2>&1; then
    if _paxel_codex_hook_trusted; then
      _paxel_setup_item "Codex hook" unchanged "~/.codex/hooks.json Stop hook"
    else
      _paxel_setup_item "Codex hook" unchanged "~/.codex/hooks.json Stop hook, waiting for trust: open Codex and run /hooks"
    fi
    return 0
  fi
  # Appended as its own last group and never rewritten: Codex keys trust to
  # the group's position and a hash of the entry.
  if ! new=$(printf '%s\n' "$input" | jq --arg cmd "$cmd" '.hooks = (.hooks // {}) | .hooks.Stop = ((.hooks.Stop // []) + [{hooks: [{type: "command", command: $cmd, timeout: 5}]}])') ||
     ! _paxel_setup_write_json "$file" "$new"; then
    _paxel_setup_item "Codex hook" "not registered" "could not write ~/.codex/hooks.json"
    return 1
  fi
  _paxel_setup_item "Codex hook" created "~/.codex/hooks.json Stop hook ($why)"
  printf '    Codex needs this hook trusted on each new box: open Codex, run /hooks and approve the Paxel Stop hook. Codex skips it until then.\n'
  _PX_CODEX_RESTART=1
}

_paxel_setup_codex_hook_snippet() {
  printf '    Add this Stop hook to ~/.codex/hooks.json yourself, as its own last group, then trust it in /hooks:\n'
  jq -n --arg cmd "$1" '{hooks: {Stop: [{hooks: [{type: "command", command: $cmd, timeout: 5}]}]}}' | sed 's/^/      /'
}

# Prints "GROUP:HOOK" for the Paxel Stop hook in ~/.codex/hooks.json.
_paxel_codex_hook_position() {
  jq -r --arg cmd "$(_paxel_hook_command codex)" '
    [ (.hooks.Stop? // []) | to_entries[] | .key as $g
      | (.value.hooks? // []) | to_entries[] | select(.value.command? == $cmd) | "\($g):\(.key)" ] | last // empty
  ' "$HOME/.codex/hooks.json" 2>/dev/null
}

# Codex records trust in config.toml as
# [hooks.state."<hooks.json path>:<event>:<group>:<hook>"] trusted_hash = …
# Only the record's presence is checked; the hash is never read out.
_paxel_codex_hook_trusted() {
  local pos
  pos=$(_paxel_codex_hook_position) || return 1
  case "$pos" in [0-9]*:[0-9]*) ;; *) return 1 ;; esac
  [ -f "$HOME/.codex/config.toml" ] || return 1
  PX_KEY="[hooks.state.\"$HOME/.codex/hooks.json:stop:$pos\"]" awk '
    { t = $0; sub(/^[ \t]+/, "", t); sub(/[ \t\r]+$/, "", t) }
    substr(t, 1, 1) == "[" { inside = (t == ENVIRON["PX_KEY"]); next }
    inside && t ~ /^trusted_hash[ \t]*=/ { found = 1; exit }
    END { exit !found }
  ' "$HOME/.codex/config.toml"
}

# A notify a chained setup replaced is put back; a saved program whose
# notify is gone (the user changed it) is forgotten.
_paxel_setup_codex_notify_remove() {
  local cfg="$HOME/.codex/config.toml" new
  if [ ! -f "$cfg" ]; then
    [ -L "$cfg" ] || _paxel_codex_chain_forget
    _paxel_setup_item "Codex notify" "not present" "~/.codex/config.toml"
    return 0
  fi
  if [ -L "$cfg" ]; then
    _paxel_setup_item "Codex notify" "left alone" "~/.codex/config.toml is a symlink: remove the Paxel notify line from it yourself"
    return 1
  fi
  _paxel_codex_notify_state "$cfg" "$(_paxel_codex_notify_line)"
  case "$_PX_NOTIFY_STATE" in
    ours|stale) ;;
    bad)
      if _paxel_codex_chain_read; then
        _paxel_setup_item "Codex notify" "left alone" "setup cannot read ~/.codex/config.toml, so your notify is not back yet: fix the file, then run $HOME/.paxel/bin/paxel setup --off again"
        return 1
      fi
      _paxel_setup_item "Codex notify" "not present" "~/.codex/config.toml"
      return 0
      ;;
    *)
      _paxel_codex_chain_forget
      _paxel_setup_item "Codex notify" "not present" "~/.codex/config.toml"
      return 0
      ;;
  esac
  if _paxel_codex_chain_read; then
    _paxel_setup_codex_notify_restore "$cfg"
    return
  fi
  if ! new=$(_paxel_setup_tmp "$cfg"); then
    _paxel_setup_item "Codex notify" "left alone" "could not rewrite ~/.codex/config.toml"
    return 1
  fi
  _paxel_toml_put_line "$cfg" "$new" delete "$_PX_NOTIFY_LINE" ""
  if _paxel_setup_replace_file "$cfg" "$new"; then
    _paxel_setup_item "Codex notify" removed "~/.codex/config.toml"
    return 0
  fi
  rm -f "$new"
  _paxel_setup_item "Codex notify" "left alone" "could not rewrite ~/.codex/config.toml"
  return 1
}

_paxel_setup_codex_hooks_json_remove() {
  local file="$HOME/.codex/hooks.json" input new
  [ -e "$file" ] || [ -L "$file" ] || return 0
  if [ -L "$file" ] || ! input=$(_paxel_setup_json_input "$file"); then
    _paxel_setup_item "Codex hook" "left alone" "~/.codex/hooks.json is a symlink or not valid JSON: remove the Paxel Stop hook from it yourself"
    return 1
  fi
  if ! printf '%s\n' "$input" | jq -e --arg re "$_PX_CODEX_HOOK_RE" "$_PX_JQ_HOOK_DEFS"'any((.hooks? // {} | objects | .[])[]?; has_paxel)' >/dev/null 2>&1; then
    return 0
  fi
  if ! new=$(printf '%s\n' "$input" | jq --arg re "$_PX_CODEX_HOOK_RE" "$_PX_JQ_HOOK_DEFS$_PX_JQ_CODEX_REMOVE" 2>/dev/null) ||
     ! _paxel_setup_write_json "$file" "$new"; then
    _paxel_setup_item "Codex hook" "left alone" "could not rewrite ~/.codex/hooks.json"
    return 1
  fi
  _paxel_setup_item "Codex hook" removed "~/.codex/hooks.json"
}

# --- Off switch ---

_paxel_setup_turn_off() {
  _paxel_setup_claude_hooks_remove || true
  if _paxel_setup_safe_dir .codex; then
    _paxel_setup_codex_notify_remove || true
    _paxel_setup_codex_hooks_json_remove || true
  else
    _paxel_setup_item "Codex notify" "left alone" "~/.codex is a symlink or belongs to another account: remove the Paxel notify line and Stop hook from it yourself"
  fi
  [ -n "$(paxel_config_get off_at)" ] || paxel_config_set off_at "$(paxel_now_iso)"
  paxel_log "setup off$_PX_SETUP_LOG"
  printf '%s Capture is off: agent turns no longer start a push, and push does nothing while off. Run %s/.paxel/bin/paxel setup to turn it back on; the next push then also copies the sessions you ran while capture was off.\n' "$1" "$HOME"
}

# --- Output ---

_paxel_setup_item() {
  local label="$1" state="$2" detail="${3:-}" key
  printf '  %-13s %-15s %s\n' "$label" "$state" "$detail"
  case "$state" in created|updated|found|removed|installed|chained|restored) _PX_SETUP_CHANGED=1 ;; esac
  key=$(printf '%s' "$label" | tr 'A-Z ' 'a-z_')
  _PX_SETUP_LOG="$_PX_SETUP_LOG $key=$(printf '%s' "$state" | tr ' ' '_')"
}

_paxel_setup_warn() {
  printf 'warning: %s\n' "$*" >&2
}

_paxel_setup_footer() {
  local store floor widened
  store=$(_paxel_setup_saved_store)
  floor=$(paxel_config_get history_since)
  widened=$(_paxel_setup_floor_widened)
  if [ -n "$store" ]; then
    printf 'Store: https://%s\n' "$store"
    if [ "$_PX_STORE_USABLE" = 1 ] && [ ! -f "$PAXEL_HOME_DIR/push/last.json" ]; then
      if [ -z "$floor" ]; then
        printf "The first push copies this machine's full Claude Code and Codex history to the store."
      else
        printf 'The first push copies the Claude Code and Codex sessions active since %s; older ones stay on this machine (to add them: %s/.paxel/bin/paxel setup --since all).' \
          "$(paxel_epoch_iso "$floor")" "$HOME"
      fi
      printf ' It starts about a minute after the next agent turn ends. To see when it is done, run %s/.paxel/bin/paxel status --wait after that turn.\n' "$HOME"
    elif [ -n "$widened" ]; then
      printf '%s\n' "$widened"
    elif [ -n "$_PX_WAS_OFF" ]; then
      printf "Capture is back on. The next push also copies the Claude Code and Codex sessions you ran while it was off%s.\n" "$(_paxel_setup_off_since)"
    fi
  fi
  if [ "$_PX_CODEX_RESTART" = 1 ]; then
    printf 'Codex sessions that are already running start capturing after a restart.\n'
  fi
  printf 'Check capture: %s/.paxel/bin/paxel status\n' "$HOME"
}

# " (since <time>)" for an off_at that setup wrote.
_paxel_setup_off_since() {
  case "$_PX_WAS_OFF" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) printf ' (since %s)' "$_PX_WAS_OFF" ;;
  esac
}

_paxel_setup_has_tty() {
  case "${PAXEL_TEST_TTY:-}" in
    1) return 0 ;;
    0) return 1 ;;
  esac
  { : </dev/tty; } 2>/dev/null
}

# A provisioning script run in a PTY (T3 Code, Conductor) has a /dev/tty
# nobody answers, so the question times out and counts as yes, like the
# no-TTY path. PAXEL_TEST_TTY=1 reads the answer from stdin so bats can
# script it (and ends the prompt line the way a terminal echo would). A
# second argument of "no" makes an empty answer or a timeout mean no.
_paxel_setup_ask() {
  local answer="" secs="${PAXEL_SETUP_PROMPT_SECS:-30}" rc=0 start default="${2:-yes}"
  { paxel_is_uint "$secs" && [ "${#secs}" -le 5 ] && [ "$secs" -gt 0 ]; } || secs=30
  start=$SECONDS
  if [ "${PAXEL_TEST_TTY:-}" = 1 ]; then
    printf '%s' "$1" >&2
    IFS= read -t "$secs" -r answer || rc=$?
    printf '\n' >&2
  else
    printf '%s' "$1" >/dev/tty
    IFS= read -t "$secs" -r answer </dev/tty || rc=$?
  fi
  # bash 3.2 reports a timeout as 1, like end of input
  if [ "$rc" -gt 128 ] || { [ "$rc" -ne 0 ] && [ $((SECONDS - start)) -ge "$secs" ]; }; then
    [ "${PAXEL_TEST_TTY:-}" = 1 ] || printf '\n' >/dev/tty
    if [ "$default" = no ]; then
      printf '  No answer after %ss, so the answer is no.\n' "$secs"
      return 1
    fi
    printf '  No answer after %ss, so setup went on as if you had said yes.\n' "$secs"
    return 0
  fi
  case "$answer" in
    [Yy]|[Yy][Ee][Ss]) return 0 ;;
    '') [ "$default" = yes ] && return 0 ;;
  esac
  return 1
}

_paxel_setup_config_clear() {
  [ -z "$(paxel_config_get "$1")" ] || paxel_config_set "$1" "" || true
}

# Writes only on a change, but always writes a missing key, even empty.
_paxel_setup_config_put() {
  if [ "$(paxel_config_get "$1")" = "$2" ] && grep -q "^$1=" "$PAXEL_CONFIG_FILE" 2>/dev/null; then
    return 0
  fi
  paxel_config_set "$1" "$2"
}

# --- Paxel transcript store: status ---

# null means "not checked" (a probe that could not run, or no data yet).
_PX_JQ_STATUS_BUILD='
def nz: if . == "" then null else . end;
def lines: split("\n") | map(select(length > 0));
{
  schema_version: 1,
  healthy: (($steps | lines) == []),
  box_id: $box_id,
  target_user: ($user | nz),
  home: $home,
  paxel_version: ($version | nz),
  setup_at: ($setup_at | nz),
  off_at: ($off_at | nz),
  script_cache_age_secs: $cache_age,
  launcher: {installed: $launcher, server: ($server | nz)},
  store: {
    configured: $configured,
    display: ($display | nz),
    branch: ($branch | nz),
    transport: ($transport | nz),
    cli: ($cli | nz),
    login: ($login | nz),
    auth: ($auth | nz),
    readable: $readable,
    writable: $writable,
    visibility: ($visibility | nz),
    private: (if $visibility == "private" then true elif $visibility == "public" or $visibility == "internal" then false else null end),
    marker_present: $marker,
    missing_since: ($missing_since | nz),
    declined_at: ($declined_at | nz),
    retry_at: ($retry_at | nz),
    next_retry_after: ($next_retry | nz)
  },
  hooks: {
    claude: {registered: $claude_reg, via: ($claude_via | nz), trust_pending: false,
             last_trigger_at: ($claude_last | nz), triggered_since_setup: $claude_since},
    codex: {registered: $codex_reg, via: ($codex_via | nz), trust_pending: $codex_trust,
            chained_program: ($codex_chained | nz),
            last_trigger_at: ($codex_last | nz), triggered_since_setup: $codex_since}
  },
  last_push: $last_push,
  history: {since: ($history_since | nz), sessions_outside: $outside_sessions, bytes_outside: $outside_bytes},
  push: {pending: $pending, worker_running: $worker, scrub_failed: $scrub_failed,
         state: $push_state, starts_in_secs: $starts_in, running_since: ($running_since | nz)},
  tools: {bash: ($bash_v | nz), git: ($git_v | nz), jq: ($jq_v | nz), curl: ($curl_v | nz),
          gh: ($gh_v | nz), glab: ($glab_v | nz)},
  warnings: ($notes | lines),
  next_steps: ($steps | lines)
}
'

# last.json is written by the push worker, but every value is still
# type-checked here before it reaches the report.
_PX_JQ_LAST_PUSH='
def str: if type == "string" then . else null end;
def num: if type == "number" and . >= 0 and . == floor then . else null end;
def ids: if type == "array" then map(select(type == "string")) else [] end;
if type != "object" then null else {
  at: (.at | str),
  result: (.result | if . == "ok" or . == "partial" or . == "error" or . == "off" or . == "skipped" then . else null end),
  store: (.store | str),
  sessions_written: (.sessions_written | num),
  catchup_remaining_bytes: (.catchup_remaining_bytes | num),
  skipped_too_large: (.skipped_too_large | ids),
  quarantined: (.quarantined | ids),
  scrub_failed: (.scrub_failed | ids),
  error_class: (.error_class | str)
} end
'

_PX_JQ_SESSIONS='def sessions: "\(.) session\(if . == 1 then "" else "s" end)";'

_PX_JQ_STATUS_HUMAN='
def yn: if . == true then "yes" elif . == false then "no" else "not checked" end;
def size: if . >= 1048576 then "\((. / 104857.6 | round) / 10) MB" elif . >= 1024 then "\(. / 1024 | round) KB" else "\(.) bytes" end;
def hook:
  if .registered then
    "registered"
    + (if .via then " (\(.via)\(if .chained_program then ", then runs \(.chained_program)" else "" end))" else "" end)
    + (if .trust_pending then ", waiting for trust in /hooks" else "" end)
    + (if .last_trigger_at then ", last trigger \(.last_trigger_at)" else "" end)
    + (if .triggered_since_setup then "" else ", no trigger since setup" end)
  else "not registered" end;
"Paxel capture: " + (if .healthy then "on" elif .off_at then "off" else "needs attention" end),
"  Box:          \(.box_id) (\(.target_user // "?"), \(.home))",
(if .store.configured then
  "  Store:        \(.store.display) via \(.store.cli | if . == null or . == "none" then "git" else . end)" + (if .store.login then " as \(.store.login)" else "" end),
  "                readable \(.store.readable | yn), writable \(.store.writable | yn), visibility \(.store.visibility // "not checked"), marker \(.store.marker_present | yn)"
 else "  Store:        not set up"
   + (if .store.declined_at then " (you chose not to create it at setup)"
      elif .store.missing_since then (if .store.next_retry_after then "; push looks for it again at its first run after \(.store.next_retry_after)" else "; push looks for it again at its next run" end)
      else "" end) end),
"  Claude Code:  \(.hooks.claude | hook)",
"  Codex:        \(.hooks.codex | hook)",
"  Last push:    " + (if .last_push == null then "none yet"
   else "\(.last_push.at // "?") \(.last_push.result // "?"), \(.last_push.sessions_written // 0 | sessions) written"
        + (if (.last_push.catchup_remaining_bytes // 0) > 0 then ", \(.last_push.catchup_remaining_bytes) bytes of history still to push" else "" end) end),
"  History:      " + (if .history.since == null then "all"
   else "since \(.history.since)"
        + (if (.history.sessions_outside // 0) > 0
           then "; \(.history.sessions_outside) older session\(if .history.sessions_outside == 1 then "" else "s" end) (\(.history.bytes_outside | size)) \(if .history.sessions_outside == 1 then "stays" else "stay" end) on this machine"
           else "" end) end),
"  Pending:      " + (
   if .push.state == "pushing" then "yes, pushing now"
        + (.push.running_since | if . then " (for \(now - fromdateiso8601 | floor | if . < 0 then 0 else . end) s)" else "" end)
   elif .push.state == "waiting" then "yes, waiting for agent activity to stop; the push starts in about \(.push.starts_in_secs // 0) s"
   elif .push.pending then "yes"
   else "no" end),
(if .off_at then "  Off since:    \(.off_at)" else empty end),
"  Script cache: " + (if .script_cache_age_secs == null then "none yet" else "\(.script_cache_age_secs)s old" end),
(.warnings[] | "  Note: \(.)"),
(if (.next_steps | length) > 0 then "Next steps:", (.next_steps[] | "  - \(.)") else empty end)
'

paxel_cmd_status() {
  local rc=0
  _paxel_status_main "$@" || rc=$?
  return "$rc"
}

_paxel_status_main() {
  local json=0 wait=0 report
  while [ $# -gt 0 ]; do
    case "$1" in
      --json) json=1 ;;
      --wait) wait=1 ;;
      -h|--help)
        printf 'Usage: paxel status [--json] [--wait]\n'
        printf '  --json  print the report as JSON\n'
        printf '  --wait  when a push is waiting or running, follow it until it is done, then print the report\n'
        return 0
        ;;
      *) printf "Unknown status option '%s'. Usage: paxel status [--json] [--wait]\n" "$1" >&2; return 2 ;;
    esac
    shift
  done
  paxel_refresh_launcher
  _paxel_stat_is_gnu || true
  if ! command -v jq >/dev/null 2>&1; then
    if [ "$json" = 1 ]; then
      printf '{"schema_version":1,"healthy":false,"error":"jq_missing","next_steps":["Run paxel setup, which installs the official jq in ~/.paxel/bin, or install jq 1.6 or later, then run paxel status again."]}\n'
    else
      printf 'Paxel capture: needs attention\nNext steps:\n  - Run paxel setup, which installs the official jq in ~/.paxel/bin, or install jq 1.6 or later, then run paxel status again.\n'
    fi
    return 1
  fi
  if [ "$wait" = 1 ]; then
    if [ "$json" = 1 ]; then _paxel_status_wait >&2; else _paxel_status_wait; fi
  fi
  report=$(_paxel_status_report)
  if [ "$json" = 1 ]; then
    printf '%s\n' "$report"
  else
    printf '%s\n' "$report" | jq -r "$_PX_JQ_SESSIONS $_PX_JQ_STATUS_HUMAN"
  fi
  [ "$(printf '%s\n' "$report" | jq -r '.healthy')" = true ]
}

# Each collect step sets _PS_* fields and adds next steps (things that need
# action, which make status exit 1) and notes (informational).
_paxel_status_report() {
  _PS_STEPS=""
  _PS_NOTES=""
  _paxel_status_collect_machine
  _paxel_status_collect_store
  _paxel_status_collect_claude
  _paxel_status_collect_codex
  _paxel_status_collect_agent_dirs
  _paxel_status_collect_push
  _paxel_status_collect_history
  _paxel_status_json
}

_paxel_status_step() { _PS_STEPS="$_PS_STEPS$*"$'\n'; }
_paxel_status_note() { _PS_NOTES="$_PS_NOTES$*"$'\n'; }

_paxel_status_collect_machine() {
  local m
  _PS_BIN="$HOME/.paxel/bin/paxel"
  _PS_SETUP_AT=$(paxel_config_get setup_at)
  _PS_OFF_AT=$(paxel_config_get off_at)
  _PS_USER=$(paxel_config_get target_user)
  [ -n "$_PS_USER" ] || _PS_USER=$(id -un 2>/dev/null || true)
  _PS_LAUNCHER=false
  _PS_SERVER=""
  if [ -x "$_PS_BIN" ] && grep -q '^# paxel-launcher v1' "$_PS_BIN" 2>/dev/null; then
    _PS_LAUNCHER=true
    _PS_SERVER=$(paxel_config_get launcher_server)
  fi
  _PS_CACHE_AGE=null
  if m=$(_paxel_status_mtime "$PAXEL_HOME_DIR/paxel.sh"); then
    _PS_CACHE_AGE=$(( $(paxel_now_epoch) - m ))
    [ "$_PS_CACHE_AGE" -ge 0 ] || _PS_CACHE_AGE=0
  fi
  _PS_GIT_V=$(git --version 2>/dev/null | sed -n 's/^git version //p')
  _PS_JQ_V=$(jq --version 2>/dev/null | sed 's/^jq-//')
  _PS_CURL_V=$(curl --version 2>/dev/null | sed -n '1s/^curl \([^ ]*\).*/\1/p')
  _PS_GH_V=$(gh --version 2>/dev/null | sed -n '1s/^gh version \([^ ]*\).*/\1/p')
  _PS_GLAB_V=$(glab --version 2>/dev/null | sed -n '1s/^glab[^0-9]*\([0-9][^ ]*\).*/\1/p')

  if [ "$_PS_LAUNCHER" != true ]; then
    _paxel_status_step "Paxel is not set up on this machine. Run: curl -fsSL ${PAXEL_SERVER:-https://paxel.ycombinator.com}/paxel.sh | bash -s -- setup || true (in a provisioning script, || true keeps a failed download from stopping it)"
  fi
  if [ -n "$_PS_OFF_AT" ]; then
    _paxel_status_step "Capture is off (since $_PS_OFF_AT). Run $_PS_BIN setup to turn it back on."
  fi
  [ -n "$_PS_GIT_V" ] || _paxel_status_step "Install git 2.27 or later; push needs it."
  if [ -n "$_PS_JQ_V" ] && ! _paxel_setup_version_ge "$_PS_JQ_V" 1 6; then
    _paxel_status_step "jq $_PS_JQ_V is too old for the credential scrub, so push refuses to run. Run $_PS_BIN setup, which installs the official jq in ~/.paxel/bin, or install jq 1.6 or later, then run $_PS_BIN status again."
  fi
}

_paxel_status_collect_store() {
  _PS_CONFIGURED=false
  _PS_DISPLAY=$(_paxel_setup_saved_store)
  _PS_BRANCH=$(paxel_config_get store_branch)
  _PS_TRANSPORT=$(paxel_config_get store_transport)
  _PS_CLI=$(paxel_config_get store_cli)
  # The CLI the messages name; store_cli=none means plain git credentials.
  _PS_TOOL="$_PS_CLI"
  [ "$_PS_TOOL" != none ] || _PS_TOOL=""
  _PS_LOGIN=$(paxel_config_get store_login)
  _PS_AUTH=$(paxel_config_get store_auth)
  _PS_READABLE=null
  _PS_WRITABLE=null
  _PS_MARKER=null
  _PS_VISIBILITY=""
  _PS_MISSING_SINCE=""
  _PS_DECLINED_AT=""
  _PS_RETRY_AT=""
  _PS_NEXT_RETRY=""
  _paxel_status_store_retry
  if [ -z "$_PS_DISPLAY" ]; then
    # Only a search for a store needs the logins; setup reuses a saved store.
    _paxel_status_cli_notes
    [ "$_PS_LAUNCHER" = true ] || return 0
    if [ -n "$_PS_DECLINED_AT" ]; then
      _paxel_status_step "No store is set up, so nothing is pushed: you chose not to create one at setup ($_PS_DECLINED_AT). Run $_PS_BIN setup to create it, or set PAXEL_STORE=host/owner/name and run setup."
    elif [ -n "$_PS_MISSING_SINCE" ]; then
      _paxel_status_step "No store is set up yet, so nothing is pushed. Log in with 'gh auth login' or 'glab auth login'; push looks for the store again $(_paxel_status_retry_when), or run $_PS_BIN setup to look now."
    else
      _paxel_status_step "No store is set up, so nothing is pushed. Log in with 'gh auth login' or 'glab auth login', then run: $_PS_BIN setup"
    fi
    return 0
  fi
  _PS_CONFIGURED=true
  if declare -F paxel_store_display >/dev/null; then _PS_DISPLAY=$(paxel_store_display); fi
  if [ -n "$_PS_GIT_V" ]; then
    _paxel_status_probe_store "${_PS_BRANCH:-main}"
  fi
  _PS_VISIBILITY=$(paxel_store_visibility 2>/dev/null) || _PS_VISIBILITY=""
  case "$_PS_VISIBILITY" in private|internal|public|unknown) ;; *) _PS_VISIBILITY=unknown ;; esac

  _paxel_status_add_steps "$(_paxel_status_access_problems)"
  case "$_PS_VISIBILITY" in
    public|internal) _paxel_status_step "$_PS_DISPLAY is $_PS_VISIBILITY. Pushes stay stopped until you make it private." ;;
    unknown)
      if [ -n "$_PS_TOOL" ]; then
        _paxel_status_note "Could not check the store visibility this time (network or rate limit); push checks it again on its next run."
      else
        _paxel_status_note "With no gh or glab login, this machine can detect only a public store, so it cannot confirm that $_PS_DISPLAY is private. Push checks for public on each run."
      fi
      ;;
  esac
}

# The retry state push keeps for a store setup could not find or create.
_paxel_status_store_retry() {
  local next
  _PS_DECLINED_AT=$(paxel_config_get store_declined_at)
  if [ -n "$_PS_DECLINED_AT" ]; then return 0; fi
  _PS_MISSING_SINCE=$(paxel_config_get store_missing_at)
  [ -n "$_PS_MISSING_SINCE" ] || return 0
  _PS_RETRY_AT=$(paxel_config_get store_retry_at)
  if next=$(paxel_store_retry_next) && [ "$(paxel_now_epoch)" -lt "$next" ]; then
    _PS_NEXT_RETRY=$(paxel_epoch_iso "$next")
  fi
}

_paxel_status_retry_when() {
  if [ -n "$_PS_NEXT_RETRY" ]; then
    printf 'at its first run after %s' "$_PS_NEXT_RETRY"
  else
    printf 'at its next run, after an agent turn ends'
  fi
}

# One line per problem the store probe found, each with its fix. Setup
# prints the same lines after its own probe.
_paxel_status_access_problems() {
  if [ "$_PS_READABLE" = false ]; then
    if [ -n "$_PS_TOOL" ]; then
      printf "This machine cannot read %s. Check '%s auth status' (or the SSH key for %s when the transport is ssh), then run %s status again.\n" \
        "$_PS_DISPLAY" "$_PS_TOOL" "${_PS_DISPLAY%%/*}" "$_PS_BIN"
    elif [ -n "${_PS_MISSING_SINCE:-}" ] && [ "$(paxel_config_get store_auth)" = git ]; then
      printf "This machine's git login cannot read %s: it does not exist yet, or no credential helper, GIT_ASKPASS or SSH key here reaches it. With no gh or glab login, Paxel cannot create it here: create it from your main machine with curl -fsSL %s/paxel.sh | PAXEL_STORE=%s bash -s -- --create-store --yes, or give git a login for %s. Push looks for it again %s.\n" \
        "$_PS_DISPLAY" "$(_paxel_setup_server)" "$_PS_DISPLAY" "${_PS_DISPLAY%%/*}" "$(_paxel_status_retry_when)"
    else
      printf 'This machine cannot read %s. Check the git credentials for %s (or the SSH key when the transport is ssh), then run %s status again.\n' \
        "$_PS_DISPLAY" "${_PS_DISPLAY%%/*}" "$_PS_BIN"
    fi
  fi
  if [ "$_PS_WRITABLE" = false ]; then
    printf 'This machine can read %s but cannot push to it. The %s login needs write access to the repo.\n' "$_PS_DISPLAY" "${_PS_TOOL:-git}"
  fi
  if [ "$_PS_MARKER" = false ] && [ -n "$_PS_MISSING_SINCE" ]; then
    printf 'Setup could not finish creating %s: it has no paxel-store.json yet, so nothing is pushed. Push tries to finish it %s, or run %s setup to finish it now.\n' "$_PS_DISPLAY" "$(_paxel_status_retry_when)" "$_PS_BIN"
  elif [ "$_PS_MARKER" = false ]; then
    printf '%s has no paxel-store.json, so push refuses to write to it. Point PAXEL_STORE at your Paxel store and run %s setup again.\n' "$_PS_DISPLAY" "$_PS_BIN"
  fi
}

_paxel_status_add_steps() {
  local p
  while IFS= read -r p; do
    [ -z "$p" ] || _paxel_status_step "$p"
  done <<PAXEL_STATUS_STEPS
$1
PAXEL_STATUS_STEPS
}

_paxel_status_collect_agent_dirs() {
  local p
  while IFS= read -r p; do
    [ -z "$p" ] || _paxel_status_step "$p"
  done <<PAXEL_AGENT_DIRS
$(_paxel_agent_dir_problems)
PAXEL_AGENT_DIRS
}

_paxel_status_collect_claude() {
  _PS_CLAUDE_REG=false
  _PS_CLAUDE_VIA=""
  if _paxel_claude_hooks_registered; then
    _PS_CLAUDE_REG=true
    _PS_CLAUDE_VIA=settings.json
  elif [ -z "$_PS_OFF_AT" ]; then
    _paxel_status_step "Claude Code hooks are not registered in ~/.claude/settings.json. Run $_PS_BIN setup; when the file is a symlink or not valid JSON it prints the hooks to add yourself."
  fi
  _PS_CLAUDE_LAST=$(_paxel_status_trigger claude)
  _PS_CLAUDE_SINCE=$(_paxel_status_since_setup "$_PS_CLAUDE_LAST")
}

_paxel_status_collect_codex() {
  _PS_CODEX_REG=false
  _PS_CODEX_VIA=""
  _PS_CODEX_TRUST=false
  _PS_CODEX_CHAINED=""
  if [ -f "$HOME/.codex/config.toml" ]; then
    _paxel_codex_notify_state "$HOME/.codex/config.toml" "$(_paxel_codex_notify_line)"
    if [ "$_PX_NOTIFY_STATE" = ours ]; then
      _PS_CODEX_REG=true
      _PS_CODEX_VIA=notify
      if _paxel_codex_chain_read; then _PS_CODEX_CHAINED="${_PX_CHAIN_PROG:-no program}"; fi
    fi
  fi
  if [ "$_PS_CODEX_REG" != true ] && _paxel_codex_hook_registered; then
    _PS_CODEX_REG=true
    _PS_CODEX_VIA=hooks.json
    if ! _paxel_codex_hook_trusted; then
      _PS_CODEX_TRUST=true
      _paxel_status_step "Open Codex and run /hooks to trust the Paxel Stop hook. Codex keeps that trust on this box only, so each new box needs it, and skips the hook until then."
    fi
  fi
  if [ "$_PS_CODEX_REG" != true ] && [ -z "$_PS_OFF_AT" ]; then
    _paxel_status_step "Codex capture is not registered (no Paxel notify in ~/.codex/config.toml and no Paxel Stop hook in ~/.codex/hooks.json). Run $_PS_BIN setup."
  fi
  _PS_CODEX_LAST=$(_paxel_status_trigger codex)
  _PS_CODEX_SINCE=$(_paxel_status_since_setup "$_PS_CODEX_LAST")
}

_paxel_status_collect_push() {
  local result notes
  _paxel_status_scrub_failed
  _paxel_status_read_last_push
  if [ "$_PS_LAST_PUSH" != null ]; then
    result=$(printf '%s\n' "$_PS_LAST_PUSH" | jq -r '.result // empty')
    if [ "$result" = error ]; then
      _paxel_status_step "$(_paxel_status_push_error "$_PS_BRANCH" "${_PS_DISPLAY:-the store}")"
    fi
    notes=$(printf '%s\n' "$_PS_LAST_PUSH" | jq -r --argjson failed "$_PS_SCRUB_FAILED" '
      (if (.skipped_too_large | length) > 0 then "A file over the push size limit after scrubbing was left out; the rest of the session was pushed: \(.skipped_too_large | join(", "))" else empty end),
      (if (.quarantined | length) > 0 then "Rejected by the store host for their content, now skipped: \(.quarantined | join(", ")). To retry a session, delete its line from ~/.paxel/push/quarantine.tsv; a git/<repo> snapshot is tried again when that repo gets a new commit." else empty end),
      (if (.scrub_failed | length) > 0 then "Credential scrub failed, so nothing from these was written: \(.scrub_failed | map(. as $s | $s + ([$failed[] | select(.session == $s and .reason != null) | " (\(.reason))"] | first // "")) | join(", ")). Push tries each again after a scrub update, on the next push after file_changed, once a day after timeout, killed, memory, local_io or unknown, and otherwise once a day while the session changes." else empty end)
    ')
    [ -z "$notes" ] || _paxel_status_note "$notes"
  fi
  _PS_PENDING=false
  if _paxel_status_pending; then _PS_PENDING=true; fi
  _paxel_status_push_state
}

_paxel_status_read_last_push() {
  _PS_LAST_PUSH=null
  [ -f "$PAXEL_HOME_DIR/push/last.json" ] || return 0
  _PS_LAST_PUSH=$(jq -c -s "if length == 1 then .[0] | ($_PX_JQ_LAST_PUSH) else null end" "$PAXEL_HOME_DIR/push/last.json" 2>/dev/null) || _PS_LAST_PUSH=null
  case "$_PS_LAST_PUSH" in '{'*'}') ;; *) _PS_LAST_PUSH=null ;; esac
}

# BRANCH DISPLAY: the sentence for a last push that ended in an error.
_paxel_status_push_error() {
  local error_class
  error_class=$(printf '%s\n' "$_PS_LAST_PUSH" | jq -r '.error_class // "unknown"')
  case "$error_class" in *[!a-z0-9_]*) error_class=unknown ;; esac
  printf 'The last push did not finish. %s\n' "$(_PXP_ERROR="$error_class" _PXP_DETAIL="" _PXP_BRANCH="$1" _paxel_push_error_text "$2")"
}

# A live worker is pushing once push/running holds the epoch its run started,
# and before that waits for agent activity to stop.
_paxel_status_push_state() {
  local started=""
  _PS_WORKER=null
  _PS_STATE=idle
  _PS_STARTS_IN=null
  _PS_RUNNING_SINCE=""
  if declare -F paxel_push_lock_alive >/dev/null; then
    if paxel_push_lock_alive; then _PS_WORKER=true; else _PS_WORKER=false; fi
  fi
  [ "$_PS_WORKER" = true ] || return 0
  { read -r started < "$PAXEL_HOME_DIR/push/running"; } 2>/dev/null || true
  if ! paxel_is_uint "$started" || [ "${#started}" -gt 12 ]; then
    started=$(_paxel_mtime "$PAXEL_HOME_DIR/push/running")
  fi
  if [ "$started" != 0 ]; then
    _PS_STATE=pushing
    _PS_RUNNING_SINCE=$(paxel_epoch_iso "$started")
  else
    _PS_STATE=waiting
    _PS_STARTS_IN=$(( $(paxel_push_expected_start) - $(paxel_now_epoch) ))
    [ "$_PS_STARTS_IN" -ge 0 ] || _PS_STARTS_IN=0
    # A pending mtime ahead of this clock still ends after a quiet period of polling.
    [ "$_PS_STARTS_IN" -le "$(_paxel_push_quiet_secs)" ] || _PS_STARTS_IN=$(_paxel_push_quiet_secs)
  fi
}

# PAXEL_STATUS_WAIT_START_SECS covers the launcher's fetch of paxel.sh
# (curl --max-time 30), which a hook runs before its worker takes the lock.
_paxel_status_wait() {
  local poll timeout start begin last elapsed shown=""
  poll=$(_paxel_push_uint_env PAXEL_STATUS_WAIT_POLL_SECS 2)
  [ "$poll" -ge 1 ] || poll=1
  timeout=$(_paxel_push_uint_env PAXEL_STATUS_WAIT_TIMEOUT 900)
  start=$(_paxel_push_uint_env PAXEL_STATUS_WAIT_START_SECS 35)
  begin=$(paxel_now_epoch)
  # Read before the worker check: a worker writes last.json before it lets go of the lock.
  last=$(_paxel_mtime "$PAXEL_HOME_DIR/push/last.json")
  _paxel_status_push_state
  if [ "$_PS_WORKER" != true ]; then
    if ! _paxel_status_pending; then
      printf 'No push is waiting.\n'
      return 0
    fi
    while [ "$_PS_WORKER" != true ] && [ "$(_paxel_mtime "$PAXEL_HOME_DIR/push/last.json")" = "$last" ]; do
      elapsed=$(( $(paxel_now_epoch) - begin ))
      if [ "$elapsed" -ge "$start" ] || [ "$elapsed" -ge "$timeout" ]; then
        printf 'A push is pending but has not started yet. To start it now, run %s/bin/paxel push --now.\n' "$PAXEL_HOME_DIR"
        return 0
      fi
      sleep "$poll"
      _paxel_status_push_state
    done
  fi
  while [ "$(_paxel_mtime "$PAXEL_HOME_DIR/push/last.json")" = "$last" ]; do
    if [ "$_PS_WORKER" != true ]; then
      printf 'The push stopped without writing a result. Its log is in %s/logs.\n' "$PAXEL_HOME_DIR"
      return 0
    fi
    if [ "$_PS_STATE" != "$shown" ]; then
      shown="$_PS_STATE"
      if [ "$shown" = pushing ]; then
        printf 'Pushing now...\n'
      else
        printf 'Waiting for agent activity to stop. The push starts in about %s s.\n' "$_PS_STARTS_IN"
      fi
    fi
    elapsed=$(( $(paxel_now_epoch) - begin ))
    if [ "$elapsed" -ge "$timeout" ]; then
      printf 'Stopped waiting after %s s. The push keeps going on its own; to follow it again, run %s/bin/paxel status --wait.\n' "$elapsed" "$PAXEL_HOME_DIR"
      return 0
    fi
    sleep "$poll"
    _paxel_status_push_state
  done
  _paxel_status_wait_result
  if [ -e "$PAXEL_HOME_DIR/push/pending" ]; then
    printf 'Agent activity since then queued another push. To follow it, run %s/bin/paxel status --wait.\n' "$PAXEL_HOME_DIR"
  fi
}

# How the push ended, from the result it wrote to last.json.
_paxel_status_wait_result() {
  local store result
  _paxel_status_read_last_push
  if [ "$_PS_LAST_PUSH" = null ]; then
    printf 'The push stopped without writing a result. Its log is in %s/logs.\n' "$PAXEL_HOME_DIR"
    return 0
  fi
  store=$(printf '%s\n' "$_PS_LAST_PUSH" | jq -r '.store // empty')
  [ -n "$store" ] || store=$(_paxel_setup_saved_store)
  result=$(printf '%s\n' "$_PS_LAST_PUSH" | jq -r 'if .error_class then "error" else .result // "" end')
  if [ "$result" = off ]; then
    printf 'Capture is off on this machine, so nothing was pushed. Run %s/bin/paxel setup to turn it back on.\n' "$PAXEL_HOME_DIR"
  elif [ "$result" = error ]; then
    _paxel_status_push_error "$(paxel_config_get store_branch)" "${store:-the store}"
  else
    printf '%s\n' "$_PS_LAST_PUSH" | jq -r --arg store "${store:-your transcript store}" \
      "$_PX_JQ_SESSIONS"' "Push done: \(.result // "unknown"), \(.sessions_written // 0 | sessions) written to \($store)."'
  fi
}

# The history floor setup --since saved, and the sessions before it that
# push leaves on this machine (counted as push counts them).
_paxel_status_collect_history() {
  local floor tmp counts
  _PS_HISTORY_SINCE=""
  _PS_OUTSIDE_SESSIONS=0
  _PS_OUTSIDE_BYTES=0
  floor=$(paxel_config_get history_since)
  [ -n "$floor" ] || return 0
  if ! paxel_is_uint "$floor" || [ "${#floor}" -gt 12 ]; then
    _PS_OUTSIDE_SESSIONS=null
    _PS_OUTSIDE_BYTES=null
    _paxel_status_step "history_since in $PAXEL_CONFIG_FILE is not a time, so push does not run. Run $_PS_BIN setup --since 7d (or all, or none) to set it again."
    return 0
  fi
  _PS_HISTORY_SINCE=$(paxel_epoch_iso "$floor")
  counts=""
  if tmp=$(mktemp -d "${TMPDIR:-/tmp}/paxel-status.XXXXXX"); then
    if _paxel_push_scan "$tmp/scanned"; then
      counts=$(_paxel_history_split "$floor" "$tmp/scanned" "$PAXEL_HOME_DIR/push/state.tsv" "$tmp/kept") || counts=""
    fi
    rm -rf "$tmp"
  fi
  _PS_OUTSIDE_SESSIONS=${counts%% *}
  _PS_OUTSIDE_BYTES=${counts#* }
  if ! paxel_is_uint "$_PS_OUTSIDE_SESSIONS" || ! paxel_is_uint "$_PS_OUTSIDE_BYTES"; then
    _PS_OUTSIDE_SESSIONS=null
    _PS_OUTSIDE_BYTES=null
  elif [ "$_PS_OUTSIDE_SESSIONS" -gt 0 ]; then
    _paxel_status_note "To push the sessions last active before $_PS_HISTORY_SINCE too, run: $_PS_BIN setup --since all"
  fi
}

# Sessions push holds back after a failed scrub (scrub_failed.tsv: session
# bytes mtime digest epoch reason), as JSON. Local state, still type-checked.
_paxel_status_scrub_failed() {
  _PS_SCRUB_FAILED='[]'
  [ -f "$PAXEL_HOME_DIR/push/scrub_failed.tsv" ] || return 0
  _PS_SCRUB_FAILED=$(jq -R -s -c '
    split("\n") | map(split("\t") | select(length == 6 and (.[0] | test("^(claude|codex)/[A-Za-z0-9._-]+$")))
      | {session: .[0], reason: (.[5] | if test("^[a-z_]+$") then . else null end),
         failed_at: (.[4] | if test("^[0-9]{1,12}$") then tonumber | todate else null end)})
  ' "$PAXEL_HOME_DIR/push/scrub_failed.tsv" 2>/dev/null) || _PS_SCRUB_FAILED='[]'
  case "$_PS_SCRUB_FAILED" in '['*']') ;; *) _PS_SCRUB_FAILED='[]' ;; esac
}

_paxel_status_json() {
  jq -n \
    --arg box_id "$(paxel_box_id)" --arg user "$_PS_USER" --arg home "$HOME" \
    --arg version "${PAXEL_SCRIPT_VERSION:-}" --arg setup_at "$_PS_SETUP_AT" --arg off_at "$_PS_OFF_AT" \
    --argjson cache_age "$_PS_CACHE_AGE" --argjson launcher "$_PS_LAUNCHER" --arg server "$_PS_SERVER" \
    --argjson configured "$_PS_CONFIGURED" --arg display "$_PS_DISPLAY" --arg branch "$_PS_BRANCH" \
    --arg transport "$_PS_TRANSPORT" --arg cli "$_PS_CLI" --arg login "$_PS_LOGIN" --arg auth "$_PS_AUTH" \
    --argjson readable "$_PS_READABLE" --argjson writable "$_PS_WRITABLE" --argjson marker "$_PS_MARKER" \
    --arg visibility "$_PS_VISIBILITY" \
    --arg missing_since "$_PS_MISSING_SINCE" --arg declined_at "$_PS_DECLINED_AT" \
    --arg retry_at "$_PS_RETRY_AT" --arg next_retry "$_PS_NEXT_RETRY" \
    --argjson claude_reg "$_PS_CLAUDE_REG" --arg claude_via "$_PS_CLAUDE_VIA" \
    --arg claude_last "$_PS_CLAUDE_LAST" --argjson claude_since "$_PS_CLAUDE_SINCE" \
    --argjson codex_reg "$_PS_CODEX_REG" --arg codex_via "$_PS_CODEX_VIA" --argjson codex_trust "$_PS_CODEX_TRUST" \
    --arg codex_chained "$_PS_CODEX_CHAINED" \
    --arg codex_last "$_PS_CODEX_LAST" --argjson codex_since "$_PS_CODEX_SINCE" \
    --argjson last_push "$_PS_LAST_PUSH" --argjson pending "$_PS_PENDING" --argjson worker "$_PS_WORKER" \
    --arg push_state "$_PS_STATE" --argjson starts_in "$_PS_STARTS_IN" --arg running_since "$_PS_RUNNING_SINCE" \
    --argjson scrub_failed "$_PS_SCRUB_FAILED" --arg history_since "$_PS_HISTORY_SINCE" \
    --argjson outside_sessions "$_PS_OUTSIDE_SESSIONS" --argjson outside_bytes "$_PS_OUTSIDE_BYTES" \
    --arg bash_v "${BASH_VERSION:-}" --arg git_v "$_PS_GIT_V" --arg jq_v "$_PS_JQ_V" --arg curl_v "$_PS_CURL_V" \
    --arg gh_v "$_PS_GH_V" --arg glab_v "$_PS_GLAB_V" \
    --arg steps "$_PS_STEPS" --arg notes "$_PS_NOTES" \
    "$_PX_JQ_STATUS_BUILD"
}

# Read access is a blobless depth-1 fetch of the branch into a scratch repo;
# write access is a dry-run push of that same tip back, which the host only
# accepts from a login that may push.
_paxel_status_probe_store() {
  local branch="$1" url tmp PAXEL_STORE_GIT_TIMEOUT="${PAXEL_STATUS_GIT_TIMEOUT:-30}"
  _PS_READABLE=false
  url=$(paxel_store_url 2>/dev/null) || return 0
  [ -n "$url" ] || return 0
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/paxel-status.XXXXXX") || return 0
  if paxel_git -c init.templateDir= init -q --bare "$tmp/probe.git" >/dev/null 2>&1 &&
     paxel_store_git -C "$tmp/probe.git" fetch -q --depth 1 --filter=blob:none "$url" \
       "+refs/heads/$branch:refs/heads/probe" >/dev/null 2>&1; then
    _PS_READABLE=true
    # The tree entry, not the blob: the blobless probe lacks it, and reading
    # it would start a plain git fetch with none of the store credentials.
    if [ "$(git -C "$tmp/probe.git" ls-tree refs/heads/probe -- paxel-store.json 2>/dev/null | cut -d' ' -f1-2)" = "100644 blob" ]; then
      _PS_MARKER=true
    else
      _PS_MARKER=false
    fi
    if paxel_store_git -C "$tmp/probe.git" push -q --dry-run "$url" "refs/heads/probe:refs/heads/$branch" >/dev/null 2>&1; then
      _PS_WRITABLE=true
    else
      _PS_WRITABLE=false
    fi
  fi
  rm -rf "$tmp"
}

# Registered means all three events run the launcher at its current path.
_paxel_claude_hooks_registered() {
  local file="$HOME/.claude/settings.json"
  [ -f "$file" ] || return 1
  jq -e --arg cmd "$(_paxel_hook_command claude)" '
    . as $root
    | all(("Stop", "StopFailure", "SessionEnd"); . as $e
        | $root | any((.hooks[$e]? // [])[]?; any((.hooks? // [])[]?; .command? == $cmd)))
  ' "$file" >/dev/null 2>&1
}

_paxel_codex_hook_registered() {
  [ -f "$HOME/.codex/hooks.json" ] || return 1
  jq -e --arg cmd "$(_paxel_hook_command codex)" "$_PX_JQ_CODEX_HAS_CMD" "$HOME/.codex/hooks.json" >/dev/null 2>&1
}

# Both sides are UTC ISO-8601 strings, so a string comparison orders them.
_paxel_status_since_setup() {
  if [ -n "$1" ] && ! [[ "$1" < "$_PS_SETUP_AT" ]]; then echo true; else echo false; fi
}

_paxel_status_trigger() {
  local m
  m=$(_paxel_status_mtime "$PAXEL_HOME_DIR/push/last_trigger_$1") || return 0
  paxel_epoch_iso "$m"
}

# The pending marker counts only when it is newer than the last push.
_paxel_status_pending() {
  local p l
  p=$(_paxel_status_mtime "$PAXEL_HOME_DIR/push/pending") || return 1
  l=$(_paxel_status_mtime "$PAXEL_HOME_DIR/push/last.json") || return 0
  [ "$p" -ge "$l" ]
}

_paxel_status_cli_notes() {
  local cli
  for cli in $(_paxel_logged_out_clis); do
    _paxel_status_note "$cli is installed but not logged in, so $(_paxel_cli_host_name "$cli") is not searched for a store."
  done
}

# _paxel_mtime, with status 1 for a missing file.
_paxel_status_mtime() {
  local m
  m=$(_paxel_mtime "$1") && [ "$m" != 0 ] || return 1
  printf '%s\n' "$m"
}

# --- Paxel transcript store: laptop pull (upload) ---
#
# The upload restages store sessions into ~/.paxel/cache/store_sessions-$$ in
# the formats the local collectors write (native file names, the _metadata.json
# sidecar, the --all _git file set) and mounts that dir at /store_sessions.
# Everything read from the store is untrusted: any machine that can push to it
# can write anything into it.
#
# bash 3.2 (macOS /bin/bash) runs the upload's ERR trap inside $(...) even when
# the caller guards the assignment with `||`, so every substitution that can
# fail ends with its own `|| exit $?`.

PAXEL_STORE_SESSIONS=0
PAXEL_STORE_JSONL=0
PAXEL_STORE_STAGE_DIR=""
PAXEL_STORE_SOURCES=""
PAXEL_STORE_BOXES=""
_PAXEL_PULL_LOCK=""
PAXEL_STORE_DISPLAY=""
PAXEL_STORE_LINK=""
PAXEL_STORE_OLDEST_EPOCH=""
PAXEL_STORE_CAPABILITY="store_sessions_v1"
PAXEL_PULL_GIT_FILES="commit_count.txt numstat.txt activity.tsv author_commits.jsonl author_numstat.txt"
_PAXEL_US=$'\037'
# At most 64 characters (Linux HOST_NAME_MAX); anything else shows as the box id.
PAXEL_BOX_NAME_RE='\A[A-Za-z0-9](?:[A-Za-z0-9.-]{0,62}[A-Za-z0-9])?\z'
PAXEL_SOURCES_TOOLS="Claude Code|Codex|Cursor|opencode|Gemini CLI|VS Code Copilot|Antigravity"

# Input is "<path>\t<line>" from _paxel_pull_tag_lines. One verdict line per
# manifest, fields joined by \x1f (not IFS whitespace, so empty fields survive
# `read`). Raw-line input regrouped per file keeps one malformed manifest from
# aborting jq for the rest.
_PAXEL_PULL_MANIFEST_JQ='
def str($re): if type == "string" and test($re) then . else null end;
def epoch: if type == "number" and . == floor and . >= 0 and . < 10000000000 then . else null end;
def fields:
  [ (.tool | str("\\A(claude|codex)\\z")),
    (.session_id | str("\\A[A-Za-z0-9_][A-Za-z0-9._-]{0,127}\\z")),
    (.source_mtime | epoch | if . == null then null else tostring end),
    ((.git_remote // "") | str("\\A(?:[A-Za-z0-9][A-Za-z0-9._~:/@+-]{0,299})?\\z")),
    ((.cwd // "") | str("\\A[^\\x00-\\x1f\\x7f]{0,4096}\\z")),
    ((.box_id // "") | if type == "string" and test("\\Ab-[0-9a-f]{12}\\z") then . else "" end),
    ((.box_name // "") | if type == "string" and test($box_name_re) then . else "" end) ];
def verdict:
  if type != "object" or (.schema_version | type) != "number"
     or .schema_version != (.schema_version | floor) or .schema_version < 1 then ["bad"]
  elif .schema_version > $schema then ["newer"]
  else fields as $f
    | if any($f[]; . == null) then ["bad"]
      else ["ok"] + $f + [(.source_mtime | gmtime | strftime("%Y%m%d%H%M.%S"))] end
  end;
[inputs | split("\t") | { f: .[0], l: (.[1:] | join("\t")) }] | group_by(.f)[]
| (.[0].f | split("/")) as $p
| ((map(.l) | join("\n")) | try fromjson catch null) as $m
| [$p[1], $p[2]] + ($m | verdict) + ["end"]
| join("\u001f")
'

_PAXEL_PULL_GIT_META_JQ='
def str($re): if type == "string" and test($re) then . else null end;
def verdict:
  if type != "object" or .schema_version != 1 then ["skip"]
  else [ (.git_remote | str("\\A[A-Za-z0-9][A-Za-z0-9._~:/@+-]{0,299}\\z")),
         (.captured_at | str("\\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\\z")) ] as $f
    | if any($f[]; . == null) or (.shallow | type) != "boolean" then ["skip"]
      elif .shallow then ["shallow"]
      else ["full"] + $f end
  end;
[inputs | split("\t") | { f: .[0], l: (.[1:] | join("\t")) }] | group_by(.f)[]
| (.[0].f | split("/")) as $p
| ((map(.l) | join("\n")) | try fromjson catch null) as $m
| [$p[1], ($p[3] | rtrimstr(".json"))] + ($m | verdict) + ["end"]
| join("\u001f")
'

# --all takes every store session. A single-project run takes the sessions of
# the current repo, and with --project only when that repo is the named one,
# the same rule run_docker_mode applies to the local auto-detect. --all with
# --project scopes the store by that name here: the client applies its name
# filter before it merges the store mount, so it never filters the store.
paxel_pull_stage_for_run() {
  local filter="" project=""
  if [ "${ALL_PROJECTS:-0}" -ne 1 ]; then
    filter=$(get_git_remote "$PWD" || exit $?) || filter=""
    if [ -z "$filter" ] || ! _paxel_pull_matches_project "$filter"; then
      paxel_pull_discard
      return 0
    fi
  elif [ -n "${PROJECT_NAME:-}" ] && [ "$PROJECT_NAME" != all ]; then
    project="$PROJECT_NAME"
  fi
  paxel_pull_stage "${HOME}/.paxel/cache/store_sessions-$$" "$filter" "$project"
}

_paxel_pull_matches_project() {
  [ -n "${PROJECT_NAME:-}" ] || return 0
  local want have
  want=$(printf '%s' "$PROJECT_NAME" | tr '[:upper:]' '[:lower:]' | tr '_' '-' || exit $?) || return 1
  have=$(printf '%s' "${1##*/}" | tr '[:upper:]' '[:lower:]' | tr '_' '-' || exit $?) || return 1
  case "$have" in *"$want"*) return 0 ;; esac
  return 1
}

# paxel_pull_stage OUT_DIR [REMOTE_FILTER] [PROJECT_NAME]
paxel_pull_stage() {
  local out_dir="$1" filter="${2:-}" project="${3:-}" work _pp_store=0 _pp_said=0 _pp_step="reading it"
  paxel_pull_discard
  rm -rf "$out_dir" "$out_dir.sources"
  if [ -n "${PAXEL_STORE+x}" ] && [ -z "$PAXEL_STORE" ]; then
    return 0
  fi
  work=$(mktemp -d 2>/dev/null || exit $?) || return 0
  # Called as an `if` condition so errexit and the upload's ERR trap stay off
  # inside: a store problem ends in one notice and a local-only run.
  if _paxel_pull_run "$out_dir" "$filter" "$work" "$project"; then
    PAXEL_STORE_STAGE_DIR="$out_dir"
    PAXEL_STORE_SOURCES="$out_dir.sources"
  else
    if [ "$_pp_store" -eq 1 ] && [ "$_pp_said" -eq 0 ]; then
      paxel_say "Transcript store ${PAXEL_STORE_LINK}: a step on this machine failed while ${_pp_step}. This run uses this machine's sessions only. If this repeats, delete ~/.paxel/store-cache; the next upload downloads the store again."
    fi
    paxel_pull_discard
    rm -rf "$out_dir" "$out_dir.sources"
  fi
  _paxel_pull_unlock
  rm -rf "$work"
  return 0
}

paxel_pull_discard() {
  if [ -n "${PAXEL_STORE_STAGE_DIR:-}" ]; then
    rm -rf "$PAXEL_STORE_STAGE_DIR"
  fi
  if [ -n "${PAXEL_STORE_SOURCES:-}" ]; then
    rm -f "$PAXEL_STORE_SOURCES"
  fi
  PAXEL_STORE_STAGE_DIR=""
  PAXEL_STORE_SOURCES=""
  PAXEL_STORE_BOXES=""
  PAXEL_STORE_SESSIONS=0
  PAXEL_STORE_JSONL=0
  PAXEL_STORE_OLDEST_EPOCH=""
}

# Every notice on the way to a local-only run goes through here, so
# paxel_pull_stage knows the failure was already explained.
_paxel_pull_say() {
  _pp_said=1
  paxel_say "$@"
}

_paxel_pull_run() {
  local out_dir="$1" filter="$2" work="$3" _pp_project="${4:-}"
  # A store resolved for this run alone gets a run-local config, so the store
  # helpers (which read the config) work while ~/.paxel/config stays as
  # setup left it.
  local PAXEL_CONFIG_FILE="$PAXEL_CONFIG_FILE"
  local _pp_work="$work" _pp_view="$work/view" _pp_cache="" _pp_branch="" _pp_marker_branch="" _pp_fresh=0
  local _pp_found=0 _pp_here=0 _pp_older=0 _pp_added=0 _pp_newer=0 _pp_rejected=0 _pp_valid=0 _pp_pending=0 _pp_other=0
  local _pp_jsonl=0 _pp_oldest="" _pp_git_repos=0 _pp_bucket="" _pp_bad_names=0
  local _pp_bkeys=() _pp_bnames=()

  PAXEL_STORE_DISPLAY=""
  PAXEL_STORE_LINK=""
  _paxel_pull_tools_ok || return 1
  _paxel_pull_pick_store "$work/config" || return 1
  _pp_store=1
  _paxel_pull_read_config || return 1
  _pp_step="locking its local copy"
  _paxel_pull_lock "$_pp_cache" || return 1
  _pp_step="fetching it"
  _paxel_pull_fetch "$_pp_cache" || return 1
  _pp_step="reading its file list"
  _paxel_pull_read_index "$_pp_cache" || return 1
  _pp_step="reading its session manifests"
  _paxel_pull_select "$filter" || return 1
  # A single-project run reads git data from the laptop clone it runs in, and
  # --no-repo ships no git data, so box snapshots would be downloaded for
  # nothing.
  if [ -z "$filter" ] && [ "${NO_REPO:-0}" != 1 ]; then
    _paxel_pull_pick_git
  else
    : > "$_pp_work/git"
  fi
  _pp_step="downloading the selected sessions"
  _paxel_pull_download_selected "$_pp_cache" || return 1
  if ! mkdir -p "$out_dir" 2>/dev/null; then
    _paxel_pull_say_mkdir "$out_dir"
    return 1
  fi
  _pp_step="copying the sessions into $out_dir"
  _paxel_pull_restage_sessions "$_pp_cache" "$out_dir" || return 1
  _paxel_pull_write_sources "$out_dir.sources" || rm -f "$out_dir.sources"
  _paxel_pull_restage_git "$out_dir"
  _paxel_pull_report
  _paxel_pull_maintain "$_pp_cache"
}

# Git first, so no jq is downloaded for a store this git cannot read. An old
# git stops the pull before the convention lookup, so only a store named in
# PAXEL_STORE or in ~/.paxel/config is worth a notice.
_paxel_pull_tools_ok() {
  local v
  v=$(git --version 2>/dev/null || true)
  if ! _paxel_pull_version_at_least "${v#git version }" 2 29; then
    if _paxel_pull_store_named; then
      _paxel_pull_say "Transcript store: skipped. Reading it needs git 2.29 or later (found: ${v:-none}). This run uses this machine's sessions only."
    fi
    return 1
  fi
  _paxel_pull_jq_ok
}

# When this machine's jq is missing, older than 1.6 or built without regex
# support, the pull takes setup's jq (_paxel_pull_own_jq), but only when a
# store could be read: an upload with no store in sight downloads nothing.
_paxel_pull_jq_ok() {
  local v problem link
  v=$(jq --version 2>/dev/null || true)
  if ! command -v jq >/dev/null 2>&1; then
    problem="jq is missing and could not be downloaded"
  elif ! _paxel_pull_version_at_least "${v#jq-}" 1 6; then
    problem="jq is too old (found: ${v:-no version}) and a newer one could not be downloaded"
  elif ! jq -n '"a" | test("a")' >/dev/null 2>&1; then
    problem="${v} has no regex support and a jq with it could not be downloaded"
  else
    return 0
  fi
  _paxel_pull_store_possible || return 1
  _paxel_pull_own_jq && return 0
  link=$(_paxel_pull_named_link || exit $?) || link=""
  _paxel_pull_say "Transcript store${link:+ $link}: skipped, ${problem}${_PX_JQ_WHY:+ (${_PX_JQ_WHY})}. Install jq 1.6 or later, then run the upload again."
  return 1
}

# Puts setup's jq first on PATH for the rest of the upload, the store part's
# helpers included: the copy an earlier setup installed in ~/.paxel/bin (or
# found in a folder it saved in tool_path), else the pinned build, downloaded
# and checked as setup does. Status 1 with the reason in _PX_JQ_WHY.
_paxel_pull_own_jq() {
  local out rc=0
  # Setup's jq helpers expect their own $(...) to fail quietly; bash 3.2 runs
  # the upload's ERR trap inside them.
  out=$(trap - ERR; _paxel_pull_own_jq_dir || exit $?) || rc=$?
  if [ "$rc" -ne 0 ]; then
    _PX_JQ_WHY="$out"
    return 1
  fi
  PATH="$out:$PATH"
  export PATH
}

# Prints the folder of setup's jq, or the reason there is none (status 1).
_paxel_pull_own_jq_dir() {
  local jq_path rc=0
  paxel_use_own_jq
  if ! paxel_jq_usable jq; then
    if ! mkdir -p "$PAXEL_HOME_DIR/bin" 2>/dev/null; then
      printf 'could not create %s/bin\n' "$PAXEL_HOME_DIR"
      return 1
    fi
    _paxel_setup_jq_install || rc=$?
    [ -z "$_PX_SETUP_JQ_DIR" ] || rm -rf "$_PX_SETUP_JQ_DIR"
    if [ "$rc" -ne 0 ]; then
      printf '%s\n' "$_PX_JQ_WHY"
      return 1
    fi
  fi
  jq_path=$(command -v jq || exit $?) || return 1
  printf '%s\n' "${jq_path%/*}"
}

_paxel_pull_store_named() {
  [ -n "${PAXEL_STORE:-}" ] || [ -n "$(paxel_config_get store_host)" ]
}

# A named store, or a gh or glab login (checked offline) that the convention
# lookup would search.
_paxel_pull_store_possible() {
  _paxel_pull_store_named && return 0
  if command -v gh >/dev/null 2>&1 && _paxel_store_cli_has_token gh github.com; then
    return 0
  fi
  command -v glab >/dev/null 2>&1 && _paxel_store_cli_has_token glab gitlab.com
}

# The https link of the store PAXEL_STORE or ~/.paxel/config names, read
# without jq. None for the convention: only the lookup knows the owner.
_paxel_pull_named_link() {
  local spec
  if [ -n "${PAXEL_STORE:-}" ]; then
    spec=$(paxel_store_parse_spec "$PAXEL_STORE" || exit $?) || return 0
    printf 'https://%s\n' "${spec//${_PAXEL_STORE_TAB}//}"
  elif spec=$(paxel_store_display || exit $?); then
    printf 'https://%s\n' "$spec"
  fi
}

# _paxel_pull_version_at_least VERSION MAJOR MINOR, for "1.7.1", "2.39.3 (Apple Git-145)".
_paxel_pull_version_at_least() {
  local major rest minor
  major=${1%%.*}
  rest=${1#*.}
  minor=${rest%%[!0-9]*}
  paxel_is_uint "$major" && paxel_is_uint "$minor" || return 1
  [ "$major" -gt "$2" ] && return 0
  [ "$major" -eq "$2" ] && [ "$minor" -ge "$3" ]
}

# PAXEL_STORE, then the store setup or --create-store saved in ~/.paxel/config,
# then the convention.
# With no CLI logged in, or PAXEL_STORE="", nothing is said: most uploads have
# no store at all. A host that could not be checked is already named by
# paxel_store_resolve's own line.
_paxel_pull_pick_store() {
  local run_config="$1" line="" rc=0
  if [ -z "${PAXEL_STORE+x}" ] && [ -n "$(paxel_config_get store_host)" ]; then
    return 0
  fi
  # Not in $(...), so PAXEL_STORE_LOGGED_OUT_CLIS reaches this shell.
  PAXEL_STORE_LOGGED_OUT_CLIS=""
  paxel_store_resolve > "$_pp_work/resolved" || rc=$?
  [ "$rc" -eq 0 ] || return 1
  line=$(cat "$_pp_work/resolved" || exit $?) || return 1
  local host owner name cli login state transport
  IFS=$'\t' read -r host owner name cli login state <<EOF
$line
EOF
  [ -n "${PAXEL_STORE+x}" ] || _paxel_pull_note_logged_out "$cli"
  if [ "$state" != "existing" ]; then
    if [ -n "${PAXEL_STORE:-}" ]; then
      _paxel_pull_say "Transcript store https://${host}/${owner}/${name}: not found through ${cli}. Check the name in PAXEL_STORE and that ${cli} is logged in to an account that can read it. This run uses this machine's sessions only."
    fi
    return 1
  fi
  transport=$(paxel_store_transport "$cli" "$host" || exit $?) || transport=https
  PAXEL_CONFIG_FILE="$run_config"
  paxel_config_set store_host "$host" \
    && paxel_config_set store_owner "$owner" \
    && paxel_config_set store_name "$name" \
    && paxel_config_set store_cli "$cli" \
    && paxel_config_set store_login "$login" \
    && paxel_config_set store_transport "$transport"
}

# A box and this machine can have different CLIs logged in, so a store on the
# host this machine's logged-out CLI serves would be missed without a word.
# Only said when another CLI is logged in: with none, there is no sign the
# user keeps a store at all. The list comes from the lookup that just ran.
_paxel_pull_note_logged_out() {
  local cli host
  for cli in ${PAXEL_STORE_LOGGED_OUT_CLIS:-}; do
    [ "$cli" != "$1" ] || continue
    host="GitHub"
    [ "$cli" = gh ] || host="GitLab"
    paxel_say "Transcript store: ${cli} is installed but not logged in, so ${host} was not searched for a store. Run '${cli} auth login' to include one there."
  done
}

# Sets PAXEL_STORE_DISPLAY (for logs), PAXEL_STORE_LINK (for the terminal) and
# _pp_cache. Only a hand-edited or partial ~/.paxel/config fails here: a
# resolved store's run-local config is complete.
_paxel_pull_read_config() {
  local host owner name
  host=$(paxel_config_get store_host)
  owner=$(paxel_config_get store_owner)
  name=$(paxel_config_get store_name)
  if paxel_valid_name "$host" && paxel_valid_name "$owner" && paxel_valid_name "$name" \
    && PAXEL_STORE_DISPLAY=$(paxel_store_display || exit $?); then
    PAXEL_STORE_LINK="https://${PAXEL_STORE_DISPLAY}"
    _pp_cache="${PAXEL_HOME_DIR}/store-cache/${host}/${owner}/${name}"
    return 0
  fi
  local lines="Transcript store: the store_host, store_owner and store_name lines in ~/.paxel/config do not name a repo."
  if _paxel_pull_saved_by_create_store; then
    _paxel_pull_say "$lines A --create-store run saved them (store_saved_at is set) and may have stopped partway. This run uses this machine's sessions only. To finish the save, run this with the store you chose in place of host/owner/name: $(_paxel_pull_create_store_cmd host/owner/name || exit $?). Run it without PAXEL_STORE=host/owner/name to remove the saved lines instead; uploads here then use <login>/paxel-transcripts through gh or glab, which that command creates if it is missing."
  else
    _paxel_pull_say "$lines This run uses this machine's sessions only; run ~/.paxel/bin/paxel setup to rewrite them."
  fi
  return 1
}

# A store --create-store saved is fixed by running it again: setup would also
# start pushing this machine's sessions to the store.
_paxel_pull_saved_by_create_store() {
  [ -n "$(paxel_config_get store_saved_at)" ]
}

_paxel_pull_create_store_cmd() {
  printf 'curl -fsSL %s/paxel.sh | PAXEL_STORE=%s bash -s -- --create-store --yes' "$(_paxel_setup_server || exit $?)" "$1"
}

_paxel_pull_say_mkdir() {
  _paxel_pull_say "Transcript store ${PAXEL_STORE_LINK}: could not create $1. This run uses this machine's sessions only."
}

# One upload at a time reads a store cache: a second one waits briefly, then
# runs on this machine's sessions. A lock left by a killed run (its process
# is gone) is taken over; one from another host (a home on a network share)
# only once it is three hours old.
_paxel_pull_lock() {
  local lock="$1.lock" waited=0 wait host
  wait="${PAXEL_PULL_LOCK_WAIT:-30}"
  paxel_is_uint "$wait" || wait=30
  host=$(hostname 2>/dev/null || uname -n || exit $?) || host=unknown
  if ! mkdir -p "${1%/*}" 2>/dev/null; then
    _paxel_pull_say_mkdir "${1%/*}"
    return 1
  fi
  while ! mkdir "$lock" 2>/dev/null; do
    if _paxel_pull_lock_stale "$lock" "$host" && _paxel_pull_lock_break "$lock" "$host"; then
      continue
    fi
    if [ "$waited" -ge "$wait" ]; then
      _paxel_pull_say "Transcript store ${PAXEL_STORE_LINK}: another upload on this machine is reading it right now. This run uses this machine's sessions only."
      return 1
    fi
    sleep 1
    waited=$((waited + 1))
  done
  printf '%s\t%s\n' "$host" "$$" > "$lock/owner" 2>/dev/null || true
  _PAXEL_PULL_LOCK="$lock"
}

# True when LOCK belongs to a run that is gone: a dead pid on this host, no
# owner after a minute (the run died before writing it), or another host's
# lock after three hours.
_paxel_pull_lock_stale() {
  local lock="$1" host="$2" owner_host="" pid=""
  if [ -f "$lock/owner" ]; then
    IFS=$'\t' read -r owner_host pid < "$lock/owner" || true
  fi
  if [ "$owner_host" = "$host" ] && paxel_is_uint "$pid" && ! kill -0 "$pid" 2>/dev/null; then
    return 0
  fi
  if [ -z "$owner_host" ]; then
    [ -n "$(find "$lock" -maxdepth 0 -mmin +1 2>/dev/null || true)" ]
    return
  fi
  [ "$owner_host" != "$host" ] && [ -n "$(find "$lock" -maxdepth 0 -mmin +180 2>/dev/null || true)" ]
}

# Removes a stale LOCK under a takeover mutex, after checking again that it is
# stale: two uploads that both judged it dead must not remove the lock the
# first of them has just taken. Status 1 when another run holds the mutex or
# the lock is live again.
_paxel_pull_lock_break() {
  local lock="$1" host="$2" mutex="$1.takeover" rc=1
  if [ -n "$(find "$mutex" -maxdepth 0 -mmin +1 2>/dev/null || true)" ]; then
    rmdir "$mutex" 2>/dev/null || true
  fi
  mkdir "$mutex" 2>/dev/null || return 1
  if _paxel_pull_lock_stale "$lock" "$host"; then
    rm -rf "$lock"
    rc=0
  fi
  rmdir "$mutex" 2>/dev/null || true
  return "$rc"
}

_paxel_pull_unlock() {
  [ -n "${_PAXEL_PULL_LOCK:-}" ] || return 0
  rm -rf "$_PAXEL_PULL_LOCK"
  _PAXEL_PULL_LOCK=""
}

# Blobless and depth 1: later runs download only new commits and trees, and a
# file's contents only when a run selects it. Nothing is ever checked out:
# files are read from git objects into the run's own folders, so a store
# entry is never written as a link or outside its folder. Git's stderr is
# dropped because its errors name the remote URL. A cache git cannot update
# is replaced by a fresh clone.
_paxel_pull_fetch() {
  local cache="$1" url want
  if ! url=$(paxel_store_url || exit $?); then
    if _paxel_pull_saved_by_create_store; then
      _paxel_pull_say "Transcript store ${PAXEL_STORE_LINK}: ~/.paxel/config has no valid store_transport (ssh or https). A --create-store run saved this store (store_saved_at is set) and may have stopped partway. This run uses this machine's sessions only. To finish the save, run: $(_paxel_pull_create_store_cmd "$PAXEL_STORE_DISPLAY" || exit $?)"
    else
      _paxel_pull_say "Transcript store ${PAXEL_STORE_LINK}: ~/.paxel/config has no valid store_transport (ssh or https). This run uses this machine's sessions only; run ~/.paxel/bin/paxel setup to rewrite it."
    fi
    return 1
  fi
  want=$(paxel_config_get store_branch)
  _paxel_store_valid_branch "$want" || want=""
  if [ -z "$want" ] && [ -d "$cache/.git" ]; then
    want=$(paxel_git -C "$cache" config --get paxel.branch 2>/dev/null || true)
    _paxel_store_valid_branch "$want" || want=""
  fi
  # _paxel_pull_lock makes this run the cache's only user, so a git lock file
  # in it is left by a run that was killed (the timeout fallback's KILL, a
  # power loss), and git refuses every later fetch while it is there.
  if [ -d "$cache/.git" ]; then
    find "$cache/.git" -name '*.lock' -type f -exec rm -f {} + 2>/dev/null || true
  fi
  if [ -d "$cache/.git" ] && [ -n "$want" ] \
    && ! paxel_git -C "$cache" remote set-url origin "$url" 2>/dev/null; then
    rm -rf "$cache"
  fi
  if [ -d "$cache/.git" ] && [ -n "$want" ]; then
    if ! _paxel_pull_fetch_branch "$cache" "$want"; then
      _paxel_pull_say_unreachable
      return 1
    fi
    _pp_branch="$want"
  else
    _paxel_pull_clone "$cache" "$url" "$want" || return 1
  fi
}

_paxel_pull_clone() {
  local cache="$1" url="$2" want="$3" ref
  local args=(clone --quiet --no-checkout --no-tags --depth 1 --filter=blob:none)
  [ -z "$want" ] || args+=(--branch "$want")
  rm -rf "$cache"
  if ! mkdir -p "${cache%/*}" 2>/dev/null; then
    _paxel_pull_say_mkdir "${cache%/*}"
    return 1
  fi
  if ! paxel_store_git "${args[@]}" -- "$url" "$cache" >/dev/null 2>&1; then
    rm -rf "$cache"
    _paxel_pull_say_unreachable
    return 1
  fi
  _pp_fresh=1
  _pp_branch="$want"
  if [ -z "$_pp_branch" ]; then
    _pp_branch=$(paxel_git -C "$cache" symbolic-ref --short HEAD 2>/dev/null || true)
  fi
  if ! paxel_git -C "$cache" update-ref refs/paxel/tip HEAD 2>/dev/null; then
    rm -rf "$cache"
    _paxel_pull_say_not_store
    return 1
  fi
  # refs/paxel/tip is the ref later fetches move; the clone's branch refs are
  # dropped so they do not point at an old commit. The cache still keeps old
  # objects (see _paxel_pull_maintain).
  paxel_git -C "$cache" for-each-ref --format='%(refname)' refs/heads > "$_pp_work/clone_refs" 2>/dev/null || true
  while IFS= read -r ref; do
    paxel_git -C "$cache" update-ref -d "$ref" 2>/dev/null || true
  done < "$_pp_work/clone_refs"
}

_paxel_pull_fetch_branch() {
  paxel_store_git -C "$1" fetch --quiet --no-tags --depth 1 --filter=blob:none origin \
    "+refs/heads/$2:refs/paxel/tip" >/dev/null 2>&1
}

# Readers follow the branch recorded in paxel-store.json, not the host's
# default branch.
_paxel_pull_read_index() {
  local cache="$1"
  _paxel_pull_index_from_tip "$cache" || return 1
  if [ "$_pp_marker_branch" != "$_pp_branch" ]; then
    if ! _paxel_pull_fetch_branch "$cache" "$_pp_marker_branch"; then
      _paxel_pull_say_unreachable
      return 1
    fi
    _pp_branch="$_pp_marker_branch"
    _paxel_pull_index_from_tip "$cache" || return 1
  fi
  paxel_git -C "$cache" config paxel.branch "$_pp_branch" 2>/dev/null || true
}

_paxel_pull_index_from_tip() {
  local cache="$1"
  rm -rf "$_pp_view"
  mkdir -p "$_pp_view" || return 1
  if ! _paxel_pull_list_tree "$cache"; then
    _paxel_pull_say "Transcript store ${PAXEL_STORE_LINK}: could not read its file list. This run uses this machine's sessions only."
    return 1
  fi
  awk -F '\t' -v OFS='\t' '$1 == "marker" || $1 == "manifest" || $1 == "meta" { print $2, $3 }' \
    "$_pp_work/tree" > "$_pp_work/index_files" || return 1
  cut -f1 "$_pp_work/index_files" > "$_pp_work/index_oids" || return 1
  if ! _paxel_pull_prefetch "$cache" "$_pp_work/index_oids" 0; then
    _paxel_pull_say_unreachable
    return 1
  fi
  _paxel_pull_write_blobs "$cache" "$_pp_work/index_files" "$_pp_view" || return 1
  _paxel_pull_check_marker || return 1
}

# Lists the tip's tree (no file contents are downloaded for this) into
# $_pp_work/tree as "kind<TAB>oid<TAB>path", keeping only regular files in
# the store layout with safe names: the marker, manifests, Claude main files
# and subagents, Codex rollouts, snapshot metas and snapshot files. Every
# other entry (a symlink, a nested or extra file, a '..' name) is never read.
# Sets _pp_bad_names to the manifests skipped for an unsafe name or type.
_paxel_pull_list_tree() {
  local cache="$1" rec meta mode rest type oid path slashes kind a b c last
  _pp_bad_names=0
  paxel_git -C "$cache" ls-tree -r -z --full-tree refs/paxel/tip > "$_pp_work/tree.raw" 2>/dev/null || return 1
  while IFS= read -r -d '' rec; do
    meta=${rec%%$'\t'*}
    path=${rec#*$'\t'}
    mode=${meta%% *}
    rest=${meta#* }
    type=${rest%% *}
    oid=${rest#* }
    slashes=${path//[!\/]/}
    case "${#slashes}:$path" in
      0:paxel-store.json) kind=marker ;;
      3:sessions/*/*/manifest.json) kind=manifest ;;
      3:sessions/claude/*/*.jsonl) kind=main ;;
      4:sessions/claude/*/subagents/agent-*.jsonl) kind=sub ;;
      3:sessions/codex/*/rollout-*.jsonl) kind=rollout ;;
      3:git/*/meta/*.json) kind=meta ;;
      3:git/*/_git/*) kind=gitfile ;;
      *) continue ;;
    esac
    rest=${path#*/}
    a=${rest%%/*}
    rest=${rest#*/}
    b=${rest%%/*}
    rest=${rest#*/}
    c=${rest%%/*}
    last=${path##*/}
    case "$oid" in ''|*[!0-9a-f]*) continue ;; esac
    if [ "$type" != blob ] || { [ "$mode" != 100644 ] && [ "$mode" != 100755 ]; }; then
      [ "$kind" != manifest ] || _pp_bad_names=$((_pp_bad_names + 1))
      continue
    fi
    case "$kind" in
      marker) ;;
      manifest)
        if ! paxel_valid_name "$a" || ! paxel_valid_name "$b"; then
          _pp_bad_names=$((_pp_bad_names + 1))
          continue
        fi
        ;;
      main) paxel_valid_name "$b" && [ "$last" = "$b.jsonl" ] || continue ;;
      sub) paxel_valid_name "$b" && [ "$c" = subagents ] && paxel_valid_name "$last" || continue ;;
      rollout)
        paxel_valid_name "$b" && paxel_valid_name "$last" || continue
        case "$last" in *"-$b.jsonl") ;; *) continue ;; esac
        ;;
      meta) paxel_valid_name "$a" && [ "$b" = meta ] && paxel_valid_name "${last%.json}" || continue ;;
      gitfile) paxel_valid_name "$a" && [ "$b" = _git ] && paxel_valid_name "$last" || continue ;;
    esac
    printf '%s\t%s\t%s\n' "$kind" "$oid" "$path"
  done < "$_pp_work/tree.raw" > "$_pp_work/tree"
}

# The objects in $_pp_cache, one id per line, sorted.
_paxel_pull_present() {
  git -C "$1" cat-file --batch-all-objects --batch-check='%(objectname)' 2>/dev/null \
    | LC_ALL=C sort -u > "$_pp_work/present"
}

# _paxel_pull_prefetch CACHE OIDS_FILE BUDGET downloads the objects in
# OIDS_FILE the cache lacks, in file order, PAXEL_PULL_FETCH_BATCH (50) at a
# time, so an interrupted download keeps every batch that finished. With
# BUDGET 1 it stops once PAXEL_PULL_CHECKOUT_TIMEOUT (1800 s) has passed:
# status 3, the rest wait for the next run. Status 2: a batch failed.
_paxel_pull_prefetch() {
  local cache="$1" oids="$2" budget="$3" size limit start now f
  size="${PAXEL_PULL_FETCH_BATCH:-50}"
  paxel_is_uint "$size" && [ "$size" -gt 0 ] || size=50
  limit="${PAXEL_PULL_CHECKOUT_TIMEOUT:-1800}"
  paxel_is_uint "$limit" || limit=1800
  _paxel_pull_present "$cache" || return 1
  awk 'FILENAME == ARGV[1] { have[$1] = 1; next } !($1 in have) && !seen[$1]++' \
    "$_pp_work/present" "$oids" > "$_pp_work/missing" || return 1
  [ -s "$_pp_work/missing" ] || return 0
  rm -rf "$_pp_work/batches"
  mkdir -p "$_pp_work/batches" || return 1
  split -a 4 -l "$size" "$_pp_work/missing" "$_pp_work/batches/b." || return 1
  start=$(date +%s || exit $?) || return 1
  for f in "$_pp_work/batches"/b.*; do
    [ -f "$f" ] || continue
    if [ "$budget" = 1 ]; then
      now=$(date +%s || exit $?) || return 1
      [ $((now - start)) -lt "$limit" ] || return 3
    fi
    # The noop negotiation is how git itself fetches missing objects by id
    # in a partial clone (git 2.29 and later).
    # shellcheck disable=SC2046
    paxel_store_git -C "$cache" -c fetch.negotiationAlgorithm=noop fetch --quiet --no-tags \
      --no-write-fetch-head --recurse-submodules=no --filter=blob:none origin \
      $(cat "$f" || exit $?) >/dev/null 2>&1 || return 2
  done
}

# _paxel_pull_write_blobs CACHE LIST DIR writes the blob of each
# "oid<TAB>path" line of LIST to DIR/path, with one git process for all of
# them. git cat-file --batch prints "<oid> blob <size>", the content and a
# newline for each object. Paths come from _paxel_pull_list_tree, so they are
# safe. Only objects already in the cache are asked for.
_paxel_pull_write_blobs() {
  local cache="$1" list="$2" dir="$3"
  [ -s "$list" ] || return 0
  awk -F '\t' '{ p = $2; if (sub(/\/[^\/]*$/, "", p)) print p }' "$list" | LC_ALL=C sort -u > "$_pp_work/blob_dirs" || return 1
  if [ -s "$_pp_work/blob_dirs" ]; then
    (cd "$dir" && xargs mkdir -p < "$_pp_work/blob_dirs") || return 1
  fi
  cut -f1 "$list" | LC_ALL=C sort -u \
    | GIT_NO_LAZY_FETCH=1 git -C "$cache" cat-file --batch 2>/dev/null \
    | LC_ALL=C awk -v dir="$dir" '
        FILENAME == ARGV[1] { split($0, f, "\t"); paths[f[1]] = paths[f[1]] "\n" f[2]; next }
        state == 0 {
          if (NF != 3 || $2 != "blob" || !($1 in paths)) exit 1
          size = $3 + 0; got = 0; first = 1
          nt = split(paths[$1], t, "\n")
          state = (size == 0) ? 2 : 1
          next
        }
        # Each line goes straight to the files: joining a large blob in one
        # string first takes time quadratic in its line count.
        state == 1 {
          for (i = 2; i <= nt; i++) printf "%s%s", (first ? "" : "\n"), $0 > (dir "/" t[i])
          first = 0
          got += length($0) + 1
          if (got >= size + 1) { finish(); state = 0 }
          next
        }
        state == 2 { finish(); state = 0; next }
        function finish(   i, out) {
          for (i = 2; i <= nt; i++) {
            out = dir "/" t[i]
            if (first) printf "" > out
            close(out)
          }
        }
        END { if (state != 0) exit 1 }
      ' "$list" -
}

# Sets _pp_marker_branch to the branch the marker names (the fetched one when
# it names none).
_paxel_pull_check_marker() {
  local marker="$_pp_view/paxel-store.json" version branch
  _pp_marker_branch=""
  if ! _paxel_pull_plain_file "$marker"; then
    _paxel_pull_say_not_store
    return 1
  fi
  # Parsed here first: under bash 3.2 a jq parse error inside paxel_json_int
  # would fire the upload's ERR trap.
  if ! jq -s -e 'length == 1 and (.[0] | type) == "object"' "$marker" >/dev/null 2>&1 \
    || ! version=$(paxel_json_int "$marker" .schema_version || exit $?) \
    || [ "$version" = 0 ]; then
    _paxel_pull_say "Transcript store ${PAXEL_STORE_LINK}: paxel-store.json has no valid schema_version. Skipped; this run uses this machine's sessions only."
    return 1
  fi
  if [ "${#version}" -gt 6 ] || [ "$version" -gt "$PAXEL_STORE_SCHEMA_VERSION" ]; then
    _paxel_pull_say "Transcript store ${PAXEL_STORE_LINK}: it uses store schema ${version}, which needs a newer paxel. Skipped; this run uses this machine's sessions only."
    return 1
  fi
  branch=$(paxel_json_str "$marker" .branch '\A[A-Za-z0-9][A-Za-z0-9._/-]{0,99}\z' || exit $?) || branch=""
  if [ -n "$branch" ] && ! _paxel_store_valid_branch "$branch"; then
    paxel_say "Transcript store ${PAXEL_STORE_LINK}: paxel-store.json names branch '${branch}', which git does not accept. Reading branch ${_pp_branch:-main} instead."
    branch=""
  fi
  [ -n "$branch" ] || branch="$_pp_branch"
  _pp_marker_branch="$branch"
}

_paxel_pull_plain_file() {
  [ -f "$1" ] && [ ! -L "$1" ]
}

_paxel_pull_say_not_store() {
  _paxel_pull_say "Transcript store ${PAXEL_STORE_LINK}: it has no paxel-store.json, so it is not a Paxel store. Skipped; this run uses this machine's sessions only."
}

_paxel_pull_say_unreachable() {
  local cli how="Check that this machine's git credentials can read it"
  cli=$(paxel_config_get store_cli)
  case "$cli" in
    gh|glab) how="Check access with: ${cli} repo view ${PAXEL_STORE_LINK}" ;;
    *)
      if _paxel_pull_saved_by_create_store; then
        how="~/.paxel/config has no valid store_cli (gh or glab), whose login the fetch uses over https: a --create-store run saved this store (store_saved_at is set) and may have stopped partway. Finish the save with: $(_paxel_pull_create_store_cmd "$PAXEL_STORE_DISPLAY" || exit $?)"
      fi
      ;;
  esac
  _paxel_pull_say "Transcript store ${PAXEL_STORE_LINK}: fetch failed (network, credentials, or the repo no longer exists). This run uses this machine's sessions only. ${how}, then run the upload again."
}

# Validates every manifest, keeps the sessions in scope, marks the ones this
# machine already has, applies --since, and writes $_pp_work/selected:
#   tool  session_id  touch_stamp  bucket  source_mtime
_paxel_pull_select() {
  local filter="$1" listed verdicts
  _paxel_pull_list_manifests > "$_pp_work/manifests"
  _pp_rejected=$((_pp_rejected + _pp_bad_names))
  _paxel_pull_read_manifests "$_pp_work/manifests" > "$_pp_work/verdicts" || return 1
  listed=$(tr -cd '\000' < "$_pp_work/manifests" | wc -c | tr -d ' ' || exit $?) || return 1
  verdicts=$(wc -l < "$_pp_work/verdicts" | tr -d ' ' || exit $?) || return 1
  # An empty manifest file yields no jq line at all.
  _pp_rejected=$((_pp_rejected + listed - verdicts))
  _paxel_pull_local_keys > "$_pp_work/local" || return 1
  _paxel_pull_candidates "$filter" < "$_pp_work/verdicts" > "$_pp_work/candidates" || return 1
  if [ -n "$_pp_project" ]; then
    _paxel_pull_project_scope 4 < "$_pp_work/candidates" > "$_pp_work/candidates.scoped" || return 1
    mv "$_pp_work/candidates.scoped" "$_pp_work/candidates" || return 1
  fi
  _paxel_pull_mark_local "$_pp_work/local" "$_pp_work/candidates" > "$_pp_work/marked" || return 1
  : > "$_pp_work/buckets" || return 1
  : > "$_pp_work/origins" || return 1
  _paxel_pull_choose < "$_pp_work/marked" > "$_pp_work/selected"
}

# NUL-separated store-relative manifest paths, read from the run's view.
_paxel_pull_list_manifests() {
  local kind oid path
  while IFS=$'\t' read -r kind oid path; do
    [ "$kind" = manifest ] || continue
    printf '%s\000' "$path"
  done < "$_pp_work/tree"
}

_paxel_pull_read_manifests() {
  local list="$1"
  [ -s "$list" ] || return 0
  _paxel_pull_tag_lines "$_pp_view" < "$list" \
    | jq -R -n -r --argjson schema "$PAXEL_STORE_SCHEMA_VERSION" --arg box_name_re "$PAXEL_BOX_NAME_RE" \
      "$_PAXEL_PULL_MANIFEST_JQ"
}

# Prints every line of the store-relative files named (NUL-separated) on stdin
# as "<path>\t<line>". jq -R alone would join a file's unterminated last line
# to the next file's first line. Validated names hold no tab. A file awk
# cannot read yields no lines, which the callers count as rejected or skip.
_paxel_pull_tag_lines() {
  (cd "$1" && LC_ALL=C xargs -0 awk '{ print FILENAME "\t" $0 }' 2>/dev/null || true)
}

# Reads verdict lines; prints the valid in-scope sessions:
#   tool  session_id  source_mtime  remote  cwd  box_id  touch_stamp  box_label
# where box_label is the box's host name, else its id.
_paxel_pull_candidates() {
  local filter="$1" filter_norm="" tool_dir id_dir status tool sid mtime remote cwd box box_name stamp rest box_label
  if [ -n "$filter" ]; then
    filter_norm=$(normalize_remote "$filter" || exit $?) || return 1
  fi
  while IFS="$_PAXEL_US" read -r tool_dir id_dir status tool sid mtime remote cwd box box_name stamp rest; do
    case "$status" in
      ok) ;;
      newer) _pp_newer=$((_pp_newer + 1)); continue ;;
      *) _pp_rejected=$((_pp_rejected + 1)); continue ;;
    esac
    # The manifest must describe the folder it sits in.
    if [ "$tool" != "$tool_dir" ] || [ "$sid" != "$id_dir" ]; then
      _pp_rejected=$((_pp_rejected + 1))
      continue
    fi
    _pp_valid=$((_pp_valid + 1))
    # Boxes normalize remotes before writing them, so only an odd one pays
    # for the fork of a command substitution.
    case "$remote" in
      *://*|*@*|*.git|*/) remote=$(normalize_remote "$remote" || exit $?) || return 1 ;;
    esac
    if [ -n "$filter_norm" ] && [ "$remote" != "$filter_norm" ]; then
      # Only what --all would take: it still drops sessions older than --since.
      if [ -z "${SINCE_EPOCH:-}" ] || [ "$mtime" -ge "$SINCE_EPOCH" ]; then
        _pp_other=$((_pp_other + 1))
      fi
      continue
    fi
    box_label="$box_name"
    [ -n "$box_label" ] || box_label="$box"
    [ -n "$box_label" ] || box_label="unnamed box"
    printf '%s\n' "${tool}${_PAXEL_US}${sid}${_PAXEL_US}${mtime}${_PAXEL_US}${remote}${_PAXEL_US}${cwd}${_PAXEL_US}${box}${_PAXEL_US}${stamp}${_PAXEL_US}${box_label}"
  done
}

# Keeps the US-separated lines whose field N (a remote), or field N+1 (the
# cwd) when the remote is blank, contains _pp_project. Same rule as the
# client's --project filter on project dirs: case-insensitive, _ read as -.
_paxel_pull_project_scope() {
  PXP_PROJECT="$_pp_project" LC_ALL=C awk -F "$_PAXEL_US" -v n="$1" '
    function norm(s) { s = tolower(s); gsub(/_/, "-", s); return s }
    BEGIN { want = norm(ENVIRON["PXP_PROJECT"]); m = n + 1 }
    { t = ($n != "" ? $n : $m); if (index(norm(t), want) > 0) print }'
}

# Sessions this machine already has, as tool/id. Local copies win: a session
# resumed on the laptop is newer there than in the store.
_paxel_pull_local_keys() {
  if [ -d "$CLAUDE_DIR" ]; then
    find "$CLAUDE_DIR" -mindepth 2 -maxdepth 2 -name '*.jsonl' 2>/dev/null \
      | sed 's|.*/||; s|\.jsonl$||; s|^|claude/|' || true
  fi
  if [ -d "$CODEX_DIR" ]; then
    find "$CODEX_DIR" -maxdepth 6 -name 'rollout-*.jsonl' 2>/dev/null \
      | sed -n 's|.*-\([0-9A-Fa-f]\{8\}-[0-9A-Fa-f]\{4\}-[0-9A-Fa-f]\{4\}-[0-9A-Fa-f]\{4\}-[0-9A-Fa-f]\{12\}\)\.jsonl$|codex/\1|p' || true
  fi
}

_paxel_pull_mark_local() {
  awk -F "$_PAXEL_US" -v OFS="$_PAXEL_US" '
    FILENAME == ARGV[1] { have[$0] = 1; next }
    { print ((($1 "/" $2) in have) ? "here" : "new"), $0 }' "$1" "$2"
}

_paxel_pull_choose() {
  local mark tool sid mtime remote cwd box stamp box_label
  while IFS="$_PAXEL_US" read -r mark tool sid mtime remote cwd box stamp box_label; do
    _pp_found=$((_pp_found + 1))
    if [ "$mark" = "here" ]; then
      _pp_here=$((_pp_here + 1))
      continue
    fi
    if [ -n "${SINCE_EPOCH:-}" ] && [ "$mtime" -lt "$SINCE_EPOCH" ]; then
      _pp_older=$((_pp_older + 1))
      continue
    fi
    _paxel_pull_bucket "$remote" "$cwd" "$box" || return 1
    printf '%s\n' "${tool}${_PAXEL_US}${sid}${_PAXEL_US}${remote}${_PAXEL_US}${box_label}${_PAXEL_US}${box}" >> "$_pp_work/origins"
    printf '%s\n' "${tool}${_PAXEL_US}${sid}${_PAXEL_US}${stamp}${_PAXEL_US}${_pp_bucket}${_PAXEL_US}${mtime}"
  done
}

# Sets _pp_bucket: one bucket per remote, and for sessions with no remote one
# per box and cwd, so unrelated sessions never merge into one project.
_paxel_pull_bucket() {
  local remote="$1" cwd="$2" box="$3" key slug identity hash i=0
  if [ -n "$remote" ]; then key="r|$remote"; else key="b|$box|$cwd"; fi
  while [ "$i" -lt "${#_pp_bkeys[@]}" ]; do
    if [ "${_pp_bkeys[$i]}" = "$key" ]; then
      _pp_bucket="${_pp_bnames[$i]}"
      return 0
    fi
    i=$((i + 1))
  done
  if [ -n "$remote" ]; then
    slug="${remote##*/}"
    identity="$remote"
  else
    slug="${cwd##*/}"
    identity="$box|$cwd"
  fi
  slug=$(printf '%s' "$slug" | tr -c 'A-Za-z0-9_.-' '-' | sed 's/--*/-/g; s/^-//; s/-$//' || exit $?) || slug=""
  [ -n "$slug" ] || slug="unattributed"
  hash=$(stable_hash6 "$identity" || exit $?) || return 1
  _pp_bucket="_store_${slug}_${hash}"
  _pp_bkeys+=("$key")
  _pp_bnames+=("$_pp_bucket")
  printf '%s\n' "${_pp_bucket}${_PAXEL_US}${remote}${_PAXEL_US}${cwd}" >> "$_pp_work/buckets"
}

# Writes $_pp_work/git: box  key  remote  laptop_key, one line per repo, from
# the newest full (not shallow) snapshot any box wrote. A shallow snapshot
# would replace full history with a few commits, so a repo with only shallow
# ones ships no git files.
_paxel_pull_pick_git() {
  local m rel box key status remote captured rest lkey
  : > "$_pp_work/git"
  : > "$_pp_work/git_metas"
  for m in "$_pp_view"/git/*/meta/*.json; do
    [ -f "$m" ] || continue
    rel=${m#"$_pp_view"/}
    box=${rel#git/}
    box=${box%%/*}
    key=${rel##*/}
    key=${key%.json}
    if paxel_valid_name "$box" && paxel_valid_name "$key"; then
      printf '%s\000' "$rel" >> "$_pp_work/git_metas"
    fi
  done
  [ -s "$_pp_work/git_metas" ] || return 0
  _paxel_pull_tag_lines "$_pp_view" < "$_pp_work/git_metas" \
    | jq -R -n -r "$_PAXEL_PULL_GIT_META_JQ" 2>/dev/null \
    | while IFS="$_PAXEL_US" read -r box key status remote captured rest; do
        [ "$status" = "full" ] || continue
        case "$remote" in
          *://*|*@*|*.git|*/) remote=$(normalize_remote "$remote" || exit $?) || continue ;;
        esac
        printf '%s\n' "${remote}${_PAXEL_US}${captured}${_PAXEL_US}${box}${_PAXEL_US}${key}"
      done \
    | LC_ALL=C sort -t "$_PAXEL_US" -k1,1 -k2,2r \
    | awk -F "$_PAXEL_US" '!seen[$1]++' > "$_pp_work/git_newest"
  if [ -n "$_pp_project" ]; then
    _paxel_pull_project_scope 1 < "$_pp_work/git_newest" > "$_pp_work/git_newest.scoped" \
      && mv "$_pp_work/git_newest.scoped" "$_pp_work/git_newest" || : > "$_pp_work/git_newest"
  fi
  while IFS="$_PAXEL_US" read -r remote captured box key; do
    lkey=$(repository_git_key "$remote" || exit $?) || continue
    printf '%s\n' "${box}${_PAXEL_US}${key}${_PAXEL_US}${remote}${_PAXEL_US}${lkey}" >> "$_pp_work/git"
  done < "$_pp_work/git_newest"
  return 0
}

# Plans the files of each selected session from the tree, newest session
# first, in the layout local runs have: Claude <id>.jsonl plus
# subagents/agent-*.jsonl, Codex exactly one rollout-*-<id>.jsonl. Extra
# files a box planted are never downloaded. $_pp_work/plan lines:
#   file  tool  sid  stamp  bucket  mtime  main|sub  oid  name
#   reject  tool/sid           (the layout is wrong)
_paxel_pull_plan() {
  LC_ALL=C sort -t "$_PAXEL_US" -k5,5nr "$_pp_work/selected" > "$_pp_work/selected.newest" || return 1
  awk -F '\t' -v US="$_PAXEL_US" '
    FILENAME == ARGV[1] {
      split($3, p, "/")
      if ($1 == "main") main["claude/" p[3]] = $2 US p[4]
      else if ($1 == "sub") subs["claude/" p[3]] = subs["claude/" p[3]] "\n" $2 US p[5]
      else if ($1 == "rollout") { nroll["codex/" p[3]]++; roll["codex/" p[3]] = $2 US p[4] }
      next
    }
    {
      split($0, s, US)
      key = s[1] "/" s[2]
      if (s[1] == "claude" && (key in main)) {
        print "file" US $0 US "main" US main[key]
        n = split(subs[key], ss, "\n")
        for (i = 2; i <= n; i++) print "file" US $0 US "sub" US ss[i]
      } else if (s[1] == "codex" && nroll[key] == 1) {
        print "file" US $0 US "main" US roll[key]
      } else {
        print "reject" US key
      }
    }' "$_pp_work/tree" "$_pp_work/selected.newest" > "$_pp_work/plan"
}

# Downloads the selected snapshot files, then the selected session files
# newest first. The snapshot files go into the run's view for restage.
_paxel_pull_download_selected() {
  local cache="$1" count rc=0
  _paxel_pull_plan || return 1
  count=$(awk -F "$_PAXEL_US" '$1 == "file" && $7 == "main" { n++ } END { print n + 0 }' "$_pp_work/plan" || exit $?) || return 1
  if [ "$_pp_fresh" -eq 1 ] && [ "$count" -gt 0 ]; then
    paxel_say "Transcript store ${PAXEL_STORE_LINK}: first download, fetching $(paxel_sessions_text "$count") (later runs fetch only what changed)."
  fi
  _paxel_pull_git_files > "$_pp_work/git_files" || return 1
  {
    cut -f1 "$_pp_work/git_files"
    awk -F "$_PAXEL_US" '$1 == "file" { print $8 }' "$_pp_work/plan"
  } > "$_pp_work/want" || return 1
  _paxel_pull_prefetch "$cache" "$_pp_work/want" 1 || rc=$?
  case "$rc" in
    0|2|3) ;;
    *) return 1 ;;
  esac
  _paxel_pull_present "$cache" || return 1
  awk 'FILENAME == ARGV[1] { have[$1] = 1; next } ($1 in have)' "$_pp_work/present" "$_pp_work/git_files" \
    > "$_pp_work/git_files.ready" || return 1
  _paxel_pull_write_blobs "$cache" "$_pp_work/git_files.ready" "$_pp_view" || return 1
  awk -F "$_PAXEL_US" -v OFS="$_PAXEL_US" 'FILENAME == ARGV[1] { have[$1] = 1; next }
    $1 == "file" { print $0, (($8 in have) ? 1 : 0); next } { print }' "$_pp_work/present" "$_pp_work/plan" \
    > "$_pp_work/plan.ready"
}

# oid<TAB>path of every file of the chosen snapshots.
_paxel_pull_git_files() {
  [ -s "$_pp_work/git" ] || return 0
  awk -F '\t' -v US="$_PAXEL_US" -v suffixes="$PAXEL_PULL_GIT_FILES" '
    FILENAME == ARGV[1] {
      split($0, g, US)
      n = split(suffixes, sx, " ")
      for (i = 1; i <= n; i++) want["git/" g[1] "/_git/" g[2] "_" sx[i]] = 1
      next
    }
    $1 == "gitfile" && ($3 in want) { print $2 "\t" $3 }' "$_pp_work/git" "$_pp_work/tree"
}

_paxel_pull_restage_sessions() {
  local cache="$1" out="$2" mark tool sid stamp bucket mtime kind oid name ready key="" rc
  local s_tool="" s_sid="" s_stamp="" s_bucket="" s_mtime="" s_ready=1 s_files=()
  : > "$_pp_work/added" || return 1
  while IFS="$_PAXEL_US" read -r mark tool sid stamp bucket mtime kind oid name ready; do
    if [ "$mark" = reject ]; then
      _pp_found=$((_pp_found - 1))
      _pp_rejected=$((_pp_rejected + 1))
      continue
    fi
    if [ "$tool/$sid" != "$key" ]; then
      _paxel_pull_restage_one "$cache" "$out" || return 1
      key="$tool/$sid"
      s_tool="$tool"; s_sid="$sid"; s_stamp="$stamp"; s_bucket="$bucket"; s_mtime="$mtime"; s_ready=1; s_files=()
    fi
    [ "$ready" = 1 ] || s_ready=0
    s_files+=("${kind}${_PAXEL_US}${oid}${_PAXEL_US}${name}")
  done < "$_pp_work/plan.ready"
  _paxel_pull_restage_one "$cache" "$out" || return 1
  _paxel_pull_write_sidecar "$out"
}

# Writes the session gathered in s_* to OUT/<bucket>, file times from the
# manifest: --since and the author-commit window read file times. A session
# missing a file (the download stopped) waits for the next run.
_paxel_pull_restage_one() {
  local cache="$1" out="$2" dest entry kind oid name target written=()
  [ -n "$s_sid" ] || return 0
  if [ "$s_ready" != 1 ]; then
    _pp_pending=$((_pp_pending + 1))
    s_sid=""
    return 0
  fi
  dest="$out/$s_bucket"
  for entry in "${s_files[@]}"; do
    kind=${entry%%"$_PAXEL_US"*}
    entry=${entry#*"$_PAXEL_US"}
    oid=${entry%%"$_PAXEL_US"*}
    name=${entry#*"$_PAXEL_US"}
    if [ "$kind" = sub ]; then target="$dest/$s_sid/subagents/$name"; else target="$dest/$name"; fi
    if ! mkdir -p "${target%/*}" 2>/dev/null \
      || ! GIT_NO_LAZY_FETCH=1 git -C "$cache" cat-file blob "$oid" > "$target" 2>/dev/null; then
      _paxel_pull_say "Transcript store ${PAXEL_STORE_LINK}: could not copy its sessions into ${out} (is the disk full?). This run uses this machine's sessions only."
      return 1
    fi
    written+=("$target")
  done
  if ! TZ=UTC0 touch -t "$s_stamp" "${written[@]}" 2>/dev/null; then
    _paxel_pull_say "Transcript store ${PAXEL_STORE_LINK}: could not copy its sessions into ${out} (is the disk full?). This run uses this machine's sessions only."
    return 1
  fi
  _pp_jsonl=$((_pp_jsonl + ${#written[@]}))
  _pp_added=$((_pp_added + 1))
  printf '%s\n' "${s_tool}${_PAXEL_US}${s_sid}" >> "$_pp_work/added"
  if [ -z "$_pp_oldest" ] || [ "$s_mtime" -lt "$_pp_oldest" ]; then _pp_oldest="$s_mtime"; fi
  s_sid=""
}

_paxel_pull_write_sidecar() {
  local out="$1" bucket remote cwd
  while IFS="$_PAXEL_US" read -r bucket remote cwd; do
    if [ -d "$out/$bucket" ]; then
      printf '%s\n' "${bucket}${_PAXEL_US}${remote}${_PAXEL_US}${cwd}"
    fi
  done < "$_pp_work/buckets" \
    | jq -R -n '{ version: 1, directories: ([inputs | split("\u001f") | { key: .[0], value: { git_remote: .[1], cwd: .[2] } }] | from_entries) }' \
    > "$out/_metadata.json"
}

# Writes the restaged sessions, one line each:
#   remote<TAB>source<TAB>tool<TAB>id<TAB>box_id
# A box's manifests pushed before push recorded box_name take the name its
# newer ones carry. Kept beside the stage dir, not in it: the stage dir is
# mounted into the client.
_paxel_pull_write_sources() {
  awk -F "$_PAXEL_US" -v OFS='\t' '
    FILENAME == ARGV[1] { added[$1 FS $2] = 1; next }
    $5 != "" && $4 != $5 { name[$5] = $4 }
    ($1 FS $2) in added {
      n++; remote[n] = $3; label[n] = $4; sid[n] = $2; box[n] = $5
      tool[n] = ($1 == "codex") ? "Codex" : "Claude Code"
    }
    END { for (i = 1; i <= n; i++) print remote[i], ((box[i] in name) ? name[box[i]] : label[i]), tool[i], sid[i], box[i] }' \
    "$_pp_work/added" "$_pp_work/origins" > "$1"
}

# Boxes of the restaged sessions. A manifest with no box id counts as one box,
# the "unnamed box" the sources list shows.
_paxel_pull_count_boxes() {
  awk -F "$_PAXEL_US" '
    FILENAME == ARGV[1] { added[$1 FS $2] = 1; next }
    (($1 FS $2) in added) && !seen[$5]++ { n++ }
    END { print n + 0 }' "$_pp_work/added" "$_pp_work/origins"
}

# Copies the chosen snapshots under the laptop's own repository key, cut to
# this run's --since and --commits window by author date so they line up with
# laptop-collected repos.
_paxel_pull_restage_git() {
  local out="$1" since_date="" limit activity_since box key remote lkey suffix src dst copied
  [ -s "$_pp_work/git" ] || return 0
  if [ -n "${SINCE_EPOCH:-}" ]; then
    since_date=$(date -r "$SINCE_EPOCH" '+%Y-%m-%d' 2>/dev/null || date -d "@$SINCE_EPOCH" '+%Y-%m-%d' 2>/dev/null || true)
  fi
  limit="${COMMIT_LIMIT:-1000}"
  paxel_is_uint "$limit" || limit=1000
  activity_since=$(_activity_since_date || exit $?) || activity_since=""
  mkdir -p "$out/_git" || return 0
  while IFS="$_PAXEL_US" read -r box key remote lkey; do
    copied=0
    for suffix in $PAXEL_PULL_GIT_FILES; do
      src="$_pp_view/git/$box/_git/${key}_${suffix}"
      dst="$out/_git/${lkey}_${suffix}"
      _paxel_pull_plain_file "$src" || continue
      case "$suffix" in
        commit_count.txt) _paxel_pull_copy_count "$src" "$dst" ;;
        numstat.txt|author_numstat.txt) _paxel_pull_cut_boundaries "$src" "$dst" "$since_date" "$limit" ;;
        author_commits.jsonl) _paxel_pull_cut_commits "$src" "$dst" "$since_date" "$limit" ;;
        activity.tsv) _paxel_pull_cut_activity "$src" "$dst" "$activity_since" ;;
      esac && copied=$((copied + 1))
    done
    if [ "$copied" -gt 0 ]; then
      printf '%s\t%s\n' "$lkey" "$remote" >> "$out/_git/repositories.tsv"
      _pp_git_repos=$((_pp_git_repos + 1))
    fi
  done < "$_pp_work/git"
}

_paxel_pull_copy_count() {
  local count
  count=$(sed -n '1p' "$1" || exit $?) || return 1
  paxel_is_uint "$count" || return 1
  printf '%s\n' "$count" > "$2"
}

# COMMIT_BOUNDARY <sha> <author date> ... blocks (numstat, author_numstat).
_paxel_pull_cut_boundaries() {
  awk -v since="$3" -v max="$4" '
    /^COMMIT_BOUNDARY / { keep = (since == "" || substr($3, 1, 10) >= since) && count < max; if (keep) count++ }
    keep { print }' "$1" > "$2"
}

# sha  short  name  email  author date  subject
_paxel_pull_cut_commits() {
  awk -F '\t' -v since="$3" -v max="$4" '
    (since == "" || substr($5, 1, 10) >= since) && count < max { print; count++ }' "$1" > "$2"
}

# "# since=DATE" then day  email  name  count rows; the header moves up to the
# cut so the client does not read the dropped days as quiet ones.
_paxel_pull_cut_activity() {
  awk -F '\t' -v since="$3" '
    NR == 1 && /^# since=/ { s = substr($0, 9); if (since != "" && s < since) s = since; print "# since=" s; next }
    NR == 1 && since != "" { print "# since=" since }
    since == "" || substr($1, 1, 10) >= since { print }' "$1" > "$2"
}

_paxel_pull_report() {
  PAXEL_STORE_SESSIONS="$_pp_added"
  PAXEL_STORE_JSONL="$_pp_jsonl"
  PAXEL_STORE_OLDEST_EPOCH="$_pp_oldest"
  PAXEL_STORE_BOXES=$(_paxel_pull_count_boxes || exit $?) || PAXEL_STORE_BOXES=""
  local via="" line
  case "$(paxel_config_get store_cli)" in
    gh) via=" (via gh)" ;;
    glab) via=" (via glab)" ;;
  esac
  line="Transcript store ${PAXEL_STORE_LINK}${via}: ${_pp_found} found, ${_pp_here} already here"
  if [ -n "${SINCE_EPOCH:-}" ]; then line="${line}, ${_pp_older} older than --since"; fi
  line="${line}, ${_pp_added} added"
  # With --project, --all still scopes the store to that name.
  if [ -z "${PROJECT_NAME:-}" ]; then
    if [ "$_pp_other" -eq 1 ]; then line="${line}; 1 more outside this repo (add --all to include it)"; fi
    if [ "$_pp_other" -gt 1 ]; then line="${line}; ${_pp_other} more outside this repo (add --all to include them)"; fi
  fi
  if [ "$_pp_newer" -gt 0 ]; then line="${line}; ${_pp_newer} skipped (needs a newer paxel)"; fi
  if [ "$_pp_rejected" -gt 0 ]; then line="${line}; ${_pp_rejected} rejected (invalid store entries)"; fi
  if [ "$_pp_pending" -gt 0 ]; then line="${line}; ${_pp_pending} not downloaded yet (the next upload continues)"; fi
  paxel_say "${line}."
  paxel_log "pull store=${PAXEL_STORE_DISPLAY} found=${_pp_found} here=${_pp_here} older=${_pp_older} added=${_pp_added} other_repos=${_pp_other} pending=${_pp_pending} schema_v1=${_pp_valid} schema_newer=${_pp_newer} rejected=${_pp_rejected} git_repos=${_pp_git_repos}"
}

# Once a day: a gc merges the many small packs batched downloads leave. git
# keeps every object of a partial clone's downloaded packs, so the old
# versions of growing sessions pile up; once the cache holds more than twice
# the current files plus PAXEL_PULL_CACHE_SLACK_KB (100 MB), it is dropped
# and the next upload downloads the current files again.
_paxel_pull_maintain() {
  local cache="$1" stamp="$1/.git/paxel-gc-at" slack all tip
  [ -z "$(find "$stamp" -mmin -1440 2>/dev/null || true)" ] || return 0
  touch "$stamp" 2>/dev/null || true
  paxel_git -C "$cache" gc --quiet >/dev/null 2>&1 || true
  slack="${PAXEL_PULL_CACHE_SLACK_KB:-102400}"
  paxel_is_uint "$slack" || slack=102400
  all=$(git -C "$cache" cat-file --batch-all-objects --batch-check='%(objecttype) %(objectsize)' 2>/dev/null \
    | awk '$1 == "blob" { s += $2 } END { printf "%d\n", s / 1024 }' || exit $?) || return 0
  awk -F '\t' 'FILENAME == ARGV[1] { have[$1] = 1; next } ($2 in have) { print $2 }' \
    "$_pp_work/present" "$_pp_work/tree" > "$_pp_work/tip_present" 2>/dev/null || return 0
  tip=$(git -C "$cache" cat-file --batch-check='%(objectsize)' < "$_pp_work/tip_present" 2>/dev/null \
    | awk '/^[0-9]+$/ { s += $1 } END { printf "%d\n", s / 1024 }' || exit $?) || return 0
  paxel_is_uint "$all" && paxel_is_uint "$tip" && [ "${#all}" -le 15 ] && [ "${#tip}" -le 15 ] || return 0
  if [ "$all" -gt $((tip * 2 + slack)) ]; then
    rm -rf "$cache"
    paxel_log "pull cache_reset blobs_kb=${all} current_kb=${tip}"
  fi
}

paxel_sessions_text() {
  if [ "$1" = 1 ]; then printf '1 session\n'; else printf '%s sessions\n' "$1"; fi
}

# The store mount needs a client image that merges it; a stale cached image
# would drop the sessions without a word.
paxel_pull_image_ready() {
  local image="$1" caps
  caps=$(docker image inspect --format '{{json .Config.Labels}}' "$image" 2>/dev/null \
    | jq -r '(. // {})["dev.paxel.capabilities"] // ""' 2>/dev/null || true)
  case ",${caps// /,}," in
    *",${PAXEL_STORE_CAPABILITY},"*) return 0 ;;
  esac
  echo "  Transcript store: $(paxel_sessions_text "$PAXEL_STORE_SESSIONS") skipped — the Paxel image ${image} predates transcript-store support. Pull a newer image and re-run to include them."
  return 1
}

# When the laptop clone is a repo's git source, that repo's store sessions join
# the local ones for the author-commit window and author-email detection.
paxel_pull_add_author_dirs() {
  local candidates="$1" stage="${PAXEL_STORE_STAGE_DIR:-}" bucket remote row tab=$'\t'
  [ -n "$stage" ] && [ -f "$stage/_metadata.json" ] || return 0
  while IFS="$_PAXEL_US" read -r bucket remote; do
    row=$(awk -F '\t' -v r="$remote" '$2 == r { print $1 "\t" $3; exit }' "$candidates" || exit $?) || row=""
    [ -n "$row" ] || continue
    printf '%s\t%s\t%s\t%s\n' "${row%%"$tab"*}" "$remote" "${row#*"$tab"}" "$stage/$bucket" >> "$candidates"
  done < <(jq -r '.directories | to_entries[] | select(.value.git_remote != "") | [.key, .value.git_remote] | join("\u001f")' \
    "$stage/_metadata.json" 2>/dev/null || true)
  return 0
}

# Repos with no laptop clone take the restaged box snapshot and a
# repositories.tsv row.
paxel_pull_add_store_git() {
  local candidates="$1" git_out="$2" manifest="$3" stage="${PAXEL_STORE_STAGE_DIR:-}"
  local key remote suffix added=0 noun="repos"
  [ -n "$stage" ] && [ -f "$stage/_git/repositories.tsv" ] || return 0
  while IFS=$'\t' read -r key remote; do
    [ -n "$key" ] && [ -n "$remote" ] || continue
    if awk -F '\t' -v r="$remote" '$2 == r { found = 1; exit } END { exit !found }' "$candidates"; then
      continue
    fi
    for suffix in $PAXEL_PULL_GIT_FILES; do
      if [ -f "$stage/_git/${key}_${suffix}" ]; then
        cp "$stage/_git/${key}_${suffix}" "$git_out/" || return 0
      fi
    done
    printf '%s\t%s\n' "$key" "$remote" >> "$manifest"
    added=$((added + 1))
  done < "$stage/_git/repositories.tsv"
  if [ "$added" -gt 0 ]; then
    if [ "$added" -eq 1 ]; then noun="repo"; fi
    echo "  Took git history for ${added} ${noun} from box snapshots in the transcript store (no clone on this machine)"
  fi
  return 0
}

# Prints, before the analysis starts, the sessions this run hands to the
# client: per project, how many come from this machine and how many from each
# box through the transcript store, with a count per agent. Only when a store
# was found, even one that added nothing. --verbose (PAXEL_LIST_SESSIONS=1)
# shows every project and lists every session.
# paxel_pull_print_sources CLAUDE_DIR CLAUDE_SIDECAR [AGENT EXTRACT_DIR]...
paxel_pull_print_sources() {
  local claude_dir="$1" claude_sidecar="$2" work
  shift 2
  [ -n "${PAXEL_STORE_DISPLAY:-}" ] || return 0
  work=$(mktemp -d 2>/dev/null || exit $?) || work=""
  if [ -n "$work" ] && _paxel_sources_collect "$work" "$claude_dir" "$claude_sidecar" "$@" \
    && _paxel_sources_render "$work" > "$work/out"; then
    cat "$work/out"
  else
    printf '\nSessions in this upload: could not list them; the analysis goes on.\n'
  fi
  [ -z "$work" ] || rm -rf "$work"
  return 0
}

# $work/rows: remote  L|S  source  agent  session_id  box_id, one line per
# session (no box_id for this machine's).
_paxel_sources_collect() {
  local work="$1" claude_dir="$2" claude_sidecar="$3"
  shift 3
  _paxel_sources_claude "$work" "$claude_dir" "$claude_sidecar" > "$work/rows" || return 1
  while [ "$#" -ge 2 ]; do
    _paxel_sources_agent "$work" "$1" "$2" >> "$work/rows" || return 1
    shift 2
  done
  if [ -n "${PAXEL_STORE_STAGE_DIR:-}" ]; then
    [ -f "${PAXEL_STORE_SOURCES:-}" ] || return 1
    awk -F '\t' -v OFS='\t' '{ print $1, "S", $2, $3, $4, $5 }' "$PAXEL_STORE_SOURCES" >> "$work/rows" || return 1
  fi
  _paxel_sources_normalize "$work"
}

# This machine's Claude sessions as the client reads them: the files
# claude_session_files finds, minus those older than --since and, in an --all
# --project run, those in folders whose name lacks the project (the client's
# own filters). Each takes its folder's remote from the sidecar.
_paxel_sources_claude() {
  local work="$1" dir="$2" sidecar="$3" want=""
  [ -d "$dir" ] || return 0
  _paxel_sources_map "$sidecar" > "$work/claude_map" || return 1
  if [ "${CLAUDE_MOUNT_SCOPE:-all}" != filtered ] && [ -n "${PROJECT_NAME:-}" ] && [ "$PROJECT_NAME" != all ]; then
    want="$PROJECT_NAME"
  fi
  _paxel_sources_claude_files "$dir" > "$work/claude_files" || return 1
  PXS_WANT="$want" LC_ALL=C awk -v since="${SINCE_EPOCH:-}" -v OFS='\t' '
    function norm(s) { s = tolower(s); gsub(/_/, "-", s); return s }
    BEGIN { want = norm(ENVIRON["PXS_WANT"]) }
    FILENAME == ARGV[1] { i = index($0, "\t"); remote[substr($0, 1, i - 1)] = substr($0, i + 1); next }
    {
      path = $0
      if (since != "") {
        i = index($0, " "); mtime = substr($0, 1, i - 1); path = substr($0, i + 1)
        if (mtime + 0 < since + 0) next
      }
      sub(/^\.\//, "", path)
      n = split(path, part, "/")
      project = (n > 1) ? part[1] : ""
      if (want != "" && index(norm(project), want) == 0) next
      id = part[n]
      sub(/\.jsonl$/, "", id)
      print remote[project], "L", "this machine", "Claude Code", id
    }' "$work/claude_map" "$work/claude_files"
}

# "./project/id.jsonl" per session file, with "mtime " before it under --since.
_paxel_sources_claude_files() {
  local action=(-print)
  if [ -n "${SINCE_EPOCH:-}" ]; then
    if stat -c %Y / >/dev/null 2>&1; then
      action=(-exec stat -c '%Y %n' {} +)
    else
      action=(-exec stat -f '%m %N' {} +)
    fi
  fi
  (cd "$1" && claude_session_files . "${action[@]}") || true
}

# This machine's sessions of another agent, from the folder its collector
# filled (already cut to --since and the run's scope): one session per
# <bucket>/<file>.jsonl, as the mount summary counts them.
_paxel_sources_agent() {
  local work="$1" agent="$2" dir="$3"
  [ -n "$dir" ] && [ -d "$dir" ] || return 0
  _paxel_sources_map "$dir/_metadata.json" > "$work/agent_map" || return 1
  (cd "$dir" && find . -mindepth 2 -maxdepth 2 -path './_*/*.jsonl' 2>/dev/null) > "$work/agent_files" || true
  LC_ALL=C awk -v agent="$agent" -v OFS='\t' '
    FILENAME == ARGV[1] { i = index($0, "\t"); remote[substr($0, 1, i - 1)] = substr($0, i + 1); next }
    {
      sub(/^\.\//, "")
      i = index($0, "/"); bucket = substr($0, 1, i - 1); id = substr($0, i + 1)
      sub(/\.jsonl$/, "", id)
      if (id ~ /^rollout-/ && length(id) > 36) id = substr(id, length(id) - 35)
      print remote[bucket], "L", "this machine", agent, id
    }' "$work/agent_map" "$work/agent_files"
}

# "folder<TAB>remote" for each folder a _metadata.json sidecar names.
_paxel_sources_map() {
  [ -n "$1" ] && [ -f "$1" ] || return 0
  jq -r '(.directories // {}) | to_entries[] | [.key, ((.value.git_remote // "") | tostring)] | @tsv' "$1" 2>/dev/null || true
}

# A collector's sidecar can hold a raw remote (a Codex repository_url).
_paxel_sources_normalize() {
  local work="$1" r n
  : > "$work/remote_map" || return 1
  cut -f1 "$work/rows" | LC_ALL=C sort -u > "$work/remotes" || return 1
  while IFS= read -r r; do
    case "$r" in
      *://*|*@*|*.git|*/)
        n=$(normalize_remote "$r" || exit $?) || n="$r"
        printf '%s\t%s\n' "$r" "$n" >> "$work/remote_map"
        ;;
    esac
  done < "$work/remotes"
  [ -s "$work/remote_map" ] || return 0
  LC_ALL=C awk -F '\t' -v OFS='\t' '
    FILENAME == ARGV[1] { norm[$1] = $2; next }
    { if ($1 in norm) $1 = norm[$1]; print }' "$work/remote_map" "$work/rows" > "$work/rows.norm" \
    && mv "$work/rows.norm" "$work/rows"
}

# $work/groups: project_total  no_remote  remote  L|S  count  source
# agent_mix, one line per project and source: projects by size (sessions with
# no remote last among equals), this machine before the boxes.
_paxel_sources_render() {
  local work="$1" verbose=0 tab=$'\t' boxes
  [ "${PAXEL_LIST_SESSIONS:-0}" != 1 ] || verbose=1
  LC_ALL=C awk -F '\t' -v OFS='\t' -v tools="$PAXEL_SOURCES_TOOLS" '
    { total[$1]++; k = $1 SUBSEP $2 SUBSEP $3; n[k]++; per[k SUBSEP $4]++ }
    END {
      nt = split(tools, tool, "|")
      for (k in n) {
        split(k, f, SUBSEP)
        mix = ""
        for (i = 1; i <= nt; i++)
          if ((k SUBSEP tool[i]) in per) mix = mix (mix == "" ? "" : ", ") tool[i] " " per[k SUBSEP tool[i]]
        print total[f[1]], (f[1] == "" ? 1 : 0), f[1], f[2], n[k], f[3], mix
      }
    }' "$work/rows" | LC_ALL=C sort -t "$tab" -k1,1nr -k2,2n -k3,3 -k4,4 -k5,5nr -k6,6 > "$work/groups" || return 1
  # Two boxes can share a host name, so they are counted by id.
  boxes=$(LC_ALL=C awk -F '\t' '$2 == "S" { id[($6 != "") ? $6 : $3] = 1 } END { n = 0; for (b in id) n++; print n }' \
    "$work/rows" || exit $?) || return 1
  _paxel_sources_render_groups "$work/groups" "$verbose" "$boxes" || return 1
  if [ "$verbose" = 1 ]; then
    _paxel_sources_render_each "$work" || return 1
  fi
  printf '\n'
}

# Store text reaches the terminal only through a strict charset already;
# local folder names and remotes are cut to printable ASCII here.
_paxel_sources_render_groups() {
  LC_ALL=C awk -F '\t' -v cap=15 -v verbose="$2" -v boxes="$3" '
    function clean(s) { gsub(/[^ -~]/, "?", s); return s }
    function title(r,  name) {
      if (r == "") return "no remote"
      name = r
      sub(/.*\//, "", name)
      return clean(name) " (" clean(r) ")"
    }
    function plural(n, word, many) { return n " " (n == 1 ? word : many) }
    BEGIN { here = 0; stored = 0; wf = 0; wc = 0; wm = 0 }
    {
      if (!($3 in rank)) { projects++; rank[$3] = projects; remote[projects] = $3; size[projects] = $1 }
      if ($4 == "L") here += $5; else stored += $5
      if (verbose != 1 && rank[$3] > cap) next
      rows++; p[rows] = rank[$3]; kind[rows] = $4; count[rows] = $5; from[rows] = clean($6); mix[rows] = $7
      if (length(from[rows]) > wf) wf = length(from[rows])
      if (length($5) > wc) wc = length($5)
      if ($4 == "S" && length($7) > wm) wm = length($7)
    }
    END {
      print ""
      print "Sessions in this upload"
      for (i = 1; i <= rows; i++) {
        if (p[i] != p[i - 1]) print "  " title(remote[p[i]])
        line = sprintf("    %-" wf "s   %" wc "d   ", from[i], count[i])
        if (kind[i] == "S") line = line sprintf("%-" wm "s   (transcript store)", mix[i])
        else line = line mix[i]
        print line
      }
      if (verbose != 1 && projects > cap) {
        hidden = 0
        for (j = cap + 1; j <= projects; j++) hidden += size[j]
        print "  and " plural(projects - cap, "more project", "more projects") " (" plural(hidden, "session", "sessions") ")"
      }
      line = "  " plural(here + stored, "session", "sessions") ": " here " from this machine, " stored " from the transcript store"
      if (boxes > 0) line = line " (" plural(boxes, "box", "boxes") ")"
      print ""
      print line
      if (verbose != 1) print "  Each session with its source: add --verbose"
    }' "$1"
}

# One line per session, in the order of the groups above.
_paxel_sources_render_each() {
  local work="$1" tab=$'\t'
  LC_ALL=C awk -F '\t' -v OFS='\t' -v tools="$PAXEL_SOURCES_TOOLS" '
    BEGIN { nt = split(tools, tool, "|"); for (i = 1; i <= nt; i++) order[tool[i]] = i }
    FILENAME == ARGV[1] { group[$3 SUBSEP $4 SUBSEP $6] = FNR; next }
    { print group[$1 SUBSEP $2 SUBSEP $3], (($4 in order) ? order[$4] : nt + 1), $5, $1, $3, $4 }' \
    "$work/groups" "$work/rows" | LC_ALL=C sort -t "$tab" -k1,1n -k2,2n -k3,3 > "$work/each" || return 1
  LC_ALL=C awk -F '\t' '
    function clean(s) { gsub(/[^ -~]/, "?", s); return s }
    function short(r) { if (r == "") return "no remote"; sub(/.*\//, "", r); return clean(r) }
    BEGIN { wp = 0; wf = 0; wa = 0 }
    {
      n++; project[n] = short($4); from[n] = clean($5); agent[n] = $6; id[n] = clean($3)
      if (length(project[n]) > wp) wp = length(project[n])
      if (length(from[n]) > wf) wf = length(from[n])
      if (length(agent[n]) > wa) wa = length(agent[n])
    }
    END {
      print ""
      print "  Each session (project, source, tool, session id):"
      fmt = "    %-" wp "s  %-" wf "s  %-" wa "s  %s\n"
      for (i = 1; i <= n; i++) printf fmt, project[i], from[i], agent[i], id[i]
    }' "$work/each"
}

# --- Paxel transcript store: local copy of the paxel-remote-setup agent skill ---

PAXEL_SKILL_NAME="paxel-remote-setup"
PAXEL_SKILL_ASK="Set up Paxel transcript capture for my remote boxes using the paxel-remote-setup skill."
_PX_SKILL_MAX_TIME=30

# Filled by _paxel_skill_plan, one entry per skill folder (agents that reach
# the same physical folder share one): its physical path, the path to show,
# the agents, the folder below the home to hand over as root for another
# account ("-" when there is none; empty when root must leave the entry
# alone because every agent reaches it through a symlink), 1 when every
# agent reaches it through a symlink, then the install result.
_PX_SKILL_KEYS=()
_PX_SKILL_SHOW=()
_PX_SKILL_LABELS=()
_PX_SKILL_REL=()
_PX_SKILL_LINKED=()
_PX_SKILL_STATES=()
_PX_SKILL_NOTES=()
# One "agent<TAB>entry index<TAB>skill folder<TAB>how to run it" line per agent found.
_PX_SKILL_FOUND=""
_PX_SKILL_ERR=""
_PX_SKILL_TMP=""
_PX_SKILL_PLATFORM=""
# 1 when the user runs it for their own home, not as root: then their own
# links are followed into folders they own.
_PX_SKILL_FOLLOW=0

# One coding agent per line: name | folders that show it is installed (any
# one; a * only in the last part) | commands on PATH that show it | the user
# skills folder it reads | what to type to run the skill, empty when the
# agent takes a plain request. Roots: ~ is the home folder, @claude is
# CLAUDE_CONFIG_DIR or ~/.claude, @codex is CODEX_HOME or ~/.codex, @config
# is XDG_CONFIG_HOME or ~/.config, @gemini is GEMINI_CLI_HOME or ~, and
# @appdata is the per-user app data folder of the OS.
_paxel_skill_agent_table() {
  cat <<'PAXEL_SKILL_AGENTS'
Claude Code|@claude|claude|@claude/skills|/paxel-remote-setup
Codex|@codex|codex|~/.agents/skills|$paxel-remote-setup
Cursor|~/.cursor @appdata/Cursor||~/.agents/skills|/paxel-remote-setup
GitHub Copilot|~/.copilot ~/.vscode/extensions/github.copilot-chat-*||~/.agents/skills|/paxel-remote-setup
Gemini CLI|@gemini/.gemini/settings.json|gemini|@gemini/.agents/skills|
opencode|@config/opencode|opencode|~/.agents/skills|
Amp|@config/amp||~/.agents/skills|
Windsurf|~/.codeium/windsurf @config/devin||~/.agents/skills|@paxel-remote-setup
Factory Droid|~/.factory|droid|~/.agents/skills|/paxel-remote-setup
Antigravity|~/.gemini/antigravity||~/.gemini/config/skills|/paxel-remote-setup
Antigravity CLI|~/.gemini/antigravity-cli|agy|~/.gemini/antigravity-cli/skills|/paxel-remote-setup
Cline|~/.cline||~/.cline/skills|/paxel-remote-setup
Kiro|~/.kiro||~/.kiro/skills|/paxel-remote-setup
PAXEL_SKILL_AGENTS
}

# --- Setup's view: one item line per skills folder ---

# Copies the skill Paxel serves into the skills folders of the agents
# installed for HOME_DIR. Prints setup item lines, or one on failure, and
# always returns 0.
paxel_install_skill() {
  local home_dir="${1:-}" i=0
  if [ -z "$home_dir" ] || [ ! -d "$home_dir" ]; then
    _paxel_setup_item skill "not installed" "home directory ${home_dir} does not exist"
    return 0
  fi
  _paxel_skill_plan "$home_dir"
  if [ "${#_PX_SKILL_KEYS[@]}" -eq 0 ]; then
    _paxel_setup_item skill skipped "no coding agent found in ${home_dir}"
    return 0
  fi
  if ! _paxel_skill_install "$home_dir"; then
    _paxel_setup_item skill "not installed" "${_PX_SKILL_ERR}; run setup again to retry"
    return 0
  fi
  while [ "$i" -lt "${#_PX_SKILL_KEYS[@]}" ]; do
    _paxel_setup_item skill "${_PX_SKILL_STATES[$i]}" \
      "${_PX_SKILL_SHOW[$i]}/SKILL.md (${_PX_SKILL_LABELS[$i]}${_PX_SKILL_NOTES[$i]:+; ${_PX_SKILL_NOTES[$i]}})"
    i=$((i + 1))
  done
  return 0
}

# --- The upload's view: one line, and a hint at the end ---

# Run once per upload. A slow or unreachable server costs one line and a few
# seconds, never the upload. bash 3.2 runs the upload's ERR trap inside a
# failing command substitution even under ||, so the subshell drops it.
paxel_skill_for_upload() {
  (
    trap - ERR
    trap '_paxel_skill_drop_tmp' EXIT
    _paxel_skill_upload_line
  ) || true
}

_paxel_skill_upload_line() {
  local home
  home=$(_paxel_skill_home)
  _paxel_skill_plan "$home"
  if [ "${#_PX_SKILL_KEYS[@]}" -eq 0 ]; then
    _paxel_skill_upload_say "skipped, no coding agent found"
    return 0
  fi
  if ! _PX_SKILL_MAX_TIME=10 _paxel_skill_install "$home"; then
    _paxel_skill_upload_say "not updated (${_PX_SKILL_ERR})"
    return 0
  fi
  _paxel_skill_upload_say "$(_paxel_skill_summary)"
}

# The blank line keeps it from reading as part of the scan or the first step.
_paxel_skill_upload_say() {
  printf 'Agent skill %s (alpha: sets up session capture on your remote dev boxes): %s\n\n' "$PAXEL_SKILL_NAME" "$1"
}

# Ends an upload that found no transcript store, when an agent here has the
# skill. LEAD is the first sentence. The install ran in a subshell, so this
# looks at the skills folders again; nothing is downloaded.
paxel_skill_upload_hint() {
  [ -z "${PAXEL_NO_SKILL:-}" ] && [ -z "${PAXEL_STORE_DISPLAY:-}" ] || return 0
  # A run that did not read the store (multi-repo, no remote, a failed
  # lookup) still has one when PAXEL_STORE is set or an earlier upload pulled it.
  [ -z "${PAXEL_STORE+x}" ] && [ ! -d "${PAXEL_HOME_DIR:-${HOME}/.paxel}/store-cache" ] || return 0
  (
    trap - ERR
    _paxel_skill_print_hint "$1"
  ) || true
}

_paxel_skill_print_hint() {
  local invocations
  _paxel_skill_plan "$(_paxel_skill_home)"
  invocations=$(_paxel_skill_print_invocations)
  [ -n "$invocations" ] || return 0
  printf '\n%s To add the sessions from your remote dev boxes (alpha), run the %s skill:\n' "$1" "$PAXEL_SKILL_NAME"
  printf '%s\n' "$invocations"
  case "$invocations" in
    *"ask with the sentence below"*) printf '  %-16s ask "%s"\n' "Any agent" "$PAXEL_SKILL_ASK" ;;
  esac
  printf 'It adds one line to whatever sets up your boxes, after you approve the change.\n'
  if [ "$_PX_SKILL_PLATFORM" = wsl ]; then
    _paxel_skill_wsl_note "curl -fsSL ${PAXEL_SERVER%/}/paxel.sh | bash -s -- --skill"
  fi
}

_paxel_skill_wsl_note() {
  printf '\nThis is WSL: agents installed on Windows itself read the skills in your Windows user folder. To add the skill there too, run %s in Git Bash on Windows.\n' "$1"
}

# "created for A, B; left alone for C (why)": the agents grouped by result.
_paxel_skill_summary() {
  local state i labels out=""
  for state in created updated unchanged "left alone" "not installed"; do
    labels=""
    i=0
    while [ "$i" -lt "${#_PX_SKILL_KEYS[@]}" ]; do
      [ "${_PX_SKILL_STATES[$i]}" != "$state" ] ||
        labels="${labels:+$labels, }${_PX_SKILL_LABELS[$i]}${_PX_SKILL_NOTES[$i]:+ (${_PX_SKILL_NOTES[$i]})}"
      i=$((i + 1))
    done
    [ -z "$labels" ] || out="${out:+$out; }$state for $labels"
  done
  printf '%s\n' "$out"
}

# --- paxel.sh --skill ---

# Installs only the skill: no Docker, no sign-in, no upload, no hooks. Like
# setup it always exits 0, so a provisioning script can run it.
paxel_cmd_skill() {
  _paxel_skill_cmd_main "$@" || true
  return 0
}

_paxel_skill_cmd_main() {
  local home invocations server="${PAXEL_SERVER:-}"
  server="${server%/}"
  case "${1:-}" in
    '') ;;
    -h|--help) _paxel_skill_usage; return 0 ;;
    *)
      printf "warning: unknown skill option '%s'. Nothing was installed.\n" "$1" >&2
      _paxel_skill_usage
      return 1
      ;;
  esac
  home=$(_paxel_skill_home)
  # Files root writes in another account's home would be root's.
  if [ "$(id -u 2>/dev/null)" = 0 ] && [ ! -O "$home" ]; then
    printf 'warning: %s belongs to another account. Run the command as that account. Nothing was installed.\n' "$home" >&2
    return 1
  fi
  _paxel_skill_plan "$home"
  if [ "${#_PX_SKILL_KEYS[@]}" -eq 0 ]; then
    printf 'No coding agent found in %s (looked for %s). Nothing was installed.\n' "$home" "$(_paxel_skill_agent_names)"
    printf 'Any agent can still follow the skill from %s/skills/%s/SKILL.md\n' "$server" "$PAXEL_SKILL_NAME"
    return 0
  fi
  if ! _paxel_skill_install "$home"; then
    printf 'Could not install the %s skill: %s. Nothing was written; run the same command again to retry.\n' "$PAXEL_SKILL_NAME" "$_PX_SKILL_ERR"
    return 0
  fi
  printf 'Agent skill %s (alpha), latest from %s\n' "$PAXEL_SKILL_NAME" "$server"
  _paxel_skill_print_agents "$home"
  invocations=$(_paxel_skill_print_invocations)
  if [ -n "$invocations" ]; then
    printf '\nIt adds the Paxel setup line to whatever provisions your remote dev boxes, once you approve the change. To start it:\n'
    printf '%s\n' "$invocations"
    printf '  %-16s ask "%s"\n' "Any agent" "$PAXEL_SKILL_ASK"
  else
    printf '\nNo agent has the skill to run. Any agent can still follow it from %s/skills/%s/SKILL.md\n' "$server" "$PAXEL_SKILL_NAME"
  fi
  if [ "$_PX_SKILL_PLATFORM" = wsl ]; then
    _paxel_skill_wsl_note "the same command"
  fi
}

_paxel_skill_usage() {
  cat <<'PAXEL_SKILL_USAGE'
Usage: paxel.sh --skill   (or: paxel.sh skill)
  Installs the latest paxel-remote-setup agent skill into the skills folder of
  each coding agent found on this machine, then says how to run it. No Docker,
  no sign-in, no upload.
PAXEL_SKILL_USAGE
}

# One line per agent: its name, the result for its skills folder, the file
# and why it was not written there.
_paxel_skill_print_agents() {
  local home="$1" label i dir invoke file note
  while IFS=$'\t' read -r label i dir invoke; do
    [ -n "$label" ] || continue
    file="$dir/SKILL.md"
    case "$file" in "$home"/*) file="~/${file#"$home"/}" ;; esac
    note="${_PX_SKILL_NOTES[$i]}"
    printf '  %-16s %-13s %s\n' "$label" "${_PX_SKILL_STATES[$i]}" "$file${note:+ ($note)}"
  done <<< "$_PX_SKILL_FOUND"
}

# What to type in each agent that has a skill file to run, a copy it manages
# itself included.
_paxel_skill_print_invocations() {
  local label i dir invoke
  while IFS=$'\t' read -r label i dir invoke; do
    [ -n "$label" ] || continue
    [ "${_PX_SKILL_STATES[$i]}" != "not installed" ] && [ -f "$dir/SKILL.md" ] || continue
    if [ -n "$invoke" ]; then
      printf '  %-16s type %s\n' "$label" "$invoke"
    else
      printf '  %-16s ask with the sentence below\n' "$label"
    fi
  done <<< "$_PX_SKILL_FOUND"
}

_paxel_skill_agent_names() {
  _paxel_skill_agent_table | awk -F'|' '{ printf "%s%s", (NR > 1 ? ", " : ""), $1 }'
}

# --- Platform and paths ---

# macos, linux, wsl or windows (Git Bash, MSYS2 or Cygwin).
_paxel_skill_platform() {
  case "$(uname -s 2>/dev/null)" in
    Darwin) echo macos ;;
    MINGW*|MSYS*|CYGWIN*) echo windows ;;
    *)
      if [ -n "${WSL_DISTRO_NAME:-}" ] || grep -qi microsoft /proc/sys/kernel/osrelease 2>/dev/null; then
        echo wsl
      else
        echo linux
      fi
      ;;
  esac
}

# The home the agents read. Native Windows agents use USERPROFILE, which
# Git Bash's HOME need not match. WSL runs Linux agents, so its HOME wins
# even when USERPROFILE is passed in.
_paxel_skill_home() {
  local profile
  if [ "$(_paxel_skill_platform)" = windows ] && [ -n "${USERPROFILE:-}" ]; then
    profile=$(_paxel_skill_posix_path "$USERPROFILE")
    if [ -d "$profile" ]; then
      printf '%s\n' "$profile"
      return 0
    fi
  fi
  printf '%s\n' "${HOME:-}"
}

# C:\Users\me -> /c/Users/me through cygpath (Cygwin mounts drives under
# /cygdrive). Any other path, or one cygpath cannot convert, is printed as
# it is.
_paxel_skill_posix_path() {
  local path="$1"
  case "$path" in
    [A-Za-z]:|[A-Za-z]:[\\/]*) ;;
    *) printf '%s\n' "$path"; return 0 ;;
  esac
  if command -v cygpath >/dev/null 2>&1 && cygpath -u "$path" 2>/dev/null; then
    return 0
  fi
  printf '%s\n' "$path"
}

# VAR's value as an absolute path, or DEFAULT. Root setting up another
# account ignores its own environment, which says nothing about where that
# account's agents look.
_paxel_skill_env_dir() {
  local value=""
  if [ "${_PX_SETUP_CHOWN:-0}" != 1 ]; then
    value="${!1:-}"
    [ "$_PX_SKILL_PLATFORM" != windows ] || value=$(_paxel_skill_posix_path "$value")
  fi
  case "$value" in
    /*) printf '%s\n' "${value%/}" ;;
    *) printf '%s\n' "$2" ;;
  esac
}

_paxel_skill_appdata() {
  case "$_PX_SKILL_PLATFORM" in
    macos) printf '%s\n' "$1/Library/Application Support" ;;
    windows) _paxel_skill_env_dir APPDATA "$1/AppData/Roaming" ;;
    *) _paxel_skill_env_dir XDG_CONFIG_HOME "$1/.config" ;;
  esac
}

# A table path with its root expanded for HOME_DIR.
_paxel_skill_path() {
  local path="$1" home="$2" root rest
  root="${path%%/*}"
  rest="${path#"$root"}"
  case "$root" in
    "~") root="$home" ;;
    @claude) root=$(_paxel_skill_env_dir CLAUDE_CONFIG_DIR "$home/.claude") ;;
    @codex) root=$(_paxel_skill_env_dir CODEX_HOME "$home/.codex") ;;
    @config) root=$(_paxel_skill_env_dir XDG_CONFIG_HOME "$home/.config") ;;
    @gemini) root=$(_paxel_skill_env_dir GEMINI_CLI_HOME "$home") ;;
    @appdata) root=$(_paxel_skill_appdata "$home") ;;
  esac
  printf '%s%s\n' "$root" "$rest"
}

# The physical path PATH names, when its last folders do not exist yet: a
# ~/.claude/skills link to a ~/.agents/skills that is still missing resolves
# to ~/.agents/skills.
_paxel_skill_resolve() {
  local path="$1" rest="" link hops=0
  case "$path" in /*) ;; *) return 1 ;; esac
  while [ ! -d "$path" ]; do
    if [ -L "$path" ]; then
      hops=$((hops + 1))
      [ "$hops" -le 16 ] || return 1
      link=$(readlink "$path") || return 1
      case "$link" in
        /*) path="$link" ;;
        *) path="${path%/*}/$link" ;;
      esac
      continue
    fi
    [ ! -e "$path" ] || return 1
    rest="/${path##*/}$rest"
    path="${path%/*}"
    [ -n "$path" ] || path=/
  done
  path=$(cd -P -- "$path" 2>/dev/null && pwd -P) || return 1
  printf '%s%s\n' "${path%/}" "$rest"
}

# Status 0 when DIR, below HOME_DIR, has no symlink in the part below the home.
_paxel_skill_unlinked() {
  local dir="$1" home="$2" rest path part
  case "$dir" in "$home"/*) rest="${dir#"$home"/}" ;; *) return 1 ;; esac
  path="$home"
  while [ -n "$rest" ]; do
    part="${rest%%/*}"
    if [ "$part" = "$rest" ]; then rest=""; else rest="${rest#*/}"; fi
    path="$path/$part"
    [ ! -L "$path" ] || return 1
    [ -e "$path" ] || return 0
  done
}

# Status 0 when PATH, or the deepest part of it that exists, belongs to the
# current user.
_paxel_skill_owned() {
  local path="$1"
  case "$path" in /*) ;; *) return 1 ;; esac
  while [ ! -e "$path" ] && [ ! -L "$path" ]; do
    path="${path%/*}"
    [ -n "$path" ] || path=/
  done
  [ -O "$path" ]
}

# --- Plan ---

# Status 0 when one of the folders or commands of a table row is there.
_paxel_skill_detected() {
  local folders="$1" commands="$2" home="$3" item path match
  local -a items=()
  read -r -a items <<< "$folders"
  for item in ${items[@]+"${items[@]}"}; do
    path=$(_paxel_skill_path "$item" "$home")
    case "$path" in
      *'*'*)
        for match in "${path%/*}"/${path##*/}; do
          [ ! -e "$match" ] || return 0
        done
        ;;
      *) [ ! -e "$path" ] || return 0 ;;
    esac
  done
  items=()
  read -r -a items <<< "$commands"
  for item in ${items[@]+"${items[@]}"}; do
    command -v "$item" >/dev/null 2>&1 && return 0
  done
  return 1
}

# Finds the agents installed for HOME_DIR and groups them by the physical
# skill folder they reach, so each folder is written once.
_paxel_skill_plan() {
  local home="$1" label folders commands skills invoke base top dir key i
  _PX_SKILL_KEYS=()
  _PX_SKILL_SHOW=()
  _PX_SKILL_LABELS=()
  _PX_SKILL_REL=()
  _PX_SKILL_LINKED=()
  _PX_SKILL_STATES=()
  _PX_SKILL_NOTES=()
  _PX_SKILL_FOUND=""
  _PX_SKILL_PLATFORM=$(_paxel_skill_platform)
  _PX_SKILL_FOLLOW=0
  [ "${_PX_SETUP_CHOWN:-0}" = 1 ] || [ "$(id -u 2>/dev/null)" = 0 ] || _PX_SKILL_FOLLOW=1
  while IFS='|' read -r label folders commands skills invoke <&3; do
    [ -n "$label" ] || continue
    _paxel_skill_detected "$folders" "$commands" "$home" || continue
    base=$(_paxel_skill_path "$skills" "$home")
    top="$home"
    case "$base" in "$home"/*) ;; *) top=$(_paxel_skill_path "${skills%%/*}" "$home") ;; esac
    dir="$base/$PAXEL_SKILL_NAME"
    if key=$(_paxel_skill_resolve "$dir"); then :; else key="$dir"; fi
    i=$(_paxel_skill_entry_index "$key")
    if [ "$i" -eq "${#_PX_SKILL_KEYS[@]}" ]; then
      _paxel_skill_add_entry "$i" "$key" "$dir" "$label"
    else
      _PX_SKILL_LABELS[$i]="${_PX_SKILL_LABELS[$i]}, $label"
    fi
    _paxel_skill_prefer_path "$i" "$dir" "$home" "$top"
    _PX_SKILL_FOUND="${_PX_SKILL_FOUND}${label}"$'\t'"${i}"$'\t'"${dir}"$'\t'"${invoke}"$'\n'
  done 3<<< "$(_paxel_skill_agent_table)"
}

# The index of the entry for KEY, or the entry count when there is none.
_paxel_skill_entry_index() {
  local i=0
  while [ "$i" -lt "${#_PX_SKILL_KEYS[@]}" ] && [ "${_PX_SKILL_KEYS[$i]}" != "$1" ]; do
    i=$((i + 1))
  done
  printf '%s\n' "$i"
}

_paxel_skill_add_entry() {
  local i="$1"
  _PX_SKILL_KEYS[$i]="$2"
  _PX_SKILL_SHOW[$i]="$3"
  _PX_SKILL_LABELS[$i]="$4"
  _PX_SKILL_STATES[$i]=""
  _PX_SKILL_NOTES[$i]=""
  _PX_SKILL_REL[$i]=""
  _PX_SKILL_LINKED[$i]=1
}

# Shows an entry by a path with no link below TOP, the home or the folder an
# environment variable names (~/.agents/skills rather than a ~/.claude/skills
# link to it). Root writes only an entry with such a path, since a link in
# a home can lead anywhere root can write. As root for another account, the
# path must also be owned by that account or root.
_paxel_skill_prefer_path() {
  local i="$1" dir="$2" home="$3" top="$4" rel
  if [ "$_PX_SKILL_FOLLOW" = 1 ]; then
    _PX_SKILL_REL[$i]="-"
    _paxel_skill_unlinked "$dir" "$top" || return 0
    [ -L "$top" ] || _PX_SKILL_LINKED[$i]=""
    _paxel_skill_unlinked "${_PX_SKILL_SHOW[$i]}" "$home" || _PX_SKILL_SHOW[$i]="$dir"
    return 0
  fi
  [ -z "${_PX_SKILL_REL[$i]}" ] || return 0
  _paxel_skill_unlinked "$dir" "$top" || return 0
  if [ "${_PX_SETUP_CHOWN:-0}" = 1 ]; then
    rel="${dir#"$home"/}"
    HOME="$home" _paxel_setup_safe_dir "$rel" || return 0
    _PX_SKILL_REL[$i]="${rel%/*}"
  else
    _PX_SKILL_REL[$i]="-"
  fi
  _PX_SKILL_SHOW[$i]="$dir"
}

# --- Install ---

# Downloads the skill once and writes every planned entry. Status 1, with
# _PX_SKILL_ERR set and nothing written, when the download fails.
_paxel_skill_install() {
  local home="$1" tmp i=0
  _PX_SKILL_ERR=""
  if ! tmp=$(mktemp "${TMPDIR:-/tmp}/paxel-skill.XXXXXX" 2>/dev/null); then
    _PX_SKILL_ERR="could not create a temp file in ${TMPDIR:-/tmp}"
    return 1
  fi
  _PX_SKILL_TMP="$tmp"
  if ! _paxel_skill_fetch "$tmp"; then
    _paxel_skill_drop_tmp
    return 1
  fi
  while [ "$i" -lt "${#_PX_SKILL_KEYS[@]}" ]; do
    _paxel_skill_write_entry "$tmp" "$i"
    i=$((i + 1))
  done
  _paxel_skill_give_to_owner "$home"
  _paxel_skill_drop_tmp
  return 0
}

# Also the EXIT trap of the upload's skill step and of the store commands,
# so a Ctrl-C during the download leaves no file.
_paxel_skill_drop_tmp() {
  [ -z "$_PX_SKILL_TMP" ] || rm -f "$_PX_SKILL_TMP"
  _PX_SKILL_TMP=""
}

# Agents follow this file's instructions, so it is fetched over HTTPS only
# (plain HTTP is allowed for a local dev server) and checked before use.
_paxel_skill_fetch() {
  local out="$1" url="${PAXEL_SERVER:-}/skills/${PAXEL_SKILL_NAME}/SKILL.md" code=""
  local -a tls=()
  case "${PAXEL_SERVER:-}" in
    https://*) tls=(--proto '=https' --tlsv1.2) ;;
    http://localhost|http://localhost:*|http://127.0.0.1|http://127.0.0.1:*) ;;
    *)
      _PX_SKILL_ERR="${PAXEL_SERVER:-the server} is not HTTPS"
      return 1
      ;;
  esac
  if ! code=$(curl -fsS --compressed --connect-timeout 5 --max-time "$_PX_SKILL_MAX_TIME" ${tls[@]+"${tls[@]}"} \
      -o "$out" -w '%{http_code}' "$url" 2>/dev/null); then
    if [ "${code:-000}" = "000" ]; then
      _PX_SKILL_ERR="no response from ${PAXEL_SERVER}"
    else
      _PX_SKILL_ERR="HTTP ${code} from ${PAXEL_SERVER}"
    fi
    return 1
  fi
  if ! _paxel_skill_valid "$out"; then
    _PX_SKILL_ERR="${url} returned something that is not the skill file"
    return 1
  fi
}

# Frontmatter must open on line 1 and name this skill before it closes.
_paxel_skill_valid() {
  awk -v want="name: ${PAXEL_SKILL_NAME}" '
    NR == 1 && $0 != "---" { exit 1 }
    NR > 1 && $0 == "---" { closed = 1; exit }
    NR > 1 && $0 == want { found = 1 }
    END { if (closed && found) exit 0; exit 1 }
  ' "$1"
}

_paxel_skill_set() {
  _PX_SKILL_STATES[$1]="$2"
  _PX_SKILL_NOTES[$1]="${3:-}"
}

# Writes entry I through its physical path. A user's own links are followed
# into a folder they own; root follows none. A folder an agent reaches with
# no link is the agent's own, whoever owns it. A linked SKILL.md is left alone
# for everyone: the user keeps that file elsewhere on purpose.
_paxel_skill_write_entry() {
  local src="$1" i="$2" dir target tmp state=created
  dir="${_PX_SKILL_KEYS[$i]}"
  target="$dir/SKILL.md"
  if [ -z "${_PX_SKILL_REL[$i]}" ] && [ "${_PX_SETUP_CHOWN:-0}" = 1 ]; then
    _paxel_skill_set "$i" "left alone" "a symlink or another account's folder; running as root, setup does not write through it"
    return 0
  fi
  if [ -z "${_PX_SKILL_REL[$i]}" ] || [ -L "$dir" ] || [ -L "$target" ]; then
    _paxel_skill_set "$i" "left alone" "a symlink, managed outside Paxel"
    return 0
  fi
  if [ "$_PX_SKILL_FOLLOW" = 1 ] && [ -n "${_PX_SKILL_LINKED[$i]}" ] && ! _paxel_skill_owned "$dir"; then
    _paxel_skill_set "$i" "left alone" "it leads to a folder you do not own"
    return 0
  fi
  if ! mkdir -p "$dir" 2>/dev/null; then
    _paxel_skill_set "$i" "not installed" "could not create ${dir}"
    return 0
  fi
  if [ -f "$target" ] && cmp -s "$src" "$target"; then
    _paxel_skill_set "$i" unchanged
    return 0
  fi
  if [ -e "$target" ]; then state=updated; fi
  if _paxel_skill_account_dir "$dir"; then
    if _paxel_skill_write_as_account "$src" "$dir"; then
      _paxel_skill_set "$i" "$state"
    else
      _paxel_skill_set "$i" "not installed" "could not write it as ${_PX_SETUP_USER}"
    fi
    return 0
  fi
  if ! tmp=$(mktemp "${dir}/.SKILL.md.XXXXXX" 2>/dev/null); then
    _paxel_skill_set "$i" "not installed" "could not write it"
    return 0
  fi
  # mv replaces a link to a file swapped in at SKILL.md.
  if cat "$src" > "$tmp" 2>/dev/null && chmod 644 "$tmp" 2>/dev/null && mv -f "$tmp" "$target" 2>/dev/null; then
    _paxel_skill_set "$i" "$state"
  else
    rm -f "$tmp" 2>/dev/null || true
    _paxel_skill_set "$i" "not installed" "could not write it"
  fi
}

# As root for another account, a skill folder that account already owns is
# written as the account: it can swap names in its own folder, and root
# writing by name would follow a link swapped in. The file then belongs to
# the account as well.
_paxel_skill_account_dir() {
  [ "${_PX_SETUP_CHOWN:-0}" = 1 ] && [ -z "$(find "$1" -maxdepth 0 -user 0 -print 2>/dev/null)" ]
}

_paxel_skill_write_as_account() {
  local src="$1" dir="$2"
  local -a runner=()
  if command -v runuser >/dev/null 2>&1; then
    runner=(runuser -u "$_PX_SETUP_USER" --)
  elif command -v sudo >/dev/null 2>&1; then
    runner=(sudo -n -H -u "$_PX_SETUP_USER" --)
  else
    return 1
  fi
  "${runner[@]}" sh -c 'tmp=$(mktemp "$1/.SKILL.md.XXXXXX") || exit 1
    if cat > "$tmp" && chmod 644 "$tmp" && mv -f "$tmp" "$1/SKILL.md"; then exit 0; fi
    rm -f "$tmp"
    exit 1' sh "$dir" < "$src" 2>/dev/null
}

# Root running setup for --user NAME: a root-owned ~/.claude would stop the
# agent from writing its own settings and history there.
_paxel_skill_give_to_owner() {
  local home_dir="$1" uid gid i=0
  [ "${_PX_SETUP_CHOWN:-0}" = 1 ] || return 0
  uid=$(id -u "$_PX_SETUP_USER" 2>/dev/null) || return 0
  gid=$(id -g "$_PX_SETUP_USER" 2>/dev/null) || return 0
  paxel_is_uint "$uid" && paxel_is_uint "$gid" || return 0
  while [ "$i" -lt "${#_PX_SKILL_KEYS[@]}" ]; do
    if [ -n "${_PX_SKILL_REL[$i]}" ]; then
      (
        cd -P -- "$home_dir" 2>/dev/null || exit 0
        set -f
        IFS=/
        # shellcheck disable=SC2086
        set -- ${_PX_SKILL_REL[$i]}
        IFS=$' \t\n'
        _paxel_skill_chown_walk "$uid:$gid" "$@" "$PAXEL_SKILL_NAME" SKILL.md
      ) || true
    fi
    i=$((i + 1))
  done
}

# Hands OWNER the root-owned parts of the path NAME/REST... below the current
# folder, deepest first. The user can swap any entry in a folder they own,
# so each folder is entered with cd and handed over as ".", never by path. A
# symlink is followed only into a folder the user already owns: a link into
# root's own files (~/.claude -> /root/.claude) must not give them away.
_paxel_skill_chown_walk() {
  local owner="$1" name="$2" here
  shift 2
  if [ ! -e "$name" ]; then return 0; fi
  if [ ! -d "$name" ]; then
    if [ ! -L "$name" ] && [ -O . ] && [ -O "$name" ]; then chown -h "$owner" "$name" 2>/dev/null || true; fi
    return 0
  fi
  (
    here=$(pwd -P)
    cd -P -- "$name" 2>/dev/null || exit 0
    if [ -O . ]; then
      [ "$(pwd -P)" = "${here%/}/${name}" ] || exit 0
    else
      [ "$(ls -ldn . | awk '{ print $3 }')" = "${owner%%:*}" ] || exit 0
    fi
    if [ $# -gt 0 ]; then _paxel_skill_chown_walk "$owner" "$@"; fi
    if [ -O . ]; then chown -h "$owner" . 2>/dev/null || true; fi
  ) || true
}


# --- Main ---

# Store commands and the skill install own their exit and error handling:
# the upload's ERR banner sends users to support email, and its EXIT trap
# deletes the shared ~/.paxel/git_metrics.txt that a concurrent upload may
# be reading.
case "${1:-}" in
  setup|push|status|skill|--skill|create-store|--create-store)
    _paxel_cmd="${1#--}"
    shift
    trap - ERR
    trap '[ -n "${_RMDC_LOG_FILE:-}" ] && rm -f "$_RMDC_LOG_FILE"; _paxel_skill_drop_tmp' EXIT
    # Hook-started workers inherit the agent's environment, and setup or status
    # can run inside a git hook or an alias; a GIT_DIR from there would point
    # store and repo git calls at the wrong repository.
    unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY \
      GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_NAMESPACE 2>/dev/null || true
    # A provisioning line can run a script from before these commands
    # existed; setup must never fail it.
    if ! declare -F "paxel_cmd_${_paxel_cmd//-/_}" >/dev/null; then
      printf 'paxel %s is not available in this version of the script.\n' "$_paxel_cmd" >&2
      [ "$_paxel_cmd" = setup ] && exit 0
      exit 1
    fi
    # Setup finds or installs jq once it knows whose home it writes to.
    [ "$_paxel_cmd" = setup ] || paxel_use_own_jq
    "paxel_cmd_${_paxel_cmd//-/_}" "$@"
    exit $?
    ;;
  upload)
    shift
    ;;
esac

while [ $# -gt 0 ]; do
  case "$1" in
    --project)
      PROJECT_NAME="$2"
      shift 2
      ;;
    --since)
      SINCE_EPOCH=$(parse_since "$2")
      shift 2
      ;;
    --all)
      ALL_PROJECTS=1
      shift
      ;;
    --no-repo)
      NO_REPO=1
      shift
      ;;
    --with-repo)
      # On by default now. Kept for backward compatibility.
      shift
      ;;
    --clean)
      CLEAN=1
      shift
      ;;
    --no-sentry)
      NO_SENTRY=1
      shift
      ;;
    --commits)
      COMMIT_LIMIT="$2"
      shift 2
      ;;
    --no-orphan-recovery)
      PAXEL_NO_ORPHAN_RECOVERY=1
      export PAXEL_NO_ORPHAN_RECOVERY
      shift
      ;;
    --clear-cache)
      # Clear legacy v1 (raw git URLs) and current v2 (normalized) caches.
      _cleared=0
      for _cache_file in \
        "$HOME/.paxel/cache/project-remotes.tsv" \
        "$HOME/.paxel/cache/project-remotes-v2.tsv"; do
        if [ -f "$_cache_file" ]; then
          rm -f "$_cache_file"
          echo "[paxel] Cleared project-remotes cache ($_cache_file)" >&2
          _cleared=$((_cleared + 1))
        fi
      done
      [ "$_cleared" -eq 0 ] && echo "[paxel] No project-remotes cache to clear" >&2
      unset _cache_file _cleared
      shift
      ;;
    --clear-pending)
      _pending_dir="$HOME/.paxel/data/pending-uploads"
      if [ -d "$_pending_dir" ]; then
        _count=$(find "$_pending_dir" -type f \( -name '*.json*' -o -name '*.meta.json' -o -name '*.error.json' \) 2>/dev/null | wc -l | tr -d ' ')
        rm -rf "$_pending_dir"
        echo "[paxel] Cleared $_count pending upload artifact(s)" >&2
      else
        echo "[paxel] No pending uploads to clear" >&2
      fi
      unset _pending_dir _count
      exit 0
      ;;
    --resume-pending)
      PAXEL_RESUME_PENDING_ONLY=1
      export PAXEL_RESUME_PENDING_ONLY
      shift
      ;;
    --no-replay)
      PAXEL_SKIP_REPLAY=1
      export PAXEL_SKIP_REPLAY
      shift
      ;;
    --verbose)
      PAXEL_LIST_SESSIONS=1
      shift
      ;;
    --no-skill)
      PAXEL_NO_SKILL=1
      shift
      ;;
    *)
      echo "Unknown option: $1"
      echo "Usage: $0 [--project NAME] [--since DURATION] [--commits N] [--all] [--no-repo] [--no-sentry] [--clean] [--no-orphan-recovery] [--clear-cache] [--clear-pending] [--resume-pending] [--no-replay] [--verbose] [--no-skill]"
      echo "  or:  $0 --skill   (install or update only the paxel-remote-setup agent skill)"
      echo "  or:  $(rerun_cmd '[OPTIONS]')"
      exit 1
      ;;
  esac
done

# Docker mode. File bodies stay local; aggregate metrics + metadata
# (paths, commit numstat, session events) upload. See /data-handling.
run_docker_mode
# paxel-script-end
