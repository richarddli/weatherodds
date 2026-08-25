import SwiftUI
import WidgetKit

struct WeatherOddsWidgetView: View {
    @Environment(\.widgetFamily) private var family

    let entry: WeatherEntry

    var body: some View {
        Group {
            switch entry.availability {
            case .unconfigured:
                WidgetMessageView(
                    systemImage: "location.viewfinder",
                    title: "Choose a zip code",
                    message: "Edit this widget to enter a five-digit US zip code."
                )
            case .invalidConfiguration(let message):
                WidgetMessageView(
                    systemImage: "exclamationmark.circle",
                    title: "Check the zip code",
                    message: message
                )
            case .unavailable(let message):
                WidgetMessageView(
                    systemImage: "wifi.exclamationmark",
                    title: "Forecast unavailable",
                    message: "\(message) No saved forecast is available yet."
                )
            case .preview, .fresh, .stale:
                if entry.visibleDays.isEmpty {
                    WidgetMessageView(
                        systemImage: "calendar.badge.exclamationmark",
                        title: "No upcoming days",
                        message: "The saved forecast has ended. A new update will be requested."
                    )
                } else {
                    forecastContent
                }
            }
        }
        .fontDesign(.rounded)
        .containerBackground(for: .widget) {
            LinearGradient(
                colors: [Color.accentColor.opacity(0.14), Color.clear],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .background(.background)
        }
    }

    @ViewBuilder
    private var forecastContent: some View {
        switch family {
        case .systemSmall:
            SmallForecastView(entry: entry)
        case .systemMedium:
            MultiDayForecastView(
                entry: entry,
                dayCount: 5,
                columns: 5,
                density: .compact
            )
        case .systemLarge:
            MultiDayForecastView(
                entry: entry,
                dayCount: 10,
                columns: 5,
                density: .regular
            )
        case .systemExtraLarge:
            MultiDayForecastView(
                entry: entry,
                dayCount: 15,
                columns: 5,
                density: .regular
            )
        default:
            MultiDayForecastView(
                entry: entry,
                dayCount: 5,
                columns: 5,
                density: .compact
            )
        }
    }
}

private struct WidgetMessageView: View {
    let systemImage: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.title)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .widgetAccentable()
            Text(title)
                .font(.headline)
                .multilineTextAlignment(.center)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
        .accessibilityElement(children: .combine)
    }
}
