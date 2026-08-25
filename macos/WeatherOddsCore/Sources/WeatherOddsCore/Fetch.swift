import Foundation

/// Open-Meteo's ensemble endpoint. The ensemble models are not served by the
/// provider's general forecast host.
public let ensembleAPIURL = URL(
    string: "https://ensemble-api.open-meteo.com/v1/ensemble"
)!

public let weatherNextModel = "google_weathernext2_ensemble"
public let ecmwfModel = "ecmwf_ifs025_ensemble"

public let ensembleForecastDays = 15
public let ensembleHourlyVariables = [
    "temperature_2m",
    "precipitation",
    "wind_speed_10m",
    "wind_gusts_10m",
    "cloud_cover",
]

/// A decoded ensemble response. Model-run metadata is intentionally absent:
/// it is not displayed by the widget and would require a second request.
public struct Ensemble: Codable, Equatable, Sendable {
    public let model: String
    public let latitude: Double
    public let longitude: Double
    public let timezone: String
    public let utcOffsetSeconds: Int
    public let hourly: HourlyData

    public init(
        model: String,
        latitude: Double,
        longitude: Double,
        timezone: String,
        utcOffsetSeconds: Int,
        hourly: HourlyData
    ) {
        self.model = model
        self.latitude = latitude
        self.longitude = longitude
        self.timezone = timezone
        self.utcOffsetSeconds = utcOffsetSeconds
        self.hourly = hourly
    }
}

/// Compact result used by callers that should not retain the raw hourly body.
public struct SummarizedEnsemble: Codable, Equatable, Sendable {
    public let model: String
    public let latitude: Double
    public let longitude: Double
    public let timezone: String
    public let utcOffsetSeconds: Int
    public let summaries: [DaySummary]

    public init(
        model: String,
        latitude: Double,
        longitude: Double,
        timezone: String,
        utcOffsetSeconds: Int,
        summaries: [DaySummary]
    ) {
        self.model = model
        self.latitude = latitude
        self.longitude = longitude
        self.timezone = timezone
        self.utcOffsetSeconds = utcOffsetSeconds
        self.summaries = summaries
    }
}

public enum FetchError: Error, Equatable, Sendable {
    case unsupportedUnits(String)
    case invalidRequest
    case requestFailed(model: String, code: URLError.Code)
    case invalidResponse(model: String)
    case invalidPayload(model: String)
    case apiError(model: String, reason: String)
    case missingMetadata(model: String, field: String)
    case missingHourlyData(model: String)
    case missingRequiredVariable(model: String, variable: String)
    case invalidSeriesLength(
        model: String,
        variable: String,
        expected: Int,
        actual: Int
    )
    case unitMismatch(
        model: String,
        variable: String,
        expected: String,
        actual: String?
    )
}

extension FetchError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unsupportedUnits(let name):
            "Unsupported forecast units: \(name)."
        case .invalidRequest:
            "The forecast request could not be constructed."
        case .requestFailed(let model, let code):
            "\(model): request failed (\(code.rawValue))."
        case .invalidResponse(let model):
            "\(model): response was not HTTP."
        case .invalidPayload(let model):
            "\(model): response was not valid ensemble JSON."
        case .apiError(let model, let reason):
            "\(model): \(reason)"
        case .missingMetadata(let model, let field):
            "\(model): response omitted \(field)."
        case .missingHourlyData(let model):
            "\(model): response contained no hourly data."
        case .missingRequiredVariable(let model, let variable):
            "\(model): response omitted required hourly variable \(variable)."
        case .invalidSeriesLength(let model, let variable, let expected, let actual):
            "\(model): \(variable) contained \(actual) steps; expected \(expected)."
        case .unitMismatch(let model, let variable, let expected, let actual):
            "\(model): \(variable) unit was \(actual ?? "missing"); expected \(expected)."
        }
    }
}

