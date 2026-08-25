"""Generate the cross-language aggregation conformance reference.

The reference deliberately retains Python's raw floating-point results. The
Swift runner compares numeric fields with a tolerance while requiring all
other values and field presence to match exactly.

Use ``--write`` to update the committed reference intentionally and ``--check``
to fail when it is stale.
"""

from __future__ import annotations

import argparse
import dataclasses
import json
import sys
from pathlib import Path
from typing import Any

from weatherodds.summarize import IMPERIAL, METRIC, cross_check, summarize

SCHEMA_VERSION = 1
ROOT = Path(__file__).resolve().parent.parent
OUTPUT = Path(__file__).resolve().parent / "reference.json"


# Fields on DaySummary that are pure functions of the ensemble input. Derived
# display properties (sky, rain_dots) are included so both view layers agree on
# the thresholds, not just the raw numbers.
def _day(day) -> dict:
    out = dataclasses.asdict(day)
    out["sky"] = day.sky
    out["rain_dots"] = day.rain_dots
    return out


def _perturb(hourly: dict, delta: float) -> dict:
    """Shift every temperature series, to force an ECMWF disagreement."""
    out = dict(hourly)
    for key, series in hourly.items():
        if key.startswith("temperature_2m"):
            out[key] = [None if v is None else v + delta for v in series]
    return out


def _remove_date(hourly: dict, date: str) -> dict:
    """Remove a local calendar date from every hourly series."""
    keep = [not stamp.startswith(f"{date}T") for stamp in hourly["time"]]
    out: dict[str, Any] = {}
    for key, value in hourly.items():
        if isinstance(value, list) and len(value) == len(keep):
            out[key] = [item for item, retained in zip(value, keep) if retained]
        else:
            out[key] = value
    return out


def _load_hourly(root: Path, fixture: str) -> dict:
    path = root / "tests" / "fixtures" / fixture
    return json.loads(path.read_text())["hourly"]


def _case(
    *,
    name: str,
    fixture: str,
    units,
    root: Path,
    max_days: int | None = None,
    cross_check_spec: dict[str, Any] | None = None,
) -> dict[str, Any]:
    hourly = _load_hourly(root, fixture)
    primary = summarize(hourly, units, max_days=max_days)

    if cross_check_spec is not None:
        mode = cross_check_spec["mode"]
        if mode == "same":
            ecmwf_hourly = hourly
        elif mode == "temperature_delta":
            ecmwf_hourly = _perturb(hourly, cross_check_spec["delta"])
        elif mode == "remove_date":
            ecmwf_hourly = _remove_date(hourly, cross_check_spec["date"])
        else:  # pragma: no cover - case definitions below are exhaustive
            raise ValueError(f"unsupported cross-check mode: {mode}")
        ecmwf = summarize(ecmwf_hourly, units, max_days=max_days)
        primary = cross_check(primary, ecmwf, units)

    return {
        "name": name,
        "fixture": fixture,
        "units": units.name,
        "max_days": max_days,
        "cross_check": cross_check_spec,
        "expected": [_day(day) for day in primary],
    }


def build(root: Path = ROOT) -> dict[str, Any]:
    """Build every named case without rounding any numeric values."""
    cases = [
        _case(
            name="baseline_imperial",
            fixture="weathernext_response.json",
            units=IMPERIAL,
            root=root,
        ),
        _case(
            name="baseline_metric",
            fixture="weathernext_response.json",
            units=METRIC,
            root=root,
        ),
        _case(
            name="edge_cases_imperial",
            fixture="weathernext_edge_cases.json",
            units=IMPERIAL,
            root=root,
        ),
        _case(
            name="edge_cases_metric",
            fixture="weathernext_edge_cases.json",
            units=METRIC,
            root=root,
        ),
        _case(
            name="edge_cases_max_days_2",
            fixture="weathernext_edge_cases.json",
            units=IMPERIAL,
            max_days=2,
            root=root,
        ),
        _case(
            name="cross_check_agrees",
            fixture="weathernext_response.json",
            units=IMPERIAL,
            cross_check_spec={"mode": "same"},
            root=root,
        ),
        _case(
            name="cross_check_disagrees",
            fixture="weathernext_response.json",
            units=IMPERIAL,
            cross_check_spec={"mode": "temperature_delta", "delta": 20.0},
            root=root,
        ),
        _case(
            name="cross_check_date_absent",
            fixture="weathernext_response.json",
            units=IMPERIAL,
            cross_check_spec={"mode": "remove_date", "date": "2026-08-09"},
            root=root,
        ),
    ]
    return {"schema_version": SCHEMA_VERSION, "cases": cases}


def _render(reference: dict[str, Any]) -> str:
    return json.dumps(reference, indent=2, sort_keys=True, allow_nan=False) + "\n"


def write_reference(output: Path = OUTPUT, root: Path = ROOT) -> None:
    output.write_text(_render(build(root)))


def reference_is_current(output: Path = OUTPUT, root: Path = ROOT) -> bool:
    if not output.exists():
        return False
    try:
        committed = output.read_text()
    except OSError:
        return False
    return committed == _render(build(root))


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    action = parser.add_mutually_exclusive_group(required=True)
    action.add_argument("--write", action="store_true", help="update reference.json")
    action.add_argument(
        "--check", action="store_true", help="fail if reference.json is stale"
    )
    args = parser.parse_args(argv)

    if args.write:
        write_reference()
        print(f"wrote {OUTPUT.relative_to(ROOT)}")
        return 0

    if reference_is_current():
        print(f"current: {OUTPUT.relative_to(ROOT)}")
        return 0

    print(
        f"stale: {OUTPUT.relative_to(ROOT)}; regenerate with --write",
        file=sys.stderr,
    )
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
