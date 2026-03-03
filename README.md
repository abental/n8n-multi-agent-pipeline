# n8n Multi-Agent Pipeline

A local AI inference pipeline orchestrated by n8n. A client sends text and/or images to a webhook; an **AI Agent** (Orchestrator) uses llama.cpp to dynamically decide which tool-workflows to call (Vision, Text, Report Writer), then returns a strict JSON report with a complete tool-call trace.

All inference is local — no cloud APIs. All three services (n8n, llm-server, torch-infer) run in Docker via a single `docker compose` command. Torch-Infer can optionally run on the host for local debugging (e.g. in PyCharm).

> For full technical documentation (node-by-node, data contracts, testing strategy, common pitfalls), see [PROJECT_PLAN.md](PROJECT_PLAN.md).
> For the full testing guide (test inventory, environment setup, commands), see [TEST.md](TEST.md).

## Architecture

```
Client
  |  POST /webhook/analyze  {text, images[]}
  v
+--------------------------------------------------------+
| Workflow A: ORCHESTRATOR (AI Agent node, llama.cpp LLM)|
| Tools (LLM decides which to call):                    |
|   1) call_vision_tool -> Workflow B (/tool/vision)     |
|   2) call_text_tool   -> Workflow C (/tool/text)       |
|   3) call_report_tool -> Workflow D (/tool/report)     |
+-----+--------------------+--------------------+-------+
      |                    |                    |
      v                    v                    v
  Workflow B           Workflow C           Workflow D
  B_VisionTool         C_TextTool           D_ReportTool
      |                    |                    |
      v                    v                    v
  torch-infer          torch-infer          llm-server
  /vision/detect       /text/classify       /v1/chat/completions

Docker Compose:
  [n8n] <--network--> [llm-server] <--network--> [torch-infer]
```

All three services are on the same Docker network and communicate via Docker DNS.

| Service | Container | Port | Stack |
|---------|-----------|------|-------|
| n8n | `n8n` | 5678 | Workflow orchestration |
| llm-server | `llm-server` | 8080 | llama.cpp via Python `llama-cpp-python` (Llama 3 8B) |
| torch-infer | `torch-infer` | 8000 | FastAPI + PyTorch (Faster R-CNN + BART-MNLI) |

## Prerequisites

- Docker and Docker Compose
- Python 3.12+ (for local debug / pytest only)
- ~5 GB disk space for the LLM model (downloaded automatically on first start)
- ~2 GB for PyTorch models (downloaded on first inference request)

## Quick Start

### 1. Run the automated setup

```bash
bash scripts/setup.sh
```

This builds all Docker images (compiles llama.cpp natively for your architecture), starts all three services, and sets up a local Python venv for testing/debugging.

### 2. Wait for model downloads (first time only)

```bash
docker compose --profile docker logs -f llm-server     # Wait for "Starting llama.cpp server"
docker compose --profile docker logs -f torch-infer     # PyTorch models download on first request
```

### 3. Set up n8n (first time only)

Open http://localhost:5678 and create an owner account.

### 4. Import workflows

```bash
bash scripts/import-workflows.sh
```

### 5. Configure the LLM credential

In n8n UI: **Credentials** > **Add Credential** > **OpenAI API**:
- API Key: `sk-local-llama` (any value, llama.cpp does not verify)
- Base URL: `http://llm-server:8080/v1`

Then assign this credential to the **LlamaCppLLM** node in the A_Orchestrator workflow.

### 6. Activate all workflows

In the n8n UI, toggle all four workflows (A_Orchestrator, B_VisionTool, C_TextTool, D_ReportTool) to **active**.

---

## Docker Compose

### Overview

The project uses Docker Compose with three services defined in `docker-compose.yml`. The `torch-infer` service uses a Docker Compose **profile** (`docker`) so it can be excluded when running Torch-Infer locally for debugging.

```
docker-compose.yml
├── n8n            (no profile — always starts)
├── llm-server     (no profile — always starts)
└── torch-infer    (profile: docker — only starts with --profile docker)
```

**Important:** All commands that should include `torch-infer` require `--profile docker`. Without it, only `n8n` and `llm-server` start.

### Services

