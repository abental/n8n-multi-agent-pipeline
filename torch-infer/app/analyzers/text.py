"""Text analysis using zero-shot classification (BART-large-MNLI) and NER."""

from __future__ import annotations

import logging
import os
from dataclasses import dataclass, field

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
NER_MODEL_NAME = "dslim/bert-base-NER"

_classifier = None
_ner_pipeline = None


def _get_classifier():
    global _classifier
    if _classifier is None:
        logger.info("Loading zero-shot classification model (first request) ...")
        _classifier = pipeline("zero-shot-classification", model=MODEL_NAME)
        logger.info("Text classification model loaded.")
    return _classifier


def _get_ner_pipeline():
    global _ner_pipeline
    if _ner_pipeline is None:
        logger.info("Loading NER model (first request) ...")
        _ner_pipeline = pipeline(
            "ner", model=NER_MODEL_NAME, aggregation_strategy="simple"
        )
        logger.info("NER model loaded.")
    return _ner_pipeline


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


@dataclass
class Entity:
    type: str
    value: str


@dataclass
class ExtractionResult:
    entities: list[Entity] = field(default_factory=list)
    keywords: list[str] = field(default_factory=list)


def classify_text(text: str, request_id: str) -> ClassificationResult:
    """Classify text into one of the candidate labels."""
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


def extract_entities(text: str, request_id: str) -> ExtractionResult:
    """Extract named entities from text using a BERT-based NER model."""
    logger.info("[request_id=%s] Text extract: %d chars received", request_id, len(text))

    ner = _get_ner_pipeline()
    raw_entities = ner(text)

    seen: set[tuple[str, str]] = set()
    entities: list[Entity] = []
    keywords: list[str] = []

    for ent in raw_entities:
        ent_type = ent["entity_group"]
        ent_value = ent["word"].strip()
        if not ent_value:
            continue
        key = (ent_type, ent_value)
        if key not in seen:
            seen.add(key)
            entities.append(Entity(type=ent_type, value=ent_value))
            keywords.append(ent_value)

    logger.info(
        "[request_id=%s] Text extract: %d entities found", request_id, len(entities)
    )
    return ExtractionResult(entities=entities, keywords=keywords)
