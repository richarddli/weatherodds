public struct DaySummary: Codable, Sendable, Equatable {
    public let date: String
    public let highMedian: Double
    public let highP10: Double
    public let highP90: Double
    public let lowMedian: Double
    public let lowP10: Double
    public let lowP90: Double
    public let spread: Double
    public let rainProbability: Double
    public let membersWet: Int
    public let membersTotal: Int
    public let amountMedian: Double?
    public let amountP90: Double?
    public let windMedianMax: Double?
    public let gustsP90: Double?
    public let cloudCover: Double?
    public let steps: Int
    public let partial: Bool
    public let rating: String
    public let points: Int
    public let ecmwfAgrees: Bool?

    public init(
        date: String,
        highMedian: Double,
        highP10: Double,
        highP90: Double,
        lowMedian: Double,
        lowP10: Double,
        lowP90: Double,
        spread: Double,
        rainProbability: Double,
        membersWet: Int,
        membersTotal: Int,
        amountMedian: Double?,
        amountP90: Double?,
        windMedianMax: Double?,
        gustsP90: Double?,
        cloudCover: Double?,
        steps: Int,
        partial: Bool,
        rating: String,
        points: Int,
        ecmwfAgrees: Bool? = nil
    ) {
        self.date = date
        self.highMedian = highMedian
        self.highP10 = highP10
        self.highP90 = highP90
        self.lowMedian = lowMedian
        self.lowP10 = lowP10
        self.lowP90 = lowP90
        self.spread = spread
        self.rainProbability = rainProbability
        self.membersWet = membersWet
        self.membersTotal = membersTotal
        self.amountMedian = amountMedian
        self.amountP90 = amountP90
        self.windMedianMax = windMedianMax
        self.gustsP90 = gustsP90
        self.cloudCover = cloudCover
        self.steps = steps
        self.partial = partial
        self.rating = rating
        self.points = points
        self.ecmwfAgrees = ecmwfAgrees
    }

    public var sky: String {
        guard let cloudCover else { return "—" }
        if cloudCover < cloudSunnyMax { return "Sunny" }
        if cloudCover <= cloudPartlyMax { return "Partly" }
        return "Cloudy"
    }

    /// Filled dots on the five-dot rain scale.
    public var rainDots: Int {
        switch rainProbability {
        case ..<0.10: 0
        case ..<0.30: 1
        case ..<0.50: 2
        case ..<0.70: 3
        case ..<0.90: 4
        default: 5
        }
    }

    enum CodingKeys: String, CodingKey {
        case date
        case highMedian = "high_median"
        case highP10 = "high_p10"
        case highP90 = "high_p90"
        case lowMedian = "low_median"
        case lowP10 = "low_p10"
        case lowP90 = "low_p90"
        case spread
        case rainProbability = "rain_probability"
        case membersWet = "members_wet"
        case membersTotal = "members_total"
        case amountMedian = "amount_median"
        case amountP90 = "amount_p90"
        case windMedianMax = "wind_median_max"
        case gustsP90 = "gusts_p90"
        case cloudCover = "cloud_cover"
        case steps
        case partial
        case rating
        case points
        case ecmwfAgrees = "ecmwf_agrees"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(date, forKey: .date)
        try container.encode(highMedian, forKey: .highMedian)
        try container.encode(highP10, forKey: .highP10)
        try container.encode(highP90, forKey: .highP90)
        try container.encode(lowMedian, forKey: .lowMedian)
        try container.encode(lowP10, forKey: .lowP10)
        try container.encode(lowP90, forKey: .lowP90)
        try container.encode(spread, forKey: .spread)
        try container.encode(rainProbability, forKey: .rainProbability)
        try container.encode(membersWet, forKey: .membersWet)
        try container.encode(membersTotal, forKey: .membersTotal)
        try container.encode(amountMedian, forKey: .amountMedian)
        try container.encode(amountP90, forKey: .amountP90)
        try container.encode(windMedianMax, forKey: .windMedianMax)
        try container.encode(gustsP90, forKey: .gustsP90)
        try container.encode(cloudCover, forKey: .cloudCover)
        try container.encode(steps, forKey: .steps)
        try container.encode(partial, forKey: .partial)
        try container.encode(rating, forKey: .rating)
        try container.encode(points, forKey: .points)
        try container.encode(ecmwfAgrees, forKey: .ecmwfAgrees)
    }
}