| Service | Image / Build | Port | Volumes | Profile |
|---------|---------------|------|---------|---------|
| `n8n` | `docker.n8n.io/n8nio/n8n:latest` | `${N8N_PORT:-5678}:5678` | `./n8n-data:/home/node/.n8n` | _(none — always starts)_ |
| `llm-server` | Built from `./llm-server/Dockerfile` | `${LLM_PORT:-8080}:8080` | `./models:/models` | _(none — always starts)_ |
| `torch-infer` | Built from `./torch-infer/Dockerfile` | `${TORCH_INFER_PORT:-8000}:8000` | `torch-model-cache`, `hf-model-cache` (named volumes) | `docker`, `full` |

### Named Volumes

| Volume | Mounted at | Purpose |
|--------|------------|---------|
| `torch-model-cache` | `/root/.cache/torch` | Persists downloaded torchvision models (Faster R-CNN) across container restarts |
| `hf-model-cache` | `/root/.cache/huggingface` | Persists downloaded Hugging Face models (BART-MNLI) across container restarts |

### Network

All services share the default Docker Compose network (`n8n-multi-agent-pipeline_default`). Inter-service communication uses Docker DNS:

| From | To | URL |
|------|----|-----|
| n8n | llm-server | `http://llm-server:8080/v1` |
| n8n | torch-infer | `http://torch-infer:8000` (configurable via `TORCH_INFER_BASE_URL`) |
| n8n | host machine | `http://host.docker.internal:<port>` (via `extra_hosts`) |

### Commands Reference

#### Build images

```bash
# Build all images (including torch-infer)
docker compose --profile docker build

# Build a specific service
docker compose build llm-server
docker compose --profile docker build torch-infer
```

#### Start services

```bash
# Start all 3 services (n8n + llm-server + torch-infer)
docker compose --profile docker up -d

# Start only n8n + llm-server (no torch-infer, for local debug mode)
docker compose up -d
```

#### Stop services

```bash
# Stop all containers and remove them
docker compose --profile docker down

# Stop all containers, remove them, AND remove named volumes (clears cached models)
docker compose --profile docker down -v

# Stop a single service (keep others running)
docker compose stop torch-infer
docker compose stop llm-server
```

#### Restart services

```bash
# Restart all services
docker compose --profile docker restart

# Restart a single service (e.g. after changing .env)
docker compose restart n8n
```

#### View logs

```bash
# Follow logs for all services
docker compose --profile docker logs -f

# Follow logs for a specific service
docker compose --profile docker logs -f llm-server
docker compose --profile docker logs -f torch-infer
docker compose --profile docker logs -f n8n

# Show last 50 lines of a service log
docker compose --profile docker logs --tail 50 llm-server
```

#### Check status

```bash
# List all containers and their status
docker compose --profile docker ps

# List all containers including stopped ones
docker compose --profile docker ps -a
```

#### Rebuild and restart (after code changes)

```bash
# Rebuild torch-infer after editing app code
docker compose --profile docker build torch-infer
docker compose --profile docker up -d torch-infer

# Rebuild llm-server after editing Dockerfile or requirements
docker compose build llm-server
docker compose up -d llm-server

# Full rebuild and restart (nuclear option)
docker compose --profile docker down
docker compose --profile docker build --no-cache
docker compose --profile docker up -d
```

#### Shell into a running container

```bash
docker compose exec torch-infer bash
docker compose exec llm-server bash
docker compose exec n8n sh          # n8n uses Alpine, so sh not bash
```

#### Health checks

```bash
# Check torch-infer
curl http://localhost:8000/health

# Check llm-server
curl http://localhost:8080/v1/models

# Check n8n
curl http://localhost:5678/healthz
```

### Environment Variables

All variables are read from `.env` (copy `.env.example` to `.env` on first setup). Docker Compose interpolates them into the service definitions.

