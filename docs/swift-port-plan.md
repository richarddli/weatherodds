# Plan: native macOS desktop widget via a Swift port

Revision 4. Status: **local prototype implemented; automated verification
green.** The Python/Swift conformance contract, Swift forecast pipeline,
durable cache, MapKit geocoding, four WidgetKit families, host app, Xcode
project, and CI workflow are present. Signing/installing the app and the manual
desktop-widget lifecycle, VoiceOver, and rendering-mode scenarios below remain
release validation work.

## Summary

- Build a native WidgetKit widget for macOS 26 that displays the WeatherNext 2
  ensemble forecast and its confidence signal for a configured US zip code.
- Keep the Python CLI independent. Pin the Python and Swift aggregation layers
  to the same behavior with shared fixtures and a field-by-field conformance
  runner.

## Goals

- Support independently configured `systemSmall`, `systemMedium`,
  `systemLarge`, and `systemExtraLarge` widget instances.
- Configure each instance with a five-digit US zip code and imperial or metric
  units, defaulting units from `Locale.current.measurementSystem`.
- Fetch and summarize WeatherNext 2 directly in the widget extension, and use
  ECMWF as an optional confidence cross-check.
- Preserve the Python implementation's percentile, NaN, missing-variable,
  partial-day, and confidence behavior exactly within a numeric tolerance.
- Survive extension termination and network failures with an extension-local,
  durable last-good cache and explicit stale, degraded, and unavailable states.
- Keep confidence understandable in full-color, accented, vibrant, and
  monochrome appearances, including through VoiceOver.
- Ship a minimal host app with widget instructions and Open-Meteo attribution.

## Non-Goals

- Replacing or embedding the Python CLI.
- Running Python, `uv`, a launch agent, or a bundled Python runtime from the
  widget extension.
- Supporting macOS 15 or earlier.
- Displaying the forecast in the host app or sharing a default zip between the
  app and widget.
- GPS/current-location configuration, non-US postal codes, current conditions,
  push updates, or interactive controls.
- Showing all 15 days in every widget family. Only `systemExtraLarge` shows the
  complete horizon.
- App Store, Developer ID, notarized, commercial, or public distribution. Those
  require a separate release and data-licensing plan.
- Exact geocoding parity with the CLI's GeoNames centroid.

## Assumptions / Inputs Needed

- No blocking input is required for this revision.
- The first release is a locally signed, noncommercial personal app. A free
  Apple ID is sufficient for local installation.
- macOS 26 is the deployment target. The build uses the current Xcode 26 SDK
  and a matching Swift toolchain.
- Open-Meteo remains reachable from the Mac and continues to expose the
  WeatherNext 2 and ECMWF ensemble endpoints used by the Python CLI.
- The existing Python behavior in `src/weatherodds/summarize.py` is canonical
  unless a fixture exposes an existing Python bug.

## High-Level Approach

- Port the pure aggregation layer and API client to a SwiftPM core package;
  build the SwiftUI host and WidgetKit extension on top of that package.
- Resolve zip codes with macOS 26's `MKGeocodingRequest`. Do not use the
  deprecated `CLGeocoder` API or vendor a postal-code dataset.
- Fetch WeatherNext and ECMWF concurrently, but summarize and discard each raw
  response inside its task so the widget retains only compact day summaries.
- Persist locations and last-good forecasts in the widget extension's own
  Application Support container. Do not add an App Group.
- Generate timeline entries only when the displayed day can change, and request
  a fresh forecast every six hours. Use shorter retry policies after failures.
- Drive the port with Swift tests plus a whole-payload conformance executable;
  finish with real desktop-widget lifecycle and rendering tests.

## Control Flow

### Existing Python CLI

1. `cli.py` parses zip, horizon, ECMWF, and unit options.
2. `geocode.py` resolves the zip through the local `pgeocode`/GeoNames dataset.
3. `fetch.py` fetches WeatherNext, then optionally ECMWF and model metadata.
4. `summarize.py` computes member-first daily summaries and folds in the ECMWF
   agreement result.
5. `render.py` emits the terminal table or JSON report.

### New widget flow

1. WidgetKit passes a widget instance's `WeatherConfigurationIntent` to the
   timeline provider.
2. The provider trims and validates the zip and resolves the selected units. A
   missing zip produces `unconfigured`; a malformed zip produces
   `invalidConfiguration`. Neither state starts network work.
3. The provider reads the cached location for the normalized `zip` key and the
   cached forecast for the normalized `zip + units` key.
