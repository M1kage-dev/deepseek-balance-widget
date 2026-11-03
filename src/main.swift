import AppKit
import WebKit

// ─────────────────────────────────────────────────────────────────────────────
// DeepSeek Balance — виджет рабочего стола: баланс DeepSeek API и траты за
// сегодня. Один процесс: опрос /user/balance → история в state.json → рендер
// в прозрачной карточке WKWebView.
// ─────────────────────────────────────────────────────────────────────────────

let APP_VERSION = "1.0.0"

// MARK: - логирование

func log(_ message: String) {
    let stamp = ISO8601DateFormatter().string(from: Date())
    let line = "\(stamp) \(message)\n"
    try? FileManager.default.createDirectory(at: Paths.base, withIntermediateDirectories: true)
    if let handle = try? FileHandle(forWritingTo: Paths.log) {
        handle.seekToEndOfFile()
        handle.write(Data(line.utf8))
        try? handle.close()
    } else {
        try? line.write(to: Paths.log, atomically: true, encoding: .utf8)
    }
}

// MARK: - локализация строк приложения

struct L10n {
    let locale: String
    func t(_ en: String, _ ru: String) -> String { locale == "ru" ? ru : en }
}

// MARK: - состояние

struct WidgetState: Codable {
    var frame_x: CGFloat?
    var frame_y: CGFloat?
    var samples: [BalanceSample] = []
}

// MARK: - окно и вэб-вью

final class WidgetWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class WidgetWebView: WKWebView {
    /// Полоса сверху, за которую таскаем окно.
    static let dragBand: CGFloat = 30
    var onContextMenu: (() -> Void)?
    var onDragFinished: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        let localised = convert(event.locationInWindow, from: nil)
        let fromTop = isFlipped ? localised.y : bounds.height - localised.y
        if fromTop <= WidgetWebView.dragBand, event.clickCount == 1 {
            window?.performDrag(with: event)
            onDragFinished?()
            return
        }
        super.mouseDown(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        onContextMenu?()
    }
}

/// WKWebView по умолчанию рисует светлую подложку — скругления CSS тогда торчат
/// серыми уголками. Гасим подложку и клипуем по радиусу.
func configureTransparency(_ webView: WKWebView, cornerRadius: CGFloat = 16) {
    webView.setValue(false, forKey: "drawsBackground")
    if #available(macOS 12.0, *) { webView.underPageBackgroundColor = .clear }
    webView.wantsLayer = true
    webView.layer?.backgroundColor = NSColor.clear.cgColor
    webView.layer?.cornerRadius = cornerRadius
    webView.layer?.masksToBounds = true
}

/// html из бандла; DEEPSEEK_WIDGET_HTML позволяет отлаживать вёрстку без сборки.
func widgetHTML() -> URL? {
    if let dev = ProcessInfo.processInfo.environment["DEEPSEEK_WIDGET_HTML"],
       !dev.isEmpty, FileManager.default.fileExists(atPath: dev) {
        return URL(fileURLWithPath: (dev as NSString).expandingTildeInPath)
    }
    return Bundle.main.url(forResource: "widget", withExtension: "html")
}

// MARK: - приложение

