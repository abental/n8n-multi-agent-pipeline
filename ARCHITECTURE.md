# Architecture

## Services Overview

The system is composed of three Docker-managed services that communicate over a shared Docker network:

```
Client
  |
  | POST /analyze  { request_id, text, images[], task_type }
  v
+-------------------------------------------------------+
|  n8n  (port 5678)                                     |
|                                                       |
|  Workflow A: A_Orchestrator                           |
|    AI Agent (llama.cpp LLM) decides which tools       |
|    to call, then delegates to sub-workflows:          |
|                                                       |
|    +---> Workflow B: B_VisionTool  ----+              |
|    |                                   |              |
|    +---> Workflow C: C_TextTool   ----+|              |
|    |                                  ||              |
|    +---> Workflow D: D_ReportTool <---+|              |
|                  |                                    |
|                  v                                    |
|           Final JSON Report                           |
+------------|----------|-------------------------------+
             |          |
             v          v
    +-------------+  +-------------------+
    | llm-server  |  |   torch-infer     |
    | (port 8080) |  |   (port 8000)     |
    | llama.cpp   |  |  FastAPI+PyTorch  |
    +-------------+  +-------------------+
```

| Service | Container | Port | Technology | Purpose |
|---|---|---|---|---|
| **n8n** | `n8n` | 5678 | n8n workflow automation | Hosts all 4 workflows, exposes webhooks |
| **llm-server** | `llm-server` | 8080 | `llama-cpp-python` (OpenAI-compatible) | Serves Llama 3 8B Instruct (Q4_K_M) for orchestration and report generation |
| **torch-infer** | `torch-infer` | 8000 | FastAPI + PyTorch + Transformers | Object detection, text classification, entity extraction |

### Inter-Service Communication

- n8n calls `llm-server` at `http://llm-server:8080/v1/chat/completions` (Docker DNS)
- n8n calls `torch-infer` at `http://torch-infer:8000/...` (Docker DNS)
- n8n workflows call each other via `http://localhost:5678/webhook/...` (internal loopback)

---

## n8n Workflows

### Workflow A -- A_Orchestrator

**Webhook:** `POST /analyze`

**Purpose:** Receives the client request, uses an LLM-driven AI Agent to decide which tools to call, and returns the final JSON report.

**Nodes (9 total: 5 main flow + 4 sub-nodes):**

```
Main flow:
  Webhook ──> NormalizeInput ──> OrchestratorAgent ──> FormatResponse ──> Respond to Webhook

Sub-nodes (connected to OrchestratorAgent):
  LlamaCppLLM         ──(ai_languageModel)──> OrchestratorAgent
  call_vision_tool    ──(ai_tool)──────────> OrchestratorAgent
  call_text_tool      ──(ai_tool)──────────> OrchestratorAgent
  call_report_tool    ──(ai_tool)──────────> OrchestratorAgent
```

| Node | Type | Role |
|---|---|---|
| **Webhook** | `n8n-nodes-base.webhook` | Entry point: `POST /analyze` |
| **NormalizeInput** | `n8n-nodes-base.code` | Parses `request_id`, `text`, `images`, `task_type`; computes `has_text` / `has_images` flags |
| **OrchestratorAgent** | `@n8n/n8n-nodes-langchain.agent` | AI Agent (`openAiFunctionsAgent`) that uses the LLM to decide which tools to invoke |
| **LlamaCppLLM** | `@n8n/n8n-nodes-langchain.lmChatOpenAi` | LLM sub-node pointing to `llm-server:8080`, model `Meta-Llama-3-8B-Instruct.Q4_K_M.gguf`, temperature 0 |
| **call_vision_tool** | `@n8n/n8n-nodes-langchain.toolHttpRequest` | Tool: `POST /webhook/tool/vision` with `{request_id, images}` |
| **call_text_tool** | `@n8n/n8n-nodes-langchain.toolHttpRequest` | Tool: `POST /webhook/tool/text` with `{request_id, text}` |
| **call_report_tool** | `@n8n/n8n-nodes-langchain.toolHttpRequest` | Tool: `POST /webhook/tool/report` with `{request_id, original_input, ...}` |
| **FormatResponse** | `n8n-nodes-base.code` | Extracts tool results from Agent's `intermediateSteps`, ensures reliable report generation (see "How It Works" below) |
| **Respond to Webhook** | `n8n-nodes-base.respondToWebhook` | Returns the final JSON report to the client |

