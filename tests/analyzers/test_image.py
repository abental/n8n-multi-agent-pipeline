"""Tests for image analysis via the /vision/detect endpoint.

Covers correctness (base64, URL, multi-image, real images) and
robustness (empty images, invalid inputs, graceful degradation).
"""
from __future__ import annotations

import pytest

pytestmark = pytest.mark.asyncio


# ---------------------------------------------------------------------------
# Correctness
# ---------------------------------------------------------------------------


async def test_vision_detect_base64(client, sample_base64_image, sample_request_id):
    resp = await client.post(
        "/vision/detect",
        json={
            "request_id": sample_request_id,
            "images": [{"base64": sample_base64_image}],
        },
    )
    assert resp.status_code == 200
    body = resp.json()
    assert body["request_id"] == sample_request_id
    assert isinstance(body["detections"], list)
    assert isinstance(body["model"], str)
    assert len(body["model"]) > 0


async def test_vision_detect_response_schema(client, sample_base64_image):
    resp = await client.post(
        "/vision/detect",
        json={
            "request_id": "schema-test",
            "images": [{"base64": sample_base64_image}],
        },
    )
    assert resp.status_code == 200
    body = resp.json()
    for det in body["detections"]:
        assert isinstance(det["image_index"], int)
        assert isinstance(det["objects"], list)
        for obj in det["objects"]:
            assert isinstance(obj["label"], str)
            assert isinstance(obj["score"], float)
            assert 0.0 <= obj["score"] <= 1.0
            assert isinstance(obj["box"], list)
            assert len(obj["box"]) == 4
            assert all(isinstance(c, int) for c in obj["box"])


async def test_vision_detect_multiple_images(client, sample_base64_image):
    resp = await client.post(
        "/vision/detect",
        json={
            "request_id": "multi-img",
            "images": [
                {"base64": sample_base64_image},
                {"base64": sample_base64_image},
            ],
        },
    )
    assert resp.status_code == 200
    body = resp.json()
    assert len(body["detections"]) == 2
    assert body["detections"][0]["image_index"] == 0
    assert body["detections"][1]["image_index"] == 1


async def test_vision_request_id_propagation(client, sample_base64_image):
    custom_id = "my-custom-id-vision-456"
    resp = await client.post(
        "/vision/detect",
        json={
            "request_id": custom_id,
            "images": [{"base64": sample_base64_image}],
        },
    )
    assert resp.status_code == 200
    assert resp.json()["request_id"] == custom_id


# ---------------------------------------------------------------------------
# Real image detection
# ---------------------------------------------------------------------------


async def test_vision_detect_cat(client, cat_base64_image):
    resp = await client.post(
        "/vision/detect",
        json={"request_id": "real-cat", "images": [{"base64": cat_base64_image}]},
    )
    assert resp.status_code == 200
    body = resp.json()
    labels = [obj["label"] for det in body["detections"] for obj in det["objects"]]
    assert "cat" in labels, f"Expected 'cat' in {labels}"


async def test_vision_detect_dog(client, dog_base64_image):
    resp = await client.post(
        "/vision/detect",
        json={"request_id": "real-dog", "images": [{"base64": dog_base64_image}]},
    )
    assert resp.status_code == 200
    body = resp.json()
    labels = [obj["label"] for det in body["detections"] for obj in det["objects"]]
    assert "dog" in labels, f"Expected 'dog' in {labels}"


async def test_vision_detect_bicycle(client, bicycle_base64_image):
    resp = await client.post(
        "/vision/detect",
        json={"request_id": "real-bicycle", "images": [{"base64": bicycle_base64_image}]},
    )
    assert resp.status_code == 200
    body = resp.json()
    labels = [obj["label"] for det in body["detections"] for obj in det["objects"]]
    assert "bicycle" in labels, f"Expected 'bicycle' in {labels}"


async def test_vision_detect_bus(client, bus_base64_image):
    resp = await client.post(
        "/vision/detect",
        json={"request_id": "real-bus", "images": [{"base64": bus_base64_image}]},
    )
    assert resp.status_code == 200
    body = resp.json()
    labels = [obj["label"] for det in body["detections"] for obj in det["objects"]]
    assert "bus" in labels, f"Expected 'bus' in {labels}"


async def test_vision_detect_multiple_real_images(client, cat_base64_image, dog_base64_image):
    resp = await client.post(
        "/vision/detect",
        json={
            "request_id": "multi-real",
            "images": [
                {"base64": cat_base64_image},
                {"base64": dog_base64_image},
            ],
        },
    )
    assert resp.status_code == 200
    body = resp.json()
    assert len(body["detections"]) == 2
    labels_0 = [obj["label"] for obj in body["detections"][0]["objects"]]
    labels_1 = [obj["label"] for obj in body["detections"][1]["objects"]]
    assert "cat" in labels_0, f"Expected 'cat' in image 0: {labels_0}"
    assert "dog" in labels_1, f"Expected 'dog' in image 1: {labels_1}"


async def test_vision_detect_coffee_cup(client, coffee_cup_base64_image):
    resp = await client.post(
        "/vision/detect",
        json={"request_id": "real-cup", "images": [{"base64": coffee_cup_base64_image}]},
    )
    assert resp.status_code == 200
    body = resp.json()
    labels = [obj["label"] for det in body["detections"] for obj in det["objects"]]
    assert "cup" in labels, f"Expected 'cup' in {labels}"


# ---------------------------------------------------------------------------
# Robustness / edge cases
# ---------------------------------------------------------------------------


async def test_vision_empty_images_returns_400(client):
    resp = await client.post(
        "/vision/detect",
        json={"request_id": "r1", "images": []},
    )
    assert resp.status_code == 400
    assert "No images provided" in resp.json()["detail"]


async def test_vision_missing_request_id_returns_422(client, sample_base64_image):
    resp = await client.post(
        "/vision/detect",
        json={"images": [{"base64": sample_base64_image}]},
    )
    assert resp.status_code == 422


async def test_vision_invalid_url_graceful(client):
    resp = await client.post(
        "/vision/detect",
        json={
            "request_id": "r2",
            "images": [{"url": "http://invalid.test/no-such-image.jpg"}],
        },
    )
    assert resp.status_code == 200
    body = resp.json()
    assert body["request_id"] == "r2"
    assert len(body["detections"]) == 1
    assert body["detections"][0]["objects"] == []


async def test_vision_invalid_base64_graceful(client):
    resp = await client.post(
        "/vision/detect",
        json={
            "request_id": "r3",
            "images": [{"base64": "not-valid-base64!!!"}],
        },
    )
    assert resp.status_code == 200
    body = resp.json()
    assert body["request_id"] == "r3"
    assert len(body["detections"]) == 1
    assert body["detections"][0]["objects"] == []


async def test_vision_no_url_no_base64(client):
    resp = await client.post(
        "/vision/detect",
        json={"request_id": "r4", "images": [{}]},
    )
    assert resp.status_code == 200
    body = resp.json()
    assert body["request_id"] == "r4"
    assert len(body["detections"]) == 1
    assert body["detections"][0]["objects"] == []
