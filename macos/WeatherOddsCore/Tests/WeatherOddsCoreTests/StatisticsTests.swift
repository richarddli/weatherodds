import Testing
@testable import WeatherOddsCore

@Test func finiteFilteringAndLinearPercentiles() {
    let values = [Double.nan, 80, 84, 88, 92, .infinity]

    #expect(finiteValues(values) == [80, 84, 88, 92])
    #expect(percentile(values, 10) == 81.2)
    #expect(percentile(values, 50) == 86)
    #expect(percentile(values, 90) == 90.8)
    #expect(percentile([7], 10) == 7)
    #expect(percentile([.nan], 50) == nil)
}

@Test func rowReductionsPreserveAllNaNRows() {
    let rows = [[Double.nan, .nan], [3, .nan, 9], [2, 4]]

    let minimum = rowMinimum(rows)
    let maximum = rowMaximum(rows)
    let sum = rowSum(rows)
    let mean = rowMean(rows)

    #expect(minimum[0].isNaN)
    #expect(maximum[0].isNaN)
    #expect(sum[0].isNaN)
    #expect(mean[0].isNaN)
    #expect(minimum.dropFirst() == [3, 2])
    #expect(maximum.dropFirst() == [9, 4])
    #expect(sum.dropFirst() == [12, 6])
    #expect(mean.dropFirst() == [6, 3])
}
