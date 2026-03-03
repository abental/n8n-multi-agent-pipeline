#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

echo "=== n8n Multi-Agent Pipeline Setup ==="
echo ""

# ── Step 1: Check prerequisites ──────────────────────────────────────────────
echo "[1/4] Checking prerequisites..."
command -v docker >/dev/null 2>&1 || { echo "ERROR: docker not found. Install Docker first."; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 not found. Install Python 3.12+."; exit 1; }
docker compose version >/dev/null 2>&1 || { echo "ERROR: docker compose not available."; exit 1; }
echo "  docker:  $(docker --version)"
echo "  python3: $(python3 --version)"
echo "  arch:    $(uname -m)"
echo ""

# ── Step 2: Create .env if missing ───────────────────────────────────────────
if [ ! -f .env ]; then
    echo "[2/4] Creating .env from .env.example..."
    cp .env.example .env
    echo "  Created .env"
else
    echo "[2/4] .env already exists."
fi
echo ""

# ── Step 3: Set up local Python venv (for local debug / pytest) ──────────────
echo "[3/4] Setting up Torch-Infer Python environment (for local debug / tests)..."
cd torch-infer
if [ ! -d .venv ]; then
    python3 -m venv .venv
    echo "  Created virtual environment"
fi
source .venv/bin/activate
pip install --upgrade pip --quiet
pip install -q -r requirements.txt
echo "  Dependencies installed (pip $(pip --version | awk '{print $2}'))"
deactivate
cd "$PROJECT_DIR"
echo ""

# ── Step 4: Build and start Docker services ──────────────────────────────────
echo "[4/4] Building and starting Docker services..."
echo "  Building images (llm-server + torch-infer) for $(uname -m)..."
echo "  This may take a few minutes on first run."
docker compose --profile docker build
echo ""
echo "  Starting services (n8n + llm-server + torch-infer)..."
docker compose --profile docker up -d
echo ""

MODEL_FILE="${MODEL_FILE:-Meta-Llama-3-8B-Instruct.Q4_K_M.gguf}"
if [ ! -f "models/$MODEL_FILE" ]; then
    echo "  NOTE: The LLM model (~4.9 GB) will download automatically on first start."
    echo "  Monitor progress: docker compose logs -f llm-server"
fi
echo ""

echo "=== Setup Complete ==="
echo ""
echo "Services (all in Docker):"
echo "  n8n:          http://localhost:${N8N_PORT:-5678}"
echo "  llm-server:   http://localhost:${LLM_PORT:-8080}   (llama.cpp Python)"
echo "  torch-infer:  http://localhost:${TORCH_INFER_PORT:-8000}  (PyTorch)"
echo ""
echo "Next steps:"
echo "  1. Wait for LLM model download (first time): docker compose logs -f llm-server"
echo "  2. Wait for PyTorch models (first request): docker compose logs -f torch-infer"
echo "  3. Set up n8n owner at http://localhost:${N8N_PORT:-5678} (first-time only)"
echo "  4. Import workflows:   bash scripts/import-workflows.sh"
echo "  5. Run tests:          bash tests/test_text_only.sh"
echo ""
echo "Local debug mode (run torch-infer in PyCharm instead of Docker):"
echo "  1. docker compose stop torch-infer"
echo "  2. Add TORCH_INFER_BASE_URL=http://host.docker.internal:8000 to .env"
echo "  3. docker compose restart n8n"
echo "  4. Run torch-infer locally (PyCharm / uvicorn)"
