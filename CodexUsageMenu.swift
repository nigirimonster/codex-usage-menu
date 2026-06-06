import Cocoa
import Darwin
import Foundation

struct AuthFile: Decodable {
    struct Tokens: Decodable {
        let access_token: String?
    }

    let tokens: Tokens?
}

struct UsageResponse: Decodable {
    struct RateLimit: Decodable {
        let allowed: Bool
        let limit_reached: Bool
        let primary_window: Window?
        let secondary_window: Window?
    }

    struct Window: Decodable {
        let used_percent: Double
        let limit_window_seconds: Int?
        let reset_after_seconds: Int?
        let reset_at: TimeInterval?
    }

    struct Credits: Decodable {
        let has_credits: Bool?
        let unlimited: Bool?
        let balance: String?
    }

    let plan_type: String?
    let rate_limit: RateLimit?
    let credits: Credits?
}

struct LocalUsage {
    let todayTokens: Int64
    let weekTokens: Int64
    let totalTokens: Int64
}

struct MeterState {
    var title: String
    var remainingPercent: Double?
    var primaryUsedPercent: Double?
    var secondaryUsedPercent: Double?
    var primaryResetText: String?
    var secondaryResetText: String?
    var primaryResetMenuText: String?
    var secondaryResetMenuText: String?
    var statusText: String
    var creditText: String?
    var localUsage: LocalUsage?
    var updatedAt: Date
    var errorText: String?

    static let loading = MeterState(
        title: "Codex",
        remainingPercent: nil,
        primaryUsedPercent: nil,
        secondaryUsedPercent: nil,
        primaryResetText: nil,
        secondaryResetText: nil,
        primaryResetMenuText: nil,
        secondaryResetMenuText: nil,
        statusText: "Loading",
        creditText: nil,
        localUsage: nil,
        updatedAt: Date(),
        errorText: nil
    )
}

enum IconChoice: String, CaseIterable {
    case speedometer
    case sparkles
    case cpuFill = "cpu.fill"
    case circleHexagonpathFill = "circle.hexagonpath.fill"
    case hexagon = "hexagon"
    case codex

    var defaultsValue: String { rawValue }
}

final class UsageReader {
    private let home = FileManager.default.homeDirectoryForCurrentUser

    private var authURL: URL {
        home.appendingPathComponent(".codex/auth.json")
    }

    private var codexStateURL: URL {
        home.appendingPathComponent(".codex/state_5.sqlite")
    }

    func readLocalUsage() -> LocalUsage? {
        guard FileManager.default.fileExists(atPath: codexStateURL.path) else {
            return nil
        }

        let now = Date()
        let startOfDay = Calendar.current.startOfDay(for: now).timeIntervalSince1970
        let startOfWeek = Calendar.current.dateInterval(of: .weekOfYear, for: now)?.start.timeIntervalSince1970
            ?? (now.timeIntervalSince1970 - 7 * 24 * 60 * 60)

        let query = """
        select
          coalesce(sum(case when updated_at >= \(Int64(startOfDay)) then tokens_used else 0 end), 0),
          coalesce(sum(case when updated_at >= \(Int64(startOfWeek)) then tokens_used else 0 end), 0),
          coalesce(sum(tokens_used), 0)
        from threads;
        """

        guard let output = runSQLite(query: query) else {
            return nil
        }

        let lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let firstLine = lines.first else {
            return nil
        }

        let totals = firstLine.split(separator: "|").map(String.init)
        guard totals.count >= 3,
              let today = Int64(totals[0]),
              let week = Int64(totals[1]),
              let total = Int64(totals[2]) else {
            return nil
        }

        return LocalUsage(
            todayTokens: today,
            weekTokens: week,
            totalTokens: total
        )
    }

