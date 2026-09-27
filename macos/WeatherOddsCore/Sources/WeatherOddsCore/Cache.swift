import Foundation
import CryptoKit

public struct CachedLocation: Codable, Equatable, Sendable {
    // Keep the on-disk key so existing v1 ZIP caches remain readable.
    private enum CodingKeys: String, CodingKey {
        case schemaVersion, location
        case locationID = "zip"
    }

    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let locationID: String
    public let location: Location

    public init(
        schemaVersion: Int = CachedLocation.currentSchemaVersion,
        locationID: String,
        location: Location
    ) {
        self.schemaVersion = schemaVersion
        self.locationID = locationID
        self.location = location
    }
}

public struct CachedForecast: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case schemaVersion, unitName, location, timeZoneIdentifier, utcOffsetSeconds
        case fetchedAt, summaries, ecmwfContributed
        case locationID = "zip"
    }

    public static let currentSchemaVersion = 1
    public static let refreshInterval: TimeInterval = 6 * 60 * 60
    public static let maximumFallbackAge: TimeInterval = 48 * 60 * 60

    public let schemaVersion: Int
    public let locationID: String
    public let unitName: String
    public let location: Location
    public let timeZoneIdentifier: String
    public let utcOffsetSeconds: Int
    public let fetchedAt: Date
    public let summaries: [DaySummary]
    public let ecmwfContributed: Bool

    public init(
        schemaVersion: Int = CachedForecast.currentSchemaVersion,
        locationID: String,
        unitName: String,
        location: Location,
        timeZoneIdentifier: String,
        utcOffsetSeconds: Int,
        fetchedAt: Date,
        summaries: [DaySummary],
        ecmwfContributed: Bool
    ) {
        self.schemaVersion = schemaVersion
        self.locationID = locationID
        self.unitName = unitName
        self.location = location
        self.timeZoneIdentifier = timeZoneIdentifier
        self.utcOffsetSeconds = utcOffsetSeconds
        self.fetchedAt = fetchedAt
        self.summaries = summaries
        self.ecmwfContributed = ecmwfContributed
    }

    public init(
        locationID: LocationID,
        units: Units,
        location: Location,
        timeZoneIdentifier: String,
        utcOffsetSeconds: Int,
        fetchedAt: Date,
        summaries: [DaySummary],
        ecmwfContributed: Bool
    ) {
        self.init(
            locationID: locationID.rawValue,
            unitName: units.name,
            location: location,
            timeZoneIdentifier: timeZoneIdentifier,
            utcOffsetSeconds: utcOffsetSeconds,
            fetchedAt: fetchedAt,
            summaries: summaries,
            ecmwfContributed: ecmwfContributed
        )
    }

    /// Reusing a forecast must not postpone the next network refresh.
    public var nextRefreshDate: Date {
        fetchedAt.addingTimeInterval(Self.refreshInterval)
    }

    public func isFresh(at now: Date) -> Bool {
        // A future timestamp may come from a clock change. Refresh it instead
        // of letting it suppress requests indefinitely.
        now >= fetchedAt && now < nextRefreshDate
            && summaries.contains { $0.date >= currentLocalDate(at: now) }
    }

    /// Whether this entry may be shown after a failed primary refresh.
    public func isUsableFallback(
        at now: Date,
        currentLocalDate: String,
        maximumAge: TimeInterval = CachedForecast.maximumFallbackAge
    ) -> Bool {
        let age = max(0, now.timeIntervalSince(fetchedAt))
        return age < maximumAge
            && summaries.contains { $0.date >= currentLocalDate }
    }

    /// Derives the location's current calendar date using the API timezone,
    /// falling back to its fixed UTC offset if the identifier is unavailable.
    public func currentLocalDate(at date: Date) -> String {
        let timeZone = TimeZone(identifier: timeZoneIdentifier)
            ?? TimeZone(secondsFromGMT: utcOffsetSeconds)
            ?? .gmt
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = timeZone
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }

    public func isUsableFallback(
        at now: Date,
        maximumAge: TimeInterval = CachedForecast.maximumFallbackAge
    ) -> Bool {
        isUsableFallback(
            at: now,
            currentLocalDate: currentLocalDate(at: now),
            maximumAge: maximumAge
        )
    }
}

