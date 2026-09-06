<img src="docs/weatherodds-icon.png" alt="WeatherOdds ribbon app icon" width="80" height="80">

# WeatherOdds

A macOS widget and command-line tool that show a 15-day weather forecast for
any US zip code, built on Google DeepMind's WeatherNext 2 model. See expected
temperatures, rain chances, and how much the forecast models agree.

![WeatherOdds macOS widget showing Boston's 15-day temperature ribbon,
P10–P90 ensemble range, rain-probability bars, and ECMWF disagreement
markers](docs/weatherodds-widget.png)

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

The ribbon layouts make that uncertainty visible:

- **Daily temperature range** — a continuous ribbon between the median daily
  low and high, with blue lows and orange highs.
- **Ensemble range** — a pale band from the 10th-percentile low to the
  90th-percentile high. A wider band means more uncertainty.
- **Rain chance** — aligned probability bars on a consistent 0–100% scale,
  with percentages shown for chances of at least 20%.
- **ECMWF comparison** — separate markers show when the independent European
  forecast differs. The temperature ribbon continues to show WeatherNext's
  actual spread.

The orange-and-blue ribbon app icon echoes this chart, with a pale envelope
around the expected temperature range.

The CLI presents the same forecast as a table, using rain dots (`●●●··`) and
confidence labels (`●●● high` / `●○○ low`). A line like
`Sat · 79° · ●●··· · ●○○ low` reads as: "probably around 79 with a chance of
rain — but it's far out and the models haven't settled, so don't book the
outdoor party on this yet."

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

The native macOS 26 widget lives in `macos/`. To install a copy for everyday use,
configure your development team for both targets in
`macos/WeatherOdds.xcodeproj` and make sure its Apple Development signing
identity is available in your keychain. Then run:

```sh
bash scripts/install-macos.sh
```

This builds with signing enabled, verifies the signatures and sandbox/network
entitlements, installs in `~/Applications/WeatherOdds.app`, registers the
widget, and opens the app to request a forecast reload. Add Weather Odds from
the macOS widget gallery and configure a zip code and units for each instance.
Run the same command to update the installation after changing the code.

You can also run the `WeatherOdds` scheme from Xcode while developing. The
installed copy is independent of Xcode's build output.

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
bash scripts/verify-macos.sh
```

The verification script and CI build without signing in
`tmp/macos-verification`, removing the build's Launch Services registration
on exit. Always use a separate `-derivedDataPath` for unsigned builds: using
Xcode's default output can overwrite a running signed widget and prevent macOS
from loading it.
The installer uses `tmp/macos-install` and verifies its signed output before
replacing the installed app.

Code lives in `src/weatherodds/`: zip lookup, API fetch, the math that turns
64 simulations into one row per day, and the table rendering. The Swift core,
widget extension, and host app live under `macos/`; shared fixtures in
`tests/fixtures/` keep the Python and Swift aggregation results aligned.

## License

Apache License 2.0 — see [LICENSE](LICENSE).
