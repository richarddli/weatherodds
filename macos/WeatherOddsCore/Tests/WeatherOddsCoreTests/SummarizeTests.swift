import Foundation
import Testing
@testable import WeatherOddsCore

@Test func memberFirstDailyStatisticsMatchCanonicalFixture() throws {
    let days = try summarize(canonicalHourly(), units: .imperial)

    #expect(days.map(\.date) == ["2026-08-09", "2026-08-10", "2026-08-11"])
    let first = days[0]
    #expect(first.highMedian == 86)
    #expect(abs(first.highP10 - 81.2) < 1e-12)
    #expect(abs(first.highP90 - 90.8) < 1e-12)
    #expect(abs(first.spread - 9.6) < 1e-12)
    #expect(first.lowMedian == 65.5)
    #expect(first.membersWet == 3)
    #expect(first.membersTotal == 4)
    #expect(first.rainProbability == 0.75)
    #expect(first.rainDots == 4)
    #expect(abs(first.amountMedian! - 0.3) < 1e-12)
    #expect(abs(first.amountP90! - 0.46) < 1e-12)
    #expect(first.windMedianMax == 13)
    #expect(first.gustsP90 == nil)
    #expect(first.cloudCover == 81)
    #expect(first.sky == "Cloudy")
    #expect(first.rating == "medium")
    #expect(first.points == 1)
    #expect(days.map(\.partial) == [false, false, true])
    #expect(days.map(\.steps) == [4, 4, 2])
}

@Test func missingValuesThresholdAndZeroStepDaysMatchPythonRules() throws {
    let hourly = HourlyData(
        times: [
            "2026-08-08T00:00", "2026-08-08T06:00",
            "2026-08-09T00:00", "2026-08-09T06:00",
            "2026-08-10T00:00",
        ],
        series: [
            "temperature_2m": [nil, nil, 60, 70, 72],
            "temperature_2m_member01": [nil, nil, nil, nil, 74],
            "precipitation": [nil, nil, 0.02, 0.02, 0],
            "precipitation_member01": [nil, nil, nil, nil, 0],
        ]
    )

    let days = try summarize(hourly, units: .imperial)
    #expect(days.map(\.date) == ["2026-08-09", "2026-08-10"])
    #expect(days[0].membersWet == 1) // exactly 0.04 in is wet
    #expect(days[0].rainProbability == 0.5)
    #expect(days[0].amountMedian == 0.04)
    #expect(days[0].windMedianMax == nil)
    #expect(days[0].gustsP90 == nil)
    #expect(days[0].cloudCover == nil)
    #expect(days[0].sky == "—")
    #expect(days[0].partial == false)
    #expect(days[1].partial == true)

    let limited = try summarize(hourly, units: .imperial, maxDays: 1)
    #expect(limited.map(\.date) == ["2026-08-09"])
}

@Test func optionalVariablesCanHaveFewerMembersThanTemperature() throws {
    let hourly = HourlyData(
        times: ["2026-08-09T00:00", "2026-08-09T06:00"],
        series: [
            "temperature_2m": [60, 70],
            "temperature_2m_member01": [61, 71],
            "precipitation": [0, 0],
            "precipitation_member01": [0, 0],
            "wind_speed_10m": [5, 8],
        ]
    )

    let day = try #require(try summarize(hourly, units: .imperial).first)
    #expect(day.membersTotal == 2)
    #expect(day.windMedianMax == 8)
}

@Test func allNullMemberAndMetricWetBoundaryMatchEdgeContract() throws {
    let hourly = HourlyData(
        times: [
            "2026-09-01T00:00", "2026-09-01T06:00",
            "2026-09-01T12:00", "2026-09-01T18:00",
        ],
        series: [
            "temperature_2m": [50, nil, 55, 53],
            "temperature_2m_member01": [51, 52, nil, 57],
            "temperature_2m_member02": [nil, nil, nil, nil],
            "precipitation": [0.01, 0.01, nil, 0.02],
            "precipitation_member01": [0.25, 0.25, 0.25, 0.25],
            "precipitation_member02": [nil, nil, nil, nil],
        ]
    )

    let imperial = try #require(try summarize(hourly, units: .imperial).first)
    #expect(imperial.highMedian == 56)
    #expect(abs(imperial.highP10 - 55.2) < 1e-12)
    #expect(abs(imperial.highP90 - 56.8) < 1e-12)
    #expect(imperial.membersTotal == 3)
    #expect(imperial.membersWet == 2)
    #expect(abs(imperial.amountMedian! - 0.52) < 1e-12)

    let metric = try #require(try summarize(hourly, units: .metric).first)
    #expect(metric.membersTotal == 3)
    #expect(metric.membersWet == 1) // exactly 1.0 mm is wet
    #expect(metric.rainProbability == 1.0 / 3.0)
    #expect(metric.amountMedian == 1)
}

