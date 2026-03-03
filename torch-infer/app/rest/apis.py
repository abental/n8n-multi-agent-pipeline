"""REST API endpoints for vision and text inference."""

from __future__ import annotations

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel

from ..analyzers import image as image_analyzer
from ..analyzers import text as text_analyzer

router = APIRouter()


# ---------------------------------------------------------------------------
# Vision models & endpoint
# ---------------------------------------------------------------------------


class ImageRef(BaseModel):
    url: str | None = None
    base64: str | None = None


class VisionRequest(BaseModel):
    request_id: str
    images: list[ImageRef]


class DetectedObject(BaseModel):
    label: str
    score: float
    box: list[int]


class ImageDetection(BaseModel):
    image_index: int
    objects: list[DetectedObject]


class VisionResponse(BaseModel):
    request_id: str
    detections: list[ImageDetection]
    model: str = image_analyzer.MODEL_NAME
    notes: str | None = None


@router.post("/vision/detect", response_model=VisionResponse)
async def detect(req: VisionRequest) -> VisionResponse:
    if not req.images:
        raise HTTPException(status_code=400, detail="No images provided")

    raw_images = [img.model_dump() for img in req.images]
    results = await image_analyzer.detect_objects(raw_images, req.request_id)

    detections = [
        ImageDetection(
            image_index=r.image_index,
            objects=[
                DetectedObject(label=o.label, score=o.score, box=o.box)
                for o in r.objects
            ],
        )
        for r in results
    ]
    return VisionResponse(request_id=req.request_id, detections=detections)


# ---------------------------------------------------------------------------
# Text models & endpoint
# ---------------------------------------------------------------------------


class TextClassifyRequest(BaseModel):
    request_id: str
    text: str


class Classification(BaseModel):
    label: str
    confidence: float


class TextClassifyResponse(BaseModel):
    request_id: str
    classification: Classification
    model: str = text_analyzer.MODEL_NAME
    notes: str | None = None


@router.post("/text/classify", response_model=TextClassifyResponse)
async def classify(req: TextClassifyRequest) -> TextClassifyResponse:
    if not req.text or not req.text.strip():
        raise HTTPException(status_code=400, detail="Text is empty")

    result = text_analyzer.classify_text(req.text, req.request_id)

    return TextClassifyResponse(
        request_id=req.request_id,
        classification=Classification(label=result.label, confidence=result.confidence),
    )
