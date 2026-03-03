#!/usr/bin/env bash
# ============================================================================
# Integration tests for sub-workflow B: B_VisionTool
# Requires: n8n running, B_VisionTool imported & active, Torch-Infer running.
# Usage:    bash tests/test_b_vision_tool.sh [N8N_BASE_URL]
# ============================================================================
set -euo pipefail

N8N_BASE_URL="${1:-${N8N_BASE_URL:-http://localhost:5678}}"
ENDPOINT="${N8N_BASE_URL}/webhook/tool/vision"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
IMAGES_DIR="${SCRIPT_DIR}/images"
PASS=0; FAIL=0

b64_file() { base64 < "$1" | tr -d '\n'; }

CAT_B64=$(b64_file "${IMAGES_DIR}/cat.jpg")
DOG_B64=$(b64_file "${IMAGES_DIR}/dog.jpg")
BICYCLE_B64=$(b64_file "${IMAGES_DIR}/bicycle.jpg")
BUS_B64=$(b64_file "${IMAGES_DIR}/bus.jpg")
ANT_B64=$(b64_file "${IMAGES_DIR}/ant.jpg")
COFFEE_B64=$(b64_file "${IMAGES_DIR}/coffee_cup.jpg")

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

# ---------- TC-B1: cat image (base64) ----------
echo "=== TC-B1: cat image (base64) ==="
jq -n --arg b64 "$CAT_B64" '{"request_id":"b1","images":[{"base64":$b64}]}' \
  | curl -s -X POST "$ENDPOINT" -H "Content-Type: application/json" -d @- > "$TMPFILE"

python3 - "$TMPFILE" << 'PYEOF'
import json, sys
with open(sys.argv[1]) as f: r = json.load(f)
checks = {
    'request_id == b1': r.get('request_id') == 'b1',
    'detections is list': isinstance(r.get('detections'), list),
    'detections[0] has objects': len(r.get('detections',[])) > 0 and 'objects' in r['detections'][0],
    'model is string': isinstance(r.get('model'), str),
    'detected cat': any(
        obj['label'] == 'cat' for det in r.get('detections',[]) for obj in det.get('objects',[])
    ),
}
for name, ok in checks.items():
    print(f'  [{"PASS" if ok else "FAIL"}] {name}')
    if not ok: sys.exit(1)
PYEOF
((PASS+=5)) || ((FAIL+=5))
echo ""

# ---------- TC-B2: dog image (base64) ----------
echo "=== TC-B2: dog image (base64) ==="
jq -n --arg b64 "$DOG_B64" '{"request_id":"b2","images":[{"base64":$b64}]}' \
  | curl -s -X POST "$ENDPOINT" -H "Content-Type: application/json" -d @- > "$TMPFILE"

python3 - "$TMPFILE" << 'PYEOF'
import json, sys
with open(sys.argv[1]) as f: r = json.load(f)
checks = {
    'request_id == b2': r.get('request_id') == 'b2',
    'detections[0].image_index == 0': len(r.get('detections',[])) > 0 and r['detections'][0].get('image_index') == 0,
    'detected dog': any(
        obj['label'] == 'dog' for det in r.get('detections',[]) for obj in det.get('objects',[])
    ),
}
for name, ok in checks.items():
    print(f'  [{"PASS" if ok else "FAIL"}] {name}')
    if not ok: sys.exit(1)
PYEOF
((PASS+=3)) || ((FAIL+=3))
echo ""

# ---------- TC-B3: multiple images (bicycle + bus) ----------
echo "=== TC-B3: multiple images (bicycle + bus) ==="
jq -n --arg b1 "$BICYCLE_B64" --arg b2 "$BUS_B64" \
  '{"request_id":"b3","images":[{"base64":$b1},{"base64":$b2}]}' \
  | curl -s -X POST "$ENDPOINT" -H "Content-Type: application/json" -d @- > "$TMPFILE"

python3 - "$TMPFILE" << 'PYEOF'
import json, sys
with open(sys.argv[1]) as f: r = json.load(f)
dets = r.get('detections', [])
checks = {
    'len(detections) == 2': len(dets) == 2,
    'image_index 0 and 1': len(dets) == 2 and dets[0]['image_index'] == 0 and dets[1]['image_index'] == 1,
    'bicycle detected in image 0': any(
        obj['label'] == 'bicycle' for obj in dets[0].get('objects',[])
    ) if len(dets) >= 1 else False,
    'bus detected in image 1': any(
        obj['label'] == 'bus' for obj in dets[1].get('objects',[])
    ) if len(dets) >= 2 else False,
}
for name, ok in checks.items():
    print(f'  [{"PASS" if ok else "FAIL"}] {name}')
    if not ok: sys.exit(1)
