import Darwin
import Foundation
import WeatherOddsCore

@main
enum WeatherOddsDiagnostics {
    @MainActor
    static func main() async {
        let rawZip = CommandLine.arguments.dropFirst().first ?? "02492"

        do {
            let zip = try USZipCode(rawZip)
            print("zip: \(zip.rawValue)")

            print("geocode: starting")
            let location = try await USZipCodeGeocoder().location(for: zip.rawValue)
            print(
                "geocode: \(location.displayName) "
                    + "(\(location.latitude), \(location.longitude))"
            )

            let client = EnsembleClient()
            print("WeatherNext: starting")
            let primary = try await client.fetchAndSummarize(
                model: weatherNextModel,
                latitude: location.latitude,
                longitude: location.longitude,
                units: .imperial,
                maxDays: ensembleForecastDays
            )
            guard let first = primary.summaries.first else {
                throw DiagnosticError.emptyPrimaryForecast
            }
            print(
                "WeatherNext: \(primary.summaries.count) days, "
                    + "first=\(first.date), high=\(first.highMedian), "
                    + "rain=\(first.rainProbability)"
            )

            print("ECMWF: starting")
            let ecmwf = try await client.fetchAndSummarizeIfAvailable(
                model: ecmwfModel,
                latitude: location.latitude,
                longitude: location.longitude,
                units: .imperial,
                maxDays: ensembleForecastDays
            )
            let checked = ecmwf.summary.map {
                crossCheck(primary.summaries, ecmwfDays: $0.summaries, units: .imperial)
            } ?? primary.summaries
            if let summary = ecmwf.summary {
                print("ECMWF: contributed \(summary.summaries.count) days")
            } else {
                let detail = ecmwf.httpFailure.map { "HTTP \($0.statusCode)" } ?? "no response"
                print("ECMWF: unavailable (allowed): \(detail)")
            }
            print("result: success, \(checked.count) summarized days")
        } catch {
            let localized = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            fputs("result: failure: \(String(reflecting: error)): \(localized)\n", stderr)
            exit(EXIT_FAILURE)
        }
    }
}

private enum DiagnosticError: LocalizedError {
    case emptyPrimaryForecast

    var errorDescription: String? {
        "WeatherNext returned no summarized forecast days."
    }
}
