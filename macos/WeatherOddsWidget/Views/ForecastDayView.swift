import SwiftUI
import WeatherOddsCore

struct ForecastDayView: View {
    enum Density {
        case compact
        case regular
    }

    let day: DaySummary
    let entry: WeatherEntry
    var density: Density = .regular

    private var unitSymbol: String { entry.units.coreUnits.tempSymbol }

    var body: some View {
        VStack(alignment: .leading, spacing: density == .compact ? 3 : 5) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(dayLabel)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if day.partial {
                    Text("Partial")
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }

            HStack(alignment: .center, spacing: 5) {
                Image(systemName: weatherSymbol)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(weatherColor)
                    .widgetAccentable()
                    .imageScale(density == .compact ? .small : .medium)

                Text("\(rounded(day.highMedian))°")
                    .font(density == .compact ? .callout.weight(.bold) : .title3.weight(.bold))
                    .monospacedDigit()
                Text("\(rounded(day.lowMedian))°")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            HStack(spacing: 5) {
                Label("\(Int((day.rainProbability * 100).rounded()))%", systemImage: "drop.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                ConfidenceView(rating: day.rating)
            }

            if density == .regular, let wind = day.windMedianMax {
                Text("Wind \(rounded(wind)) \(entry.units.coreUnits.windLabel)")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(density == .compact ? 6 : 8)
        .background(.quaternary.opacity(0.45), in: .rect(cornerRadius: 10))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
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
        guard let dayDate = Self.date(from: day.date, timeZone: entry.timeZone) else {
            return day.date
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = entry.timeZone
        if calendar.isDate(dayDate, inSameDayAs: entry.date) {
            return "Today"
        }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: entry.date),
           calendar.isDate(dayDate, inSameDayAs: tomorrow)
        {
            return "Tomorrow"
        }
        return dayDate.formatted(
            .dateTime.weekday(.abbreviated).locale(Locale(identifier: "en_US"))
        )
    }

    private var accessibilityText: String {
        var pieces = [
            dayLabel,
            "high \(rounded(day.highMedian))\(unitSymbol)",
            "low \(rounded(day.lowMedian))\(unitSymbol)",
            "\(Int((day.rainProbability * 100).rounded())) percent chance of rain",
            day.confidenceAccessibilityLabel,
        ]
        if day.partial { pieces.append("partial day") }
        return pieces.joined(separator: ", ")
    }

    private func rounded(_ value: Double) -> Int {
        Int(value.rounded())
    }

    private static func date(from value: String, timeZone: TimeZone) -> Date? {
        let fields = value.split(separator: "-").compactMap { Int($0) }
        guard fields.count == 3 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.date(from: DateComponents(
            timeZone: timeZone,
            year: fields[0],
            month: fields[1],
            day: fields[2],
            hour: 12
        ))
    }
}
