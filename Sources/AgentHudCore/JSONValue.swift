import Foundation

/// JSON с сохранением порядка ключей и исходного вида чисел.
/// Нужен, чтобы править `~/.claude/settings.json`, не перемешивая чужие настройки.
public enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(String)          // исходный текст числа: "3650", "1.5e3"
    case string(String)
    case array([JSONValue])
    case object(JSONObject)

    public static func int(_ v: Int) -> JSONValue { .number(String(v)) }
    public static func double(_ v: Double) -> JSONValue {
        if v.rounded() == v, abs(v) < 1e15 { return .number(String(Int(v))) }
        return .number(String(v))
    }

    public subscript(key: String) -> JSONValue? {
        get { if case .object(let o) = self { return o[key] } else { return nil } }
        set {
            guard case .object(var o) = self else { return }
            o[key] = newValue
            self = .object(o)
        }
    }

    public subscript(index: Int) -> JSONValue? {
        if case .array(let a) = self, a.indices.contains(index) { return a[index] }
        return nil
    }

    public var stringValue: String? { if case .string(let s) = self { return s } else { return nil } }
    public var boolValue: Bool? { if case .bool(let b) = self { return b } else { return nil } }
    public var doubleValue: Double? { if case .number(let n) = self { return Double(n) } else { return nil } }
    public var intValue: Int? { doubleValue.map { Int($0) } }
    public var arrayValue: [JSONValue]? { if case .array(let a) = self { return a } else { return nil } }
    public var objectValue: JSONObject? { if case .object(let o) = self { return o } else { return nil } }
    public var isNull: Bool { if case .null = self { return true } else { return false } }
}

public struct JSONObject: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public var key: String
        public var value: JSONValue
        public init(_ key: String, _ value: JSONValue) { self.key = key; self.value = value }
    }

    public var entries: [Entry]

    public init(_ entries: [Entry] = []) { self.entries = entries }
    public init(_ pairs: KeyValuePairs<String, JSONValue>) {
        self.entries = pairs.map { Entry($0.key, $0.value) }
    }

    public var keys: [String] { entries.map(\.key) }
    public var isEmpty: Bool { entries.isEmpty }

    /// Присваивание `nil` удаляет ключ. Новый ключ добавляется в конец, существующий меняется на месте.
    public subscript(key: String) -> JSONValue? {
        get { entries.first(where: { $0.key == key })?.value }
        set {
            if let i = entries.firstIndex(where: { $0.key == key }) {
                if let v = newValue { entries[i].value = v } else { entries.remove(at: i) }
            } else if let v = newValue {
                entries.append(Entry(key, v))
            }
        }
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .number(String(value)) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(JSONObject(elements.map { JSONObject.Entry($0.0, $0.1) }))
    }
    public init(nilLiteral: ()) { self = .null }
}

// MARK: - Разбор

public struct JSONParseError: Error, CustomStringConvertible {
    public let offset: Int
    public let reason: String
    public var description: String { "JSON: \(reason) (байт \(offset))" }
}

extension JSONValue {
    public static func parse(_ text: String) throws -> JSONValue {
        try parse(Data(text.utf8))
    }

    public static func parse(_ data: Data) throws -> JSONValue {
        var p = Parser(bytes: [UInt8](data))
        p.skipWhitespace()
        let v = try p.parseValue(depth: 0)
        p.skipWhitespace()
        guard p.i == p.bytes.count else { throw p.error("лишние символы после значения") }
        return v
    }

    private struct Parser {
        let bytes: [UInt8]
        var i = 0

        func error(_ r: String) -> JSONParseError { JSONParseError(offset: i, reason: r) }

        mutating func skipWhitespace() {
            while i < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[i]) { i += 1 }
        }

        mutating func expect(_ literal: String) throws {
            for b in literal.utf8 {
                guard i < bytes.count, bytes[i] == b else { throw error("ожидалось \(literal)") }
                i += 1
            }
        }

        mutating func parseValue(depth: Int) throws -> JSONValue {
            guard depth < 512 else { throw error("слишком глубокая вложенность") }
            guard i < bytes.count else { throw error("неожиданный конец") }
            switch bytes[i] {
            case UInt8(ascii: "{"): return try parseObject(depth: depth)
            case UInt8(ascii: "["): return try parseArray(depth: depth)
            case UInt8(ascii: "\""): return .string(try parseString())
            case UInt8(ascii: "t"): try expect("true"); return .bool(true)
            case UInt8(ascii: "f"): try expect("false"); return .bool(false)
            case UInt8(ascii: "n"): try expect("null"); return .null
            default: return try parseNumber()
            }
        }

        mutating func parseObject(depth: Int) throws -> JSONValue {
            i += 1
            var obj = JSONObject()
            skipWhitespace()
            if i < bytes.count, bytes[i] == UInt8(ascii: "}") { i += 1; return .object(obj) }
            while true {
                skipWhitespace()
                guard i < bytes.count, bytes[i] == UInt8(ascii: "\"") else { throw error("ожидался ключ") }
                let key = try parseString()
                skipWhitespace()
                try expect(":")
                skipWhitespace()
                let value = try parseValue(depth: depth + 1)
                // При дубликатах побеждает последний, как в JSON.parse.
                obj[key] = value
                skipWhitespace()
                guard i < bytes.count else { throw error("неожиданный конец объекта") }
                if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
                if bytes[i] == UInt8(ascii: "}") { i += 1; return .object(obj) }
                throw error("ожидалась , или }")
            }
        }

