import AppKit
import FinderSync
import SwiftUI

private final class WeakWindowBox: @unchecked Sendable {
    weak var window: NSWindow?

    init(_ window: NSWindow) {
        self.window = window
    }
}

@MainActor
final class AppLifecycleModel: NSObject, ObservableObject {
    private let observers = NotificationObservationBag()
    private var statusItem: NSStatusItem?
    private var fallbackSettingsWindow: NSWindow?
    private var renameTask: Task<Void, Never>?
    private var destructiveConfirmationTask: Task<Void, Never>?
    private var pendingDestructiveConfirmations: [DestructiveConfirmationRequest] = []
    private var handledDestructiveConfirmationIDs: [UUID: Date] = [:]
    private var configuration: MenuConfiguration

    override init() {
        let initialConfiguration = ConfigurationStore.load()
        configuration = initialConfiguration
        super.init()
        updateStatusItem(configuration: initialConfiguration)
        observers.addLocal(ConfigurationStore.observeLocalUpdates { [weak self] value in
            guard let self else { return }
            self.configuration = value
            self.updateStatusItem(configuration: value)
        })
        // 进程级 owner 负责接收并持久化扩展配置，避免每个设置窗口
        // 都注册一份跨进程观察者和配置请求响应者。
        observers.addDistributed(ConfigurationStore.observeUpdates { _ in })
        observers.addDistributed(ConfigurationStore.observeAppRequests())
        observers.addDistributed(ConfigurationStore.observeRenameRequests { [weak self] url in
            self?.renameInFinder(url)
        })
        observers.addDistributed(DestructiveConfirmationBridge.observeRequests { [weak self] url in
            self?.enqueueDestructiveConfirmation(at: url)
        })
        if let launchURL = Self.renameURLFromLaunchArguments() {
            renameInFinder(launchURL)
        }
        if let requestURL = Self.destructiveConfirmationURLFromLaunchArguments() {
            Task { @MainActor [weak self] in
                await Task.yield()
                self?.enqueueDestructiveConfirmation(at: requestURL)
            }
        }
    }

