"""Open-Meteo ensemble API client: cached, with a bounded retry budget.

One CLI invocation used to make four requests unconditionally. Now a matching
forecast from the last six hours is reused without touching the network, and a
failed request is retried only a couple of times with jittered backoff. A
rate-limited response is not retried at all: it is recorded as a cooldown that
outlives the process, so the next invocation reports the deadline instead of
adding to the pile.
"""

from __future__ import annotations

import datetime as dt
import random
import time
from collections.abc import Callable
from dataclasses import dataclass, field

import httpx

from .cache import CachedForecast, ForecastCache, forecast_key
from .retry import RetryPolicy, UpstreamFailure

# The ensemble models live on Open-Meteo's ensemble host; api.open-meteo.com
# answers `/v1/ensemble` with 404.
BASE_URL = "https://ensemble-api.open-meteo.com/v1/ensemble"
META_URL = "https://ensemble-api.open-meteo.com/data/{model}/static/meta.json"

WEATHERNEXT = "google_weathernext2_ensemble"
ECMWF = "ecmwf_ifs025_ensemble"

HOURLY_VARS = (
    "temperature_2m",
    "precipitation",
    "wind_speed_10m",
    "wind_gusts_10m",
    "cloud_cover",
)

TIMEOUT = 10.0


class FetchError(Exception):
    """Raised when the forecast API cannot be reached or returns an error."""

    def __init__(self, message: str, *, failure: UpstreamFailure | None = None) -> None:
        super().__init__(message)
        self.failure = failure


class CooldownError(FetchError):
    """Raised when Open-Meteo is off limits until a known moment.

    Either the upstream just asked us to back off, or a cooldown recorded by an
    earlier invocation is still in force. Interactive runs report the deadline
    rather than sleeping through it.
    """

    def __init__(
        self,
        message: str,
        *,
        next_attempt: dt.datetime,
        failure: UpstreamFailure | None = None,
    ) -> None:
        super().__init__(message, failure=failure)
        self.next_attempt = next_attempt


@dataclass(frozen=True)
class Ensemble:
    """A raw ensemble response plus the metadata we display in the header."""

    model: str
    latitude: float
    longitude: float
    timezone: str
    utc_offset_seconds: int
    hourly: dict
    run_time: dt.datetime | None = None
    fetched_at: dt.datetime | None = None
    cached: bool = False
    # Served from cache past its freshness window because a refresh failed.
    stale: bool = False
    stale_reason: str | None = None


def _unit_params(units: str) -> dict[str, str]:
    if units == "metric":
        return {
            "temperature_unit": "celsius",
            "wind_speed_unit": "kmh",
            "precipitation_unit": "mm",
        }
    return {
        "temperature_unit": "fahrenheit",
        "wind_speed_unit": "mph",
        "precipitation_unit": "inch",
    }


def ensemble_params(model: str, lat: float, lon: float, days: int, units: str) -> dict[str, str]:
    """Every parameter that shapes the response, and so the cache key."""
    return {
        "latitude": f"{lat:.4f}",
        "longitude": f"{lon:.4f}",
        "models": model,
        "hourly": ",".join(HOURLY_VARS),
        "forecast_days": str(days),
        "timezone": "auto",
        **_unit_params(units),
    }


def _utc(epoch: float) -> dt.datetime:
    return dt.datetime.fromtimestamp(epoch, dt.timezone.utc)


def _build(
    model: str,
    payload: dict,
    *,
    run_time: dt.datetime | None,
    fetched_at: dt.datetime,
    cached: bool = False,
    stale: bool = False,
    stale_reason: str | None = None,
) -> Ensemble:
    """Turn a raw response into an Ensemble. Raises FetchError if unusable."""
    hourly = payload.get("hourly")
    if not hourly or not hourly.get("time"):
        raise FetchError(f"{model}: response contained no hourly data")
    try:
        latitude = float(payload["latitude"])
        longitude = float(payload["longitude"])
        offset = int(payload.get("utc_offset_seconds", 0))
    except (KeyError, TypeError, ValueError) as exc:
        raise FetchError(f"{model}: response was missing its grid point ({exc})") from exc

    return Ensemble(
        model=model,
        latitude=latitude,
        longitude=longitude,
        timezone=payload.get("timezone", "UTC"),
        utc_offset_seconds=offset,
        hourly=hourly,
        run_time=run_time,
        fetched_at=fetched_at,
        cached=cached,
        stale=stale,
        stale_reason=stale_reason,
    )


