import SwiftUI
import WeatherOddsCore

struct ConfidenceView: View {
    let rating: String
    var includesWord = false

    private var filledDots: Int {
        switch rating.lowercased() {
        case "high": 3
        case "medium": 2
        default: 1
        }
    }

    private var color: Color {
        switch rating.lowercased() {
        case "high": .green
        case "medium": .orange
        default: .red
        }
    }

    private var spokenRating: String {
        switch rating.lowercased() {
        case "high": "High confidence"
        case "medium": "Medium confidence"
        default: "Low confidence"
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            Text((0..<3).map { $0 < filledDots ? "●" : "○" }.joined())
                .font(.caption2.monospaced())
                .foregroundStyle(color)
                .widgetAccentable()

            if includesWord {
                Text(rating.capitalized)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenRating)
    }
}

extension DaySummary {
    var confidenceAccessibilityLabel: String {
        switch rating.lowercased() {
        case "high": "high confidence"
        case "medium": "medium confidence"
        default: "low confidence"
        }
    }
}
