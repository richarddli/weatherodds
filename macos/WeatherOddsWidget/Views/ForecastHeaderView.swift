import SwiftUI

struct ForecastHeaderView: View {
    let entry: WeatherEntry

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.locationName ?? "Weather Odds")
                    .font(.headline)
                    .lineLimit(1)
                Text("WeatherNext 2 ensemble")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            HStack(spacing: 5) {
                if entry.availability == .stale {
                    StatusPill(
                        text: staleText,
                        systemImage: "clock.arrow.circlepath",
                        accessibilityText: staleAccessibilityText
                    )
                }
                if entry.isDegraded {
                    StatusPill(
                        text: "WeatherNext only",
                        systemImage: "exclamationmark.triangle",
                        accessibilityText: "WeatherNext only. ECMWF comparison is unavailable."
                    )
                }
            }
        }
    }

    private var staleText: String {
        guard let age = entry.staleAge else { return "Saved" }
        let hours = Int(age / 3600)
        if hours < 1 { return "Updated <1h ago" }
        return "Updated \(hours)h ago"
    }

    private var staleAccessibilityText: String {
        guard let age = entry.staleAge else { return "Showing a saved forecast" }
        let hours = Int(age / 3600)
        if hours < 1 { return "Showing a saved forecast updated less than one hour ago" }
        if hours == 1 { return "Showing a saved forecast updated one hour ago" }
        return "Showing a saved forecast updated \(hours) hours ago"
    }
}

private struct StatusPill: View {
    let text: String
    let systemImage: String
    let accessibilityText: String

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.system(size: 9, weight: .semibold))
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(.quaternary, in: .capsule)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityText)
    }
}
