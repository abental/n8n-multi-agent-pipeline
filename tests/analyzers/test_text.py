"""Tests for text analysis via the /text/classify endpoint.

Covers correctness (classification, label matching, request_id propagation)
and robustness (empty text, missing fields, very long text).
"""
from __future__ import annotations

import pytest

pytestmark = pytest.mark.asyncio

CANDIDATE_LABELS = [
    "maintenance_issue",
    "safety_hazard",
    "normal_operation",
    "equipment_failure",
    "environmental_concern",
]


# ---------------------------------------------------------------------------
# Correctness
# ---------------------------------------------------------------------------


async def test_text_classify(client, sample_request_id):
    resp = await client.post(
        "/text/classify",
        json={
            "request_id": sample_request_id,
            "text": "There is smoke near the machine.",
        },
    )
    assert resp.status_code == 200
    body = resp.json()
    assert body["request_id"] == sample_request_id
    assert isinstance(body["classification"]["label"], str)
    assert isinstance(body["classification"]["confidence"], float)
    assert 0.0 <= body["classification"]["confidence"] <= 1.0
    assert isinstance(body["model"], str)
    assert isinstance(body["notes"], str)
    assert len(body["notes"]) > 0


async def test_text_classify_label_in_candidates(client):
    resp = await client.post(
        "/text/classify",
        json={
            "request_id": "label-check",
            "text": "There is smoke near the machine.",
        },
    )
    assert resp.status_code == 200
    label = resp.json()["classification"]["label"]
    assert label in CANDIDATE_LABELS, f"Label '{label}' not in {CANDIDATE_LABELS}"


async def test_text_classify_request_id_propagation(client):
    custom_id = "my-custom-id-text-123"
    resp = await client.post(
        "/text/classify",
        json={"request_id": custom_id, "text": "test input"},
    )
    assert resp.status_code == 200
    assert resp.json()["request_id"] == custom_id


# ---------------------------------------------------------------------------
# Robustness / edge cases
# ---------------------------------------------------------------------------


async def test_text_empty_text_returns_400(client):
    resp = await client.post(
        "/text/classify",
        json={"request_id": "r5", "text": ""},
    )
    assert resp.status_code == 400
    assert "Text is empty" in resp.json()["detail"]


async def test_text_whitespace_only_returns_400(client):
    resp = await client.post(
        "/text/classify",
        json={"request_id": "r6", "text": "   "},
    )
    assert resp.status_code == 400
    assert "Text is empty" in resp.json()["detail"]


async def test_text_missing_request_id_returns_422(client):
    resp = await client.post(
        "/text/classify",
        json={"text": "something happened"},
    )
    assert resp.status_code == 422


async def test_text_missing_text_field_returns_422(client):
    resp = await client.post(
        "/text/classify",
        json={"request_id": "r7"},
    )
    assert resp.status_code == 422


async def test_text_very_long_text(client):
    long_text = "word " * 5000
    resp = await client.post(
        "/text/classify",
        json={"request_id": "r8", "text": long_text},
    )
    assert resp.status_code == 200
    body = resp.json()
    assert body["request_id"] == "r8"
    assert isinstance(body["classification"]["label"], str)
    assert isinstance(body["classification"]["confidence"], float)
    assert 0.0 <= body["classification"]["confidence"] <= 1.0


# ---------------------------------------------------------------------------
# /text/extract endpoint
# ---------------------------------------------------------------------------


async def test_text_extract(client, sample_request_id):
    resp = await client.post(
        "/text/extract",
        json={
            "request_id": sample_request_id,
            "text": "John went to New York to visit the Statue of Liberty.",
        },
    )
    assert resp.status_code == 200
    body = resp.json()
    assert body["request_id"] == sample_request_id
    assert isinstance(body["entities"], list)
    assert isinstance(body["keywords"], list)
    assert isinstance(body["model"], str)
    assert isinstance(body["notes"], str)


async def test_text_extract_returns_typed_entities(client):
    resp = await client.post(
        "/text/extract",
        json={
            "request_id": "ner-types",
            "text": "Alice works at Google in San Francisco.",
        },
    )
    assert resp.status_code == 200
    body = resp.json()
    assert len(body["entities"]) > 0
    for ent in body["entities"]:
        assert "type" in ent
        assert "value" in ent
        assert isinstance(ent["type"], str)
        assert isinstance(ent["value"], str)


async def test_text_extract_request_id_propagation(client):
    custom_id = "extract-id-123"
    resp = await client.post(
        "/text/extract",
        json={"request_id": custom_id, "text": "Test text"},
    )
    assert resp.status_code == 200
    assert resp.json()["request_id"] == custom_id


async def test_text_extract_empty_returns_400(client):
    resp = await client.post(
        "/text/extract",
        json={"request_id": "r-empty", "text": ""},
    )
    assert resp.status_code == 400


async def test_text_extract_no_entities(client):
    resp = await client.post(
        "/text/extract",
        json={"request_id": "no-ent", "text": "something happened today"},
    )
    assert resp.status_code == 200
    body = resp.json()
    assert isinstance(body["entities"], list)
    assert isinstance(body["keywords"], list)
