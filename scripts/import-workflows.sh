#!/usr/bin/env bash
set -euo pipefail

N8N_BASE_URL="${N8N_BASE_URL:-http://localhost:5678}"
WORKFLOWS_DIR="$(cd "$(dirname "$0")/../n8n-workflows" && pwd)"

echo "n8n base URL: $N8N_BASE_URL"
echo "Workflows dir: $WORKFLOWS_DIR"
echo ""

# n8n requires an owner to be set up before API calls work.
# Check if n8n is reachable.
echo "Checking n8n connectivity..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "${N8N_BASE_URL}/healthz" 2>/dev/null || echo "000")
if [ "$HTTP_CODE" = "000" ]; then
    echo "ERROR: Cannot reach n8n at ${N8N_BASE_URL}"
    echo "Make sure n8n is running: docker compose up -d"
    exit 1
fi
echo "n8n is reachable (HTTP $HTTP_CODE)"
echo ""

# Import order matters: tool workflows first, then orchestrator
WORKFLOW_FILES=(
    "B_VisionTool.json"
    "C_TextTool.json"
    "D_ReportTool.json"
    "A_Orchestrator.json"
)

for wf_file in "${WORKFLOW_FILES[@]}"; do
    filepath="$WORKFLOWS_DIR/$wf_file"
    wf_name=$(echo "$wf_file" | sed 's/.json$//')

    if [ ! -f "$filepath" ]; then
        echo "SKIP: $filepath not found"
        continue
    fi

    echo "Importing $wf_name ..."

    RESPONSE=$(curl -s -X POST \
        "${N8N_BASE_URL}/api/v1/workflows" \
        -H "Content-Type: application/json" \
        -d @"$filepath" 2>&1)

    WF_ID=$(echo "$RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || echo "")

    if [ -z "$WF_ID" ]; then
        echo "  WARNING: Could not extract workflow ID. Response:"
        echo "  $RESPONSE" | head -c 200
        echo ""
        continue
    fi

    echo "  Created workflow ID: $WF_ID"

    # Activate the workflow
    ACTIVATE_RESP=$(curl -s -X PATCH \
        "${N8N_BASE_URL}/api/v1/workflows/${WF_ID}" \
        -H "Content-Type: application/json" \
        -d '{"active": true}' 2>&1)

    ACTIVE=$(echo "$ACTIVATE_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('active',''))" 2>/dev/null || echo "")

    if [ "$ACTIVE" = "True" ] || [ "$ACTIVE" = "true" ]; then
        echo "  Activated successfully"
    else
        echo "  WARNING: Activation may have failed. You can activate it manually in the n8n UI."
    fi

    echo ""
done

echo "Import complete."
echo ""
echo "Verify in the n8n UI: ${N8N_BASE_URL}"
echo ""
echo "Webhook URLs (after activation):"
echo "  POST ${N8N_BASE_URL}/webhook/analyze"
echo "  POST ${N8N_BASE_URL}/webhook/tool/vision"
echo "  POST ${N8N_BASE_URL}/webhook/tool/text"
echo "  POST ${N8N_BASE_URL}/webhook/tool/report"
