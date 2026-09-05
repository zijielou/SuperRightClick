import AppKit
import FinderSync
import SwiftUI
import UniformTypeIdentifiers

private final class WeakWindowBox: @unchecked Sendable {
    weak var window: NSWindow?

    init(_ window: NSWindow) {
        self.window = window
    }
}

@MainActor
final class AppLifecycleModel: NSObject, ObservableObject {
    private struct CompletedDestructiveConfirmationResponse {
        let response: DestructiveConfirmationResponse
        let request: DestructiveConfirmationRequest
        let completedAt: Date
    }

    private struct CompletedTransferDestinationResponse {
        let response: TransferDestinationPickerResponse
        let request: TransferDestinationPickerRequest
        let completedAt: Date
    }

    private let observers = NotificationObservationBag()
    private var statusItem: NSStatusItem?
    private var fallbackSettingsWindow: NSWindow?
    private var renameTask: Task<Void, Never>?
    private var destructiveConfirmationTask: Task<Void, Never>?
    private var pendingDestructiveConfirmations: [DestructiveConfirmationRequest] = []
    private var validatingDestructiveConfirmationIDs = Set<UUID>()
    private var inFlightDestructiveConfirmationIDs = Set<UUID>()
    private var resendingDestructiveConfirmationIDs = Set<UUID>()
    private var completedDestructiveConfirmationResponses: [
        UUID: CompletedDestructiveConfirmationResponse
    ] = [:]
    private var transferDestinationPickerTask: Task<Void, Never>?
    private var pendingTransferDestinationPickers: [TransferDestinationPickerRequest] = []
    private var validatingTransferDestinationPickerIDs = Set<UUID>()
    private var inFlightTransferDestinationPickerIDs = Set<UUID>()
    private var resendingTransferDestinationPickerIDs = Set<UUID>()
    private var completedTransferDestinationResponses: [
        UUID: CompletedTransferDestinationResponse
    ] = [:]
    private var configuration: MenuConfiguration

