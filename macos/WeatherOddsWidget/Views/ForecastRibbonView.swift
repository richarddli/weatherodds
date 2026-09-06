import SwiftUI
import WeatherOddsCore

struct ForecastRibbonView: View {
    enum Density {
        case compact
        case standard
        case detailed

        var dayCount: Int {
            switch self {
            case .compact: 5
            case .standard: 10
            case .detailed: 15
            }
        }

        var spacing: CGFloat { self == .compact ? 4 : 6 }
        var padding: CGFloat { self == .compact ? 10 : 12 }
        var leadingInset: CGFloat { self == .compact ? 4 : 24 }
        var legendFontSize: CGFloat { self == .detailed ? 11 : 10 }
        var temperatureFontSize: CGFloat {
            switch self {
            case .compact: 9
            case .standard: 10
            case .detailed: 11
            }
        }
        var lowTemperatureFontSize: CGFloat {
            switch self {
            case .compact: 9
            case .standard, .detailed: 10
            }
        }
        var axisFontSize: CGFloat { self == .detailed ? 10 : 9 }
        var rainTitleFontSize: CGFloat { self == .compact ? 10 : 11 }
        var rainLabelFontSize: CGFloat { self == .compact ? 9 : 10 }
        var dayFontSize: CGFloat { 10 }
        var footerFontSize: CGFloat { self == .detailed ? 10 : 9 }
        var rainHeight: CGFloat {
            switch self {
            case .compact: 32
            case .standard: 44
            case .detailed: 48
            }
        }
        var showsLegend: Bool { self != .compact }
        var showsAxisLabels: Bool { self != .compact }
        var showsRainExplanation: Bool { self == .detailed }
        var showsFooter: Bool { self != .compact }
    }

    let entry: WeatherEntry
    let density: Density

    private var days: [DaySummary] {
        Array(entry.visibleDays.prefix(density.dayCount))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: density.spacing) {
            ForecastHeaderView(entry: entry)

            if density.showsLegend {
                HStack(spacing: density == .detailed ? 12 : 7) {
                    RibbonLegendSwatch(style: .dailyRange)
                    Text(density == .detailed ? "Expected daily range" : "Daily range")
                    RibbonLegendSwatch(style: .ensembleRange)
                    Text(density == .detailed ? "P10–P90 ensemble range" : "P10–P90")
                    Spacer(minLength: 4)
                    Text(entry.units.coreUnits.tempSymbol)
                        .monospacedDigit()
                }
                .font(.system(size: density.legendFontSize, weight: .semibold))
                .foregroundStyle(.primary.opacity(0.76))
                .accessibilityElement(children: .combine)
            }

            TemperatureRibbonChart(
                days: days,
                units: entry.units.coreUnits,
                leadingInset: density.leadingInset,
                showsAxisLabels: density.showsAxisLabels,
                labelFontSize: density.temperatureFontSize,
                lowLabelFontSize: density.lowTemperatureFontSize,
                axisFontSize: density.axisFontSize
            )
                .frame(maxHeight: .infinity)

            HStack(alignment: .firstTextBaseline) {
                Text("Rain chance")
                    .font(.system(size: density.rainTitleFontSize, weight: .bold))
                Spacer()
                if density.showsRainExplanation {
                    Text("Probability across 64 ensemble members")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.primary.opacity(0.62))
                }
            }

            RainProbabilityChart(
                days: days,
                units: entry.units.coreUnits,
                leadingInset: density.leadingInset,
                labelFontSize: density.rainLabelFontSize
            )
                .frame(height: density.rainHeight)

            ForecastDayAxis(
                days: days,
                entry: entry,
                leadingInset: density.leadingInset,
                fontSize: density.dayFontSize,
                showsPartialMarker: density.showsFooter
            )

            if density.showsFooter {
                HStack(spacing: 6) {
                    if days.contains(where: \.partial) {
                        Text("* partial day")
                    }
                    if days.contains(where: { $0.ecmwfAgrees == false }) {
                        Label("ECMWF differs", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                    Spacer(minLength: 4)
                    Text("Forecast data via Open-Meteo")
                }
                .font(.system(size: density.footerFontSize, weight: .medium))
                .foregroundStyle(.primary.opacity(0.58))
                .lineLimit(1)
            }
        }
        .padding(density.padding)
    }
}