| Variable | Default | Used by | Description |
|----------|---------|---------|-------------|
| `N8N_PORT` | `5678` | n8n | Host port for n8n web UI and webhooks |
| `N8N_SECURE_COOKIE` | `false` | n8n | Set to `true` if serving over HTTPS |
| `WEBHOOK_URL` | `http://localhost:5678/` | n8n | External webhook base URL |
| `LLM_PORT` | `8080` | llm-server | Host port for llm-server API |
| `MODEL_REPO` | `QuantFactory/Meta-Llama-3-8B-Instruct-GGUF` | llm-server | HuggingFace model repository |
| `MODEL_FILE` | `Meta-Llama-3-8B-Instruct.Q4_K_M.gguf` | llm-server | GGUF model filename |
| `LLM_CONTEXT_SIZE` | `4096` | llm-server | LLM context window size |
| `TORCH_INFER_PORT` | `8000` | torch-infer | Host port for Torch-Infer API |
| `VISION_SCORE_THRESHOLD` | `0.5` | torch-infer | Minimum object detection confidence |
| `TEXT_CANDIDATE_LABELS` | `maintenance_issue,...` | torch-infer | Comma-separated classification labels |
| `TORCH_INFER_BASE_URL` | `http://torch-infer:8000` | n8n | How n8n reaches Torch-Infer (change for local debug) |

### First-Time Startup Sequence

On first `docker compose --profile docker up -d`:

1. Docker builds the `llm-server` image (~5 min, compiles llama.cpp C++ code via `pip install llama-cpp-python`)
2. Docker builds the `torch-infer` image (~3 min, installs PyTorch)
3. All three containers start
4. `llm-server` detects the model is missing and downloads it from HuggingFace (~4.9 GB). Monitor with `docker compose --profile docker logs -f llm-server`
5. `torch-infer` downloads PyTorch models on the first inference request (~1-2 GB). These are cached in named volumes.
6. Subsequent restarts are fast — images are cached, models are persisted

---

## Test Examples

### Text-only analysis

```bash
curl -s -X POST http://localhost:5678/webhook/analyze \
  -H "Content-Type: application/json" \
  -d '{
    "request_id": "t1",
    "text": "There is smoke near the machine.",
    "images": []
  }' | python3 -m json.tool
```

Expected: Orchestrator calls TextTool then ReportTool. Trace contains `text_tool` and `report_tool`.

### Image-only analysis

```bash
curl -s -X POST http://localhost:5678/webhook/analyze \
  -H "Content-Type: application/json" \
  -d '{
    "request_id": "v1",
    "text": "",
    "images": [{"url": "https://upload.wikimedia.org/wikipedia/commons/thumb/4/4d/Cat_November_2010-1a.jpg/1200px-Cat_November_2010-1a.jpg"}]
  }' | python3 -m json.tool
```

Expected: Orchestrator calls VisionTool then ReportTool. `findings.vision.top_objects` has detected objects.

### Mixed analysis (text + image)

```bash
curl -s -X POST http://localhost:5678/webhook/analyze \
  -H "Content-Type: application/json" \
  -d '{
    "request_id": "m1",
    "text": "Check if there are people near the gate.",
    "images": [{"url": "https://upload.wikimedia.org/wikipedia/commons/thumb/4/4d/Cat_November_2010-1a.jpg/1200px-Cat_November_2010-1a.jpg"}]
  }' | python3 -m json.tool
```

Expected: Orchestrator calls VisionTool AND TextTool, then ReportTool. Trace shows all three tool calls.

## Running Tests

For the full testing guide, see [TEST.md](TEST.md).

### Quick: Layer 1 only (no services needed)

```bash
cd torch-infer
source .venv/bin/activate
pip install -r ../tests/requirements-test.txt
pytest ../tests/rest/ ../tests/analyzers/ -v --tb=short
```

**24 tests** across `rest/test_apis.py` (1), `analyzers/test_image.py` (15), and `analyzers/test_text.py` (8).

### Integration and E2E (requires Docker services)

```bash
# Layer 2: sub-workflow tests
bash tests/test_b_vision_tool.sh    # 7 test cases for Vision Tool
bash tests/test_c_text_tool.sh      # 5 test cases for Text Tool
bash tests/test_d_report_tool.sh    # 5 test cases for Report Tool

# Layer 3: end-to-end tests
bash tests/test_text_only.sh        # Text-only scenario
bash tests/test_image_only.sh       # Image-only scenario
bash tests/test_mixed.sh            # Mixed text+image scenario
```

---

## Local Debug Mode (PyCharm / VS Code)

By default, all services run in Docker. To debug Torch-Infer locally:

### Switch to local debug

