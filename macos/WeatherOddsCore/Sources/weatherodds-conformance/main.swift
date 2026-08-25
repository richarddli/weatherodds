import Darwin
import Foundation
import WeatherOddsCore

private let numericTolerance = 1e-6

private enum RunnerError: Error, CustomStringConvertible {
    case usage(String)
    case invalidReference(String)
    case invalidFixture(String)
    case mismatches(Int)

    var description: String {
        switch self {
        case .usage(let message), .invalidReference(let message), .invalidFixture(let message):
            message
        case .mismatches(let count):
            "conformance failed with \(count) mismatch\(count == 1 ? "" : "es")"
        }
    }
}

private indirect enum JSONValue: Decodable, Sendable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }
}

private struct Reference: Decodable {
    let schemaVersion: Int
    let cases: [ReferenceCase]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case cases
    }
}

private struct ReferenceCase: Decodable {
    let name: String
    let fixture: String
    let units: String
    let maxDays: Int?
    let crossCheck: CrossCheckSpec?
    let expected: [JSONValue]

    enum CodingKeys: String, CodingKey {
        case name, fixture, units, expected
        case maxDays = "max_days"
        case crossCheck = "cross_check"
    }
}

private struct CrossCheckSpec: Decodable {
    let mode: String
    let delta: Double?
    let date: String?
}

@main
private enum WeatherOddsConformance {
    static func main() {
        do {
            let root = try repositoryRoot(arguments: Array(CommandLine.arguments.dropFirst()))
            try run(repositoryRoot: root)
        } catch {
            writeError("error: \(error)\n")
            exit(EXIT_FAILURE)
        }
    }

    private static func repositoryRoot(arguments: [String]) throws -> URL {
        guard arguments.count == 2, arguments[0] == "--repo-root" else {
            throw RunnerError.usage(
                "usage: weatherodds-conformance --repo-root <repository-path>"
            )
        }
        return URL(fileURLWithPath: arguments[1], isDirectory: true).standardizedFileURL
    }

    private static func run(repositoryRoot root: URL) throws {
        let referenceURL = root.appending(path: "conformance/reference.json")
        let reference = try JSONDecoder().decode(Reference.self, from: Data(contentsOf: referenceURL))
        guard reference.schemaVersion == 1 else {
            throw RunnerError.invalidReference(
                "unsupported reference schema \(reference.schemaVersion); expected 1"
            )
        }

        var diagnostics: [String] = []
        for testCase in reference.cases {
            do {
                let actual = try evaluate(testCase, repositoryRoot: root)
                compare(
                    .array(actual),
                    .array(testCase.expected),
                    path: testCase.name,
                    diagnostics: &diagnostics
                )
            } catch {
                diagnostics.append("\(testCase.name): evaluation failed: \(error)")
            }
        }

        if diagnostics.isEmpty {
            print("conformance passed: \(reference.cases.count) cases")
            return
        }

        diagnostics.forEach { writeError("\($0)\n") }
        throw RunnerError.mismatches(diagnostics.count)
    }

    private static func evaluate(
        _ testCase: ReferenceCase,
        repositoryRoot root: URL
    ) throws -> [JSONValue] {
        guard let units = Units.named(testCase.units) else {
            throw RunnerError.invalidReference("unknown units \(testCase.units)")
        }
        let fixtureURL = root
            .appending(path: "tests/fixtures", directoryHint: .isDirectory)
            .appending(path: testCase.fixture)
        let hourly = try loadHourly(from: fixtureURL)
        var summaries = try summarize(hourly, units: units, maxDays: testCase.maxDays)

        if let spec = testCase.crossCheck {
            let secondaryHourly: HourlyData
            switch spec.mode {
            case "same":
                secondaryHourly = hourly
            case "temperature_delta":
                guard let delta = spec.delta else {
                    throw RunnerError.invalidReference("temperature_delta requires delta")
                }
                secondaryHourly = perturbTemperatures(hourly, delta: delta)
            case "remove_date":
                guard let date = spec.date else {
                    throw RunnerError.invalidReference("remove_date requires date")
                }
                secondaryHourly = removingDate(hourly, date: date)
            default:
                throw RunnerError.invalidReference("unknown cross_check mode \(spec.mode)")
            }
            let secondary = try summarize(
                secondaryHourly,
                units: units,
                maxDays: testCase.maxDays
            )
            summaries = crossCheck(summaries, ecmwfDays: secondary, units: units)
        }

        return summaries.map(dayValue)
    }
}