4. On a location-cache miss, an `@MainActor` wrapper calls
   `MKGeocodingRequest` with the exact zip plus `United States`, validates the
   returned US address, and immediately converts the selected `MKMapItem` to a
   Sendable `Location` value.
5. The provider starts WeatherNext and ECMWF fetch-and-summarize tasks
   concurrently. Each task decodes, summarizes, and releases its raw payload
   before returning.
6. WeatherNext success is sufficient. If ECMWF succeeds, `crossCheck` adjusts
   confidence; if it fails, the result uses spread-only confidence and sets
   `ecmwfContributed` to false.
7. A successful primary result is written atomically to the last-good cache and
   returned as `fresh`. The ECMWF flag is orthogonal, so a forecast can be fresh
   or stale while also showing the `WeatherNext only` degraded indicator. The
   timeline contains an entry for now and an additional entry only if the
   forecast location reaches midnight before the next six-hour refresh.
8. On WeatherNext failure, a usable cache younger than 48 hours is returned as
   `stale`. Without a usable cache, the provider returns `unavailable`.
9. `placeholder` and gallery preview always use canned data. `snapshot` never
   starts network work; it uses cache when available and canned data otherwise.

## Implementation Details

### Repository layout

```text
macos/
  WeatherOddsCore/
    Package.swift
    Sources/WeatherOddsCore/
      Units.swift
      Statistics.swift
      Ensemble.swift
      DaySummary.swift
      Summarize.swift
      Fetch.swift
      Geocode.swift
      Cache.swift
    Sources/weatherodds-conformance/
      main.swift
    Tests/WeatherOddsCoreTests/
  WeatherOdds.xcodeproj
  WeatherOddsApp/
  WeatherOddsWidget/
    WeatherConfigurationIntent.swift
    WeatherOddsWidget.swift
    TimelineProvider.swift
    Views/
conformance/
  dump_reference.py
  reference.json
tests/fixtures/
  weathernext_response.json
  weathernext_edge_cases.json
```

Commit the small `.xcodeproj`. Do not add XcodeGen or Tuist for this two-target
app. The app and widget consume `WeatherOddsCore` as a local Swift package.

### Core aggregation port

- Change `Package.swift` to target macOS 26 and add a Swift Testing target.
- `Statistics.swift` implements finite filtering, row-wise min/max/sum/mean,
  median, and NumPy's default linear percentile:
  `(n - 1) * q / 100`, followed by interpolation between adjacent values.
- `Ensemble.swift` discovers the control member and numbered members from
  dynamic response keys. It preserves the Python ordering: control first, then
  numeric member order.
- Keep Open-Meteo's location-local, offset-free timestamps as `String`. Bucket
  them by the `YYYY-MM-DD` prefix; never decode hourly stamps to `Date`.
- Preserve all-NaN rows as missing. Treat NaN precipitation as dry, compare wet
  totals with `wetThreshold - 1e-9`, count steps from timestamps where any
  temperature member is finite, and drop zero-step days.
- Model optional variables as `nil`, not zero. WeatherNext's missing gust data
  must produce nil gust output without failing the forecast.
- `DaySummary` is `Codable`, `Sendable`, and `Equatable`. Values guaranteed by
  the nonzero-step invariant remain nonoptional; optional model variables remain
  optional.
- `crossCheck` leaves a day unchanged when ECMWF lacks the matching date. It
  does not add an impossible nil-high case to the serialized contract.

### Conformance contract

- Phase 1 replaces the current transitional conformance scaffold. The committed
  `conformance/dump_reference.py` and `conformance/reference.json` currently
  cover one fixture with rounded output; they are not the final contract.
- Add `weathernext_edge_cases.json` before porting the math. It contains nulls,
  an all-null member/day, a zero-step day, missing optional variables, a member
  exactly at each unit's wet threshold, and data beyond a `maxDays` boundary.
- `conformance/dump_reference.py` writes raw Python numeric values. Remove the
  current six-decimal rounding and byte-identical comparison language.
- The reference contains a schema version plus named cases for both fixtures,
  imperial and metric units, `maxDays`, ECMWF agree/disagree, and an ECMWF date
  absent from the primary series.
- `weatherodds-conformance` accepts `--repo-root`, loads the shared fixtures and
  reference from that root, and compares every field. Numeric values use
  `abs(actual - expected) <= 1e-6`; strings, integers, booleans, nulls, list
  lengths, and field presence compare exactly. Diagnostics name the case, day,
  and field.
- `dump_reference.py --write` intentionally updates the committed reference.
  `dump_reference.py --check` regenerates in memory and exits nonzero if the
  committed file is stale.