```bash
# 1. Stop the Docker torch-infer container (n8n + llm-server keep running)
docker compose stop torch-infer

# 2. Tell n8n to reach torch-infer on the host instead of Docker DNS
#    Add this line to .env:
echo 'TORCH_INFER_BASE_URL=http://host.docker.internal:8000' >> .env

# 3. Restart n8n so it picks up the new env var
docker compose restart n8n

# 4. Run torch-infer locally
cd torch-infer
source .venv/bin/activate
uvicorn app.main:app --host 0.0.0.0 --port 8000 --reload
```

Or run it from PyCharm with a uvicorn run configuration:
- **Module**: `uvicorn`
- **Parameters**: `app.main:app --host 0.0.0.0 --port 8000 --reload`
- **Working directory**: `torch-infer/`

### Switch back to Docker

```bash
# 1. Remove or comment out TORCH_INFER_BASE_URL in .env
# 2. Restart everything
docker compose --profile docker up -d
```

---

## Troubleshooting

### llm-server won't start
- Check container logs: `docker compose --profile docker logs llm-server`
- Verify model download completed: `ls -la models/*.gguf`
- Rebuild the image: `docker compose build llm-server`

### Model download fails
- The model (~4.9 GB) downloads from HuggingFace on first container start
- If it fails, check network connectivity from the container
- Manual download: `pip install huggingface-hub && huggingface-cli download QuantFactory/Meta-Llama-3-8B-Instruct-GGUF Meta-Llama-3-8B-Instruct.Q4_K_M.gguf --local-dir models/`

### torch-infer first request is slow
- PyTorch models (~1-2 GB) download on first inference request
- Monitor: `docker compose --profile docker logs -f torch-infer`
- Subsequent requests use cached models (persisted in Docker volumes)

### Only 2 containers running (torch-infer missing)
- The `torch-infer` service requires `--profile docker`
- Use: `docker compose --profile docker up -d` (not `docker compose up -d`)
- Verify: `docker compose --profile docker ps`

### n8n webhooks return 404
- Ensure all four workflows are **active** (green toggle) in the n8n UI
- Check webhook paths match expected URLs

### AI Agent not calling tools
- Verify the OpenAI API credential is configured (see Quick Start step 5)
- Check llm-server is responding: `curl http://localhost:8080/v1/models`

### n8n can't reach torch-infer
- Docker mode: torch-infer is at `http://torch-infer:8000` (Docker DNS)
- Local debug: set `TORCH_INFER_BASE_URL=http://host.docker.internal:8000` in `.env` and restart n8n
- Verify: `curl http://localhost:8000/health`

### n8n API import fails
- Create an owner account first (visit http://localhost:5678)
- Alternative: import workflow JSON files manually via n8n UI

### Clearing cached models (full reset)

```bash
docker compose --profile docker down -v    # removes containers AND named volumes
docker compose --profile docker up -d      # rebuilds, re-downloads everything
```

---

## Output Schema

```json
{
  "request_id": "...",
  "summary": "Short human-readable summary.",
  "findings": {
    "vision": { "top_objects": ["person", "car"], "details": [] },
    "text": { "label": "maintenance_issue", "confidence": 0.87, "entities": [] }
  },
  "recommendations": ["..."],
  "trace": [...],
  "errors": []
}
```

## Workflow Details

| Workflow | Webhook Path | Purpose |
|----------|-------------|---------|
| A_Orchestrator | `POST /webhook/analyze` | AI Agent entry point. LLM decides tool calls. |
| B_VisionTool | `POST /webhook/tool/vision` | Calls Torch-Infer `/vision/detect` |
| C_TextTool | `POST /webhook/tool/text` | Calls Torch-Infer `/text/classify` |
| D_ReportTool | `POST /webhook/tool/report` | Calls llm-server to generate final report |

## Trace Visibility

### n8n UI

Open the workflow execution in n8n to see:
- Which tools the AI Agent decided to call
- Input and output of each tool call
- The final response

### Torch-Infer Console

```bash
docker compose --profile docker logs -f torch-infer
```

```
[INFO] app.analyzers.image: [request_id=t1] Vision detect: 2 images received
[INFO] app.analyzers.text:  [request_id=t1] Text classify: 32 chars received
```

### Report Trace Array

```json
"trace": [
  { "step": "orchestrator", "decision": "called vision+text then report" },
  { "step": "tool_call", "tool": "vision_tool" },
  { "step": "tool_call", "tool": "text_tool" },
  { "step": "tool_call", "tool": "report_tool" }
]
```
