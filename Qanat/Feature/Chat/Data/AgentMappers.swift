import Foundation

/// Сервер отдаёт даты то в ISO-8601 ("...T...Z"), то как "yyyy-MM-dd HH:mm:ss.SSSSSS+00:00".
func parseServerDate(_ raw: String) -> Date? {
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = iso.date(from: raw) { return date }
    iso.formatOptions = [.withInternetDateTime]
    if let date = iso.date(from: raw) { return date }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    for pattern in ["yyyy-MM-dd HH:mm:ss.SSSSSSXXXXX", "yyyy-MM-dd HH:mm:ssXXXXX", "yyyy-MM-dd'T'HH:mm:ss.SSSSSSXXXXX"] {
        formatter.dateFormat = pattern
        if let date = formatter.date(from: raw) { return date }
    }
    return nil
}

enum AgentMappers {
    static func chat(_ json: JSONValue) -> Chat {
        let source: Chat.Source = switch json.string("source") {
        case "voice": .voice
        case "glasses": .glasses
        default: .text
        }
        let rawDate = json["updated_at"]?.stringValue ?? json["created_at"]?.stringValue
        return Chat(
            id: json.string("uuid"),
            title: json.string("title"),
            preview: json.string("preview"),
            source: source,
            updatedAt: rawDate.flatMap(parseServerDate) ?? Date(),
            pinned: json["pinned"]?.bool ?? false
        )
    }

    static func message(_ json: JSONValue) -> ChatMessage {
        let error = json.string("error")
        return ChatMessage(
            id: json.string("uuid"),
            role: json.string("role") == "user" ? .user : .assistant,
            text: json.string("content"),
            blocks: json.objects("blocks").map(block),
            error: error.isEmpty ? nil : error,
            hasAudio: json["has_audio"]?.bool ?? false,
            // Живые события потока (вопрос/ответ только что) его не присылают — им подходит текущее время.
            createdAt: json["created_at"]?.stringValue.flatMap(parseServerDate) ?? Date(),
            steps: json.array("steps").compactMap(\.stringValue),
            photos: json.objects("photos").compactMap(photo),
            trace: json.objects("trace").compactMap(traceStep),
            latencyMs: json["latency_ms"]?.int64
        )
    }

    /// Шаг хода работы — из сообщения, потока ответа и голосового сокета:
    /// `{"kind": "tool", "title", "detail", "at_ms"}` или `{"kind": "said", "text", "at_ms"}`.
    /// Незнакомый вид или шаг без текста — nil: показывать нечего.
    static func traceStep(_ json: JSONValue) -> TraceStep? {
        let atMs = json["at_ms"]?.int64
        switch json.string("kind") {
        case "tool":
            // Без title — хотя бы код инструмента, чтобы шаг не пропал.
            var title = json.string("title")
            if title.trimmingCharacters(in: .whitespaces).isEmpty { title = json.string("tool") }
            guard !title.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            return .tool(title: title, detail: json.string("detail"), atMs: atMs)
        case "said":
            let text = json.string("text")
            guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            return .said(text: text, atMs: atMs)
        default:
            return nil
        }
    }

    /// Снимок к вопросу: {uuid, width, height}. Без uuid показывать нечего — такой пропускаем.
    private static func photo(_ json: JSONValue) -> ChatPhoto? {
        guard let id = json["uuid"]?.stringValue else { return nil }
        return ChatPhoto(id: id, width: json["width"]?.int ?? 0, height: json["height"]?.int ?? 0)
    }

    /// Блоки приходят разнотипным JSON, поэтому разбираем их вручную и снисходительно к пропущенным полям.
    static func block(_ json: JSONValue) -> ChatBlock {
        let title = json.string("title")
        let subtitle = json.string("subtitle")
        let type = json.string("type")
        switch type {
        case "kpis":
            return .kpis(title: title, items: json.objects("items").map(kpi), subtitle: subtitle)
        case "table":
            return .table(
                title: title,
                columns: json.array("columns").map(\.text),
                rows: json.array("rows").map { $0.arrayValue.map(\.text) },
                subtitle: subtitle
            )
        case "chart":
            return .chart(ChartBlock(
                title: title,
                kind: chartKind(json.string("kind")),
                categories: json.array("categories").map(\.text),
                series: json.objects("series").map { series in
                    Series(name: series.string("name"), data: series.array("data").map(\.double))
                },
                unit: json.string("unit"),
                subtitle: subtitle
            ))
        case "dashboard":
            return .dashboard(
                title: title,
                widgets: json.objects("widgets").map { DashboardWidget(block: block($0), wide: $0["wide"]?.bool == true) },
                insights: json.array("insights").map(\.text),
                subtitle: subtitle
            )
        case "deck":
            let embed = json.string("embed")
            return .deck(title: title, url: embed.isEmpty ? nil : siteURL(embed))
        case "letter":
            let short = json.string("addressee_short")
            return .letter(LetterBlock(
                title: title,
                addressee: short.isEmpty ? (json.array("addressee").first?.text ?? "") : short,
                subject: json.string("subject"),
                preview: json.string("preview"),
                documentId: json["document_uuid"]?.stringValue,
                // Номер, дату, подписанта агент не знает и оставляет человеку — где угодно в письме.
                needsFilling: json.jsonString.contains(letterBlank)
            ))
        default:
            return .unsupported(title: title, type: type)
        }
    }

    private static let letterBlank = "[____]"

    // Старые ответы приходили без kind — их рисуем столбцами, как и неизвестные виды.
    private static func chartKind(_ raw: String) -> ChartBlock.Kind {
        switch raw {
        case "bar": .bar
        case "stacked_bar": .stackedBar
        case "stacked_column": .stackedColumn
        case "line": .line
        case "area": .area
        case "donut": .donut
        default: .column
        }
    }

    private static func kpi(_ json: JSONValue) -> Kpi {
        let delta = json.string("delta")
        return Kpi(
            label: json.string("label"),
            value: json.string("value"),
            hint: json.string("hint"),
            tone: tone(json.string("tone")),
            delta: delta.isEmpty ? nil : delta,
            deltaTone: tone(json.string("delta_tone")),
            spark: json.array("spark").compactMap(\.double),
            progress: json["progress"]?.double.map { min(max(Int($0.rounded()), 0), 100) }
        )
    }

    private static func tone(_ raw: String) -> Kpi.Tone {
        switch raw {
        case "good": .good
        case "bad": .bad
        case "warn": .warn
        default: .neutral
        }
    }
}