- CI runs:

  ```sh
  uv run pytest
  uv run python conformance/dump_reference.py --check
  swift test --package-path macos/WeatherOddsCore
  swift run --package-path macos/WeatherOddsCore weatherodds-conformance --repo-root .
  ```

- Keep the executable even though Swift Testing ships with current Command Line
  Tools: the executable validates the complete cross-language payload, while
  the test target gives focused failures during development.

### Geocoding and API fetching

- `Geocode.swift` creates `MKGeocodingRequest(addressString: "<zip>, United States")`,
  sets `preferredLocale` to `Locale(identifier: "en_US")`, and awaits
  `request.mapItems`.
- Prefer a result whose `addressRepresentations.region?.identifier` is `US` and
  whose normalized `fullAddress(includingRegion:singleLine:)` contains the
  requested zip. If no result satisfies both checks, report
  `invalidConfiguration` rather than silently selecting a similarly named
  place.
- Build the display name from `addressRepresentations.cityWithContext`, falling
  back to `MKMapItem.name` and then `US <zip>`. Copy coordinates and timezone
  into the Sendable `Location`; do not pass MapKit reference types out of the
  main-actor wrapper.
- A successful location lookup is cached indefinitely by zip. An empty or
  nonmatching result is an invalid zip; cancellation, decoding, service, and
  network errors are temporary failures.
- `Fetch.swift` mirrors the existing ensemble endpoint, model identifiers,
  variables, unit parameters, `timezone=auto`, and response validation in
  `src/weatherodds/fetch.py`.
- Always request the full 15-day horizon. Widget families select a prefix at
  presentation time, so one cached payload serves every family for the same zip
  and units.
- Do not call either `meta.json` endpoint from the widget. Model-run metadata is
  not shown, and removing those calls cuts each refresh from four requests to
  two after the location is cached.
- Use a standard `URLSession` with a six-second request timeout and eight-second
  resource timeout. Do not retry inline; WidgetKit schedules the next attempt.
- Assert that `hourly_units` matches the selected units when the field is
  present. Treat absent optional hourly variables as missing, but reject absent
  time, temperature, or precipitation data.

### Durable cache and states

- `Cache.swift` stores separate versioned JSON files under the extension's
  Application Support directory. Validated keys are safe filenames such as
  `02108-location-v1.json` and `02108-imperial-forecast-v1.json`.
- Write a temporary sibling file and atomically replace the destination. A
  failed write leaves the previous last-good file intact. Ignore corrupt or
  unknown-schema cache files.
- `CachedForecast` contains schema version, zip, units, location, timezone,
  UTC-offset fallback, `fetchedAt`, summaries, and whether ECMWF contributed.
- Mark a fallback forecast stale after a failed refresh and show its age. Use it
  only while it is younger than 48 hours and contains at least one forecast day
  on or after the location's current date.
- Cache entries are shared by widget instances with the same zip and units.
  Instances with different configurations use different files. No host-app
  access or App Group is required.
- Model availability/freshness as `unconfigured`, `invalidConfiguration`,
  `preview`, `fresh`, `stale`, or `unavailable`. Model ECMWF contribution as a
  separate boolean so the degraded indicator can coexist with fresh or stale
  data.

### Timeline and timezone policy

- On success, request the next timeline after `now + 6 hours`.
- On primary failure with a usable cache, request another timeline after
  `now + 1 hour`. Without a usable cache, retry after `now + 30 minutes`.
- Build a Gregorian `Calendar` from the API timezone identifier. Fall back to a
  fixed timezone from `utc_offset_seconds` only when the identifier is invalid.
- Include a location-midnight entry only when midnight occurs before the next
  requested refresh. Each entry filters out forecast days earlier than its own
  location-local date.
- Do not add three-hour entries: they neither fetch new data nor change the
  daily summary.

### Widget configuration and presentation

- `WeatherConfigurationIntent` has an optional zip `String` and a units
  `AppEnum`. Its initializer selects metric or imperial from the current locale.
- Normalize the zip by trimming whitespace, then require exactly five ASCII
  digits. Keep it as a string so leading zeroes survive.
- Family content:
  - Small: today's high/low and confidence as the hero, plus two compact days.
  - Medium: five days.
  - Large: ten days.
  - Extra large: the full forecast, up to 15 days.
- Encode confidence with text and shape (`●●●`, `●●○`, `●○○`), with color only
  as reinforcement. Add explicit VoiceOver labels such as “high confidence.”
- Show `WeatherNext only` for degraded data and `Updated N hours ago` for stale
  data. An unavailable view tells the user that no saved forecast exists.
