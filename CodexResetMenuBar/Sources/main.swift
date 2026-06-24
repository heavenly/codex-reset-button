import AppKit
import Foundation

struct AuthFile: Decodable {
    struct Tokens: Decodable { let access_token: String }
    let tokens: Tokens
}

struct ResetCreditsResponse: Decodable {
    let credits: [ResetCredit]
    let available_count: Int
}

struct ResetCredit: Decodable {
    let id: String
    let status: String
    let granted_at: String?
    let expires_at: String?
    let redeemed_at: String?
    let title: String?
    let description: String?
}

struct ConsumeResponse: Decodable {
    let code: String?
}

enum APIError: LocalizedError {
    case authMissing(String)
    case invalidResponse(String)
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .authMissing(let s): return s
        case .invalidResponse(let s): return s
        case .http(let code, let body): return "HTTP \(code): \(body)"
        }
    }
}

final class CodexAPI {
    private let apiBase = (ProcessInfo.processInfo.environment["CODEX_API_BASE_URL"] ?? "https://chatgpt.com/backend-api").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    private let authPath: URL = {
        if let override = ProcessInfo.processInfo.environment["CODEX_AUTH_JSON"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/auth.json")
    }()

    func fetchCredits() async throws -> ResetCreditsResponse {
        try await request("GET", path: "/wham/rate-limit-reset-credits", body: nil)
    }

    func redeem(creditId: String?) async throws -> ConsumeResponse {
        var body: [String: String] = ["redeem_request_id": UUID().uuidString]
        if let creditId, !creditId.isEmpty { body["credit_id"] = creditId }
        return try await request("POST", path: "/wham/rate-limit-reset-credits/consume", body: body)
    }

    private func accessToken() throws -> String {
        guard FileManager.default.fileExists(atPath: authPath.path) else {
            throw APIError.authMissing("No auth file at \(authPath.path). Run Codex login first.")
        }
        let data = try Data(contentsOf: authPath)
        let auth = try JSONDecoder().decode(AuthFile.self, from: data)
        return auth.tokens.access_token
    }

    private func request<T: Decodable>(_ method: String, path: String, body: [String: String]?) async throws -> T {
        guard let url = URL(string: apiBase + path) else { throw APIError.invalidResponse("Bad API URL") }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 30
        req.setValue("Bearer \(try accessToken())", forHTTPHeaderField: "Authorization")
        req.setValue("Codex Desktop", forHTTPHeaderField: "originator")
        req.setValue("Codex Desktop reset-menu-bar", forHTTPHeaderField: "User-Agent")
        req.setValue("en", forHTTPHeaderField: "OAI-Language")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONEncoder().encode(body)
        }

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse("Non-HTTP response") }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        if data.isEmpty, T.self == ConsumeResponse.self {
            return ConsumeResponse(code: nil) as! T
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

final class AppModel: ObservableObject {
    let api = CodexAPI()
    var credits: [ResetCredit] = []
    var availableCount: Int = 0
    var isLoading = false
    var lastError: String?
    var onChange: (() -> Void)?

    func refresh() {
        isLoading = true; lastError = nil; notify()
        Task {
            do {
                let data = try await api.fetchCredits()
                await MainActor.run {
                    self.credits = data.credits
                    self.availableCount = data.available_count
                    self.isLoading = false
                    self.notify()
                }
            } catch {
                await MainActor.run {
                    self.isLoading = false
                    self.lastError = error.localizedDescription
                    self.notify()
                }
            }
        }
    }

    func redeem(_ creditId: String?) {
        isLoading = true; lastError = nil; notify()
        Task {
            do {
                let result = try await api.redeem(creditId: creditId)
                await MainActor.run {
                    if let code = result.code, code != "reset" {
                        self.lastError = "Redeem returned: \(code)"
                    }
                    self.isLoading = false
                    self.refresh()
                }
            } catch {
                await MainActor.run {
                    self.isLoading = false
                    self.lastError = error.localizedDescription
                    self.notify()
                }
            }
        }
    }

    private func notify() { onChange?() }
}

final class ResetPopoverViewController: NSViewController {
    private let model: AppModel
    private let stack = NSStackView()

    init(model: AppModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
        self.model.onChange = { [weak self] in self?.render() }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 140))
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor)
        ])
        render()
    }

    private func label(_ text: String, size: CGFloat = 13, weight: NSFont.Weight = .regular) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: size, weight: weight)
        l.lineBreakMode = .byWordWrapping
        l.maximumNumberOfLines = 0
        l.preferredMaxLayoutWidth = 256
        return l
    }

    private func button(_ title: String, action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded
        return b
    }

    @objc private func refreshTapped() { model.refresh() }
    @objc private func quitTapped() { NSApp.terminate(nil) }
    @objc private func redeemAutoTapped() { confirmRedeem(nil) }
    @objc private func redeemSpecificTapped(_ sender: NSButton) { confirmRedeem(sender.identifier?.rawValue) }

    private func confirmRedeem(_ creditId: String?) {
        let alert = NSAlert()
        alert.messageText = "Redeem a Codex rate-limit reset?"
        alert.informativeText = creditId == nil ? "This will consume one available reset automatically." : "This will consume the selected reset."
        alert.addButton(withTitle: "Redeem")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        if alert.runModal() == .alertFirstButtonReturn { model.redeem(creditId) }
    }

    func render() {
        guard isViewLoaded else { return }
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        let title = model.isLoading ? "Loading…" : "\(model.availableCount) reset\(model.availableCount == 1 ? "" : "s")"
        stack.addArrangedSubview(label(title, size: 15, weight: .semibold))

        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 6
        row.addArrangedSubview(button("Refresh", action: #selector(refreshTapped)))
        row.addArrangedSubview(button("Quit", action: #selector(quitTapped)))

        if let error = model.lastError {
            let err = label(error, size: 12, weight: .regular)
            err.textColor = .systemRed
            stack.addArrangedSubview(err)
        }

        let available = model.credits.filter { $0.status == "available" }
        if available.isEmpty && !model.isLoading {
            stack.addArrangedSubview(label("No rate-limit resets are available.", size: 13))
        }

        for credit in available {
            let item = NSStackView()
            item.orientation = .horizontal
            item.alignment = .centerY
            item.spacing = 8

            let text = NSStackView()
            text.orientation = .vertical
            text.alignment = .leading
            text.spacing = 1
            text.addArrangedSubview(label(credit.title ?? "Rate-limit reset", size: 13, weight: .medium))
            let relative = label("Expires \(relativeExpiry(credit.expires_at))", size: 12)
            relative.textColor = .secondaryLabelColor
            text.addArrangedSubview(relative)
            item.addArrangedSubview(text)

            let redeem = button("Reset", action: #selector(redeemSpecificTapped(_:)))
            redeem.identifier = NSUserInterfaceItemIdentifier(credit.id)
            redeem.isEnabled = !model.isLoading
            item.addArrangedSubview(redeem)

            text.widthAnchor.constraint(equalToConstant: 196).isActive = true
            stack.addArrangedSubview(item)
        }

        stack.addArrangedSubview(row)

        view.layoutSubtreeIfNeeded()
        preferredContentSize = NSSize(width: 280, height: min(max(ceil(stack.fittingSize.height), 96), 360))
    }
}

func parseISODate(_ s: String?) -> Date? {
    guard let s else { return nil }
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return iso.date(from: s) ?? ISO8601DateFormatter().date(from: s)
}

func relativeExpiry(_ s: String?) -> String {
    guard let date = parseISODate(s) else { return "at unknown time" }
    let seconds = Int(date.timeIntervalSinceNow.rounded())
    if seconds <= 0 { return "now" }
    let minute = 60
    let hour = 60 * minute
    let day = 24 * hour
    let month = 30 * day
    let value: Int
    let unit: String
    switch seconds {
    case month...:
        value = max(1, seconds / month)
        unit = value == 1 ? "month" : "months"
    case day...:
        value = max(1, seconds / day)
        unit = value == 1 ? "day" : "days"
    case hour...:
        value = max(1, seconds / hour)
        unit = value == 1 ? "hour" : "hours"
    default:
        value = max(1, seconds / minute)
        unit = value == 1 ? "minute" : "minutes"
    }
    return "in \(value) \(unit)"
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let model = AppModel()
    private var timer: Timer?
    private var eventMonitors: [Any] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        popover.behavior = .transient
        popover.delegate = self
        popover.contentSize = NSSize(width: 280, height: 140)
        popover.contentViewController = ResetPopoverViewController(model: model)

        if let button = statusItem.button {
            button.title = "… resets"
            button.action = #selector(togglePopover(_:))
            button.target = self
        }
        model.onChange = { [weak self] in
            guard let self else { return }
            self.statusItem.button?.title = self.model.isLoading ? "… resets" : "\(self.model.availableCount) reset\(self.model.availableCount == 1 ? "" : "s")"
            (self.popover.contentViewController as? ResetPopoverViewController)?.view.needsLayout = true
        }
        // Reassign after VC init overwrote onChange.
        if let vc = popover.contentViewController as? ResetPopoverViewController {
            model.onChange = { [weak self, weak vc] in
                guard let self else { return }
                self.statusItem.button?.title = self.model.isLoading ? "… resets" : "\(self.model.availableCount) reset\(self.model.availableCount == 1 ? "" : "s")"
                vc?.render()
            }
        }
        model.refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in self?.model.refresh() }
    }

    @objc private func togglePopover(_ sender: Any?) {
        if popover.isShown { closePopover(sender); return }
        if let button = statusItem.button {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            installOutsideClickMonitors()
        }
        model.refresh()
    }

    private func closePopover(_ sender: Any?) {
        popover.performClose(sender)
        removeOutsideClickMonitors()
    }

    private func installOutsideClickMonitors() {
        removeOutsideClickMonitors()
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]

        let localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            guard let self else { return event }
            if self.shouldClosePopover(for: event) { self.closePopover(event) }
            return event
        }

        let globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            DispatchQueue.main.async { self?.closePopover(event) }
        }

        if let localMonitor { eventMonitors.append(localMonitor) }
        if let globalMonitor { eventMonitors.append(globalMonitor) }
    }

    private func removeOutsideClickMonitors() {
        eventMonitors.forEach { NSEvent.removeMonitor($0) }
        eventMonitors.removeAll()
    }

    private func shouldClosePopover(for event: NSEvent) -> Bool {
        guard popover.isShown else { return false }
        let eventWindow = event.window
        if eventWindow == popover.contentViewController?.view.window { return false }
        if eventWindow == statusItem.button?.window { return false }
        return true
    }

    func popoverDidClose(_ notification: Notification) {
        removeOutsideClickMonitors()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
