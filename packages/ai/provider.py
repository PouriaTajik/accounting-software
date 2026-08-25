"""
Provider-agnostic AI layer.

Every feature (OCR field extraction, transaction categorization fallback,
anomaly explanations, natural-language ledger querying) calls AIProvider.
Nothing upstream ever imports `openai`, `anthropic`, or `ollama` directly —
that's what makes "desktop with your own API key" and "fully offline
on-prem" the same code path with a different config row, instead of two
maintained branches.
"""

from abc import ABC
from enum import Enum
from typing import Optional

import litellm
from pydantic import BaseModel


class ProviderMode(str, Enum):
    CLOUD_OPENAI = "cloud_openai"
    CLOUD_ANTHROPIC = "cloud_anthropic"
    CLOUD_AZURE_OPENAI = "cloud_azure_openai"
    CLOUD_CUSTOM_ENDPOINT = "cloud_custom_endpoint"   # any OpenAI-compatible endpoint
    LOCAL_OLLAMA = "local_ollama"


class ProviderConfig(BaseModel):
    mode: ProviderMode
    model: str
    api_key: Optional[str] = None       # required for cloud modes; a client-supplied key
    api_base: Optional[str] = None      # custom endpoint URL, or local Ollama host
    organization: Optional[str] = None  # OpenAI org id, if applicable


class AIRequest(BaseModel):
    messages: list[dict]
    temperature: float = 0.2
    max_tokens: int = 1024
    response_format: Optional[dict] = None   # e.g. {"type": "json_object"} for structured extraction


class AIResponse(BaseModel):
    content: str
    model: str
    provider_mode: ProviderMode
    usage: dict


class AIProvider:
    """
    Thin, swappable wrapper around LiteLLM. One instance is bound to one
    workspace's ProviderConfig, resolved at request time from the
    `workspace_ai_config` table — never hardcoded — so an enterprise client
    can swap models (or go offline) without a redeploy.
    """

    _MODEL_PREFIX = {
        ProviderMode.CLOUD_OPENAI: "openai/{model}",
        ProviderMode.CLOUD_ANTHROPIC: "anthropic/{model}",
        ProviderMode.CLOUD_AZURE_OPENAI: "azure/{model}",
        ProviderMode.CLOUD_CUSTOM_ENDPOINT: "openai/{model}",   # OpenAI-compatible wire format
        ProviderMode.LOCAL_OLLAMA: "ollama/{model}",
    }

    def __init__(self, config: ProviderConfig):
        self.config = config

    def _resolve_model_string(self) -> str:
        return self._MODEL_PREFIX[self.config.mode].format(model=self.config.model)

    async def complete(self, request: AIRequest) -> AIResponse:
        kwargs = {
            "model": self._resolve_model_string(),
            "messages": request.messages,
            "temperature": request.temperature,
            "max_tokens": request.max_tokens,
        }
        if request.response_format:
            kwargs["response_format"] = request.response_format
        if self.config.api_key:
            kwargs["api_key"] = self.config.api_key
        if self.config.api_base:
            kwargs["api_base"] = self.config.api_base
        if self.config.organization:
            kwargs["organization"] = self.config.organization

        response = await litellm.acompletion(**kwargs)
        return AIResponse(
            content=response.choices[0].message.content,
            model=self.config.model,
            provider_mode=self.config.mode,
            usage=response.usage.model_dump() if response.usage else {},
        )


def load_provider_for_workspace(workspace_ai_config_row: dict) -> AIProvider:
    """
    workspace_ai_config_row comes straight from the `workspace_ai_config`
    table (see db/schema.sql). This function is the entire boundary between
    "cloud with a client's own key" and "fully offline via Ollama" — every
    caller below is identical regardless of which one it resolves to.
    """
    config = ProviderConfig(**workspace_ai_config_row)
    return AIProvider(config)


class UseCase(ABC):
    """
    Marker base for the four planned AI use cases. Each concrete use case
    (OCR field extraction, categorization fallback, anomaly explanation,
    NL ledger query) should depend only on AIProvider, and where possible
    avoid a full LLM call in the hot path:
      - OCR: dedicated OCR engine (PaddleOCR/Tesseract) extracts raw text;
        AIProvider only does structured field extraction from that text.
      - Categorization: try `categorization_rules` table match first;
        AIProvider is the fallback for unmatched/ambiguous transactions.
      - Anomaly detection: statistical checks (z-score/IQR) flag candidates;
        AIProvider only generates the human-readable explanation.
      - NL ledger query: AIProvider does text-to-SQL against a fixed,
        read-only schema view — never against a live write connection.

    Least-steps principle (see BUSINESS_PRINCIPLES.md): AI does the first
    pass, the human only touches what's uncertain. In practice this means
    every use case above needs a confidence threshold — high-confidence
    results should be auto-applied (posted draft, applied category, silent
    rule update) with one-tap confirmation, not a review form. Only
    low-confidence results should interrupt the user with something to
    fill in. Any use case implementation that surfaces a full form
    regardless of confidence is not meeting this principle.
    """
    pass
