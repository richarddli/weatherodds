"""Open-Meteo ensemble API client."""

from __future__ import annotations

import datetime as dt
from dataclasses import dataclass

import httpx

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


def _get(client: httpx.Client, url: str, params: dict | None = None) -> httpx.Response:
    """GET with a single retry on timeout or 5xx."""
    last_error: Exception | None = None
    for attempt in range(2):
        try:
            response = client.get(url, params=params, timeout=TIMEOUT)
        except httpx.TimeoutException as exc:
            last_error = exc
            continue
        except httpx.HTTPError as exc:
            last_error = exc
            break
        if response.status_code >= 500:
            last_error = httpx.HTTPStatusError(
                f"HTTP {response.status_code}", request=response.request, response=response
            )
            continue
        return response
    raise FetchError(str(last_error) if last_error else "request failed")


def fetch_run_time(client: httpx.Client, model: str) -> dt.datetime | None:
    """Best-effort model initialisation time; None when unavailable."""
    try:
        response = _get(client, META_URL.format(model=model))
        if response.status_code != 200:
            return None
        stamp = response.json().get("last_run_initialisation_time")
    except (FetchError, ValueError, AttributeError):
        return None
    if not isinstance(stamp, (int, float)):
        return None
    return dt.datetime.fromtimestamp(stamp, dt.timezone.utc)


def fetch_ensemble(
    client: httpx.Client,
    model: str,
    lat: float,
    lon: float,
    days: int,
    units: str = "imperial",
) -> Ensemble:
    """Fetch one ensemble model for a point. Raises FetchError on failure."""
    params = {
        "latitude": f"{lat:.4f}",
        "longitude": f"{lon:.4f}",
        "models": model,
        "hourly": ",".join(HOURLY_VARS),
        "forecast_days": str(days),
        "timezone": "auto",
        **_unit_params(units),
    }

    response = _get(client, BASE_URL, params)
    try:
        payload = response.json()
    except ValueError as exc:
        raise FetchError(f"{model}: response was not JSON ({exc})") from exc

    if response.status_code != 200 or payload.get("error"):
        reason = payload.get("reason") or f"HTTP {response.status_code}"
        raise FetchError(f"{model}: {reason}")

    hourly = payload.get("hourly")
    if not hourly or not hourly.get("time"):
        raise FetchError(f"{model}: response contained no hourly data")

    return Ensemble(
        model=model,
        latitude=float(payload["latitude"]),
        longitude=float(payload["longitude"]),
        timezone=payload.get("timezone", "UTC"),
        utc_offset_seconds=int(payload.get("utc_offset_seconds", 0)),
        hourly=hourly,
        run_time=fetch_run_time(client, model),
    )
