"""Cache, retry, and cooldown behavior, with mocked transport, clock, and jitter.

Nothing here touches the network or sleeps: the session's clock, sleep, and
jitter callables are injected, and every response comes from an
``httpx.MockTransport``.
"""

from __future__ import annotations

import datetime as dt
import os

import httpx
import pytest

from weatherodds import cache as cache_mod
from weatherodds import fetch
from weatherodds.cache import ForecastCache
from weatherodds.retry import RetryPolicy, RetryState, UpstreamFailure, parse_retry_after

# 2023-11-14T22:13:20Z — the fixtures below are built around this instant.
START = 1_700_000_000.0
START_DATE = dt.datetime.fromtimestamp(START, dt.timezone.utc).date()
RUN_STAMP = START - 3600


class Clock:
    """A clock that only moves when the code under test sleeps or a test says so."""

    def __init__(self, start: float = START) -> None:
        self.now = start
        self.slept: list[float] = []

    def time(self) -> float:
        return self.now

    def monotonic(self) -> float:
        return self.now

    def sleep(self, seconds: float) -> None:
        self.slept.append(seconds)
        self.now += seconds

    def advance(self, seconds: float) -> None:
        self.now += seconds


def make_payload(start_date: dt.date = START_DATE, days: int = 3, members: int = 2) -> dict:
    times = [
        f"{start_date + dt.timedelta(days=day)}T{hour:02d}:00"
        for day in range(days)
        for hour in (0, 6, 12, 18)
    ]
    hourly: dict = {"time": times}
    for member in range(members):
        suffix = "" if member == 0 else f"_member{member:02d}"
        hourly[f"temperature_2m{suffix}"] = [50.0 + member for _ in times]
        hourly[f"precipitation{suffix}"] = [0.0 for _ in times]
    return {
        "latitude": 42.35,
        "longitude": -71.06,
        "timezone": "UTC",
        "utc_offset_seconds": 0,
        "hourly": hourly,
    }


class Upstream:
    """Records requests and answers them from canned responses."""

    def __init__(self, forecast=None, meta=None) -> None:
        self.requests: list[httpx.Request] = []
        self.forecast = forecast if forecast is not None else httpx.Response(
            200, json=make_payload()
        )
        self.meta = meta if meta is not None else httpx.Response(
            200, json={"last_run_initialisation_time": RUN_STAMP}
        )

    def handle(self, request: httpx.Request) -> httpx.Response:
        self.requests.append(request)
        responder = self.meta if request.url.path.endswith("meta.json") else self.forecast
        if callable(responder):
            return responder(request)
        if isinstance(responder, list):
            return responder.pop(0)
        return responder

    @property
    def paths(self) -> list[str]:
        return [request.url.path for request in self.requests]

    @property
    def forecast_requests(self) -> list[httpx.Request]:
        return [r for r in self.requests if not r.url.path.endswith("meta.json")]

    @property
    def meta_requests(self) -> list[httpx.Request]:
        return [r for r in self.requests if r.url.path.endswith("meta.json")]

    def client(self) -> httpx.Client:
        return httpx.Client(transport=httpx.MockTransport(self.handle))


def make_session(
    upstream: Upstream,
    root,
    clock: Clock,
    *,
    policy: RetryPolicy | None = None,
    jitter: float = 0.5,
) -> fetch.Session:
    return fetch.Session(
        client=upstream.client(),
        cache=ForecastCache(root),
        policy=policy or RetryPolicy(),
        clock=clock.time,
        monotonic=clock.monotonic,
        sleep=clock.sleep,
        jitter=lambda: jitter,
    )


def get_forecast(session: fetch.Session, **kwargs) -> fetch.Ensemble:
    params = {"lat": 42.3583, "lon": -71.0603, "days": 3, "units": "imperial"}
    params.update(kwargs)
    return session.ensemble(
        fetch.WEATHERNEXT, params["lat"], params["lon"], params["days"], params["units"]
    )


@pytest.fixture
def clock() -> Clock:
    return Clock()


# --------------------------------------------------------------------------- #
# cache reuse
# --------------------------------------------------------------------------- #


