#!/usr/bin/env bash

set -uo pipefail

log() { echo "[gbrain-maintenance] $*"; }

ROOT_DIR="${ALPHACLAW_ROOT_DIR:-/data}"
GBRAIN_PARENT="${GBRAIN_HOME:-$ROOT_DIR}"
REPO_PATH="${GBRAIN_REPO_PATH:-$ROOT_DIR/brain}"
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

if [ "${#FAILURES[@]}" -eq 0 ]; then
  run_step "gbrain sync" gbrain sync --source default || true
fi
if [ "${#FAILURES[@]}" -eq 0 ]; then
  run_step "gbrain embed stale" gbrain embed --stale || true
fi
if [ "${#FAILURES[@]}" -eq 0 ]; then
  run_step "gbrain extract stale" gbrain extract --stale || true
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
