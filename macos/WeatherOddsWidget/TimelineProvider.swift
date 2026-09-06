import Foundation
import WeatherOddsCore
import WidgetKit

enum ForecastAvailability: Equatable, Sendable {
    case unconfigured
    case invalidConfiguration(String)
    case preview
    case fresh
    case stale
    case unavailable(String)
}

struct WeatherEntry: TimelineEntry, Sendable {
    let date: Date
    let availability: ForecastAvailability
    let locationName: String?
    let days: [DaySummary]
    let units: UnitChoice
    let fetchedAt: Date?
    let ecmwfContributed: Bool
    let timeZoneIdentifier: String
    let utcOffsetSeconds: Int

    var timeZone: TimeZone {
        TimeZone(identifier: timeZoneIdentifier)
            ?? TimeZone(secondsFromGMT: utcOffsetSeconds)
            ?? .gmt
    }

    var visibleDays: [DaySummary] {
        let localDate = Self.localDateString(for: date, timeZone: timeZone)
        return days.filter { $0.date >= localDate }
    }

    var isDegraded: Bool {
        !days.isEmpty && !ecmwfContributed
    }

    var staleAge: TimeInterval? {
        guard availability == .stale, let fetchedAt else { return nil }
        return max(0, date.timeIntervalSince(fetchedAt))
    }

    static func unconfigured(at date: Date, units: UnitChoice) -> WeatherEntry {
        WeatherEntry(
            date: date,
            availability: .unconfigured,
            locationName: nil,
            days: [],
            units: units,
            fetchedAt: nil,
            ecmwfContributed: false,
            timeZoneIdentifier: "UTC",
            utcOffsetSeconds: 0
        )
    }

    static func message(
        at date: Date,
        availability: ForecastAvailability,
        units: UnitChoice
    ) -> WeatherEntry {
        WeatherEntry(
            date: date,
            availability: availability,
            locationName: nil,
            days: [],
            units: units,
            fetchedAt: nil,
            ecmwfContributed: false,
            timeZoneIdentifier: "UTC",
            utcOffsetSeconds: 0
        )
    }

    static func cached(
        _ cached: CachedForecast,
        at date: Date,
        availability: ForecastAvailability,
        units: UnitChoice
    ) -> WeatherEntry {
        WeatherEntry(
            date: date,
            availability: availability,
            locationName: cached.location.displayName,
            days: cached.summaries,
            units: units,
            fetchedAt: cached.fetchedAt,
            ecmwfContributed: cached.ecmwfContributed,
            timeZoneIdentifier: cached.timeZoneIdentifier,
            utcOffsetSeconds: cached.utcOffsetSeconds
        )
    }

    static func canned(at date: Date = .now, units: UnitChoice = .imperial) -> WeatherEntry {
        let timeZone = TimeZone(identifier: "America/New_York")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let start = calendar.startOfDay(for: date)
        let ratings = ["high", "high", "medium", "medium", "low"]

        let days = (0..<15).map { offset in
            let day = calendar.date(byAdding: .day, value: offset, to: start)!
            let dateString = localDateString(for: day, timeZone: timeZone)
            let high = units == .metric ? 23.0 - Double(offset % 4) : 74.0 - Double(offset % 4) * 2
            let range = units == .metric ? 2.6 + Double(offset % 3) : 4.5 + Double(offset % 3) * 2
            let rain = [0.08, 0.18, 0.42, 0.71, 0.26][offset % 5]
            let rating = ratings[offset % ratings.count]
            return DaySummary(
                date: dateString,
                highMedian: high,
                highP10: high - range / 2,
                highP90: high + range / 2,
                lowMedian: high - (units == .metric ? 8 : 14),
                lowP10: high - (units == .metric ? 10 : 18),
                lowP90: high - (units == .metric ? 6 : 10),
                spread: range,
                rainProbability: rain,
                membersWet: Int((rain * 64).rounded()),
                membersTotal: 64,
                amountMedian: rain > 0.3 ? (units == .metric ? 6.4 : 0.25) : nil,
                amountP90: rain > 0.3 ? (units == .metric ? 15.0 : 0.59) : nil,
                windMedianMax: units == .metric ? 18 : 11,
                gustsP90: units == .metric ? 35 : 22,
                cloudCover: rain * 100,
                steps: 24,
                partial: offset == 0,
                rating: rating,
                points: rating == "high" ? 2 : rating == "medium" ? 1 : 0,
                ecmwfAgrees: rating == "high" ? true : rating == "low" ? false : nil
            )
        }

        return WeatherEntry(
            date: date,
            availability: .preview,
            locationName: "Boston, MA",
            days: days,
            units: units,
            fetchedAt: date.addingTimeInterval(-22 * 60),
            ecmwfContributed: true,
            timeZoneIdentifier: timeZone.identifier,
            utcOffsetSeconds: timeZone.secondsFromGMT(for: date)
        )
    }

