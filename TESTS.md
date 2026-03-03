# Testing Guide

This document covers how to set up, configure, and run all tests for the n8n Multi-Agent Pipeline.

## Test Architecture

Tests are organized in three layers, from fastest/most-isolated to slowest/most-integrated:

| Layer | Type | Tool | Requires Running Services | Speed |
|-------|------|------|---------------------------|-------|
| 1 | Unit / API | pytest | None (in-process) | ~25s total |
| 2 | Sub-Workflow Integration | curl + bash | n8n, torch-infer, llm-server | ~15s-7min per script |
| 3 | End-to-End Pipeline | curl + bash | All services + all workflows active + LLM credential | ~60s per script |

## Directory Structure

```
tests/
├── conftest.py                   # Shared pytest fixtures (client, base64 images)
├── requirements-test.txt         # pytest + pytest-asyncio + httpx
├── images/                       # Real test images (JPEG)
│   ├── ant.jpg
│   ├── bicycle.jpg
│   ├── bus.jpg
│   ├── cat.jpg
│   ├── coffee_cup.jpg
│   └── dog.jpg
├── rest/
│   ├── __init__.py
│   └── test_apis.py              # Health endpoint test
├── analyzers/
│   ├── __init__.py
│   ├── test_image.py             # Vision detection tests (correctness + robustness)
│   └── test_text.py              # Text classification tests (correctness + robustness)
├── test_b_vision_tool.sh         # Layer 2: B_VisionTool sub-workflow
├── test_c_text_tool.sh           # Layer 2: C_TextTool sub-workflow
├── test_d_report_tool.sh         # Layer 2: D_ReportTool sub-workflow
├── test_text_only.sh             # Layer 3: E2E text-only scenario
├── test_image_only.sh            # Layer 3: E2E image-only scenario
├── test_mixed.sh                 # Layer 3: E2E mixed text+image scenario
└── expected/                     # Auto-generated E2E test output (gitignored)
```

---

## Prerequisites for Layer 2 and 3 Tests

### 1. Start All Docker Services

```bash
docker compose --profile docker up -d
```

Verify all three containers are running:

```bash
docker compose --profile docker ps
```

Expected output shows three containers: `n8n`, `llm-server`, `torch-infer`, all with status `Up`.

### 2. Wait for Model Downloads (First Run Only)

On the first start, the following models download automatically:

| Service | Model | Size | Download Time |
|---------|-------|------|---------------|
| llm-server | Meta-Llama-3-8B-Instruct Q4_K_M (GGUF) | ~4.7 GB | 5-15 min |
| torch-infer | Faster R-CNN ResNet50 FPN (PyTorch) | ~160 MB | 1-2 min |
| torch-infer | BART-large-MNLI (Hugging Face) | ~1.6 GB | 3-5 min |

Monitor download progress:

```bash
# LLM model — wait for "Starting llama.cpp server" or "llama server listening"
docker compose --profile docker logs -f llm-server

# Torch models — download on first request (health check won't trigger it)
# Models download when the first vision/text test runs
```

**Important:** Do NOT run Layer 2/3 tests until `llm-server` shows it has loaded the model. The `torch-infer` models download automatically on first test invocation; the first B_VisionTool test will take 1-3 minutes longer as models load.

### 3. Import and Activate n8n Workflows via CLI

The n8n workflows must be imported and activated before Layer 2/3 tests will work. This is done entirely via the n8n CLI inside the container — no browser or API key needed.

#### Step-by-step

```bash
# Copy workflow files into the n8n container
for wf in B_VisionTool C_TextTool D_ReportTool A_Orchestrator; do
  docker cp n8n-workflows/${wf}.json n8n:/tmp/${wf}.json
done

# Import each workflow
for wf in B_VisionTool C_TextTool D_ReportTool A_Orchestrator; do
  echo -n "${wf}: "
  docker compose exec -T n8n n8n import:workflow --input=/tmp/${wf}.json 2>&1 | tail -1
done

# List workflows to get their IDs
docker compose exec -T n8n n8n list:workflow

# Activate each workflow (replace IDs from the list above)
for wf_id in $(docker compose exec -T n8n n8n list:workflow 2>&1 | cut -d'|' -f1); do
  docker compose exec -T n8n n8n update:workflow --id="$wf_id" --active=true 2>&1 | tail -1
done

# IMPORTANT: Restart n8n for activations to take effect
docker compose restart n8n
```

