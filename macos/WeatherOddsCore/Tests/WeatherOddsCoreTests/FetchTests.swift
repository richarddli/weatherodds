import Foundation
import Testing
@testable import WeatherOddsCore

@Suite("Open-Meteo ensemble fetch client")
struct FetchTests {
    @Test("Imperial request is fixed to the full WeatherNext horizon")
    func imperialRequestAndDynamicDecode() async throws {
        let loader = FetchTestLoader(data: validPayload(), statusCode: 200)
        let client = EnsembleClient(loader: loader)

        let ensemble = try await client.fetch(
            model: weatherNextModel,
            latitude: 42.35722,
            longitude: -71.06371,
            units: .imperial
        )

        #expect(ensemble.model == weatherNextModel)
        #expect(ensemble.latitude == 42.25)
        #expect(ensemble.longitude == -71.25)
        #expect(ensemble.timezone == "America/New_York")
        #expect(ensemble.utcOffsetSeconds == -14_400)
        #expect(ensemble.hourly.times == ["2026-08-09T00:00", "2026-08-09T06:00"])
        #expect(ensemble.hourly["temperature_2m_member01"] == [61, 71])

        let request = try #require(await loader.lastRequest())
        let components = try #require(URLComponents(url: request.url!, resolvingAgainstBaseURL: false))
        let query = Dictionary(
            components.queryItems!.map { ($0.name, $0.value!) },
            uniquingKeysWith: { _, last in last }
        )
        #expect(components.scheme == "https")
        #expect(components.host == "ensemble-api.open-meteo.com")
        #expect(components.path == "/v1/ensemble")
        #expect(query["latitude"] == "42.3572")
        #expect(query["longitude"] == "-71.0637")
        #expect(query["models"] == weatherNextModel)
        #expect(query["forecast_days"] == "15")
        #expect(query["timezone"] == "auto")
        #expect(query["hourly"] == ensembleHourlyVariables.joined(separator: ","))
        #expect(query["temperature_unit"] == "fahrenheit")
        #expect(query["wind_speed_unit"] == "mph")
        #expect(query["precipitation_unit"] == "inch")
        #expect(request.timeoutInterval == 6)
    }

    @Test("Metric parameters and summarized helper compose with aggregation")
    func metricSummary() async throws {
        let loader = FetchTestLoader(
            data: validPayload(
                temperatureUnit: "°C",
                precipitationUnit: "mm",
                windUnit: "km/h"
            ),
            statusCode: 200
        )
        let client = EnsembleClient(loader: loader)

        let result = try await client.fetchAndSummarize(
            model: ecmwfModel,
            latitude: 42,
            longitude: -71,
            units: .metric,
            maxDays: 1
        )

        #expect(result.model == ecmwfModel)
        #expect(result.summaries.count == 1)
        #expect(result.summaries[0].highMedian == 70.5)

        let request = try #require(await loader.lastRequest())
        let query = Dictionary(
            URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
                .map { ($0.name, $0.value!) },
            uniquingKeysWith: { _, last in last }
        )
        #expect(query["temperature_unit"] == "celsius")
        #expect(query["wind_speed_unit"] == "kmh")
        #expect(query["precipitation_unit"] == "mm")
    }

    @Test("Default session applies widget request and resource deadlines")
    func timeoutConfiguration() {
        let configuration = EnsembleClient.defaultSessionConfiguration()
        #expect(configuration.timeoutIntervalForRequest == 6)
        #expect(configuration.timeoutIntervalForResource == 8)
        #expect(configuration.waitsForConnectivity == false)
        #expect(configuration.urlCache == nil)
    }

