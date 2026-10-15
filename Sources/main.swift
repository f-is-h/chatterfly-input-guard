import AppKit
import Carbon
import ServiceManagement

enum InputSources {
    static let chatterflyID = "com.tencent.inputmethod.chatterfly"

    static func isChatterfly(_ id: String) -> Bool {
        id == chatterflyID || id.hasPrefix(chatterflyID + ".")
    }

    static func property(_ source: TISInputSource, _ key: CFString) -> String? {
        guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    }

    static func id(_ source: TISInputSource) -> String {
        property(source, kTISPropertyInputSourceID) ?? ""
    }

    static func selectable() -> [TISInputSource] {
        let sources = TISCreateInputSourceList(nil, false).takeRetainedValue() as! [TISInputSource]
        return sources.filter { source in
            guard property(source, kTISPropertyInputSourceCategory) == (kTISCategoryKeyboardInputSource as String),
                  let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceIsSelectCapable) else { return false }
            return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(pointer).takeUnretainedValue())
        }
    }

    static func current() -> String {
        id(TISCopyCurrentKeyboardInputSource().takeRetainedValue())
    }

    static func select(_ target: String) -> OSStatus? {
        guard let source = selectable().first(where: { id($0) == target }) else { return nil }
        return TISSelectInputSource(source)
    }

    static func startupTarget(defaults: UserDefaults = .standard) -> String? {
        let current = self.current()
        if !isChatterfly(current), !current.isEmpty { return current }
        let sources = selectable().filter { !isChatterfly(id($0)) }
        if let saved = defaults.string(forKey: "lastSource"), sources.contains(where: { id($0) == saved }) { return saved }
        let history = UserDefaults(suiteName: "com.apple.HIToolbox")?.array(forKey: "AppleInputSourceHistory") as? [[String: Any]] ?? []
        for entry in history {
            if let mode = entry["Input Mode"] as? String,
               let source = sources.first(where: { id($0) == mode || property($0, kTISPropertyInputModeID) == mode }) {
                return id(source)
            }
            if entry["KeyboardLayout Name"] as? String == "ABC", sources.contains(where: { id($0) == "com.apple.keylayout.ABC" }) {
                return "com.apple.keylayout.ABC"
            }
        }
        return nil
    }
}

// 只保存输入法标识；不接触按键、录音和输入内容。
struct RestorationPolicy {
    var target: String?
    private(set) var pauseReason: String?
    private var attempts: [TimeInterval] = []
    var isPaused: Bool { pauseReason != nil }

    mutating func observe(_ current: String, available: Set<String>) {
        if !InputSources.isChatterfly(current), available.contains(current) { target = current }
    }

    func targetToRestore(current: String, available: Set<String>) -> String? {
        guard !isPaused, InputSources.isChatterfly(current), let target = target, available.contains(target) else { return nil }
        return target
    }

    mutating func beginAttempt(at now: TimeInterval) -> Bool {
        attempts.removeAll { now - $0 >= 2 }
        guard attempts.count < 5 else {
            pause(reason: "输入法持续争用，已暂停保护；可点“恢复自动恢复”重试。")
            return false
        }
        attempts.append(now)
        return true
    }

    mutating func pause(reason: String = "已手动暂停") { pauseReason = reason }

    mutating func resume() {
        pauseReason = nil
        attempts.removeAll()
    }
}

enum Project {
    static let repository = "https://github.com/f-is-h/chatterfly-input-guard"
    static let repositoryURL = URL(string: repository)!
    static let releasesURL = URL(string: repository + "/releases/latest")!
    static let apiURL = URL(string: "https://api.github.com/repos/f-is-h/chatterfly-input-guard/releases/latest")!
    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
}

struct Version: Comparable {
    let parts: [Int]

    init?(_ text: String) {
        let value = text.hasPrefix("v") ? String(text.dropFirst()) : text
        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        guard (2...3).contains(components.count), components.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } }) else { return nil }
        let parsed = components.compactMap { Int($0) }
        guard parsed.count == components.count else { return nil }
        parts = parsed + Array(repeating: 0, count: 3 - parsed.count)
    }

    static func < (lhs: Version, rhs: Version) -> Bool { lhs.parts.lexicographicallyPrecedes(rhs.parts) }
}

struct Release: Decodable {
    let tag: String
    let page: URL
    let draft: Bool
    let prerelease: Bool

    enum CodingKeys: String, CodingKey {
        case tag = "tag_name", page = "html_url", draft, prerelease
    }

