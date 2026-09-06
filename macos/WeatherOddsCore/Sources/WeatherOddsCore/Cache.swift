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
    public nonisolated let rootDirectory: URL
    private var refreshTasks: [URL: Task<CachedForecast, Error>] = [:]

    public init(rootDirectory: URL) {
        self.rootDirectory = rootDirectory
    }

    public init() {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        self.rootDirectory = applicationSupport.appending(
            path: "WeatherOdds",
            directoryHint: .isDirectory
        )
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
    public func loadOrRefreshForecast(
        for zip: USZipCode,
        units: Units,
        at now: Date,
        refresh: @escaping @Sendable () async throws -> CachedForecast
    ) async throws -> CachedForecast {
        try Task.checkCancellation()
        if let saved = loadForecast(for: zip, units: units), saved.isFresh(at: now) {
            return saved
        }

        let key = forecastURL(for: zip, units: units)
        let task: Task<CachedForecast, Error>
        if let pending = refreshTasks[key] {
            task = pending
        } else {
            task = Task {
                defer { refreshTasks[key] = nil }
                let forecast = try await refresh()
                // A failed disk write must not hide a successfully fetched
                // forecast, but a response for another configuration is invalid.
                do {
                    try saveForecast(forecast, for: zip, units: units)
                } catch let error as CacheError {
                    throw error
                } catch {}
                return forecast
            }
            refreshTasks[key] = task
        }

        // Cancelling one widget request must not cancel a fetch shared by
        // another widget. The transport supplies its own bounded timeout.
        let forecast = try await task.value
        try Task.checkCancellation()
        return forecast
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
