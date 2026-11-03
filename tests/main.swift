import Foundation

// Тесты без XCTest: обычный исполняемый файл. Запуск — ./test.sh
// Файл обязан называться main.swift: swiftc разрешает top-level код только в нём.

var failures = 0
func check(_ name: String, _ cond: Bool, _ detail: String = "") {
    if cond { print("ok   \(name)") }
    else { failures += 1; print("FAIL \(name) \(detail)") }
}
func eq(_ name: String, _ got: Double, _ want: Double, _ eps: Double = 0.001) {
    check(name, abs(got - want) < eps, "got \(got), want \(want)")
}

// MARK: - траты

var cal = Calendar(identifier: .gregorian)
cal.timeZone = TimeZone(identifier: "Asia/Yekaterinburg")!
let fmt = ISO8601DateFormatter()
fmt.timeZone = cal.timeZone
func day(_ s: String) -> Date { fmt.date(from: s)! }
func ts(_ s: String) -> Int { Int(fmt.date(from: s)!.timeIntervalSince1970) }
func sample(_ iso: String, _ cny: Double?) -> BalanceSample {
    BalanceSample(t: ts(iso), cny: cny, usd: nil)
}

let today = day("2026-11-04T12:00:00+05:00")
let cny: (BalanceSample) -> Double? = { $0.cny }

let drops = [sample("2026-11-04T00:10:00+05:00", 76.14),
             sample("2026-11-04T08:00:00+05:00", 76.00),
             sample("2026-11-04T09:30:00+05:00", 75.72)]
let d1 = SpendLogic.daySpend(drops, day: today, value: cny, cal: cal)
eq("drops суммируются", d1.spent, 0.42)
check("drops: 3 наблюдения", d1.samples == 3, "\(d1.samples)")
check("drops: покрывает сутки", d1.coversFromMidnight)

let topup = [sample("2026-11-04T00:10:00+05:00", 75.72),
             sample("2026-11-04T10:00:00+05:00", 100.00),
             sample("2026-11-04T11:00:00+05:00", 99.80)]
eq("пополнение не считается тратой",
   SpendLogic.daySpend(topup, day: today, value: cny, cal: cal).spent, 0.20)

let mixed = [sample("2026-11-03T23:50:00+05:00", 90.00),
             sample("2026-11-04T00:10:00+05:00", 76.14),
             sample("2026-11-04T01:10:00+05:00", 76.04)]
let d3 = SpendLogic.daySpend(mixed, day: today, value: cny, cal: cal)
eq("вчерашний баланс не в тратах сегодня", d3.spent, 0.10)
check("вчерашний не в счётчике", d3.samples == 2, "\(d3.samples)")

let single = [sample("2026-11-04T09:00:00+05:00", 76.14)]
let d4 = SpendLogic.daySpend(single, day: today, value: cny, cal: cal)
eq("одно наблюдение: 0", d4.spent, 0)
check("одно наблюдение: не покрывает сутки", d4.coversFromMidnight == false)
check("пустая история: 0", SpendLogic.daySpend([], day: today, value: cny, cal: cal).spent == 0)

let noCurrency = [sample("2026-11-04T00:10:00+05:00", nil),
                  BalanceSample(t: ts("2026-11-04T01:10:00+05:00"), cny: 76.00, usd: 10.0)]
let d5 = SpendLogic.daySpend(noCurrency, day: today, value: cny, cal: cal)
eq("nil-валюта пропущена", d5.spent, 0)
check("nil-валюта не в счётчике", d5.samples == 1, "\(d5.samples)")

let now = day("2026-11-04T12:00:00+05:00")
let nowT = ts("2026-11-04T12:00:00+05:00")
let hist = [sample("2026-11-04T11:50:00+05:00", 76.10),
            sample("2026-11-04T11:55:00+05:00", 76.00),
            sample("2026-11-04T11:58:00+05:00", 75.72)]
let sp = SpendLogic.spark(hist, now: now, window: 86400, maxPoints: 120, value: cny)
check("спарклайн: 3 замера + дотяжка до now", sp.count == 4, "\(sp.count)")
eq("спарклайн: первая точка 76.10", sp.first?.v ?? 0, 76.10)
eq("спарклайн: последняя точка 75.72", sp.last?.v ?? 0, 75.72)
check("спарклайн: последняя точка на now", sp.last?.t == nowT, "\(String(describing: sp.last?.t))")
check("спарклайн: время возрастает", zip(sp, sp.dropFirst()).allSatisfy { $0.t <= $1.t })

