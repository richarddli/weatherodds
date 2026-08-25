import Testing
@testable import WeatherOddsCore

@Test func memberDiscoveryIsControlFirstAndNumericallySorted() {
    let hourly = HourlyData(times: [], series: [
        "temperature_2m_member10": [],
        "temperature_2m_member02": [],
        "temperature_2m": [],
        "temperature_2m_member01": [],
        "apparent_temperature_2m": [],
    ])

    #expect(memberKeys(in: hourly, variable: "temperature_2m") == [
        "temperature_2m",
        "temperature_2m_member01",
        "temperature_2m_member02",
        "temperature_2m_member10",
    ])
}

@Test func localTimestampStringsAreBucketedWithoutTimezoneConversion() {
    let slices = daySlices([
        "2026-11-01T00:00",
        "2026-11-01T01:00",
        "2026-11-02T00:00",
        "2026-11-01T02:00",
    ])

    #expect(slices == [
        DaySlice(date: "2026-11-01", indices: [0, 1, 3]),
        DaySlice(date: "2026-11-02", indices: [2]),
    ])
}

@Test func mismatchedSeriesLengthIsRejected() {
    let hourly = HourlyData(
        times: ["2026-08-09T00:00"],
        series: ["temperature_2m": [1, 2]]
    )

    #expect(throws: AggregationError.invalidSeriesLength(
        variable: "temperature_2m",
        key: "temperature_2m",
        expected: 1,
        actual: 2
    )) {
        _ = try memberMatrix(in: hourly, variable: "temperature_2m")
    }
}