    private static func renameURLFromLaunchArguments(
        _ arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> URL? {
        guard let marker = arguments.firstIndex(of: RenameRequestBridge.launchArgument),
              arguments.indices.contains(marker + 1) else { return nil }
        return URL(fileURLWithPath: arguments[marker + 1]).standardizedFileURL
    }

    private static func destructiveConfirmationURLFromLaunchArguments(
        _ arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> URL? {
        guard let marker = arguments.firstIndex(of: DestructiveConfirmationBridge.launchArgument),
              arguments.indices.contains(marker + 1) else { return nil }
        return URL(fileURLWithPath: arguments[marker + 1]).standardizedFileURL
    }

    private func enqueueDestructiveConfirmation(at requestURL: URL) {
        let request: DestructiveConfirmationRequest
        do {
            request = try DestructiveConfirmationBridge.readRequest(at: requestURL)
        } catch {
            return
        }

        let expiry = Date().addingTimeInterval(-300)
        handledDestructiveConfirmationIDs = handledDestructiveConfirmationIDs.filter {
            $0.value >= expiry
        }
        guard handledDestructiveConfirmationIDs[request.id] == nil else { return }

        handledDestructiveConfirmationIDs[request.id] = Date()
        pendingDestructiveConfirmations.append(request)
        processNextDestructiveConfirmation()
    }

    private func processNextDestructiveConfirmation() {
        guard destructiveConfirmationTask == nil,
              !pendingDestructiveConfirmations.isEmpty else { return }
        let request = pendingDestructiveConfirmations.removeFirst()
        destructiveConfirmationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let approved = await self.presentDestructiveConfirmation(request)
            await self.sendDestructiveConfirmationResponse(approved, for: request)
            self.destructiveConfirmationTask = nil
            self.processNextDestructiveConfirmation()
        }
    }

    private func sendDestructiveConfirmationResponse(
        _ approved: Bool,
        for request: DestructiveConfirmationRequest
    ) async {
        let response = DestructiveConfirmationResponse(
            requestID: request.id,
            requestDigest: request.authenticationDigest,
            approved: approved
        )
        await Task.detached(priority: .userInitiated) {
            try? DestructiveConfirmationBridge.sendResponse(
                response,
                toSocketPath: request.replySocketPath
            )
        }.value
    }

    private func presentDestructiveConfirmation(
        _ request: DestructiveConfirmationRequest
    ) async -> Bool {
        let maximumAge = DestructiveConfirmationBridge.responseTimeoutSeconds
        let remaining = DestructiveConfirmationBridge.remainingResponseLifetime(
            for: request
        )
        guard remaining > 0 else { return false }

        NSApp.activate(ignoringOtherApps: true)
        let clock = ContinuousClock()
        let activationDeadline = clock.now.advanced(by: .seconds(3))
        while !NSApp.isActive, clock.now < activationDeadline {
            NSApp.activate(ignoringOtherApps: true)
            try? await Task.sleep(for: .milliseconds(25))
        }
        guard NSApp.isActive else { return false }

        let language = configuration.language
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = Localizer.text("永久删除", language: language)
        alert.informativeText = request.paths.count == 1
            ? Localizer.text(
                "将永久删除 1 个项目，此操作不经过废纸篓且无法撤销。",
                language: language
            )
            : Localizer.format(
                "将永久删除 %@ 个项目，此操作不经过废纸篓且无法撤销。",
                language: language,
                String(request.paths.count)
            )
        alert.addButton(withTitle: Localizer.text("永久删除", language: language))
        alert.addButton(withTitle: Localizer.text("取消", language: language))

        var confirmationField: NSTextField?
        if request.confirmationMode == .typeDelete {
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
            field.placeholderString = Localizer.text("请输入 DELETE", language: language)
            alert.accessoryView = field
            confirmationField = field
        }

        let window = alert.window
        window.collectionBehavior.formUnion([.moveToActiveSpace, .fullScreenAuxiliary])
        window.makeKeyAndOrderFront(nil)
        let windowBox = WeakWindowBox(window)
        let timeout = Timer(timeInterval: remaining, repeats: false) { _ in
            Task { @MainActor in
                guard let window = windowBox.window else { return }
                if NSApp.modalWindow === window { NSApp.abortModal() }
                window.orderOut(nil)
            }
        }
        RunLoop.main.add(timeout, forMode: .common)
        defer { timeout.invalidate() }

        let response = alert.runModal()
        guard Date().timeIntervalSince(request.createdAt) < maximumAge,
              response == .alertFirstButtonReturn else { return false }
        return confirmationField?.stringValue == "DELETE" || confirmationField == nil
    }

    private func updateStatusItem(configuration: MenuConfiguration) {
        guard configuration.showMenuBarIcon else {
            if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
            statusItem = nil
            return
        }

        let item: NSStatusItem
        if let statusItem {
            item = statusItem
        } else {
            item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.button?.image = OriginalMenuIcon.statusBarImage()
            item.button?.image?.size = NSSize(width: 18, height: 18)
            item.button?.imageScaling = .scaleProportionallyDown
            item.button?.toolTip = "SuperRightClick"
            statusItem = item
        }

        let language = configuration.language
        let menu = NSMenu()
        let openSettings = NSMenuItem(
            title: Localizer.text("打开设置", language: language),
            action: #selector(showSettings),
            keyEquivalent: ""
        )
        openSettings.target = self
        menu.addItem(openSettings)
        let extensionSettings = NSMenuItem(
            title: Localizer.text("打开 Finder 扩展设置", language: language),
            action: #selector(showFinderExtensionSettings),
            keyEquivalent: ""
        )
        extensionSettings.target = self
        menu.addItem(extensionSettings)
        let quit = NSMenuItem(
            title: Localizer.text("退出", language: language),
            action: #selector(quitApplication),
            keyEquivalent: ""
        )
        quit.target = self
        menu.addItem(quit)
        item.menu = menu
    }

    @objc private func showSettings() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: {
            $0.canBecomeMain && $0 !== fallbackSettingsWindow
        }) {
            window.makeKeyAndOrderFront(nil)
            return
        }
        if fallbackSettingsWindow == nil {
            let controller = NSHostingController(rootView: ContentView())
            let window = NSWindow(contentViewController: controller)
            window.title = "SuperRightClick"
            window.setContentSize(NSSize(width: 820, height: 600))
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.isReleasedWhenClosed = false
            fallbackSettingsWindow = window
        }
        fallbackSettingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func showFinderExtensionSettings() {
        FIFinderSyncController.showExtensionManagementInterface()
    }

    @objc private func quitApplication() {
        NSApp.terminate(nil)
    }

