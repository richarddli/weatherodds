import Foundation
import Testing
@testable import WeatherOddsCore

@Suite("Durable forecast cache")
struct DurableCacheTests {
    @Test("Repeated reloads and new cache instances reuse a forecast until its original deadline")
    func freshForecastSkipsRefresh() async throws {
        let root = cacheTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let zip = try USZipCode("02108")
        let fetchedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let saved = cacheTestForecast(zip: zip, location: cacheTestLocation(), fetchedAt: fetchedAt)
        try await WeatherOddsCache(rootDirectory: root).saveForecast(saved, for: zip, units: .imperial)

        for age: TimeInterval in [0, 60, 5 * 60 * 60, 6 * 60 * 60 - 1] {
            let cache = WeatherOddsCache(rootDirectory: root)
            let result = try await cache.loadOrRefreshForecast(
                for: zip, units: .imperial, at: fetchedAt.addingTimeInterval(age)
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
        let zip = try USZipCode("02108")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let cache = WeatherOddsCache(rootDirectory: root)
        let refreshed = cacheTestForecast(zip: zip, location: cacheTestLocation(), fetchedAt: now)
        let calls = RefreshCallCounter()

        for (age, day): (TimeInterval, String) in [
            (6 * 60 * 60, "2027-01-15"),
            (-60, "2027-01-15"),
            (60, "2027-01-14"),
        ] {
            let saved = cacheTestForecast(
                zip: zip, location: cacheTestLocation(),
                fetchedAt: now.addingTimeInterval(-age), day: day
            )
            try await cache.saveForecast(saved, for: zip, units: .imperial)
            let result = try await cache.loadOrRefreshForecast(for: zip, units: .imperial, at: now) {
                await calls.increment()
                return refreshed
            }
            #expect(result == refreshed)
            #expect(await cache.loadForecast(for: zip, units: .imperial) == refreshed)
        }
        #expect(await calls.value == 3)
    }

    @Test("Changing ZIP or units fetches the matching configuration; switching back reuses it")
    func configurationChanges() async throws {
        let root = cacheTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = WeatherOddsCache(rootDirectory: root)
        let calls = RefreshCallCounter()
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        for (rawZip, units): (String, Units) in [
            ("02108", .imperial), ("10001", .imperial), ("10001", .metric), ("02108", .imperial),
        ] {
            let zip = try USZipCode(rawZip)
            let forecast = cacheTestForecast(
                zip: zip,
                location: Location(zip: rawZip, displayName: rawZip, latitude: 40, longitude: -74),
                fetchedAt: now, units: units
            )
            let result = try await cache.loadOrRefreshForecast(for: zip, units: units, at: now) {
                await calls.increment()
                return forecast
            }
            #expect(result.zip == rawZip)
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
        let zip = try USZipCode("02108")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let forecast = cacheTestForecast(zip: zip, location: cacheTestLocation(), fetchedAt: now)

        try await withThrowingTaskGroup(of: CachedForecast.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    try await cache.loadOrRefreshForecast(for: zip, units: .imperial, at: now) {
                        await calls.increment()
                        try await Task.sleep(for: .milliseconds(50))
                        return forecast
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
        let cache = WeatherOddsCache(rootDirectory: root)
        let zip = try USZipCode("02108")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let stale = cacheTestForecast(
            zip: zip, location: cacheTestLocation(), fetchedAt: now.addingTimeInterval(-7 * 60 * 60)
        )
        try await cache.saveForecast(stale, for: zip, units: .imperial)
        await #expect(throws: RefreshTestError.unexpectedRequest) {
            try await cache.loadOrRefreshForecast(for: zip, units: .imperial, at: now) {
                throw RefreshTestError.unexpectedRequest
            }
        }
        #expect(await cache.loadForecast(for: zip, units: .imperial) == stale)
        let refreshed = cacheTestForecast(zip: zip, location: cacheTestLocation(), fetchedAt: now)
        let result = try await cache.loadOrRefreshForecast(for: zip, units: .imperial, at: now) {
            refreshed
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
        let zip = try USZipCode("02108")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let forecast = cacheTestForecast(zip: zip, location: cacheTestLocation(), fetchedAt: now)

        let first = Task {
            try await cache.loadOrRefreshForecast(for: zip, units: .imperial, at: now) {
                await calls.increment()
                await gate.wait()
                try Task.checkCancellation()
                return forecast
            }
        }
        await gate.waitUntilStarted()
        first.cancel()
        let second = Task {
            try await cache.loadOrRefreshForecast(for: zip, units: .imperial, at: now) {
                await calls.increment()
                return forecast
            }
        }
        await gate.release()

        await #expect(throws: CancellationError.self) { try await first.value }
        #expect(try await second.value == forecast)
        #expect(await calls.value == 1)
        #expect(await cache.loadForecast(for: zip, units: .imperial) == forecast)
    }

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
    day: String = "2027-01-15",
    units: Units = .imperial
) -> CachedForecast {
    CachedForecast(
        zip: zip,
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
