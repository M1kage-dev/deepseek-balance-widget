import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// Пути и конфиг. Файл намеренно не зависит от AppKit — чтобы его можно было
// покрывать тестами без GUI.
// ─────────────────────────────────────────────────────────────────────────────

enum Paths {
    /// Данные живут в ~/Library/Application Support/DeepSeekBalance.
    /// DEEPSEEK_WIDGET_DIR переопределяет базу (тесты, несколько профилей).
    static func defaultBase(_ env: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let dir = env["DEEPSEEK_WIDGET_DIR"], !dir.trimmingCharacters(in: .whitespaces).isEmpty {
            return URL(fileURLWithPath: (dir as NSString).expandingTildeInPath, isDirectory: true)
        }
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("DeepSeekBalance", isDirectory: true)
    }

    static let base = defaultBase()
    static var config: URL { base.appendingPathComponent("config.json") }
    static var state: URL { base.appendingPathComponent("state.json") }
    static var log: URL { base.appendingPathComponent("widget.log") }
}

/// Как файл читается: всё опционально, чтобы задавать только нужное.
struct ConfigFile: Decodable {
    var refresh_seconds: Int?
    var currency: String?
    var locale: String?
    var title: String?
    var width: CGFloat?
    var height: CGFloat?
    var window_level: String?
    var start_x: CGFloat?
    var start_y: CGFloat?
    var keep_days: Int?
    var spark_hours: Int?
    var api_key_env: String?
    var env_file: String?
    var keychain_service: String?
    var keychain_account: String?
}

struct Config {
    static let supportedLocales = ["en", "ru"]
    static let supportedLevels = ["desktop", "floating", "normal"]

    var refresh_seconds = 300
    var currency = "CNY"
    var locale = "en"
    var title = "DEEPSEEK API"
    var width: CGFloat = 340
    var height: CGFloat = 196
    var window_level = "desktop"
    var start_x: CGFloat?
    var start_y: CGFloat?
    var keep_days = 30
    var spark_hours = 24
    var api_key_env = "DEEPSEEK_API_KEY"
    var env_file = ""
    var keychain_service = "deepseek-balance-widget"
    var keychain_account = "api-key"

    init() {}

    init(_ f: ConfigFile) {
        if let v = f.refresh_seconds { refresh_seconds = max(15, v) }
        if let v = f.currency { currency = v.trimmingCharacters(in: .whitespaces).uppercased() }
        if let v = f.locale, Config.supportedLocales.contains(v.lowercased()) { locale = v.lowercased() }
        if let v = f.title, !v.isEmpty { title = v }
        if let v = f.width { width = max(240, v) }
        if let v = f.height { height = max(140, v) }
        if let v = f.window_level, Config.supportedLevels.contains(v.lowercased()) { window_level = v.lowercased() }
        start_x = f.start_x
        start_y = f.start_y
        if let v = f.keep_days { keep_days = max(1, v) }
        if let v = f.spark_hours { spark_hours = max(1, v) }
        if let v = f.api_key_env, !v.isEmpty { api_key_env = v }
        if let v = f.env_file { env_file = v }
        if let v = f.keychain_service, !v.isEmpty { keychain_service = v }
        if let v = f.keychain_account, !v.isEmpty { keychain_account = v }
    }

    /// Читает config.json; битый или отсутствующий файл → значения по умолчанию.
    static func load(from url: URL) -> Config {
        guard let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(ConfigFile.self, from: data) else {
            return Config()
        }
        return Config(file)
    }

    /// Для первого запуска: создаёт config.json, чтобы человеку было что править.
    func writeTemplate(to url: URL) {
        var out: [String: Any] = [
            "refresh_seconds": refresh_seconds,
            "currency": currency,
            "locale": locale,
            "title": title,
            "width": Int(width),
            "height": Int(height),
            "window_level": window_level,
            "keep_days": keep_days,
            "spark_hours": spark_hours,
            "api_key_env": api_key_env,
            "keychain_service": keychain_service,
            "keychain_account": keychain_account,
        ]
        if !env_file.isEmpty { out["env_file"] = env_file }
        if let x = start_x, let y = start_y { out["start_x"] = Double(x); out["start_y"] = Double(y) }
        guard let data = try? JSONSerialization.data(withJSONObject: out,
                                                     options: [.prettyPrinted, .sortedKeys]) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
