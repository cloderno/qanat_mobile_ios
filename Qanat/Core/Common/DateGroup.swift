import Foundation

/// Группы «Сегодня / Вчера / Последние 7 дней / Ранее» — в меню чатов и в галерее.
enum DateGroup: Int, CaseIterable, Comparable {
    case today, yesterday, lastWeek, earlier

    var labelKey: String {
        switch self {
        case .today: "chat_date_today"
        case .yesterday: "chat_date_yesterday"
        case .lastWeek: "chat_date_last_week"
        case .earlier: "chat_date_earlier"
        }
    }

    var label: String { L.t(labelKey) }

    static func < (lhs: DateGroup, rhs: DateGroup) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Группа дня [date], если сегодня — [today]. Даты — начала дней в [calendar].
func dateGroupOf(_ date: Date, today: Date, calendar: Calendar = .current) -> DateGroup {
    let day = calendar.startOfDay(for: date)
    let start = calendar.startOfDay(for: today)
    let days = calendar.dateComponents([.day], from: day, to: start).day ?? 0
    switch days {
    case ...0: return .today
    case 1: return .yesterday
    case 2...6: return .lastWeek
    default: return .earlier
    }
}

extension Array {
    /// Раскладывает по [DateGroup] — группы от свежих к старым, порядок внутри группы сохраняется.
    func groupedByDate(calendar: Calendar = .current, now: Date = Date(), dateOf: (Element) -> Date) -> [(DateGroup, [Element])] {
        let groups = Dictionary(grouping: self) { dateGroupOf(dateOf($0), today: now, calendar: calendar) }
        return groups.keys.sorted().map { ($0, groups[$0]!) }
    }
}

/// «Сегодня, 12:25», «Вчера, 09:10», «8 окт., 17:40», другой год — «8 окт. 2025 г., 17:40».
func lastActivityLabel(
    _ date: Date,
    language: AppLanguage = LanguageSettings.shared.language,
    calendar: Calendar = .current,
    now: Date = Date()
) -> String {
    let time = formatted(date, "HH:mm", language)
    let day: String = switch dateGroupOf(date, today: now, calendar: calendar) {
    case .today: DateGroup.today.label
    case .yesterday: DateGroup.yesterday.label
    case .lastWeek, .earlier: dayLabel(date, language: language, calendar: calendar, now: now)
    }
    return "\(day), \(time)"
}

/// Короткий вариант: сегодня — «12:25», вчера — «Вчера», раньше — «8 окт.», другой год — «8 окт. 2025 г.».
func shortActivityLabel(
    _ date: Date,
    language: AppLanguage = LanguageSettings.shared.language,
    calendar: Calendar = .current,
    now: Date = Date()
) -> String {
    switch dateGroupOf(date, today: now, calendar: calendar) {
    case .today: formatted(date, "HH:mm", language)
    case .yesterday: DateGroup.yesterday.label
    case .lastWeek, .earlier: dayLabel(date, language: language, calendar: calendar, now: now)
    }
}

private func dayLabel(_ date: Date, language: AppLanguage, calendar: Calendar, now: Date) -> String {
    let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
    let pattern = switch language {
    case .russian: sameYear ? "d MMM" : "d MMM y 'г'."
    case .kazakh: sameYear ? "d MMM" : "y 'ж'. d MMM"
    case .english: sameYear ? "MMM d" : "MMM d, y"
    }
    return formatted(date, pattern, language)
}

private func formatted(_ date: Date, _ pattern: String, _ language: AppLanguage) -> String {
    let formatter = DateFormatter()
    formatter.locale = language.locale
    formatter.dateFormat = pattern
    return formatter.string(from: date)
}

/// 0:07, 1:23 — длительность голосового или видео; меньше секунды показываем как 0:01.
func formatDuration(ms: Int64) -> String {
    let seconds = max(ms / 1000, 1)
    return String(format: "%d:%02d", seconds / 60, seconds % 60)
}
