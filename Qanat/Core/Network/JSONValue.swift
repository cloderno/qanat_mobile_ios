import Foundation

/// Произвольный JSON — для блоков ответа агента, которые приходят разнотипными и разбираются вручную,
/// снисходительно к пропущенным полям (как JsonObject в Android-версии).
enum JSONValue: Decodable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    static func parse(_ data: Data) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: data)
    }

    static func parse(_ text: String) throws -> JSONValue {
        try parse(Data(text.utf8))
    }

    subscript(key: String) -> JSONValue? {
        if case .object(let object) = self { return object[key] }
        return nil
    }

    var object: [String: JSONValue]? {
        if case .object(let object) = self { return object }
        return nil
    }

    var arrayValue: [JSONValue] {
        if case .array(let array) = self { return array }
        return []
    }

    var objects: [JSONValue] { arrayValue.filter { $0.object != nil } }

    /// Число или строка — как есть, null — пусто, остальное — как JSON.
    var text: String {
        switch self {
        case .null: return ""
        case .bool(let value): return value ? "true" : "false"
        case .number(let value):
            return value.rounded() == value && abs(value) < 1e15 ? String(Int64(value)) : String(value)
        case .string(let value): return value
        case .array, .object: return jsonString
        }
    }

    var double: Double? {
        switch self {
        case .number(let value): value
        case .string(let value): Double(value)
        default: nil
        }
    }

    var int: Int? { double.map { Int($0) } }
    var int64: Int64? { double.map { Int64($0) } }

    var bool: Bool? {
        switch self {
        case .bool(let value): value
        case .string(let value): Bool(value)
        default: nil
        }
    }

    /// Значение как строка, если оно строка или число; иначе nil.
    var stringValue: String? {
        switch self {
        case .string(let value): value
        case .number, .bool: text
        default: nil
        }
    }

    var jsonString: String {
        switch self {
        case .null: return "null"
        case .bool(let value): return value ? "true" : "false"
        case .number: return text
        case .string(let value):
            let data = (try? JSONEncoder().encode(value)) ?? Data()
            return String(decoding: data, as: UTF8.self)
        case .array(let array): return "[" + array.map(\.jsonString).joined(separator: ",") + "]"
        case .object(let object):
            return "{" + object.map { JSONValue.string($0.key).jsonString + ":" + $0.value.jsonString }.joined(separator: ",") + "}"
        }
    }

    func string(_ key: String) -> String { self[key]?.text ?? "" }
    func array(_ key: String) -> [JSONValue] { self[key]?.arrayValue ?? [] }
    func objects(_ key: String) -> [JSONValue] { self[key]?.objects ?? [] }
}
