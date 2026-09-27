"""Rendering: the rich table (default) and the JSON payload (--json)."""

from __future__ import annotations

import datetime as dt
import json
from dataclasses import dataclass

from rich import box
from rich.console import Console
from rich.table import Table
from rich.text import Text

from .geocode import Location
from .summarize import IMPERIAL, RAIN_PROB_TOLERANCE, DaySummary, Units

# Warm scale for high temps, in °F; lows use the same colors, dimmed.
TEMP_COLORS = ((50.0, "#6f9fd8"), (70.0, "#7fb87f"), (85.0, "#e0a33e"))
TEMP_HOT = "#e05a3a"

RAIN_COLORS = {
    1: "#7fb2e0",
    2: "#5f9fdd",
    3: "#3d86d6",
    4: "#1f6fd0",
    5: "bold #1f6fd0",
}
RAIN_EMPTY = "grey42"
AMOUNT_COLOR = "#5f9fdd"

CONFIDENCE = {
    "high": "green3",
    "medium": "yellow3",
    "low": "red3",
}

SKY_STYLES = {"Sunny": "yellow", "Partly": "", "Cloudy": "dim"}

TODAY_ROW_STYLE = "on grey15"


@dataclass
class Report:
    """Everything the renderers need beyond the per-day summaries."""

    location: Location
    units: Units
    days: list[DaySummary]
    grid_lat: float
    grid_lon: float
    grid_distance: float
    timezone: str
    # When the displayed data was fetched; older than `now` for a cached run.
    fetched_at: dt.datetime
    members: int
    model_run: dt.datetime | None
    ecmwf_used: bool
    ecmwf_members: int | None = None
    ecmwf_run: dt.datetime | None = None
    ecmwf_note: str | None = None
    # Current local time, used to mark today's row. Defaults to `fetched_at`.
    now: dt.datetime | None = None
    cached: bool = False
    stale: bool = False
    cache_note: str | None = None
    horizon: int = 15
    # An unavailable comparison still has a column; an explicitly disabled one does not.
    ecmwf_enabled: bool = True


# --------------------------------------------------------------------------- #
# formatting helpers
# --------------------------------------------------------------------------- #


def temp_style(value: float, units: Units, dim: bool = False) -> str:
    fahrenheit = value if units is IMPERIAL else value * 9 / 5 + 32
    style = TEMP_HOT
    for cutoff, color in TEMP_COLORS:
        if fahrenheit <= cutoff:
            style = color
            break
    return f"dim {style}" if dim else style


def format_temp(value: float) -> str:
    return f"{round(value):.0f}°"


def format_amount(day: DaySummary, units: Units) -> str:
    value = day.amount_median
    # Suppress conditional amounts when the rain chance is below 10%.
    if value is None or day.rain_dots == 0:
        return "—"
    if units is IMPERIAL:
        if value < 0.005:
            return "—"
        return f'{value:.2f}"' if value < 0.1 else f'{value:.1f}"'
    if value < 0.05:
        return "—"
    return f"{value:.1f} mm"


def format_wind(day: DaySummary, units: Units) -> str:
    if day.wind_median_max is None:
        return "—"
    text = f"{day.wind_median_max:.0f} {units.wind_label}"
    gusts = day.gusts_p90
    if gusts is not None and gusts >= units.gust_notable and gusts >= 1.5 * day.wind_median_max:
        text += f" g{gusts:.0f}"
    return text


def rain_text(day: DaySummary) -> Text:
    return Text(
        f"{day.rain_probability:.0%}",
        style=RAIN_COLORS.get(day.rain_dots, RAIN_EMPTY),
    )


def ecmwf_text(day: DaySummary) -> Text:
    if day.ecmwf_agrees is True:
        return Text("Agrees", style="green3")
    if day.ecmwf_agrees is False:
        return Text("Differs", style="yellow3")
    return Text("Unavailable", style="dim")


