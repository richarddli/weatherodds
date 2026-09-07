import Foundation

public struct CachedLocation: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let zip: String
    public let location: Location

    public init(
        schemaVersion: Int = CachedLocation.currentSchemaVersion,
        zip: String,
        location: Location
    ) {
        self.schemaVersion = schemaVersion
        self.zip = zip
        self.location = location
    }
}

public struct CachedForecast: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public static let refreshInterval: TimeInterval = 6 * 60 * 60
    public static let maximumFallbackAge: TimeInterval = 48 * 60 * 60

    public let schemaVersion: Int
    public let zip: String
    public let unitName: String
    public let location: Location
    public let timeZoneIdentifier: String
    public let utcOffsetSeconds: Int
    public let fetchedAt: Date
    public let summaries: [DaySummary]
    public let ecmwfContributed: Bool

    public init(
        schemaVersion: Int = CachedForecast.currentSchemaVersion,
        zip: String,
        unitName: String,
        location: Location,
        timeZoneIdentifier: String,
        utcOffsetSeconds: Int,
        fetchedAt: Date,
        summaries: [DaySummary],
        ecmwfContributed: Bool
    ) {
        self.schemaVersion = schemaVersion
        self.zip = zip
        self.unitName = unitName
        self.location = location
        self.timeZoneIdentifier = timeZoneIdentifier
        self.utcOffsetSeconds = utcOffsetSeconds
        self.fetchedAt = fetchedAt
        self.summaries = summaries
        self.ecmwfContributed = ecmwfContributed
    }

    public init(
        zip: USZipCode,
        units: Units,
        location: Location,
        timeZoneIdentifier: String,
        utcOffsetSeconds: Int,
        fetchedAt: Date,
        summaries: [DaySummary],
        ecmwfContributed: Bool
    ) {
        self.init(
            zip: zip.rawValue,
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
    /// property of the caller, not of one ZIP or unit choice, so changing
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

    public func loadLocation(for zip: USZipCode) -> CachedLocation? {
        guard let entry: CachedLocation = decode(from: locationURL(for: zip)),
              entry.schemaVersion == CachedLocation.currentSchemaVersion,
              entry.zip == zip.rawValue,
              entry.location.zip == zip.rawValue
        else {
            return nil
        }
        return entry
    }

    public func saveLocation(_ location: Location, for zip: USZipCode) throws {
        guard location.zip == zip.rawValue else {
            throw CacheError.keyMismatch
        }
        try encode(
            CachedLocation(zip: zip.rawValue, location: location),
            to: locationURL(for: zip)
        )
    }

    public func loadForecast(for zip: USZipCode, units: Units) -> CachedForecast? {
        guard let entry: CachedForecast = decode(from: forecastURL(for: zip, units: units)),
              entry.schemaVersion == CachedForecast.currentSchemaVersion,
              entry.zip == zip.rawValue,
              entry.unitName == units.name,
              entry.location.zip == zip.rawValue
        else {
            return nil
        }
        return entry
    }

    /// Reuses a fresh durable forecast or shares one refresh among callers for
    /// the same ZIP and units. Widget providers must share this actor instance.
    ///
    /// This is the single gate in front of the network: a cooldown recorded by
    /// an earlier failure suppresses the request even after the extension
    /// restarts, and the thrown `ForecastUnavailable` carries the deadline the
    /// caller should hand to WidgetKit.
    public func loadOrRefreshForecast(
        for zip: USZipCode,
        units: Units,
        at now: Date,
        refresh: @escaping @Sendable () async throws -> ForecastRefreshResult
    ) async throws -> CachedForecast {
        try Task.checkCancellation()
        if let saved = loadForecast(for: zip, units: units), saved.isFresh(at: now) {
            return saved
        }

        let key = forecastURL(for: zip, units: units)
        let task: Task<ForecastRefreshResult, Error>
        if let pending = refreshTasks[key] {
            // Joining a request already in flight adds no upstream traffic.
            task = pending
        } else {
            if let cooldown = activeCooldown(for: zip, units: units, at: now) {
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
                        try saveForecast(result.forecast, for: zip, units: units)
                    } catch let error as CacheError {
                        throw error
                    } catch {}
                    recordSuccess(for: zip, units: units, rateLimit: result.rateLimit, at: now)
                    return result
                } catch is CancellationError {
                    // An interrupted refresh says nothing about the upstream,
                    // so it must not extend any backoff.
                    throw CancellationError()
                } catch {
                    throw recordFailure(error, for: zip, units: units, at: now)
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
    public func nextEligibleAttempt(for zip: USZipCode, units: Units, at now: Date) -> Date? {
        activeCooldown(for: zip, units: units, at: now)?.deadline
    }

    /// The cooldown holding this configuration back, reported as one record so
    /// the deadline and the failure count that produced it always agree.
    func activeCooldown(
        for zip: USZipCode,
        units: Units,
        at now: Date
    ) -> (deadline: Date, consecutiveFailures: Int)? {
        [
            retryState(for: zip, units: units),
            retryState(forKey: Self.rateLimitKey),
        ]
        .compactMap { state -> (deadline: Date, consecutiveFailures: Int)? in
            guard let state, let deadline = state.activeDeadline(at: now) else { return nil }
            return (deadline, state.failureCount(at: now))
        }
        .max { $0.deadline < $1.deadline }
    }

    func retryState(for zip: USZipCode, units: Units) -> RetryState? {
        retryState(forKey: retryKey(for: zip, units: units))
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
        for zip: USZipCode,
        units: Units,
        rateLimit: UpstreamHTTPFailure?,
        at now: Date
    ) {
        clearRetryState(forKey: retryKey(for: zip, units: units))
        if let rateLimit {
            _ = advanceRetryState(forKey: Self.rateLimitKey, httpFailure: rateLimit, at: now)
        } else {
            clearRetryState(forKey: Self.rateLimitKey)
        }
    }

    private func recordFailure(
        _ error: any Error,
        for zip: USZipCode,
        units: Units,
        at now: Date
    ) -> ForecastUnavailable {
        let httpFailure = (error as? FetchError)?.upstreamHTTPFailure
        let isRateLimited = httpFailure?.isRateLimited == true
        let local = advanceRetryState(
            forKey: retryKey(for: zip, units: units),
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

    public func saveForecast(_ forecast: CachedForecast, for zip: USZipCode, units: Units) throws {
        guard forecast.zip == zip.rawValue,
              forecast.location.zip == zip.rawValue,
              forecast.unitName == units.name,
              forecast.schemaVersion == CachedForecast.currentSchemaVersion
        else {
            throw CacheError.keyMismatch
        }
        try encode(forecast, to: forecastURL(for: zip, units: units))
    }

    public nonisolated func locationURL(for zip: USZipCode) -> URL {
        rootDirectory.appending(path: "\(zip.rawValue)-location-v1.json")
    }

    public nonisolated func forecastURL(for zip: USZipCode, units: Units) -> URL {
        rootDirectory.appending(path: "\(zip.rawValue)-\(units.name)-forecast-v1.json")
    }

    nonisolated func retryKey(for zip: USZipCode, units: Units) -> String {
        "\(zip.rawValue)-\(units.name)"
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
