import Foundation

enum ChatError: Error, Equatable {
    /// Нет права «Агент» у роли пользователя.
    case notAllowed
    /// Чата нет или он чужой.
    case notFound
    /// Нет разрешения на микрофон, или его занял кто-то другой.
    case microphoneUnavailable
    /// Выбранный снимок не открывается: доступ к нему пропал, или формат не читается.
    case photoUnavailable
    case network
    case server(String)
}

struct Chat: Equatable, Identifiable, Hashable {
    enum Source: String { case text, voice, glasses }

    /// UUID чата на сервере.
    let id: String
    /// Пусто, пока агент не придумал название по первому вопросу.
    var title: String
    var preview: String
    var source: Source = .text
    var updatedAt: Date = Date()
    /// Закреплён — в шторке в разделе «Закреплённые» над недавними.
    var pinned = false
}

struct ChatMessage: Equatable, Identifiable {
    enum Role: Equatable { case user, assistant }

    /// UUID сообщения на сервере.
    let id: String
    let role: Role
    /// У ответа агента — markdown.
    var text: String
    var blocks: [ChatBlock] = []
    /// Почему ответа нет.
    var error: String?
    /// Голосовой вопрос: его запись можно прослушать.
    var hasAudio = false
    var createdAt: Date = Date()
    /// Инструменты, которые агент вызвал для ответа, — коды вроде `list_assignments`.
    var steps: [String] = []
    /// Снимки, приложенные к вопросу.
    var photos: [ChatPhoto] = []
    /// Ход работы агента над ответом; пусто у старых ответов — тогда только [steps].
    var trace: [TraceStep] = []
    /// Сколько агент работал над ответом, мс; nil — сервер не прислал.
    var latencyMs: Int64?
}

/// Событие в чате на сервере, см. [ChatRepository.serverChatEvents].
enum ServerChatEvent: Equatable {
    /// В чате сохранён новый вопрос (answered = false) или готовый ответ — чат пора перечитать.
    case changed(chatId: String, answered: Bool)
    /// Шаг работы над ответом, который пишется где-то ещё; чат перечитывать не нужно.
    case trace(chatId: String, step: TraceStep)

    var chatId: String {
        switch self {
        case .changed(let id, _), .trace(let id, _): id
        }
    }
}

/// Ход работы над ответом, который пишется мимо экрана чата (голосовой разговор), — в чате [chatId].
struct LiveTrace: Equatable {
    let chatId: String
    let steps: [TraceStep]
}

/// Шаг работы агента над ответом, по порядку; [atMs] — от вопроса, nil — сервер не прислал.
enum TraceStep: Equatable {
    /// Агент обратился к источнику: [title] — что делает, словами; [detail] — суть запроса, может быть пустой.
    case tool(title: String, detail: String, atMs: Int64?)
    /// Что Канат сказал по ходу работы («Собираю данные по ДТП»).
    case said(text: String, atMs: Int64?)

    var atMs: Int64? {
        switch self {
        case .tool(_, _, let at), .said(_, let at): at
        }
    }
}

/// Снимок к вопросу, [id] — его UUID. Размеры в пикселях, 0 — сервер их не прислал.
struct ChatPhoto: Equatable, Hashable {
    let id: String
    var width = 0
    var height = 0
}

/// Источники ответа — инструменты из [steps], которыми агент искал данные: без повторов, по порядку вызова.
/// Инструменты, которые только оформляют ответ графиком, таблицей или презентацией, источниками не считаются.
func answerSources(_ steps: [String]) -> [String] {
    var seen = Set<String>()
    return steps.filter { !presentationSteps.contains($0) && seen.insert($0).inserted }
}

private let presentationSteps: Set<String> = [
    "show_chart", "show_table", "show_kpis", "make_dashboard", "present_analytics", "make_presentation",
]