def test_second_identical_invocation_makes_no_requests(tmp_path, clock):
    upstream = Upstream()
    first = get_forecast(make_session(upstream, tmp_path, clock))
    assert len(upstream.forecast_requests) == 1
    assert len(upstream.meta_requests) == 1
    assert first.cached is False

    clock.advance(60)
    # A separate session, as a second CLI invocation would be.
    second = get_forecast(make_session(upstream, tmp_path, clock))

    assert len(upstream.requests) == 2, "no forecast or metadata request may be repeated"
    assert second.cached is True
    assert second.stale is False
    assert second.run_time == first.run_time
    assert second.hourly == first.hourly


@pytest.mark.parametrize(
    "changed",
    [{"units": "metric"}, {"days": 5}, {"lat": 40.0}, {"lon": -70.0}],
)
def test_changed_parameters_miss_the_cache(tmp_path, clock, changed):
    upstream = Upstream()
    session = make_session(upstream, tmp_path, clock)
    get_forecast(session)
    get_forecast(session, **changed)

    assert len(upstream.forecast_requests) == 2


def test_a_different_model_misses_the_cache(tmp_path, clock):
    upstream = Upstream()
    session = make_session(upstream, tmp_path, clock)
    session.ensemble(fetch.WEATHERNEXT, 42.0, -71.0, 3)
    session.ensemble(fetch.ECMWF, 42.0, -71.0, 3)

    assert len(upstream.forecast_requests) == 2
    assert len(upstream.meta_requests) == 2, "run metadata is per model"


def test_expired_forecast_is_refetched(tmp_path, clock):
    upstream = Upstream()
    get_forecast(make_session(upstream, tmp_path, clock))

    clock.advance(cache_mod.FRESHNESS - 1)
    assert get_forecast(make_session(upstream, tmp_path, clock)).cached is True
    assert len(upstream.forecast_requests) == 1

    clock.advance(2)
    upstream.forecast = httpx.Response(200, json=make_payload(START_DATE, days=4))
    refreshed = get_forecast(make_session(upstream, tmp_path, clock))

    assert len(upstream.forecast_requests) == 2
    assert refreshed.cached is False


def test_cache_entry_that_no_longer_reaches_today_is_refetched(tmp_path, clock):
    upstream = Upstream()
    get_forecast(make_session(upstream, tmp_path, clock))

    # Still inside the freshness window, but the stored days are all in the past.
    clock.advance(cache_mod.FRESHNESS - 60)
    clock.advance(3 * 24 * 3600 - cache_mod.FRESHNESS + 60)
    clock.now = START + 4 * 24 * 3600
    upstream.forecast = httpx.Response(
        200, json=make_payload(START_DATE + dt.timedelta(days=4))
    )
    assert get_forecast(make_session(upstream, tmp_path, clock)).cached is False


def test_run_metadata_is_reused_across_locations(tmp_path, clock):
    upstream = Upstream()
    session = make_session(upstream, tmp_path, clock)
    get_forecast(session)
    get_forecast(session, lat=40.7)

    assert len(upstream.forecast_requests) == 2
    assert len(upstream.meta_requests) == 1


def test_refresh_ignores_the_stored_forecast(tmp_path, clock):
    upstream = Upstream()
    session = make_session(upstream, tmp_path, clock)
    get_forecast(session)
    session.ensemble(fetch.WEATHERNEXT, 42.3583, -71.0603, 3, "imperial", refresh=True)

    assert len(upstream.forecast_requests) == 2


# --------------------------------------------------------------------------- #
# durability
# --------------------------------------------------------------------------- #


def test_corrupt_entries_are_misses(tmp_path, clock):
    upstream = Upstream()
    cache = ForecastCache(tmp_path)
    get_forecast(make_session(upstream, tmp_path, clock))

    forecast_file = next(tmp_path.glob("forecast-*.json.gz"))
    forecast_file.write_bytes(b"not gzip")
    (tmp_path / cache.run_time_name(fetch.WEATHERNEXT)).write_text("{ truncated")

    assert cache.load_forecast(forecast_file.name.split("-")[1], now=clock.time()) is None
    reread = get_forecast(make_session(upstream, tmp_path, clock))

    assert reread.cached is False
    assert len(upstream.forecast_requests) == 2
    assert len(upstream.meta_requests) == 2


def test_entry_from_another_schema_or_key_is_a_miss(tmp_path, clock):
    cache = ForecastCache(tmp_path)
    cache.store_forecast("abc123", make_payload(), None, now=clock.time())

    assert cache.load_forecast("abc123", now=clock.time()) is not None
    assert cache.load_forecast("different", now=clock.time()) is None

    cache._write(
        cache.forecast_name("abc123"),
        {"schema_version": 99, "key": "abc123", "fetched_at": clock.time(), "payload": {}},
        compressed=True,
    )
    assert cache.load_forecast("abc123", now=clock.time()) is None


