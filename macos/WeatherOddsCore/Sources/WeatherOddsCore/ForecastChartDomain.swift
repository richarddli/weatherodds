import Foundation

/// A rounded temperature domain that preserves the full daily ensemble envelope.
public struct ForecastChartDomain: Sendable, Equatable {
    public let lowerBound: Double
    public let upperBound: Double

    public init?(days: [DaySummary], units: Units) {
        guard let rawLower = days.map(\.lowP10).min(),
              let rawUpper = days.map(\.highP90).max()
        else {
            return nil
        }

        let rawSpan = max(1, rawUpper - rawLower)
        let interval = units == .metric ? 2.0 : 5.0
        let minimumPadding = units == .metric ? 1.0 : 2.0
        let padding = max(minimumPadding, rawSpan * 0.06)

        lowerBound = floor((rawLower - padding) / interval) * interval
        upperBound = ceil((rawUpper + padding) / interval) * interval
    }
}
