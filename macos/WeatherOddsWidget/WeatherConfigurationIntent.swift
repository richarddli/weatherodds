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
        "Search for a city or postal code and choose your units."
    )

    @Parameter(title: "Location")
    var location: WeatherLocationEntity?

    // Retain the parameter identifier for previously installed widgets.
    @Parameter(title: "US ZIP (used when Location is empty)")
    var zipCode: String?

    @Parameter(title: "Units")
    var units: UnitChoice?

    static var parameterSummary: some ParameterSummary {
        Summary {
            \.$location
            \.$units
        }
    }

    func configuredLocationID() throws -> LocationID? {
        try LocationID.configured(selected: location?.place.id, legacyZip: zipCode)
    }

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

/// One shared cache keeps entity restoration and timeline refreshes in agreement.
enum WidgetLocations {
    static let cache = WeatherOddsCache()
    static let search = LocationSearch(cache: cache)
}

struct WeatherLocationEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Location")
    static let defaultQuery = WeatherLocationQuery()

    let place: Location
    var id: String { place.id.rawValue }
    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(place.displayName)")
    }
}

struct WeatherLocationQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [WeatherLocationEntity] {
        var entities: [WeatherLocationEntity] = []
        for value in identifiers {
            guard let id = try? LocationID(value) else { continue }
            let place = try await WidgetLocations.search.location(for: id)
            entities.append(WeatherLocationEntity(place: place))
        }
        return entities
    }

    func entities(matching string: String) async throws -> [WeatherLocationEntity] {
        try await WidgetLocations.search.search(string).map { WeatherLocationEntity(place: $0) }
    }

    func suggestedEntities() async throws -> [WeatherLocationEntity] {
        await WidgetLocations.cache.suggestedLocations().prefix(10).map {
            WeatherLocationEntity(place: $0)
        }
    }
}