/// Блоки интерфейса в ответе агента.
indirect enum ChatBlock: Equatable {
    case kpis(title: String, items: [Kpi], subtitle: String = "")
    case table(title: String, columns: [String], rows: [[String]], subtitle: String = "")
    case chart(ChartBlock)
    case dashboard(title: String, widgets: [DashboardWidget], insights: [String], subtitle: String = "")
    /// Презентация; [url] — страница для просмотра, живёт 12 часов.
    case deck(title: String, url: String?)
    /// Письмо, подготовленное агентом. [addressee] — коротко, кому; [documentId] — его файл DOCX в «Документах»;
    /// [needsFilling] — в письме остались поля, которые заполняет человек.
    case letter(LetterBlock)
    /// Блок, который приложение пока не умеет показывать.
    case unsupported(title: String, type: String)

    var title: String {
        switch self {
        case .kpis(let title, _, _), .table(let title, _, _, _), .dashboard(let title, _, _, _),
             .deck(let title, _), .unsupported(let title, _):
            title
        case .chart(let chart): chart.title
        case .letter(let letter): letter.title
        }
    }

    /// Строка под заголовком; пусто — нет. В ней сервер пишет «факт» или «прогноз» и их период.
    var subtitle: String {
        switch self {
        case .kpis(_, _, let subtitle), .table(_, _, _, let subtitle), .dashboard(_, _, _, let subtitle): subtitle
        case .chart(let chart): chart.subtitle
        default: ""
        }
    }
}

struct ChartBlock: Equatable {
    /// bar — горизонтальные полосы, column — вертикальные столбцы; stacked* — ряды друг на друге.
    enum Kind: String { case bar, column, stackedBar, stackedColumn, line, area, donut }

    let title: String
    let kind: Kind
    let categories: [String]
    let series: [Series]
    let unit: String
    var subtitle = ""
}

struct LetterBlock: Equatable {
    let title: String
    let addressee: String
    let subject: String
    let preview: String
    let documentId: String?
    var needsFilling = false
}

/// [wide] — виджет на всю ширину, иначе по два в ряд.
struct DashboardWidget: Equatable {
    let block: ChatBlock
    let wide: Bool
}

struct Kpi: Equatable {
    enum Tone: Equatable { case good, bad, warn, neutral }

    let label: String
    let value: String
    let hint: String
    let tone: Tone
    /// Изменение как есть: «+12%», «−3»; nil — не показывать. Цвет стрелки — [deltaTone].
    var delta: String?
    var deltaTone: Tone = .neutral
    /// Мини-график в карточке, до 24 точек; пусто — не рисовать.
    var spark: [Double] = []
    /// Доля в процентах, 0–100 — полоса прогресса; nil — не рисовать.
    var progress: Int?
}

struct Series: Equatable {
    let name: String
    let data: [Double?]
}

struct ChatPage: Equatable {
    let chats: [Chat]
    let nextCursor: String?
}

struct ChatHistory: Equatable {
    /// Старые — первыми.
    let messages: [ChatMessage]
    let hasEarlier: Bool
}

struct OpenedChat: Equatable {
    let chat: Chat
    let history: ChatHistory
}

/// События ответа агента, по мере прихода.
enum AnswerEvent {
    /// Голосовой вопрос сохранён на сервере; расшифровки пока нет — она придёт в [transcribed].
    case questionSaved(ChatMessage)
    /// Расшифровка того же голосового вопроса (тот же id).
    case transcribed(ChatMessage)
    /// «Секунду, посмотрю…» — агент работает.
    case thinking(String)
    /// Агент вызвал инструменты — коды, как в [ChatMessage.steps].
    case steps([String])
    /// Очередной шаг работы агента — как в [ChatMessage.trace].
    case trace(TraceStep)
    /// Кусок текста ответа — дописывается к уже пришедшему.
    case textDelta(String)
    case block(ChatBlock)
    /// Фраза голосового ответа (запрошен `reply=voice`): mp3, по порядку [seq], без пауз между фразами.
    case speech(seq: Int, text: String, audio: Data, isFiller: Bool)
    /// Ответ сохранён; [chat] — с названием, которое мог придумать агент.
    /// [message] — nil, если речь в голосовом вопросе не распознана: самого ответа нет.
    case done(message: ChatMessage?, chat: Chat)
}
