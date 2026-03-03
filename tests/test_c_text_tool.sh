#!/usr/bin/env bash
# ============================================================================
# Integration tests for sub-workflow C: C_TextTool
# Requires: n8n running, C_TextTool imported & active, Torch-Infer running.
# Usage:    bash tests/test_c_text_tool.sh [N8N_BASE_URL]
# ============================================================================
set -euo pipefail

N8N_BASE_URL="${1:-${N8N_BASE_URL:-http://localhost:5678}}"
ENDPOINT="${N8N_BASE_URL}/webhook/tool/text"
PASS=0; FAIL=0

check() {
    local name="$1" ok="$2"
    if [ "$ok" = "true" ]; then
        echo "  [PASS] $name"; ((PASS++))
    else
        echo "  [FAIL] $name"; ((FAIL++))
    fi
}

# ---------- TC-C1: normal text ----------
echo "=== TC-C1: normal text ==="
RESP=$(curl -s -X POST "$ENDPOINT" \
  -H "Content-Type: application/json" \
  -d '{"request_id":"c1","text":"There is smoke near the machine."}')

python3 -c "
import json, sys
r = json.loads('''${RESP}''')
checks = {
    'request_id == c1': r.get('request_id') == 'c1',
    'classification.label is str': isinstance(r.get('classification',{}).get('label'), str),
    'classification.confidence in [0,1]': 0 <= r.get('classification',{}).get('confidence',0) <= 1,
    'model is str': isinstance(r.get('model'), str),
}
for name, ok in checks.items():
    print(f'  [{\"PASS\" if ok else \"FAIL\"}] {name}')
    if not ok: sys.exit(1)
" && ((PASS+=4)) || ((FAIL+=4))
echo ""

# ---------- TC-C2: safety text ----------
echo "=== TC-C2: safety text ==="
RESP=$(curl -s -X POST "$ENDPOINT" \
  -H "Content-Type: application/json" \
  -d '{"request_id":"c2","text":"A worker fell from the scaffolding."}')

python3 -c "
import json, sys
r = json.loads('''${RESP}''')
label = r.get('classification',{}).get('label','')
ok = label == 'safety_hazard'
print(f'  [{\"PASS\" if ok else \"FAIL\"}] label is safety_hazard (got: {label})')
sys.exit(0 if ok else 1)
" && ((PASS++)) || ((FAIL++))
echo ""

# ---------- TC-C3: normal operation ----------
echo "=== TC-C3: normal operation ==="
RESP=$(curl -s -X POST "$ENDPOINT" \
  -H "Content-Type: application/json" \
  -d '{"request_id":"c3","text":"All systems operating within normal parameters."}')

python3 -c "
import json, sys
r = json.loads('''${RESP}''')
label = r.get('classification',{}).get('label','')
ok = label == 'normal_operation'
print(f'  [{\"PASS\" if ok else \"FAIL\"}] label is normal_operation (got: {label})')
sys.exit(0 if ok else 1)
" && ((PASS++)) || ((FAIL++))
echo ""

# ---------- TC-C4: empty text (expect error / empty response) ----------
echo "=== TC-C4: empty text ==="
BODY=$(curl -s -w "\n%{http_code}" -X POST "$ENDPOINT" \
  -H "Content-Type: application/json" \
  -d '{"request_id":"c4","text":""}')
HTTP_CODE=$(echo "$BODY" | tail -1)
RESP_BODY=$(echo "$BODY" | sed '$d')

if [ "$HTTP_CODE" != "200" ]; then
    check "error for empty text (HTTP $HTTP_CODE)" "true"
elif [ -z "$RESP_BODY" ] || echo "$RESP_BODY" | python3 -c "import sys,json; r=json.load(sys.stdin); sys.exit(0 if 'error' in r or 'detail' in r else 1)" 2>/dev/null; then
    check "error for empty text (empty or error body)" "true"
else
    check "error for empty text (HTTP $HTTP_CODE)" "false"
fi
echo ""

# ---------- TC-C5: request_id propagation ----------
echo "=== TC-C5: request_id propagation ==="
RESP=$(curl -s -X POST "$ENDPOINT" \
  -H "Content-Type: application/json" \
  -d '{"request_id":"unique-c5-id","text":"Test propagation."}')

python3 -c "
import json, sys
r = json.loads('''${RESP}''')
ok = r.get('request_id') == 'unique-c5-id'
print(f'  [{\"PASS\" if ok else \"FAIL\"}] request_id propagated correctly')
sys.exit(0 if ok else 1)
" && ((PASS++)) || ((FAIL++))
echo ""

# ---------- Summary ----------
echo "==============================="
echo "C_TextTool: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && echo "ALL TESTS PASSED" || echo "SOME TESTS FAILED"
exit "$FAIL"
