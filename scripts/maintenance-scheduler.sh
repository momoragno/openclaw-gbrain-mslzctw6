#!/usr/bin/env bash

set -uo pipefail

log() { echo "[maintenance-scheduler] $*"; }

if [ "${GBRAIN_MAINTENANCE_ENABLED:-true}" != "true" ]; then
  log "disabled by GBRAIN_MAINTENANCE_ENABLED"
  exit 0
fi

MAINTENANCE_TIME="${GBRAIN_MAINTENANCE_TIME:-03:15}"
MAINTENANCE_TZ="${GBRAIN_MAINTENANCE_TZ:-Europe/Rome}"
MAINTENANCE_SCRIPT="${GBRAIN_MAINTENANCE_SCRIPT:-/app/scripts/gbrain-maintenance.sh}"

if ! [[ "$MAINTENANCE_TIME" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
  log "invalid GBRAIN_MAINTENANCE_TIME: $MAINTENANCE_TIME"
  exit 1
fi
if [ ! -x "$MAINTENANCE_SCRIPT" ]; then
  log "maintenance script is not executable: $MAINTENANCE_SCRIPT"
  exit 1
fi

export TZ="$MAINTENANCE_TZ"
log "scheduled daily at $MAINTENANCE_TIME ($MAINTENANCE_TZ)"

while true; do
  now_epoch="$(date +%s)"
  target_epoch="$(date -d "today $MAINTENANCE_TIME" +%s)"
  if [ "$target_epoch" -le "$now_epoch" ]; then
    target_epoch="$(date -d "tomorrow $MAINTENANCE_TIME" +%s)"
  fi
  sleep_seconds=$((target_epoch - now_epoch))
  log "next run at $(date -d "@$target_epoch" -Iseconds)"
  sleep "$sleep_seconds"
  "$MAINTENANCE_SCRIPT" || log "cycle completed with problems"
  sleep 60
done

