import Combine
import Foundation

/// Файлы документов ложатся в «Документы/Qanat» приложения: их видно в «Файлах» iOS («На iPhone → Qanat»).
final class DocumentRepositoryImpl: DocumentRepository {
    private let api: ApiClient
    private let deviceInfo: DeviceInfoProvider
    private let deletedSubject = PassthroughSubject<String, Never>()

    init(api: ApiClient, deviceInfo: DeviceInfoProvider) {
        self.api = api
        self.deviceInfo = deviceInfo
    }

    var deleted: AnyPublisher<String, Never> { deletedSubject.eraseToAnyPublisher() }

    func documents(kind: AgentDocument.Kind?, query: String, cursor: String?) async throws -> DocumentPage {
        precondition(kind != .other, "Документы вида other сервер не отбирает")
        var items: [URLQueryItem] = []
        if let kind { items.append(URLQueryItem(name: "type", value: kind.rawValue)) }
        if !query.isEmpty { items.append(URLQueryItem(name: "q", value: query)) }
        if let cursor { items.append(URLQueryItem(name: "cursor", value: cursor)) }
        return try await mapErrors {
            let page = try JSONValue.parse(try await api.data(api.request("GET", "mobile/agent/documents", query: items)))
            let next = page.string("next")
            return DocumentPage(documents: try page.objects("documents").map(Self.document), nextCursor: next.isEmpty ? nil : next)
        }
    }

    func document(id: String) async throws -> AgentDocument {
        try await mapErrors { try Self.document(try JSONValue.parse(try await api.data(api.request("GET", "mobile/agent/documents/\(id)")))) }
    }

    func delete(id: String) async throws {
        do {
            try await mapErrors { _ = try await api.data(api.request("DELETE", "mobile/agent/documents/\(id)")) }
        } catch ChatError.notFound {
            // Документ уже убрали — например, на сайте: для списков это то же, что убрать его сейчас.
            log.info("Документ \(id) уже убран")
        }
        deletedSubject.send(id)
    }

    func saveAsTemplate(documentId: String, name: String) async throws -> LetterTemplate {
        try await mapErrors {
            let request = try api.jsonRequest("POST", "mobile/agent/documents/\(documentId)/template", body: ["name": name.trimmingCharacters(in: .whitespaces)])
            return try Self.template(try JSONValue.parse(try await api.data(request)))
        }
    }

    func letterTemplates() async throws -> [LetterTemplate] {
        try await mapErrors {
            try JSONValue.parse(try await api.data(api.request("GET", "mobile/agent/letter-templates"))).objects("templates").map(Self.template)
        }
    }

    func deleteLetterTemplate(id: String) async throws {
        do {
            try await mapErrors { _ = try await api.data(api.request("DELETE", "mobile/agent/letter-templates/\(id)")) }
        } catch ChatError.notFound {
            // Шаблон уже удалили — например, на сайте: результат тот же.
            log.info("Шаблон \(id) уже удалён")
        }
    }

    func download(id: String, format: DocumentFormat) async throws -> SavedDocument {
        try await mapErrors {
            var query: [URLQueryItem] = []
            // Письмо сервер и без format отдаёт в DOCX — тот же запрос, что у кнопки письма в чате.
            if format != .docx {
                query = [URLQueryItem(name: "format", value: format.rawValue), URLQueryItem(name: "lang", value: deckLanguage())]
            }
            let (file, response) = try await api.download(api.request("GET", "mobile/agent/documents/\(id)/file", query: query))
            let name = fileNameFromContentDisposition(response.value(forHTTPHeaderField: "Content-Disposition")) ?? "document-\(id).\(format.rawValue)"
            let mimeType = response.mimeType ?? format.mimeType
            return SavedDocument(url: try Self.saveToDocuments(file, name: name), mimeType: mimeType, fileName: name)
        }
    }

    /// Презентации бывают на русском и казахском; в приложении на английском — русская.
    private func deckLanguage() -> String { deviceInfo.locale() == "kk" ? "kk" : "ru" }

