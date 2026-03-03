#!/usr/bin/env bash
# ============================================================================
# End-to-end test: Image-only analysis through A_Orchestrator
# Requires: All services running (n8n, llm-server, Torch-Infer), all workflows active.
# Usage:    bash tests/test_image_only.sh [N8N_BASE_URL]
# ============================================================================
set -euo pipefail

N8N_BASE_URL="${1:-${N8N_BASE_URL:-http://localhost:5678}}"
OUTPUT_FILE="$(dirname "$0")/expected/image_only_output.json"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
IMAGES_DIR="${SCRIPT_DIR}/images"
TMPFILE=$(mktemp)
trap 'rm -f "$TMPFILE"' EXIT

CAT_B64=$(base64 < "${IMAGES_DIR}/cat.jpg" | tr -d '\n')

echo "=== E2E Test: Image Only ==="
echo "Endpoint: ${N8N_BASE_URL}/webhook/analyze"
echo "Image: cat.jpg (base64, $(wc -c < "${IMAGES_DIR}/cat.jpg" | tr -d ' ') bytes)"
echo ""

jq -n --arg b64 "$CAT_B64" '{
    "request_id": "v1",
    "text": "",
    "images": [{"base64": $b64}]
  }' | curl -s -m 900 -X POST "${N8N_BASE_URL}/webhook/analyze" \
  -H "Content-Type: application/json" \
  -d @- > "$TMPFILE"

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
    "summary present and non-empty": isinstance(r.get("summary"), str) and len(r["summary"].strip()) > 0,
    "findings present": "findings" in r,
    "recommendations present and non-empty": isinstance(r.get("recommendations"), list) and len(r["recommendations"]) > 0,
    "trace present": "trace" in r,
    "errors present": "errors" in r,
    "errors is list": isinstance(r.get("errors"), list),
    "findings.vision present": "vision" in r.get("findings", {}),
    "findings.vision.top_objects non-empty": len(
        r.get("findings", {}).get("vision", {}).get("top_objects", [])
    ) > 0,
    "trace has orchestrator step": any(
        t.get("step") == "orchestrator" for t in r.get("trace", []) if isinstance(t, dict)
    ),
    "trace mentions vision_tool": any(
        t.get("tool") == "vision_tool" for t in r.get("trace", []) if isinstance(t, dict)
    ),
    "trace mentions report_tool": any(
        t.get("tool") == "report_tool" for t in r.get("trace", []) if isinstance(t, dict)
    ),
    "trace does NOT mention text_tool": not any(
        t.get("tool") == "text_tool" for t in r.get("trace", []) if isinstance(t, dict)
    ),
}

all_pass = True
for name, ok in checks.items():
    status = "PASS" if ok else "FAIL"
    if not ok:
        all_pass = False
    print(f"  [{status}] {name}")

sys.exit(0 if all_pass else 1)
PYEOF
