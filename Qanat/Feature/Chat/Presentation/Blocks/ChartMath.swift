import Foundation

// Арифметика графиков без UI — проверяется unit-тестами.

extension ChartBlock {
    /// Значения рядов ровно по числу категорий: недостающие и нечисловые (NaN, ∞) — пропуски.
    func rows() -> [[Double?]] {
        series.map { series in
            categories.indices.map { index in
                guard index < series.data.count, let value = series.data[index], value.isFinite else { return nil }
                return value
            }
        }
    }
}

/// Числа на графике: разряды по локали, не больше двух знаков после запятой, без хвостовых нулей.
struct ChartNumbers {
    private let number: NumberFormatter
    private let percentFormatter: NumberFormatter
    let locale: Locale

    init(locale: Locale = LanguageSettings.shared.language.locale) {
        self.locale = locale
        number = NumberFormatter()
        number.locale = locale
        number.numberStyle = .decimal
        number.maximumFractionDigits = 2
        number.roundingMode = .halfUp
        percentFormatter = NumberFormatter()
        percentFormatter.locale = locale
        percentFormatter.numberStyle = .percent
        percentFormatter.maximumFractionDigits = 1
        percentFormatter.roundingMode = .halfUp
    }

    // То, что округляется до нуля (−0,001), — просто «0», без минуса.
    func value(_ value: Double) -> String {
        number.string(from: NSNumber(value: abs(value) < 0.005 ? 0 : value)) ?? "\(value)"
    }

    /// [share] — доля от 0 до 1.
    func percent(_ share: Double) -> String {
        percentFormatter.string(from: NSNumber(value: share)) ?? "\(share)"
    }

    /// Числа на осях и у концов полос: «1,2 млн», если так короче полной записи самого большого из них,
    /// иначе полностью — чтобы на одной оси записи не смешивались.
    func short(largest: Double) -> (Double) -> String {
        let compact = { (value: Double) -> String in
            value.formatted(.number.notation(.compactName).precision(.significantDigits(1...3)).locale(locale))
        }
        if compact(largest).count >= self.value(largest).count { return { self.value($0) } }
        return { abs($0) < 0.005 ? self.value(0) : compact($0) }
    }
}

/// Текст графика для VoiceOver: «категория: значения рядов» по каждой категории и единица в конце.
func spokenSummary(_ chart: ChartBlock, rows: [[Double?]], numbers: ChartNumbers) -> String {
    let text = chart.categories.indices.map { "\(chart.categories[$0]): \(spokenValues(chart, rows: rows, index: $0, numbers: numbers))" }
        .joined(separator: "; ")
    return chart.unit.isEmpty ? text : "\(text) (\(chart.unit))"
}

/// Значения рядов одной категории: «ряд число, …» (имя — только когда рядов несколько); нет чисел — «—».
func spokenValues(_ chart: ChartBlock, rows: [[Double?]], index: Int, numbers: ChartNumbers) -> String {
    let parts = rows.enumerated().compactMap { series, row -> String? in
        guard index < row.count, let value = row[index] else { return nil }
        let name = rows.count > 1 && series < chart.series.count ? chart.series[series].name : ""
        return name.isEmpty ? numbers.value(value) : "\(name) \(numbers.value(value))"
    }
    return parts.isEmpty ? "—" : parts.joined(separator: ", ")
}

/// Деления оси значений: круглые шаги (1, 2, 2,5 или 5 × 10ⁿ), не больше [maxSteps] штук;
/// ноль всегда на оси, крайние деления не меньше данных.
func axisTicks(_ range: ClosedRange<Double>, maxSteps: Int = 4) -> [Double] {
    let low = min(range.lowerBound, 0)
    let high = max(range.upperBound, 0)
    guard high - low > 0 else { return [0, 1] }
    let raw = (high - low) / Double(maxSteps)
    let exponent = Int(floor(log10(raw)))
    let fraction = raw / pow(10, Double(exponent))
    let nice = [1.0, 2.0, 2.5, 5.0, 10.0].first { $0 >= fraction - 1e-9 } ?? 10
    // Шаг в Decimal, чтобы деления были ровно 0,6, а не 0,6000000000000001.
    let step = Decimal(nice) * pow(Decimal(10), exponent >= 0 ? exponent : 0) / pow(Decimal(10), exponent < 0 ? -exponent : 0)
    let stepDouble = NSDecimalNumber(decimal: step).doubleValue
    let from = Int64(floor(low / stepDouble + 1e-9))
    let to = Int64(ceil(high / stepDouble - 1e-9))
    return (from...to).map { NSDecimalNumber(decimal: step * Decimal($0)).doubleValue }
}

/// Суммы столбцов-стопок по категориям: отрицательные части..положительные части. Пропуски — ноль.
func stackTotals(_ rows: [[Double?]]) -> [ClosedRange<Double>] {
    let size = rows.map(\.count).max() ?? 0
    return (0..<size).map { index in
        let values = rows.compactMap { index < $0.count ? $0[index] : nil }
        return values.filter { $0 < 0 }.reduce(0, +)...values.filter { $0 > 0 }.reduce(0, +)
    }
}