    private func renameInFinder(_ url: URL) {
        renameTask?.cancel()
        guard FileManager.default.fileExists(atPath: url.path) else { return }

        // CGEvent 发布权限才是发送 Return 的直接前置条件；单独检查
        // AXIsProcessTrusted 在部分系统版本上可能与真实投递权限不同步。
        let canPostKeyboardEvent = CGPreflightPostEventAccess() || CGRequestPostEventAccess()
        guard canPostKeyboardEvent else {
            Self.recordRenameOutcome("permissionDenied")
            NSWorkspace.shared.activateFileViewerSelecting([url])
            Self.openAccessibilitySettings()
            return
        }

        let finderBundleIdentifier = "com.apple.finder"
        let needsFinderActivation = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            != finderBundleIdentifier
        if needsFinderActivation {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }

        renameTask = Task { @MainActor in
            let clock = ContinuousClock()
            let finderDeadline = clock.now.advanced(by: .seconds(1))
            var finderApplication: NSRunningApplication?

            while !Task.isCancelled, clock.now < finderDeadline {
                if let frontmost = NSWorkspace.shared.frontmostApplication,
                   frontmost.bundleIdentifier == finderBundleIdentifier {
                    finderApplication = frontmost
                    break
                }
                try? await Task.sleep(for: .milliseconds(8))
            }
            guard !Task.isCancelled,
                  let finderApplication,
                  FileManager.default.fileExists(atPath: url.path) else { return }

            // Finder 在执行扩展菜单回调时仍可能处于菜单跟踪循环。至少等待
            // 120ms，并在辅助功能可读时继续等到焦点离开菜单；最长 350ms。
            let settleStart = clock.now
            let minimumReady = settleStart.advanced(by: .milliseconds(120))
            let settleDeadline = settleStart.advanced(by: .milliseconds(350))
            while !Task.isCancelled, clock.now < settleDeadline {
                if clock.now >= minimumReady,
                   !Self.finderHasFocusedMenu(processIdentifier: finderApplication.processIdentifier) {
                    break
                }
                try? await Task.sleep(for: .milliseconds(8))
            }
            guard !Task.isCancelled,
                  FileManager.default.fileExists(atPath: url.path),
                  NSWorkspace.shared.frontmostApplication?.bundleIdentifier == finderBundleIdentifier
            else { return }

            await Self.postReturnKey(to: finderApplication.processIdentifier)
            let firstProbe = await Self.waitForRenameEditor(
                processIdentifier: finderApplication.processIdentifier,
                timeout: .milliseconds(220)
            )
            switch firstProbe {
            case .editing:
                Self.recordRenameOutcome("editing")
                return
            case .unavailable:
                // 事件发布已获准但 Finder 没有暴露焦点角色时不盲目重试，
                // 避免第一次已经成功却被第二个 Return 立即提交。
                Self.recordRenameOutcome("eventPostedUnverified")
                return
            case .notEditing:
                break
            }

            // 明确读到 Finder 焦点但仍不是文本框，说明第一次 Return 被菜单
            // 跟踪或选择刷新吞掉。重新选择后只重试一次。
            NSWorkspace.shared.activateFileViewerSelecting([url])
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled,
                  FileManager.default.fileExists(atPath: url.path),
                  NSWorkspace.shared.frontmostApplication?.bundleIdentifier == finderBundleIdentifier
            else { return }
            await Self.postReturnKey(to: finderApplication.processIdentifier)
            let retryProbe = await Self.waitForRenameEditor(
                processIdentifier: finderApplication.processIdentifier,
                timeout: .milliseconds(260)
            )
            Self.recordRenameOutcome(retryProbe == .editing ? "editingAfterRetry" : "failed")
        }
    }

    private enum RenameProbeResult: Equatable {
        case editing
        case notEditing
        case unavailable
    }

    private static func finderFocusedRole(processIdentifier: pid_t) -> String? {
        let applicationElement = AXUIElementCreateApplication(processIdentifier)
        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            applicationElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        ) == .success,
        let focusedValue,
        CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else { return nil }

        let focusedElement = focusedValue as! AXUIElement
        var roleValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            focusedElement,
            kAXRoleAttribute as CFString,
            &roleValue
        ) == .success else { return nil }
        return roleValue as? String
    }

    private static func finderHasFocusedMenu(processIdentifier: pid_t) -> Bool {
        guard let role = finderFocusedRole(processIdentifier: processIdentifier) else {
            return false
        }
        return role == (kAXMenuRole as String) || role == (kAXMenuItemRole as String)
    }

    private static func waitForRenameEditor(
        processIdentifier: pid_t,
        timeout: Duration
    ) async -> RenameProbeResult {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        var didReadRole = false
        while !Task.isCancelled, clock.now < deadline {
            if let role = finderFocusedRole(processIdentifier: processIdentifier) {
                didReadRole = true
                if role == (kAXTextFieldRole as String) || role == (kAXTextAreaRole as String) {
                    return .editing
                }
            }
            try? await Task.sleep(for: .milliseconds(8))
        }
        return didReadRole ? .notEditing : .unavailable
    }

    private static func recordRenameOutcome(_ outcome: String) {
        UserDefaults.standard.set(outcome, forKey: "rename.lastOutcome")
        UserDefaults.standard.set(Date(), forKey: "rename.lastOutcomeDate")
    }

    private static func postReturnKey(to processIdentifier: pid_t) async {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let keyDown = CGEvent(
                keyboardEventSource: source,
                virtualKey: 36,
                keyDown: true
              ),
              let keyUp = CGEvent(
                keyboardEventSource: source,
                virtualKey: 36,
                keyDown: false
              ) else { return }
        keyDown.postToPid(processIdentifier)
        try? await Task.sleep(for: .milliseconds(12))
        keyUp.postToPid(processIdentifier)
    }

    private static func openAccessibilitySettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) else { return }
        NSWorkspace.shared.open(url)
    }
}

@main
struct SuperRightClickApp: App {
    @StateObject private var lifecycle = AppLifecycleModel()

    var body: some Scene {
        WindowGroup(id: "settings") {
            ContentView()
        }
        .windowResizability(.contentSize)
    }
}
