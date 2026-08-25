import AppIntents
import Foundation
import WeatherOddsCore
import WidgetKit

enum UnitChoice: String, AppEnum, Sendable {
    case imperial
    case metric

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Units")
    static let caseDisplayRepresentations: [UnitChoice: DisplayRepresentation] = [
        .imperial: "Imperial (°F, mph, in)",
        .metric: "Metric (°C, km/h, mm)",
    ]

    var coreUnits: Units {
        switch self {
        case .imperial: .imperial
        case .metric: .metric
        }
    }
}

struct WeatherConfigurationIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Weather Odds"
    static let description = IntentDescription(
        "Choose the US zip code and units for this widget."
    )

    @Parameter(title: "US zip code")
    var zipCode: String?

    @Parameter(title: "Units")
    var units: UnitChoice?

    var effectiveUnits: UnitChoice {
        units ?? (Locale.current.measurementSystem == .metric ? .metric : .imperial)
    }

    init() {
        units = Locale.current.measurementSystem == .metric ? .metric : .imperial
    }

    init(zipCode: String?, units: UnitChoice?) {
        self.zipCode = zipCode
        self.units = units
    }
}
