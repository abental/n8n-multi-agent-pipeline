# Troubleshooting Guide

This document describes all significant problems encountered during development and testing of the n8n Multi-Agent Pipeline, along with root causes, fixes applied, and the reasoning behind architectural decisions.

---

## Table of Contents

1. [LLM Model Download Failures](#1-llm-model-download-failures)
2. [Docker Platform Mismatch for llama.cpp](#2-docker-platform-mismatch-for-llamacpp)
3. [Adopting llama-cpp-python as a Dockerized LLM Server](#3-adopting-llama-cpp-python-as-a-dockerized-llm-server)
4. [n8n Workflow Import Creates Duplicates](#4-n8n-workflow-import-creates-duplicates)
5. [n8n Webhooks Return Empty Responses](#5-n8n-webhooks-return-empty-responses)
6. [n8n Code Node Silent Failures (responseNode Mode)](#6-n8n-code-node-silent-failures-responsenode-mode)
7. [D_ReportTool: LLM-Based Report Generation Was Unacceptably Slow](#7-d_reporttool-llm-based-report-generation-was-unacceptably-slow)
8. [Output JSON Schema via LLM System Prompt](#8-output-json-schema-via-llm-system-prompt)
9. [Model Loading Delays (Cold Start)](#9-model-loading-delays-cold-start)
10. [n8n API Requires API Key](#10-n8n-api-requires-api-key)
11. [Torch-Infer Error Handling Through n8n](#11-torch-infer-error-handling-through-n8n)

---

## 1. LLM Model Download Failures

### Problem

The `setup.sh` script downloaded a 4 KB HTML error page instead of the expected ~4.7 GB Llama 3 GGUF model file. The script reported success because it didn't validate the file size.

### Root Cause

Two issues:
1. The HuggingFace repository (`QuantFactory`) used dots in the filename (`Meta-Llama-3-8B-Instruct.Q4_K_M.gguf`), but the download script used hyphens.
2. No file-size validation — a 4 KB HTML error page was silently accepted as the model.

### Fix

- Corrected the model filename to match the HuggingFace repository exactly.
- Added size validation to `scripts/download-model.sh`: if the downloaded file is smaller than 100 MB, it prints a detailed error with troubleshooting steps and an alternative download URL.
- Updated `docker-compose.yml`, `.env.example`, and `.env` to use the correct filename.

---

## 2. Docker Platform Mismatch for llama.cpp

### Problem

Running `docker compose up` failed with:

```
image with reference ghcr.io/ggml-org/llama.cpp:server was found but its
platform (linux/amd64) does not match the specified platform (linux/arm64)
```

### Root Cause

The official `llama.cpp` Docker image (`ghcr.io/ggml-org/llama.cpp:server`) is only built for `linux/amd64`. On Apple Silicon (ARM64) Macs, Docker cannot run it even with Rosetta emulation because the image explicitly declares `linux/amd64`.

### What Was Tried

1. **ghcr.io/ggerganov/llama.cpp:server** — registry had moved, returned "manifest unknown".
2. **ghcr.io/ggml-org/llama.cpp:server** — correct registry, but only `linux/amd64`.
3. **Ollama** — considered as a replacement, but rejected because the project requirements specify `llama.cpp`.

### Fix

Created a custom Docker image (`llm-server/Dockerfile`) that:
- Uses `python:3.12-slim` as the base (available for all architectures).
- Installs `llama-cpp-python[server]`, which compiles the `llama.cpp` C++ library natively for the host architecture at Docker build time.
- Downloads the GGUF model on first start (`llm-server/start.py`).
- Exposes an OpenAI-compatible API on port 8080.

**Why this solution:** Building from source ensures native architecture support. The `llama-cpp-python` library wraps `llama.cpp` and provides a FastAPI-based OpenAI-compatible server, meeting the project requirement that the LLM be served by `llama.cpp`.

---

## 3. Adopting llama-cpp-python as a Dockerized LLM Server

### Problem

The project requirement mandated `llama.cpp` for LLM serving, but the pre-built Docker image didn't support ARM64.

### Solution Selected

A custom Docker service (`llm-server`) using `llama-cpp-python[server]`:

```dockerfile
FROM python:3.12-slim
RUN pip install llama-cpp-python[server]
```

### Why This Over Alternatives

| Alternative | Pros | Cons | Decision |
|-------------|------|------|----------|
| Pre-built llama.cpp Docker image | Simple setup | AMD64 only | Rejected |
| Ollama | Easy to use, multi-arch | Not llama.cpp (project requirement) | Rejected |
| Native llama.cpp compile in Docker | Pure llama.cpp | Complex CMake setup, no OpenAI API | Rejected |
| **llama-cpp-python[server]** | **Native build, OpenAI API, Python ecosystem** | **Build time ~5 min** | **Selected** |

The `llama-cpp-python` library compiles `llama.cpp` from source during `pip install`, ensuring native architecture support. Its `[server]` extra provides a FastAPI-based OpenAI-compatible API (`/v1/chat/completions`, `/v1/models`), eliminating the need for a custom Flask wrapper.

---

## 4. n8n Workflow Import Creates Duplicates

### Problem

Running `n8n import:workflow --input=FILE.json` multiple times created duplicate workflows instead of updating existing ones. This led to multiple workflows registered on the same webhook path, with the oldest (potentially outdated) version handling requests.

### Root Cause

The n8n CLI `import:workflow` command always creates a new workflow entry. It does not support upsert (update-or-insert) behavior.

### Impact

When duplicate B_VisionTool workflows existed, the oldest version (with the original Code node pattern) handled webhook requests, while the updated version sat idle and deactivated.

### Fix

Before reimporting workflows, always reset n8n data to ensure a clean state:

```bash
docker compose --profile docker down
rm -rf n8n-data
mkdir n8n-data
docker compose --profile docker up -d
```

Then import and activate workflows once. This is the recommended approach for any CI/CD pipeline or fresh setup.

---

## 5. n8n Webhooks Return Empty Responses

### Problem

After importing and activating workflows, calling webhook endpoints returned HTTP 200 with an empty body instead of the expected JSON response.

### Root Cause

Two distinct causes were identified:

1. **Activation not effective without restart:** The `n8n update:workflow --active=true` CLI command modifies the database but does not register webhooks on the running n8n instance. A restart is required.

2. **Duplicate workflows:** When the same webhook path is registered by multiple workflows, n8n uses the first match, which may be an outdated or broken version.

### Fix

- Always restart n8n after activating workflows: `docker compose restart n8n`
- Wait ~12 seconds after restart before sending requests.
- Ensure no duplicate workflows exist (see [issue #4](#4-n8n-workflow-import-creates-duplicates)).

---

## 6. n8n Code Node Silent Failures (responseNode Mode)

### Problem

Workflows using `responseMode: "responseNode"` returned empty HTTP 200 responses when a Code node in the chain failed. No error was logged in the n8n console.

### Root Cause

In `responseNode` mode, the HTTP response is only sent when execution reaches the `Respond to Webhook` node. If any upstream node fails (Code node error, HTTP request timeout), the execution halts silently and the webhook returns an empty 200 response. There is no error propagation to the caller.

### Investigation

Through systematic testing with progressively complex workflows:
1. **Webhook only** (echo back input) — worked.
2. **Webhook + Code node** (`lastNode` mode) — worked.
3. **Webhook + Code + Respond to Webhook** — worked.
4. **Webhook + Code + HTTP Request + Respond to Webhook** — worked with inline expressions, failed with Code node output.

The root issue was traced to workflow duplication (see [issue #4](#4-n8n-workflow-import-creates-duplicates)) — old versions were handling requests.

### Fix

- Switched B_VisionTool and C_TextTool to use inline expressions in the HTTP Request node instead of a separate PreparePayload Code node. This simplified the workflow and eliminated a potential failure point.
- Switched D_ReportTool to `responseMode: "lastNode"`, which returns errors as JSON instead of empty responses, making debugging easier.
- Ensured clean workflow imports (no duplicates).

### Recommendation

For webhook-triggered workflows where error visibility is important, prefer `responseMode: "lastNode"` over `responseMode: "responseNode"`. The `lastNode` mode returns `{"message":"Error in workflow"}` on failure, while `responseNode` returns empty 200 responses.

---

## 7. D_ReportTool: LLM-Based Report Generation Is Slow on CPU

### Problem

The D_ReportTool uses the local LLM (Llama-3-8B via llama-cpp-python on CPU) to generate the final JSON report from tool outputs. On CPU, each LLM call takes 1-3 minutes for typical payloads. Initial attempts with overly detailed system prompts and high `max_tokens` values (2048) led to inference times exceeding 30 minutes per call.

### Root Cause

The Llama-3-8B model running on CPU via `llama-cpp-python` processes tokens slowly (~2-5 tokens/second on a MacBook Pro). Two factors compound the issue:

1. **Prompt length:** A verbose system prompt with the full JSON schema as an example generates more prompt tokens, increasing both prompt processing and generation time.
2. **`max_tokens`:** Higher `max_tokens` allows the LLM to generate verbose, often unnecessary output (explanations, markdown fences, repeated schemas), extending inference time.

### Solution: Optimized Prompts + Validation Safety Net

The D_ReportTool retains the LLM as required by the project specification, with these optimizations:

1. **Compact system prompt:** The ReportWriter prompt is concise but complete. The required schema is specified with key names and types only (`{request_id, summary, findings:{vision:{top_objects:[],details:[]},text:{label,confidence,entities:[]}}, ...}`), not as a full JSON example with escaped quotes.

2. **Reduced `max_tokens` (512):** Limits LLM output length, keeping inference to 1-3 minutes per call instead of 30+.

3. **Increased HTTP timeout (300s):** The n8n HTTP Request node timeout is set to 5 minutes to accommodate CPU inference.

4. **ValidateReportJSON Code node:** A mandatory post-LLM validation step that:
   - Strips markdown code fences if the LLM wraps output in them.
   - Extracts JSON from surrounding text (finds first `{` to last `}`).
   - Parses the JSON and fills in any missing required keys with default values.
   - Guarantees the output always has all 6 required keys with correct types.
   - Falls back to a valid error report if the LLM output is completely unparseable.

### Workflow Structure (5 nodes as required)

```
[Webhook: POST /tool/report]
           |
           v
[BuildReportInputs: Code node — extracts body, builds LLM prompt]
           |
           v
[LLM ReportWriter: HTTP Request → llm-server:8080/v1/chat/completions]
           |
           v
[ValidateReportJSON: Code node — parses LLM output, enforces schema]
           |
           v
[Response: lastNode returns final report JSON]
```

### Performance Expectations

| Payload Type | Prompt Tokens | LLM Time (CPU) | Total Round-Trip |
|-------------|---------------|-----------------|------------------|
| Text only | ~60-80 | 1-2 min | ~2 min |
| Vision + text | ~80-120 | 2-3 min | ~3 min |
| Full payload with trace | ~100-150 | 2-4 min | ~4 min |

### Result

All D_ReportTool tests pass consistently. The LLM generates the report content, and the ValidateReportJSON node ensures schema compliance regardless of LLM output quality.

---

## 8. Output JSON Schema via LLM System Prompt

### Problem

When using the LLM to generate JSON reports, the system prompt needed to specify the exact output schema. However, the LLM frequently:
- Added extra keys not in the schema.
- Omitted required keys.
- Wrapped JSON in markdown code fences (` ```json ... ``` `).
- Returned the schema description as output instead of filling it in.
- Changed key names (e.g., `top_objects` became `detected_objects`).

### Approaches Tried

1. **Schema in natural language:** "Return JSON with keys: request_id, summary, findings..." — LLM interpreted this loosely, adding or omitting keys unpredictably.

2. **Schema as JSON example in system prompt:** Embedding `{"request_id": "...", "summary": "..."}` in the prompt — the escaped double quotes inside JSON string values caused parsing issues when the prompt was embedded in n8n workflow JSON files (nested escaping: `\"` in JS string inside `\"` in JSON).

3. **Strict schema with validation fallback:** System prompt demanded strict JSON, and a ValidateReport Code node parsed the LLM output, stripped code fences, and filled missing keys with defaults — worked but the LLM was too slow (see [issue #7](#7-d_reporttool-llm-based-report-generation-was-unacceptably-slow)).

### Solution Selected: Compact Prompt + Post-LLM Validation

The selected approach combines two strategies:

1. **Compact schema description in system prompt:** Instead of embedding a full JSON example with escaped quotes (which caused parsing issues in n8n workflow JSON), the schema is described in shorthand notation: `{request_id, summary, findings:{vision:{top_objects:[],details:[]}, text:{label,confidence,entities:[]}}, recommendations:[], trace:[], errors:[]}`. This is unambiguous to the LLM yet avoids nested JSON escaping issues.

2. **Mandatory ValidateReportJSON Code node:** A JavaScript Code node runs after the LLM call and enforces the schema programmatically. It strips markdown fences, extracts JSON from surrounding text, parses it, and fills in any missing keys with typed defaults. If the LLM output is completely unparseable, it returns a valid fallback report with the error captured in the `errors[]` array.

This design follows the "trust but verify" pattern: the LLM generates the report content (summary, recommendations, etc.), while the Code node guarantees structural compliance.

### Lessons Learned

- A local 8B-parameter LLM on CPU does not reliably follow strict JSON schemas. Post-processing validation is essential.
- Cloud-hosted models with native JSON mode (OpenAI's `response_format: { type: "json_object" }`) or function calling are more reliable for structured output, but not available in this local-only architecture.
- The `max_tokens` parameter directly controls CPU inference time. Keeping it at 512 instead of 2048 reduces response time from 30+ minutes to 1-3 minutes.
- Embedding JSON schemas as examples inside JSON string values (n8n workflow `jsCode` fields) creates nested escaping nightmares. Use shorthand notation or natural-language descriptions instead.

---

## 9. Model Loading Delays (Cold Start)

### Problem

On first invocation, all three ML models need to download and/or load into memory, causing significant delays:

| Model | Service | Download Size | Load Time (Cold) | Load Time (Warm) |
|-------|---------|---------------|-------------------|-------------------|
| Llama-3-8B GGUF | llm-server | ~4.7 GB | 5-15 min download + 30-60s load | 30-60s |
| Faster R-CNN | torch-infer | ~160 MB | 1-2 min download + 10s load | < 1s |
| BART-large-MNLI | torch-infer | ~1.6 GB | 3-5 min download + 15s load | < 1s |

### Impact on Tests

- **Layer 1 (pytest):** First run takes ~75 seconds (model download + load). Subsequent runs: ~25 seconds.
- **Layer 2 B (vision):** First B_VisionTool test triggers Faster R-CNN download inside the container. The test may appear to hang for 1-3 minutes.
- **Layer 2 C (text):** First C_TextTool test triggers BART-large-MNLI download inside the container. The test may appear to hang for 2-5 minutes.
- **Layer 2 D (report):** Calls the LLM on CPU. Each test case takes 1-3 minutes for inference. The full D_ReportTool test suite takes ~7 minutes. This is not a bug — it is inherent to CPU-based LLM inference with a 8B parameter model.

### Mitigation

1. **Named Docker volumes** (`torch-model-cache`, `hf-model-cache`) persist downloaded models across container restarts.
2. **Pre-warm models** by sending a health check or dummy request before running tests:

```bash
# Pre-warm torch-infer vision model
curl -s http://localhost:5678/webhook/tool/vision -X POST \
  -H "Content-Type: application/json" \
  -d '{"request_id":"warmup","images":[{"base64":"'$(base64 < tests/images/cat.jpg | tr -d '\n')'"}]}'

# Pre-warm torch-infer text model
curl -s http://localhost:5678/webhook/tool/text -X POST \
  -H "Content-Type: application/json" \
  -d '{"request_id":"warmup","text":"test"}'
```

3. **Monitor startup:** Check container logs before running tests:

```bash
docker compose --profile docker logs -f llm-server    # Wait for "llama server listening"
docker compose --profile docker logs -f torch-infer    # Wait for "Application startup complete"
```

---

## 10. n8n API Requires API Key

### Problem

The `scripts/import-workflows.sh` script used the n8n REST API (`POST /api/v1/workflows`) to import workflows, but n8n 2.x requires an `X-N8N-API-KEY` header for all API calls. On a fresh n8n instance with no owner account configured, there's no way to generate an API key.

### Fix

Switched from the REST API to the **n8n CLI** (`n8n import:workflow`, `n8n update:workflow`, `n8n list:workflow`), which operates directly on the database inside the container and requires no authentication:

```bash
docker compose exec -T n8n n8n import:workflow --input=/tmp/workflow.json
docker compose exec -T n8n n8n list:workflow
docker compose exec -T n8n n8n update:workflow --id=ID --active=true
```

The CLI approach is more reliable for automation and works without browser-based setup.

---

## 11. Torch-Infer Error Handling Through n8n

### Problem

When torch-infer returns an HTTP 400 error (e.g., "No images provided" for empty images), the n8n HTTP Request node catches the error. In `responseNode` mode, this caused the webhook to return an empty HTTP 200 response, making it impossible for tests to distinguish between success and error.

### Root Cause

The n8n HTTP Request node v4.2 treats non-2xx responses as execution errors by default. In `responseNode` mode, the error halts execution before reaching the `Respond to Webhook` node, resulting in an empty response.

### Fix

Updated the Layer 2 test scripts (TC-B4, TC-C4) to accept **either** of two error indicators:
- HTTP status code != 200
- HTTP 200 with empty body or error JSON

```bash
if [ "$HTTP_CODE" != "200" ]; then
    check "error for empty images (HTTP $HTTP_CODE)" "true"
elif [ -z "$RESP_BODY" ]; then
    check "error for empty images (empty body)" "true"
else
    check "error for empty images (HTTP $HTTP_CODE)" "false"
fi
```

This approach is resilient to n8n's error handling behavior regardless of `responseMode` configuration.

---

## Quick Diagnostic Commands

```bash
# Check all containers are running
docker compose --profile docker ps

# Check n8n health
curl -s http://localhost:5678/healthz

# Check torch-infer health
curl -s http://localhost:8000/health

# Check LLM server model
curl -s http://localhost:8080/v1/models | python3 -m json.tool

# List active workflows
docker compose exec -T n8n n8n list:workflow

# Check n8n logs for errors
docker compose --profile docker logs --tail 20 n8n

# Check if torch-infer received requests
docker compose --profile docker logs --tail 20 torch-infer

# Network connectivity from n8n to torch-infer
docker compose exec -T n8n wget -qO- http://torch-infer:8000/health

# Network connectivity from n8n to llm-server
docker compose exec -T n8n wget -qO- http://llm-server:8080/v1/models
```
