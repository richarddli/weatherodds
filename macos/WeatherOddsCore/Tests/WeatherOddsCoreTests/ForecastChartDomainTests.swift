import Testing
@testable import WeatherOddsCore

@Test("Imperial chart domain contains and tightly rounds a wide ensemble envelope")
func imperialChartDomain() throws {
    let days = [
        summary(lowP10: 56.86, highP90: 84.07),
        summary(lowP10: 60.28, highP90: 91.20),
    ]

    let domain = try #require(ForecastChartDomain(days: days, units: .imperial))

    #expect(domain.lowerBound == 50)
    #expect(domain.upperBound == 95)
}

@Test("Metric chart domain uses smaller round intervals")
func metricChartDomain() throws {
    let days = [
        summary(lowP10: 12.4, highP90: 23.8),
        summary(lowP10: 14.1, highP90: 28.1),
    ]

    let domain = try #require(ForecastChartDomain(days: days, units: .metric))

    #expect(domain.lowerBound == 10)
    #expect(domain.upperBound == 30)
}

@Test("Empty forecasts have no chart domain")
func emptyChartDomain() {
    #expect(ForecastChartDomain(days: [], units: .imperial) == nil)
}

private func summary(lowP10: Double, highP90: Double) -> DaySummary {
    DaySummary(
        date: "2026-08-25",
        highMedian: highP90 - 2,
        highP10: highP90 - 4,
        highP90: highP90,
        lowMedian: lowP10 + 2,
        lowP10: lowP10,
        lowP90: lowP10 + 4,
        spread: 4,
        rainProbability: 0,
        membersWet: 0,
        membersTotal: 64,
        amountMedian: nil,
        amountP90: nil,
        windMedianMax: nil,
        gustsP90: nil,
        cloudCover: nil,
        steps: 24,
        partial: false,
        rating: "high",
        points: 2
    )
}
