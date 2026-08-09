"""Tests for the pure aggregation layer, using a canned API response (no network)."""

from __future__ import annotations

import copy
import json
from pathlib import Path

import pytest

from weatherodds.summarize import (
    IMPERIAL,
    cross_check,
    day_slices,
    member_keys,
    score_confidence,
    summarize,
)

FIXTURE = Path(__file__).parent / "fixtures" / "weathernext_response.json"


@pytest.fixture
def hourly() -> dict:
    return json.loads(FIXTURE.read_text())["hourly"]


@pytest.fixture
def days(hourly):
    return summarize(hourly, IMPERIAL)


def test_member_keys_are_discovered_control_first(hourly):
    keys = member_keys(hourly, "temperature_2m")
    assert keys == [
        "temperature_2m",
        "temperature_2m_member01",
        "temperature_2m_member02",
        "temperature_2m_member03",
    ]
    # wind_speed_10m must not pick up wind_gusts_10m series
    assert all("gusts" not in k for k in member_keys(hourly, "wind_speed_10m"))


def test_steps_bucket_into_local_calendar_days(hourly):
    slices = day_slices(hourly["time"])
    assert [day for day, _ in slices] == ["2026-08-09", "2026-08-10", "2026-08-11"]
    assert [len(idx) for _, idx in slices] == [4, 4, 2]


def test_high_low_are_member_first_medians_and_percentiles(days):
    day = days[0]
    # member daily maxima are 80/84/88/92 -> median 86, p10 81.2, p90 90.8
    assert day.high_median == pytest.approx(86.0)
    assert day.high_p10 == pytest.approx(81.2)
    assert day.high_p90 == pytest.approx(90.8)
    assert day.spread == pytest.approx(9.6)
    # member daily minima are 64/65/66/67 -> median 65.5
    assert day.low_median == pytest.approx(65.5)


def test_rain_probability_and_wet_member_amounts(days):
    wet_day, dry_day = days[0], days[1]
    # member daily totals 0.00 / 0.10 / 0.30 / 0.50 in; three clear the 0.04" bar
    assert wet_day.members_wet == 3
    assert wet_day.members_total == 4
    assert wet_day.rain_probability == pytest.approx(0.75)
    assert wet_day.rain_dots == 4  # 70-89%
    # median among the *wet* members only, not all members
    assert wet_day.amount_median == pytest.approx(0.30)
    assert wet_day.amount_p90 == pytest.approx(0.46)

    assert dry_day.members_wet == 0
    assert dry_day.rain_probability == 0.0
    assert dry_day.rain_dots == 0
    assert dry_day.amount_median is None


def test_wind_cloud_and_sky_buckets(days):
    # member daily max winds 10/12/14/16 -> median 13
    assert days[0].wind_median_max == pytest.approx(13.0)
    assert days[0].cloud_cover == pytest.approx(81.0)
    assert days[0].sky == "Cloudy"
    assert days[1].sky == "Sunny"
    assert days[2].sky == "Partly"


def test_partial_last_day_is_flagged(days):
    assert [d.partial for d in days] == [False, False, True]
    assert days[2].steps == 2


def test_confidence_points_from_spread_alone():
    assert score_confidence(4.0, None, IMPERIAL) == ("high", 2)
    assert score_confidence(9.0, None, IMPERIAL) == ("medium", 1)
    assert score_confidence(18.0, None, IMPERIAL) == ("low", 0)


def test_confidence_ecmwf_adjustment():
    # agreement lifts a 1-point day to high, disagreement drops a 2-point day
    assert score_confidence(9.0, True, IMPERIAL) == ("high", 2)
    assert score_confidence(4.0, False, IMPERIAL) == ("medium", 1)
    assert score_confidence(18.0, False, IMPERIAL) == ("low", -1)


def test_cross_check_folds_ecmwf_agreement_into_rating(hourly):
    base = summarize(hourly, IMPERIAL)
    assert [d.rating for d in base[:2]] == ["medium", "high"]

    agreeing = cross_check(base, summarize(copy.deepcopy(hourly), IMPERIAL), IMPERIAL)
    assert agreeing[0].ecmwf_agrees is True
    assert agreeing[0].rating == "high"  # 1 spread point + 1 agreement point

    # shift the other model's temperatures by 10°F -> median highs 10°F apart
    shifted = copy.deepcopy(hourly)
    for key in member_keys(shifted, "temperature_2m"):
        shifted[key] = [v + 10 for v in shifted[key]]
    disagreeing = cross_check(base, summarize(shifted, IMPERIAL), IMPERIAL)
    assert disagreeing[0].ecmwf_agrees is False
    assert disagreeing[0].rating == "low"  # 1 - 1 = 0 points
    assert disagreeing[1].rating == "medium"  # 2 - 1 = 1 point


def test_cross_check_disagreement_on_rain_probability_alone(hourly):
    base = summarize(hourly, IMPERIAL)
    dry = copy.deepcopy(hourly)
    for key in member_keys(dry, "precipitation"):
        dry[key] = [0.0] * len(dry[key])
    checked = cross_check(base, summarize(dry, IMPERIAL), IMPERIAL)
    # temps identical, but 75% vs 0% rain is well outside the 20pp window
    assert checked[0].ecmwf_agrees is False
    assert checked[1].ecmwf_agrees is True