    /// Файл с тем же именем не перезаписываем, а называем новый «Письмо (1).docx» — как «Загрузки» Android.
    private static func saveToDocuments(_ temp: URL, name: String) throws -> URL {
        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Qanat", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var target = folder.appendingPathComponent(name)
        var copy = 1
        while FileManager.default.fileExists(atPath: target.path) {
            target = folder.appendingPathComponent(ext.isEmpty ? "\(base) (\(copy))" : "\(base) (\(copy)).\(ext)")
            copy += 1
        }
        try FileManager.default.moveItem(at: temp, to: target)
        return target
    }

    private static func document(_ json: JSONValue) throws -> AgentDocument {
        guard let created = parseServerDate(json.string("created_at")) else { throw ChatError.server("Неожиданный ответ сервера") }
        let chatId = json["chat_uuid"]?.stringValue
        return AgentDocument(
            id: json.string("uuid"),
            kind: AgentDocument.Kind(rawValue: json.string("kind")).flatMap { $0 == .other ? nil : $0 } ?? .other,
            title: json.string("title"),
            subtitle: json.string("subtitle"),
            chatId: chatId?.isEmpty == false ? chatId : nil,
            chatTitle: json.string("chat_title"),
            createdAt: created,
            block: AgentMappers.block(json["block"] ?? .object([:])),
            // Формат, которого приложение не знает, скачать не предлагаем.
            formats: json.array("formats").compactMap { $0.stringValue.flatMap(DocumentFormat.init(rawValue:)) }
        )
    }

    private static func template(_ json: JSONValue) throws -> LetterTemplate {
        guard let created = parseServerDate(json.string("created_at")) else { throw ChatError.server("Неожиданный ответ сервера") }
        return LetterTemplate(
            id: json.string("uuid"),
            name: json.string("name"),
            kindLabel: json.string("kind_label"),
            subject: json.string("subject"),
            addresseeShort: json.string("addressee_short"),
            createdAt: created,
            usedAt: json["used_at"]?.stringValue.flatMap(parseServerDate)
        )
    }

    private func mapErrors<T>(_ block: () async throws -> T) async throws -> T {
        do {
            return try await block()
        } catch {
            throw ChatRepositoryImpl.chatError(error)
        }
    }
}

extension DocumentFormat {
    /// Тип файла, если сервер его не прислал (присылает всегда), — по запрошенному формату, как и запасное имя.
    var mimeType: String {
        switch self {
        case .docx: "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        case .pptx: "application/vnd.openxmlformats-officedocument.presentationml.presentation"
        case .html: "text/html"
        }
    }
}

/// Имя файла из заголовка Content-Disposition. filename*=UTF-8''… (RFC 5987) важнее filename="…": в нём сервер
/// передаёт имена не латиницей. Путь из имени отбрасываем — файл ляжет только в свою папку. nil — имени нет.
func fileNameFromContentDisposition(_ header: String?) -> String? {
    guard let header else { return nil }
    func match(_ pattern: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let result = regex.firstMatch(in: header, range: NSRange(header.startIndex..., in: header)) else { return nil }
        return (0..<result.numberOfRanges).map { index in
            Range(result.range(at: index), in: header).map { String(header[$0]) } ?? ""
        }
    }
    // filename*=кодировка'язык'%D0%9F…
    let extended = match(#"(?:^|;)\s*filename\*\s*=\s*([^';\s]*)'[^']*'([^;\s]*)"#).flatMap { groups -> String? in
        let charset = groups[1].lowercased()
        // Кодировку проверяем сами; «+» в RFC 5987 — это сам плюс.
        guard charset.isEmpty || charset == "utf-8" else { return nil }
        return groups[2].removingPercentEncoding
    }
    // filename="…": внутри кавычек могут быть «;» и экранированные \".
    let quoted = match(#"(?:^|;)\s*filename\s*=\s*"((?:[^"\\]|\\.)*)""#).map { groups in
        groups[1].replacingOccurrences(of: #"\\(.)"#, with: "$1", options: .regularExpression)
    }
    let plain = match(#"(?:^|;)\s*filename\s*=\s*([^";]+)"#).map { $0[1] }
    return [extended, quoted, plain].compactMap { $0 }
        .map { name -> String in
            let afterSlash = name.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? name
            let afterBackslash = afterSlash.split(separator: "\\", omittingEmptySubsequences: false).last.map(String.init) ?? afterSlash
            return afterBackslash.trimmingCharacters(in: .whitespaces)
        }
        .first { !$0.isEmpty }
}

private let log = Log("DocumentRepository")
