"""Zip code -> latitude/longitude via the offline GeoNames dataset (pgeocode)."""

from __future__ import annotations

import math
import re
from dataclasses import dataclass

ZIP_RE = re.compile(r"^\d{5}$")

EARTH_RADIUS_KM = 6371.0088
MI_PER_KM = 0.621371


class GeocodeError(Exception):
    """Raised when a zip code cannot be resolved to a location."""


@dataclass(frozen=True)
class Location:
    zip: str
    name: str
    lat: float
    lon: float


def _clean(value: object) -> str | None:
    if value is None:
        return None
    text = str(value).strip()
    if not text or text.lower() == "nan":
        return None
    return text


def lookup(zip_code: str) -> Location:
    """Resolve a 5-digit US zip code. Raises GeocodeError on bad/unknown input."""
    zip_code = zip_code.strip()
    if not ZIP_RE.match(zip_code):
        raise GeocodeError(
            f"{zip_code!r} is not a 5-digit US zip code. "
            "weatherodds v1 supports US zip codes only (e.g. 02108)."
        )

    # Imported lazily: pgeocode pulls in pandas and may download the GeoNames
    # dataset on first use, which we don't want to pay for on --help.
    import pgeocode

    try:
        nomi = pgeocode.Nominatim("us")
        record = nomi.query_postal_code(zip_code)
    except Exception as exc:  # network failure on first-run dataset download
        raise GeocodeError(
            f"Could not load the US postal-code dataset: {exc}. "
            "pgeocode downloads it once on first run and needs network access."
        ) from exc

    lat = record.get("latitude")
    lon = record.get("longitude")
    if lat is None or lon is None or math.isnan(float(lat)) or math.isnan(float(lon)):
        raise GeocodeError(
            f"Zip code {zip_code} was not found in the US postal-code dataset. "
            "Check the digits, or try a neighboring zip."
        )

    place = _clean(record.get("place_name"))
    state = _clean(record.get("state_code"))
    if place and state:
        name = f"{place}, {state}"
    else:
        name = place or state or f"US {zip_code}"

    return Location(zip=zip_code, name=name, lat=float(lat), lon=float(lon))


def distance_km(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    """Great-circle distance in kilometers."""
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dp = p2 - p1
    dl = math.radians(lon2 - lon1)
    a = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * EARTH_RADIUS_KM * math.asin(math.sqrt(a))


def distance_mi(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    return distance_km(lat1, lon1, lat2, lon2) * MI_PER_KM