Wait ~12 seconds after restart, then verify:

```bash
docker compose --profile docker logs --tail 8 n8n | grep "Activated"
```

Expected output:

```
Activated workflow "B_VisionTool" (ID: ...)
Activated workflow "C_TextTool" (ID: ...)
Activated workflow "D_ReportTool" (ID: ...)
Activated workflow "A_Orchestrator" (ID: ...)
```

#### Key CLI commands reference

| Command | Purpose |
|---------|---------|
| `n8n import:workflow --input=/tmp/FILE.json` | Import a workflow JSON file |
| `n8n list:workflow` | List all workflows with IDs |
| `n8n update:workflow --id=ID --active=true` | Activate a workflow (requires restart) |

#### Important notes on workflow import

- Each `import:workflow` call creates a **new** workflow, even if one with the same name exists. If you reimport, **delete the old duplicates** or reset n8n data (`rm -rf n8n-data && mkdir n8n-data`).
- After activating workflows, you **must restart n8n** for the activation to take effect on webhook registration.
- The deprecated `update:workflow` command shows a warning — this is harmless. Use `publish:workflow` if available in your n8n version.
- The n8n REST API requires an API key (`X-N8N-API-KEY`), which is why the CLI approach is preferred for automation.

---

## Layer 1: Unit / API Tests (pytest)

### What these test

These tests exercise the FastAPI endpoints directly in-process using `httpx.ASGITransport`. No running server, no Docker, no network needed. The PyTorch and Hugging Face models load on first invocation and are cached for subsequent tests.

### Environment setup

```bash
cd torch-infer
python3 -m venv .venv
source .venv/bin/activate
pip install --upgrade pip
pip install -r requirements.txt
pip install -r ../tests/requirements-test.txt
```

Dependencies installed by `requirements-test.txt`:

| Package | Version | Purpose |
|---------|---------|---------|
| `pytest` | >= 8.0 | Test runner |
| `pytest-asyncio` | >= 0.24 | Async test support |
| `httpx` | >= 0.28 | Async HTTP client for in-process testing |

### Running the tests

From the project root:

```bash
cd torch-infer
source .venv/bin/activate
pytest ../tests/rest/ ../tests/analyzers/ -v --tb=short
```

Run only image tests:

```bash
pytest ../tests/analyzers/test_image.py -v --tb=short
```

Run only text tests:

```bash
pytest ../tests/analyzers/test_text.py -v --tb=short
```

Run only the REST/health test:

```bash
pytest ../tests/rest/test_apis.py -v --tb=short
```

### Expected output

```
tests/rest/test_apis.py::test_health PASSED                           [  4%]
tests/analyzers/test_image.py::test_vision_detect_base64 PASSED       [  8%]
tests/analyzers/test_image.py::test_vision_detect_response_schema PASSED [ 12%]
...
tests/analyzers/test_text.py::test_text_very_long_text PASSED         [100%]

============================= 24 passed in 25.95s ==============================
```

### Test inventory (24 tests)

#### `tests/rest/test_apis.py` (1 test)

| Test | Input | Expected |
|------|-------|----------|
| `test_health` | `GET /health` | 200, `{"status": "ok"}` |

#### `tests/analyzers/test_image.py` (15 tests)

