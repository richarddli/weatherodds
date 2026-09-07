"""Retry budget, ``Retry-After`` parsing, and durable cooldown records.

The CLI is interactive, so the inline retry budget is deliberately small: a
couple of quick jittered attempts measured in seconds. A delay the server asks
for that is longer than :attr:`RetryPolicy.max_inline_wait` is never slept on;
it becomes a cooldown persisted next to the forecast cache, so the next
invocation reports the deadline instead of hammering an upstream that already
said no.
"""

from __future__ import annotations

import datetime as dt
import email.utils
from dataclasses import dataclass

# Ceiling applied to any persisted cooldown, including one the server asked
# for. It matches the forecast freshness window: while a cooldown is in force a
# cached forecast from within that window is still served, so the cap bounds
# how long a stale clock or an absurd header can keep the CLI offline.
MAX_COOLDOWN = 6 * 60 * 60

# Clamps the exponent so a corrupt or absurd failure counter stays finite.
MAX_BACKOFF_EXPONENT = 16


def _clamp_unit(value: float) -> float:
    return min(max(value, 0.0), 1.0)


@dataclass(frozen=True)
class UpstreamFailure:
    """HTTP-level detail from a failed upstream response.

    Captured before the body is decoded, so a rate-limit response with an HTML
    body still carries its status code and headers. ``retry_after`` is kept
    verbatim: resolving its HTTP-date form needs the clock reading used by the
    retry policy, not the moment the header arrived.
    """

    status_code: int
    retry_after: str | None = None
    reason: str | None = None

    @property
    def is_rate_limited(self) -> bool:
        """Whether the upstream asked every caller to stop, not just this one."""
        return self.status_code == 429

    def retry_after_delay(self, now: float) -> float | None:
        return parse_retry_after(self.retry_after, now)


def parse_retry_after(value: str | None, now: float) -> float | None:
    """Seconds to wait per RFC 9110 ``Retry-After``, or None when unusable.

    Both forms are accepted: delta-seconds and an HTTP-date. A missing,
    malformed, or already-elapsed value returns None so the caller falls back
    to its own backoff rather than retrying immediately.
    """
    if value is None:
        return None
    text = value.strip()
    if not text:
        return None

    # delta-seconds is an unsigned integer; anything else is an HTTP-date.
    if text.isdigit():
        seconds = float(text)
        return seconds if seconds > 0 else None

    try:
        parsed = email.utils.parsedate_to_datetime(text)
    except (TypeError, ValueError):
        return None
    if parsed is None:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=dt.timezone.utc)
    delay = parsed.timestamp() - now
    return delay if delay > 0 else None


@dataclass(frozen=True)
class RetryPolicy:
    """The documented retry budget for one CLI invocation.

    Inline retries cover transport errors and 5xx responses: at most
    ``max_attempts`` requests per URL, separated by capped exponential backoff
    with subtractive jitter, and never running past ``max_elapsed`` seconds of
    waiting. Rate limiting is not retried inline at all — it is recorded as a
    cooldown, which starts at ``cooldown_base`` and doubles per consecutive
    rate-limited invocation whenever the server sends no usable
    ``Retry-After``.
    """

    base_delay: float = 0.5
    multiplier: float = 2.0
    max_delay: float = 8.0
    max_attempts: int = 3
    max_elapsed: float = 20.0
    # Jitter is subtracted, so successive delays stay ordered and never exceed
    # the cap.
    jitter_fraction: float = 0.2
    max_inline_wait: float = 5.0
    cooldown_base: float = 60.0
    max_cooldown: float = MAX_COOLDOWN

    def backoff(self, attempt: int, jitter: float = 0.0) -> float:
        """Delay before retrying, where the first completed attempt is 1."""
        exponent = min(max(attempt, 1) - 1, MAX_BACKOFF_EXPONENT)
        capped = min(self.base_delay * self.multiplier**exponent, self.max_delay)
        return capped * (1 - self.jitter_fraction * _clamp_unit(jitter))

    def cooldown_delay(
        self, consecutive_failures: int, retry_after: float | None = None
    ) -> float:
        """How long to stay off Open-Meteo after a rate-limited response.

        A usable ``Retry-After`` wins over local backoff, still capped by
        ``max_cooldown``.
        """
        if retry_after is not None:
            return min(retry_after, self.max_cooldown)
        exponent = min(max(consecutive_failures, 1) - 1, MAX_BACKOFF_EXPONENT)
        return min(self.cooldown_base * self.multiplier**exponent, self.max_cooldown)


@dataclass(frozen=True)
class RetryState:
    """Durable cooldown for one retry key.

    ``recorded_at`` is kept so a clock change cannot park the CLI: a record
    written in the future is ignored, and a deadline further out than
    :data:`MAX_COOLDOWN` past its recording is clamped.
    """

    SCHEMA_VERSION = 1

    key: str
    consecutive_failures: int
    recorded_at: float
    next_attempt_after: float

    def active_deadline(self, now: float, max_cooldown: float = MAX_COOLDOWN) -> float | None:
        """The deadline this record imposes now, or None when a call is allowed."""
        if now < self.recorded_at:
            return None
        deadline = min(self.next_attempt_after, self.recorded_at + max_cooldown)
        return deadline if now < deadline else None

    def failure_count(self, now: float) -> int:
        """The count a following failure builds on.

        An expired record still counts, so a persistently rate-limited upstream
        does not restart at the base delay on every invocation.
        """
        return self.consecutive_failures if now >= self.recorded_at else 0

    def to_dict(self) -> dict:
        return {
            "schema_version": self.SCHEMA_VERSION,
            "key": self.key,
            "consecutive_failures": self.consecutive_failures,
            "recorded_at": self.recorded_at,
            "next_attempt_after": self.next_attempt_after,
        }

    @classmethod
    def from_dict(cls, data: object, key: str) -> RetryState | None:
        """Rebuild a record, or None when it is corrupt or for another key."""
        if not isinstance(data, dict) or data.get("schema_version") != cls.SCHEMA_VERSION:
            return None
        if data.get("key") != key:
            return None
        try:
            failures = int(data["consecutive_failures"])
            recorded_at = float(data["recorded_at"])
            next_attempt_after = float(data["next_attempt_after"])
        except (KeyError, TypeError, ValueError):
            return None
        if failures < 1:
            return None
        return cls(
            key=key,
            consecutive_failures=failures,
            recorded_at=recorded_at,
            next_attempt_after=next_attempt_after,
        )
