#!/usr/bin/env bash
# ============================================================================
# End-to-end test: Text-only analysis through A_Orchestrator
# Requires: All services running (n8n, llm-server, Torch-Infer), all workflows active.
# Usage:    bash tests/test_text_only.sh [N8N_BASE_URL]
# ============================================================================
set -euo pipefail

N8N_BASE_URL="${1:-${N8N_BASE_URL:-http://localhost:5678}}"
OUTPUT_FILE="$(dirname "$0")/expected/text_only_output.json"
TMPFILE=$(mktemp)
trap 'rm -f "$TMPFILE"' EXIT

echo "=== E2E Test: Text Only ==="
echo "Endpoint: ${N8N_BASE_URL}/webhook/analyze"
echo ""

curl -s -m 600 -X POST "${N8N_BASE_URL}/webhook/analyze" \
  -H "Content-Type: application/json" \
  -d '{
    "request_id": "t1",
    "text": "There is smoke near the machine.",
    "images": []
  }' > "$TMPFILE"

python3 -m json.tool < "$TMPFILE" 2>/dev/null || cat "$TMPFILE"

mkdir -p "$(dirname "$OUTPUT_FILE")"
cp "$TMPFILE" "$OUTPUT_FILE"
echo ""
echo "Output saved to: $OUTPUT_FILE"
echo ""

echo "--- Validation ---"
python3 - "$TMPFILE" << 'PYEOF'
import json, sys

with open(sys.argv[1]) as f:
    raw = f.read()

try:
    r = json.loads(raw)
except Exception:
    print("FAIL: Response is not valid JSON")
    sys.exit(1)

checks = {
    "request_id present": "request_id" in r,
    "summary present": "summary" in r,
    "findings present": "findings" in r,
    "recommendations present": "recommendations" in r,
    "trace present": "trace" in r,
    "errors present": "errors" in r,
    "errors is empty (happy path)": isinstance(r.get("errors"), list) and len(r["errors"]) == 0,
    "trace is non-empty": isinstance(r.get("trace"), list) and len(r["trace"]) > 0,
    "trace mentions text_tool": any(
        t.get("tool") == "text_tool" for t in r.get("trace", []) if isinstance(t, dict)
    ),
    "trace mentions report_tool": any(
        t.get("tool") == "report_tool" for t in r.get("trace", []) if isinstance(t, dict)
    ),
    "trace does NOT mention vision_tool": not any(
        t.get("tool") == "vision_tool" for t in r.get("trace", []) if isinstance(t, dict)
    ),
    "findings.text has label": r.get("findings", {}).get("text", {}).get("label") is not None,
}

all_pass = True
for name, ok in checks.items():
    status = "PASS" if ok else "FAIL"
    if not ok:
        all_pass = False
    print(f"  [{status}] {name}")

sys.exit(0 if all_pass else 1)
PYEOF