/// Наименьшее и наибольшее значения графика; у стопок — по суммам частей. Нет чисел — 0..0.
func valueRange(_ rows: [[Double?]], stacked: Bool) -> ClosedRange<Double> {
    if stacked {
        let totals = stackTotals(rows)
        return (totals.map(\.lowerBound).min() ?? 0)...(totals.map(\.upperBound).max() ?? 0)
    }
    let values = rows.flatMap { $0 }.compactMap { $0 }
    return (values.min() ?? 0)...(values.max() ?? 0)
}

/// Внешние края стопок по категориям — у них скругление: ряд с последней положительной частью
/// и с последней отрицательной; nil — таких частей нет.
struct StackEnds: Equatable {
    let positive: Int?
    let negative: Int?
}

func stackEnds(_ rows: [[Double?]]) -> [StackEnds] {
    let size = rows.map(\.count).max() ?? 0
    return (0..<size).map { index in
        func value(_ row: Int) -> Double { index < rows[row].count ? rows[row][index] ?? 0 : 0 }
        return StackEnds(
            positive: rows.indices.last { value($0) > 0 },
            negative: rows.indices.last { value($0) < 0 }
        )
    }
}

/// Части стопки одной категории в единицах значений: положительные копятся от нуля вправо, отрицательные — влево,
/// в порядке рядов. Пропуск и ноль — nil.
func stackSegments(_ values: [Double?]) -> [ClosedRange<Double>?] {
    var positive = 0.0
    var negative = 0.0
    return values.map { value in
        guard let value, value != 0 else { return nil }
        if value > 0 {
            defer { positive += value }
            return positive...(positive + value)
        }
        defer { negative += value }
        return (negative + value)...negative
    }
}

/// Масштаб полос от min(0, наименьшего) до max(0, наибольшего): [fraction] — доля ширины от левого края.
struct BarScale {
    private let low: Double
    private let high: Double

    init(_ range: ClosedRange<Double>) {
        low = min(range.lowerBound, 0)
        let top = max(range.upperBound, 0)
        high = top == low ? low + 1 : top
    }

    /// Самое большое по модулю число шкалы — по нему решают, сокращать ли подписи.
    var largest: Double { max(abs(low), abs(high)) }

    func fraction(_ value: Double) -> CGFloat { CGFloat((value - low) / (high - low)) }
}

/// Доли в сумме положительных значений — для кольца; пропуски и отрицательные — ноль.
func shares(_ values: [Double?]) -> [Double] {
    let total = values.reduce(0.0) { $0 + max($1 ?? 0, 0) }
    return values.map { value in
        guard total > 0, let value, value > 0 else { return 0 }
        return value / total
    }
}

/// Сегмент кольца, на который приходится доля окружности [position] (0 — сверху, по часовой); nil — пусто.
func segmentAt(_ position: Double, shares: [Double]) -> Int? {
    var end = 0.0
    for (index, share) in shares.enumerated() {
        end += share
        if share > 0 && position < end { return index }
    }
    return nil
}

/// Куски ряда без пропусков, с индексами категорий: линия рвётся там, где значения нет.
func segments(_ values: [Double?]) -> [[(index: Int, value: Double)]] {
    var result: [[(index: Int, value: Double)]] = []
    var current: [(index: Int, value: Double)] = []
    for (index, value) in values.enumerated() {
        if let value {
            current.append((index, value))
        } else if !current.isEmpty {
            result.append(current)
            current = []
        }
    }
    if !current.isEmpty { result.append(current) }
    return result
}

/// Ширины столбцов в pt: [slot] — место на категорию, [thickness] — столбец, между столбцами группы — [groupGap].
/// Категории делят ширину поровну, пока им хватает места; иначе [scrolls] — график листается вбок.
struct ColumnLayout: Equatable {
    static let groupGap: CGFloat = 2

    let slot: CGFloat
    let thickness: CGFloat
    let scrolls: Bool

    /// Ширина группы столбцов одной категории.
    func groupWidth(_ groupSize: Int) -> CGFloat { thickness * CGFloat(groupSize) + Self.groupGap * CGFloat(groupSize - 1) }
}

/// [groupSize] — сколько столбцов стоит рядом в категории: число рядов, у стопок — 1.
func columnLayout(plotWidth: CGFloat, categories: Int, groupSize: Int) -> ColumnLayout {
    let extra = CGFloat(groupSize - 1)
    let fitted = plotWidth / CGFloat(max(categories, 1))
    let scrolls = fitted < 24 + extra * 10
    let slot = scrolls ? 44 + extra * 12 : fitted
    let thickness = min(max((slot * 0.65 - ColumnLayout.groupGap * extra) / CGFloat(groupSize), 4), 24)
    return ColumnLayout(slot: slot, thickness: thickness, scrolls: scrolls)
}