    func fetchUsage(completion: @escaping (Result<UsageResponse, Error>) -> Void) {
        do {
            let token = try readAccessToken()
            var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/codex/usage")!)
            request.httpMethod = "GET"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("en-US", forHTTPHeaderField: "OAI-Language")
            request.setValue("CodexUsageMenu/0.2.0", forHTTPHeaderField: "User-Agent")

            URLSession.shared.dataTask(with: request) { data, response, error in
                if let error {
                    completion(.failure(error))
                    return
                }

                guard let http = response as? HTTPURLResponse else {
                    completion(.failure(UsageError.invalidResponse))
                    return
                }

                guard (200..<300).contains(http.statusCode), let data else {
                    completion(.failure(UsageError.httpStatus(http.statusCode)))
                    return
                }

                do {
                    completion(.success(try JSONDecoder().decode(UsageResponse.self, from: data)))
                } catch {
                    completion(.failure(error))
                }
            }.resume()
        } catch {
            completion(.failure(error))
        }
    }

    private func readAccessToken() throws -> String {
        let data = try Data(contentsOf: authURL)
        let auth = try JSONDecoder().decode(AuthFile.self, from: data)

        guard let token = auth.tokens?.access_token, !token.isEmpty else {
            throw UsageError.missingToken
        }

        return token
    }

    private func runSQLite(query: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [codexStateURL.path, query]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        guard process.terminationStatus == 0 else {
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }
}

enum UsageError: LocalizedError {
    case missingToken
    case invalidResponse
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .missingToken:
            return "No Codex login token"
        case .invalidResponse:
            return "Invalid server response"
        case .httpStatus(let status):
            return "Usage request failed: HTTP \(status)"
        }
    }
}

