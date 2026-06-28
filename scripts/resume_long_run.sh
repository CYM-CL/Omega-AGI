#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPORT_DIR="$ROOT/reports"
CHECKPOINT="$REPORT_DIR/checkpoint-meta.json"
TARGET_STEPS="${L3_TARGET_STEPS:-1000000}"

if [[ ! -f "$CHECKPOINT" ]]; then
  echo "resume: missing checkpoint metadata: $CHECKPOINT" >&2
  exit 1
fi

COMPLETED="$(python3 - <<'PY' "$CHECKPOINT"
import json, sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    data = json.load(f)
print(int(data.get("l3_step", 0)))
PY
)"

if [[ "$COMPLETED" -ge "$TARGET_STEPS" ]]; then
  echo "resume: already completed $COMPLETED/$TARGET_STEPS"
  exit 0
fi

REMAINING=$(( TARGET_STEPS - COMPLETED ))
echo "resume: checkpoint completed=$COMPLETED target=$TARGET_STEPS remaining=$REMAINING"
echo "resume: restoring graph-state checkpoint and running remaining L3 steps."

"$ROOT/zig-engine/main" 0 0 "$REMAINING" resume
