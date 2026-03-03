"""Shared pytest fixtures for Torch-Infer API tests."""
from __future__ import annotations

import base64
import io
import sys
import uuid
from pathlib import Path

import httpx
import pytest
import pytest_asyncio
from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "torch-infer"))

from app.main import app  # noqa: E402

IMAGES_DIR = Path(__file__).resolve().parent / "images"


def _load_b64(filename: str) -> str:
    return base64.b64encode((IMAGES_DIR / filename).read_bytes()).decode()


@pytest_asyncio.fixture
async def client():
    """Async HTTP client wired to the FastAPI app (no network needed)."""
    transport = httpx.ASGITransport(app=app)
    async with httpx.AsyncClient(transport=transport, base_url="http://test") as c:
        yield c


@pytest.fixture
def sample_base64_image() -> str:
    """A tiny 10x10 red PNG encoded as base64."""
    img = Image.new("RGB", (10, 10), color=(255, 0, 0))
    buf = io.BytesIO()
    img.save(buf, format="PNG")
    return base64.b64encode(buf.getvalue()).decode()


@pytest.fixture
def cat_base64_image() -> str:
    return _load_b64("cat.jpg")


@pytest.fixture
def dog_base64_image() -> str:
    return _load_b64("dog.jpg")


@pytest.fixture
def bicycle_base64_image() -> str:
    return _load_b64("bicycle.jpg")


@pytest.fixture
def bus_base64_image() -> str:
    return _load_b64("bus.jpg")


@pytest.fixture
def ant_base64_image() -> str:
    return _load_b64("ant.jpg")


@pytest.fixture
def coffee_cup_base64_image() -> str:
    return _load_b64("coffee_cup.jpg")


@pytest.fixture
def sample_request_id() -> str:
    return f"test-{uuid.uuid4().hex[:8]}"
