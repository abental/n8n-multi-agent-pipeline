"""Text analysis using zero-shot classification (BART-large-MNLI)."""

from __future__ import annotations

import logging
import os
from dataclasses import dataclass

from transformers import pipeline

logger = logging.getLogger(__name__)

DEFAULT_LABELS = [
    "maintenance_issue",
    "safety_hazard",
    "normal_operation",
    "equipment_failure",
    "environmental_concern",
]

MODEL_NAME = "facebook/bart-large-mnli"

_classifier = None


def _get_classifier():
    global _classifier
    if _classifier is None:
        logger.info("Loading zero-shot classification model (first request) ...")
        _classifier = pipeline("zero-shot-classification", model=MODEL_NAME)
        logger.info("Text classification model loaded.")
    return _classifier


def get_candidate_labels() -> list[str]:
    """Return candidate labels from env var or defaults."""
    env = os.environ.get("TEXT_CANDIDATE_LABELS", "")
    if env.strip():
        return [label.strip() for label in env.split(",") if label.strip()]
    return DEFAULT_LABELS


@dataclass
class ClassificationResult:
    label: str
    confidence: float


def classify_text(text: str, request_id: str) -> ClassificationResult:
    """Classify text into one of the candidate labels.

    Args:
        text: The input text to classify.
        request_id: Used for structured logging.

    Returns:
        Classification result with label and confidence.
    """
    logger.info("[request_id=%s] Text classify: %d chars received", request_id, len(text))

    clf = _get_classifier()
    labels = get_candidate_labels()
    result = clf(text, candidate_labels=labels)

    classification = ClassificationResult(
        label=result["labels"][0],
        confidence=round(result["scores"][0], 4),
    )
    logger.info(
        "[request_id=%s] Text classify: label=%s confidence=%.4f",
        request_id, classification.label, classification.confidence,
    )
    return classification