    func validatedVersion() throws -> Version {
        guard !draft, !prerelease, let version = Version(tag),
              page.scheme == "https", page.host == "github.com", page.user == nil, page.password == nil, page.port == nil,
              page.path.hasPrefix("/f-is-h/chatterfly-input-guard/releases/tag/") else { throw UpdateError.invalidRelease }
        return version
    }
}

enum UpdateError: LocalizedError {
    case noRelease, invalidRelease, server(Int)

    var errorDescription: String? {
        switch self {
        case .noRelease: return "仓库暂时没有公开的正式版本。"
        case .invalidRelease: return "更新信息格式不正确，请前往仓库查看。"
        case .server(let code): return "GitHub 返回 HTTP \(code)，请稍后重试。"
        }
    }
}

enum Updates {
    static func parse(data: Data, statusCode: Int) throws -> Release {
        guard statusCode != 404 else { throw UpdateError.noRelease }
        guard statusCode == 200 else { throw UpdateError.server(statusCode) }
        let release: Release
        do { release = try JSONDecoder().decode(Release.self, from: data) }
        catch { throw UpdateError.invalidRelease }
        _ = try release.validatedVersion()
        return release
    }

    static func check(completion: @escaping (Result<Release, Error>) -> Void) {
        var request = URLRequest(url: Project.apiURL)
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2026-03-10", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("ChatterflyInputGuard/\(Project.version)", forHTTPHeaderField: "User-Agent")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        let session = URLSession(configuration: configuration)
        session.dataTask(with: request) { data, response, error in
            defer { session.finishTasksAndInvalidate() }
            if let error = error { completion(.failure(error)); return }
            guard let response = response as? HTTPURLResponse, let data = data else {
                completion(.failure(UpdateError.invalidRelease)); return
            }
            completion(Result { try parse(data: data, statusCode: response.statusCode) })
        }.resume()
    }
}

enum LoginItems {
    static var status: SMAppService.Status { SMAppService.mainApp.status }

    static func initializeDefault() throws {
        guard !UserDefaults.standard.bool(forKey: "loginItemInitialized") else { return }
        // 仅首次运行默认开启。尊重用户此后在菜单或系统设置里的关闭操作。
        UserDefaults.standard.set(true, forKey: "loginItemInitialized")
        if status != .enabled && status != .requiresApproval { try SMAppService.mainApp.register() }
    }

    static func setEnabled(_ enabled: Bool) throws {
        UserDefaults.standard.set(true, forKey: "loginItemInitialized")
        if enabled {
            if status != .enabled { try SMAppService.mainApp.register() }
        } else if status == .enabled || status == .requiresApproval {
            try SMAppService.mainApp.unregister()
        }
    }

    static var description: String {
        switch status {
        case .enabled: return "已开启"
        case .notRegistered: return "已关闭"
        case .requiresApproval: return "需要在系统设置中允许"
        case .notFound: return "系统未找到应用，请先放入应用程序文件夹"
        @unknown default: return "未知状态"
        }
    }
}

