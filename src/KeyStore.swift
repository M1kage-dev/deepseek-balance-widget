import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// Ключ API: Keychain → переменная окружения → .env файл.
// Чистая часть (resolve/sanitize) тестируется без обращения к Keychain.
// ─────────────────────────────────────────────────────────────────────────────

enum KeySource: String {
    case keychain
    case environment
    case dotenv
}

struct ResolvedKey: Equatable {
    let value: String
    let source: KeySource
}

enum KeyStore {
    /// Порядок поиска: Keychain, потом env, потом файл. Пустые и «кавычковые»
    /// значения игнорируются — иначе виджет молча шлёт пустой Bearer.
    static func resolve(env: [String: String],
                        envVar: String,
                        keychain: () -> String?,
                        dotenv: () -> String?) -> ResolvedKey? {
        if let raw = keychain() {
            let v = sanitize(raw)
            if !v.isEmpty { return ResolvedKey(value: v, source: .keychain) }
        }
        if let raw = env[envVar] {
            let v = sanitize(raw)
            if !v.isEmpty { return ResolvedKey(value: v, source: .environment) }
        }
        if let raw = dotenv() {
            let v = sanitize(raw)
            if !v.isEmpty { return ResolvedKey(value: v, source: .dotenv) }
        }
        return nil
    }

    /// Срезает пробелы, \r\n и парные кавычки — .env часто пишут как KEY="sk-…"
    static func sanitize(_ raw: String) -> String {
        var v = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if v.count >= 2, let first = v.first, let last = v.last,
           (first == "\"" && last == "\"") || (first == "'" && last == "'") {
            v = String(v.dropFirst().dropLast())
        }
        return v.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Ищет KEY=… в тексте .env (первое совпадение).
    static func value(inDotenv text: String, key: String) -> String? {
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") { continue }
            guard trimmed.hasPrefix(key + "=") else { continue }
            let value = sanitize(String(trimmed.dropFirst(key.count + 1)))
            return value.isEmpty ? nil : value
        }
        return nil
    }

    // MARK: Keychain (macOS security CLI — без сторонних зависимостей)

    static func readKeychain(service: String, account: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", service, "-a", account, "-w"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func writeKeychain(value: String, service: String, account: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["add-generic-password", "-U", "-s", service, "-a", account, "-w", value]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    @discardableResult
    static func deleteKeychain(service: String, account: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["delete-generic-password", "-s", service, "-a", account]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}