    private var canAcceptAnotherHostUIRequest: Bool {
        HostUIRequestAdmission.canAccept(
            validating: validatingDestructiveConfirmationIDs.count
                + validatingTransferDestinationPickerIDs.count,
            pending: pendingDestructiveConfirmations.count
                + pendingTransferDestinationPickers.count,
            inFlight: inFlightDestructiveConfirmationIDs.count
                + inFlightTransferDestinationPickerIDs.count
        )
    }

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
        observers.addDistributed(TransferDestinationPickerBridge.observeRequests { [weak self] url in
            self?.enqueueTransferDestinationPicker(at: url)
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
        if let requestURL = Self.transferDestinationPickerURLFromLaunchArguments() {
            Task { @MainActor [weak self] in
                await Task.yield()
                self?.enqueueTransferDestinationPicker(at: requestURL)
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

    private static func transferDestinationPickerURLFromLaunchArguments(
        _ arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> URL? {
        guard let marker = arguments.firstIndex(of: TransferDestinationPickerBridge.launchArgument),
              arguments.indices.contains(marker + 1) else { return nil }
        return URL(fileURLWithPath: arguments[marker + 1]).standardizedFileURL
    }

    private func enqueueDestructiveConfirmation(at requestURL: URL) {
        let expiry = Date().addingTimeInterval(-300)
        completedDestructiveConfirmationResponses =
            completedDestructiveConfirmationResponses.filter {
                $0.value.completedAt >= expiry
            }
        guard let requestID = DestructiveConfirmationBridge.requestID(from: requestURL) else {
            return
        }

        if let completed = completedDestructiveConfirmationResponses[requestID] {
            scheduleDestructiveConfirmationResponseResend(completed)
            return
        }
        guard !validatingDestructiveConfirmationIDs.contains(requestID),
              !inFlightDestructiveConfirmationIDs.contains(requestID),
              !pendingDestructiveConfirmations.contains(where: { $0.id == requestID }),
              canAcceptAnotherHostUIRequest else { return }

        validatingDestructiveConfirmationIDs.insert(requestID)
        Task { @MainActor [weak self] in
            let request = await Task.detached(priority: .userInitiated) {
                Self.validatedDestructiveConfirmationRequest(at: requestURL)
            }.value
            guard let self else { return }
            self.validatingDestructiveConfirmationIDs.remove(requestID)
            guard let request,
                  request.id == requestID,
                  self.completedDestructiveConfirmationResponses[requestID] == nil,
                  !self.inFlightDestructiveConfirmationIDs.contains(requestID),
                  !self.pendingDestructiveConfirmations.contains(where: {
                      $0.id == requestID
                  }),
                  self.canAcceptAnotherHostUIRequest else { return }
            self.pendingDestructiveConfirmations.append(request)
            self.processNextDestructiveConfirmation()
        }
    }

    nonisolated private static func validatedDestructiveConfirmationRequest(
        at requestURL: URL
    ) -> DestructiveConfirmationRequest? {
        guard let request = try? DestructiveConfirmationBridge.readRequest(at: requestURL),
              DestructiveConfirmationBridge.hasExpectedProductionTransport(
                  request,
                  requestURL: requestURL
              ),
              request.containingHostBundleIdentity == currentHostBundleIdentity(),
              let expectedCodeHash = embeddedFinderExtensionCodeHash(),
              let peerCodeHash = try? LocalUnixSocket.peerCodeHash(
                  at: request.replySocketPath
              ),
              peerCodeHash == expectedCodeHash else { return nil }
        return request
    }

    private func processNextDestructiveConfirmation() {
        guard destructiveConfirmationTask == nil,
              transferDestinationPickerTask == nil,
              !pendingDestructiveConfirmations.isEmpty else { return }
        let request = pendingDestructiveConfirmations.removeFirst()
        inFlightDestructiveConfirmationIDs.insert(request.id)
        destructiveConfirmationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let approved = await self.presentDestructiveConfirmation(request)
            let response = DestructiveConfirmationResponse(
                requestID: request.id,
                requestDigest: request.authenticationDigest,
                approved: approved
            )
            self.inFlightDestructiveConfirmationIDs.remove(request.id)
            self.completedDestructiveConfirmationResponses[request.id] =
                CompletedDestructiveConfirmationResponse(
                    response: response,
                    request: request,
                    completedAt: Date()
                )
            await self.sendDestructiveConfirmationResponse(response, for: request)
            self.destructiveConfirmationTask = nil
            self.processNextTransferDestinationPicker()
            self.processNextDestructiveConfirmation()
        }
    }

    private func sendDestructiveConfirmationResponse(
        _ response: DestructiveConfirmationResponse,
        for request: DestructiveConfirmationRequest
    ) async {
        guard let expectedPeerCodeHash = Self.embeddedFinderExtensionCodeHash() else { return }
        await Task.detached(priority: .userInitiated) {
            try? DestructiveConfirmationBridge.sendResponse(
                response,
                toSocketPath: request.replySocketPath,
                expectedPeerCodeHash: expectedPeerCodeHash
            )
        }.value
    }

    private func scheduleDestructiveConfirmationResponseResend(
        _ completed: CompletedDestructiveConfirmationResponse
    ) {
        guard resendingDestructiveConfirmationIDs.insert(completed.request.id).inserted else {
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.sendDestructiveConfirmationResponse(
                completed.response,
                for: completed.request
            )
            self.resendingDestructiveConfirmationIDs.remove(completed.request.id)
        }
    }

    private func enqueueTransferDestinationPicker(at requestURL: URL) {
        let expiry = Date().addingTimeInterval(-300)
        completedTransferDestinationResponses = completedTransferDestinationResponses.filter {
            $0.value.completedAt >= expiry
        }
        guard let requestID = TransferDestinationPickerBridge.requestID(from: requestURL) else {
            return
        }

        if let completed = completedTransferDestinationResponses[requestID] {
            // The extension keeps publishing wake-ups until it receives a reply.
            // Re-send the exact authenticated response after a transient socket
            // failure instead of permanently discarding the request ID.
            scheduleTransferDestinationPickerResponseResend(completed)
            return
        }
        guard !validatingTransferDestinationPickerIDs.contains(requestID),
              !inFlightTransferDestinationPickerIDs.contains(requestID),
              !pendingTransferDestinationPickers.contains(where: { $0.id == requestID }),
              canAcceptAnotherHostUIRequest else { return }

        validatingTransferDestinationPickerIDs.insert(requestID)
        Task { @MainActor [weak self] in
            let request = await Task.detached(priority: .userInitiated) {
                Self.validatedTransferDestinationPickerRequest(at: requestURL)
            }.value
            guard let self else { return }
            self.validatingTransferDestinationPickerIDs.remove(requestID)
            guard let request,
                  request.id == requestID,
                  self.completedTransferDestinationResponses[requestID] == nil,
                  !self.inFlightTransferDestinationPickerIDs.contains(requestID),
                  !self.pendingTransferDestinationPickers.contains(where: {
                      $0.id == requestID
                  }),
                  self.canAcceptAnotherHostUIRequest else { return }
            self.pendingTransferDestinationPickers.append(request)
            self.processNextTransferDestinationPicker()
        }
    }

    nonisolated private static func validatedTransferDestinationPickerRequest(
        at requestURL: URL
    ) -> TransferDestinationPickerRequest? {
        guard let request = try? TransferDestinationPickerBridge.readRequest(at: requestURL),
              TransferDestinationPickerBridge.hasExpectedProductionTransport(
                  request,
                  requestURL: requestURL
              ),
              request.containingHostBundleIdentity == currentHostBundleIdentity(),
              let expectedCodeHash = embeddedFinderExtensionCodeHash(),
              let peerCodeHash = try? LocalUnixSocket.peerCodeHash(
                  at: request.replySocketPath
              ),
              peerCodeHash == expectedCodeHash else { return nil }
        return request
    }

    nonisolated private static func currentHostBundleIdentity() -> HostBundleIdentity? {
        HostBundleIdentity.capture(at: Bundle.main.bundleURL)
    }

    nonisolated private static func embeddedFinderExtensionCodeHash() -> Data? {
        guard let plugInsURL = Bundle.main.builtInPlugInsURL else { return nil }
        let extensionURL = plugInsURL.appendingPathComponent(
            "SuperRightClickFinder.appex",
            isDirectory: true
        )
        return CodeIdentity.codeHash(at: extensionURL)
    }

    private func processNextTransferDestinationPicker() {
        guard transferDestinationPickerTask == nil,
              destructiveConfirmationTask == nil,
              !pendingTransferDestinationPickers.isEmpty else { return }
        let request = pendingTransferDestinationPickers.removeFirst()
        inFlightTransferDestinationPickerIDs.insert(request.id)
        transferDestinationPickerTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let selection = await self.presentTransferDestinationPicker(request)
            let response = TransferDestinationPickerResponse(
                requestID: request.id,
                requestDigest: request.authenticationDigest,
                outcome: selection.outcome,
                destinationBookmark: selection.bookmark
            )
            self.inFlightTransferDestinationPickerIDs.remove(request.id)
            self.completedTransferDestinationResponses[request.id] =
                CompletedTransferDestinationResponse(
                    response: response,
                    request: request,
                    completedAt: Date()
                )
            await self.sendTransferDestinationPickerResponse(
                response,
                for: request
            )
            self.transferDestinationPickerTask = nil
            self.processNextDestructiveConfirmation()
            self.processNextTransferDestinationPicker()
        }
    }

    private func sendTransferDestinationPickerResponse(
        _ response: TransferDestinationPickerResponse,
        for request: TransferDestinationPickerRequest
    ) async {
        guard let expectedPeerCodeHash = Self.embeddedFinderExtensionCodeHash() else { return }
        await Task.detached(priority: .userInitiated) {
            try? TransferDestinationPickerBridge.sendResponse(
                response,
                toSocketPath: request.replySocketPath,
                expectedPeerCodeHash: expectedPeerCodeHash
            )
        }.value
    }

    private func scheduleTransferDestinationPickerResponseResend(
        _ completed: CompletedTransferDestinationResponse
    ) {
        guard resendingTransferDestinationPickerIDs.insert(completed.request.id).inserted else {
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.sendTransferDestinationPickerResponse(
                completed.response,
                for: completed.request
            )
            self.resendingTransferDestinationPickerIDs.remove(completed.request.id)
        }
    }

    private func presentTransferDestinationPicker(
        _ request: TransferDestinationPickerRequest
    ) async -> (outcome: TransferDestinationPickerResponse.Outcome, bookmark: Data?) {
        let remaining = TransferDestinationPickerBridge.remainingResponseLifetime(for: request)
        guard remaining > 0 else { return (.failed, nil) }

        await activateForHostUI()

        let language = configuration.language
        let panel = NSOpenPanel()
        let selectsIconImage = request.operation == .selectFolderIconImage
        let title: String
        switch request.operation {
        case .copy:
            title = "选择复制目标文件夹"
        case .move:
            title = "选择移动目标文件夹"
        case .selectFolderIconImage:
            title = "选择文件夹图标图片"
        }
        panel.title = Localizer.text(title, language: language)
        panel.canChooseDirectories = !selectsIconImage
        panel.canChooseFiles = selectsIconImage
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = !selectsIconImage
        panel.resolvesAliases = true
        if selectsIconImage {
            panel.allowedContentTypes = [.image]
        }
        panel.level = .modalPanel
        panel.collectionBehavior.formUnion([.moveToActiveSpace, .fullScreenAuxiliary])

        let timeoutTask = Task { @MainActor [weak panel] in
            do {
                try await Task.sleep(for: .seconds(remaining))
            } catch {
                return
            }
            panel?.cancel(nil)
        }
        defer { timeoutTask.cancel() }

        let response = await panel.begin()
        guard response == .OK,
              Date().timeIntervalSince(request.createdAt)
                < TransferDestinationPickerBridge.responseTimeoutSeconds,
              let destination = panel.url else {
            return (.cancelled, nil)
        }

        do {
            let resourceKeys: Set<URLResourceKey> = selectsIconImage
                ? [.isRegularFileKey, .contentTypeKey]
                : [.isDirectoryKey]
            let values = try destination.resourceValues(forKeys: resourceKeys)
            if selectsIconImage {
                guard values.isRegularFile == true,
                      values.contentType?.conforms(to: .image) == true else {
                    return (.failed, nil)
                }
            } else {
                guard values.isDirectory == true else { return (.failed, nil) }
            }
            // For an immediate cross-process handoff Apple requires an
            // implicit-scope bookmark. Explicit app-scoped bookmarks are tied
            // to the creator's signing identity and cannot be consumed by the
            // separately sandboxed Finder extension.
            let bookmark = try TransferDestinationPickerBridge
                .makeEphemeralBookmark(for: destination)
            guard !bookmark.isEmpty,
                  bookmark.count <= TransferDestinationPickerBridge.maximumBookmarkSize else {
                return (.failed, nil)
            }
            return (.selected, bookmark)
        } catch {
            return (.failed, nil)
        }
    }

    private func activateForHostUI() async {
        NSApp.activate()
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .milliseconds(600))
        while !NSApp.isActive, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(40))
            if !NSApp.isActive { NSApp.activate() }
        }
    }

    private func presentDestructiveConfirmation(
        _ request: DestructiveConfirmationRequest
    ) async -> Bool {
        let maximumAge = DestructiveConfirmationBridge.responseTimeoutSeconds
        let remaining = DestructiveConfirmationBridge.remainingResponseLifetime(
            for: request
        )
        guard remaining > 0 else { return false }

        NSApp.activate()
        if !NSApp.isActive {
            try? await Task.sleep(for: .milliseconds(80))
            if !NSApp.isActive { NSApp.activate() }
        }

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
        window.level = .modalPanel
        window.collectionBehavior.formUnion([.moveToActiveSpace, .fullScreenAuxiliary])
        window.makeKeyAndOrderFront(nil)
        if !NSApp.isActive {
            NSApp.activate()
        }
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
        NSApp.activate()
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
