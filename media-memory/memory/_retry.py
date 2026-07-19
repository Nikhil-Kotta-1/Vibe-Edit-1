"""Tiny retry helper for transient cloud errors (Vertex rate limits / 429s, §13 risk).

No hard dependency on google libs — transience is detected by exception type name or
message, so this works whether or not google.api_core is importable.
"""
from __future__ import annotations

import logging
import time

log = logging.getLogger("media-memory.retry")

_TRANSIENT_TYPES = {
    "ResourceExhausted", "ServiceUnavailable", "DeadlineExceeded",
    "TooManyRequests", "InternalServerError", "Aborted",
}
_TRANSIENT_MARKERS = ("429", "resource exhausted", "quota", "rate limit", "unavailable", "deadline exceeded")


def _is_transient(e: Exception) -> bool:
    if type(e).__name__ in _TRANSIENT_TYPES:
        return True
    msg = str(e).lower()
    return any(m in msg for m in _TRANSIENT_MARKERS)


def with_retry(fn, *args, attempts: int = 4, base_delay: float = 2.0, **kwargs):
    """Call fn with exponential backoff on transient errors. Non-transient errors raise immediately."""
    for i in range(attempts):
        try:
            return fn(*args, **kwargs)
        except Exception as e:
            if i == attempts - 1 or not _is_transient(e):
                raise
            delay = base_delay * (2**i)
            log.warning("transient error %s; retry %d/%d in %.1fs", type(e).__name__, i + 1, attempts - 1, delay)
            time.sleep(delay)
