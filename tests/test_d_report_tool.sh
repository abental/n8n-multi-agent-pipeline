#!/usr/bin/env bash
# ============================================================================
# Integration tests for sub-workflow D: D_ReportTool
# Requires: n8n running, D_ReportTool imported & active, llm-server running.
#
# NOTE: D_ReportTool calls the local LLM (llama.cpp on CPU). Each test case
# takes 1-3 minutes. The full suite takes approximately 5-15 minutes.
#
# Usage:    bash tests/test_d_report_tool.sh [N8N_BASE_URL]
# ============================================================================
set -euo pipefail

N8N_BASE_URL="${1:-${N8N_BASE_URL:-http://localhost:5678}}"
ENDPOINT="${N8N_BASE_URL}/webhook/tool/report"
CURL_TIMEOUT=300  # 5 minutes per request (LLM on CPU is slow)
PASS=0; FAIL=0

check() {
    local name="$1" ok="$2"
    if [ "$ok" = "true" ]; then
        echo "  [PASS] $name"; ((PASS++))
    else
        echo "  [FAIL] $name"; ((FAIL++))
    fi
}

TMPFILE=$(mktemp)
trap 'rm -f "$TMPFILE"' EXIT

echo "D_ReportTool tests (LLM-based — each test takes 1-3 min on CPU)"
echo ""

# ---------- TC-D1: full inputs (vision + text) ----------
echo "=== TC-D1: full inputs (vision + text) ==="
echo "  (calling LLM, please wait...)"
curl -s -m "$CURL_TIMEOUT" -X POST "$ENDPOINT" \
  -H "Content-Type: application/json" \
  -d '{
    "request_id": "d1",
    "original_input": {"text": "smoke near machine"},
    "vision_result": {
      "request_id": "d1",
      "detections": [{"image_index": 0, "objects": [{"label": "person", "score": 0.95, "box": [10,20,200,300]}]}],
      "model": "fasterrcnn_resnet50_fpn"
    },
    "text_result": {
      "request_id": "d1",
      "classification": {"label": "maintenance_issue", "confidence": 0.87},
      "model": "facebook/bart-large-mnli"
    },
    "trace": [
      {"step": "tool_call", "tool": "vision_tool"},
      {"step": "tool_call", "tool": "text_tool"}
    ]
  }' > "$TMPFILE"

python3 - "$TMPFILE" << 'PYEOF'
import json, sys
with open(sys.argv[1]) as f:
    raw = f.read().strip()
if not raw:
    print("  [FAIL] empty response from D_ReportTool (LLM may have timed out)")
    sys.exit(1)
try:
    r = json.loads(raw)
except json.JSONDecodeError as e:
    print(f"  [FAIL] invalid JSON: {e}")
    print(f"  Response: {raw[:200]}")
    sys.exit(1)
required = ["request_id", "summary", "findings", "recommendations", "trace", "errors"]
missing = [k for k in required if k not in r]
checks = {
    'all 6 required keys present': len(missing) == 0,
    'request_id is string': isinstance(r.get('request_id'), str),
    'summary is string': isinstance(r.get('summary'), str),
    'findings is dict': isinstance(r.get('findings'), dict),
    'findings.vision exists': 'vision' in r.get('findings', {}),
    'findings.text exists': 'text' in r.get('findings', {}),
    'recommendations is list': isinstance(r.get('recommendations'), list),
    'trace is list': isinstance(r.get('trace'), list),
    'errors is list': isinstance(r.get('errors'), list),
}
for name, ok in checks.items():
    print(f'  [{"PASS" if ok else "FAIL"}] {name}')
    if not ok:
        if missing: print(f'    missing keys: {missing}')
        sys.exit(1)
PYEOF
((PASS+=9)) || ((FAIL+=9))
echo ""

# ---------- TC-D2: text only (no vision result) ----------
echo "=== TC-D2: text only (no vision result) ==="
echo "  (calling LLM, please wait...)"
curl -s -m "$CURL_TIMEOUT" -X POST "$ENDPOINT" \
  -H "Content-Type: application/json" \
  -d '{
    "request_id": "d2",
    "original_input": {"text": "equipment malfunction"},
    "vision_result": null,
    "text_result": {
      "request_id": "d2",
      "classification": {"label": "equipment_failure", "confidence": 0.92},
      "model": "facebook/bart-large-mnli"
    },
    "trace": [{"step": "tool_call", "tool": "text_tool"}]
  }' > "$TMPFILE"

python3 - "$TMPFILE" << 'PYEOF'
import json, sys
with open(sys.argv[1]) as f:
    raw = f.read().strip()
if not raw:
    print("  [FAIL] empty response"); sys.exit(1)
r = json.loads(raw)
required = ["request_id", "summary", "findings", "recommendations", "trace", "errors"]
missing = [k for k in required if k not in r]
checks = {
    'schema valid (all 6 keys)': len(missing) == 0,
    'findings present': isinstance(r.get('findings'), dict),
    'request_id preserved': r.get('request_id') == 'd2',
}
for name, ok in checks.items():
    print(f'  [{"PASS" if ok else "FAIL"}] {name}')
    if not ok: sys.exit(1)
PYEOF
((PASS+=3)) || ((FAIL+=3))
echo ""

# ---------- TC-D3: request_id propagation ----------
echo "=== TC-D3: request_id propagation ==="
echo "  (calling LLM, please wait...)"
curl -s -m "$CURL_TIMEOUT" -X POST "$ENDPOINT" \
  -H "Content-Type: application/json" \
  -d '{
    "request_id": "unique-d3-id",
    "original_input": {"text": "test"},
    "vision_result": null,
    "text_result": {"request_id": "unique-d3-id", "classification": {"label": "normal_operation", "confidence": 0.8}, "model": "test"},
    "trace": []
  }' > "$TMPFILE"

python3 - "$TMPFILE" << 'PYEOF'
import json, sys
with open(sys.argv[1]) as f:
    raw = f.read().strip()
if not raw:
    print("  [FAIL] empty response"); sys.exit(1)
r = json.loads(raw)
ok = r.get('request_id') == 'unique-d3-id'
print(f'  [{"PASS" if ok else "FAIL"}] request_id propagated correctly (got: {r.get("request_id")})')
sys.exit(0 if ok else 1)
PYEOF
((PASS++)) || ((FAIL++))
echo ""

# ---------- Summary ----------
echo "==============================="
echo "D_ReportTool: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && echo "ALL TESTS PASSED" || echo "SOME TESTS FAILED"
exit "$FAIL"
