#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

mkdir -p "$TEST_ROOT/bin" "$TEST_ROOT/brain/.git" "$TEST_ROOT/state"

cat > "$TEST_ROOT/bin/git" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *"status --porcelain"* ]]; then
  exit 0
fi
if [[ "$*" == *"pull --ff-only origin main"* ]]; then
  echo "Already up to date."
  exit 0
fi
exit 1
EOF

cat > "$TEST_ROOT/bin/gbrain" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  sync) echo "Synchronized default" ;;
  embed) echo "Embedded 0 chunks (0 stale found)" ;;
  extract) echo "Extracted 0 stale pages" ;;
  health)
    echo "Health score: ${GBRAIN_TEST_HEALTH_SCORE:-10}/10"
    echo "Embed coverage: 100.0%"
    echo "Missing embeddings: 0"
    echo "Stale pages: 0"
    ;;
  *) exit 1 ;;
esac
EOF

cat > "$TEST_ROOT/notifier.mjs" <<'EOF'
import { appendFileSync } from 'node:fs';
const chunks = [];
for await (const chunk of process.stdin) chunks.push(chunk);
appendFileSync(process.env.ALERT_CAPTURE, Buffer.concat(chunks).toString('utf8'));
EOF

chmod +x "$TEST_ROOT/bin/git" "$TEST_ROOT/bin/gbrain"

export PATH="$TEST_ROOT/bin:$PATH"
export GBRAIN_REPO_PATH="$TEST_ROOT/brain"
export GBRAIN_MAINTENANCE_STATE_DIR="$TEST_ROOT/state"
export GBRAIN_TELEGRAM_ALERT_SCRIPT="$TEST_ROOT/notifier.mjs"
export ALERT_CAPTURE="$TEST_ROOT/alert.txt"

"$REPO_ROOT/scripts/gbrain-maintenance.sh"
test -f "$TEST_ROOT/state/last-success.txt"
test ! -f "$TEST_ROOT/alert.txt"

export GBRAIN_TEST_HEALTH_SCORE=9
if "$REPO_ROOT/scripts/gbrain-maintenance.sh"; then
  echo "expected degraded health to fail" >&2
  exit 1
fi
grep -q "health score 9/10" "$TEST_ROOT/alert.txt"

echo "maintenance smoke test passed"