var many: [BalanceSample] = []
var bal = 90.0
for i in 0..<600 {
    bal -= 0.01
    many.append(BalanceSample(t: nowT - 86400 + i * 144, cny: bal, usd: nil))
}
let sp2 = SpendLogic.spark(many, now: now, window: 86400, maxPoints: 120, value: cny)
check("прореживание: не больше maxPoints+1", sp2.count <= 121, "\(sp2.count)")
check("прореживание: минимум 60 точек", sp2.count >= 60, "\(sp2.count)")
eq("прореживание: конец = последний баланс", sp2.last?.v ?? 0, many.last?.cny ?? 0)
check("спарклайн: пусто", SpendLogic.spark([], now: now, window: 86400, maxPoints: 120, value: cny).isEmpty)
let outside = [sample("2026-11-02T12:00:00+05:00", 80.0)]
check("спарклайн: за окном отброшено",
      SpendLogic.spark(outside, now: now, window: 86400, maxPoints: 120, value: cny).isEmpty)

// MARK: - конфиг

let defaults = Config()
check("конфиг: refresh 300", defaults.refresh_seconds == 300, "\(defaults.refresh_seconds)")
check("конфиг: локаль en", defaults.locale == "en", defaults.locale)
check("конфиг: валюта CNY", defaults.currency == "CNY", defaults.currency)
check("конфиг: уровень desktop", defaults.window_level == "desktop", defaults.window_level)
check("конфиг: ключ ищется в Keychain", defaults.keychain_service == "deepseek-balance-widget", defaults.keychain_service)

func cfg(_ json: String) -> Config {
    let data = Data(json.utf8)
    guard let file = try? JSONDecoder().decode(ConfigFile.self, from: data) else { return Config() }
    return Config(file)
}

let custom = cfg("""
{"refresh_seconds": 90, "currency": "usd ", "locale": "RU", "title": "MY API",
 "width": 420, "height": 220, "window_level": "floating", "keep_days": 7, "spark_hours": 12}
""")
check("конфиг: refresh переопределён", custom.refresh_seconds == 90, "\(custom.refresh_seconds)")
check("конфиг: валюта нормализована", custom.currency == "USD", custom.currency)
check("конфиг: локаль нормализована", custom.locale == "ru", custom.locale)
check("конфиг: заголовок", custom.title == "MY API", custom.title)
check("конфиг: размер", custom.width == 420 && custom.height == 220)
check("конфиг: уровень floating", custom.window_level == "floating", custom.window_level)

let clamped = cfg("""
{"refresh_seconds": 5, "width": 100, "height": 20, "keep_days": 0, "spark_hours": 0}
""")
check("конфиг: refresh не меньше 15", clamped.refresh_seconds == 15, "\(clamped.refresh_seconds)")
check("конфиг: ширина не меньше 240", clamped.width == 240, "\(clamped.width)")
check("конфиг: высота не меньше 140", clamped.height == 140, "\(clamped.height)")
check("конфиг: keep_days не меньше 1", clamped.keep_days == 1, "\(clamped.keep_days)")
check("конфиг: spark_hours не меньше 1", clamped.spark_hours == 1, "\(clamped.spark_hours)")

let invalid = cfg("""
{"locale": "de", "window_level": "nowhere", "title": "", "refresh_seconds": 300}
""")
check("конфиг: неизвестная локаль → en", invalid.locale == "en", invalid.locale)
check("конфиг: неизвестный уровень → desktop", invalid.window_level == "desktop", invalid.window_level)
check("конфиг: пустой заголовок не затирает дефолт", invalid.title == "DEEPSEEK API", invalid.title)
check("конфиг: битый json → дефолты",
      Config.load(from: URL(fileURLWithPath: "/tmp/definitely-missing-\(UUID().uuidString).json")).refresh_seconds == 300)

