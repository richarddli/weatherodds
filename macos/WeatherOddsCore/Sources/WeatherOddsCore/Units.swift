/// Display units plus the thresholds that are expressed in those units.
///
/// Mirrors `weatherodds.summarize.Units`. Any change to these numbers must be
/// made on both sides and the conformance reference regenerated.
public struct Units: Sendable, Equatable {
    public let name: String
    public let tempSymbol: String     // "°F"
    public let windLabel: String      // "mph"
    public let precipLabel: String    // "in"
    public let wetThreshold: Double   // daily total that counts a member as "wet"
    public let spreadHigh: Double     // <= this spread scores 2 points
    public let spreadMedium: Double   // <= this spread scores 1 point
    public let agreeTemp: Double      // ECMWF median-high tolerance
    public let gustNotable: Double    // gusts worth printing next to sustained wind
    public let distanceLabel: String

    public static let imperial = Units(
        name: "imperial",
        tempSymbol: "°F",
        windLabel: "mph",
        precipLabel: "in",
        wetThreshold: 0.04,
        spreadHigh: 5.0,
        spreadMedium: 10.0,
        agreeTemp: 4.0,
        gustNotable: 30.0,
        distanceLabel: "mi"
    )

    public static let metric = Units(
        name: "metric",
        tempSymbol: "°C",
        windLabel: "km/h",
        precipLabel: "mm",
        wetThreshold: 1.0,
        spreadHigh: 2.8,
        spreadMedium: 5.6,
        agreeTemp: 2.2,
        gustNotable: 50.0,
        distanceLabel: "km"
    )

    public static func named(_ name: String) -> Units? {
        switch name {
        case "imperial": return .imperial
        case "metric": return .metric
        default: return nil
        }
    }
}

/// Percentage-point agreement window for the ECMWF rain-probability check.
public let rainProbTolerance = 0.20

let cloudSunnyMax = 30.0
let cloudPartlyMax = 70.0

/// Matches Python's `EPS`, used to keep the wet-threshold comparison from
/// tripping on representation error at the boundary.
let eps = 1e-9
