#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

MODEL_FILE="${MODEL_FILE:-Meta-Llama-3-8B-Instruct.Q4_K_M.gguf}"
MODEL_PATH="models/$MODEL_FILE"
MIN_SIZE=$((100 * 1024 * 1024))

if [ -f "$MODEL_PATH" ]; then
    FILE_SIZE=$(wc -c < "$MODEL_PATH" | tr -d ' ')
    if [ "$FILE_SIZE" -gt "$MIN_SIZE" ]; then
        echo "Model already exists: $MODEL_PATH ($(du -h "$MODEL_PATH" | cut -f1))"
        exit 0
    fi
fi

echo "Triggering model download via llm-server container..."
echo "The model (~4.9 GB) will be downloaded by the container on startup."
echo ""

docker compose up llm-server -d
echo ""
echo "Monitor download progress:"
echo "  docker compose logs -f llm-server"