private struct TemperatureRibbonChart: View {
    let days: [DaySummary]
    let units: Units
    let leadingInset: CGFloat
    let showsAxisLabels: Bool
    let labelFontSize: CGFloat
    let lowLabelFontSize: CGFloat
    let axisFontSize: CGFloat

    var body: some View {
        Canvas { context, size in
            guard !days.isEmpty else { return }

            let plot = ChartGeometry(
                size: size,
                days: days,
                units: units,
                leadingInset: leadingInset
            )
            drawGrid(in: &context, plot: plot)

            let ensembleBand = plot.bandPath(
                upper: { $0.highP90 },
                lower: { $0.lowP10 }
            )
            context.fill(
                ensembleBand,
                with: .color(.secondary.opacity(0.22))
            )

            let expectedBand = plot.bandPath(
                upper: { $0.highMedian },
                lower: { $0.lowMedian }
            )
            context.fill(
                expectedBand,
                with: .linearGradient(
                    Gradient(colors: [
                        .orange.opacity(0.68),
                        .blue.opacity(0.45),
                    ]),
                    startPoint: CGPoint(x: 0, y: plot.plotTop),
                    endPoint: CGPoint(x: 0, y: plot.plotBottom)
                )
            )

            context.stroke(
                plot.linePath(value: { $0.highMedian }),
                with: .color(.orange.opacity(0.9)),
                lineWidth: 1.25
            )
            context.stroke(
                plot.linePath(value: { $0.lowMedian }),
                with: .color(.blue.opacity(0.85)),
                lineWidth: 1.25
            )

            drawTemperatureLabels(in: &context, plot: plot)
            drawDisagreementMarkers(in: &context, plot: plot)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(days.count)-day temperature range")
        .accessibilityValue(temperatureAccessibilityValue)
    }

    private func drawGrid(in context: inout GraphicsContext, plot: ChartGeometry) {
        for fraction in [0.0, 0.5, 1.0] {
            let y = plot.plotTop + plot.plotHeight * fraction
            var line = Path()
            line.move(to: CGPoint(x: plot.plotLeft, y: y))
            line.addLine(to: CGPoint(x: plot.plotRight, y: y))
            context.stroke(
                line,
                with: .color(.secondary.opacity(fraction == 0.5 ? 0.14 : 0.08)),
                style: StrokeStyle(lineWidth: 0.5, dash: [2, 3])
            )
        }

        if showsAxisLabels {
            drawAxisLabel(
                Int(plot.upperBound.rounded()),
                y: plot.plotTop,
                in: &context
            )
            drawAxisLabel(
                Int(plot.lowerBound.rounded()),
                y: plot.plotBottom,
                in: &context
            )
        }
    }

    private func drawAxisLabel(
        _ value: Int,
        y: CGFloat,
        in context: inout GraphicsContext
    ) {
        let label = context.resolve(
            Text("\(value)°")
                .font(.system(size: axisFontSize, weight: .medium))
                .foregroundStyle(.primary.opacity(0.62))
        )
        context.draw(label, at: CGPoint(x: 0, y: y), anchor: .leading)
    }

    private func drawTemperatureLabels(
        in context: inout GraphicsContext,
        plot: ChartGeometry
    ) {
        for (index, day) in days.enumerated() {
            let x = plot.x(for: index)
            let high = context.resolve(
                Text("\(Int(day.highMedian.rounded()))°")
                    .font(.system(
                        size: labelFontSize,
                        weight: .bold,
                        design: .rounded
                    ))
                    .foregroundStyle(.primary)
            )
            let low = context.resolve(
                Text("\(Int(day.lowMedian.rounded()))°")
                    .font(.system(
                        size: lowLabelFontSize,
                        weight: .semibold,
                        design: .rounded
                    ))
                    .foregroundStyle(.primary.opacity(0.76))
            )
            context.draw(
                high,
                at: CGPoint(x: x, y: plot.y(for: day.highMedian) - 2),
                anchor: .bottom
            )
            context.draw(
                low,
                at: CGPoint(x: x, y: plot.y(for: day.lowMedian) + 2),
                anchor: .top
            )
        }
    }

    private func drawDisagreementMarkers(
        in context: inout GraphicsContext,
        plot: ChartGeometry
    ) {
        for (index, day) in days.enumerated() where day.ecmwfAgrees == false {
            let x = plot.x(for: index)
            var marker = context.resolve(Image(systemName: "exclamationmark.triangle.fill"))
            marker.shading = .color(.orange)
            context.draw(
                marker,
                at: CGPoint(x: x, y: plot.plotTop + 7),
                anchor: .center
            )
        }
    }

    private var temperatureAccessibilityValue: String {
        days.map { day in
            var value = "\(day.date), high \(Int(day.highMedian.rounded())) degrees, "
                + "low \(Int(day.lowMedian.rounded())) degrees, "
                + "ensemble range \(Int(day.lowP10.rounded())) to "
                + "\(Int(day.highP90.rounded())) degrees \(spokenTemperatureUnit), "
                + "\(day.rating.lowercased()) confidence"
            if day.partial {
                value += ", partial day"
            }
            if day.ecmwfAgrees == false {
                value += ", ECMWF differs"
            }
            return value
        }
        .joined(separator: "; ")
    }

    private var spokenTemperatureUnit: String {
        units == .metric ? "Celsius" : "Fahrenheit"
    }
}

private struct RainProbabilityChart: View {
    let days: [DaySummary]
    let units: Units
    let leadingInset: CGFloat
    let labelFontSize: CGFloat

