import Foundation

/// Правило «красного флага»: опасная Bash-команда. Запрос с флагом показывается красным,
/// и «Разрешить всегда» для него не предлагается.
public struct RedFlagRule: Equatable, Sendable {
    public var id: String
    public var title: String
    /// NSRegularExpression без учёта регистра; ищется в любом месте полной строки команды.
    public var pattern: String

    public init(id: String, title: String, pattern: String) {
        self.id = id
        self.title = title
        self.pattern = pattern
    }
}

/// Набор правил из файла пользователя (`red-flags.json`) или встроенный.
public struct RedFlagSet: Sendable {
    public var rules: [RedFlagRule]
    /// Что не так с файлом правил — текстом для пользователя.
    public var problems: [String]

    public init(rules: [RedFlagRule], problems: [String] = []) {
        self.rules = rules
        self.problems = problems
    }

    /// Все правила, под которые попадает команда. Флаги есть только у Bash.
    public func matches(toolName: String, input: JSONValue) -> [RedFlagRule] {
        guard toolName == "Bash", let cmd = input["command"]?.stringValue else { return [] }
        let range = NSRange(cmd.startIndex..., in: cmd)
        return rules.filter { rule in
            guard let re = Self.regex(rule.pattern) else { return false }
            return re.firstMatch(in: cmd, range: range) != nil
        }
    }

    static func regex(_ pattern: String) -> NSRegularExpression? {
        try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    // MARK: Файл

    /// Читает правила. Любая беда с файлом — встроенные правила плюс описание проблемы:
    /// сломанный файл не должен молча выключать защиту.
    public static func load(from url: URL) -> RedFlagSet {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else {
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data((defaultsJSON.pretty() + "\n").utf8).write(to: url, options: .atomic)
            return RedFlagSet(rules: defaults)
        }
        // Файл пользователя не перезаписываем: он сам его исправит.
        let name = url.lastPathComponent
        guard let data = try? Data(contentsOf: url) else {
            return RedFlagSet(rules: defaults, problems: ["\(name) не читается — действуют встроенные правила"])
        }
        let json: JSONValue
        do {
            json = try JSONValue.parse(data)
        } catch {
            return RedFlagSet(rules: defaults, problems: ["\(name): \(error) — действуют встроенные правила"])
        }
        guard let list = json["rules"]?.arrayValue else {
            return RedFlagSet(rules: defaults, problems: ["\(name): нет массива rules — действуют встроенные правила"])
        }
        // Пустой массив — осознанный выбор пользователя: правил нет.
        var rules: [RedFlagRule] = []
        var problems: [String] = []
        for (i, entry) in list.enumerated() {
            let id = entry["id"]?.stringValue ?? ""
            let label = id.isEmpty ? "№\(i + 1)" : id
            guard !id.isEmpty, let title = entry["title"]?.stringValue, !title.isEmpty,
                  let pattern = entry["pattern"]?.stringValue, !pattern.isEmpty else {
                problems.append("Правило \(label): нужны непустые id, title и pattern — пропущено")
                continue
            }
            guard regex(pattern) != nil else {
                problems.append("Правило \(label): неверное регулярное выражение — пропущено")
                continue
            }
            rules.append(RedFlagRule(id: id, title: title, pattern: pattern))
        }
        return RedFlagSet(rules: rules, problems: problems)
    }

    static var defaultsJSON: JSONValue {
        let list = defaults.map { r -> JSONValue in
            ["id": .string(r.id), "title": .string(r.title), "pattern": .string(r.pattern)]
        }
        return ["version": 1, "rules": .array(list)]
    }

    // MARK: Встроенные правила

    /// Начало имени команды: не хвост другого слова (`perform`, `legit`), но путь (`/bin/rm`) годится.
    private static let cmd = #"(?<![\w.-])"#
    /// Остаток одной простой команды: за `;`, `&`, `|` и перевод строки не заходим.
    private static let seg = #"[^;&|\n]*?"#
    /// Конец слова-аргумента.
    private static let end = #"(?=$|[\s;&|)"'])"#
    /// `git push`, в том числе `git -C dir push`.
    private static let gitPush = cmd + #"git\s+(?:"# + seg + #"\s)?push"#

    public static let defaults: [RedFlagRule] = [
        RedFlagRule(
            id: "push-protected",
            title: "Пуш в защищённую ветку (main, master, dev, develop)",
            // Ветка — отдельное слово или правая часть refspec (`HEAD:main`); `feature/dev-tools` и `develop-2` не подходят.
            pattern: gitPush + #"\s(?:"# + seg + #"[\s"'])?\+?(?:[^\s:;&|]*:)?(?:refs/heads/)?(?:main|master|dev|develop)"# + end
        ),
        RedFlagRule(
            id: "force",
            title: "Принудительная операция (--force, push -f, +refspec)",
            pattern: #"(?<![\w-])--force(?:-with-lease|-if-includes)?(?=$|[\s=;&|)"'])"#
                + "|" + gitPush + #"\s(?:"# + seg + #"\s)?(?:-[a-z]*f[a-z]*"# + end + #"|\+[^\s;&|]+)"#
        ),
        RedFlagRule(
            id: "mr-create",
            title: "Создание или слияние merge request / pull request",
            pattern: #"(?:(?<![\w-])-o\s*|--push-option[=\s]\s*)["']?merge_request\."#
                + "|" + cmd + #"glab\s+(?:"# + seg + #"\s)?mr\s+(?:create|new|merge|update|approve)"# + end
                + "|" + cmd + #"gh\s+(?:"# + seg + #"\s)?pr\s+(?:create|merge)"# + end
        ),
        RedFlagRule(
            id: "rm-rf",
            title: "Рекурсивное удаление без подтверждения (rm -rf)",
            // Два независимых условия на одну команду: есть рекурсия и есть force, в любом порядке и виде.
            pattern: cmd + #"rm(?=\s)"#
                + #"(?=[^;&|\n]*\s(?:-[a-z]*r[a-z]*|--recursive)"# + end + ")"
                + #"(?=[^;&|\n]*\s(?:-[a-z]*f[a-z]*|--force)"# + end + ")"
        ),
        RedFlagRule(
            id: "db-migrate",
            title: "Миграция или запись в базу данных",
            // У psql/pg_restore флаг — явный адрес сервера. `-h`/`-p` с учётом регистра: `-H` и `-P` у psql значат другое.
            pattern: cmd + #"alembic\s+(?:"# + seg + #"\s)?(?:upgrade|downgrade)(?![\w-])"#
                + "|" + cmd + #"prisma\s+(?:"# + seg + #"\s)?migrate\s+(?:deploy|reset)(?![\w-])"#
                + "|" + cmd + #"artisan\s+(?:"# + seg + #"\s)?migrate(?!\w)"#
                + "|" + #"(?<![\w-])manage\.py\s+(?:"# + seg + #"\s)?migrate(?!\w)"#
                + "|" + cmd + #"(?:psql|pg_restore)(?=\s)(?=[^;&|\n]*(?:\s(?-i:-[hp])|\s--(?:host|port)(?![\w-])|postgres(?:ql)?://))"#
        ),
    ]
}
