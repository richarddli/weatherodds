import Foundation

/// Open-Meteo hourly timestamps and their dynamically named ensemble series.
///
/// Timestamps intentionally remain offset-free strings. They describe local
/// forecast time, so decoding them as absolute `Date` values would risk
/// grouping steps into the wrong calendar day.
public struct HourlyData: Codable, Sendable, Equatable {
    public let times: [String]
    public let series: [String: [Double?]]

    public init(times: [String], series: [String: [Double?]]) {
        self.times = times
        self.series = series
    }

    public subscript(_ key: String) -> [Double?]? {
        series[key]
    }
}

public struct DaySlice: Codable, Sendable, Equatable {
    public let date: String
    public let indices: [Int]

    public init(date: String, indices: [Int]) {
        self.date = date
        self.indices = indices
    }
}

public enum AggregationError: Error, Sendable, Equatable {
    case missingMemberSeries(variable: String)
    case invalidSeriesLength(variable: String, key: String, expected: Int, actual: Int)
}

extension AggregationError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .missingMemberSeries(let variable):
            "No member series found for \(variable)"
        case .invalidSeriesLength(let variable, let key, let expected, let actual):
            "Invalid \(variable) series length for \(key): expected \(expected), got \(actual)"
        }
    }
}

/// Discovers member keys with the control first, followed by numbered members.
public func memberKeys(in hourly: HourlyData, variable: String) -> [String] {
    let escaped = NSRegularExpression.escapedPattern(for: variable)
    guard let regex = try? NSRegularExpression(pattern: "^\(escaped)(?:_member(\\d+))?$") else {
        return []
    }

    return hourly.series.keys.compactMap { key -> (index: Int, key: String)? in
        let range = NSRange(key.startIndex..<key.endIndex, in: key)
        guard let match = regex.firstMatch(in: key, range: range) else { return nil }

        let memberRange = match.range(at: 1)
        guard memberRange.location != NSNotFound,
              let range = Range(memberRange, in: key),
              let index = Int(key[range])
        else {
            return (-1, key)
        }
        return (index, key)
    }
    .sorted {
        if $0.index == $1.index { return $0.key < $1.key }
        return $0.index < $1.index
    }
    .map(\.key)
}

/// Groups step indices by the `YYYY-MM-DD` portion of local timestamps while
/// preserving the dates' first-seen order.
public func daySlices(_ times: [String]) -> [DaySlice] {
    var positions: [String: Int] = [:]
    var slices: [DaySlice] = []

    for (index, stamp) in times.enumerated() {
        let date = String(stamp.prefix { $0 != "T" })
        if let position = positions[date] {
            let existing = slices[position]
            slices[position] = DaySlice(date: date, indices: existing.indices + [index])
        } else {
            positions[date] = slices.count
            slices.append(DaySlice(date: date, indices: [index]))
        }
    }
    return slices
}

func memberMatrix(
    in hourly: HourlyData,
    variable: String,
    required: Bool = true
) throws -> [[Double]]? {
    let keys = memberKeys(in: hourly, variable: variable)
    guard !keys.isEmpty else {
        if required { throw AggregationError.missingMemberSeries(variable: variable) }
        return nil
    }

    return try keys.map { key in
        let values = hourly.series[key]!
        guard values.count == hourly.times.count else {
            throw AggregationError.invalidSeriesLength(
                variable: variable,
                key: key,
                expected: hourly.times.count,
                actual: values.count
            )
        }
        return values.map { $0 ?? .nan }
    }
}

func block(_ matrix: [[Double]], at indices: [Int]) -> [[Double]] {
    matrix.map { row in indices.map { row[$0] } }
}