#### How It Works

1. **NormalizeInput** parses the incoming request body into a clean structure with boolean flags `has_text` and `has_images`.

2. **OrchestratorAgent** receives the normalized input and presents it to the LLM with the system prompt:
   ```
   You are an orchestration agent.
   You MUST decide which tools to call:
   - If has_images is true -> call call_vision_tool
   - If has_text is true  -> call call_text_tool
   - Always call call_report_tool last.
   ```
   The LLM uses OpenAI-compatible function calling (`CHAT_FORMAT=chatml-function-calling`) to invoke tool sub-nodes. Each tool call triggers an HTTP request to the corresponding sub-workflow.

3. **FormatResponse** acts as a reliability layer after the Agent finishes:
   - Parses the Agent's `intermediateSteps` array to extract actual tool results (`vision_result`, `text_result`, `report_from_agent`)
   - **Fallback:** If the Agent failed to call a required tool (e.g., the LLM returned text instead of a `tool_calls` response), FormatResponse calls the missing tool(s) deterministically via `this.helpers.httpRequest`
   - Builds the `trace` array with an `orchestrator` decision entry and a `tool_call` entry per tool
   - If the Agent produced a valid report with non-empty findings, uses it directly
   - Otherwise, calls `D_ReportTool` with the complete data (vision + text results) to generate the final report
   - If the report tool also fails, returns an error report with the `errors[]` array populated

4. **Respond to Webhook** returns the final JSON report to the caller.

#### Key Design Decisions

- **AI Agent with fallback.** The guideline requires an AI Agent node for LLM-driven tool selection. The local Llama 3 8B model on CPU may not always produce reliable OpenAI-compatible `tool_calls`. The `FormatResponse` node provides a deterministic fallback that guarantees the pipeline always returns a valid report, regardless of the LLM's behavior.
- **`maxIterations: 5`.** Limits the Agent's tool-calling rounds to prevent infinite loops if the LLM repeatedly fails.
- **Temperature 0.** Ensures the LLM makes consistent, deterministic routing decisions.
- **Tool bodies from NormalizeInput.** The vision and text tool sub-nodes build their request bodies from `$('NormalizeInput').first().json`, so the LLM only decides *when* to call each tool -- the payloads are pre-constructed.
- **Report tool limitation.** The `call_report_tool` sub-node cannot include vision/text results in its body (those exist only in the Agent's internal state, not in the workflow's expression context). If the Agent calls it, the report tool receives `null` for both results. `FormatResponse` detects this and re-calls the report tool with complete data.

---

### Workflow B -- B_VisionTool

**Webhook:** `POST /tool/vision`

**Purpose:** Receives images, calls the Torch-Infer vision endpoint, and returns detection results.

**Nodes (4):**

```
Webhook ──> PreparePayload ──> TorchInfer Vision ──> Respond to Webhook
```

| Node | Type | Role |
|---|---|---|
| **Webhook** | `n8n-nodes-base.webhook` | Entry point: `POST /tool/vision` |
| **PreparePayload** | `n8n-nodes-base.code` | Extracts `request_id` and `images` from the webhook body |
| **TorchInfer Vision** | `n8n-nodes-base.httpRequest` | `POST http://torch-infer:8000/vision/detect` (timeout: 120s) |
| **Respond to Webhook** | `n8n-nodes-base.respondToWebhook` | Returns the detection JSON |

---

### Workflow C -- C_TextTool

**Webhook:** `POST /tool/text`

**Purpose:** Receives text, calls Torch-Infer classification and entity extraction, merges both results.

**Nodes (6):**

```
Webhook ──> PreparePayload ──> TorchInfer Classify ──> TorchInfer Extract ──> MergeResults ──> Respond to Webhook
```