| Test | Input | Expected |
|------|-------|----------|
| `test_vision_detect_base64` | 10x10 red PNG | 200, has `request_id`, `detections`, `model` |
| `test_vision_detect_response_schema` | 10x10 red PNG | Each object has `label` (str), `score` (0-1), `box` (4 ints) |
| `test_vision_detect_multiple_images` | 2 identical PNGs | `len(detections)==2`, correct `image_index` |
| `test_vision_request_id_propagation` | custom ID | Response `request_id` matches input |
| `test_vision_detect_cat` | `images/cat.jpg` | Detects label `"cat"` |
| `test_vision_detect_dog` | `images/dog.jpg` | Detects label `"dog"` |
| `test_vision_detect_bicycle` | `images/bicycle.jpg` | Detects label `"bicycle"` |
| `test_vision_detect_bus` | `images/bus.jpg` | Detects label `"bus"` |
| `test_vision_detect_multiple_real_images` | cat + dog | Detects `"cat"` in image 0, `"dog"` in image 1 |
| `test_vision_detect_coffee_cup` | `images/coffee_cup.jpg` | Detects label `"cup"` |
| `test_vision_empty_images_returns_400` | `images: []` | 400, `"No images provided"` |
| `test_vision_missing_request_id_returns_422` | no `request_id` field | 422 (Pydantic validation) |
| `test_vision_invalid_url_graceful` | unreachable URL | 200, `objects: []` (graceful degradation) |
| `test_vision_invalid_base64_graceful` | invalid base64 string | 200, `objects: []` (graceful degradation) |
| `test_vision_no_url_no_base64` | `images: [{}]` | 200, `objects: []` (graceful degradation) |

#### `tests/analyzers/test_text.py` (8 tests)

| Test | Input | Expected |
|------|-------|----------|
| `test_text_classify` | `"There is smoke near the machine."` | 200, has `classification.label` and `classification.confidence` in [0,1] |
| `test_text_classify_label_in_candidates` | `"There is smoke near the machine."` | Label is one of the 5 candidate labels |
| `test_text_classify_request_id_propagation` | custom ID | Response `request_id` matches input |
| `test_text_empty_text_returns_400` | `text: ""` | 400, `"Text is empty"` |
| `test_text_whitespace_only_returns_400` | `text: "   "` | 400, `"Text is empty"` |
| `test_text_missing_request_id_returns_422` | no `request_id` field | 422 (Pydantic validation) |
| `test_text_missing_text_field_returns_422` | no `text` field | 422 (Pydantic validation) |
| `test_text_very_long_text` | 25,000 characters | 200, valid classification (no crash) |

### Shared fixtures (`tests/conftest.py`)

| Fixture | Scope | Description |
|---------|-------|-------------|
| `client` | per-test | `httpx.AsyncClient` wired to the FastAPI app via `ASGITransport` |
| `sample_base64_image` | per-test | Synthetic 10x10 red PNG as base64 |
| `sample_request_id` | per-test | Random UUID-based request ID |
| `cat_base64_image` | per-test | `tests/images/cat.jpg` as base64 |
| `dog_base64_image` | per-test | `tests/images/dog.jpg` as base64 |
| `bicycle_base64_image` | per-test | `tests/images/bicycle.jpg` as base64 |
| `bus_base64_image` | per-test | `tests/images/bus.jpg` as base64 |
| `ant_base64_image` | per-test | `tests/images/ant.jpg` as base64 |
| `coffee_cup_base64_image` | per-test | `tests/images/coffee_cup.jpg` as base64 |

---

## Layer 2: Sub-Workflow Integration Tests (curl)

### What these test

Each script tests one n8n sub-workflow independently by sending HTTP requests to its webhook endpoint. The scripts validate response schemas, field values, and edge cases.

### Prerequisites

