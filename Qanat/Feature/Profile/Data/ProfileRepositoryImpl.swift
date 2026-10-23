import Foundation

private struct ProfileDto: Codable {
    let lastName: String
    let firstName: String
    let middleName: String
    let birthDate: String?
    /// Только в ответе: относительная подписанная ссылка; nil — фото нет. В PATCH не уходит.
    var avatarUrl: String?

    enum CodingKeys: String, CodingKey {
        case lastName = "last_name"
        case firstName = "first_name"
        case middleName = "middle_name"
        case birthDate = "birth_date"
        case avatarUrl = "avatar_url"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(lastName, forKey: .lastName)
        try container.encode(firstName, forKey: .firstName)
        try container.encode(middleName, forKey: .middleName)
        // null — дату стёрли: серверу нужно явное значение.
        try container.encode(birthDate, forKey: .birthDate)
    }
}

final class ProfileRepositoryImpl: ProfileRepository, AvatarRepository {
    private let api: ApiClient

    init(api: ApiClient) {
        self.api = api
    }

    func get() async throws -> Profile {
        try await mapErrors(httpError: profileError) {
            try toProfile(try await api.get("mobile/profile"))
        }
    }

    func update(_ profile: Profile) async throws -> Profile {
        try await mapErrors(httpError: profileError) {
            let dto = ProfileDto(
                lastName: profile.lastName,
                firstName: profile.firstName,
                middleName: profile.middleName,
                birthDate: profile.birthDate?.iso
            )
            return try toProfile(try await api.patch("mobile/profile", body: dto))
        }
    }

    func upload(jpeg: Data) async throws -> Profile {
        try await mapErrors(httpError: avatarError) {
            var form = MultipartForm()
            form.addFile(name: "image", filename: "avatar.jpg", mimeType: "image/jpeg", data: jpeg)
            let request = form.request(api.request("POST", "mobile/profile/avatar"))
            return try toProfile(try api.decode(try await api.data(request)))
        }
    }

    func remove() async throws -> Profile {
        try await mapErrors(httpError: avatarError) {
            try toProfile(try api.decode(try await api.data(api.request("DELETE", "mobile/profile/avatar"))))
        }
    }

    private func toProfile(_ dto: ProfileDto) throws -> Profile {
        var birthDate: LocalDate?
        if let raw = dto.birthDate {
            guard let date = LocalDate(iso: raw) else { throw ProfileError.server }
            birthDate = date
        }
        return Profile(
            lastName: dto.lastName,
            firstName: dto.firstName,
            middleName: dto.middleName,
            birthDate: birthDate,
            avatarURL: dto.avatarUrl.flatMap { siteURL($0) }
        )
    }

    private func profileError(_ error: HTTPError) -> ProfileError {
        guard error.code == 400 else { return .server }
        let detail = (try? JSONDecoder().decode(DetailDto.self, from: error.body))?.detail
        return .invalid(detail: detail ?? "HTTP \(error.code)")
    }

    /// У фото свои 400 и 503: сервер объясняет их по-русски, а нам нужен текст на языке приложения.
    private func avatarError(_ error: HTTPError) -> ProfileError {
        switch error.code {
        case 400: .imageRejected
        case 503: .storageUnavailable
        default: .server
        }
    }

    private func mapErrors<T>(httpError: (HTTPError) -> ProfileError, _ block: () async throws -> T) async throws -> T {
        do {
            return try await block()
        } catch let error as ProfileError {
            throw error
        } catch let error as HTTPError {
            throw httpError(error)
        } catch {
            throw error.isNetworkError ? ProfileError.network : ProfileError.server
        }
    }
}
