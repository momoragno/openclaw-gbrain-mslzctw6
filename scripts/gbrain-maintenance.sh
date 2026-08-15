#!/usr/bin/env bash

set -uo pipefail

log() { echo "[gbrain-maintenance] $*"; }

ROOT_DIR="${ALPHACLAW_ROOT_DIR:-/data}"
GBRAIN_PARENT="${GBRAIN_HOME:-$ROOT_DIR}"
REPO_PATH="${GBRAIN_REPO_PATH:-$ROOT_DIR/brain}"
SOURCE_ID="${GBRAIN_SOURCE_ID:-default}"
STATE_DIR="${GBRAIN_MAINTENANCE_STATE_DIR:-$GBRAIN_PARENT/.gbrain/maintenance}"
LOCK_DIR="$STATE_DIR/lock"
NOTIFIER="${GBRAIN_TELEGRAM_ALERT_SCRIPT:-/app/scripts/telegram-alert.mjs}"
MIN_HEALTH_SCORE="${GBRAIN_HEALTH_MIN_SCORE:-10}"

mkdir -p "$STATE_DIR"

acquire_lock() {
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    echo "$$" > "$LOCK_DIR/pid"
    return 0
  fi

  local existing_pid=""
  if [ -f "$LOCK_DIR/pid" ]; then
    existing_pid="$(sed -n '1p' "$LOCK_DIR/pid" 2>/dev/null || true)"
  fi
  if [ -n "$existing_pid" ] && kill -0 "$existing_pid" 2>/dev/null; then
    log "another maintenance cycle is already running (pid $existing_pid); skipping"
    return 1
  fi

  log "recovering stale maintenance lock"
  rm -f "$LOCK_DIR/pid"
  rmdir "$LOCK_DIR" 2>/dev/null || return 1
  mkdir "$LOCK_DIR"
  echo "$$" > "$LOCK_DIR/pid"
}

release_lock() {
  rm -f "$LOCK_DIR/pid"
  rmdir "$LOCK_DIR" 2>/dev/null || true
}

if ! acquire_lock; then
  exit 0
fi
trap release_lock EXIT INT TERM

RUN_LOG="$(mktemp "$STATE_DIR/run.XXXXXX")"
FAILURES=()

run_step() {
  local name="$1"
  shift
  log "$name"
  {
    echo
    echo "## $name"
    "$@"
  } >> "$RUN_LOG" 2>&1
  local status=$?
  if [ "$status" -ne 0 ]; then
    FAILURES+=("$name (exit $status)")
  fi
  return "$status"
}

notify_problem() {
  local message="$1"
  if [ ! -f "$NOTIFIER" ]; then
    log "Telegram notifier unavailable at $NOTIFIER"
    return 1
  fi
  printf '%s' "$message" | node "$NOTIFIER"
}

STARTED_AT="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
{
  echo "GBrain maintenance"
  echo "started_at=$STARTED_AT"
  echo "repo=$REPO_PATH"
} > "$RUN_LOG"

if [ ! -d "$REPO_PATH/.git" ]; then
  FAILURES+=("brain repository missing at $REPO_PATH")
else
  DIRTY_STATE="$(git -C "$REPO_PATH" status --porcelain 2>> "$RUN_LOG" || true)"
  if [ -n "$DIRTY_STATE" ]; then
    FAILURES+=("brain repository has uncommitted changes")
    {
      echo
      echo "## git status"
      printf '%s\n' "$DIRTY_STATE"
    } >> "$RUN_LOG"
  else
    run_step "git pull (fast-forward only)" git -C "$REPO_PATH" pull --ff-only origin main || true
  fi
fi

BASE_HEAD=""
DREAM_WORKTREE=""
if [ "${#FAILURES[@]}" -eq 0 ]; then
  BASE_HEAD="$(git -C "$REPO_PATH" rev-parse HEAD 2>> "$RUN_LOG" || true)"
  if [ -z "$BASE_HEAD" ]; then
    FAILURES+=("could not resolve brain repository HEAD")
  fi
fi