    static func localDateString(for date: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            parts.year ?? 0,
            parts.month ?? 0,
            parts.day ?? 0
        )
    }
}

struct WeatherTimelineProvider: AppIntentTimelineProvider {
    typealias Entry = WeatherEntry
    typealias Intent = WeatherConfigurationIntent

    private static let sharedCache = WeatherOddsCache()
    private let cache = Self.sharedCache
    private let refresher = ForecastRefresher()

    func placeholder(in context: Context) -> WeatherEntry {
        .canned()
    }

    func snapshot(
        for configuration: WeatherConfigurationIntent,
        in context: Context
    ) async -> WeatherEntry {
        let now = Date.now
        guard let rawZip = configuration.zipCode,
              !rawZip.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return context.isPreview
                ? .canned(at: now, units: configuration.effectiveUnits)
                : .unconfigured(at: now, units: configuration.effectiveUnits)
        }

        let zip: USZipCode
        do {
            zip = try USZipCode(rawZip)
        } catch let error as GeocodeError {
            return .message(
                at: now,
                availability: .invalidConfiguration(error.localizedDescription),
                units: configuration.effectiveUnits
            )
        } catch {
            return .message(
                at: now,
                availability: .invalidConfiguration("Enter a five-digit US zip code."),
                units: configuration.effectiveUnits
            )
        }

        if let saved = await cache.loadForecast(
            for: zip,
            units: configuration.effectiveUnits.coreUnits
        ) {
            return .cached(
                saved,
                at: now,
                availability: .preview,
                units: configuration.effectiveUnits
            )
        }
        return .canned(at: now, units: configuration.effectiveUnits)
    }

    func timeline(
        for configuration: WeatherConfigurationIntent,
        in context: Context
    ) async -> Timeline<WeatherEntry> {
        let now = Date.now
        guard let rawZip = configuration.zipCode,
              !rawZip.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return Timeline(
                entries: [.unconfigured(at: now, units: configuration.effectiveUnits)],
                policy: .never
            )
        }

        let zip: USZipCode
        do {
            zip = try USZipCode(rawZip)
        } catch let error as GeocodeError {
            return Timeline(
                entries: [.message(
                    at: now,
                    availability: .invalidConfiguration(error.localizedDescription),
                    units: configuration.effectiveUnits
                )],
                policy: .never
            )
        } catch {
            return Timeline(
                entries: [.message(
                    at: now,
                    availability: .invalidConfiguration("Enter a five-digit US zip code."),
                    units: configuration.effectiveUnits
                )],
                policy: .never
            )
        }

        return await refreshedTimeline(
            at: now,
            zip: zip,
            unitChoice: configuration.effectiveUnits
        )
    }
}

