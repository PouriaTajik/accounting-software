"""Request/response models.

Only the shapes shared across routers exist in phase 1. Per-endpoint DTOs land
in phase 2 alongside the logic that produces them -- writing them now would be
guessing at payloads before the operations that return them exist.
"""

from .common import Money, OptimisticUpdate, Page

__all__ = ["Money", "OptimisticUpdate", "Page"]
