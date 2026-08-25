import SwiftUI
import WeatherOddsCore
import WidgetKit

struct SmallForecastView: View {
    let entry: WeatherEntry

    var body: some View {
        let days = Array(entry.visibleDays.prefix(3))
        VStack(alignment: .leading, spacing: 7) {
            compactHeader
            if let today = days.first {
                HStack(alignment: .center, spacing: 8) {
                    Image(systemName: heroSymbol(for: today))
                        .font(.title2)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(today.rainProbability >= 0.3 ? .blue : .orange)
                        .widgetAccentable()
                    VStack(alignment: .leading, spacing: 0) {
                        Text("\(Int(today.highMedian.rounded()))°")
                            .font(.system(size: 31, weight: .bold, design: .rounded))
                            .monospacedDigit()
                        Text("Low \(Int(today.lowMedian.rounded()))°")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    VStack(alignment: .trailing, spacing: 3) {
                        ConfidenceView(rating: today.rating, includesWord: true)
                        Label(
                            "\(Int((today.rainProbability * 100).rounded()))%",
                            systemImage: "drop.fill"
                        )
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(
                    "Today, high \(Int(today.highMedian.rounded()))\(entry.units.coreUnits.tempSymbol), "
                        + "low \(Int(today.lowMedian.rounded()))\(entry.units.coreUnits.tempSymbol), "
                        + "\(Int((today.rainProbability * 100).rounded())) percent chance of rain, "
                        + today.confidenceAccessibilityLabel
                )
            }

            HStack(spacing: 5) {
                ForEach(Array(days.dropFirst().enumerated()), id: \.offset) { _, day in
                    ForecastDayView(day: day, entry: entry, density: .compact)
                }
            }
        }
    }

    private var compactHeader: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(entry.locationName ?? "Weather Odds")
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }

            if entry.availability == .stale || entry.isDegraded {
                HStack(spacing: 6) {
                    if entry.availability == .stale {
                        Text(staleText)
                    }
                    if entry.isDegraded {
                        Label("WeatherNext only", systemImage: "exclamationmark.triangle")
                            .accessibilityLabel(
                                "WeatherNext only. ECMWF comparison is unavailable."
                            )
                    }
                }
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        }
    }

    private var staleText: String {
        let hours = Int((entry.staleAge ?? 0) / 3600)
        return hours < 1 ? "Updated <1h ago" : "Updated \(hours)h ago"
    }

    private func heroSymbol(for day: DaySummary) -> String {
        if day.rainProbability >= 0.65 { return "cloud.heavyrain.fill" }
        if day.rainProbability >= 0.30 { return "cloud.rain.fill" }
        if (day.cloudCover ?? 50) < 30 { return "sun.max.fill" }
        return "cloud.sun.fill"
    }
}

struct MultiDayForecastView: View {
    let entry: WeatherEntry
    let dayCount: Int
    let columns: Int
    let density: ForecastDayView.Density

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForecastHeaderView(entry: entry)
            LazyVGrid(
                columns: Array(
                    repeating: GridItem(.flexible(minimum: 40), spacing: 6),
                    count: columns
                ),
                spacing: 6
            ) {
                ForEach(Array(entry.visibleDays.prefix(dayCount)), id: \.date) { day in
                    ForecastDayView(day: day, entry: entry, density: density)
                }
            }
            Spacer(minLength: 0)
            HStack {
                Text("Forecast data via Open-Meteo")
                Spacer()
                Text("Confidence: ensemble spread + ECMWF")
            }
            .font(.system(size: 8))
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Forecast data via Open-Meteo")
        }
    }
}
