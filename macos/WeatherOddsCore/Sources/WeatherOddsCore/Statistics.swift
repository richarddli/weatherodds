/// Values that are neither NaN nor infinite.
func finiteValues(_ values: [Double]) -> [Double] {
    values.filter(\.isFinite)
}

/// NumPy's default linear percentile method.
///
/// Non-finite values are discarded before sorting. `nil` is returned when no
/// finite values remain.
func percentile(_ values: [Double], _ q: Double) -> Double? {
    let sorted = finiteValues(values).sorted()
    guard !sorted.isEmpty else { return nil }

    let boundedQ = min(max(q, 0), 100)
    let position = Double(sorted.count - 1) * boundedQ / 100
    let lowerIndex = Int(position.rounded(.down))
    let upperIndex = Int(position.rounded(.up))
    guard lowerIndex != upperIndex else { return sorted[lowerIndex] }

    let fraction = position - Double(lowerIndex)
    return sorted[lowerIndex] + (sorted[upperIndex] - sorted[lowerIndex]) * fraction
}

func median(_ values: [Double]) -> Double? {
    percentile(values, 50)
}

/// Reduces every row while ignoring NaN values. An all-NaN row stays NaN.
func rowReduce(
    _ rows: [[Double]],
    _ operation: ([Double]) -> Double
) -> [Double] {
    rows.map { row in
        let present = row.filter { !$0.isNaN }
        return present.isEmpty ? .nan : operation(present)
    }
}

func rowMinimum(_ rows: [[Double]]) -> [Double] {
    rowReduce(rows) { $0.min()! }
}

func rowMaximum(_ rows: [[Double]]) -> [Double] {
    rowReduce(rows) { $0.max()! }
}

func rowSum(_ rows: [[Double]]) -> [Double] {
    rowReduce(rows) { $0.reduce(0, +) }
}

func rowMean(_ rows: [[Double]]) -> [Double] {
    rowReduce(rows) { $0.reduce(0, +) / Double($0.count) }
}
