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
from .summarize import IMPERIAL, DaySummary, Units

FILLED = "●"
EMPTY_RAIN = "·"
EMPTY_CONF = "○"

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
    "high": (FILLED * 3, "green3"),
    "medium": (FILLED * 2 + EMPTY_CONF, "yellow3"),
    "low": (FILLED + EMPTY_CONF * 2, "red3"),
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
    fetched_at: dt.datetime
    members: int
    model_run: dt.datetime | None
    ecmwf_used: bool
    ecmwf_members: int | None = None
    ecmwf_run: dt.datetime | None = None
    ecmwf_note: str | None = None
    horizon: int = 15


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
    # Below the 1-dot threshold the day reads as dry; an amount there is noise.
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
    filled = day.rain_dots
    text = Text()
    if filled == 0:
        return Text(EMPTY_RAIN * 5, style=RAIN_EMPTY)
    text.append(FILLED * filled, style=RAIN_COLORS[filled])
    if filled < 5:
        text.append(EMPTY_RAIN * (5 - filled), style=RAIN_EMPTY)
    return text


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
    today = report.fetched_at.date()

    console.print(
        Text.assemble(
            ("WeatherNext 2", "bold"),
            " · ",
            (f"{report.horizon}-day ensemble forecast", "bold"),
        )
    )
    console.print(
        f"{loc.name} {loc.zip} ({format_coords(report.grid_lat, report.grid_lon)} · "
        f"grid point {report.grid_distance:.0f} {units.distance_label} away)"
    )

    line = f"Model run: {format_run(report.model_run, with_date=True)} ({report.members} members)"
    if report.ecmwf_used:
        line += f" · ECMWF ENS {format_run(report.ecmwf_run)} ({report.ecmwf_members} members)"
    tzname = report.fetched_at.tzname() or ""
    line += f" · fetched {report.fetched_at:%H:%M} {tzname}".rstrip()
    console.print(line, style="dim")
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
    table.add_column("Rain", justify="left", no_wrap=True)
    table.add_column("Amount", justify="left", no_wrap=True)
    table.add_column("Wind", justify="right", no_wrap=True)
    table.add_column("Sky", justify="left", no_wrap=True)
    table.add_column("Confidence", justify="left", no_wrap=True)

    for day in report.days:
        dots, color = CONFIDENCE[day.rating]
        amount = format_amount(day, units)
        row = [
            day_text(day, today),
            Text(format_temp(day.high_median), style=temp_style(day.high_median, units)),
            Text(format_temp(day.low_median), style=temp_style(day.low_median, units, dim=True)),
            rain_text(day),
            Text(amount, style=AMOUNT_COLOR if amount != "—" else RAIN_EMPTY),
            Text(format_wind(day, units)),
            Text(day.sky, style=SKY_STYLES.get(day.sky, "dim")),
            Text(f"{dots} {day.rating}", style=color),
        ]
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
        f" Rain dots = share of members producing {threshold} that day "
        "(1 dot ≈ 10–30%, 5 dots ≈",
        style="dim",
    )
    console.print(
        ' certain); Amount = median among the wet members ("if it rains, roughly how much").',
        style="dim",
    )
    if report.ecmwf_used:
        console.print(
            " Confidence = ensemble spread + agreement with the independent ECMWF ensemble.",
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
            "zip": report.location.zip,
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
        "days": days,
    }
    return payload


def render_json(report: Report) -> str:
    return json.dumps(build_json(report), indent=2)
