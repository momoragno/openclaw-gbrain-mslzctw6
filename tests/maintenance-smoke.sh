#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

mkdir -p "$TEST_ROOT/bin" "$TEST_ROOT/brain/.git" "$TEST_ROOT/state"

cat > "$TEST_ROOT/bin/git" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *"status --porcelain"* ]]; then
  if [[ "$*" == *"dream-worktree"* ]] && [ ! -f "$GIT_COMMITTED" ]; then
    echo " M people/momo.md"
  fi
  exit 0
fi
if [[ "$*" == *"pull --ff-only origin main"* ]]; then
  echo "Already up to date."
  exit 0
fi
if [[ "$*" == *"rev-parse HEAD"* ]]; then
  if [[ "$*" == *"dream-worktree"* ]] && [ -f "$GIT_COMMITTED" ]; then
    echo "fedcba9876543210fedcba9876543210fedcba98"
  else
    echo "0123456789abcdef0123456789abcdef01234567"
  fi
  exit 0
fi
if [[ "$*" == *"worktree add --detach"* ]]; then
  worktree_path="${@: -2:1}"
  mkdir -p "$worktree_path"
  printf '%s\n' "$*" >> "$GIT_CALL_CAPTURE"
  exit 0
fi
if [[ "$*" == *"worktree remove"* ]]; then
  rmdir "${@: -1}" 2>/dev/null || true
  printf '%s\n' "$*" >> "$GIT_CALL_CAPTURE"
  exit 0
fi
if [[ "$*" == *"merge-base --is-ancestor"* ]]; then
  exit 0
fi
if [[ "$*" == *"merge --ff-only"* ]]; then
  printf '%s\n' "$*" >> "$GIT_CALL_CAPTURE"
  exit 0
fi
if [[ "$*" == *"push origin HEAD:main"* ]]; then
  printf '%s\n' "$*" >> "$GIT_CALL_CAPTURE"
  echo "Everything up-to-date"
  exit 0
fi
if [[ "$*" == *" add --all"* ]]; then
  printf '%s\n' "$*" >> "$GIT_CALL_CAPTURE"
  exit 0
fi
if [[ "$*" == *" commit -m "* ]]; then
  touch "$GIT_COMMITTED"
  printf '%s\n' "$*" >> "$GIT_CALL_CAPTURE"
  exit 0
fi
exit 1
EOF

cat > "$TEST_ROOT/bin/gbrain" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  dream)
    printf '%s\n' "$*" >> "$GBRAIN_CALL_CAPTURE"
    echo '{"status":"clean","phases":[]}'
    ;;
  extract)
    printf '%s\n' "$*" >> "$GBRAIN_CALL_CAPTURE"
    touch "$GBRAIN_EXTRACT_CAUGHT_UP"
    echo '{"action":"extract_stale_done","pages_processed":2,"stale_remaining":0}'
    ;;
  doctor)
    printf '%s\n' "$*" >> "$GBRAIN_CALL_CAPTURE"
    echo '{"status":"ok","checks":[]}'
    ;;
  health)
    if [ -f "$GBRAIN_EXTRACT_CAUGHT_UP" ]; then
      stale_pages=0
      health_score="${GBRAIN_TEST_HEALTH_SCORE:-10}"
    else
      stale_pages=2
      health_score=9
    fi
    echo "Health score: $health_score/10"
    echo "Embed coverage: 100.0%"
    echo "Missing embeddings: 0"
    echo "Stale pages: $stale_pages"
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
export GBRAIN_CALL_CAPTURE="$TEST_ROOT/gbrain-calls.txt"
export GBRAIN_EXTRACT_CAUGHT_UP="$TEST_ROOT/extract-caught-up"
export GIT_CALL_CAPTURE="$TEST_ROOT/git-calls.txt"
export GIT_COMMITTED="$TEST_ROOT/git-committed"

"$REPO_ROOT/scripts/gbrain-maintenance.sh"
test -f "$TEST_ROOT/state/last-success.txt"
test ! -f "$TEST_ROOT/alert.txt"
grep -Eq "dream --json --dir $TEST_ROOT/state/dream-worktree\.[^ ]+ --source default" "$GBRAIN_CALL_CAPTURE"
grep -q "extract --stale --source-id default --catch-up --json" "$GBRAIN_CALL_CAPTURE"
grep -q "doctor --json" "$GBRAIN_CALL_CAPTURE"
grep -q "add --all" "$GIT_CALL_CAPTURE"
grep -q "commit -m gbrain: dream cycle" "$GIT_CALL_CAPTURE"
grep -q "push origin HEAD:main" "$GIT_CALL_CAPTURE"
grep -q "worktree add --detach" "$GIT_CALL_CAPTURE"
grep -q "merge --ff-only" "$GIT_CALL_CAPTURE"

export GBRAIN_TEST_HEALTH_SCORE=9
if "$REPO_ROOT/scripts/gbrain-maintenance.sh"; then
  echo "expected degraded health to fail" >&2
  exit 1
fi
grep -q "health score 9/10" "$TEST_ROOT/alert.txt"
test "$(grep -c "push origin HEAD:main" "$GIT_CALL_CAPTURE")" -eq 1
test "$(grep -c "commit -m gbrain: dream cycle" "$GIT_CALL_CAPTURE")" -eq 1

echo "maintenance smoke test passed"