/// Small transport seam that permits URLProtocol-configured URLSession values
/// in production-shaped tests without coupling the client to global state.
public protocol ForecastDataLoading: Sendable {
    func data(forForecastRequest request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: ForecastDataLoading {
    public func data(forForecastRequest request: URLRequest) async throws -> (Data, URLResponse) {
        try await data(for: request)
    }
}

public struct EnsembleClient: Sendable {
    public static let requestTimeout: TimeInterval = 6
    public static let resourceTimeout: TimeInterval = 8

    private let loader: any ForecastDataLoading
    private let baseURL: URL

    /// Creates a client backed by a supplied session, including sessions whose
    /// configurations install a custom URLProtocol. A short-lived ephemeral
    /// session with widget-appropriate timeouts is used by default.
    public init(
        session: URLSession? = nil,
        baseURL: URL = ensembleAPIURL
    ) {
        self.loader = session ?? URLSession(
            configuration: Self.defaultSessionConfiguration()
        )
        self.baseURL = baseURL
    }

    /// Creates a client with a custom async transport, useful for unit tests.
    public init(
        loader: any ForecastDataLoading,
        baseURL: URL = ensembleAPIURL
    ) {
        self.loader = loader
        self.baseURL = baseURL
    }

    public static func defaultSessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.waitsForConnectivity = false
        return configuration
    }

    public func request(
        model: String,
        latitude: Double,
        longitude: Double,
        units: Units
    ) throws -> URLRequest {
        let unitParameters = try Self.unitParameters(for: units)
        guard !model.isEmpty,
              latitude.isFinite,
              longitude.isFinite,
              var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        else {
            throw FetchError.invalidRequest
        }

        components.queryItems = [
            URLQueryItem(name: "latitude", value: Self.coordinate(latitude)),
            URLQueryItem(name: "longitude", value: Self.coordinate(longitude)),
            URLQueryItem(name: "models", value: model),
            URLQueryItem(name: "hourly", value: ensembleHourlyVariables.joined(separator: ",")),
            URLQueryItem(name: "forecast_days", value: String(ensembleForecastDays)),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "temperature_unit", value: unitParameters.temperature),
            URLQueryItem(name: "wind_speed_unit", value: unitParameters.wind),
            URLQueryItem(name: "precipitation_unit", value: unitParameters.precipitation),
        ]
        guard let url = components.url else { throw FetchError.invalidRequest }

        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: Self.requestTimeout
        )
        request.httpMethod = "GET"
        return request
    }

    /// Fetches one model with no inline retries and no metadata request.
    public func fetch(
        model: String,
        latitude: Double,
        longitude: Double,
        units: Units
    ) async throws -> Ensemble {
        let request = try request(
            model: model,
            latitude: latitude,
            longitude: longitude,
            units: units
        )

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await loader.data(forForecastRequest: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled && Task.isCancelled {
            throw CancellationError()
        } catch let error as URLError {
            throw FetchError.requestFailed(model: model, code: error.code)
        } catch {
            throw FetchError.requestFailed(model: model, code: .unknown)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw FetchError.invalidResponse(model: model)
        }

        let payload: EnsemblePayload
        do {
            payload = try JSONDecoder().decode(EnsemblePayload.self, from: data)
        } catch {
            throw FetchError.invalidPayload(model: model)
        }

        guard (200..<300).contains(httpResponse.statusCode), payload.error != true else {
            throw FetchError.apiError(
                model: model,
                reason: payload.reason ?? "HTTP \(httpResponse.statusCode)"
            )
        }

        guard let latitude = payload.latitude else {
            throw FetchError.missingMetadata(model: model, field: "latitude")
        }
        guard let longitude = payload.longitude else {
            throw FetchError.missingMetadata(model: model, field: "longitude")
        }
        guard let hourly = payload.hourly?.data, !hourly.times.isEmpty else {
            throw FetchError.missingHourlyData(model: model)
        }

        try Self.validate(hourly: hourly, model: model)
        if let hourlyUnits = payload.hourlyUnits {
            try Self.validate(
                hourlyUnits: hourlyUnits,
                hourly: hourly,
                requestedUnits: units,
                model: model
            )
        }

        return Ensemble(
            model: model,
            latitude: latitude,
            longitude: longitude,
            timezone: payload.timezone ?? "UTC",
            utcOffsetSeconds: payload.utcOffsetSeconds ?? 0,
            hourly: hourly
        )
    }

    /// Fetches and summarizes inside one async operation so callers can retain
    /// only compact day summaries after this function returns.
    public func fetchAndSummarize(
        model: String,
        latitude: Double,
        longitude: Double,
        units: Units,
        maxDays: Int? = nil
    ) async throws -> SummarizedEnsemble {
        let ensemble = try await fetch(
            model: model,
            latitude: latitude,
            longitude: longitude,
            units: units
        )
        let summaries = try summarize(ensemble.hourly, units: units, maxDays: maxDays)
        return SummarizedEnsemble(
            model: ensemble.model,
            latitude: ensemble.latitude,
            longitude: ensemble.longitude,
            timezone: ensemble.timezone,
            utcOffsetSeconds: ensemble.utcOffsetSeconds,
            summaries: summaries
        )
    }

    /// Best-effort variant used for optional secondary models. Cancellation
    /// still aborts the caller, while transport and API failures degrade to nil.
    public func fetchAndSummarizeIfAvailable(
        model: String,
        latitude: Double,
        longitude: Double,
        units: Units,
        maxDays: Int? = nil
    ) async throws -> SummarizedEnsemble? {
        do {
            return try await fetchAndSummarize(
                model: model,
                latitude: latitude,
                longitude: longitude,
                units: units,
                maxDays: maxDays
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return nil
        }
    }

    private static func coordinate(_ value: Double) -> String {
        String(format: "%.4f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private static func unitParameters(for units: Units) throws -> UnitParameters {
        switch units.name {
        case Units.imperial.name:
            UnitParameters(
                temperature: "fahrenheit",
                wind: "mph",
                precipitation: "inch"
            )
        case Units.metric.name:
            UnitParameters(
                temperature: "celsius",
                wind: "kmh",
                precipitation: "mm"
            )
        default:
            throw FetchError.unsupportedUnits(units.name)
        }
    }

    private static func validate(hourly: HourlyData, model: String) throws {
        for variable in ["temperature_2m", "precipitation"] {
            guard !memberKeys(in: hourly, variable: variable).isEmpty else {
                throw FetchError.missingRequiredVariable(model: model, variable: variable)
            }
        }

        for (variable, values) in hourly.series where values.count != hourly.times.count {
            throw FetchError.invalidSeriesLength(
                model: model,
                variable: variable,
                expected: hourly.times.count,
                actual: values.count
            )
        }
    }

    private static func validate(
        hourlyUnits: [String: String],
        hourly: HourlyData,
        requestedUnits: Units,
        model: String
    ) throws {
        let expected: [String: String]
        switch requestedUnits.name {
        case Units.imperial.name:
            expected = [
                "temperature_2m": "°F",
                "precipitation": "inch",
                "wind_speed_10m": "mp/h",
                "wind_gusts_10m": "mp/h",
                "cloud_cover": "%",
            ]
        case Units.metric.name:
            expected = [
                "temperature_2m": "°C",
                "precipitation": "mm",
                "wind_speed_10m": "km/h",
                "wind_gusts_10m": "km/h",
                "cloud_cover": "%",
            ]
        default:
            throw FetchError.unsupportedUnits(requestedUnits.name)
        }

        let requiredVariables = Set(["temperature_2m", "precipitation"])
        for (variable, expectedUnit) in expected {
            let keys = memberKeys(in: hourly, variable: variable)
            guard !keys.isEmpty else { continue }

            // Open-Meteo currently emits all-null WeatherNext gust series with
            // an `undefined` unit. Optional data with no usable values is
            // semantically absent and must not invalidate the primary model.
            let hasUsableValue = keys.contains { key in
                hourly[key]?.contains { $0?.isFinite == true } == true
            }
            guard requiredVariables.contains(variable) || hasUsableValue else {
                continue
            }

            let actual = hourlyUnits[variable]
            guard actual == expectedUnit else {
                throw FetchError.unitMismatch(
                    model: model,
                    variable: variable,
                    expected: expectedUnit,
                    actual: actual
                )
            }
        }
    }
}

private struct UnitParameters {
    let temperature: String
    let wind: String
    let precipitation: String
}

private struct EnsemblePayload: Decodable {
    let latitude: Double?
    let longitude: Double?
    let timezone: String?
    let utcOffsetSeconds: Int?
    let hourlyUnits: [String: String]?
    let hourly: HourlyPayload?
    let error: Bool?
    let reason: String?

    enum CodingKeys: String, CodingKey {
        case latitude
        case longitude
        case timezone
        case utcOffsetSeconds = "utc_offset_seconds"
        case hourlyUnits = "hourly_units"
        case hourly
        case error
        case reason
    }
}

private struct HourlyPayload: Decodable {
    let data: HourlyData

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        let timeKey = DynamicCodingKey("time")
        let times = try container.decodeIfPresent([String].self, forKey: timeKey) ?? []
        var series: [String: [Double?]] = [:]

        for key in container.allKeys where key.stringValue != timeKey.stringValue {
            series[key.stringValue] = try container.decode([Double?].self, forKey: key)
        }
        data = HourlyData(times: times, series: series)
    }
}

private struct DynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil

    init(_ stringValue: String) {
        self.stringValue = stringValue
    }

    init?(stringValue: String) {
        self.init(stringValue)
    }

    init?(intValue: Int) {
        return nil
    }
}
