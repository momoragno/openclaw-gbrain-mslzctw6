#!/usr/bin/env bash

set -uo pipefail

log() { echo "[alert-dispatcher] $*"; }

if [ "${GBRAIN_TELEGRAM_ALERTS:-true}" != "true" ]; then
  log "disabled by GBRAIN_TELEGRAM_ALERTS"
  exit 0
fi

NOTIFIER="${GBRAIN_TELEGRAM_ALERT_SCRIPT:-/app/scripts/telegram-alert.mjs}"
INTERVAL_SECONDS="${GBRAIN_ALERT_DRAIN_INTERVAL_SECONDS:-900}"
export TZ="${GBRAIN_MAINTENANCE_TZ:-Europe/Rome}"

if ! [[ "$INTERVAL_SECONDS" =~ ^[1-9][0-9]*$ ]]; then
  log "invalid GBRAIN_ALERT_DRAIN_INTERVAL_SECONDS: $INTERVAL_SECONDS"
  exit 1
fi
if [ ! -f "$NOTIFIER" ]; then
  log "Telegram notifier unavailable at $NOTIFIER"
  exit 1
fi

log "holding alerts during ${GBRAIN_QUIET_HOURS_START:-23}:00-${GBRAIN_QUIET_HOURS_END:-8}:00 ($TZ)"

while true; do
  node "$NOTIFIER" --drain || log "pending alert delivery failed; retrying"
  sleep "$INTERVAL_SECONDS"
done