// шаблон config.json пишется и читается обратно
let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("dsw-test-\(UUID().uuidString)")
let tmpConfig = tmpDir.appendingPathComponent("config.json")
var rounded = Config()
rounded.refresh_seconds = 120
rounded.locale = "ru"
rounded.writeTemplate(to: tmpConfig)
let reread = Config.load(from: tmpConfig)
check("конфиг: шаблон записан", FileManager.default.fileExists(atPath: tmpConfig.path))
check("конфиг: шаблон читается обратно", reread.refresh_seconds == 120 && reread.locale == "ru",
      "\(reread.refresh_seconds)/\(reread.locale)")
try? FileManager.default.removeItem(at: tmpDir)

// MARK: - пути

let overridden = Paths.defaultBase(["DEEPSEEK_WIDGET_DIR": "/tmp/dsw-profile"])
check("пути: override из env", overridden.path == "/tmp/dsw-profile", overridden.path)
let standard = Paths.defaultBase([:])
check("пути: Application Support/DeepSeekBalance",
      standard.path.hasSuffix("Library/Application Support/DeepSeekBalance"), standard.path)

// MARK: - ключ

let kc = KeyStore.resolve(env: ["DEEPSEEK_API_KEY": "test-key-env"],
                          envVar: "DEEPSEEK_API_KEY",
                          keychain: { "test-key-keychain" },
                          dotenv: { "test-key-dotenv" })
check("ключ: Keychain важнее env", kc?.value == "test-key-keychain" && kc?.source == .keychain,
      "\(String(describing: kc))")

let envOnly = KeyStore.resolve(env: ["DEEPSEEK_API_KEY": "test-key-env"], envVar: "DEEPSEEK_API_KEY",
                               keychain: { "   " }, dotenv: { "test-key-dotenv" })
check("ключ: пустой Keychain → env", envOnly?.value == "test-key-env" && envOnly?.source == .environment,
      "\(String(describing: envOnly))")

let dotenvOnly = KeyStore.resolve(env: ["": ""], envVar: "DEEPSEEK_API_KEY",
                                  keychain: { nil }, dotenv: { "test-key-dotenv" })
check("ключ: env пуст → .env файл", dotenvOnly?.value == "test-key-dotenv" && dotenvOnly?.source == .dotenv,
      "\(String(describing: dotenvOnly))")

check("ключ: ничего нет → nil",
      KeyStore.resolve(env: [:], envVar: "DEEPSEEK_API_KEY", keychain: { nil }, dotenv: { nil }) == nil)

check("ключ: кавычки и \\r\\n срезаны",
      KeyStore.sanitize("  \"test-key-abc\"\r\n") == "test-key-abc", KeyStore.sanitize("  \"test-key-abc\"\r\n"))
check("ключ: одинарные кавычки срезаны", KeyStore.sanitize("'test-key-abc'") == "test-key-abc")
check("ключ: обычное значение не портится", KeyStore.sanitize("test-key-abc") == "test-key-abc")
check("ключ: одиночная кавычка не режется", KeyStore.sanitize("\"test-key-abc") == "\"test-key-abc")

check("env-файл: первое совпадение",
      KeyStore.value(inDotenv: "A=1\nDEEPSEEK_API_KEY=test-key-one\nDEEPSEEK_API_KEY=test-key-two\n",
                     key: "DEEPSEEK_API_KEY") == "test-key-one")
check("env-файл: комментарии игнорируются",
      KeyStore.value(inDotenv: "# DEEPSEEK_API_KEY=test-key-bad\nDEEPSEEK_API_KEY=\"test-key-good\"\n",
                     key: "DEEPSEEK_API_KEY") == "test-key-good")
check("env-файл: другое имя ключа",
      KeyStore.value(inDotenv: "DEEPSEEK_API_KEY=test-key-a\nMY_KEY=test-key-b\n", key: "MY_KEY") == "test-key-b")
check("env-файл: нет ключа → nil",
      KeyStore.value(inDotenv: "OTHER=1\n", key: "DEEPSEEK_API_KEY") == nil)
check("env-файл: пустое значение → nil",
      KeyStore.value(inDotenv: "DEEPSEEK_API_KEY=\n", key: "DEEPSEEK_API_KEY") == nil)

if failures > 0 { print("\n\(failures) FAILED"); exit(1) }
print("\nall green")