/// Extension-local storage for geocoding and last-good forecast responses.
///
/// The actor serializes writes from independently configured widget instances.
/// Its root is injectable so tests and previews never touch production data.
public actor WeatherOddsCache {
    /// Retry key shared by every configuration. An Open-Meteo rate limit is a
    /// property of the caller, not of one location or unit choice, so changing
    /// configuration must not bypass it.
    public static let rateLimitKey = "open-meteo"

    public nonisolated let rootDirectory: URL
    private let retryPolicy: RetryPolicy
    private var refreshTasks: [URL: Task<ForecastRefreshResult, Error>] = [:]

    public init(rootDirectory: URL, retryPolicy: RetryPolicy = RetryPolicy()) {
        self.rootDirectory = rootDirectory
        self.retryPolicy = retryPolicy
    }

    public init(retryPolicy: RetryPolicy = RetryPolicy()) {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        self.rootDirectory = applicationSupport.appending(
            path: "WeatherOdds",
            directoryHint: .isDirectory
        )
        self.retryPolicy = retryPolicy
    }

    public func suggestedLocations() -> [Location] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: rootDirectory, includingPropertiesForKeys: nil
        )) ?? []
        return files.filter { $0.lastPathComponent.hasSuffix("-location-v1.json") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url -> Location? in
                guard let record: CachedLocation = decode(from: url),
                      let id = try? LocationID(record.locationID)
                else { return nil }
                return loadLocation(for: id)?.location
            }
    }

    public func loadSearch(query: String, at now: Date) -> [Location]? {
        guard let saved: CachedSearch = decode(from: searchURL(query)),
              saved.query == query,
              saved.fetchedAt <= now,
              now.timeIntervalSince(saved.fetchedAt) < 30 * 24 * 60 * 60
        else { return nil }
        return saved.locations
    }

    public func saveSearch(_ locations: [Location], query: String, at now: Date) throws {
        try encode(CachedSearch(query: query, fetchedAt: now, locations: locations),
                   to: searchURL(query))
    }

    private func searchURL(_ query: String) -> URL {
        let hash = SHA256.hash(data: Data(query.utf8)).map { String(format: "%02x", $0) }.joined()
        return rootDirectory.appending(path: "search-\(hash)-v1.json")
    }

    public func checkGeocodingCooldown(at now: Date) throws {
        let active = [Self.rateLimitKey, "geocoding"].compactMap { key -> (RetryState, Date)? in
            guard let state = retryState(forKey: key), let deadline = state.activeDeadline(at: now)
            else { return nil }
            return (state, deadline)
        }.max { $0.1 < $1.1 }
        if let (state, deadline) = active {
            throw ForecastUnavailable(
                reason: .cooldown, nextAttempt: deadline,
                consecutiveFailures: state.failureCount(at: now),
                message: "Location search can try again after \(deadline.formatted(date: .omitted, time: .standard))."
            )
        }
    }

    public func recordGeocodingSuccess() {
        clearRetryState(forKey: "geocoding")
    }

    public func recordGeocodingFailure(_ error: any Error, at now: Date) {
        if error is CancellationError { return }
        if let error = error as? GeocodeError, error.isInvalidConfiguration { return }
        let failure = (error as? FetchError)?.upstreamHTTPFailure
        if failure?.isRateLimited == true {
            _ = advanceRetryState(forKey: Self.rateLimitKey, httpFailure: failure, at: now)
            return
        }
        // A person typing in the picker should recover quickly after a timeout.
        // Background forecast backoff starts at 30 minutes, far too long here.
        let failures = (retryState(forKey: "geocoding")?.failureCount(at: now) ?? 0) + 1
        let backoff = min(2 * pow(2, Double(min(max(failures - 1, 0), 16))), 60)
        let delay = RetryAfterHeader.delay(failure?.retryAfterHeader, at: now) ?? backoff
        let state = RetryState(
            key: "geocoding", consecutiveFailures: failures, recordedAt: now,
            nextAttemptAfter: now.addingTimeInterval(min(delay, RetryPolicy.maximumRetryAfter))
        )
        try? encode(state, to: retryStateURL(forKey: "geocoding"))
    }

    public func loadLocation(for locationID: LocationID) -> CachedLocation? {
        guard let entry: CachedLocation = decode(from: locationURL(for: locationID)),
              entry.schemaVersion == CachedLocation.currentSchemaVersion,
              entry.locationID == locationID.rawValue,
              entry.location.id.rawValue == locationID.rawValue
        else {
            return nil
        }
        return entry
    }

    public func saveLocation(_ location: Location, for locationID: LocationID) throws {
        guard location.id.rawValue == locationID.rawValue else {
            throw CacheError.keyMismatch
        }
        try encode(
            CachedLocation(locationID: locationID.rawValue, location: location),
            to: locationURL(for: locationID)
        )
    }

    public func loadForecast(for locationID: LocationID, units: Units) -> CachedForecast? {
        guard let entry: CachedForecast = decode(from: forecastURL(for: locationID, units: units)),
              entry.schemaVersion == CachedForecast.currentSchemaVersion,
              entry.locationID == locationID.rawValue,
              entry.unitName == units.name,
              entry.location.id.rawValue == locationID.rawValue
        else {
            return nil
        }
        return entry
    }

    /// Reuses a fresh durable forecast or shares one refresh among callers for
    /// the same location and units. Widget providers must share this actor instance.
    ///
    /// This is the single gate in front of the network: a cooldown recorded by
    /// an earlier failure suppresses the request even after the extension
    /// restarts, and the thrown `ForecastUnavailable` carries the deadline the
    /// caller should hand to WidgetKit.
    public func loadOrRefreshForecast(
        for locationID: LocationID,
        units: Units,
        at now: Date,
        refresh: @escaping @Sendable () async throws -> ForecastRefreshResult
    ) async throws -> CachedForecast {
        try Task.checkCancellation()
        if let saved = loadForecast(for: locationID, units: units), saved.isFresh(at: now) {
            return saved
        }

        let key = forecastURL(for: locationID, units: units)
        let task: Task<ForecastRefreshResult, Error>
        if let pending = refreshTasks[key] {
            // Joining a request already in flight adds no upstream traffic.
            task = pending
        } else {
            if let cooldown = activeCooldown(for: locationID, units: units, at: now) {
                throw ForecastUnavailable(
                    reason: .cooldown,
                    nextAttempt: cooldown.deadline,
                    consecutiveFailures: cooldown.consecutiveFailures
                )
            }
            task = Task {
                defer { refreshTasks[key] = nil }
                do {
                    let result = try await refresh()
                    // A failed disk write must not hide a successfully fetched
                    // forecast, but a response for another configuration is
                    // invalid and is accounted for as a failure below.
                    do {
                        try saveForecast(result.forecast, for: locationID, units: units)
                    } catch let error as CacheError {
                        throw error
                    } catch {}
                    recordSuccess(for: locationID, units: units, rateLimit: result.rateLimit, at: now)
                    return result
                } catch is CancellationError {
                    // An interrupted refresh says nothing about the upstream,
                    // so it must not extend any backoff.
                    throw CancellationError()
                } catch {
                    throw recordFailure(error, for: locationID, units: units, at: now)
                }
            }
            refreshTasks[key] = task
        }

        // Cancelling one widget request must not cancel a fetch shared by
        // another widget. The transport supplies its own bounded timeout.
        let result = try await task.value
        try Task.checkCancellation()
        return result.forecast
    }

    /// The latest cooldown deadline that applies to this configuration, or nil
    /// when an upstream request is permitted now.
    public func nextEligibleAttempt(for locationID: LocationID, units: Units, at now: Date) -> Date? {
        activeCooldown(for: locationID, units: units, at: now)?.deadline
    }

    /// The cooldown holding this configuration back, reported as one record so
    /// the deadline and the failure count that produced it always agree.
    func activeCooldown(
        for locationID: LocationID,
        units: Units,
        at now: Date
    ) -> (deadline: Date, consecutiveFailures: Int)? {
        [
            retryState(for: locationID, units: units),
            retryState(forKey: Self.rateLimitKey),
        ]
        .compactMap { state -> (deadline: Date, consecutiveFailures: Int)? in
            guard let state, let deadline = state.activeDeadline(at: now) else { return nil }
            return (deadline, state.failureCount(at: now))
        }
        .max { $0.deadline < $1.deadline }
    }

    func retryState(for locationID: LocationID, units: Units) -> RetryState? {
        retryState(forKey: retryKey(for: locationID, units: units))
    }

    func retryState(forKey key: String) -> RetryState? {
        guard let entry: RetryState = decode(from: retryStateURL(forKey: key)),
              entry.schemaVersion == RetryState.currentSchemaVersion,
              entry.key == key
        else {
            return nil
        }
        return entry
    }

    /// Clears the failure state a recovery invalidates. A completed request
    /// also proves the caller is no longer rate limited, unless the optional
    /// model just reported one of its own.
    private func recordSuccess(
        for locationID: LocationID,
        units: Units,
        rateLimit: UpstreamHTTPFailure?,
        at now: Date
    ) {
        clearRetryState(forKey: retryKey(for: locationID, units: units))
        if let rateLimit {
            _ = advanceRetryState(forKey: Self.rateLimitKey, httpFailure: rateLimit, at: now)
        } else {
            clearRetryState(forKey: Self.rateLimitKey)
        }
    }

    private func recordFailure(
        _ error: any Error,
        for locationID: LocationID,
        units: Units,
        at now: Date
    ) -> ForecastUnavailable {
        let httpFailure = (error as? FetchError)?.upstreamHTTPFailure
        let isRateLimited = httpFailure?.isRateLimited == true
        let local = advanceRetryState(
            forKey: retryKey(for: locationID, units: units),
            httpFailure: httpFailure,
            at: now
        )

        var nextAttempt = local.nextAttemptAfter
        if isRateLimited {
            let shared = advanceRetryState(
                forKey: Self.rateLimitKey,
                httpFailure: httpFailure,
                at: now
            )
            nextAttempt = max(nextAttempt, shared.nextAttemptAfter)
        } else if let shared = retryState(forKey: Self.rateLimitKey)?.activeDeadline(at: now) {
            nextAttempt = max(nextAttempt, shared)
        }

        return ForecastUnavailable(
            reason: isRateLimited ? .rateLimited : .transient,
            nextAttempt: nextAttempt,
            consecutiveFailures: local.consecutiveFailures,
            httpFailure: httpFailure,
            message: (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        )
    }

    /// Extends one cooldown record by a single failure and persists it.
    private func advanceRetryState(
        forKey key: String,
        httpFailure: UpstreamHTTPFailure?,
        at now: Date
    ) -> RetryState {
        let failures = (retryState(forKey: key)?.failureCount(at: now) ?? 0) + 1
        let state = RetryState(
            key: key,
            consecutiveFailures: failures,
            recordedAt: now,
            nextAttemptAfter: retryPolicy.nextAttempt(
                at: now,
                consecutiveFailures: failures,
                httpFailure: httpFailure
            )
        )
        // Best effort: a cooldown that cannot be written still applies for the
        // lifetime of the timeline WidgetKit was just handed.
        try? encode(state, to: retryStateURL(forKey: key))
        return state
    }

    private func clearRetryState(forKey key: String) {
        try? FileManager.default.removeItem(at: retryStateURL(forKey: key))
    }

    public func saveForecast(_ forecast: CachedForecast, for locationID: LocationID, units: Units) throws {
        guard forecast.locationID == locationID.rawValue,
              forecast.location.id.rawValue == locationID.rawValue,
              forecast.unitName == units.name,
              forecast.schemaVersion == CachedForecast.currentSchemaVersion
        else {
            throw CacheError.keyMismatch
        }
        try encode(forecast, to: forecastURL(for: locationID, units: units))
    }

    public nonisolated func locationURL(for locationID: LocationID) -> URL {
        rootDirectory.appending(path: "\(locationID.rawValue)-location-v1.json")
    }

    public nonisolated func forecastURL(for locationID: LocationID, units: Units) -> URL {
        rootDirectory.appending(path: "\(locationID.rawValue)-\(units.name)-forecast-v1.json")
    }

    nonisolated func retryKey(for locationID: LocationID, units: Units) -> String {
        "\(locationID.rawValue)-\(units.name)"
    }

    nonisolated func retryStateURL(forKey key: String) -> URL {
        rootDirectory.appending(path: "\(key)-retry-v1.json")
    }

    private func decode<Value: Decodable>(from url: URL) -> Value? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? Self.decoder.decode(Value.self, from: data)
    }

    private func encode<Value: Encodable>(_ value: Value, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: rootDirectory,
            withIntermediateDirectories: true
        )
        let data = try Self.encoder.encode(value)
        // `.atomic` writes a temporary sibling and renames it over the target,
        // preserving the previous last-good file if writing fails.
        try data.write(to: url, options: .atomic)
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }
}

public enum CacheError: Error, Equatable, Sendable {
    case keyMismatch
}

private struct CachedSearch: Codable {
    let query: String
    let fetchedAt: Date
    let locations: [Location]
}