PYEOF
((PASS+=4)) || ((FAIL+=4))
echo ""

# ---------- TC-B4: empty images (expect error / empty response) ----------
echo "=== TC-B4: empty images ==="
BODY=$(curl -s -w "\n%{http_code}" -X POST "$ENDPOINT" \
  -H "Content-Type: application/json" \
  -d '{"request_id":"b4","images":[]}')
HTTP_CODE=$(echo "$BODY" | tail -1)
RESP_BODY=$(echo "$BODY" | sed '$d')

if [ "$HTTP_CODE" != "200" ]; then
    check "error for empty images (HTTP $HTTP_CODE)" "true"
elif [ -z "$RESP_BODY" ] || echo "$RESP_BODY" | python3 -c "import sys,json; r=json.load(sys.stdin); sys.exit(0 if 'error' in r or 'detail' in r else 1)" 2>/dev/null; then
    check "error for empty images (empty or error body)" "true"
else
    check "error for empty images (HTTP $HTTP_CODE)" "false"
fi
echo ""

# ---------- TC-B5: request_id propagation (ant image) ----------
echo "=== TC-B5: request_id propagation (ant image) ==="
jq -n --arg b64 "$ANT_B64" '{"request_id":"unique-b5-id","images":[{"base64":$b64}]}' \
  | curl -s -X POST "$ENDPOINT" -H "Content-Type: application/json" -d @- > "$TMPFILE"

python3 - "$TMPFILE" << 'PYEOF'
import json, sys
with open(sys.argv[1]) as f: r = json.load(f)
ok = r.get('request_id') == 'unique-b5-id'
print(f'  [{"PASS" if ok else "FAIL"}] request_id propagated correctly')
sys.exit(0 if ok else 1)
PYEOF
((PASS++)) || ((FAIL++))
echo ""

# ---------- TC-B6: coffee cup image ----------
echo "=== TC-B6: coffee cup image ==="
jq -n --arg b64 "$COFFEE_B64" '{"request_id":"b6","images":[{"base64":$b64}]}' \
  | curl -s -X POST "$ENDPOINT" -H "Content-Type: application/json" -d @- > "$TMPFILE"

python3 - "$TMPFILE" << 'PYEOF'
import json, sys
with open(sys.argv[1]) as f: r = json.load(f)
checks = {
    'request_id == b6': r.get('request_id') == 'b6',
    'detections is list': isinstance(r.get('detections'), list),
    'cup detected': any(
        obj['label'] == 'cup' for det in r.get('detections',[]) for obj in det.get('objects',[])
    ),
}
for name, ok in checks.items():
    print(f'  [{"PASS" if ok else "FAIL"}] {name}')
    if not ok: sys.exit(1)
PYEOF
((PASS+=3)) || ((FAIL+=3))
echo ""

# ---------- TC-B7: three images at once (cat + dog + bus) ----------
echo "=== TC-B7: three images at once (cat + dog + bus) ==="
jq -n --arg b1 "$CAT_B64" --arg b2 "$DOG_B64" --arg b3 "$BUS_B64" \
  '{"request_id":"b7","images":[{"base64":$b1},{"base64":$b2},{"base64":$b3}]}' \
  | curl -s -X POST "$ENDPOINT" -H "Content-Type: application/json" -d @- > "$TMPFILE"

python3 - "$TMPFILE" << 'PYEOF'
import json, sys
with open(sys.argv[1]) as f: r = json.load(f)
dets = r.get('detections', [])
checks = {
    'len(detections) == 3': len(dets) == 3,
    'image_index 0, 1, 2': (
        len(dets) == 3
        and dets[0]['image_index'] == 0
        and dets[1]['image_index'] == 1
        and dets[2]['image_index'] == 2
    ),
}
for name, ok in checks.items():
    print(f'  [{"PASS" if ok else "FAIL"}] {name}')
    if not ok: sys.exit(1)
PYEOF
((PASS+=2)) || ((FAIL+=2))
echo ""

# ---------- Summary ----------
echo "==============================="
echo "B_VisionTool: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && echo "ALL TESTS PASSED" || echo "SOME TESTS FAILED"
exit "$FAIL"
