import Foundation

/// Либо наш текст по ключу строки, либо от сервера — буквально то, что он объяснил (400 detail).
enum ProfileMessage: Equatable {
    case localized(key: String)
    case fromServer(String)

    var text: String {
        switch self {
        case .localized(let key): L.t(key)
        case .fromServer(let text): text
        }
    }
}

/// ФИО, дата рождения и фото; смена пароля — та же email-ссылка, что и «забыли пароль».
@MainActor
@Observable
final class ProfileViewModel {
    private(set) var isLoading = true
    var lastName = "" { didSet { error = nil } }
    var firstName = "" { didSet { error = nil } }
    var middleName = "" { didSet { error = nil } }
    /// ДД.ММ.ГГГГ — как вводит пользователь; парсится только при сохранении.
    var birthDateText = "" { didSet { error = nil } }
    /// Полный адрес фото; nil — фото нет, видны инициалы.
    private(set) var avatarURL: String?
    /// Фото загружается или удаляется.
    private(set) var avatarBusy = false
    /// Ошибка фото — показываем под ним, а не внизу у «Сохранить», где её не видно.
    private(set) var avatarError: ProfileMessage?
    private(set) var saving = false
    private(set) var error: ProfileMessage?
    var passwordResetSent = false
    private(set) var savedOnce = false

    /// Канат обращается по имени и отчеству — и инициалы те же.
    var initials: String {
        let value = (String(firstName.prefix(1)) + String(middleName.prefix(1))).uppercased()
        return value.trimmingCharacters(in: .whitespaces).isEmpty ? "?" : value
    }

    private let repository: ProfileRepository
    private let avatarRepository: AvatarRepository
    private let authRepository: AuthRepository

    init(repository: ProfileRepository, avatarRepository: AvatarRepository, authRepository: AuthRepository) {
        self.repository = repository
        self.avatarRepository = avatarRepository
        self.authRepository = authRepository
        Task { await load() }
    }

    private func load() async {
        do {
            let profile = try await repository.get()
            lastName = profile.lastName
            firstName = profile.firstName
            middleName = profile.middleName
            birthDateText = profile.birthDate.map(Self.format) ?? ""
            avatarURL = profile.avatarURL
            error = nil
        } catch {
            self.error = Self.message(error)
        }
        isLoading = false
    }

    func save() {
        // «Готово» на клавиатуре и кнопка «Сохранить» ведут сюда же: второй запрос поверх первого не шлём.
        guard !saving else { return }
        let text = birthDateText.trimmingCharacters(in: .whitespaces)
        var birthDate: LocalDate?
        if !text.isEmpty {
            guard let parsed = Self.parse(text) else {
                error = .localized(key: "profile_error_date_format")
                return
            }
            birthDate = parsed
        }
        saving = true
        error = nil
        let profile = Profile(
            lastName: lastName.trimmingCharacters(in: .whitespaces),
            firstName: firstName.trimmingCharacters(in: .whitespaces),
            middleName: middleName.trimmingCharacters(in: .whitespaces),
            birthDate: birthDate
        )
        Task {
            do {
                let saved = try await repository.update(profile)
                lastName = saved.lastName
                firstName = saved.firstName
                middleName = saved.middleName
                birthDateText = saved.birthDate.map(Self.format) ?? ""
                savedOnce = true
            } catch {
                self.error = Self.message(error)
            }
            saving = false
        }
    }

    /// [jpeg] — квадрат, уже кадрированный на экране.
    func avatarCropped(_ jpeg: Data) { changeAvatar { try await self.avatarRepository.upload(jpeg: jpeg) } }

    func removeAvatar() { changeAvatar { try await self.avatarRepository.remove() } }

    /// Выбранное фото не открылось — до сервера дело не дошло.
    func avatarUnreadable() { avatarError = .localized(key: "avatar_error_unreadable") }

    // Из ответа берём только фото: недописанные ФИО в полях не трогаем.
    private func changeAvatar(_ request: @escaping () async throws -> Profile) {
        guard !avatarBusy else { return }
        avatarBusy = true
        avatarError = nil
        Task {
            do {
                avatarURL = try await request().avatarURL
            } catch {
                avatarError = Self.message(error)
            }
            avatarBusy = false
        }
    }

    func requestPasswordReset(email: String) {
        Task {
            do {
                try await authRepository.requestPasswordReset(email: email)
                passwordResetSent = true
            } catch {
                self.error = .localized(key: (error as? AuthError) == .network ? "profile_error_network" : "profile_error_server")
            }
        }
    }

    private static func message(_ error: Error) -> ProfileMessage {
        switch error as? ProfileError {
        case .invalid(let detail): .fromServer(detail)
        case .network: .localized(key: "profile_error_network")
        case .imageRejected: .localized(key: "avatar_error_rejected")
        case .storageUnavailable: .localized(key: "avatar_error_storage")
        default: .localized(key: "profile_error_server")
        }
    }

    static func format(_ date: LocalDate) -> String { String(format: "%02d.%02d.%04d", date.day, date.month, date.year) }

    /// Строго ДД.ММ.ГГГГ и существующий день — как DateTimeFormatter("dd.MM.yyyy").
    static func parse(_ text: String) -> LocalDate? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 2, parts[1].count == 2, parts[2].count == 4,
              let day = Int(parts[0]), let month = Int(parts[1]), let year = Int(parts[2]) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let components = DateComponents(year: year, month: month, day: day)
        guard components.isValidDate(in: calendar) else { return nil }
        return LocalDate(year: year, month: month, day: day)
    }
}
