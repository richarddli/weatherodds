"""International lookup, ambiguity, and durable cache behavior without networking."""

import json

import httpx
import pytest

from weatherodds import fetch, geocode
from weatherodds.cache import ForecastCache, GEOCODING_FRESHNESS

BRNO = {
    "id": 3078610, "name": "Brno", "latitude": 49.19522, "longitude": 16.60796,
    "country_code": "CZ", "country": "Czechia", "admin1": "South Moravian",
    "timezone": "Europe/Prague", "feature_code": "PPLA",
}


@pytest.fixture
def service(tmp_path):
    requests = []
    response = {"body": {"results": [BRNO]}, "status": 200}

    def handle(request):
        requests.append(request)
        return httpx.Response(response["status"], json=response["body"])

    with httpx.Client(transport=httpx.MockTransport(handle)) as client:
        session = fetch.Session(
            client=client, cache=ForecastCache(tmp_path), clock=lambda: 1_700_000_000,
            sleep=lambda _: None,
        )
        yield session, requests, response


def test_brno_country_and_persistent_cache(service):
    session, requests, _ = service
    place = geocode.resolve("Brno", country="cz", session=session)
    assert place.id == "geonames:3078610"
    assert place.country_code == "CZ"
    assert place.timezone == "Europe/Prague"
    assert place.zip is None
    assert place.name == "Brno, South Moravian, Czechia"
    assert requests[0].url.params["countryCode"] == "CZ"
    # Another session can resolve the same query from disk without a request.
    another = fetch.Session(client=session.client, cache=session.cache, clock=session.clock)
    assert geocode.resolve("Brno", country="CZ", session=another) == place
    assert len(requests) == 1


def test_country_alias_and_city_preference(service):
    session, requests, response = service
    response["body"]["results"] += [
        {**BRNO, "id": 3078611, "feature_code": "MT", "admin1": "Plzeň Region"},
        {**BRNO, "id": 6694367, "name": "Brno-střed"},
    ]
    assert geocode.resolve("Brno, Czech Republic", session=session).id == "geonames:3078610"
    assert requests[0].url.params["name"] == "Brno, Czechia"


def test_ambiguity_lists_reusable_ids_and_never_selects_first(service):
    session, _, response = service
    response["body"]["results"].append({**BRNO, "id": 123, "admin1": "Another region"})
    with pytest.raises(geocode.GeocodeError, match="Multiple locations") as error:
        geocode.resolve("Brno", session=session)
    assert "--location-id 3078610" in str(error.value)
    assert "--location-id 123" in str(error.value)
    response["body"] = BRNO
    assert geocode.resolve(None, location_id=3078610, session=session).lat == BRNO["latitude"]


def test_country_filter_is_enforced_even_if_upstream_ignores_it(service):
    session, requests, _ = service
    with pytest.raises(geocode.GeocodeError, match="No matching"):
        geocode.resolve("Brno", country="US", session=session)
    assert requests[0].url.params["countryCode"] == "US"


def test_zip_compatibility_and_foreign_postal_routing(service, monkeypatch):
    session, requests, _ = service
    monkeypatch.setattr(geocode, "lookup", lambda code: ("offline", code))
    assert geocode.resolve(" 02108 ", session=session) == ("offline", "02108")
    assert geocode.resolve("02108", country="us", session=session) == ("offline", "02108")
    assert not requests
    geocode.resolve("60200", country="CZ", session=session)
    assert requests[0].url.params["name"] == "60200"
    assert requests[0].url.params["countryCode"] == "CZ"


@pytest.mark.parametrize("body", [
    [], {"results": None}, {"results": [None]}, {"error": True},
    {"results": [{**BRNO, "latitude": 100}]},
    {"results": [{**BRNO, "longitude": "16.6"}]},
    {"results": [{**BRNO, "latitude": True}]},
    {"results": [{**BRNO, "id": "3078610"}]},
    {"results": [{**BRNO, "name": ""}]},
])
def test_invalid_responses_are_not_cached(service, body):
    session, _, response = service
    response["body"] = body
    with pytest.raises(geocode.GeocodeError):
        geocode.resolve("Brno", session=session)
    assert not list(session.cache.root.glob("geocoding-*.json"))


def test_empty_search_result(service):
    session, _, response = service
    response["body"] = {"generationtime_ms": 1}
    with pytest.raises(geocode.GeocodeError, match="No matching"):
        geocode.resolve("not-a-place", session=session)


@pytest.mark.parametrize("country", ["Czech Republic", "CZE", "1Z", ""])
def test_invalid_country_makes_no_request(service, country):
    session, requests, _ = service
    with pytest.raises(geocode.GeocodeError, match="two-letter"):
        geocode.resolve("Brno", country=country, session=session)
    assert not requests


@pytest.mark.parametrize("corruption", ["expired", "invalid", "truncated"])
def test_bad_or_expired_cache_is_refetched(service, corruption):
    session, requests, _ = service
    geocode.resolve("Brno", session=session)
    path = next(session.cache.root.glob("geocoding-*.json"))
    document = json.loads(path.read_text())
    if corruption == "expired":
        document["fetched_at"] -= GEOCODING_FRESHNESS
    elif corruption == "invalid":
        document["payload"]["results"][0]["latitude"] = 100
    path.write_text("{" if corruption == "truncated" else json.dumps(document))
    assert geocode.resolve("Brno", session=session).id == "geonames:3078610"
    assert len(requests) == 2


def test_rate_limit_is_shared_with_forecast_requests(service):
    session, requests, response = service
    response["status"] = 429
    with pytest.raises(fetch.CooldownError):
        geocode.resolve("Brno", session=session)
    with pytest.raises(fetch.CooldownError):
        session.ensemble(fetch.WEATHERNEXT, 49.19522, 16.60796, 15)
    with pytest.raises(fetch.CooldownError):
        geocode.resolve("Paris", session=session)
    assert len(requests) == 1


def test_offline_us_zip_retains_identity_and_postal_code(monkeypatch):
    import sys
    from types import SimpleNamespace

    def postal_record(code):
        assert code == "02108"
        return {
            "latitude": 42.3583, "longitude": -71.0603,
            "place_name": "Boston", "state_code": "MA",
        }

    def dataset(country):
        assert country == "us"
        return SimpleNamespace(query_postal_code=postal_record)

    monkeypatch.setitem(sys.modules, "pgeocode", SimpleNamespace(Nominatim=dataset))
    place = geocode.lookup("02108")
    assert place.id == "postal:US:02108"
    assert place.postal_code == place.zip == "02108"
    assert place.country_code == "US"
    assert place.name == "Boston, MA"


def test_id_result_must_match_requested_id(service):
    session, _, response = service
    response["body"] = BRNO
    with pytest.raises(geocode.GeocodeError, match="No matching"):
        geocode.resolve(None, location_id=123, session=session)


@pytest.mark.parametrize("status,body", [(400, '{}'), (200, '<html>unavailable</html>')])
def test_http_and_non_json_errors_are_readable(tmp_path, status, body):
    with httpx.Client(transport=httpx.MockTransport(
        lambda _: httpx.Response(status, text=body)
    )) as client:
        session = fetch.Session(client=client, cache=ForecastCache(tmp_path))
        with pytest.raises(geocode.GeocodeError, match="HTTP 400|invalid JSON"):
            geocode.resolve("Brno", session=session)
        assert not list(tmp_path.glob("geocoding-*.json"))
