import Combine
import Foundation

enum DocumentList: Equatable {
    /// Первая пачка грузится — и заново, после смены фильтра или поиска.
    case loading
    case failed(messageKey: String)
    /// Новые сверху; [nextPage] — что под последним из них. [isFiltered] — список отобран видом или поиском:
    /// пустой значит «ничего не нашлось», а не «документов ещё нет».
    case loaded(documents: [AgentDocument], nextPage: NextPage, isFiltered: Bool)
}

/// Следующая пачка: none — документов больше нет, failed — не загрузилась, её можно повторить.
enum NextPage { case none, available, loading, failed }

/// 404 в «Документах» — нет документа, а не чата, как у чатов.
func documentsMessageKey(_ error: Error) -> String {
    switch error as? ChatError {
    case .notAllowed: "chat_error_not_allowed"
    case .notFound: "documents_not_found"
    case .network: "chat_error_network"
    default: "chat_error_server"
    }
}

/// Вкладка «Документы» в меню чатов.
@MainActor
@Observable
final class DocumentsViewModel {
    /// Фильтр по виду; nil — все.
    private(set) var kind: AgentDocument.Kind?
    /// Поиск по названию — как набран в поле меню; сервер ищет, когда пользователь перестал печатать.
    private(set) var query = ""
    private(set) var list: DocumentList = .loading
    /// Потянули список вниз: он перечитывается с начала, а показанный остаётся до ответа.
    private(set) var isRefreshing = false
    /// Обновить показанный список не вышло — сообщение показывается один раз.
    var errorKey: String?

    private let documents: DocumentRepository
    // С какими видом и поиском загружен показанный список и где его следующая пачка.
    private var shownKind: AgentDocument.Kind?
    private var shownQuery = ""
    private var cursor: String?
    private var listTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var subscription: AnyCancellable?

    /// Столько ждём после последней набранной буквы, прежде чем искать.
    private static let searchDelay: Double = 0.4

    init(documents: DocumentRepository) {
        self.documents = documents
        load()
        subscription = documents.deleted.receive(on: DispatchQueue.main).sink { [weak self] id in
            guard let self, case .loaded(let shown, let next, let filtered) = list else { return }
            list = .loaded(documents: shown.filter { $0.id != id }, nextPage: next, isFiltered: filtered)
        }
    }

    func selectKind(_ kind: AgentDocument.Kind?) {
        guard kind != self.kind else { return }
        self.kind = kind
        load()
    }

    /// Текст в поле поиска меню: искать начинаем, когда пользователь перестал печатать.
    func onQueryChange(_ query: String) {
        self.query = query
        searchTask?.cancel()
        // Вернулись к тому, что уже показано, или дописали пробел — искать заново незачем.
        if case .loaded = list, query.trimmingCharacters(in: .whitespaces) == shownQuery { return }
        searchTask = Task {
            try? await Task.sleep(for: .seconds(Self.searchDelay))
            if !Task.isCancelled { load() }
        }
    }

    /// Потянули список вниз. Если он так и не загрузился, это то же, что «Повторить».
    func refresh() async {
        if case .loaded = list { load(refreshing: true) } else { load() }
        await listTask?.value
    }

    func retry() { load() }

    /// Показался конец списка — следующая пачка; после ошибки — её повтор.
    func loadMore() {
        guard case .loaded(_, let next, _) = list, next == .available || next == .failed, listTask == nil, let cursor else { return }
        setNextPage(.loading)
        listTask = Task {
            defer { listTask = nil }
            do {
                let page = try await documents.documents(kind: shownKind, query: shownQuery, cursor: cursor)
                self.cursor = page.nextCursor
                guard case .loaded(let shown, _, let filtered) = list else { return }
                // Пачки перекрываются, если между ними появились новые документы.
                var seen = Set<String>()
                let merged = (shown + page.documents).filter { seen.insert($0.id).inserted }
                list = .loaded(documents: merged, nextPage: page.nextCursor == nil ? .none : .available, isFiltered: filtered)
            } catch {
                log.warning("Следующая пачка документов не загрузилась: \(error)")
                setNextPage(.failed)
            }
        }
    }