def day_text(day: DaySummary, today: dt.date) -> Text:
    date = dt.date.fromisoformat(day.date)
    is_today = date == today
    label = "Today" if is_today else date.strftime("%a")
    if is_today:
        name_style = "bold"
    elif date.weekday() >= 5:
        name_style = "bold cyan"
    else:
        name_style = "bold"
    stamp = f"{date.strftime('%b')} {date.day:>2}"
    if day.partial:
        stamp += "*"
    text = Text()
    text.append(f"{label:<6}", style=name_style)
    text.append(" ")
    text.append(stamp, style="dim")
    return text


def format_coords(lat: float, lon: float) -> str:
    ns = "N" if lat >= 0 else "S"
    ew = "E" if lon >= 0 else "W"
    return f"{abs(lat):.2f}°{ns}, {abs(lon):.2f}°{ew}"


def format_run(run: dt.datetime | None, with_date: bool = False) -> str:
    if run is None:
        return "run time n/a"
    if with_date:
        return f"{run:%Y-%m-%d} {run:%H}z"
    return f"{run:%H}z"


# --------------------------------------------------------------------------- #
# table
# --------------------------------------------------------------------------- #


def render_table(console: Console, report: Report) -> None:
    units = report.units
    loc = report.location
    today = (report.now or report.fetched_at).date()

    console.print(
        Text.assemble(
            ("WeatherNext 2", "bold"),
            " · ",
            (f"{report.horizon}-day ensemble forecast", "bold"),
        )
    )
    label = f"{loc.name} {loc.postal_code}" if loc.postal_code else loc.name
    console.print(
        f"{label} ({format_coords(report.grid_lat, report.grid_lon)} · "
        f"grid point {report.grid_distance:.0f} {units.distance_label} away)",
        markup=False,
    )

    line = f"Model run: {format_run(report.model_run, with_date=True)} ({report.members} members)"
    if report.ecmwf_used:
        line += f" · ECMWF ENS {format_run(report.ecmwf_run)} ({report.ecmwf_members} members)"
    tzname = report.fetched_at.tzname() or ""
    line += f" · fetched {report.fetched_at:%H:%M} {tzname}".rstrip()
    if report.cached:
        line += " (cached)"
    console.print(line, style="dim")
    if report.cache_note:
        console.print(report.cache_note, style="yellow")
    if report.ecmwf_note:
        console.print(report.ecmwf_note, style="yellow")
    console.print()

    table = Table(
        box=box.SIMPLE,
        pad_edge=True,
        show_edge=False,
        header_style="bold",
        expand=False,
    )
    table.add_column("Day", justify="left", no_wrap=True)
    table.add_column("High", justify="right", no_wrap=True)
    table.add_column("Low", justify="right", no_wrap=True)
    table.add_column("Rain", justify="right", no_wrap=True)
    table.add_column("Amount", justify="left", no_wrap=True)
    table.add_column("Wind", justify="right", no_wrap=True)
    table.add_column("Sky", justify="left", no_wrap=True)
    if report.ecmwf_enabled:
        table.add_column("ECMWF", justify="left", no_wrap=True)
    table.add_column("Confidence", justify="left", no_wrap=True)

    for day in report.days:
        amount = format_amount(day, units)
        row = [
            day_text(day, today),
            Text(format_temp(day.high_median), style=temp_style(day.high_median, units)),
            Text(format_temp(day.low_median), style=temp_style(day.low_median, units, dim=True)),
            rain_text(day),
            Text(amount, style=AMOUNT_COLOR if amount != "—" else RAIN_EMPTY),
            Text(format_wind(day, units)),
            Text(day.sky, style=SKY_STYLES.get(day.sky, "dim")),
        ]
        if report.ecmwf_enabled:
            row.append(ecmwf_text(day))
        row.append(Text(day.rating.capitalize(), style=CONFIDENCE[day.rating]))
        is_today = dt.date.fromisoformat(day.date) == today
        table.add_row(*row, style=TODAY_ROW_STYLE if is_today else None)

    console.print(table)

    threshold = (
        f'≥{units.wet_threshold:g}"'
        if units is IMPERIAL
        else f"≥{units.wet_threshold:g} mm"
    )
    console.print(
        f" High/Low are the median of the {report.members} ensemble members.", style="dim"
    )
    console.print(
        f" Rain = share of members producing {threshold} that day (rounded to a whole percent).",
        style="dim",
    )
    console.print(
        ' Amount = median among the wet members ("if it rains, roughly how much").',
        style="dim",
    )
    if report.ecmwf_enabled:
        console.print(
            f" ECMWF Agrees = median highs within {units.agree_temp:g}{units.temp_symbol} "
            f"and rain chances within {RAIN_PROB_TOLERANCE * 100:g} percentage points.",
            style="dim",
        )
        console.print(
            " Differs = either threshold exceeded; Unavailable = no comparison for that day.",
            style="dim",
        )
        console.print(
            " Confidence = WeatherNext ensemble spread + ECMWF agreement where available.",
            style="dim",
        )
    else:
        console.print(
            " Confidence = ensemble spread alone (ECMWF cross-check skipped).", style="dim"
        )
    if any(day.partial for day in report.days):
        console.print(
            " * partial day — fewer model steps than a full day; high/low may be understated.",
            style="dim",
        )