1. All Docker services running (see [Prerequisites](#prerequisites-for-layer-2-and-3-tests) above)
2. All workflows imported and activated via CLI (see [Import and Activate](#3-import-and-activate-n8n-workflows-via-cli) above)
3. Host tools: `curl`, `jq`, `python3`, `base64`

### Running the tests

From the project root:

```bash
bash tests/test_b_vision_tool.sh
bash tests/test_c_text_tool.sh
bash tests/test_d_report_tool.sh
```

Override the n8n URL (e.g., for a non-default port):

```bash
bash tests/test_b_vision_tool.sh http://localhost:9999
# or
N8N_BASE_URL=http://localhost:9999 bash tests/test_b_vision_tool.sh
```

### Timing expectations

| Script | Cold start (models loading) | Warm (models cached) |
|--------|-----------------------------|----------------------|
| `test_b_vision_tool.sh` | 2-5 min (downloads Faster R-CNN ~160 MB) | ~30-60s |
| `test_c_text_tool.sh` | 1-3 min (downloads BART-large-MNLI ~1.6 GB) | ~15s |
| `test_d_report_tool.sh` | 5-15 min (LLM inference on CPU) | **5-10 min** (LLM inference) |

**Important:** D_ReportTool calls the local LLM (Llama-3-8B on CPU via llama-cpp-python). Each test case takes 1-3 minutes for LLM inference. This is inherent to CPU-based LLM inference and is not a bug. The test script shows progress messages (`calling LLM, please wait...`) while waiting.

### Test inventory

#### `tests/test_b_vision_tool.sh` — B_VisionTool (7 test cases, 19 assertions)

| Test Case | Input | Key Assertions |
|-----------|-------|----------------|
| TC-B1 | cat.jpg (base64) | `request_id` matches, detections list, `"cat"` detected |
| TC-B2 | dog.jpg (base64) | `image_index == 0`, `"dog"` detected |
| TC-B3 | bicycle.jpg + bus.jpg | `len(detections) == 2`, `"bicycle"` in image 0, `"bus"` in image 1 |
| TC-B4 | empty `images: []` | Error response (non-200 or empty body) |
| TC-B5 | ant.jpg, custom ID | `request_id` propagated correctly |
| TC-B6 | coffee_cup.jpg | `"cup"` detected |
| TC-B7 | cat + dog + bus | `len(detections) == 3`, correct `image_index` values |

#### `tests/test_c_text_tool.sh` — C_TextTool (5 test cases, 8 assertions)

| Test Case | Input | Key Assertions |
|-----------|-------|----------------|
| TC-C1 | `"There is smoke near the machine."` | `request_id`, label is string, confidence in [0,1], model present |
| TC-C2 | `"A worker fell from the scaffolding."` | `label == "safety_hazard"` |
| TC-C3 | `"All systems operating within normal parameters."` | `label == "normal_operation"` |
| TC-C4 | `text: ""` (empty) | Error response (non-200 or empty body) |
| TC-C5 | custom ID | `request_id` propagated correctly |

#### `tests/test_d_report_tool.sh` — D_ReportTool (3 test cases, 13 assertions)

D_ReportTool calls the local LLM to generate reports. Each test case invokes `llama.cpp` on CPU, taking 1-3 minutes. The ValidateReportJSON Code node ensures the LLM output conforms to the required 6-key schema regardless of LLM output quality.

| Test Case | Input | Key Assertions |
|-----------|-------|----------------|
| TC-D1 | Full inputs (vision + text results + trace) | All 6 required keys, `findings.vision` and `findings.text` exist, correct types |
| TC-D2 | Text only (`vision_result: null`) | Schema valid, findings present, `request_id` preserved |
| TC-D3 | Custom request_id | `request_id` propagated correctly through LLM pipeline |

---

## Layer 3: End-to-End Pipeline Tests (curl)

### What these test

Each script sends a request to the A_Orchestrator webhook (`/webhook/analyze`) and validates that the full pipeline executes correctly: the AI Agent selects the right tools, calls them via sub-workflows, and returns a properly structured report.

### Prerequisites

Same as Layer 2, plus:
- All four workflows must be active (A_Orchestrator, B_VisionTool, C_TextTool, D_ReportTool)
- **The LLM credential must be configured manually in the n8n UI** (see below)

#### Setting up the LLM credential in n8n

The A_Orchestrator workflow uses an AI Agent node that requires an OpenAI-compatible API credential. This **cannot** be automated via CLI and must be configured once through the n8n web UI:

1. Open `http://localhost:5678` in your browser
2. Complete the initial n8n owner setup if prompted
3. Go to **Settings > Credentials > Add Credential**
4. Select **OpenAI API**
5. Set:
   - **Name:** `llama.cpp Local`
   - **API Key:** `not-needed` (any non-empty string)
   - **Base URL:** `http://llm-server:8080/v1`
6. Save the credential
7. Open the **A_Orchestrator** workflow, click the **LlamaCppLLM** node, and assign the credential you just created
8. Save and activate the workflow

### Running the tests

From the project root:

```bash
bash tests/test_text_only.sh
bash tests/test_image_only.sh
bash tests/test_mixed.sh
```

Each script prints the full JSON response, saves it to `tests/expected/`, then runs validation assertions.

### Test inventory

#### `tests/test_text_only.sh` — Text-Only Scenario

**Input:**
```json
{
  "request_id": "t1",
  "text": "There is smoke near the machine.",
  "images": []
}
```

**Assertions (12):** `request_id` present, `summary` present, `findings` present, `recommendations` present, `trace` present, `errors` present, `errors` is empty, `trace` is non-empty, trace mentions `text_tool`, trace mentions `report_tool`, trace does NOT mention `vision_tool`, `findings.text` has label.

#### `tests/test_image_only.sh` — Image-Only Scenario

**Input:** `cat.jpg` as base64, no text.

**Assertions (12):** Same structural checks, plus `findings.vision` present, `findings.vision.top_objects` non-empty, trace mentions `vision_tool`, trace does NOT mention `text_tool`.

#### `tests/test_mixed.sh` — Mixed Text + Image Scenario

**Input:** `bus.jpg` as base64 + `"Check if there are people near the gate."`.

**Assertions (13):** Same structural checks, plus all three tools appear in trace (`vision_tool`, `text_tool`, `report_tool`).

---

## Environment Variables

### For pytest (Layer 1)

No environment variables required. Optional:

| Variable | Default | Effect |
|----------|---------|--------|
| `TEXT_CANDIDATE_LABELS` | `maintenance_issue,safety_hazard,normal_operation,equipment_failure,environmental_concern` | Comma-separated classification labels |

### For curl tests (Layers 2 and 3)

| Variable | Default | Usage |
|----------|---------|-------|
| `N8N_BASE_URL` | `http://localhost:5678` | n8n webhook base URL. Can also be passed as the first positional argument. |

---

## Running All Tests (Quick Reference)

### Layer 1 only (no services needed)

```bash
cd torch-infer
source .venv/bin/activate
pytest ../tests/rest/ ../tests/analyzers/ -v --tb=short
```

### Layers 1 + 2 (full automated)

```bash
# 1. Start services
docker compose --profile docker up -d

# 2. Wait for LLM model (first time: watch for "Starting llama.cpp server")
docker compose --profile docker logs -f llm-server

# 3. Import and activate workflows
for wf in B_VisionTool C_TextTool D_ReportTool A_Orchestrator; do
  docker cp n8n-workflows/${wf}.json n8n:/tmp/${wf}.json
  docker compose exec -T n8n n8n import:workflow --input=/tmp/${wf}.json
done
for wf_id in $(docker compose exec -T n8n n8n list:workflow | cut -d'|' -f1); do
  docker compose exec -T n8n n8n update:workflow --id="$wf_id" --active=true
done
docker compose restart n8n
sleep 12

# 4. Layer 1
cd torch-infer && source .venv/bin/activate
pytest ../tests/rest/ ../tests/analyzers/ -v --tb=short
cd ..

# 5. Layer 2
bash tests/test_b_vision_tool.sh
bash tests/test_c_text_tool.sh
bash tests/test_d_report_tool.sh
```

### Layer 3 (requires manual credential setup)

After completing the LLM credential setup in the n8n UI:

```bash
bash tests/test_text_only.sh
bash tests/test_image_only.sh
bash tests/test_mixed.sh
```

---

## Test Results Summary

All Layer 1 and Layer 2 tests pass consistently:

| Layer | Script | Tests | Assertions | Time | Result |
|-------|--------|-------|------------|------|--------|
| 1 | `pytest` | 24 | 24 | ~25s | **ALL PASSED** |
| 2 | `test_b_vision_tool.sh` | 7 | 19 | ~60s | **ALL PASSED** |
| 2 | `test_c_text_tool.sh` | 5 | 8 | ~15s | **ALL PASSED** |
| 2 | `test_d_report_tool.sh` | 3 | 13 | ~7 min (LLM) | **ALL PASSED** |
| **Total** | | **39** | **64** | ~10 min | **ALL PASSED** |