    /// Первая пачка с текущими видом и поиском. [refreshing] — показанный список остаётся на экране до ответа,
    /// а если обновить не вышло — остаётся совсем, с сообщением об ошибке.
    private func load(refreshing: Bool = false) {
        listTask?.cancel()
        searchTask?.cancel()
        let kind = self.kind
        let query = self.query.trimmingCharacters(in: .whitespaces)
        if refreshing {
            isRefreshing = true
        } else {
            list = .loading
            isRefreshing = false
        }
        listTask = Task {
            do {
                let page = try await documents.documents(kind: kind, query: query, cursor: nil)
                guard !Task.isCancelled else { return }
                shownKind = kind
                shownQuery = query
                cursor = page.nextCursor
                list = .loaded(documents: page.documents, nextPage: page.nextCursor == nil ? .none : .available, isFiltered: kind != nil || !query.isEmpty)
                isRefreshing = false
            } catch {
                guard !Task.isCancelled else { return }
                if refreshing, case .loaded(let shown, let next, let filtered) = list {
                    // Пачка, которую отменило обновление, снова ждёт прокрутки до конца.
                    list = .loaded(documents: shown, nextPage: next == .loading ? .available : next, isFiltered: filtered)
                    errorKey = documentsMessageKey(error)
                } else {
                    list = .failed(messageKey: documentsMessageKey(error))
                }
                isRefreshing = false
            }
            listTask = nil
        }
    }

    private func setNextPage(_ next: NextPage) {
        guard case .loaded(let shown, _, let filtered) = list else { return }
        list = .loaded(documents: shown, nextPage: next, isFiltered: filtered)
    }
}

enum TemplateList: Equatable {
    case loading
    case failed(messageKey: String)
    /// По названию — как отдал сервер.
    case loaded([LetterTemplate])
}

/// «Шаблоны писем» во вкладке «Документы». Грузятся, только когда их показали.
@MainActor
@Observable
final class LetterTemplatesViewModel {
    private(set) var list: TemplateList = .loading
    private(set) var isRefreshing = false
    /// Шаблон, который сейчас удаляется; nil — ничего не удаляется.
    private(set) var deleting: String?
    /// Не обновилось или не удалилось — сообщение показывается один раз.
    var messageKey: String?

    private let documents: DocumentRepository
    private var loadTask: Task<Void, Never>?

    init(documents: DocumentRepository) {
        self.documents = documents
    }

    /// Выбрали «Шаблоны писем». Уже показанный список перечитывается — в чате могли сохранить новый шаблон.
    func onShown() { load(refreshing: isLoaded) }

    /// Потянули список вниз. Если он так и не загрузился, это то же, что «Повторить».
    func refresh() async {
        load(refreshing: isLoaded)
        await loadTask?.value
    }

    func retry() { load(refreshing: false) }

    /// Подтверждение спрашивает экран. Пока удаляется один шаблон, другие не удаляются.
    func delete(_ id: String) {
        guard deleting == nil else { return }
        deleting = id
        messageKey = nil
        Task {
            do {
                try await documents.deleteLetterTemplate(id: id)
                if case .loaded(let templates) = list { list = .loaded(templates.filter { $0.id != id }) }
            } catch {
                log.warning("Шаблон \(id) не удалён: \(error)")
                messageKey = "letter_templates_delete_failed"
            }
            deleting = nil
        }
    }

    private var isLoaded: Bool {
        if case .loaded = list { return true }
        return false
    }

    private func load(refreshing: Bool) {
        loadTask?.cancel()
        if refreshing {
            isRefreshing = true
        } else {
            list = .loading
            isRefreshing = false
        }
        loadTask = Task {
            do {
                let templates = try await documents.letterTemplates()
                guard !Task.isCancelled else { return }
                list = .loaded(templates)
            } catch {
                guard !Task.isCancelled else { return }
                if refreshing && isLoaded {
                    messageKey = documentsMessageKey(error)
                } else {
                    list = .failed(messageKey: documentsMessageKey(error))
                }
            }
            isRefreshing = false
        }
    }
}

extension Array where Element == LetterTemplate {
    /// Шаблоны, подходящие под поиск меню: сервер шаблоны не ищет, а их немного — отбираем здесь,
    /// по названию, теме и адресату. Пустой поиск — все.
    func matching(_ query: String) -> [LetterTemplate] {
        let words = query.trimmingCharacters(in: .whitespaces)
        guard !words.isEmpty else { return self }
        return filter { [$0.name, $0.subject, $0.addresseeShort].contains { $0.localizedCaseInsensitiveContains(words) } }
    }
}

/// Когда сделан документ — коротко, для списка: сегодня — «14:32», в этом году — «8 окт.», раньше — «8 окт. 2025».
func shortCreatedLabel(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
    let pattern: String
    if calendar.isDate(date, inSameDayAs: now) {
        pattern = "HH:mm"
    } else if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
        pattern = "d MMM"
    } else {
        pattern = "d MMM yyyy"
    }
    let formatter = DateFormatter()
    formatter.locale = LanguageSettings.shared.language.locale
    formatter.dateFormat = pattern
    return formatter.string(from: date)
}

/// Полностью — на экране документа: «8 октября 2026, 14:32».
func fullCreatedLabel(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = LanguageSettings.shared.language.locale
    formatter.dateFormat = "d MMMM yyyy, HH:mm"
    return formatter.string(from: date)
}

private let log = Log("Documents")
