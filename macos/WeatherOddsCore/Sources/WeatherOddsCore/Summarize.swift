public struct ConfidenceScore: Codable, Sendable, Equatable {
    public let rating: String
    public let points: Int

    public init(rating: String, points: Int) {
        self.rating = rating
        self.points = points
    }
}

public func scoreConfidence(
    spread: Double,
    ecmwfAgrees: Bool?,
    units: Units
) -> ConfidenceScore {
    var points: Int
    if spread <= units.spreadHigh {
        points = 2
    } else if spread <= units.spreadMedium {
        points = 1
    } else {
        points = 0
    }

    if ecmwfAgrees == true {
        points += 1
    } else if ecmwfAgrees == false {
        points -= 1
    }

    let rating: String
    if points >= 2 {
        rating = "high"
    } else if points == 1 {
        rating = "medium"
    } else {
        rating = "low"
    }
    return ConfidenceScore(rating: rating, points: points)
}

/// Computes member-first per-day ensemble statistics.
public func summarize(
    _ hourly: HourlyData,
    units: Units,
    maxDays: Int? = nil
) throws -> [DaySummary] {
    let temperature = try memberMatrix(in: hourly, variable: "temperature_2m")!
    let precipitation = try memberMatrix(in: hourly, variable: "precipitation")!
    let wind = try memberMatrix(in: hourly, variable: "wind_speed_10m", required: false)
    let gusts = try memberMatrix(in: hourly, variable: "wind_gusts_10m", required: false)
    let cloud = try memberMatrix(in: hourly, variable: "cloud_cover", required: false)

    let membersTotal = temperature.count
    let rawDays = daySlices(hourly.times)
    let stepCounts = rawDays.map { slice in
        slice.indices.reduce(into: 0) { count, index in
            if temperature.contains(where: { $0[index].isFinite }) {
                count += 1
            }
        }
    }
    let fullDay = stepCounts.max() ?? 0

    var summaries: [DaySummary] = []
    for (slice, steps) in zip(rawDays, stepCounts) {
        guard steps > 0 else { continue }

        let memberHigh = rowMaximum(block(temperature, at: slice.indices))
        let memberLow = rowMinimum(block(temperature, at: slice.indices))
        let memberPrecipitation = rowSum(block(precipitation, at: slice.indices))
        let memberWind = wind.map { rowMaximum(block($0, at: slice.indices)) }
        let memberGust = gusts.map { rowMaximum(block($0, at: slice.indices)) }
        let memberCloud = cloud.map { rowMean(block($0, at: slice.indices)) }

        // A nonzero step count guarantees at least one finite member high/low.
        let highMedian = median(memberHigh)!
        let highP10 = percentile(memberHigh, 10)!
        let highP90 = percentile(memberHigh, 90)!
        let lowMedian = median(memberLow)!
        let lowP10 = percentile(memberLow, 10)!
        let lowP90 = percentile(memberLow, 90)!
        let spread = highP90 - highP10

        let wetTotals = memberPrecipitation.filter { value in
            let comparisonValue = value.isNaN ? 0 : value
            return comparisonValue >= units.wetThreshold - eps
        }
        let membersWet = wetTotals.count
        let probability = membersTotal == 0 ? 0 : Double(membersWet) / Double(membersTotal)
        let amountMedian = wetTotals.isEmpty ? nil : median(wetTotals)
        let amountP90 = wetTotals.isEmpty ? nil : percentile(wetTotals, 90)
        let confidence = scoreConfidence(spread: spread, ecmwfAgrees: nil, units: units)

        summaries.append(DaySummary(
            date: slice.date,
            highMedian: highMedian,
            highP10: highP10,
            highP90: highP90,
            lowMedian: lowMedian,
            lowP10: lowP10,
            lowP90: lowP90,
            spread: spread,
            rainProbability: probability,
            membersWet: membersWet,
            membersTotal: membersTotal,
            amountMedian: amountMedian,
            amountP90: amountP90,
            windMedianMax: memberWind.flatMap(median),
            gustsP90: memberGust.flatMap { percentile($0, 90) },
            cloudCover: memberCloud.flatMap(median),
            steps: steps,
            partial: steps < fullDay,
            rating: confidence.rating,
            points: confidence.points
        ))
    }

    guard let maxDays else { return summaries }
    return Array(summaries.prefix(max(0, maxDays)))
}

/// Folds ECMWF agreement into each WeatherNext day's confidence score.
public func crossCheck(
    _ days: [DaySummary],
    ecmwfDays: [DaySummary],
    units: Units
) -> [DaySummary] {
    let byDate = Dictionary(ecmwfDays.map { ($0.date, $0) }, uniquingKeysWith: { _, last in last })
    return days.map { day in
        guard let other = byDate[day.date] else { return day }

        let agrees = abs(day.highMedian - other.highMedian) <= units.agreeTemp
            && abs(day.rainProbability - other.rainProbability) <= rainProbTolerance
        let confidence = scoreConfidence(spread: day.spread, ecmwfAgrees: agrees, units: units)
        return DaySummary(
            date: day.date,
            highMedian: day.highMedian,
            highP10: day.highP10,
            highP90: day.highP90,
            lowMedian: day.lowMedian,
            lowP10: day.lowP10,
            lowP90: day.lowP90,
            spread: day.spread,
            rainProbability: day.rainProbability,
            membersWet: day.membersWet,
            membersTotal: day.membersTotal,
            amountMedian: day.amountMedian,
            amountP90: day.amountP90,
            windMedianMax: day.windMedianMax,
            gustsP90: day.gustsP90,
            cloudCover: day.cloudCover,
            steps: day.steps,
            partial: day.partial,
            rating: confidence.rating,
            points: confidence.points,
            ecmwfAgrees: agrees
        )
    }
}
