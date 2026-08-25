# weatherodds

A command-line tool that shows a 15-day weather forecast for any US zip code,
built on Google DeepMind's WeatherNext 2 model.

```sh
uv run weatherodds 02108
```

![15-day weatherodds forecast for Boston, MA, showing daily high/low, rain
probability dots, expected amount, wind, sky, and a confidence rating for
each day](docs/weatherodds-boston.svg)

## The problem

Most weather apps stop at 10 days, and — more importantly — they always show a
single confident-looking number. "High of 84°" looks the same on the day-2
forecast (very reliable) and the day-10 forecast (largely a guess). The app
never tells you which one you're looking at.

## How this tool is different

WeatherNext 2 doesn't produce one forecast — it produces **64 slightly
different simulations** of the next 15 days, each starting from a slightly
different estimate of the atmosphere right now. Where the simulations agree,
the forecast is trustworthy. Where they scatter, the honest answer is "we
don't know yet."

This tool shows you that agreement instead of hiding it:

- **High / Low** — the middle value across all 64 simulations.
- **Rain dots** (`●●●··`) — how many of the simulations produce rain that
  day. Three dots means roughly half of them do.
- **Confidence** (`●●● high` / `●○○ low`) — how tightly the simulations
  agree, cross-checked against a second, independent forecast model run by
  the European weather agency (ECMWF). When two unrelated models tell the
  same story, you can plan on it; when they disagree, check back in a day
  or two.

So a line like `Sat · 79° · ●●··· · ●○○ low` reads as: "probably around 79
with a chance of rain — but it's far out and the models haven't settled, so
don't book the outdoor party on this yet."

## Where the data comes from

Forecast data comes from [Open-Meteo](https://open-meteo.com), a free weather
API that serves Google's WeatherNext 2 model and ECMWF's forecasts. No account
or API key is needed for personal, noncommercial use. The Python CLI looks up
zip codes offline. The macOS widget resolves zip codes with Apple MapKit, then
sends coordinates—not the zip code—to Open-Meteo. The model updates twice a
day.

## Usage

Requires [uv](https://docs.astral.sh/uv/). From this directory:

```sh
uv run weatherodds 02108              # 15-day forecast
uv run weatherodds 02108 --days 7     # shorter horizon
uv run weatherodds 02108 --units metric
uv run weatherodds 02108 --json       # machine-readable output
uv run weatherodds 02108 --no-ecmwf   # skip the second-model cross-check
```

US 5-digit zip codes only.

## macOS widget

The native macOS 26 widget lives in `macos/`. Open
`macos/WeatherOdds.xcodeproj`, select the `WeatherOdds` scheme, and run the host
app once. Then add Weather Odds from the macOS widget gallery and configure a
zip code and units for each widget instance.

Small, medium, large, and extra-large families show progressively more of the
15-day forecast. Forecasts refresh through WidgetKit and fall back to the last
good result for up to 48 hours when the primary model is temporarily
unavailable.

## Development

```sh
uv run python -m pytest
uv run python conformance/dump_reference.py --check
swift test --package-path macos/WeatherOddsCore
swift run --package-path macos/WeatherOddsCore \
  weatherodds-conformance --repo-root .
```

Code lives in `src/weatherodds/`: zip lookup, API fetch, the math that turns
64 simulations into one row per day, and the table rendering. The Swift core,
widget extension, and host app live under `macos/`; shared fixtures in
`tests/fixtures/` keep the Python and Swift aggregation results aligned.

## License

Apache License 2.0 — see [LICENSE](LICENSE).
