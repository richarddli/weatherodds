"""Durable on-disk cache for forecasts, model run metadata, and cooldowns.

Every entry is a JSON document written atomically (temporary sibling plus
``os.replace``), so an interrupted run leaves the previous entry intact. A
document that cannot be read back as the record it claims to be — truncated,
corrupt, or written by an older schema — is treated as a miss.

Forecast payloads are the raw Open-Meteo ensemble responses, which run to
several megabytes for a 15-day, 50-member model, so they are stored gzipped.
"""

from __future__ import annotations

import datetime as dt
import gzip
import hashlib
import json
import os
import re
import sys
import tempfile
import zlib
from dataclasses import dataclass
from pathlib import Path

from .retry import MAX_COOLDOWN, RetryPolicy, RetryState, UpstreamFailure

# How long a forecast is reused without any request at all. Open-Meteo's
# ensemble models publish twice a day, so six hours never skips more than the
# run that is already on disk by more than half a cycle.
FRESHNESS = 6 * 60 * 60

# How old a forecast may be and still be shown when a refresh fails. Beyond
# this the run is too old to describe today, so a failure is reported instead.
MAX_FALLBACK_AGE = 48 * 60 * 60

# Run metadata is a header detail, and it is refetched whenever a forecast is
# actually refetched; this window only suppresses repeats across back-to-back
# invocations for different locations.
RUN_TIME_FRESHNESS = 60 * 60

# Rate limiting is a property of the caller, not of one location or model, so
# every request shares one cooldown key.
RATE_LIMIT_KEY = "open-meteo"

SCHEMA_VERSION = 1

_UNSAFE = re.compile(r"[^A-Za-z0-9_.-]+")


def default_root() -> Path:
    """Cache directory, overridable with ``WEATHERODDS_CACHE_DIR``."""
    override = os.environ.get("WEATHERODDS_CACHE_DIR")
    if override:
        return Path(override).expanduser()
    if sys.platform == "darwin":
        return Path.home() / "Library" / "Caches" / "weatherodds"
    xdg = os.environ.get("XDG_CACHE_HOME")
    base = Path(xdg).expanduser() if xdg else Path.home() / ".cache"
    return base / "weatherodds"


def forecast_key(url: str, params: dict[str, str]) -> str:
    """Cache key covering every parameter that can change the response.

    Deriving it from the request itself means a new query parameter — a unit, a
    variable, a longer horizon — cannot silently reuse another response.
    """
    canonical = json.dumps({"url": url, "params": params}, sort_keys=True)
    return hashlib.sha256(canonical.encode()).hexdigest()[:16]


def _to_epoch(value: dt.datetime | None) -> float | None:
    return None if value is None else value.timestamp()


def _to_datetime(value: object) -> dt.datetime | None:
    if not isinstance(value, (int, float)) or isinstance(value, bool):
        return None
    return dt.datetime.fromtimestamp(value, dt.timezone.utc)


@dataclass(frozen=True)
class CachedForecast:
    """A stored ensemble response and the run metadata fetched alongside it."""

    key: str
    fetched_at: float
    payload: dict
    run_time: dt.datetime | None

    def age(self, now: float) -> float:
        # A negative age means the clock moved backwards; treat the entry as
        # brand new rather than letting it look fresh forever.
        return max(0.0, now - self.fetched_at)

    def is_fresh(self, now: float, freshness: float = FRESHNESS) -> bool:
        # A timestamp in the future is refreshed rather than trusted.
        return self.fetched_at <= now < self.fetched_at + freshness

    def local_date(self, now: float) -> str:
        """Today's date at the forecast location, from the response's UTC offset."""
        offset = self.payload.get("utc_offset_seconds", 0)
        if not isinstance(offset, (int, float)) or isinstance(offset, bool):
            offset = 0
        zone = dt.timezone(dt.timedelta(seconds=int(offset)))
        return dt.datetime.fromtimestamp(now, zone).date().isoformat()

    def covers_today(self, now: float) -> bool:
        """Whether the stored hourly series still reaches the location's today."""
        times = self.payload.get("hourly", {}).get("time")
        if not isinstance(times, list) or not times:
            return False
        return str(times[-1]).split("T")[0] >= self.local_date(now)


@dataclass(frozen=True)
class CachedRunTime:
    model: str
    fetched_at: float
    run_time: dt.datetime | None


