"""Entrypoint: download model on first start, then run llama.cpp Python server."""

import os
import sys
from pathlib import Path

MODEL_DIR = Path(os.environ.get("MODEL_DIR", "/models"))
MODEL_REPO = os.environ.get("MODEL_REPO", "QuantFactory/Meta-Llama-3-8B-Instruct-GGUF")
MODEL_FILE = os.environ.get("MODEL_FILE", "Meta-Llama-3-8B-Instruct.Q4_K_M.gguf")
MODEL_PATH = MODEL_DIR / MODEL_FILE

MIN_SIZE = 100_000_000  # 100 MB


def download_model():
    from huggingface_hub import hf_hub_download

    print(f"=== Downloading {MODEL_FILE} from {MODEL_REPO} ===")
    print("This only happens on first start (~4.9 GB download)...")
    hf_hub_download(
        repo_id=MODEL_REPO,
        filename=MODEL_FILE,
        local_dir=str(MODEL_DIR),
        local_dir_use_symlinks=False,
    )
    size = MODEL_PATH.stat().st_size
    print(f"Download complete: {MODEL_PATH} ({size / 1e9:.1f} GB)")
    if size < MIN_SIZE:
        print(f"ERROR: File is only {size} bytes — download likely failed.")
        sys.exit(1)


if not MODEL_PATH.exists() or MODEL_PATH.stat().st_size < MIN_SIZE:
    download_model()
else:
    size = MODEL_PATH.stat().st_size
    print(f"Model ready: {MODEL_PATH} ({size / 1e9:.1f} GB)")

os.environ.setdefault("MODEL", str(MODEL_PATH))
os.environ.setdefault("HOST", "0.0.0.0")
os.environ.setdefault("PORT", "8080")

print(f"=== Starting llama.cpp server ===")
print(f"  Model:   {os.environ['MODEL']}")
print(f"  Host:    {os.environ['HOST']}")
print(f"  Port:    {os.environ['PORT']}")
print(f"  N_CTX:   {os.environ.get('N_CTX', '2048')}")

os.execvp(sys.executable, [sys.executable, "-m", "llama_cpp.server"])