def test_writes_are_atomic(tmp_path, clock, monkeypatch):
    cache = ForecastCache(tmp_path)
    cache.store_forecast("abc123", make_payload(), None, now=clock.time())
    original = cache.load_forecast("abc123", now=clock.time())

    def explode(*args, **kwargs):
        raise OSError("disk full")

    monkeypatch.setattr(os, "replace", explode)
    cache.store_forecast("abc123", make_payload(days=9), None, now=clock.time() + 1)

    survived = cache.load_forecast("abc123", now=clock.time())
    assert survived == original, "a failed write must not damage the previous entry"
    assert not list(tmp_path.glob("*.tmp")), "no partial file is left behind"


def test_an_unwritable_cache_does_not_fail_the_forecast(tmp_path, clock):
    upstream = Upstream()
    unwritable = tmp_path / "nope"
    unwritable.write_text("not a directory")
    session = make_session(upstream, unwritable, clock)

    assert get_forecast(session).cached is False


# --------------------------------------------------------------------------- #
# retries
# --------------------------------------------------------------------------- #


def test_server_error_is_retried_with_jittered_backoff(tmp_path, clock):
    upstream = Upstream(
        forecast=[httpx.Response(503), httpx.Response(200, json=make_payload())]
    )
    policy = RetryPolicy(base_delay=0.5, jitter_fraction=0.2)
    session = make_session(upstream, tmp_path, clock, policy=policy, jitter=0.5)

    assert get_forecast(session).cached is False
    assert len(upstream.forecast_requests) == 2
    assert clock.slept == [pytest.approx(0.45)]  # 0.5 * (1 - 0.2 * 0.5)


def test_timeouts_are_retried_within_the_attempt_budget(tmp_path, clock):
    def always_timeout(request):
        raise httpx.ConnectTimeout("too slow", request=request)

    upstream = Upstream(forecast=always_timeout)
    policy = RetryPolicy(max_attempts=3)
    session = make_session(upstream, tmp_path, clock, policy=policy)

    with pytest.raises(fetch.FetchError) as excinfo:
        get_forecast(session)

    assert len(upstream.forecast_requests) == 3
    assert len(clock.slept) == 2
    assert clock.slept == sorted(clock.slept), "backoff grows"
    assert "gave up after 3 attempts" in str(excinfo.value)


def test_the_time_budget_stops_retrying_early(tmp_path, clock):
    def always_500(request):
        return httpx.Response(500)

    upstream = Upstream(forecast=always_500)
    # One 4s sleep fits the budget; a second 8s one would not.
    policy = RetryPolicy(base_delay=4.0, max_attempts=9, max_elapsed=10.0, jitter_fraction=0.0)
    session = make_session(upstream, tmp_path, clock, policy=policy)

    with pytest.raises(fetch.FetchError):
        get_forecast(session)

    assert clock.slept == [4.0]
    assert len(upstream.forecast_requests) == 2


def test_client_errors_are_not_retried(tmp_path, clock):
    upstream = Upstream(forecast=httpx.Response(400, json={"error": True, "reason": "bad zip"}))
    session = make_session(upstream, tmp_path, clock)

    with pytest.raises(fetch.FetchError) as excinfo:
        get_forecast(session)

    assert len(upstream.forecast_requests) == 1
    assert clock.slept == []
    assert "bad zip" in str(excinfo.value)


def test_a_short_retry_after_is_honored_inline(tmp_path, clock):
    upstream = Upstream(
        forecast=[
            httpx.Response(503, headers={"Retry-After": "2"}),
            httpx.Response(200, json=make_payload()),
        ]
    )
    session = make_session(upstream, tmp_path, clock, policy=RetryPolicy(max_inline_wait=5.0))

    assert get_forecast(session).cached is False
    assert clock.slept == [2.0]


def test_a_long_retry_after_becomes_a_cooldown(tmp_path, clock):
    upstream = Upstream(forecast=httpx.Response(503, headers={"Retry-After": "600"}))
    session = make_session(upstream, tmp_path, clock, policy=RetryPolicy(max_inline_wait=5.0))

    with pytest.raises(fetch.CooldownError) as excinfo:
        get_forecast(session)

    assert clock.slept == []
    assert excinfo.value.next_attempt.timestamp() == pytest.approx(clock.time() + 600)


