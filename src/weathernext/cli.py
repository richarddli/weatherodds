"""Command-line entry point for weathernext."""

from __future__ import annotations

import argparse
import datetime as dt
import os
import sys
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

import httpx
from rich.console import Console

from . import fetch, geocode, render, summarize


def _days(value: str) -> int:
    try:
        days = int(value)
    except ValueError:
        raise argparse.ArgumentTypeError(f"{value!r} is not a whole number of days")
    if not 1 <= days <= 15:
        raise argparse.ArgumentTypeError("--days must be between 1 and 15")
    return days


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="weathernext",
        description=(
            "15-day ensemble forecast for a US zip code, summarizing Google "
            "DeepMind's WeatherNext 2 ensemble (via the free Open-Meteo API)."
        ),
    )
    parser.add_argument("zip", help="5-digit US zip code, e.g. 02492")
    parser.add_argument(
        "--days", type=_days, default=15, metavar="N", help="forecast days, 1-15 (default 15)"
    )
    parser.add_argument(
        "--no-ecmwf",
        action="store_true",
        help="skip the ECMWF cross-check (confidence from WeatherNext spread alone)",
    )
    parser.add_argument("--json", action="store_true", help="emit JSON instead of the table")
    parser.add_argument(
        "--units",
        choices=("imperial", "metric"),
        default="imperial",
        help="imperial (°F, mph, inches) or metric (°C, km/h, mm); default imperial",
    )
    return parser


def _local_now(timezone: str, utc_offset_seconds: int) -> dt.datetime:
    try:
        return dt.datetime.now(ZoneInfo(timezone))
    except (ZoneInfoNotFoundError, ValueError):
        return dt.datetime.now(dt.timezone(dt.timedelta(seconds=utc_offset_seconds)))


def _make_console() -> Console:
    """Colored on a TTY; plain when piped or when NO_COLOR is set."""
    plain = bool(os.environ.get("NO_COLOR")) or not sys.stdout.isatty()
    return Console(
        no_color=plain,
        highlight=False,
        soft_wrap=True,
        width=None if sys.stdout.isatty() else 100,
    )


def run(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    units = summarize.UNITS[args.units]
    stderr = Console(stderr=True, highlight=False)

    try:
        location = geocode.lookup(args.zip)
    except geocode.GeocodeError as exc:
        stderr.print(f"error: {exc}", style="red")
        return 1

    ecmwf_note: str | None = None
    try:
        with httpx.Client(headers={"User-Agent": "weathernext/0.1"}) as client:
            primary = fetch.fetch_ensemble(
                client, fetch.WEATHERNEXT, location.lat, location.lon, args.days, args.units
            )
            secondary = None
            if not args.no_ecmwf:
                try:
                    secondary = fetch.fetch_ensemble(
                        client, fetch.ECMWF, location.lat, location.lon, args.days, args.units
                    )
                except fetch.FetchError as exc:
                    ecmwf_note = (
                        f"Note: ECMWF cross-check unavailable ({exc}); "
                        "confidence uses WeatherNext spread alone."
                    )
    except fetch.FetchError as exc:
        stderr.print(
            f"error: could not reach the Open-Meteo ensemble API: {exc}", style="red"
        )
        return 1

    days = summarize.summarize(primary.hourly, units, max_days=args.days)
    if not days:
        stderr.print("error: the API returned no usable forecast days.", style="red")
        return 1

    ecmwf_members = None
    if secondary is not None:
        ecmwf_days = summarize.summarize(secondary.hourly, units, max_days=args.days)
        days = summarize.cross_check(days, ecmwf_days, units)
        ecmwf_members = ecmwf_days[0].members_total if ecmwf_days else None

    distance = (
        geocode.distance_mi if units is summarize.IMPERIAL else geocode.distance_km
    )(location.lat, location.lon, primary.latitude, primary.longitude)

    report = render.Report(
        location=location,
        units=units,
        days=days,
        grid_lat=primary.latitude,
        grid_lon=primary.longitude,
        grid_distance=distance,
        timezone=primary.timezone,
        fetched_at=_local_now(primary.timezone, primary.utc_offset_seconds),
        members=days[0].members_total,
        model_run=primary.run_time,
        ecmwf_used=secondary is not None,
        ecmwf_members=ecmwf_members,
        ecmwf_run=secondary.run_time if secondary else None,
        ecmwf_note=ecmwf_note,
        horizon=args.days,
    )

    if args.json:
        print(render.render_json(report))
    else:
        render.render_table(_make_console(), report)
    return 0


def main() -> None:
    try:
        sys.exit(run())
    except KeyboardInterrupt:
        sys.exit(130)


if __name__ == "__main__":
    main()
