"""Location resolution: offline US ZIPs and international Open-Meteo search."""

from __future__ import annotations

import math
import re
import unicodedata
from dataclasses import dataclass

from . import fetch
from .cache import forecast_key

ZIP_RE = re.compile(r"^[0-9]{5}$")
GEOCODING_URL = "https://geocoding-api.open-meteo.com/v1"

EARTH_RADIUS_KM = 6371.0088
MI_PER_KM = 0.621371


class GeocodeError(Exception):
    """Raised when input cannot be resolved to one location."""


@dataclass(frozen=True)
class Location:
    id: str
    name: str
    lat: float
    lon: float
    country_code: str
    postal_code: str | None = None
    timezone: str | None = None

    @property
    def zip(self) -> str | None:
        """Legacy JSON field, populated only for US postal-code lookups."""
        return self.postal_code if self.country_code == "US" else None


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
            "Use a city name or specify --country for international locations."
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

    return Location(
        id=f"postal:US:{zip_code}", name=name, lat=float(lat), lon=float(lon),
        country_code="US", postal_code=zip_code,
    )


def _parse_place(record: object) -> Location:
    """Validate upstream and cached records before trusting their coordinates."""
    try:
        if not isinstance(record, dict):
            raise ValueError
        identifier = record["id"]
        if type(identifier) is not int or identifier <= 0:
            raise ValueError
        name = record["name"]
        country = record["country_code"]
        if not isinstance(name, str) or not name.strip():
            raise ValueError
        if not isinstance(country, str) or not re.fullmatch(r"[A-Z]{2}", country):
            raise ValueError
        lat, lon = record["latitude"], record["longitude"]
        if any(type(v) not in (int, float) or not math.isfinite(v) for v in (lat, lon)):
            raise ValueError
        if not -90 <= lat <= 90 or not -180 <= lon <= 180:
            raise ValueError
        timezone = record.get("timezone")
        if timezone is not None and not isinstance(timezone, str):
            raise ValueError
        parts = [name]
        for part in (record.get("admin1"), record.get("country") or country):
            if part is not None and not isinstance(part, str):
                raise ValueError
            if part and part not in parts:
                parts.append(part)
        return Location(
            id=f"geonames:{identifier}", name=", ".join(parts),
            lat=float(lat), lon=float(lon), country_code=country, timezone=timezone,
        )
    except (KeyError, TypeError, ValueError) as exc:
        raise GeocodeError("Location service returned an invalid location.") from exc


def _records(payload: object, location_id: int | None) -> list[dict]:
    if not isinstance(payload, dict) or payload.get("error"):
        raise GeocodeError("Location service returned an invalid response.")
    records = [payload] if location_id is not None else payload.get("results", [])
    if not isinstance(records, list):
        raise GeocodeError("Location service returned invalid search results.")
    for record in records:
        _parse_place(record)
    return records


def _normalized_name(value: str) -> str:
    return "".join(
        c for c in unicodedata.normalize("NFKD", value.casefold())
        if not unicodedata.combining(c)
    ).strip()


def resolve(
    query: str | None, *, session: fetch.Session,
    country: str | None = None, location_id: int | None = None,
) -> Location:
    """Resolve one place; ambiguous searches list stable IDs for a second call.

    Bare five-digit inputs retain their historical US meaning. Search results
    are cached separately from forecasts, so repeated runs need no geocoding.
    """
    query = (query or "").strip()
    # GeoNames currently labels the country Czechia and does not recognize
    # its familiar English alias in a qualified search.
    city, separator, qualifier = query.partition(",")
    if separator and _normalized_name(qualifier) == "czech republic":
        query = f"{city.strip()}, Czechia"
    if country is not None:
        country = country.strip().upper()
        if not re.fullmatch(r"[A-Z]{2}", country):
            raise GeocodeError("--country must be a two-letter country code, e.g. CZ.")
    if location_id is None and not query:
        raise GeocodeError("Enter a city or postal code, or use --location-id.")
    if location_id is None and ZIP_RE.fullmatch(query) and country in (None, "US"):
        return lookup(query)

    url = f"{GEOCODING_URL}/{'get' if location_id is not None else 'search'}"
    params = {"language": "en", "format": "json"}
    if location_id is not None:
        params["id"] = str(location_id)
    else:
        params.update(name=query, count="100")
        if country:
            params["countryCode"] = country
    key = forecast_key(url, params)
    payload = session.cache.load_geocoding(key, now=session.clock()) if session.cache else None
    if payload is not None:
        try:
            _records(payload, location_id)
        except GeocodeError:
            payload = None
    if payload is None:
        response = session.get(url, params)
        if response.status_code != 200:
            raise GeocodeError(f"Location lookup failed (HTTP {response.status_code}).")
        try:
            payload = response.json()
        except ValueError as exc:
            raise GeocodeError("Location service returned invalid JSON.") from exc
        records = _records(payload, location_id)
        if records and session.cache:
            session.cache.store_geocoding(key, payload, now=session.clock())

    records = _records(payload, location_id)
    if country:
        records = [r for r in records if r["country_code"] == country]
    if location_id is not None:
        records = [r for r in records if r["id"] == location_id]
    else:
        # Search also returns prefixes (e.g. Brno suburbs). Prefer exact city
        # names, but never choose arbitrarily among multiple exact matches.
        name = _normalized_name(query.split(",", 1)[0])
        exact = [r for r in records if _normalized_name(r["name"]) == name]
        if exact:
            records = exact
        populated = [r for r in records if str(r.get("feature_code", "")).startswith("PPL")]
        if populated:
            records = populated
    places = list({r["id"]: _parse_place(r) for r in records}.values())
    if not places:
        raise GeocodeError(
            "No matching location found. Check the spelling or country code "
            "(e.g. Brno --country CZ)."
        )
    if len(places) > 1:
        choices = "\n".join(
            f"  {p.name} ({p.lat:.4f}, {p.lon:.4f}) — --location-id {p.id.split(':')[1]}"
            for p in places[:10]
        )
        raise GeocodeError(
            f"Multiple locations match {query!r}. Use --country to narrow the search "
            f"or rerun with --location-id:\n{choices}"
            + ("\n  More matches exist; narrow your search." if len(places) > 10 else "")
        )
    return places[0]


def distance_km(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    """Great-circle distance in kilometers."""
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dp = p2 - p1
    dl = math.radians(lon2 - lon1)
    a = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * EARTH_RADIUS_KM * math.asin(math.sqrt(a))


def distance_mi(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    return distance_km(lat1, lon1, lat2, lon2) * MI_PER_KM