# --------------------------------------------------------------------------- #
# rate limiting and cooldown
# --------------------------------------------------------------------------- #


def test_rate_limit_is_not_retried_and_persists_a_cooldown(tmp_path, clock):
    upstream = Upstream(forecast=httpx.Response(429, headers={"Retry-After": "300"}))
    session = make_session(upstream, tmp_path, clock)

    with pytest.raises(fetch.CooldownError) as excinfo:
        get_forecast(session)

    assert len(upstream.requests) == 1
    assert clock.slept == []
    assert excinfo.value.next_attempt.timestamp() == pytest.approx(START + 300)

    # A later invocation, with its own session, must not call Open-Meteo at all.
    clock.advance(60)
    later = make_session(upstream, tmp_path, clock)
    with pytest.raises(fetch.CooldownError):
        get_forecast(later)
    assert later.run_time(fetch.WEATHERNEXT) is None
    assert len(upstream.requests) == 1

    # Once the deadline passes, requests resume.
    clock.advance(300)
    upstream.forecast = httpx.Response(200, json=make_payload())
    assert get_forecast(make_session(upstream, tmp_path, clock)).cached is False


def test_cooldown_backs_off_when_retry_after_is_missing_or_malformed(tmp_path, clock):
    upstream = Upstream(forecast=httpx.Response(429, headers={"Retry-After": "soon"}))
    policy = RetryPolicy(cooldown_base=60.0)

    for expected in (60.0, 120.0, 240.0):
        clock.advance(24 * 3600)  # each attempt happens long after the last
        session = make_session(upstream, tmp_path, clock, policy=policy)
        with pytest.raises(fetch.CooldownError) as excinfo:
            get_forecast(session)
        assert excinfo.value.next_attempt.timestamp() == pytest.approx(clock.time() + expected)


def test_cooldown_is_capped(tmp_path, clock):
    upstream = Upstream(forecast=httpx.Response(429, headers={"Retry-After": "999999"}))
    policy = RetryPolicy()
    session = make_session(upstream, tmp_path, clock, policy=policy)

    with pytest.raises(fetch.CooldownError) as excinfo:
        get_forecast(session)

    assert excinfo.value.next_attempt.timestamp() == pytest.approx(
        clock.time() + policy.max_cooldown
    )


def test_a_cooldown_recorded_in_the_future_is_ignored(tmp_path, clock):
    cache = ForecastCache(tmp_path)
    cache.record_rate_limit(
        UpstreamFailure(429, retry_after="300"), now=clock.time() + 10_000, policy=RetryPolicy()
    )

    # The record was written by a clock ahead of ours; it must not park the CLI.
    assert cache.active_cooldown(now=clock.time()) is None


def test_success_clears_the_cooldown(tmp_path, clock):
    cache = ForecastCache(tmp_path)
    cache.record_rate_limit(
        UpstreamFailure(429, retry_after="60"), now=clock.time(), policy=RetryPolicy()
    )
    clock.advance(61)

    upstream = Upstream()
    get_forecast(make_session(upstream, tmp_path, clock))

    assert cache.retry_state() is None


# --------------------------------------------------------------------------- #
# cached data during failures
# --------------------------------------------------------------------------- #


def test_a_failed_refresh_falls_back_to_the_cached_forecast(tmp_path, clock):
    upstream = Upstream()
    get_forecast(make_session(upstream, tmp_path, clock))

    clock.advance(cache_mod.FRESHNESS + 3600)
    upstream.forecast = httpx.Response(500)
    session = make_session(upstream, tmp_path, clock, policy=RetryPolicy(max_attempts=1))
    stale = get_forecast(session)

    assert stale.cached is True
    assert stale.stale is True
    assert "HTTP 500" in (stale.stale_reason or "")
    assert stale.fetched_at.timestamp() == pytest.approx(START)


def test_a_cooldown_still_serves_the_cached_forecast(tmp_path, clock):
    upstream = Upstream()
    get_forecast(make_session(upstream, tmp_path, clock))

    clock.advance(cache_mod.FRESHNESS + 60)
    upstream.forecast = httpx.Response(429, headers={"Retry-After": "600"})
    stale = get_forecast(make_session(upstream, tmp_path, clock))

    assert stale.stale is True
    assert ForecastCache(tmp_path).active_cooldown(now=clock.time()) is not None