        mutating func parseArray(depth: Int) throws -> JSONValue {
            i += 1
            var arr: [JSONValue] = []
            skipWhitespace()
            if i < bytes.count, bytes[i] == UInt8(ascii: "]") { i += 1; return .array(arr) }
            while true {
                skipWhitespace()
                arr.append(try parseValue(depth: depth + 1))
                skipWhitespace()
                guard i < bytes.count else { throw error("неожиданный конец массива") }
                if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
                if bytes[i] == UInt8(ascii: "]") { i += 1; return .array(arr) }
                throw error("ожидалась , или ]")
            }
        }

        mutating func parseHex4() throws -> UInt32 {
            guard i + 4 <= bytes.count else { throw error("обрезанный \\u") }
            var v: UInt32 = 0
            for _ in 0..<4 {
                let c = bytes[i]
                v <<= 4
                switch c {
                case 0x30...0x39: v |= UInt32(c - 0x30)
                case 0x41...0x46: v |= UInt32(c - 0x41 + 10)
                case 0x61...0x66: v |= UInt32(c - 0x61 + 10)
                default: throw error("плохой \\u")
                }
                i += 1
            }
            return v
        }

        mutating func parseString() throws -> String {
            i += 1
            var out = [UInt8]()
            while true {
                guard i < bytes.count else { throw error("незакрытая строка") }
                let c = bytes[i]
                if c == UInt8(ascii: "\"") { i += 1; break }
                if c == UInt8(ascii: "\\") {
                    i += 1
                    guard i < bytes.count else { throw error("обрезанное экранирование") }
                    let e = bytes[i]; i += 1
                    switch e {
                    case UInt8(ascii: "\""): out.append(0x22)
                    case UInt8(ascii: "\\"): out.append(0x5C)
                    case UInt8(ascii: "/"): out.append(0x2F)
                    case UInt8(ascii: "b"): out.append(0x08)
                    case UInt8(ascii: "f"): out.append(0x0C)
                    case UInt8(ascii: "n"): out.append(0x0A)
                    case UInt8(ascii: "r"): out.append(0x0D)
                    case UInt8(ascii: "t"): out.append(0x09)
                    case UInt8(ascii: "u"):
                        var scalar = try parseHex4()
                        if (0xD800...0xDBFF).contains(scalar),
                           i + 6 <= bytes.count, bytes[i] == 0x5C, bytes[i + 1] == UInt8(ascii: "u") {
                            let save = i
                            i += 2
                            let low = try parseHex4()
                            if (0xDC00...0xDFFF).contains(low) {
                                scalar = 0x10000 + ((scalar - 0xD800) << 10) + (low - 0xDC00)
                            } else { i = save }
                        }
                        let u = Unicode.Scalar(scalar) ?? "\u{FFFD}"
                        out.append(contentsOf: Array(String(Character(u)).utf8))
                    default: throw error("неизвестное экранирование")
                    }
                } else {
                    out.append(c); i += 1
                }
            }
            return String(decoding: out, as: UTF8.self)
        }

        mutating func parseNumber() throws -> JSONValue {
            let start = i
            while i < bytes.count, "+-0123456789.eE".utf8.contains(bytes[i]) { i += 1 }
            guard i > start else { throw error("неожиданный символ") }
            let text = String(decoding: bytes[start..<i], as: UTF8.self)
            guard Double(text) != nil else { throw error("плохое число \(text)") }
            return .number(text)
        }
    }
}

// MARK: - Запись

extension JSONValue {
    /// Компактная запись в одну строку (для сокета и stdout хука).
    public func compact() -> String {
        var s = ""
        write(into: &s, indent: nil, level: 0)
        return s
    }

    /// Запись с отступом в 2 пробела — как `JSON.stringify(x, null, 2)` и `jq`.
    public func pretty(indent: Int = 2) -> String {
        var s = ""
        write(into: &s, indent: indent, level: 0)
        return s
    }

    private func write(into s: inout String, indent: Int?, level: Int) {
        switch self {
        case .null: s += "null"
        case .bool(let b): s += b ? "true" : "false"
        case .number(let n): s += n
        case .string(let str): JSONValue.writeString(str, into: &s)
        case .array(let a):
            if a.isEmpty { s += "[]"; return }
            s += "["
            for (k, v) in a.enumerated() {
                if k > 0 { s += "," }
                if let ind = indent { s += "\n" + String(repeating: " ", count: ind * (level + 1)) }
                v.write(into: &s, indent: indent, level: level + 1)
            }
            if let ind = indent { s += "\n" + String(repeating: " ", count: ind * level) }
            s += "]"
        case .object(let o):
            if o.isEmpty { s += "{}"; return }
            s += "{"
            for (k, e) in o.entries.enumerated() {
                if k > 0 { s += "," }
                if let ind = indent { s += "\n" + String(repeating: " ", count: ind * (level + 1)) }
                JSONValue.writeString(e.key, into: &s)
                s += indent == nil ? ":" : ": "
                e.value.write(into: &s, indent: indent, level: level + 1)
            }
            if let ind = indent { s += "\n" + String(repeating: " ", count: ind * level) }
            s += "}"
        }
    }

    static func writeString(_ str: String, into s: inout String) {
        s += "\""
        for u in str.unicodeScalars {
            switch u {
            case "\"": s += "\\\""
            case "\\": s += "\\\\"
            case "\n": s += "\\n"
            case "\r": s += "\\r"
            case "\t": s += "\\t"
            case "\u{08}": s += "\\b"
            case "\u{0C}": s += "\\f"
            default:
                if u.value < 0x20 {
                    s += String(format: "\\u%04x", u.value)
                } else {
                    s.unicodeScalars.append(u)
                }
            }
        }
        s += "\""
    }
}
