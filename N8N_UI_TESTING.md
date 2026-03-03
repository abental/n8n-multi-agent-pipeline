# Examples for Testing via n8n UI

Use `http://localhost:5678/webhook-test/analyze` to trigger test executions visible in the n8n UI. The `webhook-test` URLs are for manual testing in the n8n editor — you must have the A_Orchestrator workflow open in the editor and the "Listen for Test Event" button active.

## 1. Text-only (safety hazard)

```bash
curl -X POST http://localhost:5678/webhook-test/analyze \
  -H "Content-Type: application/json" \
  -d '{
    "request_id": "demo-text-1",
    "text": "Smoke detected near the engine room, immediate evacuation recommended.",
    "images": []
  }'
```

**Expected behavior:** Calls C_TextTool (text classification) then D_ReportTool (LLM report). Trace should contain `text_tool` and `report_tool`. The text label should be `safety_hazard`.

## 2. Image-only (cat detection)

```bash
curl -X POST http://localhost:5678/webhook-test/analyze \
  -H "Content-Type: application/json" \
  -d "{
    \"request_id\": \"demo-image-1\",
    \"text\": \"\",
    \"images\": [{\"base64\": \"$(base64 < tests/images/cat.jpg | tr -d '\n')\"}]
  }"
```

**Expected behavior:** Calls B_VisionTool (object detection) then D_ReportTool. Trace should contain `vision_tool` and `report_tool`. The vision findings should include `cat` with high confidence.

## 3. Image-only (bus with people)

```bash
curl -X POST http://localhost:5678/webhook-test/analyze \
  -H "Content-Type: application/json" \
  -d "{
    \"request_id\": \"demo-image-2\",
    \"text\": \"\",
    \"images\": [{\"base64\": \"$(base64 < tests/images/bus.jpg | tr -d '\n')\"}]
  }"
```

**Expected behavior:** Detects `bus`, `person`, `car` in vision findings.

## 4. Mixed — text + image (most complete flow)

```bash
curl -X POST http://localhost:5678/webhook-test/analyze \
  -H "Content-Type: application/json" \
  -d "{
    \"request_id\": \"demo-mixed-1\",
    \"text\": \"Check if there are people near the gate.\",
    \"images\": [{\"base64\": \"$(base64 < tests/images/bus.jpg | tr -d '\n')\"}]
  }"
```

**Expected behavior:** Calls all three tools — B_VisionTool, C_TextTool, D_ReportTool. Trace should contain all three. The report combines vision detections (bus, person, car) with text classification.

## 5. Mixed — equipment failure text + dog image

```bash
curl -X POST http://localhost:5678/webhook-test/analyze \
  -H "Content-Type: application/json" \
  -d "{
    \"request_id\": \"demo-mixed-2\",
    \"text\": \"Machine bearing temperature exceeding threshold, possible equipment failure.\",
    \"images\": [{\"base64\": \"$(base64 < tests/images/dog.jpg | tr -d '\n')\"}]
  }"
```

**Expected behavior:** Text classifies as `equipment_failure`, vision detects `dog`. All three tools in trace.

## 6. Text-only (normal operation)

```bash
curl -X POST http://localhost:5678/webhook-test/analyze \
  -H "Content-Type: application/json" \
  -d '{
    "request_id": "demo-text-2",
    "text": "All systems operating normally, routine maintenance completed.",
    "images": []
  }'
```

**Expected behavior:** Text classifies as `normal_operation`. Only `text_tool` and `report_tool` in trace.

## Important notes for n8n UI testing

- **Each request takes 1–3 minutes** because D_ReportTool calls the LLM (Llama 3 8B on CPU).
- In the n8n editor, open the **A_Orchestrator** workflow, click "Test workflow" (the play button), then click "Listen for Test Event" on the Webhook node. This activates `webhook-test` URLs.
- After the request completes, you will see the execution flow in the canvas — each node will show green check marks.
- Go to the **Executions** tab (clock icon in the left sidebar) to see the execution history with timing and output data for each node.
- Sub-workflow executions (B_VisionTool, C_TextTool, D_ReportTool) appear as separate entries in the execution history — you can click into each one to inspect their individual node data.
- All `curl` commands above must be run from the project root directory (`n8n-multi-agent-pipeline/`) so that the relative paths to test images resolve correctly.
