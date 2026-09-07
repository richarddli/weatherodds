"""End-to-end CLI behavior with a mocked transport and zip lookup (no network)."""

from __future__ import annotations

import datetime as dt
import gzip
import json

import httpx
import pytest

from weatherodds import cli, fetch, geocode

BOSTON = geocode.Location(zip="02108", name="Boston", lat=42.3583, lon=-71.0603)


def payload(days: int = 4, members: int = 3) -> dict:
    """A response whose days start today in UTC, so none are filtered as past."""
    start = dt.datetime.now(dt.timezone.utc).date()
    times = [
        f"{start + dt.timedelta(days=day)}T{hour:02d}:00"
        for day in range(days)
        for hour in (0, 6, 12, 18)
    ]
    hourly: dict = {"time": times}
    for member in range(members):
        suffix = "" if member == 0 else f"_member{member:02d}"
        hourly[f"temperature_2m{suffix}"] = [50.0 + member for _ in times]
        hourly[f"precipitation{suffix}"] = [0.0 for _ in times]
        hourly[f"wind_speed_10m{suffix}"] = [8.0 for _ in times]
        hourly[f"cloud_cover{suffix}"] = [20.0 for _ in times]
    return {
        "latitude": 42.35,
        "longitude": -71.06,
        "timezone": "UTC",
        "utc_offset_seconds": 0,
        "hourly": hourly,
    }


class Upstream:
    def __init__(self, forecast=None) -> None:
        self.requests: list[httpx.Request] = []
        self.forecast = forecast

    def handle(self, request: httpx.Request) -> httpx.Response:
        self.requests.append(request)
        if request.url.path.endswith("meta.json"):
            return httpx.Response(200, json={"last_run_initialisation_time": 1_700_000_000})
        if self.forecast is not None:
            responder = self.forecast
            return responder(request) if callable(responder) else responder
        return httpx.Response(200, json=payload())


@pytest.fixture
def upstream(tmp_path, monkeypatch) -> Upstream:
    """Points the CLI at a mock transport, a temp cache, and a fixed location."""
    served = Upstream()
    monkeypatch.setenv("WEATHERODDS_CACHE_DIR", str(tmp_path / "cache"))
    monkeypatch.setattr(cli.geocode, "lookup", lambda zip_code: BOSTON)
    # `cli.httpx` is the httpx module itself, so keep a reference to the real
    # class before replacing it with the mock-transport factory.
    real_client = httpx.Client
    monkeypatch.setattr(
        cli.httpx,
        "Client",
        lambda **kwargs: real_client(transport=httpx.MockTransport(served.handle), **kwargs),
    )
    return served


def run_json(capsys, *argv) -> dict:
    assert cli.run(["02108", "--json", *argv]) == 0
    return json.loads(capsys.readouterr().out)


def test_a_repeat_invocation_serves_the_cache(upstream, capsys):
    first = run_json(capsys)
    assert first["cache"] == {"cached": False, "stale": False, "note": None}
    requests_made = len(upstream.requests)
    assert requests_made == 4  # forecast + metadata, for each of two models

    second = run_json(capsys)

    assert len(upstream.requests) == requests_made
    assert second["cache"]["cached"] is True
    assert second["days"] == first["days"]


def test_refresh_fetches_again(upstream, capsys):
    run_json(capsys)
    before = len(upstream.requests)

    assert run_json(capsys, "--refresh")["cache"]["cached"] is False
    assert len(upstream.requests) > before


def test_a_failing_ecmwf_cross_check_still_prints_a_forecast(upstream, capsys):
    def by_model(request: httpx.Request) -> httpx.Response:
        if fetch.ECMWF in str(request.url):
            return httpx.Response(404, json={"error": True, "reason": "model unavailable"})
        return httpx.Response(200, json=payload())

    upstream.forecast = by_model
    report = run_json(capsys)

    assert report["ecmwf"]["used"] is False
    assert "model unavailable" in report["ecmwf"]["note"]
    assert len(report["days"]) == 15 or report["days"], "the primary forecast is still rendered"


def test_a_rate_limit_reports_the_deadline_and_then_stays_offline(upstream, capsys):
    upstream.forecast = httpx.Response(429, headers={"Retry-After": "600"})

    assert cli.run(["02108", "--json"]) == 1
    error = capsys.readouterr().err
    assert "slow down" in error
    assert "Next attempt at" in error
    requests_made = len(upstream.requests)

    # The cooldown outlives the process, so nothing is sent this time.
    assert cli.run(["02108", "--json"]) == 1
    assert len(upstream.requests) == requests_made
    assert "waiting out an earlier Open-Meteo rate limit" in capsys.readouterr().err


def age_cached_forecasts(root, seconds: float) -> None:
    """Backdate stored forecasts so the next run has to go to the network."""
    for path in (root / "cache").glob("forecast-*.json.gz"):
        document = json.loads(gzip.decompress(path.read_bytes()))
        document["fetched_at"] -= seconds
        path.write_bytes(gzip.compress(json.dumps(document).encode()))


def test_a_cached_forecast_is_served_while_the_upstream_is_down(upstream, capsys, tmp_path):
    run_json(capsys)
    age_cached_forecasts(tmp_path, 8 * 3600)
    upstream.forecast = httpx.Response(404, json={"error": True, "reason": "upstream is down"})

    report = run_json(capsys)

    assert report["cache"] == {
        "cached": True,
        "stale": True,
        "note": report["cache"]["note"],
    }
    assert "could not be refreshed" in report["cache"]["note"]
    assert "upstream is down" in report["cache"]["note"]


def test_the_table_renders_without_a_tty(upstream, capsys):
    assert cli.run(["02108", "--days", "3"]) == 0
    out = capsys.readouterr().out
    assert "WeatherNext 2" in out
    assert "Confidence" in out
    assert "(cached)" not in out

    # The same run again, now served from cache, says so in the header.
    assert cli.run(["02108", "--days", "3"]) == 0
    assert "(cached)" in capsys.readouterr().out
