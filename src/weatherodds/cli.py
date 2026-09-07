"""Command-line entry point for weatherodds."""

from __future__ import annotations

import argparse
import datetime as dt
import os
import sys
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

import httpx
from rich.console import Console

from . import cache as cache_mod
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
        prog="weatherodds",
        description=(
            "15-day ensemble forecast for a US zip code, summarizing Google "
            "DeepMind's WeatherNext 2 ensemble (via the free Open-Meteo API)."
        ),
    )
    parser.add_argument("zip", help="5-digit US zip code, e.g. 02108")
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
        "--refresh",
        action="store_true",
        help="ignore cached forecasts and fetch again (a rate-limit cooldown still applies)",
    )
    parser.add_argument(
        "--units",
        choices=("imperial", "metric"),
        default="imperial",
        help="imperial (°F, mph, inches) or metric (°C, km/h, mm); default imperial",
    )
    return parser


def _local_tz(timezone: str, utc_offset_seconds: int) -> dt.tzinfo:
    try:
        return ZoneInfo(timezone)
    except (ZoneInfoNotFoundError, ValueError):
        return dt.timezone(dt.timedelta(seconds=utc_offset_seconds))


def _format_deadline(deadline: dt.datetime, tz: dt.tzinfo, now: dt.datetime) -> str:
    """`14:32 EDT (in 42m)` — when the CLI may talk to Open-Meteo again."""
    local = deadline.astimezone(tz)
    minutes = max(0, round((deadline - now).total_seconds() / 60))
    ahead = f"{minutes}m" if minutes < 60 else f"{minutes // 60}h{minutes % 60:02d}m"
    return f"{local:%H:%M} {local.tzname() or ''} (in {ahead})".replace("  ", " ")


def _stale_note(model: str, ensemble: fetch.Ensemble, tz: dt.tzinfo, now: dt.datetime) -> str:
    stamp = (ensemble.fetched_at or now).astimezone(tz)
    age = max(0, round((now - stamp).total_seconds() / 3600))
    reason = ensemble.stale_reason or "the refresh failed"
    return (
        f"Note: {model} could not be refreshed ({reason}); showing the cached "
        f"forecast from {stamp:%b %d %H:%M} (about {age}h old)."
    )


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

    session = fetch.Session(
        client=httpx.Client(headers={"User-Agent": "weatherodds/0.1"}),
        cache=cache_mod.ForecastCache(),
    )
    ecmwf_note: str | None = None
    with session.client:
        try:
            primary = session.ensemble(
                fetch.WEATHERNEXT,
                location.lat,
                location.lon,
                args.days,
                args.units,
                refresh=args.refresh,
            )
        except fetch.CooldownError as exc:
            # Nothing cached is usable, and Open-Meteo has told us to wait.
            now = dt.datetime.now().astimezone()
            stderr.print(
                f"error: {exc}. Next attempt at "
                f"{_format_deadline(exc.next_attempt, now.tzinfo, now)}.",
                style="red",
            )
            return 1
        except fetch.FetchError as exc:
            stderr.print(
                f"error: could not reach the Open-Meteo ensemble API: {exc}", style="red"
            )
            return 1

        secondary = None
        if not args.no_ecmwf:
            try:
                secondary = session.ensemble(
                    fetch.ECMWF,
                    location.lat,
                    location.lon,
                    args.days,
                    args.units,
                    refresh=args.refresh,
                )
            except fetch.FetchError as exc:
                ecmwf_note = (
                    f"Note: ECMWF cross-check unavailable ({exc}); "
                    "confidence uses WeatherNext spread alone."
                )

    tz = _local_tz(primary.timezone, primary.utc_offset_seconds)
    now_local = dt.datetime.now(tz)
    cache_note = _stale_note("WeatherNext 2", primary, tz, now_local) if primary.stale else None
    if secondary is not None and secondary.stale:
        ecmwf_note = _stale_note("the ECMWF cross-check", secondary, tz, now_local)

    # Days already past at the location are dropped before the horizon is
    # applied, so a forecast reused across local midnight still shows N days
    # starting today.
    today = now_local.date().isoformat()
    days = [
        day for day in summarize.summarize(primary.hourly, units) if day.date >= today
    ][: args.days]
    if not days:
        stderr.print("error: the API returned no usable forecast days.", style="red")
        return 1

    ecmwf_members = None
    if secondary is not None:
        ecmwf_days = summarize.summarize(secondary.hourly, units)
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
        fetched_at=(primary.fetched_at or now_local).astimezone(tz),
        now=now_local,
        members=days[0].members_total,
        model_run=primary.run_time,
        ecmwf_used=secondary is not None,
        ecmwf_members=ecmwf_members,
        ecmwf_run=secondary.run_time if secondary else None,
        ecmwf_note=ecmwf_note,
        cached=primary.cached,
        stale=primary.stale,
        cache_note=cache_note,
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