# Run file-producing phases in an isolated worktree. Telegram/OpenClaw can
# still write to the canonical checkout while maintenance is running; keeping
# generated files separate prevents `git add --all` from ever capturing those
# concurrent user-authored changes.
if [ "${#FAILURES[@]}" -eq 0 ]; then
  DREAM_WORKTREE="$(mktemp -d "$STATE_DIR/dream-worktree.XXXXXX")"
  rmdir "$DREAM_WORKTREE"
  run_step "create isolated dream worktree" \
    git -C "$REPO_PATH" worktree add --detach "$DREAM_WORKTREE" "$BASE_HEAD" || true
fi

# GBrain's native one-shot cycle is the source of truth for nightly
# maintenance. On PGLite it is safer than a long-lived autopilot process:
# each command opens the embedded database, completes, and releases the file
# lock before OpenClaw needs it again.
if [ "${#FAILURES[@]}" -eq 0 ]; then
  run_step "gbrain dream" \
    gbrain dream --json --dir "$DREAM_WORKTREE" --source "$SOURCE_ID" || true
fi

# Dream's extract phase is incremental to pages changed during that cycle.
# Clear any extraction backlog that predates the cycle before enforcing the
# strict zero-stale-pages health gate.
if [ "${#FAILURES[@]}" -eq 0 ]; then
  run_step "gbrain stale extraction catch-up" \
    gbrain extract --stale --source-id "$SOURCE_ID" --catch-up --json || true
fi

if [ "${#FAILURES[@]}" -eq 0 ]; then
  run_step "gbrain doctor" gbrain doctor --json || true
fi

HEALTH_OUTPUT=""
if HEALTH_OUTPUT="$(gbrain health 2>&1)"; then
  {
    echo
    echo "## gbrain health"
    printf '%s\n' "$HEALTH_OUTPUT"
  } >> "$RUN_LOG"
else
  health_status=$?
  FAILURES+=("gbrain health (exit $health_status)")
  {
    echo
    echo "## gbrain health"
    printf '%s\n' "$HEALTH_OUTPUT"
  } >> "$RUN_LOG"
fi

HEALTH_SCORE="$(printf '%s\n' "$HEALTH_OUTPUT" | sed -nE 's/^Health score: ([0-9]+)\/10$/\1/p' | head -n1)"
MISSING_EMBEDDINGS="$(printf '%s\n' "$HEALTH_OUTPUT" | sed -nE 's/^Missing embeddings: ([0-9]+)$/\1/p' | head -n1)"
STALE_PAGES="$(printf '%s\n' "$HEALTH_OUTPUT" | sed -nE 's/^Stale pages: ([0-9]+)$/\1/p' | head -n1)"

if [ -z "$HEALTH_SCORE" ]; then
  FAILURES+=("health score unavailable")
elif [ "$HEALTH_SCORE" -lt "$MIN_HEALTH_SCORE" ]; then
  FAILURES+=("health score ${HEALTH_SCORE}/10 (minimum ${MIN_HEALTH_SCORE}/10)")
fi
if [ -n "$MISSING_EMBEDDINGS" ] && [ "$MISSING_EMBEDDINGS" -gt 0 ]; then
  FAILURES+=("$MISSING_EMBEDDINGS missing embedding(s)")
fi
if [ -n "$STALE_PAGES" ] && [ "$STALE_PAGES" -gt 0 ]; then
  FAILURES+=("$STALE_PAGES stale page(s)")
fi

# The dream cycle can repair lint, backlinks, and synthesized pages on disk.
# Only publish those changes after doctor and health both pass, so generated
# knowledge never crosses into the canonical repository before validation.
# Fast-forward the canonical checkout only if no agent changed it meanwhile.
if [ "${#FAILURES[@]}" -eq 0 ]; then
  if [ -n "$(git -C "$DREAM_WORKTREE" status --porcelain 2>> "$RUN_LOG" || true)" ]; then
    run_step "stage validated dream cycle changes" git -C "$DREAM_WORKTREE" add --all || true
    if [ "${#FAILURES[@]}" -eq 0 ]; then
      DREAM_DATE="$(TZ="${GBRAIN_MAINTENANCE_TZ:-Europe/Rome}" date +%F)"
      run_step "commit validated dream cycle changes" \
        git -C "$DREAM_WORKTREE" \
          -c user.name="${GBRAIN_GIT_AUTHOR_NAME:-MomoBrain}" \
          -c user.email="${GBRAIN_GIT_AUTHOR_EMAIL:-momobrain@users.noreply.github.com}" \
          commit -m "gbrain: dream cycle $DREAM_DATE" || true
    fi
  fi
