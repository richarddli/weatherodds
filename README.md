# weatherodds

A command-line tool that shows a 15-day weather forecast for any US zip code,
built on Google DeepMind's WeatherNext 2 model.

```sh
uv run weatherodds 02108
```

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
or API key needed (free for personal use). Zip codes are looked up offline, so
your location isn't sent anywhere except as coordinates in the forecast
request. The model updates twice a day.

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

## Development

```sh
uv run pytest
```

Code lives in `src/weatherodds/`: zip lookup, API fetch, the math that turns
64 simulations into one row per day, and the table rendering.

## License

Apache License 2.0 — see [LICENSE](LICENSE).