// 简单诊断入口，也用于验证系统登录项的实际状态。
if CommandLine.arguments.contains("--diagnose") {
    print("版本：\(Project.version)\n当前输入法：\(InputSources.current())\n登录启动：\(LoginItems.description)")
    exit(0)
}
if let index = CommandLine.arguments.firstIndex(of: "--login"), CommandLine.arguments.indices.contains(index + 1) {
    let value = CommandLine.arguments[index + 1]
    guard ["on", "off"].contains(value) else { exit(1) }
    do { try LoginItems.setEnabled(value == "on"); print(LoginItems.description); exit(0) }
    catch { fputs("登录启动设置失败：\(error.localizedDescription)\n", stderr); exit(1) }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let stateItem = NSMenuItem(title: "运行中", action: nil, keyEquivalent: "")
    private let targetItem = NSMenuItem(title: "等待输入法", action: nil, keyEquivalent: "")
    private var pauseItem: NSMenuItem!
    private var loginItem: NSMenuItem!
    private var autoUpdateItem: NSMenuItem!
    private var checkUpdateItem: NSMenuItem!
    private var downloadItem: NSMenuItem!
    private var observer: NSObjectProtocol?
    private var updateTimer: Timer?
    private var policy = RestorationPolicy()
    private var pending = false
    private var checkingUpdates = false
    private var latestRelease: Release?
    private var loginError: String?
    private let defaults = UserDefaults.standard
    private let logURL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs/ChatterflyInputGuard/guard.log")

    private func log(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        try? FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let size = try? logURL.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 262144 {
            let old = logURL.appendingPathExtension("previous")
            try? FileManager.default.removeItem(at: old)
            try? FileManager.default.moveItem(at: logURL, to: old)
        }
        if !FileManager.default.fileExists(atPath: logURL.path) { FileManager.default.createFile(atPath: logURL.path, contents: nil) }
        guard let handle = try? FileHandle(forWritingTo: logURL) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(line.utf8))
    }

    @discardableResult private func alert(_ title: String, _ message: String, buttons: [String] = ["好"]) -> NSApplication.ModalResponse {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        for button in buttons { alert.addButton(withTitle: button) }
        return alert.runModal()
    }

    private func addItem(_ menu: NSMenu, _ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return item
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let id = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: id).contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            NSApp.terminate(nil)
            return
        }
        defaults.register(defaults: ["autoCheckUpdates": true])
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        let heading = NSMenuItem(title: "护输宝 · \(Project.version)", action: nil, keyEquivalent: "")
        heading.isEnabled = false
        stateItem.isEnabled = false
        targetItem.isEnabled = false
        menu.addItem(heading)
        menu.addItem(stateItem)
        menu.addItem(targetItem)
        menu.addItem(.separator())
        pauseItem = addItem(menu, "暂停自动恢复", #selector(togglePause))
        loginItem = addItem(menu, "登录时启动", #selector(toggleLogin))
        menu.addItem(.separator())
        autoUpdateItem = addItem(menu, "自动检查更新", #selector(toggleAutoUpdate))
        checkUpdateItem = addItem(menu, "检查更新", #selector(checkUpdatesManually))
        downloadItem = addItem(menu, "下载新版本", #selector(openLatestRelease))
        downloadItem.isHidden = true
        _ = addItem(menu, "GitHub 仓库", #selector(openRepository))
        _ = addItem(menu, "关于", #selector(showAbout))
        menu.addItem(.separator())
        _ = addItem(menu, "退出", #selector(quit))
        statusItem.menu = menu

        policy.target = InputSources.startupTarget()
        observer = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil, queue: .main
        ) { [weak self] _ in self?.inputChanged() }
        log("启动 version=\(Project.version) current=\(InputSources.current()) target=\(policy.target ?? "等待选择")")
        inputChanged()
        do {
            try LoginItems.initializeDefault()
            log("登录启动：\(LoginItems.description)")
        }
        catch { loginError = error.localizedDescription; log("登录启动设置失败：\(error.localizedDescription)") }
        refreshMenu()
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.checkUpdatesIfDue() }
        updateTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in self?.checkUpdatesIfDue() }
    }

    func menuWillOpen(_ menu: NSMenu) { refreshMenu() }

    private func refreshMenu() {
        let source = InputSources.selectable().first(where: { InputSources.id($0) == policy.target })
        let name = source.flatMap { InputSources.property($0, kTISPropertyLocalizedName) }
        targetItem.title = name.map { "恢复到：\($0)" } ?? "请先选择一次常用输入法"
        if let reason = policy.pauseReason { stateItem.title = reason }
        else if source == nil { stateItem.title = "等待可用的恢复目标" }
        else { stateItem.title = "运行中 · 只恢复 Chatterfly 的切换" }
        statusItem.button?.title = policy.isPaused ? "護·停" : (latestRelease == nil ? "護" : "護↑")
        statusItem.button?.toolTip = "护输宝：\(stateItem.title)"
        pauseItem.title = policy.isPaused ? "恢复自动恢复" : "暂停自动恢复"
        switch LoginItems.status {
        case .enabled: loginItem.state = .on; loginItem.title = "登录时启动"
        case .requiresApproval: loginItem.state = .mixed; loginItem.title = "登录时启动（需系统允许）"
        default: loginItem.state = .off; loginItem.title = loginError == nil ? "登录时启动" : "登录时启动（设置失败）"
        }
        autoUpdateItem.state = defaults.bool(forKey: "autoCheckUpdates") ? .on : .off
        checkUpdateItem.isEnabled = !checkingUpdates
        checkUpdateItem.title = checkingUpdates ? "正在检查更新" : "检查更新"
        downloadItem.isHidden = latestRelease == nil
        if let release = latestRelease { downloadItem.title = "下载新版本 \(release.tag)" }
    }

    private func inputChanged() {
        let current = InputSources.current()
        let available = Set(InputSources.selectable().map { InputSources.id($0) })
        policy.observe(current, available: available)
        if let target = policy.target { defaults.set(target, forKey: "lastSource") }
        refreshMenu()
        guard !pending, policy.targetToRestore(current: current, available: available) != nil else { return }
        pending = true
        DispatchQueue.main.async { [weak self] in self?.restore() }
    }

    private func restore() {
        let available = Set(InputSources.selectable().map { InputSources.id($0) })
        guard let target = policy.targetToRestore(current: InputSources.current(), available: available) else { pending = false; return }
        guard policy.beginAttempt(at: ProcessInfo.processInfo.systemUptime) else {
            pending = false
            log(policy.pauseReason ?? "暂停保护")
            refreshMenu()
            return
        }
        guard let result = InputSources.select(target), result == noErr else {
            pending = false
            policy.pause(reason: "恢复失败，请先选择常用输入法，再点“恢复自动恢复”。")
            log("恢复失败 target=\(target)")
            refreshMenu()
            return
        }
        log("恢复 target=\(target) result=0")
        // 合并同一次切换的重复通知，读回后才允许下一次恢复。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self = self else { return }
            self.log("验证 current=\(InputSources.current())")
            self.pending = false
            self.inputChanged()
        }
    }

    @objc private func togglePause() {
        if policy.isPaused { policy.resume() } else { policy.pause() }
        log(policy.isPaused ? "手动暂停" : "恢复运行")
        inputChanged()
    }

    @objc private func toggleLogin() {
        do {
            try LoginItems.setEnabled(LoginItems.status != .enabled && LoginItems.status != .requiresApproval)
            loginError = nil
            log("登录启动：\(LoginItems.description)")
            if LoginItems.status == .requiresApproval {
                let response = alert("需要系统允许", "请在系统设置的登录项中允许 护输宝。", buttons: ["打开系统设置", "稍后"])
                if response == .alertFirstButtonReturn { SMAppService.openSystemSettingsLoginItems() }
            }
        } catch {
            loginError = error.localizedDescription
            log("登录启动设置失败：\(error.localizedDescription)")
            alert("无法设置登录启动", "请先将应用放入“应用程序”文件夹。\n\n\(error.localizedDescription)")
        }
        refreshMenu()
    }


    @objc private func toggleAutoUpdate() {
        defaults.set(!defaults.bool(forKey: "autoCheckUpdates"), forKey: "autoCheckUpdates")
        refreshMenu()
        checkUpdatesIfDue()
    }

    private func checkUpdatesIfDue() {
        guard defaults.bool(forKey: "autoCheckUpdates") else { return }
        if let last = defaults.object(forKey: "lastUpdateAttempt") as? Date, Date().timeIntervalSince(last) < 86400 { return }
        checkUpdates(manual: false)
    }

    @objc private func checkUpdatesManually() { checkUpdates(manual: true) }

    private func checkUpdates(manual: Bool) {
        guard !checkingUpdates else { return }
        checkingUpdates = true
        defaults.set(Date(), forKey: "lastUpdateAttempt")
        refreshMenu()
        Updates.check { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.checkingUpdates = false
                switch result {
                case .success(let release):
                    if let current = Version(Project.version), let latest = try? release.validatedVersion(), current < latest {
                        self.latestRelease = release
                        self.log("发现新版 \(release.tag)")
                        if manual {
                            let response = self.alert("发现新版本 \(release.tag)", "当前版本为 \(Project.version)。下载并解压新版，退出旧版后替换应用即可。", buttons: ["查看新版", "稍后"])
                            if response == .alertFirstButtonReturn { NSWorkspace.shared.open(release.page) }
                        }
                    } else {
                        self.latestRelease = nil
                        self.log("检查更新：当前无需更新")
                        if manual { self.alert("当前无需更新", "当前版本：\(Project.version)\nGitHub 最新正式版本：\(release.tag)") }
                    }
                case .failure(let error):
                    self.log("检查更新失败：\(error.localizedDescription)")
                    if manual { self.alert("暂时无法检查更新", error.localizedDescription) }
                }
                self.refreshMenu()
            }
        }
    }

    @objc private func openLatestRelease() { NSWorkspace.shared.open(latestRelease?.page ?? Project.releasesURL) }
    @objc private func openRepository() { NSWorkspace.shared.open(Project.repositoryURL) }
    @objc private func showAbout() {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let credits = NSAttributedString(
            string: "只使用 Chatterfly 的语音输入，\n保留自己习惯的输入法。\n\n独立项目，与腾讯及 Chatterfly 官方无关联。",
            attributes: [.font: NSFont.systemFont(ofSize: 12), .paragraphStyle: paragraph])
        var options: [NSApplication.AboutPanelOptionKey: Any] = [
            .applicationName: "护输宝", .applicationVersion: "版本 \(Project.version)",
            .version: "", .credits: credits]
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: url) { options[.applicationIcon] = icon }
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: options)
    }
    @objc private func quit() { NSApp.terminate(nil) }

    func applicationWillTerminate(_ notification: Notification) {
        if let observer = observer { DistributedNotificationCenter.default().removeObserver(observer) }
        updateTimer?.invalidate()
        log("退出")
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
