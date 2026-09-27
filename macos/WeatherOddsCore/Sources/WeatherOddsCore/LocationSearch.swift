import Foundation

/// International search uses the same GeoNames identities as the Python CLI.
public struct InternationalGeocoder: Sendable {
    private let loader: any ForecastDataLoading

    public init(loader: any ForecastDataLoading = URLSession(
        configuration: EnsembleClient.defaultSessionConfiguration()
    )) {
        self.loader = loader
    }

    public func search(_ query: String) async throws -> [Location] {
        let query = Self.normalizedQuery(query)
        guard query.count >= 2 else { return [] }
        let data = try await request(path: "search", parameters: [
            URLQueryItem(name: "name", value: query),
            URLQueryItem(name: "count", value: "100"),
        ])
        let response: SearchResponse
        do { response = try JSONDecoder().decode(SearchResponse.self, from: data) }
        catch { throw GeocodeError.temporaryFailure }
        guard response.error != true else { throw GeocodeError.temporaryFailure }
        var records = response.results ?? []
        let name = query.components(separatedBy: ",")[0].trimmingCharacters(in: .whitespaces)
        let exact = records.filter {
            $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
        if !exact.isEmpty { records = exact }
        let populated = records.filter { $0.feature_code?.hasPrefix("PPL") == true }
        if !populated.isEmpty { records = populated }
        var seen = Set<Int>()
        return try records.filter { seen.insert($0.id).inserted }.map { try $0.location() }
    }

    public func location(for id: LocationID) async throws -> Location {
        guard let number = id.geonamesID else { throw GeocodeError.invalidLocation }
        let data = try await request(path: "get", parameters: [
            URLQueryItem(name: "id", value: String(number)),
        ])
        let record: PlaceRecord
        do { record = try JSONDecoder().decode(PlaceRecord.self, from: data) }
        catch { throw GeocodeError.temporaryFailure }
        guard record.id == number else { throw GeocodeError.noMatchingResult }
        return try record.location()
    }

    static func normalizedQuery(_ query: String) -> String {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = query.split(separator: ",", maxSplits: 1).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        if parts.count == 2, parts[1].lowercased() == "czech republic" {
            return "\(parts[0]), Czechia"
        }
        return query
    }

    private func request(path: String, parameters: [URLQueryItem]) async throws -> Data {
        var components = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/\(path)")!
        components.queryItems = parameters + [
            URLQueryItem(name: "language", value: "en"),
            URLQueryItem(name: "format", value: "json"),
        ]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = EnsembleClient.requestTimeout
        request.setValue("WeatherOdds/0.1", forHTTPHeaderField: "User-Agent")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await loader.data(forForecastRequest: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw GeocodeError.temporaryFailure
        }
        guard let response = response as? HTTPURLResponse else {
            throw GeocodeError.temporaryFailure
        }
        if response.statusCode == 404 { throw GeocodeError.noMatchingResult }
        guard response.statusCode == 200 else {
            throw FetchError.httpFailure(model: "Location search", failure: UpstreamHTTPFailure(
                statusCode: response.statusCode,
                retryAfterHeader: response.value(forHTTPHeaderField: "Retry-After")
            ))
        }
        return data
    }
}

private struct SearchResponse: Decodable {
    let error: Bool?
    let results: [PlaceRecord]?
}

private struct PlaceRecord: Decodable {
    let id: Int
    let name: String
    let latitude: Double
    let longitude: Double
    let country_code: String
    let country: String?
    let admin1: String?
    let timezone: String?
    let feature_code: String?

    func location() throws -> Location {
        guard id > 0, latitude.isFinite, longitude.isFinite,
              (-90...90).contains(latitude), (-180...180).contains(longitude),
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              country_code.count == 2,
              country_code.utf8.allSatisfy({ $0 >= 65 && $0 <= 90 })
        else { throw GeocodeError.temporaryFailure }
        var parts = [name]
        for part in [admin1, country ?? country_code].compactMap({ $0 }) {
            if !part.isEmpty, !parts.contains(part) { parts.append(part) }
        }
        return Location(
            id: try LocationID("geonames:\(id)"), displayName: parts.joined(separator: ", "),
            latitude: latitude, longitude: longitude, countryCode: country_code,
            timeZoneIdentifier: timezone
        )
    }
}

/// Search and entity restoration share durable coordinates and the forecast cooldown.
public actor LocationSearch {
    private let cache: WeatherOddsCache
    private let geocoder: InternationalGeocoder

    public init(cache: WeatherOddsCache, geocoder: InternationalGeocoder = InternationalGeocoder()) {
        self.cache = cache
        self.geocoder = geocoder
    }

    public func search(_ query: String) async throws -> [Location] {
        let query = InternationalGeocoder.normalizedQuery(query)
        if let zip = try? USZipCode(query) {
            return [try await location(for: LocationID(zip.rawValue))]
        }
        guard query.count >= 2 else { return [] }
        if let saved = await cache.loadSearch(query: query, at: .now) { return saved }
        try await cache.checkGeocodingCooldown(at: .now)
        do {
            let places = try await geocoder.search(query)
            for place in places { try? await cache.saveLocation(place, for: place.id) }
            try? await cache.saveSearch(places, query: query, at: .now)
            await cache.recordGeocodingSuccess()
            return places
        } catch {
            await cache.recordGeocodingFailure(error, at: .now)
            throw error
        }
    }

    public func location(for id: LocationID) async throws -> Location {
        if let saved = await cache.loadLocation(for: id) { return saved.location }
        // Entity restoration also works if the standalone location file was lost.
        for units in [Units.imperial, .metric] {
            if let saved = await cache.loadForecast(for: id, units: units) {
                try? await cache.saveLocation(saved.location, for: id)
                return saved.location
            }
        }
        let place: Location
        if id.geonamesID == nil {
            place = try await USZipCodeGeocoder().location(for: id.rawValue)
        } else {
            try await cache.checkGeocodingCooldown(at: .now)
            do {
                place = try await geocoder.location(for: id)
                await cache.recordGeocodingSuccess()
            }
            catch {
                await cache.recordGeocodingFailure(error, at: .now)
                throw error
            }
        }
        try? await cache.saveLocation(place, for: id)
        return place
    }
}