@dataclass
class Session:
    """One CLI invocation's view of Open-Meteo: transport, cache, retry budget.

    The clock, sleep, and jitter callables are injected so tests are
    deterministic and never wait.
    """

    client: httpx.Client
    cache: ForecastCache | None = None
    policy: RetryPolicy = field(default_factory=RetryPolicy)
    clock: Callable[[], float] = time.time
    monotonic: Callable[[], float] = time.monotonic
    sleep: Callable[[float], None] = time.sleep
    jitter: Callable[[], float] = random.random

    # ---------------------------------------------------------------- public

    def ensemble(
        self,
        model: str,
        lat: float,
        lon: float,
        days: int,
        units: str = "imperial",
        *,
        allow_stale: bool = True,
        refresh: bool = False,
    ) -> Ensemble:
        """One ensemble model for a point, from cache when it is still fresh.

        A fresh hit issues no requests at all, forecast or metadata. When a
        refresh fails and ``allow_stale`` is set, an entry from the last 48
        hours that still covers today is returned with ``stale`` set, so the
        caller can say so; otherwise the failure is raised. ``refresh`` ignores
        the stored entry entirely — but never the cooldown, which no caller may
        opt out of.
        """
        params = ensemble_params(model, lat, lon, days, units)
        key = forecast_key(BASE_URL, params)
        now = self.clock()
        entry = (
            self.cache.load_forecast(key, now=now)
            if self.cache is not None and not refresh
            else None
        )

        if entry is not None and entry.is_fresh(now) and entry.covers_today(now):
            reused = self._from_cache(model, entry, stale=False)
            if reused is not None:
                return reused

        try:
            payload = self._forecast_payload(model, params)
        except FetchError as exc:
            if allow_stale and entry is not None and entry.covers_today(self.clock()):
                fallback = self._from_cache(model, entry, stale=True, reason=str(exc))
                if fallback is not None:
                    return fallback
            raise

        run_time = self.run_time(model)
        fetched_at = self.clock()
        if self.cache is not None:
            self.cache.store_forecast(key, payload, run_time, now=fetched_at)
        return _build(model, payload, run_time=run_time, fetched_at=_utc(fetched_at))

    def run_time(self, model: str) -> dt.datetime | None:
        """Best-effort model initialisation time; None when unavailable."""
        now = self.clock()
        if self.cache is not None:
            hit = self.cache.load_run_time(model, now=now)
            if hit is not None:
                return hit.run_time

        try:
            response = self.get(META_URL.format(model=model))
        except FetchError:
            # A header detail is never worth failing (or delaying) a forecast,
            # and a failed lookup must not be cached as "no run time".
            return None

        run_time = None
        if response.status_code == 200:
            try:
                stamp = response.json().get("last_run_initialisation_time")
            except (ValueError, AttributeError):
                stamp = None
            if isinstance(stamp, (int, float)) and not isinstance(stamp, bool):
                run_time = _utc(stamp)
        if self.cache is not None:
            self.cache.store_run_time(model, run_time, now=self.clock())
        return run_time

    def get(self, url: str, params: dict | None = None) -> httpx.Response:
        """GET within the retry budget, honoring the durable cooldown.

        Transport errors and 5xx responses are retried up to
        ``policy.max_attempts`` times with jittered exponential backoff, never
        waiting longer than ``policy.max_elapsed`` in total. Ordinary 4xx
        responses are returned to the caller unretried; a rate limit raises
        :class:`CooldownError` immediately.
        """
        self._check_cooldown()
        started = self.monotonic()
        attempt = 0
        while True:
            attempt += 1
            failure: UpstreamFailure | None = None
            try:
                response = self.client.get(url, params=params, timeout=TIMEOUT)
            except httpx.TimeoutException:
                reason = f"timed out after {TIMEOUT:g}s"
            except httpx.TransportError as exc:
                reason = str(exc) or exc.__class__.__name__
            except httpx.HTTPError as exc:
                # A bad URL or a redirect loop: another attempt cannot help.
                raise FetchError(str(exc) or exc.__class__.__name__) from exc
            else:
                if response.status_code < 500 and response.status_code != 429:
                    self._record_success()
                    return response
                failure = UpstreamFailure(
                    status_code=response.status_code,
                    retry_after=response.headers.get("retry-after"),
                    reason=response.reason_phrase or None,
                )
                reason = f"HTTP {response.status_code}"
                if failure.is_rate_limited:
                    raise self._cooldown(failure)

            requested = failure.retry_after_delay(self.clock()) if failure else None
            if requested is not None and requested > self.policy.max_inline_wait:
                # The server named a delay we will not sit through.
                raise self._cooldown(failure)

            delay = (
                requested
                if requested is not None
                else self.policy.backoff(attempt, self.jitter())
            )
            elapsed = self.monotonic() - started
            if attempt >= self.policy.max_attempts or elapsed + delay > self.policy.max_elapsed:
                raise FetchError(
                    f"{reason} (gave up after {attempt} attempt"
                    f"{'' if attempt == 1 else 's'})",
                    failure=failure,
                )
            self.sleep(delay)

    def next_attempt(self) -> dt.datetime | None:
        """The active cooldown deadline, or None when a request is allowed."""
        if self.cache is None:
            return None
        deadline = self.cache.active_cooldown(
            now=self.clock(), max_cooldown=self.policy.max_cooldown
        )
        return None if deadline is None else _utc(deadline)

    # --------------------------------------------------------------- private

    def _forecast_payload(self, model: str, params: dict[str, str]) -> dict:
        response = self.get(BASE_URL, params)
        try:
            payload = response.json()
        except ValueError as exc:
            raise FetchError(f"{model}: response was not JSON ({exc})") from exc
        if not isinstance(payload, dict):
            raise FetchError(f"{model}: response was not a JSON object")

        if response.status_code != 200 or payload.get("error"):
            reason = payload.get("reason") or f"HTTP {response.status_code}"
            raise FetchError(
                f"{model}: {reason}",
                failure=UpstreamFailure(
                    status_code=response.status_code,
                    retry_after=response.headers.get("retry-after"),
                    reason=str(reason),
                ),
            )
        # Validate before caching, so a malformed body is never stored.
        _build(model, payload, run_time=None, fetched_at=_utc(self.clock()))
        return payload

    def _from_cache(
        self, model: str, entry: CachedForecast, *, stale: bool, reason: str | None = None
    ) -> Ensemble | None:
        try:
            return _build(
                model,
                entry.payload,
                run_time=entry.run_time,
                fetched_at=_utc(entry.fetched_at),
                cached=True,
                stale=stale,
                stale_reason=reason,
            )
        except FetchError:
            # An entry we can no longer make sense of is a miss, not a failure.
            return None

    def _check_cooldown(self) -> None:
        deadline = self.next_attempt()
        if deadline is not None:
            raise CooldownError(
                "waiting out an earlier Open-Meteo rate limit", next_attempt=deadline
            )

    def _cooldown(self, failure: UpstreamFailure | None) -> CooldownError:
        now = self.clock()
        if self.cache is not None:
            state = self.cache.record_rate_limit(failure, now=now, policy=self.policy)
            deadline = state.next_attempt_after
        else:
            requested = failure.retry_after_delay(now) if failure else None
            deadline = now + self.policy.cooldown_delay(1, requested)
        status = f"HTTP {failure.status_code}" if failure else "rate limited"
        return CooldownError(
            f"Open-Meteo asked us to slow down ({status})",
            next_attempt=_utc(deadline),
            failure=failure,
        )

    def _record_success(self) -> None:
        # A completed request proves we are no longer being rate limited.
        if self.cache is not None and self.cache.retry_state() is not None:
            self.cache.clear_cooldown()
