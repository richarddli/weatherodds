import SwiftUI
import WidgetKit

@main
struct WeatherOddsWidget: Widget {
    static let kind = "com.polarsky.weatherodds.forecast"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: Self.kind,
            intent: WeatherConfigurationIntent.self,
            provider: WeatherTimelineProvider()
        ) { entry in
            WeatherOddsWidgetView(entry: entry)
        }
        .configurationDisplayName("Weather Odds")
        .description("See a 15-day ensemble forecast and how confident it is.")
        .supportedFamilies([
            .systemSmall,
            .systemMedium,
            .systemLarge,
            .systemExtraLarge,
        ])
        .contentMarginsDisabled()
        .containerBackgroundRemovable(true)
    }
}

#Preview("Small", as: .systemSmall) {
    WeatherOddsWidget()
} timeline: {
    WeatherEntry.canned()
}

#Preview("Medium", as: .systemMedium) {
    WeatherOddsWidget()
} timeline: {
    WeatherEntry.canned()
}

#Preview("Large", as: .systemLarge) {
    WeatherOddsWidget()
} timeline: {
    WeatherEntry.canned()
}

#Preview("Extra Large", as: .systemExtraLarge) {
    WeatherOddsWidget()
} timeline: {
    WeatherEntry.canned()
}

#Preview("Stale and degraded", as: .systemMedium) {
    WeatherOddsWidget()
} timeline: {
    let sample = WeatherEntry.canned()
    WeatherEntry(
        date: sample.date,
        availability: .stale,
        locationName: sample.locationName,
        days: sample.days,
        units: sample.units,
        fetchedAt: sample.date.addingTimeInterval(-5 * 60 * 60),
        ecmwfContributed: false,
        timeZoneIdentifier: sample.timeZoneIdentifier,
        utcOffsetSeconds: sample.utcOffsetSeconds
    )
}