@Test func confidenceAndCrossCheckApplyAgreementAdjustment() throws {
    #expect(scoreConfidence(spread: 4, ecmwfAgrees: nil, units: .imperial)
        == ConfidenceScore(rating: "high", points: 2))
    #expect(scoreConfidence(spread: 9, ecmwfAgrees: true, units: .imperial)
        == ConfidenceScore(rating: "high", points: 2))
    #expect(scoreConfidence(spread: 4, ecmwfAgrees: false, units: .imperial)
        == ConfidenceScore(rating: "medium", points: 1))
    #expect(scoreConfidence(spread: 18, ecmwfAgrees: false, units: .imperial)
        == ConfidenceScore(rating: "low", points: -1))

    let primary = try summarize(canonicalHourly(), units: .imperial)
    let agreeing = crossCheck(primary, ecmwfDays: primary, units: .imperial)
    #expect(agreeing[0].ecmwfAgrees == true)
    #expect(agreeing[0].rating == "high")

    let shifted = HourlyData(
        times: canonicalHourly().times,
        series: canonicalHourly().series.mapValues { $0.map { $0.map { $0 + 20 } } }
    )
    // Only shifting temperature is relevant; retain precipitation so the rain
    // check cannot hide the temperature disagreement.
    var shiftedSeries = canonicalHourly().series
    for key in memberKeys(in: canonicalHourly(), variable: "temperature_2m") {
        shiftedSeries[key] = shifted.series[key]
    }
    let other = try summarize(
        HourlyData(times: canonicalHourly().times, series: shiftedSeries),
        units: .imperial
    )
    let disagreeing = crossCheck(primary, ecmwfDays: other, units: .imperial)
    #expect(disagreeing[0].ecmwfAgrees == false)
    #expect(disagreeing[0].rating == "low")

    let unmatched = crossCheck([primary[0]], ecmwfDays: Array(other.dropFirst()), units: .imperial)
    #expect(unmatched == [primary[0]])
}

@Test func daySummaryEncodingIncludesExplicitNullAgreement() throws {
    let day = try #require(try summarize(canonicalHourly(), units: .imperial).first)
    let object = try #require(
        JSONSerialization.jsonObject(with: JSONEncoder().encode(day)) as? [String: Any]
    )

    #expect(object.keys.contains("high_median"))
    #expect(object.keys.contains("ecmwf_agrees"))
    #expect(object["ecmwf_agrees"] is NSNull)
}

private func canonicalHourly() -> HourlyData {
    let times = [
        "2026-08-09T00:00", "2026-08-09T06:00", "2026-08-09T12:00", "2026-08-09T18:00",
        "2026-08-10T00:00", "2026-08-10T06:00", "2026-08-10T12:00", "2026-08-10T18:00",
        "2026-08-11T00:00", "2026-08-11T06:00",
    ]
    return HourlyData(times: times, series: [
        "temperature_2m": optional([66, 64, 80, 72, 60, 58, 70, 64, 59, 57]),
        "temperature_2m_member01": optional([67, 65, 84, 74, 61, 59, 71, 65, 60, 58]),
        "temperature_2m_member02": optional([68, 66, 88, 76, 62, 60, 72, 66, 61, 59]),
        "temperature_2m_member03": optional([69, 67, 92, 78, 63, 61, 73, 67, 62, 60]),
        "precipitation": optional([0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
        "precipitation_member01": optional([0, 0.05, 0.05, 0, 0, 0, 0, 0, 0.01, 0.01]),
        "precipitation_member02": optional([0, 0.1, 0.2, 0, 0, 0, 0, 0, 0.01, 0.01]),
        "precipitation_member03": optional([0.1, 0.2, 0.2, 0, 0, 0, 0, 0, 0.01, 0.01]),
        "wind_speed_10m": optional([4, 6, 10, 8, 3, 4, 5, 4, 6, 7]),
        "wind_speed_10m_member01": optional([4, 7, 12, 8, 3, 4, 6, 4, 6, 7]),
        "wind_speed_10m_member02": optional([5, 8, 14, 9, 4, 5, 7, 5, 7, 8]),
        "wind_speed_10m_member03": optional([5, 9, 16, 9, 4, 5, 8, 5, 7, 8]),
        "cloud_cover": optional([80, 80, 80, 80, 10, 10, 10, 10, 50, 50]),
        "cloud_cover_member01": optional([80, 80, 80, 80, 10, 10, 10, 10, 50, 50]),
        "cloud_cover_member02": optional([82, 82, 82, 82, 12, 12, 12, 12, 50, 50]),
        "cloud_cover_member03": optional([82, 82, 82, 82, 12, 12, 12, 12, 50, 50]),
    ])
}

private func optional(_ values: [Double]) -> [Double?] {
    values.map(Optional.some)
}