| Node | Type | Role |
|---|---|---|
| **Webhook** | `n8n-nodes-base.webhook` | Entry point: `POST /tool/text` |
| **PreparePayload** | `n8n-nodes-base.code` | Extracts `request_id` and `text` |
| **TorchInfer Classify** | `n8n-nodes-base.httpRequest` | `POST http://torch-infer:8000/text/classify` (timeout: 60s) |
| **TorchInfer Extract** | `n8n-nodes-base.httpRequest` | `POST http://torch-infer:8000/text/extract` (timeout: 60s) |
| **MergeResults** | `n8n-nodes-base.code` | Combines `classification` from Classify and `entities` from Extract into a single response |
| **Respond to Webhook** | `n8n-nodes-base.respondToWebhook` | Returns the merged text JSON |

---

### Workflow D -- D_ReportTool

**Webhook:** `POST /tool/report`

**Purpose:** Receives tool outputs, uses the LLM to generate a structured JSON report, then validates/enriches it.

**Nodes (4):**

```
Webhook ──> BuildReportInputs ──> LLM ReportWriter ──> ValidateReportJSON
```

| Node | Type | Role |
|---|---|---|
| **Webhook** | `n8n-nodes-base.webhook` | Entry point: `POST /tool/report` (`responseMode: lastNode`) |
| **BuildReportInputs** | `n8n-nodes-base.code` | Constructs a concise LLM prompt from vision/text results; summarizes detections as `VISION=[bus:1.00,person:0.98]` and classification as `TEXT=safety_hazard:0.34` to reduce token count |
| **LLM ReportWriter** | `n8n-nodes-base.httpRequest` | `POST http://llm-server:8080/v1/chat/completions` (timeout: 600s / 10 min) |
| **ValidateReportJSON** | `n8n-nodes-base.code` | Parses LLM response, strips markdown/code fences, enforces strict schema, fills in missing fields from original tool data |

#### Report Schema Enforcement

`ValidateReportJSON` guarantees every report matches this schema:

```json
{
  "request_id": "...",
  "summary": "Short human-readable summary.",
  "findings": {
    "vision": { "top_objects": ["person", "car"], "details": [] },
    "text": { "label": "safety_hazard", "confidence": 0.87, "entities": ["Plant 3"] }
  },
  "recommendations": ["..."],
  "trace": [
    { "step": "orchestrator", "decision": "called vision+text then report" },
    { "step": "tool_call", "tool": "vision_tool", "status": "ok" },
    { "step": "tool_call", "tool": "text_tool", "status": "ok" },
    { "step": "tool_call", "tool": "report_tool" }
  ],
  "errors": []
}
```

**Fallback logic in ValidateReportJSON:**

| Field | Fallback if LLM omits it |
|---|---|
| `summary` | Generated from tool outputs, e.g. "Vision detected: bus, person. Text classified as safety_hazard (34% confidence)." |
| `findings.vision.top_objects` | Populated from `vision_result.detections[].objects[].label` |
| `findings.text.label` / `confidence` | Populated from `text_result.classification` |
| `findings.text.entities` | Populated from `text_result.entities[].value` |
| `recommendations` | Generated based on classification label (e.g., "Immediate safety review recommended based on text classification.") |
| `trace` | Copied from the input trace array |

---

## Torch-Infer API

**Framework:** FastAPI + PyTorch + HuggingFace Transformers

**Base URL:** `http://torch-infer:8000` (Docker) or `http://localhost:8000` (local)

### Code Structure

```
torch-infer/
  app/
    main.py              # FastAPI app, CORS, health endpoint
    rest/
      apis.py            # API endpoint definitions + Pydantic models
    analyzers/
      image.py           # Faster R-CNN object detection (fasterrcnn_resnet50_fpn)
      text.py            # BART-large-MNLI classification + BERT-base-NER extraction
```

### Endpoints

#### `POST /vision/detect`

**Model:** `fasterrcnn_resnet50_fpn` (torchvision, COCO-pretrained, 91 classes)