fi

if [ "${#FAILURES[@]}" -eq 0 ]; then
  DREAM_HEAD="$(git -C "$DREAM_WORKTREE" rev-parse HEAD 2>> "$RUN_LOG" || true)"
  CURRENT_HEAD="$(git -C "$REPO_PATH" rev-parse HEAD 2>> "$RUN_LOG" || true)"
  CURRENT_DIRTY="$(git -C "$REPO_PATH" status --porcelain 2>> "$RUN_LOG" || true)"
  if [ "$CURRENT_HEAD" != "$BASE_HEAD" ] || [ -n "$CURRENT_DIRTY" ]; then
    FAILURES+=("canonical brain repository changed during dream cycle")
  elif [ -z "$DREAM_HEAD" ]; then
    FAILURES+=("could not resolve validated dream worktree HEAD")
  elif [ "$DREAM_HEAD" != "$BASE_HEAD" ]; then
    run_step "fast-forward canonical brain checkout" \
      git -C "$REPO_PATH" merge --ff-only "$DREAM_HEAD" || true
  fi
fi

# Push even when this cycle made no new commit. This retries a previous
# maintenance commit whose push failed after the local commit succeeded.
if [ "${#FAILURES[@]}" -eq 0 ]; then
  run_step "push validated dream cycle changes" git -C "$REPO_PATH" push origin HEAD:main || true
fi

# A clean worktree is disposable even when the network push failed: the
# canonical checkout already holds the commit and the next cycle retries it.
# Dirty worktrees are preserved on failures for operator inspection.
if [ -n "$DREAM_WORKTREE" ] && [ -d "$DREAM_WORKTREE" ]; then
  DREAM_DIRTY="$(git -C "$DREAM_WORKTREE" status --porcelain 2>/dev/null || true)"
  if [ -z "$DREAM_DIRTY" ] \
    && [ -n "${DREAM_HEAD:-}" ] \
    && git -C "$REPO_PATH" merge-base --is-ancestor "$DREAM_HEAD" HEAD 2>/dev/null; then
    git -C "$REPO_PATH" worktree remove "$DREAM_WORKTREE" >> "$RUN_LOG" 2>&1 || true
  elif [ "${#FAILURES[@]}" -gt 0 ]; then
    FAILURES+=("dream worktree preserved for recovery at $DREAM_WORKTREE")
  fi
fi

cp "$RUN_LOG" "$STATE_DIR/last-run.log"
rm -f "$RUN_LOG"

if [ "${#FAILURES[@]}" -gt 0 ]; then
  FAILURE_SUMMARY="$(printf '%s; ' "${FAILURES[@]}")"
  FAILURE_SUMMARY="${FAILURE_SUMMARY%; }"
  printf -v ALERT '⚠️ Momobrain maintenance requires attention\n\n%s\n\nHealth: %s/10 · missing embeddings: %s · stale pages: %s\n\nThe full diagnostic is stored in %s/last-run.log.' \
    "$FAILURE_SUMMARY" "${HEALTH_SCORE:-unknown}" "${MISSING_EMBEDDINGS:-unknown}" "${STALE_PAGES:-unknown}" "$STATE_DIR"
  log "$FAILURE_SUMMARY"
  notify_problem "$ALERT" || log "Telegram alert could not be delivered"
  exit 1
fi

FINISHED_AT="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
printf 'finished_at=%s\nhealth_score=%s\n' "$FINISHED_AT" "${HEALTH_SCORE:-unknown}" > "$STATE_DIR/last-success.txt"
log "completed successfully (health ${HEALTH_SCORE:-unknown}/10); no notification sent"
