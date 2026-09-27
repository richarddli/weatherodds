import Foundation
import Testing
@testable import WeatherOddsCore

private let brnoJSON = #"{"id":3078610,"name":"Brno","latitude":49.19522,"longitude":16.60796,"country_code":"CZ","country":"Czechia","admin1":"South Moravian","timezone":"Europe/Prague","feature_code":"PPLA"}"#

@Suite("International widget locations")
struct LocationSearchTests {
    @Test("Selected city takes precedence; legacy ZIP widgets keep their identity")
    func configurationMigration() throws {
        let brno = try LocationID("geonames:3078610")
        #expect(try LocationID.configured(selected: brno, legacyZip: "invalid") == brno)
        #expect(try LocationID.configured(selected: nil, legacyZip: " 02108 ")?.rawValue == "02108")
        #expect(try LocationID.configured(selected: nil, legacyZip: " ") == nil)
        #expect(throws: GeocodeError.invalidPostalCode) {
            try LocationID.configured(selected: nil, legacyZip: "Brno")
        }
    }

    @Test("Identifiers cannot escape cache paths", arguments: [
        "../02108", "geonames:../1", "geonames:0", "geonames:-1", "geonames:01", "Brno", "",
    ])
    func invalidIDs(value: String) {
        #expect(throws: GeocodeError.invalidLocation) { try LocationID(value) }
        #expect(throws: GeocodeError.invalidLocation) {
            try JSONDecoder().decode(LocationID.self, from: JSONEncoder().encode(value))
        }
    }

    @Test("Czech Republic alias selects the city ahead of a mountain and prefixes")
    func citySearch() async throws {
        let mountain = brnoJSON.replacingOccurrences(of: "3078610", with: "3078611")
            .replacingOccurrences(of: "PPLA", with: "MT")
        let suburb = brnoJSON.replacingOccurrences(of: "3078610", with: "6694367")
            .replacingOccurrences(of: #""name":"Brno""#, with: #""name":"Brno-střed""#)
        let loader = LocationTestLoader(body: "{\"results\":[\(brnoJSON),\(mountain),\(suburb)]}")
        let places = try await InternationalGeocoder(loader: loader).search("Brno, Czech Republic")
        #expect(places.count == 1)
        #expect(places.first?.id.rawValue == "geonames:3078610")
        #expect(places.first?.displayName == "Brno, South Moravian, Czechia")
        #expect(places.first?.timeZoneIdentifier == "Europe/Prague")
        let request = try #require(await loader.requests.first)
        let params = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
        #expect(params?.first { $0.name == "name" }?.value == "Brno, Czechia")
    }

    @Test("Multiple matching cities remain separate picker choices")
    func ambiguity() async throws {
        let other = brnoJSON.replacingOccurrences(of: "3078610", with: "123")
        let loader = LocationTestLoader(body: "{\"results\":[\(brnoJSON),\(other)]}")
        #expect(try await InternationalGeocoder(loader: loader).search("Brno").count == 2)
    }

    @Test("Searches and restored entity IDs reuse durable coordinates")
    func durableSearch() async throws {
        let root = testRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let loader = LocationTestLoader(body: "{\"results\":[\(brnoJSON)]}")
        let geocoder = InternationalGeocoder(loader: loader)
        let search = LocationSearch(cache: WeatherOddsCache(rootDirectory: root), geocoder: geocoder)
        let place = try #require(try await search.search("Brno").first)
        let newCache = WeatherOddsCache(rootDirectory: root)
        let restored = LocationSearch(cache: newCache, geocoder: geocoder)
        #expect(try await restored.search("Brno") == [place])
        #expect(try await restored.location(for: place.id) == place)
        #expect(await newCache.suggestedLocations() == [place])
        #expect(await loader.requests.count == 1)
        #expect(await newCache.loadLocation(for: try LocationID("02108")) == nil)
    }

    @Test("A lost location cache can restore the selected GeoNames ID")
    func restoreID() async throws {
        let loader = LocationTestLoader(body: brnoJSON)
        let id = try LocationID("geonames:3078610")
        #expect(try await InternationalGeocoder(loader: loader).location(for: id).id == id)
        let request = try #require(await loader.requests.first)
        #expect(request.url?.path == "/v1/get")
        #expect(request.url?.query?.contains("id=3078610") == true)
        await #expect(throws: GeocodeError.noMatchingResult) {
            try await InternationalGeocoder(loader: loader).location(for: LocationID("geonames:123"))
        }
    }

    @Test("Malformed locations cannot become cached coordinates")
    func invalidResponse() async throws {
        let loader = LocationTestLoader(body: brnoJSON.replacingOccurrences(of: "49.19522", with: "149"))
        await #expect(throws: GeocodeError.temporaryFailure) {
            try await InternationalGeocoder(loader: loader).location(for: LocationID("geonames:3078610"))
        }
    }

    @Test("Legacy v1 ZIP location files decode and retain the same filename")
    func legacyLocationCache() async throws {
        let root = testRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let json = #"{"schemaVersion":1,"zip":"02108","location":{"zip":"02108","displayName":"Boston, MA","latitude":42.357,"longitude":-71.063,"timeZoneIdentifier":"America/New_York","utcOffsetSeconds":-18000}}"#
        try Data(json.utf8).write(to: root.appending(path: "02108-location-v1.json"))
        let cache = WeatherOddsCache(rootDirectory: root)
        let id = try LocationID("02108")
        let saved = try #require(await cache.loadLocation(for: id))
        #expect(saved.location.id == id)
        #expect(saved.location.countryCode == "US")
        #expect(saved.location.postalCode == "02108")
        #expect(cache.locationURL(for: id).lastPathComponent == "02108-location-v1.json")
    }

    @Test("Picker timeouts recover in seconds and success resets their backoff")
    func shortTransientCooldown() async throws {
        let root = testRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = WeatherOddsCache(rootDirectory: root)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        await cache.recordGeocodingFailure(GeocodeError.temporaryFailure, at: now)
        let blocked = await #expect(throws: ForecastUnavailable.self) {
            try await cache.checkGeocodingCooldown(at: now.addingTimeInterval(1))
        }
        #expect(blocked?.nextAttempt == now.addingTimeInterval(2))
        #expect(blocked?.localizedDescription.contains("Location search") == true)
        try await cache.checkGeocodingCooldown(at: now.addingTimeInterval(2))
        await cache.recordGeocodingFailure(GeocodeError.temporaryFailure, at: now.addingTimeInterval(2))
        #expect(await cache.retryState(forKey: "geocoding")?.nextAttemptAfter == now.addingTimeInterval(6))
        // Interactive lookup failures never suppress already-resolved forecasts.
        #expect(await cache.nextEligibleAttempt(for: try LocationID("02108"), units: .imperial, at: now) == nil)
        await cache.recordGeocodingSuccess()
        try await cache.checkGeocodingCooldown(at: now.addingTimeInterval(3))
    }

    @Test("Search Retry-After takes precedence over short transient backoff")
    func searchRetryAfter() async throws {
        let root = testRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = WeatherOddsCache(rootDirectory: root)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        await cache.recordGeocodingFailure(FetchError.httpFailure(
            model: "Location search", failure: UpstreamHTTPFailure(statusCode: 503, retryAfterHeader: "600")
        ), at: now)
        let blocked = await #expect(throws: ForecastUnavailable.self) {
            try await cache.checkGeocodingCooldown(at: now)
        }
        #expect(blocked?.nextAttempt == now.addingTimeInterval(600))
    }

    @Test("Geocoding 429 suppresses searches and forecasts across restarts")
    func sharedCooldown() async throws {
        let root = testRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let loader = LocationTestLoader(body: "{}", status: 429)
        let cache = WeatherOddsCache(rootDirectory: root)
        let search = LocationSearch(cache: cache, geocoder: InternationalGeocoder(loader: loader))
        await #expect(throws: FetchError.self) { try await search.search("Brno") }
        let restarted = WeatherOddsCache(rootDirectory: root)
        let second = LocationSearch(cache: restarted, geocoder: InternationalGeocoder(loader: loader))
        await #expect(throws: ForecastUnavailable.self) { try await second.search("Paris") }
        #expect(await restarted.nextEligibleAttempt(
            for: try LocationID("02108"), units: .imperial, at: .now
        ) != nil)
        #expect(await loader.requests.count == 1)
    }
}

private func testRoot() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "WeatherOddsLocationTests-\(UUID())")
}

private actor LocationTestLoader: ForecastDataLoading {
    let body: String
    let status: Int
    private(set) var requests: [URLRequest] = []

    init(body: String, status: Int = 200) { self.body = body; self.status = status }

    func data(forForecastRequest request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        return (Data(body.utf8), HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil,
            headerFields: ["Retry-After": "600"]
        )!)
    }
}
