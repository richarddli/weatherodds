"""End-to-end CLI behavior with a mocked transport and zip lookup (no network)."""

from __future__ import annotations

import datetime as dt
import gzip
import json

import httpx
import pytest

from weatherodds import cli, fetch, geocode

BOSTON = geocode.Location(
    id="postal:US:02108", name="Boston", lat=42.3583, lon=-71.0603,
    country_code="US", postal_code="02108",
)


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
        self.geocoding = None

    def handle(self, request: httpx.Request) -> httpx.Response:
        self.requests.append(request)
        if request.url.host == "geocoding-api.open-meteo.com":
            return httpx.Response(200, json=self.geocoding)
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


BRNO_RESULT = {
    "id": 3078610, "name": "Brno", "latitude": 49.19522, "longitude": 16.60796,
    "country_code": "CZ", "country": "Czechia", "admin1": "South Moravian",
    "timezone": "Europe/Prague", "feature_code": "PPLA",
}


def test_international_cli_and_repeat_cache(upstream, capsys):
    upstream.geocoding = {"results": [BRNO_RESULT]}
    argv = ["Brno", "--country", "cz", "--units", "metric", "--json"]
    assert cli.run(argv) == 0
    report = json.loads(capsys.readouterr().out)
    assert report["location"]["id"] == "geonames:3078610"
    assert report["location"]["country_code"] == "CZ"
    assert report["location"]["zip"] is None
    assert report["location"]["postal_code"] is None
    assert report["units"] == "metric"
    assert "high_c" in report["days"][0]
    forecast_request = next(r for r in upstream.requests if r.url.path == "/v1/ensemble")
    assert forecast_request.url.params["latitude"] == "49.1952"
    assert forecast_request.url.params["longitude"] == "16.6080"
    assert forecast_request.url.params["timezone"] == "auto"
    assert len(upstream.requests) == 5
    assert cli.run(argv) == 0
    assert json.loads(capsys.readouterr().out)["cache"]["cached"]
    assert len(upstream.requests) == 5


def test_qualified_city_table_and_id_selection(upstream, capsys):
    upstream.geocoding = {"results": [BRNO_RESULT]}
    assert cli.run(["Brno, Czech Republic", "--no-ecmwf"]) == 0
    output = capsys.readouterr().out
    assert "Brno, South Moravian, Czechia (" in output
    assert "None" not in output
    upstream.geocoding = BRNO_RESULT
    assert cli.run(["--location-id", "3078610", "--json"]) == 0
    assert json.loads(capsys.readouterr().out)["location"]["id"] == "geonames:3078610"


def test_ambiguity_stops_before_forecasting(upstream, capsys):
    upstream.geocoding = {"results": [BRNO_RESULT, {**BRNO_RESULT, "id": 123}]}
    assert cli.run(["Brno", "--json"]) == 1
    output = capsys.readouterr()
    assert not output.out
    assert "Multiple locations" in output.err
    assert "--location-id 3078610" in output.err
    assert len(upstream.requests) == 1


@pytest.mark.parametrize("argv", [[], ["Brno", "--location-id", "1"], ["--location-id", "0"]])
def test_location_argument_validation(argv):
    with pytest.raises(SystemExit) as error:
        cli.run(argv)
    assert error.value.code == 2


@pytest.mark.parametrize("month,day", [(3, 28), (10, 24)])
def test_forecast_starts_on_prague_date_around_dst(upstream, capsys, monkeypatch, month, day):
    instant = dt.datetime(2026, month, day, 23, 30, tzinfo=dt.timezone.utc)

    class FixedDateTime(dt.datetime):
        @classmethod
        def now(cls, tz=None):
            return instant.astimezone(tz)

    monkeypatch.setattr(dt, "datetime", FixedDateTime)
    upstream.geocoding = {"results": [BRNO_RESULT]}
    forecast = payload()
    forecast.update(timezone="Europe/Prague", utc_offset_seconds=3600 if month == 3 else 7200)
    upstream.forecast = httpx.Response(200, json=forecast)
    assert cli.run(["Brno", "--json", "--days", "2"]) == 0
    report = json.loads(capsys.readouterr().out)
    assert report["days"][0]["date"] == f"2026-{month:02d}-{day + 1:02d}"
    assert len(report["days"]) == 2
    assert report["location"]["timezone"] == "Europe/Prague"


@pytest.mark.parametrize("units", ["imperial", "metric"])
def test_table_shows_rain_probability_and_per_day_ecmwf_checks(upstream, capsys, units):
    def by_model(request):
        secondary = fetch.ECMWF in str(request.url)
        result = payload(days=2 if secondary else 3)
        # One of three members is wet: the table should show 33%, not rain dots.
        result["hourly"]["precipitation"] = [1.0] * len(result["hourly"]["time"])
        if secondary:
            # Agree on day 1, disagree on day 2, and omit day 3 entirely.
            for key, values in result["hourly"].items():
                if key.startswith("temperature_2m"):
                    values[4:] = [value + 10 for value in values[4:]]
        return httpx.Response(200, json=result)

    upstream.forecast = by_model
    assert cli.run(["02108", "--days", "3", "--units", units]) == 0
    output = capsys.readouterr().out
    rows = [line for line in output.splitlines() if "33%" in line]
    assert len(rows) == 3
    assert "Agrees" in rows[0]
    assert "Differs" in rows[1]
    assert "Unavailable" in rows[2]
    assert "High" in rows[0]
    assert "●" not in output
    assert "20 percentage points" in output
    assert ("2.2°C" if units == "metric" else "4°F") in output
    assert ("≥1 mm" if units == "metric" else '≥0.04"') in output


def test_ecmwf_failure_shows_unavailable_instead_of_disagreement(upstream, capsys):
    def by_model(request):
        if fetch.ECMWF in str(request.url):
            return httpx.Response(404, json={"error": True, "reason": "model unavailable"})
        return httpx.Response(200, json=payload(days=2))

    upstream.forecast = by_model
    assert cli.run(["02108", "--days", "2"]) == 0
    output = capsys.readouterr().out
    rows = [line for line in output.splitlines() if "0%" in line]
    assert len(rows) == 2
    assert all("Unavailable" in row and "Differs" not in row for row in rows)
    assert "ECMWF cross-check unavailable" in output


def test_disabled_ecmwf_omits_the_column_and_network_request(upstream, capsys):
    assert cli.run(["02108", "--no-ecmwf", "--days", "2"]) == 0
    output = capsys.readouterr().out
    header = next(line for line in output.splitlines() if line.strip().startswith("Day "))
    assert "Rain" in header and "Confidence" in header
    assert "ECMWF" not in header
    assert "Unavailable" not in output
    assert "cross-check skipped" in output
    assert not any(fetch.ECMWF in str(request.url) for request in upstream.requests)


def test_all_wet_members_display_one_hundred_percent(upstream, capsys):
    result = payload(days=1)
    for key, values in result["hourly"].items():
        if key.startswith("precipitation"):
            result["hourly"][key] = [1.0] * len(values)
    upstream.forecast = httpx.Response(200, json=result)
    assert cli.run(["02108", "--days", "1"]) == 0
    output = capsys.readouterr().out
    assert "100%" in output
