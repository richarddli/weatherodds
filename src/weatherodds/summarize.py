"""Member-first aggregation of an ensemble response into per-day statistics.

Everything here is a pure function of the ``hourly`` dict returned by the
Open-Meteo ensemble API, so it is fully testable without network access.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, replace

import numpy as np

EPS = 1e-9


@dataclass(frozen=True)
class Units:
    """Display units plus the thresholds that are expressed in those units."""

    name: str
    temp_symbol: str  # "°F"
    wind_label: str  # "mph"
    precip_label: str  # "in"
    wet_threshold: float  # daily total that counts a member as "wet"
    spread_high: float  # <= this spread scores 2 points
    spread_medium: float  # <= this spread scores 1 point
    agree_temp: float  # ECMWF median-high tolerance
    gust_notable: float  # gusts worth printing next to sustained wind
    distance_label: str


IMPERIAL = Units(
    name="imperial",
    temp_symbol="°F",
    wind_label="mph",
    precip_label="in",
    wet_threshold=0.04,
    spread_high=5.0,
    spread_medium=10.0,
    agree_temp=4.0,
    gust_notable=30.0,
    distance_label="mi",
)

METRIC = Units(
    name="metric",
    temp_symbol="°C",
    wind_label="km/h",
    precip_label="mm",
    wet_threshold=1.0,
    spread_high=2.8,
    spread_medium=5.6,
    agree_temp=2.2,
    gust_notable=50.0,
    distance_label="km",
)

UNITS = {"imperial": IMPERIAL, "metric": METRIC}

RAIN_PROB_TOLERANCE = 0.20  # percentage-point agreement window for ECMWF

CLOUD_SUNNY_MAX = 30.0
CLOUD_PARTLY_MAX = 70.0


@dataclass(frozen=True)
class DaySummary:
    date: str
    high_median: float
    high_p10: float
    high_p90: float
    low_median: float
    low_p10: float
    low_p90: float
    spread: float
    rain_probability: float
    members_wet: int
    members_total: int
    amount_median: float | None
    amount_p90: float | None
    wind_median_max: float | None
    gusts_p90: float | None
    cloud_cover: float | None
    steps: int
    partial: bool
    rating: str
    points: int
    ecmwf_agrees: bool | None = None

    @property
    def sky(self) -> str:
        if self.cloud_cover is None:
            return "—"
        if self.cloud_cover < CLOUD_SUNNY_MAX:
            return "Sunny"
        if self.cloud_cover <= CLOUD_PARTLY_MAX:
            return "Partly"
        return "Cloudy"

    @property
    def rain_dots(self) -> int:
        """Filled dots on the 5-dot rain scale (0-5)."""
        p = self.rain_probability
        if p < 0.10:
            return 0
        if p < 0.30:
            return 1
        if p < 0.50:
            return 2
        if p < 0.70:
            return 3
        if p < 0.90:
            return 4
        return 5


def member_keys(hourly: dict, variable: str) -> list[str]:
    """Member series keys for a variable, control member first.

    The API names members ``temperature_2m_member01``…; the control member is
    the plain ``temperature_2m``. Member counts differ per model, so they are
    always discovered from the response rather than hardcoded.
    """
    pattern = re.compile(rf"^{re.escape(variable)}(?:_member(\d+))?$")
    found: list[tuple[int, str]] = []
    for key in hourly:
        match = pattern.match(key)
        if match:
            index = int(match.group(1)) if match.group(1) else -1
            found.append((index, key))
    return [key for _, key in sorted(found)]


def member_matrix(hourly: dict, variable: str) -> np.ndarray:
    """(n_members, n_steps) float array with None -> NaN."""
    keys = member_keys(hourly, variable)
    if not keys:
        raise KeyError(f"no member series for {variable!r} in response")
    rows = [
        np.array([np.nan if v is None else float(v) for v in hourly[key]], dtype=float)
        for key in keys
    ]
    return np.vstack(rows)


def _optional_matrix(hourly: dict, variable: str) -> np.ndarray | None:
    try:
        return member_matrix(hourly, variable)
    except KeyError:
        return None


def day_slices(times: list[str]) -> list[tuple[str, np.ndarray]]:
    """Group step indices by local calendar day, preserving order.

    Works for any step size (WeatherNext 2 is 6-hourly, ECMWF 3-hourly; the API
    may also serve them interpolated to 1-hourly).
    """
    buckets: dict[str, list[int]] = {}
    for i, stamp in enumerate(times):
        buckets.setdefault(stamp.split("T")[0], []).append(i)
    return [(day, np.array(idx, dtype=int)) for day, idx in buckets.items()]


def _nan_reduce(func, block: np.ndarray | None) -> np.ndarray | None:
    """Row-wise reduction that tolerates all-NaN rows without warnings."""
    if block is None:
        return None
    valid = ~np.isnan(block)
    out = np.full(block.shape[0], np.nan)
    rows = valid.any(axis=1)
    if rows.any():
        out[rows] = func(block[rows], axis=1)
    return out


def _finite(values: np.ndarray | None) -> np.ndarray | None:
    """Drop NaNs; None when nothing is left (e.g. a variable the model omits)."""
    if values is None:
        return None
    kept = values[np.isfinite(values)]
    return kept if kept.size else None


def _median(values: np.ndarray | None) -> float | None:
    kept = _finite(values)
    return None if kept is None else float(np.median(kept))


def _percentile(values: np.ndarray | None, q: float) -> float | None:
    kept = _finite(values)
    return None if kept is None else float(np.percentile(kept, q))


def score_confidence(
    spread: float, ecmwf_agrees: bool | None, units: Units
) -> tuple[str, int]:
    """Spread points (2/1/0) plus the ECMWF agreement adjustment (+1/-1)."""
    if spread <= units.spread_high:
        points = 2
    elif spread <= units.spread_medium:
        points = 1
    else:
        points = 0

    if ecmwf_agrees is True:
        points += 1
    elif ecmwf_agrees is False:
        points -= 1

    if points >= 2:
        rating = "high"
    elif points == 1:
        rating = "medium"
    else:
        rating = "low"
    return rating, points


def summarize(hourly: dict, units: Units, max_days: int | None = None) -> list[DaySummary]:
    """Per-day ensemble statistics, computed member-first."""
    temp = member_matrix(hourly, "temperature_2m")
    precip = member_matrix(hourly, "precipitation")
    # WeatherNext 2 serves no wind gusts; treat any absent variable as missing
    # rather than failing the whole run.
    wind = _optional_matrix(hourly, "wind_speed_10m")
    gusts = _optional_matrix(hourly, "wind_gusts_10m")
    cloud = _optional_matrix(hourly, "cloud_cover")

    members_total = temp.shape[0]
    raw_days = day_slices(hourly["time"])

    # Steps with any temperature data; a day with none at all is dropped, a day
    # with fewer than a full day's worth is flagged as partial.
    step_counts = [int(np.isfinite(temp[:, idx]).any(axis=0).sum()) for _, idx in raw_days]
    full_day = max(step_counts) if step_counts else 0

    summaries: list[DaySummary] = []
    for (day, idx), steps in zip(raw_days, step_counts):
        if steps == 0:
            continue

        member_high = _nan_reduce(np.nanmax, temp[:, idx])
        member_low = _nan_reduce(np.nanmin, temp[:, idx])
        member_precip = _nan_reduce(np.nansum, precip[:, idx])
        member_wind = _nan_reduce(np.nanmax, None if wind is None else wind[:, idx])
        member_gust = _nan_reduce(np.nanmax, None if gusts is None else gusts[:, idx])
        member_cloud = _nan_reduce(np.nanmean, None if cloud is None else cloud[:, idx])

        high_p10 = _percentile(member_high, 10)
        high_p90 = _percentile(member_high, 90)
        spread = high_p90 - high_p10

        wet_mask = np.nan_to_num(member_precip) >= units.wet_threshold - EPS
        members_wet = int(np.count_nonzero(wet_mask))
        probability = members_wet / members_total if members_total else 0.0
        if members_wet:
            wet_totals = member_precip[wet_mask]
            amount_median: float | None = float(np.median(wet_totals))
            amount_p90: float | None = _percentile(wet_totals, 90)
        else:
            amount_median = amount_p90 = None

        rating, points = score_confidence(spread, None, units)

        summaries.append(
            DaySummary(
                date=day,
                high_median=_median(member_high),
                high_p10=high_p10,
                high_p90=high_p90,
                low_median=_median(member_low),
                low_p10=_percentile(member_low, 10),
                low_p90=_percentile(member_low, 90),
                spread=spread,
                rain_probability=probability,
                members_wet=members_wet,
                members_total=members_total,
                amount_median=amount_median,
                amount_p90=amount_p90,
                wind_median_max=_median(member_wind),
                gusts_p90=_percentile(member_gust, 90),
                cloud_cover=_median(member_cloud),
                steps=steps,
                partial=steps < full_day,
                rating=rating,
                points=points,
            )
        )

    if max_days is not None:
        summaries = summaries[:max_days]
    return summaries


def cross_check(
    days: list[DaySummary], ecmwf_days: list[DaySummary], units: Units
) -> list[DaySummary]:
    """Fold ECMWF agreement into each day's confidence rating."""
    by_date = {d.date: d for d in ecmwf_days}
    out: list[DaySummary] = []
    for day in days:
        other = by_date.get(day.date)
        if other is None or day.high_median is None or other.high_median is None:
            out.append(day)
            continue
        agrees = (
            abs(day.high_median - other.high_median) <= units.agree_temp
            and abs(day.rain_probability - other.rain_probability) <= RAIN_PROB_TOLERANCE
        )
        rating, points = score_confidence(day.spread, agrees, units)
        out.append(replace(day, ecmwf_agrees=agrees, rating=rating, points=points))
    return out
