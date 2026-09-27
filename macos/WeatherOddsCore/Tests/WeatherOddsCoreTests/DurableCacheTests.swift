import Foundation
import Testing
@testable import WeatherOddsCore

@Suite("Durable forecast cache")
struct DurableCacheTests {
    @Test("Repeated reloads and new cache instances reuse a forecast until its original deadline")
    func freshForecastSkipsRefresh() async throws {
        let root = cacheTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let locationID = try LocationID("02108")
        let fetchedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let saved = cacheTestForecast(locationID: locationID, location: cacheTestLocation(), fetchedAt: fetchedAt)
        try await WeatherOddsCache(rootDirectory: root).saveForecast(saved, for: locationID, units: .imperial)

        for age: TimeInterval in [0, 60, 5 * 60 * 60, 6 * 60 * 60 - 1] {
            let cache = WeatherOddsCache(rootDirectory: root)
            let result = try await cache.loadOrRefreshForecast(
                for: locationID, units: .imperial, at: fetchedAt.addingTimeInterval(age)
            ) {
                throw RefreshTestError.unexpectedRequest
            }
            #expect(result == saved)
            #expect(result.nextRefreshDate == fetchedAt.addingTimeInterval(6 * 60 * 60))
        }
    }

    @Test("Expired, future-dated, and past-days-only forecasts trigger a refresh")
    func unusableForecastsRefresh() async throws {
        let root = cacheTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let locationID = try LocationID("02108")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let cache = WeatherOddsCache(rootDirectory: root)
        let refreshed = cacheTestForecast(locationID: locationID, location: cacheTestLocation(), fetchedAt: now)
        let calls = RefreshCallCounter()

        for (age, day): (TimeInterval, String) in [
            (6 * 60 * 60, "2027-01-15"),
            (-60, "2027-01-15"),
            (60, "2027-01-14"),
        ] {
            let saved = cacheTestForecast(
                locationID: locationID, location: cacheTestLocation(),
                fetchedAt: now.addingTimeInterval(-age), day: day
            )
            try await cache.saveForecast(saved, for: locationID, units: .imperial)
            let result = try await cache.loadOrRefreshForecast(for: locationID, units: .imperial, at: now) {
                await calls.increment()
                return ForecastRefreshResult(refreshed)
            }
            #expect(result == refreshed)
            #expect(await cache.loadForecast(for: locationID, units: .imperial) == refreshed)
        }
        #expect(await calls.value == 3)
    }

    @Test("Changing location or units fetches the matching configuration; switching back reuses it")
    func configurationChanges() async throws {
        let root = cacheTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = WeatherOddsCache(rootDirectory: root)
        let calls = RefreshCallCounter()
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        for (rawZip, units): (String, Units) in [
            ("02108", .imperial), ("geonames:3078610", .imperial), ("geonames:3078610", .metric), ("02108", .imperial),
        ] {
            let locationID = try LocationID(rawZip)
            let forecast = cacheTestForecast(
                locationID: locationID,
                location: Location(id: locationID, displayName: rawZip, latitude: 40, longitude: -74),
                fetchedAt: now, units: units
            )
            let result = try await cache.loadOrRefreshForecast(for: locationID, units: units, at: now) {
                await calls.increment()
                return ForecastRefreshResult(forecast)
            }
            #expect(result.locationID == rawZip)
            #expect(result.unitName == units.name)
        }
        #expect(await calls.value == 3)
    }

