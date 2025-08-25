from __future__ import annotations
import hashlib
from typing import TypeVar

T = TypeVar("T")


def synthetic_email(name: str | None, domain: str = "example.com") -> str:
    seed = (name or "unknown").encode("utf-8")
    h = hashlib.sha1(seed).hexdigest()[:10]
    return f"user_{h}@{domain}"
