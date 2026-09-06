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
                        Text("\(today.rating.capitalized) confidence")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
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

            HStack(spacing: 6) {
                ForEach(Array(days.dropFirst().enumerated()), id: \.element.date) { index, day in
                    if index > 0 {
                        Divider()
                            .padding(.vertical, 2)
                    }
                    SmallSecondaryDayView(day: day, entry: entry)
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

private struct SmallSecondaryDayView: View {
    let day: DaySummary
    let entry: WeatherEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(dayLabel)
                    .font(.caption.weight(.semibold))
                Spacer(minLength: 2)
                Image(systemName: weatherSymbol)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(weatherColor)
                    .imageScale(.small)
                    .widgetAccentable()
            }

            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text("\(Int(day.highMedian.rounded()))°")
                    .font(.callout.weight(.bold))
                    .monospacedDigit()
                Text("\(Int(day.lowMedian.rounded()))°")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer(minLength: 0)
            }

            if day.rainProbability >= 0.20 {
                Label(
                    "\(Int((day.rainProbability * 100).rounded()))%",
                    systemImage: "drop.fill"
                )
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(dayLabel), high \(Int(day.highMedian.rounded()))"
                + "\(entry.units.coreUnits.tempSymbol), low \(Int(day.lowMedian.rounded()))"
                + "\(entry.units.coreUnits.tempSymbol), "
                + "\(Int((day.rainProbability * 100).rounded())) percent chance of rain, "
                + day.confidenceAccessibilityLabel
        )
    }

    private var weatherSymbol: String {
        if day.rainProbability >= 0.65 { return "cloud.heavyrain.fill" }
        if day.rainProbability >= 0.30 { return "cloud.rain.fill" }
        guard let cloudCover = day.cloudCover else { return "cloud.sun.fill" }
        if cloudCover < 30 { return "sun.max.fill" }
        if cloudCover <= 70 { return "cloud.sun.fill" }
        return "cloud.fill"
    }

    private var weatherColor: Color {
        if day.rainProbability >= 0.30 { return .blue }
        if (day.cloudCover ?? 50) < 30 { return .orange }
        return .secondary
    }

    private var dayLabel: String {
        guard let dayDate = date(from: day.date) else { return day.date }
        return dayDate.formatted(
            Date.FormatStyle(locale: Locale(identifier: "en_US"), timeZone: entry.timeZone)
                .weekday(.abbreviated)
        )
    }

    private func date(from value: String) -> Date? {
        let fields = value.split(separator: "-").compactMap { Int($0) }
        guard fields.count == 3 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = entry.timeZone
        return calendar.date(from: DateComponents(
            timeZone: entry.timeZone,
            year: fields[0],
            month: fields[1],
            day: fields[2],
            hour: 12
        ))
    }
}

private extension DaySummary {
    var confidenceAccessibilityLabel: String {
        switch rating.lowercased() {
        case "high": "high confidence"
        case "medium": "medium confidence"
        default: "low confidence"
        }
    }
}