private func loadHourly(from url: URL) throws -> HourlyData {
    let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
    guard let payload = root as? [String: Any],
          let hourly = payload["hourly"] as? [String: Any],
          let times = hourly["time"] as? [String]
    else {
        throw RunnerError.invalidFixture("\(url.lastPathComponent): missing hourly.time")
    }

    var series: [String: [Double?]] = [:]
    for (key, rawValue) in hourly where key != "time" {
        guard let values = rawValue as? [Any] else { continue }
        series[key] = try values.map { value in
            if value is NSNull { return nil }
            guard let number = value as? NSNumber else {
                throw RunnerError.invalidFixture(
                    "\(url.lastPathComponent): nonnumeric value in \(key)"
                )
            }
            return number.doubleValue
        }
    }
    return HourlyData(times: times, series: series)
}

private func perturbTemperatures(_ hourly: HourlyData, delta: Double) -> HourlyData {
    var series = hourly.series
    for key in series.keys where key.hasPrefix("temperature_2m") {
        series[key] = series[key]!.map { $0.map { $0 + delta } }
    }
    return HourlyData(times: hourly.times, series: series)
}

private func removingDate(_ hourly: HourlyData, date: String) -> HourlyData {
    let retained = hourly.times.indices.filter { !hourly.times[$0].hasPrefix("\(date)T") }
    let series = hourly.series.mapValues { values in retained.map { values[$0] } }
    return HourlyData(times: retained.map { hourly.times[$0] }, series: series)
}

private func dayValue(_ day: DaySummary) -> JSONValue {
    .object([
        "date": .string(day.date),
        "high_median": .number(day.highMedian),
        "high_p10": .number(day.highP10),
        "high_p90": .number(day.highP90),
        "low_median": .number(day.lowMedian),
        "low_p10": .number(day.lowP10),
        "low_p90": .number(day.lowP90),
        "spread": .number(day.spread),
        "rain_probability": .number(day.rainProbability),
        "members_wet": .number(Double(day.membersWet)),
        "members_total": .number(Double(day.membersTotal)),
        "amount_median": optionalNumber(day.amountMedian),
        "amount_p90": optionalNumber(day.amountP90),
        "wind_median_max": optionalNumber(day.windMedianMax),
        "gusts_p90": optionalNumber(day.gustsP90),
        "cloud_cover": optionalNumber(day.cloudCover),
        "steps": .number(Double(day.steps)),
        "partial": .bool(day.partial),
        "rating": .string(day.rating),
        "points": .number(Double(day.points)),
        "ecmwf_agrees": day.ecmwfAgrees.map(JSONValue.bool) ?? .null,
        "sky": .string(day.sky),
        "rain_dots": .number(Double(day.rainDots)),
    ])
}

private func optionalNumber(_ value: Double?) -> JSONValue {
    value.map(JSONValue.number) ?? .null
}

private func compare(
    _ actual: JSONValue,
    _ expected: JSONValue,
    path: String,
    diagnostics: inout [String]
) {
    switch (actual, expected) {
    case (.null, .null):
        return
    case (.bool(let actual), .bool(let expected)) where actual == expected:
        return
    case (.string(let actual), .string(let expected)) where actual == expected:
        return
    case (.number(let actual), .number(let expected)):
        guard actual.isFinite, expected.isFinite,
              abs(actual - expected) <= numericTolerance
        else {
            diagnostics.append("\(path): expected \(expected), got \(actual)")
            return
        }
    case (.array(let actual), .array(let expected)):
        guard actual.count == expected.count else {
            diagnostics.append("\(path): expected \(expected.count) items, got \(actual.count)")
            return
        }
        for index in actual.indices {
            compare(
                actual[index],
                expected[index],
                path: "\(path)[\(index)]",
                diagnostics: &diagnostics
            )
        }
    case (.object(let actual), .object(let expected)):
        let actualKeys = Set(actual.keys)
        let expectedKeys = Set(expected.keys)
        if actualKeys != expectedKeys {
            let missing = expectedKeys.subtracting(actualKeys).sorted()
            let extra = actualKeys.subtracting(expectedKeys).sorted()
            if !missing.isEmpty { diagnostics.append("\(path): missing fields \(missing)") }
            if !extra.isEmpty { diagnostics.append("\(path): extra fields \(extra)") }
        }
        for key in actualKeys.intersection(expectedKeys).sorted() {
            compare(
                actual[key]!,
                expected[key]!,
                path: "\(path).\(key)",
                diagnostics: &diagnostics
            )
        }
    default:
        diagnostics.append("\(path): value or type mismatch")
    }
}

private func writeError(_ message: String) {
    FileHandle.standardError.write(Data(message.utf8))
}
