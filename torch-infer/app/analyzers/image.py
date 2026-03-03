"""Image analysis using Faster R-CNN object detection."""

from __future__ import annotations

import base64
import io
import logging
from dataclasses import dataclass, field

import httpx
import torch
from PIL import Image
from torchvision.models.detection import (
    FasterRCNN_ResNet50_FPN_Weights,
    fasterrcnn_resnet50_fpn,
)

logger = logging.getLogger(__name__)

SCORE_THRESHOLD = 0.5

COCO_LABELS = [
    "__background__", "person", "bicycle", "car", "motorcycle", "airplane",
    "bus", "train", "truck", "boat", "traffic light", "fire hydrant",
    "N/A", "stop sign", "parking meter", "bench", "bird", "cat", "dog",
    "horse", "sheep", "cow", "elephant", "bear", "zebra", "giraffe", "N/A",
    "backpack", "umbrella", "N/A", "N/A", "handbag", "tie", "suitcase",
    "frisbee", "skis", "snowboard", "sports ball", "kite", "baseball bat",
    "baseball glove", "skateboard", "surfboard", "tennis racket", "bottle",
    "N/A", "wine glass", "cup", "fork", "knife", "spoon", "bowl", "banana",
    "apple", "sandwich", "orange", "broccoli", "carrot", "hot dog", "pizza",
    "donut", "cake", "chair", "couch", "potted plant", "bed", "N/A",
    "dining table", "N/A", "N/A", "toilet", "N/A", "tv", "laptop", "mouse",
    "remote", "keyboard", "cell phone", "microwave", "oven", "toaster",
    "sink", "refrigerator", "N/A", "book", "clock", "vase", "scissors",
    "teddy bear", "hair drier", "toothbrush",
]

MODEL_NAME = "fasterrcnn_resnet50_fpn"

_model = None
_weights = None


def _get_model():
    global _model, _weights
    if _model is None:
        logger.info("Loading Faster R-CNN model (first request) ...")
        _weights = FasterRCNN_ResNet50_FPN_Weights.DEFAULT
        _model = fasterrcnn_resnet50_fpn(weights=_weights)
        _model.eval()
        logger.info("Faster R-CNN model loaded.")
    return _model, _weights


@dataclass
class DetectedObject:
    label: str
    score: float
    box: list[int]


@dataclass
class ImageDetectionResult:
    image_index: int
    objects: list[DetectedObject] = field(default_factory=list)


async def load_image(*, url: str | None = None, base64_data: str | None = None) -> Image.Image:
    """Load an image from a URL or base64-encoded string."""
    if base64_data:
        data = base64.b64decode(base64_data)
        return Image.open(io.BytesIO(data)).convert("RGB")
    if url:
        async with httpx.AsyncClient(timeout=30) as client:
            resp = await client.get(url)
            resp.raise_for_status()
            return Image.open(io.BytesIO(resp.content)).convert("RGB")
    raise ValueError("Image must have either 'url' or 'base64'")


async def detect_objects(
    images: list[dict],
    request_id: str,
) -> list[ImageDetectionResult]:
    """Run object detection on a list of images.

    Args:
        images: List of dicts, each with optional 'url' or 'base64' key.
        request_id: Used for structured logging.

    Returns:
        List of detection results, one per input image.
    """
    logger.info("[request_id=%s] Vision detect: %d images received", request_id, len(images))

    model, weights = _get_model()
    transform = weights.transforms()

    results: list[ImageDetectionResult] = []
    for idx, img_ref in enumerate(images):
        try:
            pil_img = await load_image(url=img_ref.get("url"), base64_data=img_ref.get("base64"))
        except Exception as exc:
            logger.warning("Failed to load image %d: %s", idx, exc)
            results.append(ImageDetectionResult(image_index=idx))
            continue

        tensor = transform(pil_img).unsqueeze(0)
        with torch.no_grad():
            preds = model(tensor)[0]

        objects: list[DetectedObject] = []
        for label_id, score, box in zip(preds["labels"], preds["scores"], preds["boxes"]):
            if score.item() < SCORE_THRESHOLD:
                continue
            objects.append(DetectedObject(
                label=COCO_LABELS[label_id.item()],
                score=round(score.item(), 4),
                box=[int(c) for c in box.tolist()],
            ))
        results.append(ImageDetectionResult(image_index=idx, objects=objects))

    total_objects = sum(len(r.objects) for r in results)
    logger.info(
        "[request_id=%s] Vision detect: %d images processed, %d total objects",
        request_id, len(results), total_objects,
    )
    return results
