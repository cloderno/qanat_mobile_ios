import Foundation

/// Столбец таблицы: ширина, pt, и числовой ли он — числа стоят по правому краю.
struct TableColumn: Equatable {
    let width: CGFloat
    let numeric: Bool
}

/// Ширины столбцов по содержимому — как у таблицы на сайте (автораскладка браузера). У каждого столбца два размера:
/// наименьший — самое длинное слово заголовка или ячейки (число — целиком), и желаемый — заголовок и ячейки одной
/// строкой. Желаемые помещаются — столбцы получают их, а остаток делится пропорционально им же. Не помещаются, но
/// наименьшие помещаются — каждый получает наименьший и долю остатка по тому, сколько ему не хватает до желаемого.
/// Не помещаются и наименьшие — столбцы наименьшие, таблица листается вбок. Слово поэтому не рвётся никогда.
func tableColumns(
    header: [String],
    rows: [[String]],
    available: CGFloat,
    cellPadding: CGFloat,
    measureHeader: (String) -> CGFloat,
    measureCell: (String) -> CGFloat
) -> [TableColumn] {
    let count = tableColumnCount(header: header, rows: rows)
    struct Size { let min: CGFloat; let desired: CGFloat; let numeric: Bool }
    let sizes: [Size] = (0..<count).map { index in
        let title = index < header.count ? header[index] : ""
        let cells = rows.map { index < $0.count ? $0[index] : "" }
        // Самое широкое, что нельзя переносить: слово заголовка, слово ячейки или число целиком.
        let titleWord = words(title).map(measureHeader).max() ?? 0
        let cellWord = cells.map { cell -> CGFloat in
            isNumericCell(cell) ? measureCell(cell.trimmingCharacters(in: .whitespaces)) : (words(cell).map(measureCell).max() ?? 0)
        }.max() ?? 0
        let unbreakable = max(titleWord, cellWord)
        let oneLine = max(measureHeader(title.trimmingCharacters(in: .whitespaces)), cells.map { measureCell($0.trimmingCharacters(in: .whitespaces)) }.max() ?? 0)
        // Округление вверх: на долю точки уже ячейки текст перенёсся бы.
        return Size(min: ceil(unbreakable) + cellPadding, desired: ceil(max(oneLine, unbreakable)) + cellPadding, numeric: isNumericColumn(cells))
    }
    // Запас — точка на столбец: поля и ширины округляются по отдельности и в сумме могли бы чуть вылезти.
    let room = available - CGFloat(count)
    let minTotal = sizes.reduce(0) { $0 + $1.min }
    let desiredTotal = sizes.reduce(0) { $0 + $1.desired }
    let widths: [CGFloat]
    if desiredTotal <= 0 {
        widths = sizes.map(\.desired)
    } else if desiredTotal <= room {
        widths = sizes.map { $0.desired * room / desiredTotal }
    } else if minTotal < room {
        let extra = room - minTotal
        let shortfall = desiredTotal - minTotal
        widths = sizes.map { $0.min + extra * ($0.desired - $0.min) / shortfall }
    } else {
        widths = sizes.map(\.min)
    }
    return zip(sizes, widths).map { TableColumn(width: $1, numeric: $0.numeric) }
}

/// Закреплять ли первый столбец при прокрутке вбок: только если он берёт не больше половины ширины.
func pinFirstColumn(_ columns: [TableColumn], available: CGFloat) -> Bool {
    columns.count > 1 && columns[0].width <= available * 0.5
}

/// Столбцов столько, сколько в самой длинной строке или заголовке: сервер может прислать неровные строки.
func tableColumnCount(header: [String], rows: [[String]]) -> Int {
    max(header.count, rows.map(\.count).max() ?? 0)
}

/// На узкой карточке широкая таблица — карточками по строке: столбцов слишком много для телефона.
func tableAsCards(columnCount: Int, width: CGFloat) -> Bool {
    columnCount >= 4 && width < 400
}

/// Слова — части между пробелами: только там текст и переносится. Неразрывный пробел слово не делит.
func words(_ text: String) -> [String] {
    text.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).map(String.init)
}

private let numberPattern = try! NSRegularExpression(pattern: "^[+\\-−–]?\\d+([.,]\\d+)?%?$")

/// Число: «12», «1 245», «−3», «+5,5%», «87.5 %». Пробелы внутри — разделители разрядов,
/// знак — плюс, дефис, минус U+2212 или тире U+2013, дробная часть — через запятую или точку.
func isNumericCell(_ text: String) -> Bool {
    let compact = String(text.filter { !$0.isWhitespace && $0 != "\u{00A0}" && $0 != "\u{202F}" })
    return numberPattern.firstMatch(in: compact, range: NSRange(compact.startIndex..., in: compact)) != nil
}

/// Столбец числовой, если в нём есть числа, а остальное — пустые ячейки и прочерки.
private func isNumericColumn(_ cells: [String]) -> Bool {
    let meaningful = cells.filter { !["", "-", "–", "—"].contains($0.trimmingCharacters(in: .whitespaces)) }
    return !meaningful.isEmpty && meaningful.allSatisfy(isNumericCell)
}