def test_a_forecast_too_old_to_reuse_raises(tmp_path, clock):
    upstream = Upstream()
    get_forecast(make_session(upstream, tmp_path, clock))

    clock.advance(cache_mod.MAX_FALLBACK_AGE + 60)
    upstream.forecast = httpx.Response(500)
    session = make_session(upstream, tmp_path, clock, policy=RetryPolicy(max_attempts=1))

    with pytest.raises(fetch.FetchError):
        get_forecast(session)


def test_stale_fallback_is_refused_when_it_no_longer_covers_today(tmp_path, clock):
    # A two-day forecast: it stops describing anything the day after tomorrow.
    upstream = Upstream(forecast=httpx.Response(200, json=make_payload(days=2)))
    get_forecast(make_session(upstream, tmp_path, clock))

    upstream.forecast = httpx.Response(500)
    clock.now = START + 20 * 3600  # still the second stored day
    session = make_session(upstream, tmp_path, clock, policy=RetryPolicy(max_attempts=1))
    assert get_forecast(session).stale is True

    clock.now = START + 40 * 3600  # inside the fallback window, past the last day
    session = make_session(upstream, tmp_path, clock, policy=RetryPolicy(max_attempts=1))
    with pytest.raises(fetch.FetchError):
        get_forecast(session)


def test_optional_ecmwf_failure_leaves_the_primary_model_intact(tmp_path, clock):
    def by_model(request: httpx.Request) -> httpx.Response:
        if fetch.ECMWF in str(request.url):
            return httpx.Response(404, json={"error": True, "reason": "no such model"})
        return httpx.Response(200, json=make_payload())

    upstream = Upstream(forecast=by_model)
    session = make_session(upstream, tmp_path, clock)

    assert session.ensemble(fetch.WEATHERNEXT, 42.0, -71.0, 3).cached is False
    with pytest.raises(fetch.FetchError) as excinfo:
        session.ensemble(fetch.ECMWF, 42.0, -71.0, 3)

    assert "no such model" in str(excinfo.value)
    assert ForecastCache(tmp_path).active_cooldown(now=clock.time()) is None


# --------------------------------------------------------------------------- #
# retry policy units
# --------------------------------------------------------------------------- #


@pytest.mark.parametrize(
    "header,expected",
    [
        ("120", 120.0),
        ("  120  ", 120.0),
        ("0", None),
        ("-5", None),
        ("later", None),
        ("", None),
        (None, None),
        ("Tue, 14 Nov 2023 22:18:20 GMT", 300.0),  # START + 300
        ("Tue, 14 Nov 2023 22:00:00 GMT", None),  # already elapsed
    ],
)
def test_parse_retry_after(header, expected):
    assert parse_retry_after(header, START) == (
        None if expected is None else pytest.approx(expected)
    )


def test_backoff_is_capped_and_jitter_only_subtracts():
    policy = RetryPolicy(base_delay=1.0, multiplier=2.0, max_delay=8.0, jitter_fraction=0.2)

    assert policy.backoff(1, jitter=0.0) == 1.0
    assert policy.backoff(2, jitter=0.0) == 2.0
    assert policy.backoff(99, jitter=0.0) == 8.0
    assert policy.backoff(3, jitter=1.0) == pytest.approx(3.2)
    assert 0 < policy.backoff(3, jitter=0.5) <= policy.backoff(3, jitter=0.0)


def test_retry_state_round_trips_and_rejects_corruption():
    state = RetryState(
        key="open-meteo", consecutive_failures=2, recorded_at=START, next_attempt_after=START + 60
    )
    assert RetryState.from_dict(state.to_dict(), "open-meteo") == state
    assert RetryState.from_dict(state.to_dict(), "other-key") is None
    assert RetryState.from_dict({"schema_version": 1, "key": "open-meteo"}, "open-meteo") is None
    assert RetryState.from_dict("garbage", "open-meteo") is None


def test_an_expired_record_still_counts_toward_the_next_backoff():
    state = RetryState(
        key="open-meteo", consecutive_failures=3, recorded_at=START, next_attempt_after=START + 60
    )
    assert state.active_deadline(START + 120) is None
    assert state.failure_count(START + 120) == 3