# --------------------------------------------------------------------------- #
# JSON
# --------------------------------------------------------------------------- #


def _round(value: float | None, digits: int = 0) -> float | int | None:
    if value is None or value != value:  # None or NaN
        return None
    return int(round(value)) if digits == 0 else round(value, digits)


def build_json(report: Report) -> dict:
    units = report.units
    temp_key = "high_f" if units is IMPERIAL else "high_c"
    low_key = "low_f" if units is IMPERIAL else "low_c"
    amount_key = "amount_in" if units is IMPERIAL else "amount_mm"
    wind_key = "wind_mph" if units is IMPERIAL else "wind_kmh"
    spread_key = "spread_f" if units is IMPERIAL else "spread_c"

    days = []
    for day in report.days:
        days.append(
            {
                "date": day.date,
                temp_key: {
                    "median": _round(day.high_median),
                    "p10": _round(day.high_p10),
                    "p90": _round(day.high_p90),
                },
                low_key: {
                    "median": _round(day.low_median),
                    "p10": _round(day.low_p10),
                    "p90": _round(day.low_p90),
                },
                "rain": {
                    "probability": round(day.rain_probability, 2),
                    "members_wet": day.members_wet,
                    "members_total": day.members_total,
                    amount_key: {
                        "median": _round(day.amount_median, 2),
                        "p90": _round(day.amount_p90, 2),
                    },
                },
                wind_key: {
                    "median_max": _round(day.wind_median_max),
                    "gusts_p90": _round(day.gusts_p90),
                },
                "cloud_cover_pct": _round(day.cloud_cover),
                "confidence": {
                    "rating": day.rating,
                    spread_key: _round(day.spread),
                    "ecmwf_agrees": day.ecmwf_agrees,
                },
                "partial": day.partial,
            }
        )

    payload = {
        "location": {
            "id": report.location.id,
            "zip": report.location.zip,
            "postal_code": report.location.postal_code,
            "country_code": report.location.country_code,
            "name": report.location.name,
            "lat": round(report.location.lat, 4),
            "lon": round(report.location.lon, 4),
            "grid_lat": round(report.grid_lat, 4),
            "grid_lon": round(report.grid_lon, 4),
            f"grid_distance_{units.distance_label}": round(report.grid_distance, 1),
            "timezone": report.timezone,
        },
        "units": units.name,
        "model_run": (
            report.model_run.strftime("%Y-%m-%dT%H:%M:%SZ") if report.model_run else None
        ),
        "members": report.members,
        "ecmwf": {
            "used": report.ecmwf_used,
            "members": report.ecmwf_members,
            "model_run": (
                report.ecmwf_run.strftime("%Y-%m-%dT%H:%M:%SZ") if report.ecmwf_run else None
            ),
            "note": report.ecmwf_note,
        },
        "fetched_at": report.fetched_at.isoformat(),
        "cache": {
            "cached": report.cached,
            "stale": report.stale,
            "note": report.cache_note,
        },
        "days": days,
    }
    return payload


def render_json(report: Report) -> str:
    return json.dumps(build_json(report), indent=2)