    @Test("Unit drift is rejected when hourly units are supplied")
    func unitMismatch() async throws {
        let loader = FetchTestLoader(
            data: validPayload(temperatureUnit: "°C"),
            statusCode: 200
        )

        await #expect(throws: FetchError.unitMismatch(
            model: weatherNextModel,
            variable: "temperature_2m",
            expected: "°F",
            actual: "°C"
        )) {
            try await EnsembleClient(loader: loader).fetch(
                model: weatherNextModel,
                latitude: 42,
                longitude: -71,
                units: .imperial
            )
        }
    }

    @Test("All-null optional series may report an undefined unit")
    func allNullOptionalUndefinedUnit() async throws {
        let loader = FetchTestLoader(
            data: payload(
                units: [
                    "temperature_2m": "°F",
                    "precipitation": "inch",
                    "wind_gusts_10m": "undefined",
                ],
                hourly: [
                    "time": ["2026-08-09T00:00", "2026-08-09T06:00"],
                    "temperature_2m": [60.0, 70.0],
                    "precipitation": [0.0, 0.0],
                    "wind_gusts_10m": [NSNull(), NSNull()],
                    "wind_gusts_10m_member01": [NSNull(), NSNull()],
                ]
            ),
            statusCode: 200
        )

        let result = try await EnsembleClient(loader: loader).fetchAndSummarize(
            model: weatherNextModel,
            latitude: 42,
            longitude: -71,
            units: .imperial,
            maxDays: 1
        )

        #expect(result.summaries.count == 1)
        #expect(result.summaries[0].gustsP90 == nil)
    }

    @Test("API reason is retained for HTTP failures")
    func apiErrorReason() async throws {
        let data = Data(#"{"error":true,"reason":"model unavailable"}"#.utf8)
        let loader = FetchTestLoader(data: data, statusCode: 503)

        await #expect(throws: FetchError.apiError(
            model: ecmwfModel,
            reason: "model unavailable"
        )) {
            try await EnsembleClient(loader: loader).fetch(
                model: ecmwfModel,
                latitude: 42,
                longitude: -71,
                units: .imperial
            )
        }
    }

    @Test("Optional secondary fetch preserves cancellation but swallows other failures")
    func optionalFetchPreservesCancellation() async throws {
        let cancellationClient = EnsembleClient(
            loader: ErroringFetchLoader(error: CancellationError())
        )
        await #expect(throws: CancellationError.self) {
            try await cancellationClient.fetchAndSummarizeIfAvailable(
                model: ecmwfModel,
                latitude: 42,
                longitude: -71,
                units: .imperial,
                maxDays: 1
            )
        }

        let failingClient = EnsembleClient(
            loader: ErroringFetchLoader(error: URLError(.timedOut))
        )
        let result = try await failingClient.fetchAndSummarizeIfAvailable(
            model: ecmwfModel,
            latitude: 42,
            longitude: -71,
            units: .imperial,
            maxDays: 1
        )
        #expect(result == nil)
    }

    @Test("Missing required data and malformed lengths are rejected")
    func validatesHourlyBody() async throws {
        let missingPrecipitation = FetchTestLoader(
            data: payload(hourly: [
                "time": ["2026-08-09T00:00"],
                "temperature_2m": [60.0],
            ]),
            statusCode: 200
        )
        await #expect(throws: FetchError.missingRequiredVariable(
            model: weatherNextModel,
            variable: "precipitation"
        )) {
            try await EnsembleClient(loader: missingPrecipitation).fetch(
                model: weatherNextModel,
                latitude: 42,
                longitude: -71,
                units: .imperial
            )
        }

        let wrongLength = FetchTestLoader(
            data: payload(hourly: [
                "time": ["2026-08-09T00:00", "2026-08-09T06:00"],
                "temperature_2m": [60.0, 70.0],
                "precipitation": [0.0],
            ]),
            statusCode: 200
        )
        await #expect(throws: FetchError.invalidSeriesLength(
            model: weatherNextModel,
            variable: "precipitation",
            expected: 2,
            actual: 1
        )) {
            try await EnsembleClient(loader: wrongLength).fetch(
                model: weatherNextModel,
                latitude: 42,
                longitude: -71,
                units: .imperial
            )
        }
    }
}

private actor FetchTestLoader: ForecastDataLoading {
    private let responseData: Data
    private let statusCode: Int
    private var requests: [URLRequest] = []

    init(data: Data, statusCode: Int) {
        self.responseData = data
        self.statusCode = statusCode
    }

    func data(forForecastRequest request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (responseData, response)
    }

    func lastRequest() -> URLRequest? {
        requests.last
    }
}

private struct ErroringFetchLoader: ForecastDataLoading {
    let error: Error

    func data(forForecastRequest request: URLRequest) async throws -> (Data, URLResponse) {
        throw error
    }
}

private func validPayload(
    temperatureUnit: String = "°F",
    precipitationUnit: String = "inch",
    windUnit: String = "mp/h"
) -> Data {
    payload(
        units: [
            "temperature_2m": temperatureUnit,
            "precipitation": precipitationUnit,
            "wind_speed_10m": windUnit,
        ],
        hourly: [
            "time": ["2026-08-09T00:00", "2026-08-09T06:00"],
            "temperature_2m": [60.0, 70.0],
            "temperature_2m_member01": [61.0, 71.0],
            "precipitation": [0.0, NSNull()],
            "precipitation_member01": [0.1, 0.0],
            "wind_speed_10m": [5.0, 8.0],
        ]
    )
}

private func payload(
    units: [String: String]? = nil,
    hourly: [String: Any]
) -> Data {
    var object: [String: Any] = [
        "latitude": 42.25,
        "longitude": -71.25,
        "timezone": "America/New_York",
        "utc_offset_seconds": -14_400,
        "hourly": hourly,
    ]
    object["hourly_units"] = units
    return try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}