    @Test("Concurrent widgets share one refresh")
    func concurrentRefreshes() async throws {
        let root = cacheTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = WeatherOddsCache(rootDirectory: root)
        let calls = RefreshCallCounter()
        let locationID = try LocationID("02108")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let forecast = cacheTestForecast(locationID: locationID, location: cacheTestLocation(), fetchedAt: now)

        try await withThrowingTaskGroup(of: CachedForecast.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    try await cache.loadOrRefreshForecast(for: locationID, units: .imperial, at: now) {
                        await calls.increment()
                        try await Task.sleep(for: .milliseconds(50))
                        return ForecastRefreshResult(forecast)
                    }
                }
            }
            for try await result in group { #expect(result == forecast) }
        }
        #expect(await calls.value == 1)
    }

    @Test("A failed refresh preserves stale data and permits a later retry")
    func failureDoesNotPoisonCache() async throws {
        let root = cacheTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = WeatherOddsCache(rootDirectory: root, retryPolicy: RetryPolicy(jitter: { 0 }))
        let locationID = try LocationID("02108")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let stale = cacheTestForecast(
            locationID: locationID, location: cacheTestLocation(), fetchedAt: now.addingTimeInterval(-7 * 60 * 60)
        )
        try await cache.saveForecast(stale, for: locationID, units: .imperial)

        let failure = await #expect(throws: ForecastUnavailable.self) {
            try await cache.loadOrRefreshForecast(for: locationID, units: .imperial, at: now) {
                throw RefreshTestError.unexpectedRequest
            }
        }
        #expect(failure?.reason == .transient)
        #expect(failure?.nextAttempt == now.addingTimeInterval(RetryPolicy.baseDelay))
        #expect(await cache.loadForecast(for: locationID, units: .imperial) == stale)

        let retryAt = try #require(failure?.nextAttempt)
        let refreshed = cacheTestForecast(
            locationID: locationID, location: cacheTestLocation(), fetchedAt: retryAt
        )
        let result = try await cache.loadOrRefreshForecast(
            for: locationID, units: .imperial, at: retryAt
        ) {
            ForecastRefreshResult(refreshed)
        }
        #expect(result == refreshed)
    }

    @Test("Cancelling one widget leaves the shared refresh usable by another")
    func cancelledWaiterDoesNotCancelRefresh() async throws {
        let root = cacheTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = WeatherOddsCache(rootDirectory: root)
        let calls = RefreshCallCounter()
        let gate = RefreshTestGate()
        let locationID = try LocationID("02108")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let forecast = cacheTestForecast(locationID: locationID, location: cacheTestLocation(), fetchedAt: now)

        let first = Task {
            try await cache.loadOrRefreshForecast(for: locationID, units: .imperial, at: now) {
                await calls.increment()
                await gate.wait()
                try Task.checkCancellation()
                return ForecastRefreshResult(forecast)
            }
        }
        await gate.waitUntilStarted()
        first.cancel()
        let second = Task {
            try await cache.loadOrRefreshForecast(for: locationID, units: .imperial, at: now) {
                await calls.increment()
                return ForecastRefreshResult(forecast)
            }
        }
        await gate.release()

        await #expect(throws: CancellationError.self) { try await first.value }
        #expect(try await second.value == forecast)
        #expect(await calls.value == 1)
        #expect(await cache.loadForecast(for: locationID, units: .imperial) == forecast)
    }

    @Test("Location and forecast entries round-trip under configuration keys")
    func roundTripAndKeySeparation() async throws {
        let root = cacheTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let cache = WeatherOddsCache(rootDirectory: root)
        let locationID = try LocationID("02108")
        let location = cacheTestLocation()
        let forecast = cacheTestForecast(locationID: locationID, location: location)

        try await cache.saveLocation(location, for: locationID)
        try await cache.saveForecast(forecast, for: locationID, units: .imperial)

        let loadedLocation = await cache.loadLocation(for: locationID)
        let loadedForecast = await cache.loadForecast(for: locationID, units: .imperial)
        let wrongUnits = await cache.loadForecast(for: locationID, units: .metric)

        #expect(loadedLocation == CachedLocation(locationID: locationID.rawValue, location: location))
        #expect(loadedForecast == forecast)
        #expect(wrongUnits == nil)
        #expect(cache.locationURL(for: locationID).lastPathComponent == "02108-location-v1.json")
        #expect(
            cache.forecastURL(for: locationID, units: .imperial).lastPathComponent
                == "02108-imperial-forecast-v1.json"
        )
    }

    @Test("Corrupt, future-schema, and mismatched-key entries are cache misses")
    func invalidFilesAreIgnored() async throws {
        let root = cacheTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let cache = WeatherOddsCache(rootDirectory: root)
        let locationID = try LocationID("02108")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = cache.locationURL(for: locationID)

        try Data("not json".utf8).write(to: url)
        let corrupt = await cache.loadLocation(for: locationID)
        #expect(corrupt == nil)

        let future = CachedLocation(
            schemaVersion: CachedLocation.currentSchemaVersion + 1,
            locationID: locationID.rawValue,
            location: cacheTestLocation()
        )
        try JSONEncoder().encode(future).write(to: url)
        let unknownSchema = await cache.loadLocation(for: locationID)
        #expect(unknownSchema == nil)

        let mismatch = CachedLocation(
            locationID: "10001",
            location: Location(
                zip: "10001",
                displayName: "New York, NY",
                latitude: 40.75,
                longitude: -73.99
            )
        )
        try JSONEncoder().encode(mismatch).write(to: url)
        let wrongKey = await cache.loadLocation(for: locationID)
        #expect(wrongKey == nil)
    }

    @Test("Rejected writes preserve the existing last-good entry")
    func rejectedWritePreservesCache() async throws {
        let root = cacheTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let cache = WeatherOddsCache(rootDirectory: root)
        let locationID = try LocationID("02108")
        let location = cacheTestLocation()
        try await cache.saveLocation(location, for: locationID)

        do {
            try await cache.saveLocation(
                Location(
                    zip: "10001",
                    displayName: "New York, NY",
                    latitude: 40.75,
                    longitude: -73.99
                ),
                for: locationID
            )
            Issue.record("Expected a key mismatch")
        } catch {
            #expect(error as? CacheError == .keyMismatch)
        }

        let stillCached = await cache.loadLocation(for: locationID)
        #expect(stillCached?.location == location)
    }

    @Test("Fallbacks require both freshness and a current-or-future day")
    func fallbackUsability() throws {
        let locationID = try LocationID("02108")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let fresh = cacheTestForecast(
            locationID: locationID,
            location: cacheTestLocation(),
            fetchedAt: now.addingTimeInterval(-47 * 60 * 60),
            day: "2027-01-16"
        )
        let expired = cacheTestForecast(
            locationID: locationID,
            location: cacheTestLocation(),
            fetchedAt: now.addingTimeInterval(-48 * 60 * 60),
            day: "2027-01-16"
        )
        let onlyPastDays = cacheTestForecast(
            locationID: locationID,
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
        let locationID = try LocationID("02108")
        let forecast = CachedForecast(
            locationID: locationID,
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
    @Test("Legacy forecast files survive migration and can restore a missing location file")
    func legacyForecastMigration() async throws {
        let root = cacheTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = WeatherOddsCache(rootDirectory: root)
        let id = try LocationID("02108")
        let forecast = cacheTestForecast(locationID: id, location: cacheTestLocation())
        try await cache.saveForecast(forecast, for: id, units: .imperial)
        let url = cache.forecastURL(for: id, units: .imperial)
        var document = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(document["zip"] as? String == "02108")
        var location = try #require(document["location"] as? [String: Any])
        location.removeValue(forKey: "id")
        location.removeValue(forKey: "countryCode")
        location.removeValue(forKey: "postalCode")
        location["zip"] = "02108"
        document["location"] = location
        try JSONSerialization.data(withJSONObject: document).write(to: url)
        let restored = WeatherOddsCache(rootDirectory: root)
        #expect(await restored.loadForecast(for: id, units: .imperial) == forecast)
        // No standalone geocode file exists; restoration must use the forecast.
        let search = LocationSearch(cache: restored)
        #expect(try await search.location(for: id) == forecast.location)
        #expect(await restored.loadLocation(for: id)?.location == forecast.location)
    }

    @Test("Prague day boundaries follow DST even when the cached offset is stale")
    func pragueDST() throws {
        let id = try LocationID("geonames:3078610")
        let place = Location(id: id, displayName: "Brno, Czechia", latitude: 49.19522, longitude: 16.60796)
        let forecast = CachedForecast(
            locationID: id, units: .metric, location: place,
            timeZoneIdentifier: "Europe/Prague", utcOffsetSeconds: 3600,
            fetchedAt: .now, summaries: [], ecmwfContributed: true
        )
        let formatter = ISO8601DateFormatter()
        #expect(forecast.currentLocalDate(at: try #require(formatter.date(from: "2026-03-29T22:30:00Z"))) == "2026-03-30")
        #expect(forecast.currentLocalDate(at: try #require(formatter.date(from: "2026-10-25T22:30:00Z"))) == "2026-10-25")
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
    locationID: LocationID,
    location: Location,
    fetchedAt: Date = Date(timeIntervalSince1970: 1_800_000_000),
    day: String = "2027-01-15",
    units: Units = .imperial
) -> CachedForecast {
    CachedForecast(
        locationID: locationID,
        units: units,
        location: location,
        timeZoneIdentifier: "America/New_York",
        utcOffsetSeconds: -18_000,
        fetchedAt: fetchedAt,
        summaries: [cacheTestSummary(date: day)],
        ecmwfContributed: true
    )
}

private enum RefreshTestError: Error { case unexpectedRequest }

private actor RefreshCallCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}

private actor RefreshTestGate {
    private var pending: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation {
            pending = $0
            observer?.resume()
            observer = nil
        }
    }

    func waitUntilStarted() async {
        if pending != nil { return }
        await withCheckedContinuation { observer = $0 }
    }

    func release() {
        pending?.resume()
        pending = nil
    }
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
