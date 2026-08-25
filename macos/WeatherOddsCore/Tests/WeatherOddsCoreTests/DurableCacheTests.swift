import Foundation
import Testing
@testable import WeatherOddsCore

@Suite("Durable forecast cache")
struct DurableCacheTests {
    @Test("Location and forecast entries round-trip under configuration keys")
    func roundTripAndKeySeparation() async throws {
        let root = cacheTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let cache = WeatherOddsCache(rootDirectory: root)
        let zip = try USZipCode("02108")
        let location = cacheTestLocation()
        let forecast = cacheTestForecast(zip: zip, location: location)

        try await cache.saveLocation(location, for: zip)
        try await cache.saveForecast(forecast, for: zip, units: .imperial)

        let loadedLocation = await cache.loadLocation(for: zip)
        let loadedForecast = await cache.loadForecast(for: zip, units: .imperial)
        let wrongUnits = await cache.loadForecast(for: zip, units: .metric)

        #expect(loadedLocation == CachedLocation(zip: zip.rawValue, location: location))
        #expect(loadedForecast == forecast)
        #expect(wrongUnits == nil)
        #expect(cache.locationURL(for: zip).lastPathComponent == "02108-location-v1.json")
        #expect(
            cache.forecastURL(for: zip, units: .imperial).lastPathComponent
                == "02108-imperial-forecast-v1.json"
        )
    }

    @Test("Corrupt, future-schema, and mismatched-key entries are cache misses")
    func invalidFilesAreIgnored() async throws {
        let root = cacheTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let cache = WeatherOddsCache(rootDirectory: root)
        let zip = try USZipCode("02108")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = cache.locationURL(for: zip)

        try Data("not json".utf8).write(to: url)
        let corrupt = await cache.loadLocation(for: zip)
        #expect(corrupt == nil)

        let future = CachedLocation(
            schemaVersion: CachedLocation.currentSchemaVersion + 1,
            zip: zip.rawValue,
            location: cacheTestLocation()
        )
        try JSONEncoder().encode(future).write(to: url)
        let unknownSchema = await cache.loadLocation(for: zip)
        #expect(unknownSchema == nil)

        let mismatch = CachedLocation(
            zip: "10001",
            location: Location(
                zip: "10001",
                displayName: "New York, NY",
                latitude: 40.75,
                longitude: -73.99
            )
        )
        try JSONEncoder().encode(mismatch).write(to: url)
        let wrongKey = await cache.loadLocation(for: zip)
        #expect(wrongKey == nil)
    }

    @Test("Rejected writes preserve the existing last-good entry")
    func rejectedWritePreservesCache() async throws {
        let root = cacheTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let cache = WeatherOddsCache(rootDirectory: root)
        let zip = try USZipCode("02108")
        let location = cacheTestLocation()
        try await cache.saveLocation(location, for: zip)

        do {
            try await cache.saveLocation(
                Location(
                    zip: "10001",
                    displayName: "New York, NY",
                    latitude: 40.75,
                    longitude: -73.99
                ),
                for: zip
            )
            Issue.record("Expected a key mismatch")
        } catch {
            #expect(error as? CacheError == .keyMismatch)
        }

        let stillCached = await cache.loadLocation(for: zip)
        #expect(stillCached?.location == location)
    }

    @Test("Fallbacks require both freshness and a current-or-future day")
    func fallbackUsability() throws {
        let zip = try USZipCode("02108")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let fresh = cacheTestForecast(
            zip: zip,
            location: cacheTestLocation(),
            fetchedAt: now.addingTimeInterval(-47 * 60 * 60),
            day: "2027-01-16"
        )
        let expired = cacheTestForecast(
            zip: zip,
            location: cacheTestLocation(),
            fetchedAt: now.addingTimeInterval(-48 * 60 * 60),
            day: "2027-01-16"
        )
        let onlyPastDays = cacheTestForecast(
            zip: zip,
            location: cacheTestLocation(),
            fetchedAt: now,
            day: "2027-01-14"
        )

        #expect(fresh.isUsableFallback(at: now, currentLocalDate: "2027-01-15"))
        #expect(!expired.isUsableFallback(at: now, currentLocalDate: "2027-01-15"))
        #expect(!onlyPastDays.isUsableFallback(at: now, currentLocalDate: "2027-01-15"))
    }

    @Test("Local date falls back to the fixed UTC offset")
    func localDateFallback() throws {
        let zip = try USZipCode("02108")
        let forecast = CachedForecast(
            zip: zip,
            units: .imperial,
            location: cacheTestLocation(),
            timeZoneIdentifier: "not/a-timezone",
            utcOffsetSeconds: -3_600,
            fetchedAt: Date(timeIntervalSince1970: 0),
            summaries: [cacheTestSummary(date: "1969-12-31")],
            ecmwfContributed: false
        )

        #expect(forecast.currentLocalDate(at: Date(timeIntervalSince1970: 0)) == "1969-12-31")
    }
}

private func cacheTestRoot() -> URL {
    FileManager.default.temporaryDirectory
        .appending(path: "WeatherOddsCacheTests-\(UUID().uuidString)", directoryHint: .isDirectory)
}

private func cacheTestLocation() -> Location {
    Location(
        zip: "02108",
        displayName: "Boston, MA",
        latitude: 42.357,
        longitude: -71.063,
        timeZoneIdentifier: "America/New_York",
        utcOffsetSeconds: -18_000
    )
}

private func cacheTestForecast(
    zip: USZipCode,
    location: Location,
    fetchedAt: Date = Date(timeIntervalSince1970: 1_800_000_000),
    day: String = "2027-01-15"
) -> CachedForecast {
    CachedForecast(
        zip: zip,
        units: .imperial,
        location: location,
        timeZoneIdentifier: "America/New_York",
        utcOffsetSeconds: -18_000,
        fetchedAt: fetchedAt,
        summaries: [cacheTestSummary(date: day)],
        ecmwfContributed: true
    )
}

private func cacheTestSummary(date: String) -> DaySummary {
    DaySummary(
        date: date,
        highMedian: 50,
        highP10: 45,
        highP90: 55,
        lowMedian: 35,
        lowP10: 30,
        lowP90: 40,
        spread: 10,
        rainProbability: 0.25,
        membersWet: 1,
        membersTotal: 4,
        amountMedian: 0.1,
        amountP90: 0.25,
        windMedianMax: 12,
        gustsP90: nil,
        cloudCover: 45,
        steps: 24,
        partial: false,
        rating: "Medium",
        points: 2
    )
}