final class WidgetApp: NSObject, NSApplicationDelegate, WKScriptMessageHandler,
                       WKNavigationDelegate, NSWindowDelegate {

    var config: Config = .load(from: Paths.config)
    var state = WidgetState()
    var window: WidgetWindow!
    var webView: WidgetWebView!
    var timer: Timer?
    var lastSuccess: Date?
    var lastError: String?
    var polling = false
    var pageLoaded = false

    var l10n: L10n { L10n(locale: config.locale) }

    // MARK: lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let bundleID = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
               .contains(where: { $0 != NSRunningApplication.current }) {
            log("уже запущен, выхожу")
            NSApp.terminate(nil)
            return
        }
        try? FileManager.default.createDirectory(at: Paths.base, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: Paths.config.path) {
            config.writeTemplate(to: Paths.config)
        }
        config = Config.load(from: Paths.config)
        loadState()
        buildWindow()
        loadPage()
        startTimer()
        poll()
        if resolvedKey() == nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.promptForKey(auto: true) }
        }
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    private func loadState() {
        if let data = try? Data(contentsOf: Paths.state),
           let decoded = try? JSONDecoder().decode(WidgetState.self, from: data) {
            state = decoded
        }
    }

    private func saveState() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(state) else { return }
        try? FileManager.default.createDirectory(at: Paths.base, withIntermediateDirectories: true)
        try? data.write(to: Paths.state, options: .atomic)
    }

    private func level(for name: String) -> NSWindow.Level {
        switch name {
        case "floating": return .floating
        case "normal": return .normal
        // +1: выше иконок Finder, иначе клики уходят в рабочий стол, а не в виджет
        default: return NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        }
    }

    private func buildWindow() {
        let savedPoint = state.frame_x.flatMap { fx in state.frame_y.map { CGPoint(x: fx, y: $0) } }
        let screen = savedPoint.flatMap { p in NSScreen.screens.first { $0.frame.contains(p) } }
            ?? NSScreen.screens.first ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        // по умолчанию — верхний правый угол основного экрана
        var x = state.frame_x ?? config.start_x ?? (visible.maxX - config.width - 48)
        var y = state.frame_y ?? config.start_y ?? (visible.maxY - config.height - 56)
        x = min(max(x, visible.minX + 4), visible.maxX - config.width - 4)
        y = min(max(y, visible.minY + 4), visible.maxY - config.height - 4)

        window = WidgetWindow(contentRect: NSRect(x: x, y: y, width: config.width, height: config.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = level(for: config.window_level)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.isReleasedWhenClosed = false
        window.delegate = self

        let userContent = WKUserContentController()
        userContent.add(self, name: "widget")
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = userContent
        configuration.suppressesIncrementalRendering = false

        webView = WidgetWebView(frame: NSRect(origin: .zero, size: window.frame.size),
                                configuration: configuration)
        webView.navigationDelegate = self
        webView.autoresizingMask = [.width, .height]
        configureTransparency(webView)
        webView.onContextMenu = { [weak self] in self?.showMenu() }
        webView.onDragFinished = { [weak self] in
            guard let self else { return }
            self.state.frame_x = self.window.frame.origin.x
            self.state.frame_y = self.window.frame.origin.y
            self.saveState()
        }
        window.contentView = webView
        window.orderFrontRegardless()
    }

    private func loadPage() {
        guard let url = widgetHTML() else {
            log("widget.html не найден")
            return
        }
        webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    }

    // MARK: ключ

    private func dotenvValue() -> String? {
        guard !config.env_file.isEmpty else { return nil }
        let path = (config.env_file as NSString).expandingTildeInPath
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        return KeyStore.value(inDotenv: text, key: config.api_key_env)
    }

    func resolvedKey() -> ResolvedKey? {
        KeyStore.resolve(env: ProcessInfo.processInfo.environment,
                         envVar: config.api_key_env,
                         keychain: { KeyStore.readKeychain(service: self.config.keychain_service,
                                                           account: self.config.keychain_account) },
                         dotenv: { self.dotenvValue() })
    }

    private func promptForKey(auto: Bool) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = l10n.t("DeepSeek API key", "Ключ DeepSeek API")
        alert.informativeText = l10n.t(
            "The key is stored in the macOS Keychain. This app never writes it to disk.",
            "Ключ сохраняется в Keychain macOS. Приложение не пишет его на диск.")
        alert.addButton(withTitle: l10n.t("Save", "Сохранить"))
        alert.addButton(withTitle: l10n.t("Cancel", "Отмена"))
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "sk-…"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else {
            if !auto { render() }
            return
        }
        let value = KeyStore.sanitize(field.stringValue)
        guard !value.isEmpty else { return }
        if KeyStore.writeKeychain(value: value, service: config.keychain_service,
                                  account: config.keychain_account) {
            lastError = nil
            poll()
        } else {
            lastError = l10n.t("could not save key to Keychain", "не удалось сохранить ключ в Keychain")
            render()
        }
    }

    // MARK: опрос

    private func startTimer() {
        timer?.invalidate()
        let interval = TimeInterval(config.refresh_seconds)
        let newTimer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.poll() }
        newTimer.tolerance = min(10, interval * 0.1)
        RunLoop.main.add(newTimer, forMode: .common)
        timer = newTimer
    }

    func poll() {
        guard !polling else { return }
        guard let key = resolvedKey() else {
            finishWith(error: l10n.t("no API key", "нет ключа API"))
            return
        }
        polling = true
        var request = URLRequest(url: URL(string: "https://api.deepseek.com/user/balance")!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(key.value)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 25

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.polling = false
                if let error {
                    self.finishWith(error: "\(self.l10n.t("network", "сеть")): \(error.localizedDescription)")
                    return
                }
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard status == 200, let data else {
                    self.finishWith(error: status == 401
                        ? self.l10n.t("key rejected (401)", "ключ отклонён (401)")
                        : "HTTP \(status)")
                    return
                }
                self.apply(data: data)
            }
        }.resume()
    }

    private func apply(data: Data) {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let infos = root["balance_infos"] as? [[String: Any]] else {
            finishWith(error: l10n.t("unexpected response", "непонятный ответ"))
            return
        }
        func number(_ dict: [String: Any], _ key: String) -> Double? {
            if let s = dict[key] as? String { return Double(s) }
            if let d = dict[key] as? Double { return d }
            if let i = dict[key] as? Int { return Double(i) }
            return nil
        }
        var cny: Double?
        var usd: Double?
        for info in infos {
            switch (info["currency"] as? String)?.uppercased() {
            case "CNY": cny = number(info, "total_balance")
            case "USD": usd = number(info, "total_balance")
            default: break
            }
        }
        guard cny != nil || usd != nil else {
            finishWith(error: l10n.t("no balance in response", "в ответе нет баланса"))
            return
        }
        let now = Int(Date().timeIntervalSince1970)
        if let last = state.samples.last, now - last.t < 45 {
            state.samples[state.samples.count - 1] = BalanceSample(t: now, cny: cny ?? last.cny, usd: usd ?? last.usd)
        } else {
            state.samples.append(BalanceSample(t: now, cny: cny, usd: usd))
        }
        pruneSamples(now: now)
        saveState()
        lastError = nil
        lastSuccess = Date()
        log("balance=\(cny.map { String(format: "%.2f", $0) } ?? "—") samples=\(state.samples.count)")
        render()
    }

    private func pruneSamples(now: Int) {
        let cutoff = now - config.keep_days * 86400
        if let firstKept = state.samples.firstIndex(where: { $0.t >= cutoff }), firstKept > 0 {
            state.samples.removeFirst(firstKept)
        }
    }

    private func finishWith(error: String) {
        lastError = error
        log("error: \(error)")
        render()
    }

    // MARK: рендер

    private func render() {
        guard pageLoaded else { return }
        let json = WidgetApp.jsonString(payload())
        webView.evaluateJavaScript("window.render(\(json));") { _, error in
            if let error { log("js: \(error.localizedDescription)") }
        }
    }

    static func jsonString(_ object: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    func payload(now: Date = Date()) -> [String: Any] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        let value: (BalanceSample) -> Double? = { self.config.currency == "USD" ? $0.usd : $0.cny }
        let today = SpendLogic.daySpend(state.samples, day: now, value: value, cal: calendar)

        var week = 0.0
        var weekKnown = false
        for offset in 0..<7 {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: now) else { continue }
            let spend = SpendLogic.daySpend(state.samples, day: day, value: value, cal: calendar)
            if spend.samples >= 2 { weekKnown = true }
            week += spend.spent
        }

        let spark = SpendLogic.spark(state.samples, now: now,
                                     window: Double(config.spark_hours) * 3600,
                                     maxPoints: 160, value: value)
        let balance = state.samples.last.flatMap(value)

        let hhmm = DateFormatter()
        hhmm.dateFormat = "HH:mm"
        hhmm.timeZone = calendar.timeZone
        let firstHM = today.firstT.map { hhmm.string(from: Date(timeIntervalSince1970: TimeInterval($0))) }
        let stale = lastSuccess.map { now.timeIntervalSince($0) > Double(config.refresh_seconds) * 3 } ?? true
        let hasKey = resolvedKey() != nil

        var out: [String: Any] = [
            "ok": lastError == nil && balance != nil,
            "stale": stale,
            "has_key": hasKey,
            "locale": config.locale,
            "title": config.title,
            "currency": config.currency,
            "symbol": config.currency == "USD" ? "$" : "¥",
            "balance": balance ?? NSNull(),
            "week": weekKnown ? week : NSNull(),
            "spark": spark.map { [$0.t, $0.v] as [Any] },
            "interval": config.refresh_seconds,
            "updated_text": hhmm.string(from: now),
            "points": state.samples.filter { $0.t > Int(now.timeIntervalSince1970) - 86400 }.count,
            "today": [
                "spent": today.spent,
                "samples": today.samples,
                "covers": today.coversFromMidnight,
                "from": firstHM ?? NSNull(),
            ] as [String: Any],
        ]
        out["error"] = lastError ?? NSNull()
        return out
    }

    // MARK: события

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pageLoaded = true
        render()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        log("html: \(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        log("html: \(error.localizedDescription)")
    }

    func userContentController(_ userContentController: WKUserContentController,
                              didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], (body["action"] as? String) == "refresh" else { return }
        poll()
    }

    func windowDidMove(_ notification: Notification) {
        state.frame_x = window.frame.origin.x
        state.frame_y = window.frame.origin.y
        saveState()
    }

    // MARK: меню

    private func showMenu() {
        let menu = NSMenu()
        func item(_ title: String, _ action: Selector, _ key: String = "") {
            let entry = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
            entry.target = self
        }
        item(l10n.t("Refresh now", "Обновить сейчас"), #selector(menuRefresh))
        item(l10n.t("Set API key…", "Указать ключ API…"), #selector(menuKey))
        menu.addItem(.separator())
        item(l10n.t("Open config.json", "Открыть config.json"), #selector(menuConfig))
        item(l10n.t("Show data folder", "Открыть папку данных"), #selector(menuFolder))
        menu.addItem(.separator())
        item(l10n.t("Hide for an hour", "Скрыть на час"), #selector(menuHide))
        item(l10n.t("Quit", "Выход"), #selector(menuQuit), "q")
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    @objc private func menuRefresh() { poll() }
    @objc private func menuKey() { promptForKey(auto: false) }
    @objc private func menuConfig() { NSWorkspace.shared.open(Paths.config) }
    @objc private func menuFolder() { NSWorkspace.shared.activateFileViewerSelecting([Paths.state]) }

    @objc private func menuHide() {
        window.orderOut(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3600) { [weak self] in
            self?.window.orderFrontRegardless()
        }
    }

    @objc private func menuQuit() { NSApp.terminate(nil) }
}

// MARK: - снапшот: рендер карточки в PNG без показа на экране

final class Snapshotter: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    let out: URL
    let payload: [String: Any]
    let size: NSSize
    var loaded = false

    init(out: URL, payload: [String: Any], size: NSSize) {
        self.out = out
        self.payload = payload
        self.size = size
        webView = WKWebView(frame: NSRect(origin: .zero, size: size), configuration: WKWebViewConfiguration())
        super.init()
        webView.navigationDelegate = self
        configureTransparency(webView)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded = true }

    func run() -> Int32 {
        guard let html = widgetHTML() else { print("widget.html not found"); return 2 }
        let window = NSWindow(contentRect: NSRect(x: 120, y: 200, width: size.width, height: size.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .floating
        window.contentView = webView
        window.orderFrontRegardless()

        webView.loadFileURL(html, allowingReadAccessTo: html.deletingLastPathComponent())
        let loadDeadline = Date().addingTimeInterval(15)
        while !loaded && Date() < loadDeadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        guard loaded else { print("html did not load"); return 3 }

        webView.evaluateJavaScript("window.render(\(WidgetApp.jsonString(payload)));") { _, error in
            if let error { print("js error: \(error.localizedDescription)") }
        }
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))

        var written = false
        var code: Int32 = 4
        let snapshotConfig = WKSnapshotConfiguration()
        snapshotConfig.rect = NSRect(origin: .zero, size: size)
        snapshotConfig.snapshotWidth = NSNumber(value: Double(size.width * 2))
        webView.takeSnapshot(with: snapshotConfig) { image, error in
            defer { written = true }
            guard let image, let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else {
                print("snapshot failed: \(error?.localizedDescription ?? "no image")")
                return
            }
            do {
                try png.write(to: self.out)
                print("saved \(self.out.path) \(png.count) bytes")
                code = 0
            } catch {
                print("write failed: \(error)")
            }
        }
        let snapshotDeadline = Date().addingTimeInterval(15)
        while !written && Date() < snapshotDeadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        return code
    }
}

/// Демо-история для скриншотов: детерминированная, без реального баланса.
func demoState(now: Date) -> WidgetState {
    let steps = [0.0, 0.0, 0.02, 0.0, 0.05, 0.01, 0.0, 0.03]
    var samples: [BalanceSample] = []
    var balance = 48.60
    let end = Int(now.timeIntervalSince1970)
    let count = 26 * 12
    for i in 0..<count {
        let t = end - (count - i) * 300
        balance -= steps[i % steps.count]
        samples.append(BalanceSample(t: t, cny: (balance * 100).rounded() / 100, usd: nil))
    }
    return WidgetState(frame_x: nil, frame_y: nil, samples: samples)
}

// MARK: - разбор аргументов

func argumentValue(_ args: [String], _ name: String) -> String? {
    guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
    return args[index + 1]
}

let arguments = CommandLine.arguments

if arguments.contains("--version") {
    print(APP_VERSION)
    exit(0)
}

// общие для снапшота и печати состояния
func probeApp(demo: Bool, localeOverride: String?) -> WidgetApp {
    let probe = WidgetApp()
    probe.config = Config.load(from: Paths.config)
    if let locale = localeOverride, Config.supportedLocales.contains(locale.lowercased()) {
        probe.config.locale = locale.lowercased()
    }
    if demo {
        probe.state = demoState(now: Date())
    } else if let data = try? Data(contentsOf: Paths.state),
              let decoded = try? JSONDecoder().decode(WidgetState.self, from: data) {
        probe.state = decoded
    }
    probe.lastError = nil
    probe.lastSuccess = Date()
    return probe
}

if let path = argumentValue(arguments, "--snapshot") {
    let out = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    let demo = arguments.contains("--demo")
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let probe = probeApp(demo: demo, localeOverride: argumentValue(arguments, "--locale"))
    let size = NSSize(width: probe.config.width, height: probe.config.height)
    exit(Snapshotter(out: out, payload: probe.payload(), size: size).run())
}

if arguments.contains("--print-payload") {
    let probe = probeApp(demo: arguments.contains("--demo"),
                         localeOverride: argumentValue(arguments, "--locale"))
    if let data = try? JSONSerialization.data(withJSONObject: probe.payload(),
                                              options: [.sortedKeys, .prettyPrinted]),
       let text = String(data: data, encoding: .utf8) {
        print(text)
    }
    exit(0)
}

let application = NSApplication.shared
let delegate = WidgetApp()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
