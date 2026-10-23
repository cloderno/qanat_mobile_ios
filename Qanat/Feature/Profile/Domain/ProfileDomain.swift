import Foundation

/// День без времени и часового пояса — как LocalDate.
struct LocalDate: Equatable, Comparable, Hashable {
    let year: Int
    let month: Int
    let day: Int

    /// ISO-8601: 1990-04-25.
    init?(iso: String) {
        let parts = iso.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, (1...12).contains(parts[1]), (1...31).contains(parts[2]) else { return nil }
        year = parts[0]
        month = parts[1]
        day = parts[2]
    }

    init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    init(date: Date, calendar: Calendar = .current) {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(year: components.year!, month: components.month!, day: components.day!)
    }

    var iso: String { String(format: "%04d-%02d-%02d", year, month, day) }

    func date(calendar: Calendar = .current) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    static func < (lhs: LocalDate, rhs: LocalDate) -> Bool { (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day) }
}

struct Profile: Equatable {
    var lastName: String
    var firstName: String
    /// Пусто — отчества нет.
    var middleName: String
    /// nil — не указана.
    var birthDate: LocalDate?
    /// Полный адрес фото; nil — фото нет, показываем инициалы.
    var avatarURL: String?
}

enum ProfileError: Error, Equatable {
    case network
    /// Сервер отклонил данные (400) и объяснил почему — показываем [detail] как есть.
    case invalid(detail: String)
    case server
    /// Фото не принято (400): не картинка или больше 10 МБ.
    case imageRejected
    /// Хранилище фото на сервере недоступно (503) — можно повторить позже.
    case storageUnavailable
}

/// ФИО и дата рождения пользователя. Методы бросают [ProfileError].
protocol ProfileRepository: AnyObject {
    func get() async throws -> Profile
    /// Сохраняет все поля сразу.
    func update(_ profile: Profile) async throws -> Profile
}

/// Фото профиля. Оба метода возвращают профиль, каким его вернул сервер; бросают [ProfileError].
protocol AvatarRepository: AnyObject {
    /// [jpeg] — уже кадрированный квадрат.
    func upload(jpeg: Data) async throws -> Profile
    func remove() async throws -> Profile
}