- Verify `fullColor`, `accented`, and `vibrant` rendering, removable backgrounds,
  light/dark appearance, increased contrast, and realistic desktop wallpapers.

### Host app, entitlements, and attribution

- The host app contains one window explaining what the widget shows, how to add
  and configure it, and that configuration belongs to each widget instance.
- Include `Forecast data via Open-Meteo` with a link in the host window and
  README.
- Enable App Sandbox and outbound network access on the widget extension. Do not
  add location permissions or an App Group.
- Use Swift 6 strict concurrency. Core value types are `Sendable`; isolate cache
  mutation in an actor instead of suppressing concurrency warnings.

### Delivery phases and estimate

| # | Phase | Estimate |
| --- | --- | --- |
| 0 | Install/select Xcode 26 and prove a minimal Swift Testing target runs | user action, ~1h |
| 1 | Align the existing scaffold with revision 3; add edge fixtures and regenerate the unrounded reference | 0.5d |
| 2 | Add Swift tests, conformance executable, comparator, and CI commands | 0.5d |
| 3 | Port statistics, ensemble decoding, summaries, and cross-check to conformance green | 0.75d |
| 4 | Implement MapKit geocoding, concurrent fetch-and-summarize, cache, and injected clock/network/filesystem seams | 0.75d |
| 5 | Create and commit the Xcode project, host app, widget target, entitlements, and local signing | 0.75d |
| 6 | Complete the four-family design pass and rendering-mode previews | 0.5d |
| 7 | Implement intent configuration, views, accessibility, and all visible states | 1.0d |
| 8 | Integrate timeline, timezone rollover, cache fallback, and retry policies | 0.75d |
| 9 | Run end-to-end validation; finish README, attribution, screenshots, and CI | 0.5d |

Plan on **about 6 working days including contingency** for a polished local
prototype. Public distribution is not included in this estimate.

## End-to-End Testing

### Setup

- Select Xcode 26 for SwiftPM and the app project.
- Sign and install the host app locally, launch it once, and add each widget
  family from the macOS gallery.
- Keep the Mac in an Eastern timezone and use fixtures plus an injected clock
  for deterministic midnight and DST checks.
- Run lifecycle tests outside the Xcode debugger because debug refresh behavior
  does not match WidgetKit's normal scheduling.

### Scenarios

1. Open the gallery offline. All families render canned previews without a
   network request, clipping, or placeholder leakage.
2. Add an unconfigured widget, configure `02108` with imperial units, and verify
   the first successful forecast, location label, confidence, and attribution
   path without a location-permission prompt.
3. Add a second instance for a different zip in metric units. Verify independent
   data, thresholds, labels, cache files, and refreshes.
4. Configure a zip in a timezone remote from the Mac. Cross its local midnight
   with the injected clock and verify the day changes at the forecast location's
   midnight, including across a DST boundary.
5. Fail ECMWF while WeatherNext succeeds. Verify a degraded indicator,
   spread-only confidence, a cached successful primary forecast, and recovery on
   the next complete refresh.
6. Fail WeatherNext with a cache younger than 48 hours. Verify stale data and its
   age remain visible and a one-hour retry is requested. If that cached result
   lacked ECMWF, verify stale and degraded indicators appear together.
7. Fail the initial WeatherNext request without a cache. Verify the unavailable
   state and a 30-minute retry; then restore the network and verify recovery.
8. Enter malformed and unknown zips. Verify malformed input starts no work,
   unknown input produces an editable invalid-configuration state, and a MapKit
   service failure is not mislabeled as an invalid zip.
9. Terminate and relaunch the app/extension after a successful fetch. Verify the
   location and forecast survive process death without an App Group.
10. Corrupt a cache file and simulate an interrupted cache write. Verify the
    corrupt entry is ignored and an existing last-good destination is not
    destroyed.
11. Verify every family in full-color, accented, vibrant, light, dark, and
    increased-contrast appearances. Confirm confidence remains distinguishable
    without color and VoiceOver announces rating, staleness, and degraded state.
12. Leave the widgets installed outside the debugger for at least 24 hours.
    Verify normal six-hour refreshes, location-midnight rollover, and recovery
    from a temporary network outage without excessive reload requests.

### Automated gates

- Existing and new Python aggregation tests pass.
- Swift package tests pass with strict concurrency enabled.
- Python reference freshness and Swift whole-payload conformance checks pass.
- The host app and widget build successfully for macOS 26 with no signing,
  entitlement, availability, or concurrency warnings attributable to the
  project.

## Open Questions

- None block implementation. Public distribution, commercial Open-Meteo use,
  and a host-app forecast experience require separate scoped plans.