| Field | Input | Output |
|---|---|---|
| `request_id` | string (required) | string (echoed) |
| `images` | array of `{url?, base64?}` (required) | -- |
| `detections` | -- | array of `{image_index, objects: [{label, score, box}]}` |
| `model` | -- | `"fasterrcnn_resnet50_fpn"` |
| `notes` | -- | e.g. `"Detected 3 object(s) across 1 image(s): bus, person, car"` |

Objects with a confidence score below 0.5 are filtered out. Images that fail to load (bad URL, invalid base64) return an empty `objects` array for that index.

#### `POST /text/classify`

**Model:** `facebook/bart-large-mnli` (zero-shot classification)

**Candidate labels:** `maintenance_issue`, `safety_hazard`, `normal_operation`, `equipment_failure`, `environmental_concern` (configurable via `TEXT_CANDIDATE_LABELS` env var)

| Field | Input | Output |
|---|---|---|
| `request_id` | string (required) | string (echoed) |
| `text` | string (required, non-empty) | -- |
| `classification` | -- | `{label, confidence}` |
| `model` | -- | `"facebook/bart-large-mnli"` |
| `notes` | -- | e.g. `"Classified as 'safety_hazard' with 34.00% confidence"` |

#### `POST /text/extract`

**Model:** `dslim/bert-base-NER` (token classification, NER)

| Field | Input | Output |
|---|---|---|
| `request_id` | string (required) | string (echoed) |
| `text` | string (required, non-empty) | -- |
| `entities` | -- | array of `{type, value}` (e.g. `{type: "LOC", value: "New York"}`) |
| `keywords` | -- | array of entity value strings |
| `model` | -- | `"dslim/bert-base-NER"` |
| `notes` | -- | e.g. `"Extracted 2 entity(ies) and 2 keyword(s)"` |

#### `GET /health`

Returns `{"status": "ok"}`. No model loading triggered.

### Model Loading

All three ML models (Faster R-CNN, BART-large-MNLI, BERT-base-NER) are loaded lazily on first request. Initial requests take 10-30 seconds while models download and load into memory. Subsequent requests are fast. Docker volumes (`torch-model-cache`, `hf-model-cache`) persist downloaded models across container restarts.

---

## LLM Server

**Image:** Custom Docker build from `llm-server/Dockerfile`

**Library:** `llama-cpp-python` with OpenAI-compatible REST API

**Model:** `Meta-Llama-3-8B-Instruct.Q4_K_M.gguf` (4-bit quantized, ~4.7 GB)

**Endpoints:** OpenAI-compatible at `http://llm-server:8080/v1/chat/completions`

### Configuration

| Env Var | Default | Purpose |
|---|---|---|
| `MODEL_REPO` | `QuantFactory/Meta-Llama-3-8B-Instruct-GGUF` | HuggingFace repository |
| `MODEL_FILE` | `Meta-Llama-3-8B-Instruct.Q4_K_M.gguf` | Model filename |
| `N_CTX` | `4096` | Context window size |
| `N_GPU_LAYERS` | `0` | GPU offload layers (0 = CPU only) |
| `CHAT_FORMAT` | `chatml-function-calling` | Enables OpenAI-compatible function/tool calling |

### Performance Characteristics

Running on CPU, each LLM inference call takes approximately **1-5 minutes** depending on prompt length and `max_tokens`. The model is downloaded on first container start (~4.7 GB) and cached in the `./models` volume. Subsequent starts load from cache.

The LLM is used in two places:
1. **A_Orchestrator** -- Agent's tool-calling decisions (via `lmChatOpenAi` sub-node)
2. **D_ReportTool** -- Report generation (via HTTP Request to `/v1/chat/completions`)

---

## Data Flow

### Request Lifecycle