enum LoginItemError: LocalizedError {
    case missingExecutable
    case launchctlFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingExecutable:
            return "Could not find app executable"
        case .launchctlFailed(let output):
            let message = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return message.isEmpty ? "Could not update launch-at-login setting" : message
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let loginItemLabel = "io.github.codexusagemenu.app"
    private let iconChoiceKey = "statusIconChoice"
    private let reader = UsageReader()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private var state = MeterState.loading
    private var timer: Timer?
    private let usageURL = URL(string: "https://chatgpt.com/codex/cloud/settings/analytics#usage")!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        terminateDuplicateInstances()
        configureStatusItem()
        refresh()

        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    private func terminateDuplicateInstances() {
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? loginItemLabel

        for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier) {
            if app.processIdentifier != currentPID {
                app.terminate()
            }
        }
    }

    private func configureStatusItem() {
        updateStatusIcon()

        setStatusTitle(shortRemaining: nil, shortReset: nil, weeklyRemaining: nil, weeklyReset: nil)
        statusItem.menu = menu
        renderMenu()
    }

    @objc private func refresh() {
        var next = state
        next.statusText = "Refreshing"
        next.localUsage = reader.readLocalUsage()
        next.updatedAt = Date()
        next.errorText = nil
        state = next
        renderMenu()

        reader.fetchUsage { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }

                switch result {
                case .success(let usage):
                    self.state = self.makeState(usage: usage, local: self.reader.readLocalUsage())
                case .failure(let error):
                    var failed = self.state
                    failed.title = "Codex"
                    failed.errorText = error.localizedDescription
                    failed.statusText = "Offline"
                    failed.updatedAt = Date()
                    failed.localUsage = self.reader.readLocalUsage()
                    self.state = failed
                }

                self.renderMenu()
            }
        }
    }

    private func renderMenu() {
        let shortRemaining = remainingFromUsed(state.primaryUsedPercent)
        let weeklyRemaining = remainingFromUsed(state.secondaryUsedPercent)
        setStatusTitle(
            shortRemaining: shortRemaining,
            shortReset: state.primaryResetText,
            weeklyRemaining: weeklyRemaining,
            weeklyReset: state.secondaryResetText
        )
        statusItem.button?.toolTip = "Codex remaining: \(remainingLabel(shortRemaining)) resets in \(state.primaryResetText ?? "--"), \(remainingLabel(weeklyRemaining)) resets in \(state.secondaryResetText ?? "--")"

        menu.removeAllItems()
        addHeader("Codex Remaining")

        if let error = state.errorText {
            addDisabled(error)
        } else {
            addDisabled(state.statusText)
            addDisabled("\(remainingLabel(shortRemaining)) remaining, resets \(state.primaryResetMenuText ?? "--")")
            addDisabled("\(remainingLabel(weeklyRemaining)) remaining, resets \(state.secondaryResetMenuText ?? "--")")
        }

        if let creditText = state.creditText {
            addDisabled(creditText)
        }

        if let local = state.localUsage {
            menu.addItem(.separator())
            addDisabled("Tokens today: \(formatTokens(local.todayTokens))")
            addDisabled("Tokens this week: \(formatTokens(local.weekTokens))")
        }

        menu.addItem(.separator())
        addDisabled("Updated \(state.updatedAt.formatted(date: .omitted, time: .shortened))")
        addAction("Refresh Now", #selector(refresh))
        addAction("Open Codex Usage Page", #selector(openUsagePage))
        addIconSubmenu()
        addCheckAction("Launch at Login", #selector(toggleStartAtLogin), checked: isStartAtLoginEnabled())
        menu.addItem(.separator())
        addAction("Quit", #selector(quit))
    }

    private func addHeader(_ title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.attributedTitle = NSAttributedString(
            string: title,
            attributes: [.font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)]
        )
        menu.addItem(item)
    }

    private func setStatusTitle(shortRemaining: Double?, shortReset: String?, weeklyRemaining: Double?, weeklyReset: String?) {
        let text = "\(remainingLabel(shortRemaining)) (\(shortReset ?? "--")) \(remainingLabel(weeklyRemaining)) (\(weeklyReset ?? "--"))"
        let attributed = NSMutableAttributedString(string: text)
        let fullRange = NSRange(location: 0, length: attributed.length)
        attributed.addAttributes([
            .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .semibold),
            .foregroundColor: NSColor.labelColor
        ], range: fullRange)

        for label in ["(\(shortReset ?? "--"))", "(\(weeklyReset ?? "--"))"] {
            let range = (text as NSString).range(of: label)
            if range.location != NSNotFound {
                attributed.addAttributes([
                    .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular),
                    .foregroundColor: NSColor.labelColor,
                    .baselineOffset: 1
                ], range: range)
            }
        }

        statusItem.button?.attributedTitle = attributed
    }

    private func updateStatusIcon() {
        guard let image = iconImage(for: selectedIconChoice()) else {
            statusItem.button?.image = nil
            return
        }

        image.isTemplate = selectedIconChoice() != .codex
        statusItem.button?.image = image
    }

    private func addDisabled(_ title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    private func addAction(_ title: String, _ action: Selector) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
    }

    private func addCheckAction(_ title: String, _ action: Selector, checked: Bool) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.state = checked ? .on : .off
        menu.addItem(item)
    }

    private func addIconSubmenu() {
        let parent = NSMenuItem(title: "Icon", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "Icon")

        for choice in availableIconChoices() {
            let item = NSMenuItem(title: "", action: #selector(selectIcon(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = choice.defaultsValue
            item.image = iconImage(for: choice)
            item.state = choice == selectedIconChoice() ? .on : .off
            submenu.addItem(item)
        }

        parent.submenu = submenu
        menu.addItem(parent)
    }

    private func makeState(usage: UsageResponse, local: LocalUsage?) -> MeterState {
        let primaryUsed = usage.rate_limit?.primary_window?.used_percent
        let secondaryUsed = usage.rate_limit?.secondary_window?.used_percent
        let worstUsed = [primaryUsed, secondaryUsed].compactMap { $0 }.max()
        let remaining = worstUsed.map { max(0, min(100, 100 - $0)) }
        let allowed = usage.rate_limit?.allowed ?? true
        let limitReached = usage.rate_limit?.limit_reached ?? false
        let status = limitReached || !allowed ? "Limit reached" : "\(usage.plan_type?.capitalized ?? "Plan") active"

        return MeterState(
            title: "Codex",
            remainingPercent: remaining,
            primaryUsedPercent: primaryUsed,
            secondaryUsedPercent: secondaryUsed,
            primaryResetText: resetText(usage.rate_limit?.primary_window),
            secondaryResetText: resetText(usage.rate_limit?.secondary_window),
            primaryResetMenuText: resetMenuText(usage.rate_limit?.primary_window),
            secondaryResetMenuText: resetMenuText(usage.rate_limit?.secondary_window),
            statusText: status,
            creditText: creditText(usage.credits),
            localUsage: local,
            updatedAt: Date(),
            errorText: nil
        )
    }

    private func resetText(_ window: UsageResponse.Window?) -> String? {
        guard let seconds = window?.reset_after_seconds else {
            return nil
        }

        if seconds < 60 {
            return "\(seconds)s"
        }

        if seconds < 3600 {
            return "\(Int(ceil(Double(seconds) / 60)))m"
        }

        if seconds < 172800 {
            return "\(Int(ceil(Double(seconds) / 3600)))h"
        }

        return "\(Int(ceil(Double(seconds) / 86400)))d"
    }

    private func resetMenuText(_ window: UsageResponse.Window?) -> String? {
        guard let resetAt = window?.reset_at else {
            return resetText(window)
        }

        let date = Date(timeIntervalSince1970: resetAt)
        let time = compactTimeText(date)

        if Calendar.current.isDateInToday(date) {
            return time
        }

        return "\(time) on \(compactDateFormatter.string(from: date))"
    }

    private func compactTimeText(_ date: Date) -> String {
        let components = Calendar.current.dateComponents([.minute], from: date)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = components.minute == 0 ? "ha" : "h:mma"
        return formatter.string(from: date).lowercased()
    }

    private var compactDateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "M/d"
        return formatter
    }

    private func creditText(_ credits: UsageResponse.Credits?) -> String? {
        guard let credits else {
            return nil
        }

        if credits.unlimited == true {
            return "Credits unlimited"
        }

        if credits.has_credits == true, let balance = credits.balance {
            return "Credits \(balance)"
        }

        return nil
    }

    @objc private func openUsagePage() {
        NSWorkspace.shared.open(usageURL)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    @objc private func toggleStartAtLogin() {
        do {
            if isStartAtLoginEnabled() {
                try disableStartAtLogin()
            } else {
                try enableStartAtLogin()
            }
        } catch {
            state.errorText = error.localizedDescription
        }

        renderMenu()
    }

    @objc private func selectIcon(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let choice = IconChoice(rawValue: rawValue) else {
            return
        }

        UserDefaults.standard.set(choice.defaultsValue, forKey: iconChoiceKey)
        updateStatusIcon()
        renderMenu()
    }

    private func selectedIconChoice() -> IconChoice {
        if let rawValue = UserDefaults.standard.string(forKey: iconChoiceKey),
           let choice = IconChoice(rawValue: rawValue),
           availableIconChoices().contains(choice) {
            return choice
        }

        return .sparkles
    }

    private func availableIconChoices() -> [IconChoice] {
        var choices: [IconChoice] = [
            .speedometer,
            .sparkles,
            .cpuFill,
            .circleHexagonpathFill,
            .hexagon
        ]

        if codexIconImage() != nil {
            choices.append(.codex)
        }

        return choices
    }

    private func iconImage(for choice: IconChoice) -> NSImage? {
        switch choice {
        case .speedometer:
            return NSImage(systemSymbolName: "speedometer", accessibilityDescription: "Speedometer icon")
        case .sparkles:
            return NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Sparkles icon")
        case .cpuFill:
            return NSImage(systemSymbolName: "cpu.fill", accessibilityDescription: "CPU icon")
        case .circleHexagonpathFill:
            return NSImage(systemSymbolName: "circle.hexagonpath.fill", accessibilityDescription: "Token icon")
        case .hexagon:
            return NSImage(systemSymbolName: "hexagon", accessibilityDescription: "Hexagon icon")
        case .codex:
            return codexIconImage()
        }
    }

    private func codexIconImage() -> NSImage? {
        let paths = [
            "/Applications/Codex.app/Contents/Resources/codexTemplate.png",
            "/Applications/Codex.app/Contents/Resources/codexTemplate@2x.png",
            "/Applications/Codex.app/Contents/Resources/app.icns"
        ]

        for path in paths {
            if let image = NSImage(contentsOfFile: path) {
                return image
            }
        }

        return nil
    }

    private func isStartAtLoginEnabled() -> Bool {
        guard let currentExecutable = Bundle.main.executableURL?.path,
              let savedExecutable = launchAgentExecutablePath(),
              savedExecutable == currentExecutable else {
            return false
        }

        return FileManager.default.fileExists(atPath: savedExecutable)
    }

    private func enableStartAtLogin() throws {
        guard let executablePath = Bundle.main.executableURL?.path else {
            throw LoginItemError.missingExecutable
        }

        try FileManager.default.createDirectory(
            at: launchAgentURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: launchAgentLogURL,
            withIntermediateDirectories: true
        )

        try launchAgentPlist(executablePath: executablePath).write(
            to: launchAgentURL,
            atomically: true,
            encoding: .utf8
        )

        _ = runLaunchctl(arguments: ["bootout", "gui/\(getuid())", launchAgentURL.path])
        try runLaunchctlChecked(arguments: ["bootstrap", "gui/\(getuid())", launchAgentURL.path])
    }

    private func disableStartAtLogin() throws {
        _ = runLaunchctl(arguments: ["bootout", "gui/\(getuid())", launchAgentURL.path])

        if FileManager.default.fileExists(atPath: launchAgentURL.path) {
            try FileManager.default.removeItem(at: launchAgentURL)
        }
    }

    private var launchAgentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(loginItemLabel).plist")
    }

    private var launchAgentLogURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/CodexUsageMenu")
    }

    private func launchAgentExecutablePath() -> String? {
        var format = PropertyListSerialization.PropertyListFormat.xml
        guard let data = try? Data(contentsOf: launchAgentURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: &format) as? [String: Any],
              let arguments = plist["ProgramArguments"] as? [String] else {
            return nil
        }

        return arguments.first
    }

    private func launchAgentPlist(executablePath: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>Label</key>
          <string>\(xmlEscape(loginItemLabel))</string>
          <key>ProgramArguments</key>
          <array>
            <string>\(xmlEscape(executablePath))</string>
          </array>
          <key>RunAtLoad</key>
          <true/>
          <key>StandardOutPath</key>
          <string>\(xmlEscape(launchAgentLogURL.appendingPathComponent("out.log").path))</string>
          <key>StandardErrorPath</key>
          <string>\(xmlEscape(launchAgentLogURL.appendingPathComponent("err.log").path))</string>
        </dict>
        </plist>
        """
    }

    private func xmlEscape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private func runLaunchctlChecked(arguments: [String]) throws {
        let result = runLaunchctl(arguments: arguments)
        guard result.exitCode == 0 else {
            throw LoginItemError.launchctlFailed(result.output)
        }
    }

    private func runLaunchctl(arguments: [String]) -> (exitCode: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments

        let output = Pipe()
        process.standardOutput = output
        process.standardError = output

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return (1, error.localizedDescription)
        }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    private func remainingLabel(_ value: Double?) -> String {
        guard let value else {
            return "--%"
        }

        return "\(Int(value.rounded()))%"
    }

    private func remainingFromUsed(_ value: Double?) -> Double? {
        guard let value else {
            return nil
        }

        return max(0, min(100, 100 - value))
    }

    private func formatTokens(_ tokens: Int64) -> String {
        let value = Double(tokens)

        if value >= 1_000_000 {
            return String(format: "%.1fM", value / 1_000_000)
        }

        if value >= 1_000 {
            return String(format: "%.1fk", value / 1_000)
        }

        return "\(tokens)"
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