private extension WeatherTimelineProvider {
    func refreshedTimeline(
        at now: Date,
        zip: USZipCode,
        unitChoice: UnitChoice
    ) async -> Timeline<WeatherEntry> {
        let units = unitChoice.coreUnits
        let savedForecast = await cache.loadForecast(for: zip, units: units)

        let location: Location
        if let savedLocation = await cache.loadLocation(for: zip)?.location {
            location = savedLocation
        } else if let savedForecast {
            // The forecast cache also owns a validated, Sendable location. It
            // keeps a missing standalone location file from blocking refresh.
            location = savedForecast.location
        } else {
            do {
                location = try await USZipCodeGeocoder().location(for: zip.rawValue)
                try? await cache.saveLocation(location, for: zip)
            } catch let error as GeocodeError where error.isInvalidConfiguration {
                return Timeline(
                    entries: [.message(
                        at: now,
                        availability: .invalidConfiguration(error.localizedDescription),
                        units: unitChoice
                    )],
                    policy: .never
                )
            } catch {
                // MapKit geocoding is a different upstream, so it keeps its own
                // delay while still respecting any Open-Meteo cooldown.
                return failureTimeline(
                    at: now,
                    savedForecast: savedForecast,
                    unitChoice: unitChoice,
                    message: "Location lookup is temporarily unavailable.",
                    retryAt: max(
                        now.addingTimeInterval(RetryPolicy.baseDelay),
                        await cache.nextEligibleAttempt(for: zip, units: units, at: now)
                            ?? .distantPast
                    )
                )
            }
        }

        do {
            let refreshed = try await cache.loadOrRefreshForecast(
                for: zip,
                units: units,
                at: now
            ) {
                try await refresher.refresh(
                    for: zip,
                    location: location,
                    units: units,
                    at: now
                )
            }
            let entry = WeatherEntry.cached(
                refreshed,
                at: now,
                availability: .fresh,
                units: unitChoice
            )
            // A rate limit reported by the optional model outlives this
            // forecast's own deadline; waking before it expires would only be
            // suppressed again.
            let refreshAt = max(
                refreshed.nextRefreshDate,
                await cache.nextEligibleAttempt(for: zip, units: units, at: now)
                    ?? .distantPast
            )
            return successTimeline(from: entry, refreshAt: refreshAt)
        } catch is CancellationError {
            // Cancellation records no failure state, so it must not retry
            // immediately either.
            return failureTimeline(
                at: now,
                savedForecast: savedForecast,
                unitChoice: unitChoice,
                message: "Forecast update was interrupted.",
                retryAt: max(
                    now.addingTimeInterval(RetryPolicy.interruptedDelay),
                    await cache.nextEligibleAttempt(for: zip, units: units, at: now)
                        ?? .distantPast
                )
            )
        } catch let unavailable as ForecastUnavailable {
            return failureTimeline(
                at: now,
                savedForecast: savedForecast,
                unitChoice: unitChoice,
                message: "Forecast service is temporarily unavailable.",
                retryAt: unavailable.nextAttempt
            )
        } catch {
            return failureTimeline(
                at: now,
                savedForecast: savedForecast,
                unitChoice: unitChoice,
                message: "Forecast service is temporarily unavailable.",
                retryAt: await cache.nextEligibleAttempt(for: zip, units: units, at: now)
                    ?? now.addingTimeInterval(RetryPolicy.baseDelay)
            )
        }
    }

    /// Retries are always requested as a WidgetKit reload date; the extension
    /// never sleeps or loops waiting for `retryAt`.
    func failureTimeline(
        at now: Date,
        savedForecast: CachedForecast?,
        unitChoice: UnitChoice,
        message: String,
        retryAt: Date
    ) -> Timeline<WeatherEntry> {
        if let savedForecast, savedForecast.isUsableFallback(at: now) {
            let entry = WeatherEntry.cached(
                savedForecast,
                at: now,
                availability: .stale,
                units: unitChoice
            )
            return successTimeline(from: entry, refreshAt: retryAt)
        }

        let entry = WeatherEntry.message(
            at: now,
            availability: .unavailable(message),
            units: unitChoice
        )
        return Timeline(entries: [entry], policy: .after(retryAt))
    }

    func successTimeline(
        from entry: WeatherEntry,
        refreshAt: Date
    ) -> Timeline<WeatherEntry> {
        var entries = [entry]
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = entry.timeZone
        let startOfToday = calendar.startOfDay(for: entry.date)
        if let midnight = calendar.date(byAdding: .day, value: 1, to: startOfToday),
           midnight > entry.date,
           midnight < refreshAt
        {
            entries.append(WeatherEntry(
                date: midnight,
                availability: entry.availability,
                locationName: entry.locationName,
                days: entry.days,
                units: entry.units,
                fetchedAt: entry.fetchedAt,
                ecmwfContributed: entry.ecmwfContributed,
                timeZoneIdentifier: entry.timeZoneIdentifier,
                utcOffsetSeconds: entry.utcOffsetSeconds
            ))
        }
        return Timeline(entries: entries, policy: .after(refreshAt))
    }
}