class ForecastCache:
    """Reads and writes the cache directory. Every failure to write is survivable."""

    def __init__(self, root: Path | None = None) -> None:
        self.root = Path(root) if root is not None else default_root()

    # ----------------------------------------------------------------- files

    def _path(self, name: str) -> Path:
        return self.root / name

    def _read(self, name: str, *, compressed: bool = False) -> object | None:
        path = self._path(name)
        try:
            raw = gzip.decompress(path.read_bytes()) if compressed else path.read_bytes()
            return json.loads(raw)
        except (OSError, ValueError, EOFError, zlib.error):
            # Missing, unreadable, truncated, not JSON, or a gzip body damaged
            # in place — which raises zlib.error rather than BadGzipFile — are
            # all misses. Nothing a cache file contains may reach the caller as
            # an exception.
            return None

    def _write(self, name: str, document: dict, *, compressed: bool = False) -> None:
        path = self._path(name)
        raw = json.dumps(document, separators=(",", ":")).encode()
        if compressed:
            raw = gzip.compress(raw, compresslevel=6, mtime=0)
        try:
            path.parent.mkdir(parents=True, exist_ok=True)
            fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=f".{path.name}.", suffix=".tmp")
            try:
                with os.fdopen(fd, "wb") as handle:
                    handle.write(raw)
                    handle.flush()
                    os.fsync(handle.fileno())
                os.replace(tmp, path)
            except BaseException:
                Path(tmp).unlink(missing_ok=True)
                raise
        except OSError:
            # A cache that cannot be written must not fail the forecast.
            pass

    def _remove(self, name: str) -> None:
        try:
            self._path(name).unlink(missing_ok=True)
        except OSError:
            pass

    # -------------------------------------------------------------- forecast

    def forecast_name(self, key: str) -> str:
        return f"forecast-{_UNSAFE.sub('_', key)}-v{SCHEMA_VERSION}.json.gz"

    def load_forecast(self, key: str, *, now: float) -> CachedForecast | None:
        """The stored response for ``key``, or None when missing or too old."""
        data = self._read(self.forecast_name(key), compressed=True)
        if not isinstance(data, dict) or data.get("schema_version") != SCHEMA_VERSION:
            return None
        if data.get("key") != key:
            return None
        payload = data.get("payload")
        fetched_at = data.get("fetched_at")
        if not isinstance(payload, dict) or not isinstance(fetched_at, (int, float)):
            return None
        if isinstance(fetched_at, bool) or not payload.get("hourly"):
            return None
        entry = CachedForecast(
            key=key,
            fetched_at=float(fetched_at),
            payload=payload,
            run_time=_to_datetime(data.get("run_time")),
        )
        return entry if entry.age(now) < MAX_FALLBACK_AGE else None

    def store_forecast(
        self, key: str, payload: dict, run_time: dt.datetime | None, *, now: float
    ) -> None:
        self._write(
            self.forecast_name(key),
            {
                "schema_version": SCHEMA_VERSION,
                "key": key,
                "fetched_at": now,
                "run_time": _to_epoch(run_time),
                "payload": payload,
            },
            compressed=True,
        )

    # -------------------------------------------------------------- run time

    def run_time_name(self, model: str) -> str:
        return f"runtime-{_UNSAFE.sub('_', model)}-v{SCHEMA_VERSION}.json"

    def load_run_time(self, model: str, *, now: float) -> CachedRunTime | None:
        """Fresh run metadata for ``model``; a stale or corrupt entry is a miss.

        A cached ``None`` is a real answer — the model publishes no metadata —
        and is honored, so a missing endpoint is not re-requested every run.
        """
        data = self._read(self.run_time_name(model))
        if not isinstance(data, dict) or data.get("schema_version") != SCHEMA_VERSION:
            return None
        if data.get("model") != model:
            return None
        fetched_at = data.get("fetched_at")
        if not isinstance(fetched_at, (int, float)) or isinstance(fetched_at, bool):
            return None
        fetched_at = float(fetched_at)
        if not fetched_at <= now < fetched_at + RUN_TIME_FRESHNESS:
            return None
        return CachedRunTime(
            model=model, fetched_at=fetched_at, run_time=_to_datetime(data.get("run_time"))
        )

    def store_run_time(self, model: str, run_time: dt.datetime | None, *, now: float) -> None:
        self._write(
            self.run_time_name(model),
            {
                "schema_version": SCHEMA_VERSION,
                "model": model,
                "fetched_at": now,
                "run_time": _to_epoch(run_time),
            },
        )

    # -------------------------------------------------------------- cooldown

    def cooldown_name(self, key: str = RATE_LIMIT_KEY) -> str:
        return f"cooldown-{_UNSAFE.sub('_', key)}-v{RetryState.SCHEMA_VERSION}.json"

    def retry_state(self, key: str = RATE_LIMIT_KEY) -> RetryState | None:
        return RetryState.from_dict(self._read(self.cooldown_name(key)), key)

    def active_cooldown(
        self,
        *,
        now: float,
        key: str = RATE_LIMIT_KEY,
        max_cooldown: float = MAX_COOLDOWN,
    ) -> float | None:
        """The deadline holding calls back, or None when a request is allowed.

        ``max_cooldown`` must match the policy that wrote the record, so a
        caller with a longer cap is not let back on the wire early.
        """
        state = self.retry_state(key)
        return None if state is None else state.active_deadline(now, max_cooldown)

    def record_rate_limit(
        self,
        failure: UpstreamFailure | None,
        *,
        now: float,
        policy: RetryPolicy,
        key: str = RATE_LIMIT_KEY,
    ) -> RetryState:
        """Extend the cooldown by one failure and persist it."""
        previous = self.retry_state(key)
        failures = (previous.failure_count(now) if previous else 0) + 1
        retry_after = failure.retry_after_delay(now) if failure else None
        state = RetryState(
            key=key,
            consecutive_failures=failures,
            recorded_at=now,
            next_attempt_after=now + policy.cooldown_delay(failures, retry_after),
        )
        self._write(self.cooldown_name(key), state.to_dict())
        return state

    def clear_cooldown(self, key: str = RATE_LIMIT_KEY) -> None:
        self._remove(self.cooldown_name(key))