```
1. Client ──POST /analyze──> A_Orchestrator (Webhook)
2. NormalizeInput: parse request_id, text, images, task_type
3. OrchestratorAgent (LLM decides tools):
   a. If images present ──> call_vision_tool ──> B_VisionTool ──> torch-infer /vision/detect
   b. If text present   ──> call_text_tool   ──> C_TextTool   ──> torch-infer /text/classify + /text/extract
   c. call_report_tool  ──> D_ReportTool     ──> llm-server /v1/chat/completions
4. FormatResponse: extract results, build trace, ensure valid report
5. Respond to Webhook: return final JSON report to client
```

### `request_id` Propagation

The `request_id` is generated (or accepted from input) in `NormalizeInput` and propagated through every tool call and into the final report. Each sub-workflow and Torch-Infer endpoint echoes it back in their response.

### Trace Array

The `trace` array in the final report records every orchestration step:

```json
[
  { "step": "orchestrator", "decision": "called vision+text then report" },
  { "step": "tool_call", "tool": "vision_tool", "status": "ok" },
  { "step": "tool_call", "tool": "text_tool", "status": "ok" },
  { "step": "tool_call", "tool": "report_tool" }
]
```

For text-only input, `vision_tool` is omitted. For image-only input, `text_tool` is omitted. Failed tool calls include `"status": "error"` and an `"error"` message.

---

## Docker Compose Topology

```yaml
services:
  n8n:          # Workflow engine (port 5678)
  llm-server:   # LLM inference (port 8080), n8n depends on this
  torch-infer:  # PyTorch inference (port 8000), profiles: [docker, full]
```

### Volume Mounts

| Volume | Container Path | Purpose |
|---|---|---|
| `./n8n-data` | `/home/node/.n8n` | n8n database, credentials, workflow state |
| `./models` | `/models` | Downloaded LLM model files (persistent cache) |
| `torch-model-cache` | `/root/.cache/torch` | torchvision model weights |
| `hf-model-cache` | `/root/.cache/huggingface` | HuggingFace Transformers model weights |

### Network

All containers share the default Docker Compose network. Inter-container communication uses Docker DNS: `n8n`, `llm-server`, `torch-infer`.

The `torch-infer` service is gated behind Docker Compose profiles (`docker` or `full`). It can alternatively be run locally for debugging:

```bash
cd torch-infer && source .venv/bin/activate && uvicorn app.main:app --host 0.0.0.0 --port 8000
```

---

## n8n Credential: `llama-local-cred`

The AI Agent's LLM sub-node (`LlamaCppLLM`) uses an n8n credential of type `openAiApi`:

| Field | Value |
|---|---|
| **ID** | `llama-local-cred` |
| **Name** | `llama.cpp Local` |
| **Type** | `openAiApi` |
| **API Key** | `sk-local` (any non-empty string; llama-cpp-python ignores it) |
| **Base URL** | `http://llm-server:8080/v1` |

This credential is stored encrypted in `n8n-data/database.sqlite`. The `baseURL` is also set in the `LlamaCppLLM` node's `options.baseURL` as a redundant override.

---

## Error Handling and Robustness

### FormatResponse Fallback Chain

```
1. Agent calls tools via LLM ──> extract results from intermediateSteps
   |
   ├── Agent succeeded? ──> Use Agent's tool results
   └── Agent failed (no tool_calls)? ──> Call tools deterministically via httpRequest
       |
2. Report from Agent valid? (non-empty summary + findings)
   |
   ├── Yes ──> Return Agent's report with enriched trace
   └── No  ──> Call D_ReportTool with complete data
               |
               ├── Report tool succeeded? ──> Return report
               └── Report tool failed? ──> Return error report with errors[] populated
```

### Timeout Configuration

| Call | Timeout | Reason |
|---|---|---|
| Vision tool (Torch-Infer) | 120s | Large images / model loading on first call |
| Text classify (Torch-Infer) | 60s | Text inference is fast |
| Text extract (Torch-Infer) | 60s | NER inference is fast |
| LLM ReportWriter (D_ReportTool) | 600s (10 min) | CPU-based LLM inference is slow |
| Report tool call from A_Orchestrator | 600s (10 min) | Includes LLM inference time |
| E2E curl tests | 600s (10 min) | Accommodates full pipeline latency |