    var body: some View {
        Canvas { context, size in
            guard !days.isEmpty else { return }

            let rightInset: CGFloat = 4
            let topInset = labelFontSize + 4
            let bottomInset: CGFloat = 1
            let plotWidth = max(1, size.width - leadingInset - rightInset)
            let plotHeight = max(1, size.height - topInset - bottomInset)
            let step = plotWidth / CGFloat(days.count)
            let baseline = topInset + plotHeight

            var baseLine = Path()
            baseLine.move(to: CGPoint(x: leadingInset, y: baseline))
            baseLine.addLine(to: CGPoint(x: size.width - rightInset, y: baseline))
            context.stroke(baseLine, with: .color(.secondary.opacity(0.16)), lineWidth: 0.5)

            for (index, day) in days.enumerated() {
                let probability = min(1, max(0, day.rainProbability))
                let x = leadingInset + (CGFloat(index) + 0.5) * step
                let barHeight = max(probability > 0 ? 1 : 0, plotHeight * probability)
                let width = min(16, step * 0.46)
                let rect = CGRect(
                    x: x - width / 2,
                    y: baseline - barHeight,
                    width: width,
                    height: barHeight
                )
                context.fill(
                    Path(roundedRect: rect, cornerRadius: min(3, width / 3)),
                    with: .color(.blue.opacity(0.28 + probability * 0.62))
                )

                if probability >= 0.20 {
                    let label = context.resolve(
                        Text("\(Int((probability * 100).rounded()))%")
                            .font(.system(
                                size: labelFontSize,
                                weight: .bold,
                                design: .rounded
                            ))
                            .foregroundStyle(.primary.opacity(0.82))
                    )
                    context.draw(
                        label,
                        at: CGPoint(x: x, y: baseline - barHeight - 1),
                        anchor: .bottom
                    )
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Daily rain probability")
        .accessibilityValue(rainAccessibilityValue)
    }

    private var rainAccessibilityValue: String {
        days.map { day in
            var result = "\(day.date), \(Int((day.rainProbability * 100).rounded())) percent"
            if let amount = day.amountMedian {
                result += ", median amount when wet \(formatAmount(amount))"
            }
            return result
        }
        .joined(separator: "; ")
    }

    private func formatAmount(_ amount: Double) -> String {
        if units == .metric {
            return "\(amount.formatted(.number.precision(.fractionLength(0...1)))) millimeters"
        }
        return "\(amount.formatted(.number.precision(.fractionLength(0...2)))) inches"
    }
}

private struct ForecastDayAxis: View {
    let days: [DaySummary]
    let entry: WeatherEntry
    let leadingInset: CGFloat
    let fontSize: CGFloat
    let showsPartialMarker: Bool

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(days.enumerated()), id: \.element.date) { index, day in
                Text(label(for: day, index: index))
                    .font(.system(size: fontSize, weight: index == 0 ? .bold : .medium))
                    .foregroundStyle(Color.primary.opacity(index == 0 ? 1 : 0.78))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.leading, leadingInset)
        .padding(.trailing, 4)
        .accessibilityHidden(true)
    }

    private func label(for day: DaySummary, index: Int) -> String {
        guard let date = date(from: day.date) else { return day.date }
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US")
        calendar.timeZone = entry.timeZone
        let dayNumber = calendar.component(.day, from: date)
        let weekday = date.formatted(
            Date.FormatStyle(locale: Locale(identifier: "en_US"), timeZone: entry.timeZone)
                .weekday(.narrow)
        )
        let base = index == 0 ? "Now" : "\(weekday) \(dayNumber)"
        return day.partial && showsPartialMarker ? "\(base)*" : base
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

private struct ChartGeometry {
    let size: CGSize
    let days: [DaySummary]
    let lowerBound: Double
    let upperBound: Double

    let plotLeft: CGFloat
    let plotTop: CGFloat = 12
    let plotBottomInset: CGFloat = 12
    let plotRightInset: CGFloat = 4

    init(size: CGSize, days: [DaySummary], units: Units, leadingInset: CGFloat) {
        self.size = size
        self.days = days
        plotLeft = leadingInset

        let domain = ForecastChartDomain(days: days, units: units)
        lowerBound = domain?.lowerBound ?? 0
        upperBound = domain?.upperBound ?? 1
    }

    var plotRight: CGFloat { size.width - plotRightInset }
    var plotBottom: CGFloat { size.height - plotBottomInset }
    var plotWidth: CGFloat { max(1, plotRight - plotLeft) }
    var plotHeight: CGFloat { max(1, plotBottom - plotTop) }

    func x(for index: Int) -> CGFloat {
        plotLeft + (CGFloat(index) + 0.5) * plotWidth / CGFloat(max(1, days.count))
    }

    func y(for value: Double) -> CGFloat {
        let fraction = (upperBound - value) / max(1, upperBound - lowerBound)
        return plotTop + CGFloat(fraction) * plotHeight
    }

    func linePath(value: (DaySummary) -> Double) -> Path {
        var path = Path()
        if days.count == 1, let day = days.first {
            let y = y(for: value(day))
            path.move(to: CGPoint(x: plotLeft, y: y))
            path.addLine(to: CGPoint(x: plotRight, y: y))
            return path
        }
        for (index, day) in days.enumerated() {
            let point = CGPoint(x: x(for: index), y: y(for: value(day)))
            if index == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }
        return path
    }

    func bandPath(
        upper: (DaySummary) -> Double,
        lower: (DaySummary) -> Double
    ) -> Path {
        if days.count == 1, let day = days.first {
            let top = y(for: upper(day))
            return Path(CGRect(
                x: plotLeft,
                y: top,
                width: plotWidth,
                height: max(0, y(for: lower(day)) - top)
            ))
        }
        var path = Path()
        for (index, day) in days.enumerated() {
            let point = CGPoint(x: x(for: index), y: y(for: upper(day)))
            if index == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }
        for index in days.indices.reversed() {
            let point = CGPoint(x: x(for: index), y: y(for: lower(days[index])))
            path.addLine(to: point)
        }
        path.closeSubpath()
        return path
    }
}

private struct RibbonLegendSwatch: View {
    enum Style {
        case dailyRange
        case ensembleRange
    }

    let style: Style

    var body: some View {
        Capsule()
            .fill(fill)
            .frame(width: 16, height: style == .dailyRange ? 5 : 8)
            .overlay {
                if style == .dailyRange {
                    Capsule().stroke(.orange.opacity(0.65), lineWidth: 0.5)
                }
            }
            .accessibilityHidden(true)
    }

    private var fill: AnyShapeStyle {
        switch style {
        case .dailyRange:
            AnyShapeStyle(
                LinearGradient(
                    colors: [.orange.opacity(0.55), .blue.opacity(0.35)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
        case .ensembleRange:
            AnyShapeStyle(Color.secondary.opacity(0.24))
        }
    }
}
