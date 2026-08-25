"""
Provider-agnostic AI layer.

This package is the only place in the monorepo permitted to import an LLM SDK
(`litellm`, and through it `openai`/`anthropic`/`ollama`). Everything else
depends on `AIProvider`, which is what keeps "desktop with your own API key"
and "fully offline on-prem" the same code path with a different config row.
"""

from .provider import (
    AIProvider,
    AIRequest,
    AIResponse,
    ProviderConfig,
    ProviderMode,
    load_provider_for_workspace,
)

__all__ = [
    "AIProvider",
    "AIRequest",
    "AIResponse",
    "ProviderConfig",
    "ProviderMode",
    "load_provider_for_workspace",
]
