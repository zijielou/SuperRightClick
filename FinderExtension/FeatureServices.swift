@preconcurrency import AppKit
import CryptoKit
import Foundation
import ImageIO
import Security
import UniformTypeIdentifiers

enum HostCodeIdentity {
    static func codeHash(at applicationURL: URL) -> Data? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(
            applicationURL as CFURL,
            SecCSFlags(),
            &staticCode
        ) == errSecSuccess,
        let staticCode else { return nil }
        return signingHash(for: staticCode)
    }

    static func codeHash(processIdentifier: pid_t) -> Data? {
        let attributes = [
            kSecGuestAttributePid as String: NSNumber(value: processIdentifier),
        ] as CFDictionary
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(
            nil,
            attributes,
            SecCSFlags(),
            &code
        ) == errSecSuccess,
        let code,
        SecCodeCheckValidity(code, SecCSFlags(), nil) == errSecSuccess else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess,
              let staticCode else { return nil }
        return signingHash(for: staticCode)
    }

    private static func signingHash(for code: SecStaticCode) -> Data? {
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(
            code,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information
        ) == errSecSuccess,
        let dictionary = information as? [String: Any] else { return nil }
        return dictionary[kSecCodeInfoUnique as String] as? Data
    }
}

final class AuthenticatedDestructiveConfirmationServer: @unchecked Sendable {
    let socketPath: String

    private static let pollIntervalMilliseconds: Int32 = 100
    private static let responseReadTimeout: Duration = .seconds(2)
    private static let maximumResponseSize = 4 * 1024
    private let requestID: UUID
    private let expectedHostCodeHash: Data
    private let expectedRequestDigest: Data
    private let lock = NSLock()
    private var descriptor: Int32 = -1

    static func makeSocketPath() -> String {
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16)
        return FileManager.default.temporaryDirectory
            .appendingPathComponent(".src-\(token)")
            .path
    }

    init(
        socketPath: String,
        requestID: UUID,
        expectedHostCodeHash: Data,
        expectedRequestDigest: Data
    ) throws {
        self.socketPath = socketPath
        self.requestID = requestID
        self.expectedHostCodeHash = expectedHostCodeHash
        self.expectedRequestDigest = expectedRequestDigest

        let socketDescriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketDescriptor >= 0 else {
            throw SecureFileFailure.posix("无法创建永久删除确认通道", errno)
        }
        descriptor = socketDescriptor
        do {
            let flags = fcntl(socketDescriptor, F_GETFL)
            guard flags >= 0,
                  fcntl(socketDescriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
                throw SecureFileFailure.posix("无法配置永久删除确认通道", errno)
            }
            var (address, length) = try LocalUnixSocket.address(for: socketPath)
            socketPath.withCString { path in
                _ = unlink(path)
            }
            let bindResult = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(socketDescriptor, $0, length)
                }
            }
            guard bindResult == 0 else {
                throw SecureFileFailure.posix("无法绑定永久删除确认通道", errno)
            }
            guard socketPath.withCString({ chmod($0, 0o600) }) == 0 else {
                throw SecureFileFailure.posix("无法设置永久删除确认通道权限", errno)
            }
            guard listen(socketDescriptor, 4) == 0 else {
                throw SecureFileFailure.posix("无法监听永久删除确认通道", errno)
            }
        } catch {
            invalidate()
            throw error
        }
    }

    func receiveResponse() -> Bool {
        while true {
            let listeningDescriptor = currentDescriptor()
            guard listeningDescriptor >= 0 else { return false }

            var pollDescriptor = pollfd(
                fd: listeningDescriptor,
                events: Int16(POLLIN),
                revents: 0
            )
            let pollResult = Darwin.poll(
                &pollDescriptor,
                1,
                Self.pollIntervalMilliseconds
            )
            guard isActive(listeningDescriptor) else { return false }
            if pollResult < 0 {
                if errno == EINTR { continue }
                return false
            }
            if pollResult == 0 { continue }
            let failureEvents = Int16(POLLERR | POLLHUP | POLLNVAL)
            if pollDescriptor.revents & failureEvents != 0 { return false }
            guard pollDescriptor.revents & Int16(POLLIN) != 0 else { continue }

            lock.lock()
            guard descriptor == listeningDescriptor else {
                lock.unlock()
                return false
            }
            let client = accept(listeningDescriptor, nil, nil)
            let acceptError = errno
            lock.unlock()
            if client < 0 {
                if acceptError == EINTR ||
                    acceptError == EAGAIN ||
                    acceptError == EWOULDBLOCK {
                    continue
                }
                return false
            }
            defer { _ = close(client) }

            let clientFlags = fcntl(client, F_GETFL)
            guard clientFlags >= 0,
                  fcntl(client, F_SETFL, clientFlags | O_NONBLOCK) == 0 else {
                continue
            }

            var peerPID: pid_t = 0
            var peerPIDSize = socklen_t(MemoryLayout<pid_t>.size)
            guard getsockopt(
                client,
                SOL_LOCAL,
                LOCAL_PEERPID,
                &peerPID,
                &peerPIDSize
            ) == 0,
            HostCodeIdentity.codeHash(processIdentifier: peerPID) == expectedHostCodeHash else {
                continue
            }

            guard let response = readResponse(
                from: client,
                whileListeningOn: listeningDescriptor
            ) else {
                return false
            }
            guard response.requestID == requestID,
                  response.requestDigest == expectedRequestDigest else {
                continue
            }
            return response.approved
        }
    }

    func invalidate() {
        lock.lock()
        let socketDescriptor = descriptor
        descriptor = -1
        lock.unlock()
        if socketDescriptor >= 0 {
            _ = shutdown(socketDescriptor, SHUT_RDWR)
            _ = close(socketDescriptor)
        }
        socketPath.withCString { _ = unlink($0) }
    }

    private func readResponse(
        from client: Int32,
        whileListeningOn listeningDescriptor: Int32
    ) -> DestructiveConfirmationResponse? {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: Self.responseReadTimeout)
        var data = Data()
        var reachedEndOfStream = false
        var buffer = [UInt8](repeating: 0, count: 1024)

        while data.count <= Self.maximumResponseSize, clock.now < deadline {
            guard isActive(listeningDescriptor) else { return nil }
            var pollDescriptor = pollfd(
                fd: client,
                events: Int16(POLLIN | POLLHUP),
                revents: 0
            )
            let pollResult = Darwin.poll(
                &pollDescriptor,
                1,
                Self.pollIntervalMilliseconds
            )
            guard isActive(listeningDescriptor) else { return nil }
            if pollResult < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if pollResult == 0 { continue }
            let failureEvents = Int16(POLLERR | POLLNVAL)
            if pollDescriptor.revents & failureEvents != 0 { return nil }
            guard pollDescriptor.revents & Int16(POLLIN | POLLHUP) != 0 else {
                continue
            }

            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(client, $0.baseAddress, $0.count)
            }
            if count < 0 {
                if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK {
                    continue
                }
                return nil
            }
            if count == 0 {
                reachedEndOfStream = true
                break
            }
            data.append(contentsOf: buffer.prefix(count))
        }

        guard reachedEndOfStream,
              isActive(listeningDescriptor),
              !data.isEmpty,
              data.count <= Self.maximumResponseSize else {
            return nil
        }
        return try? JSONDecoder().decode(
            DestructiveConfirmationResponse.self,
            from: data
        )
    }

    private func currentDescriptor() -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        return descriptor
    }

    private func isActive(_ candidate: Int32) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return descriptor == candidate
    }

    deinit {
        invalidate()
    }
}

struct OperationFailure: LocalizedError, CustomStringConvertible, Sendable {
    let key: String
    let arguments: [String]

    init(description: String) {
        key = description
        arguments = []
    }

    init(_ key: String, arguments: [String] = []) {
        self.key = key
        self.arguments = arguments
    }

    var description: String {
        message(language: .simplifiedChinese)
    }

    var errorDescription: String? { description }

    func message(language: AppLanguage) -> String {
        Localizer.format(
            key,
            language: language,
            arguments: arguments.map { $0 as CVarArg }
        )
    }
}

enum PathSafety {
    static func standardized(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    static func isProtected(_ url: URL) -> Bool {
        let path = standardized(url).path
        let home = standardized(Self.realHome).path
        if path == "/" || path == home { return true }
        let protectedRoots = [
            "/System", "/usr", "/bin", "/sbin", "/Library",
            "/Applications", "/private",
        ]
        if protectedRoots.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
            return true
        }
        let bundle = standardized(Bundle.main.bundleURL).path
        return path == bundle || path.hasPrefix(bundle + "/") || bundle.hasPrefix(path + "/")
    }

    static var realHome: URL {
        UserPaths.homeDirectory
    }
}

enum UniqueName {
    static func candidateURL(
        in directory: URL,
        baseName: String,
        fileExtension: String?,
        index: Int
    ) -> URL {
        let ext = fileExtension?.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let suffix = index == 1 ? "" : " \(index)"
        let name = baseName + suffix
        if let ext, !ext.isEmpty {
            return directory.appendingPathComponent(name).appendingPathExtension(ext)
        }
        return directory.appendingPathComponent(name)
    }

    static func availableURL(
        in directory: URL,
        baseName: String,
        fileExtension: String?,
        fileManager: FileManager = .default
    ) -> URL {
        var index = 1
        while fileManager.fileExists(atPath: candidateURL(
            in: directory,
            baseName: baseName,
            fileExtension: fileExtension,
            index: index
        ).path) {
            index += 1
        }
        return candidateURL(
            in: directory,
            baseName: baseName,
            fileExtension: fileExtension,
            index: index
        )
    }

    static func validatedFilename(_ value: String) throws -> String {
        let result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty, result != ".", result != "..", !result.contains("/") else {
            throw OperationFailure(description: "文件名不能为空，也不能包含“/”。")
        }
        guard result.utf8.count <= 255 else {
            throw OperationFailure(description: "文件名过长。")
        }
        return result
    }

    static func validatedExtension(_ value: String) throws -> String {
        let result = value.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        guard !result.isEmpty, result.count <= 20,
              result.unicodeScalars.allSatisfy({
                  CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_")).contains($0)
              }) else {
            throw OperationFailure(description: "文件后缀无效。")
        }
        return result
    }
}

typealias PermanentDeleteConfirmationProvider = @MainActor @Sendable ([URL]) async -> Bool

@MainActor
final class FeatureCoordinator {
    private let fileManager: FileManager
    private let requiresConfirmation: Bool
    private let templateStorageURL: URL?
    private let safetyPreferencesStore: SafetyPreferencesStore
    private let permanentDeleteConfirmation: PermanentDeleteConfirmationProvider
    private let permanentDeletionWillIsolate: (@MainActor (URL) -> Void)?
    private let errorPresentation: (@MainActor (String) -> Void)?
    private(set) var configuration: MenuConfiguration

    /// 测试必须传入独立的 configurationDefaults 并关闭 publishChanges，
    /// 否则测试数据会写入真实配置并通过分布式通知污染正在运行的应用。
    private let configurationDefaults: UserDefaults
    private let publishChanges: Bool

    init(
        fileManager: FileManager = .default,
        requiresConfirmation: Bool = true,
        templateStorageURL: URL? = nil,
        configurationDefaults: UserDefaults = .standard,
        publishChanges: Bool = true,
        safetyPreferencesStore: SafetyPreferencesStore = .production,
        permanentDeleteConfirmation: PermanentDeleteConfirmationProvider? = nil,
        permanentDeletionWillIsolate: (@MainActor (URL) -> Void)? = nil,
        errorPresentation: (@MainActor (String) -> Void)? = nil
    ) {
        self.fileManager = fileManager
        self.requiresConfirmation = requiresConfirmation
        self.templateStorageURL = templateStorageURL
        self.configurationDefaults = configurationDefaults
        self.publishChanges = publishChanges
        self.safetyPreferencesStore = safetyPreferencesStore
        self.permanentDeletionWillIsolate = permanentDeletionWillIsolate
        self.errorPresentation = errorPresentation
        self.permanentDeleteConfirmation = permanentDeleteConfirmation ?? { urls in
            await FeatureCoordinator.requestPermanentDeleteConfirmation(for: urls)
        }
        configuration = ConfigurationStore.load(defaults: configurationDefaults)
    }

    func updateConfiguration(_ value: MenuConfiguration) {
        let retained = Set(value.templates.compactMap(\.storedFilename))
        let removed = configuration.templates.compactMap(\.storedFilename).filter {
            !retained.contains($0)
        }
        if !removed.isEmpty, let directory = try? templatesDirectory() {
            for filename in removed {
                try? fileManager.removeItem(at: directory.appendingPathComponent(filename))
            }
        }
        configuration = value
    }

    // MARK: - A class

    func create(templateID: UUID, in directory: URL, askForName: Bool = false) {
        guard let template = configuration.templates.first(where: { $0.id == templateID }) else {
            return showError(t("模板已不存在。"))
        }
        do {
            let requestedName: String
            if askForName {
                guard let value = prompt(
                    title: f("新建%@文件", template.name),
                    message: t("请输入文件名（可不填写后缀）"),
                    defaultValue: t("未命名")
                ) else { return }
                requestedName = try UniqueName.validatedFilename(value)
            } else {
                requestedName = t("未命名")
            }

            let supplied = URL(fileURLWithPath: requestedName)
            let baseName = supplied.deletingPathExtension().lastPathComponent
            let requestedExtension = supplied.pathExtension
            let finalExtension = try UniqueName.validatedExtension(
                requestedExtension.isEmpty ? template.fileExtension : requestedExtension
            )
            let output = UniqueName.availableURL(
                in: directory,
                baseName: baseName,
                fileExtension: finalExtension,
                fileManager: fileManager
            )
            try write(template: template, to: output)
            if configuration.playCreationSound { NSSound.beep() }
            if configuration.autoOpenNewFile {
                NSWorkspace.shared.open(output)
            } else {
                beginRename(of: output)
            }
        } catch {
            showError(errorText(error))
        }
    }

    /// 新建文件后选中它并触发 Finder 的重命名编辑状态。
    /// 主应用已运行时使用低延迟分布式通知；主应用未运行时从 Finder 扩展
    /// 包路径定位宿主 App，并以不抢焦点的方式携带文件路径启动它。
    private func beginRename(of url: URL) {
        guard requiresConfirmation else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])

        let isHostRunning = !NSRunningApplication.runningApplications(
            withBundleIdentifier: RenameRequestBridge.hostBundleIdentifier
        ).isEmpty
        if isHostRunning {
            ConfigurationStore.requestRename(url)
            return
        }

        guard let hostURL = Self.containingHostApplicationURL() else {
            ConfigurationStore.requestRename(url)
            return
        }
        let launchConfiguration = NSWorkspace.OpenConfiguration()
        launchConfiguration.activates = false
        launchConfiguration.addsToRecentItems = false
        launchConfiguration.arguments = [RenameRequestBridge.launchArgument, url.path]
        NSWorkspace.shared.openApplication(
            at: hostURL,
            configuration: launchConfiguration
        ) { _, error in
            // 极少数情况下 Launch Services 已启动 App 却仍返回错误；通知作为
            // 最后的无害回退，若 App 未启动则文件仍保持被 Finder 选中。
            if error != nil { ConfigurationStore.requestRename(url) }
        }
    }

    private static func containingHostApplicationURL() -> URL? {
        var candidate = Bundle.main.bundleURL.standardizedFileURL
        while candidate.path != "/" {
            if candidate.pathExtension.caseInsensitiveCompare("app") == .orderedSame {
                return candidate
            }
            candidate.deleteLastPathComponent()
        }
        return nil
    }

    func createNamedFile(in directory: URL) {
        let enabled = configuration.templates.filter(\.isEnabled)
        guard !enabled.isEmpty else { return showError(t("没有启用的新建模板。")) }
        let alert = NSAlert()
        alert.messageText = t("通过窗口创建新文件")
        alert.informativeText = t("输入文件名，并选择文件格式。")
        alert.addButton(withTitle: t("创建"))
        alert.addButton(withTitle: t("取消"))
        let field = NSTextField(string: t("未命名"))
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 260, height: 26))
        enabled.forEach { popup.addItem(withTitle: "\($0.name) (.\($0.fileExtension))") }
        let stack = NSStackView(views: [field, popup])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 280, height: 62)
        alert.accessoryView = stack
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            let filename = try UniqueName.validatedFilename(field.stringValue)
            let template = enabled[popup.indexOfSelectedItem]
            let supplied = URL(fileURLWithPath: filename)
            let ext = try UniqueName.validatedExtension(
                supplied.pathExtension.isEmpty ? template.fileExtension : supplied.pathExtension
            )
            let output = UniqueName.availableURL(
                in: directory,
                baseName: supplied.deletingPathExtension().lastPathComponent,
                fileExtension: ext,
                fileManager: fileManager
            )
            try write(template: template, to: output)
            if configuration.playCreationSound { NSSound.beep() }
            if configuration.autoOpenNewFile {
                NSWorkspace.shared.open(output)
            } else {
                beginRename(of: output)
            }
        } catch {
            showError(errorText(error))
        }
    }

    func importTemplate(from source: URL) {
        let rawExtension = source.pathExtension.lowercased()
        guard !rawExtension.isEmpty else {
            return showError(t("模板文件必须具有扩展名。"))
        }
        guard let name = prompt(
            title: t("添加自定义模板"),
            message: t("模板将复制到 SuperRightClick 的独立容器，不会修改原文件。"),
            defaultValue: source.deletingPathExtension().lastPathComponent
        ) else { return }
        do {
            try registerTemplate(from: source, name: name)
            showInfo(f("模板“%@”已添加。", name))
        } catch {
            showError(errorText(error))
        }
    }

    @discardableResult
    func registerTemplate(from source: URL, name: String) throws -> NewFileTemplate {
        let validName = try UniqueName.validatedFilename(name)
        let ext = try UniqueName.validatedExtension(source.pathExtension.lowercased())
        let directory = try templatesDirectory()
        let id = UUID()
        let storedName = "\(id.uuidString).\(ext)"
        let destination = directory.appendingPathComponent(storedName)
        try fileManager.copyItem(at: source, to: destination)
        let template = NewFileTemplate(
            id: id,
            name: validName,
            fileExtension: ext,
            kind: .custom,
            storedFilename: storedName
        )
        // 同名同扩展名的模板视为替换，避免重复导入时菜单里堆积重复项。
        if let existing = configuration.templates.firstIndex(where: {
            $0.name.lowercased() == validName.lowercased()
                && $0.fileExtension.lowercased() == ext
        }) {
            if let oldStored = configuration.templates[existing].storedFilename {
                try? fileManager.removeItem(at: directory.appendingPathComponent(oldStored))
            }
            configuration.templates[existing] = template
        } else {
            configuration.templates.append(template)
        }
        persistConfiguration()
        return template
    }

    private func write(template: NewFileTemplate, to output: URL) throws {
        switch template.kind {
        case .text, .markdown:
            try Data().write(to: output, options: .withoutOverwriting)
        case .richText:
            try Data("{\\rtf1\\ansi\\deff0\\n}".utf8).write(to: output, options: .withoutOverwriting)
        case .xml:
            try Data("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n".utf8)
                .write(to: output, options: .withoutOverwriting)
        case .custom:
            guard let filename = template.storedFilename else {
                throw OperationFailure(description: "自定义模板记录不完整。")
            }
            let source = try templatesDirectory().appendingPathComponent(filename)
            try fileManager.copyItem(at: source, to: output)
        }
    }

    private func templatesDirectory() throws -> URL {
        if let templateStorageURL {
            try fileManager.createDirectory(at: templateStorageURL, withIntermediateDirectories: true)
            return templateStorageURL
        }
        guard let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { throw OperationFailure(description: "无法定位模板目录。") }
        let directory = support
            .appendingPathComponent("SuperRightClick", isDirectory: true)
            .appendingPathComponent("Templates", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    // MARK: - B01/B02/B10/B11/B12

    @discardableResult
    func transfer(_ sources: [URL], to directory: URL, move: Bool) -> [URL] {
        guard !sources.isEmpty else { return [] }
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            showError(errorText(error))
            return sources
        }

        let standardizedTarget = PathSafety.standardized(directory)
        let cutItemsThatWereHidden = hiddenCutPaths
        var failedSources: [URL] = []
        var failureMessages: [String] = []

        for source in sources {
            do {
                let standardizedSource = PathSafety.standardized(source)
                let standardizedParent = PathSafety.standardized(source.deletingLastPathComponent())

                // “移动到当前目录”应是无操作，而不是因为冲突命名逻辑把原文件
                // 意外改名为“文件 2”。若它来自剪切状态，同时恢复可见性。
                if move, standardizedParent == standardizedTarget {
                    if cutItemsThatWereHidden.contains(source.path) {
                        var visibleSource = source
                        var values = URLResourceValues()
                        values.isHidden = false
                        try? visibleSource.setResourceValues(values)
                    }
                    continue
                }

                // 防止把目录复制/移动进自身后代，避免递归复制和难以恢复的部分结果。
                if standardizedTarget.path.hasPrefix(standardizedSource.path + "/") {
                    throw OperationFailure(description: "不能将项目放入它自身的子目录。")
                }

                let destination = UniqueName.availableURL(
                    in: directory,
                    baseName: source.deletingPathExtension().lastPathComponent,
                    fileExtension: source.pathExtension.isEmpty ? nil : source.pathExtension,
                    fileManager: fileManager
                )
                if move {
                    try fileManager.moveItem(at: source, to: destination)
                    if cutItemsThatWereHidden.contains(source.path) {
                        var visibleDestination = destination
                        var values = URLResourceValues()
                        values.isHidden = false
                        try? visibleDestination.setResourceValues(values)
                    }
                } else {
                    try fileManager.copyItem(at: source, to: destination)
                }
            } catch {
                failedSources.append(source)
                failureMessages.append(f(
                    "%@：%@",
                    source.lastPathComponent,
                    errorText(error)
                ))
            }
        }

        if failureMessages.isEmpty {
            playOperationSound()
        } else {
            showError(failureMessages.joined(separator: "\n"))
        }
        return failedSources
    }

    func chooseTransferDestination(for sources: [URL], move: Bool) {
        let panel = NSOpenPanel()
        panel.title = t(move ? "选择移动目标文件夹" : "选择复制目标文件夹")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let target = panel.url else { return }
        transfer(sources, to: target, move: move)
    }

    func cut(_ urls: [URL]) {
        restorePreviouslyHiddenCutItems()
        let paths = urls.map(\.path)
        configurationDefaults.set(paths, forKey: "cutPaths")
        guard configuration.hideCutItems else { return }
        var hidden: [String] = []
        for var url in urls {
            guard (try? url.resourceValues(forKeys: [.isHiddenKey]).isHidden) != true else {
                continue
            }
            var values = URLResourceValues()
            values.isHidden = true
            if (try? url.setResourceValues(values)) != nil {
                hidden.append(url.path)
            }
        }
        configurationDefaults.set(hidden, forKey: "hiddenCutPaths")
    }

    func paste(into directory: URL) {
        let paths = configurationDefaults.stringArray(forKey: "cutPaths") ?? []
        if !paths.isEmpty {
            let sources = paths.map { URL(fileURLWithPath: $0) }
            let previouslyHidden = hiddenCutPaths
            let failed = transfer(sources, to: directory, move: true)
            if failed.isEmpty {
                configurationDefaults.removeObject(forKey: "cutPaths")
                configurationDefaults.removeObject(forKey: "hiddenCutPaths")
            } else {
                // 只保留失败项，用户可以修正权限/目标后再次粘贴；原先被临时
                // 隐藏的失败项也继续记录，避免丢失恢复可见性的机会。
                let failedPaths = failed.map(\.path)
                configurationDefaults.set(failedPaths, forKey: "cutPaths")
                configurationDefaults.set(
                    failedPaths.filter { previouslyHidden.contains($0) },
                    forKey: "hiddenCutPaths"
                )
            }
            return
        }
        let copied = NSPasteboard.general.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
        guard !copied.isEmpty else {
            return showError(t("剪贴板中没有可粘贴的文件。"))
        }
        transfer(copied, to: directory, move: false)
    }

    private var hiddenCutPaths: Set<String> {
        Set(configurationDefaults.stringArray(forKey: "hiddenCutPaths") ?? [])
    }

    private func restorePreviouslyHiddenCutItems() {
        for path in hiddenCutPaths {
            var url = URL(fileURLWithPath: path)
            guard fileManager.fileExists(atPath: path) else { continue }
            var values = URLResourceValues()
            values.isHidden = false
            try? url.setResourceValues(values)
        }
        configurationDefaults.removeObject(forKey: "hiddenCutPaths")
    }

    func createSameNameFolders(for urls: [URL]) {
        var created = false
        for url in urls where !url.hasDirectoryPath {
            let folder = UniqueName.availableURL(
                in: url.deletingLastPathComponent(),
                baseName: url.deletingPathExtension().lastPathComponent,
                fileExtension: nil,
                fileManager: fileManager
            )
            do {
                try fileManager.createDirectory(at: folder, withIntermediateDirectories: false)
                created = true
            } catch {
                showError(errorText(error))
            }
        }
        if created { playOperationSound() }
    }

    // MARK: - B03/B04

    func openDirectory(_ shortcutID: UUID) {
        guard let shortcut = configuration.commonDirectories.first(where: { $0.id == shortcutID })
        else { return }
        NSWorkspace.shared.open(shortcut.resolvedURL)
    }

    func addCommonDirectory(_ url: URL) {
        let normalized = PathSafety.standardized(url)
        guard !configuration.commonDirectories.contains(where: {
            PathSafety.standardized($0.resolvedURL) == normalized
        }) else { return showInfo(t("该目录已在常用目录中。")) }
        configuration.commonDirectories.append(
            DirectoryShortcut(name: url.lastPathComponent, path: url.path)
        )
        persistConfiguration()
        showInfo(t("已添加到常用目录。"))
    }

    // MARK: - B05/B06/B07/B08

    func setFolderIcon(_ folder: URL) {
        let panel = NSOpenPanel()
        panel.title = t("选择文件夹图标图片")
        panel.allowedContentTypes = [.image]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let imageURL = panel.url,
              let image = NSImage(contentsOf: imageURL) else { return }
        if !NSWorkspace.shared.setIcon(image, forFile: folder.path, options: []) {
            showError(t("Finder 未能设置文件夹图标。"))
        } else {
            playOperationSound()
        }
    }

    func showFileInfo(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let language = configuration.language
        Task {
            let lines = await Task.detached(priority: .userInitiated) {
                Self.fileInfoLines(for: urls, language: language)
            }.value
            guard !Task.isCancelled else { return }
            let alert = NSAlert()
            alert.messageText = t("文件信息与摘要")
            alert.informativeText = lines.joined(separator: "\n")
            alert.addButton(withTitle: t("完成"))
            alert.runModal()
        }
    }

    nonisolated private static func fileInfoLines(
        for urls: [URL],
        language: AppLanguage
    ) -> [String] {
        let locale = Localizer.locale(for: language)
        let dateFormatter = DateFormatter()
        dateFormatter.locale = locale
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .medium

        func byteCount(_ count: Int) -> String {
            let units = ["B", "KB", "MB", "GB", "TB", "PB"]
            var value = Double(count)
            var unitIndex = 0
            while value >= 1_000, unitIndex < units.count - 1 {
                value /= 1_000
                unitIndex += 1
            }
            let number = NumberFormatter()
            number.locale = locale
            number.maximumFractionDigits = unitIndex == 0 ? 0 : 1
            number.minimumFractionDigits = 0
            return "\(number.string(from: NSNumber(value: value)) ?? String(Int(value))) \(units[unitIndex])"
        }

        var lines: [String] = []
        for url in urls {
            lines.append(url.lastPathComponent)
            do {
                let values = try url.resourceValues(forKeys: [
                    .fileSizeKey, .totalFileAllocatedSizeKey, .contentModificationDateKey,
                    .isDirectoryKey,
                ])
                lines.append(Localizer.format(
                    "路径：%@",
                    language: language,
                    url.path
                ))
                if let size = values.totalFileAllocatedSize ?? values.fileSize {
                    lines.append(Localizer.format(
                        "大小：%@",
                        language: language,
                        byteCount(size)
                    ))
                }
                if let date = values.contentModificationDate {
                    lines.append(Localizer.format(
                        "修改：%@",
                        language: language,
                        dateFormatter.string(from: date)
                    ))
                }
                if values.isDirectory != true {
                    let hashes = try computeFileHashes(url)
                    lines.append("MD5: \(hashes.md5)")
                    lines.append("SHA1: \(hashes.sha1)")
                    lines.append("SHA256: \(hashes.sha256)")
                    lines.append("SHA512: \(hashes.sha512)")
                }
            } catch {
                lines.append(Localizer.format(
                    "读取失败：%@",
                    language: language,
                    errorText(error, language: language)
                ))
            }
            lines.append("")
        }
        return lines
    }

    func createDesktopAliases(for urls: [URL]) {
        let desktop = PathSafety.realHome.appendingPathComponent("Desktop", isDirectory: true)
        createAliases(for: urls, in: desktop)
    }

    func createAliases(for urls: [URL], in directory: URL) {
        var created = false
        for source in urls {
            do {
                let target = UniqueName.availableURL(
                    in: directory,
                    baseName: source.lastPathComponent,
                    fileExtension: "alias",
                    fileManager: fileManager
                )
                let data = try source.bookmarkData(
                    options: .suitableForBookmarkFile,
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
                try URL.writeBookmarkData(data, to: target)
                created = true
            } catch {
                showError(f(
                    "%@：%@",
                    source.lastPathComponent,
                    errorText(error)
                ))
            }
        }
        if created { playOperationSound() }
    }

    // MARK: - C01/C06/C27 用 App 打开

    func openWith(_ shortcutID: UUID, urls: [URL], currentDirectory: URL?) {
        guard let shortcut = configuration.openWithApps.first(where: { $0.id == shortcutID })
        else { return }
        let appURL = shortcut.appURL
        guard fileManager.fileExists(atPath: appURL.path) else {
            return showError(f("找不到应用：%@", shortcut.appPath))
        }
        var targets = urls.isEmpty ? (currentDirectory.map { [$0] } ?? []) : urls
        if shortcut.isTerminalApp {
            // 终端类应用：选中文件时进入其父目录。
            var seen = Set<String>()
            targets = targets
                .map { isDirectoryTarget($0) ? $0 : $0.deletingLastPathComponent() }
                .filter { seen.insert($0.path).inserted }
        }
        guard !targets.isEmpty else { return }
        NSWorkspace.shared.open(
            targets,
            withApplicationAt: appURL,
            configuration: NSWorkspace.OpenConfiguration()
        ) { _, _ in }
    }

    private func isDirectoryTarget(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        return values?.isDirectory == true && values?.isPackage != true
    }

    // MARK: - B15...B20/B23

    func setHidden(_ urls: [URL], hidden: Bool) {
        var failures: [String] = []
        for var url in urls {
            do {
                var values = URLResourceValues()
                values.isHidden = hidden
                try url.setResourceValues(values)
            } catch {
                failures.append(f(
                    "%@：%@",
                    url.lastPathComponent,
                    errorText(error)
                ))
            }
        }
        if failures.isEmpty {
            playOperationSound()
        } else {
            showError(failures.joined(separator: "\n"))
        }
    }

    func setAllHidden(in directory: URL, hidden: Bool) {
        do {
            let children = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isHiddenKey],
                options: []
            )
            guard confirm(
                title: t(hidden ? "隐藏全部项目" : "显示全部项目"),
                message: f(
                    "将修改“%@”第一层的 %@ 个项目，是否继续？",
                    directory.lastPathComponent,
                    String(children.count)
                )
            ) else { return }
            setHidden(children, hidden: hidden)
        } catch {
            showError(errorText(error))
        }
    }

    func grantWritePermission(_ urls: [URL]) {
        guard urls.allSatisfy({ !PathSafety.isProtected($0) }) else {
            return showError(t("所选内容包含受保护路径。"))
        }
        let preview = urls.compactMap { url -> String? in
            guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
                  let number = attributes[.posixPermissions] as? NSNumber else { return nil }
            let current = number.intValue
            return f(
                "%@：%@",
                url.lastPathComponent,
                "\(String(current, radix: 8)) → \(String(current | 0o200, radix: 8))"
            )
        }
        guard confirm(
            title: t("授予写入权限"),
            message: f("只会为当前用户增加写入权限：\n%@", preview.joined(separator: "\n"))
        )
        else { return }
        for url in urls {
            do {
                let attributes = try fileManager.attributesOfItem(atPath: url.path)
                let current = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o444
                try fileManager.setAttributes(
                    [.posixPermissions: NSNumber(value: current | 0o200)],
                    ofItemAtPath: url.path
                )
            } catch {
                showError(f(
                    "%@：%@",
                    url.lastPathComponent,
                    errorText(error)
                ))
            }
        }
        playOperationSound()
    }

    func dissolve(_ folder: URL) {
        guard !PathSafety.isProtected(folder) else {
            return showError(t("不能解散受保护目录。"))
        }
        do {
            let parent = folder.deletingLastPathComponent()
            let children = try fileManager.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: nil
            )
            let conflicts = children.filter {
                fileManager.fileExists(atPath: parent.appendingPathComponent($0.lastPathComponent).path)
            }
            guard conflicts.isEmpty else {
                return showError(f(
                    "上级目录存在同名项目：\n%@",
                    conflicts.map(\.lastPathComponent).joined(separator: "\n")
                ))
            }
            guard confirm(
                title: t("解散文件夹"),
                message: f(
                    "将移动 %@ 个项目到上级目录并删除“%@”。",
                    String(children.count),
                    folder.lastPathComponent
                )
            ) else { return }
            var moved: [(from: URL, to: URL)] = []
            do {
                for child in children {
                    let destination = parent.appendingPathComponent(child.lastPathComponent)
                    try fileManager.moveItem(at: child, to: destination)
                    moved.append((child, destination))
                }
                try fileManager.removeItem(at: folder)
                playOperationSound()
            } catch {
                for item in moved.reversed() {
                    try? fileManager.moveItem(at: item.to, to: item.from)
                }
                throw error
            }
        } catch {
            showError(errorText(error))
        }
    }

    private struct DeletionTargetSnapshot {
        let url: URL
        let path: String
        let resolvedPath: String
        let device: dev_t
        let inode: ino_t
        let fileType: mode_t
    }

    func permanentlyDelete(_ urls: [URL]) async {
        guard !urls.isEmpty else { return }
        guard let targets = captureDeletionTargets(urls) else { return }

        if requiresConfirmation {
            let preference = safetyPreferencesStore.load()
            if preference.confirmBeforePermanentDelete {
                guard await permanentDeleteConfirmation(targets.map(\.url)) else { return }
                guard revalidateDeletionTargets(targets) else { return }
            } else {
                guard revalidateDeletionTargets(targets) else { return }
                let latestPreference = safetyPreferencesStore.load()
                if latestPreference.confirmBeforePermanentDelete
                    || latestPreference.revision != preference.revision {
                    guard await permanentDeleteConfirmation(targets.map(\.url)) else { return }
                    guard revalidateDeletionTargets(targets) else { return }
                }
            }
        } else {
            guard revalidateDeletionTargets(targets) else { return }
        }

        executePermanentDeletion(targets)
    }

    private func captureDeletionTargets(_ urls: [URL]) -> [DeletionTargetSnapshot]? {
        var targets: [DeletionTargetSnapshot] = []
        targets.reserveCapacity(urls.count)
        for url in urls {
            let standardizedURL = url.standardizedFileURL
            guard !PathSafety.isProtected(standardizedURL) else {
                showError(t("拒绝删除根目录、主目录或系统保护路径。"))
                return nil
            }
            var status = stat()
            guard standardizedURL.path.withCString({ lstat($0, &status) }) == 0 else {
                showError(f("%@：目标已不存在或无法访问。", url.lastPathComponent))
                return nil
            }
            targets.append(DeletionTargetSnapshot(
                url: standardizedURL,
                path: standardizedURL.path,
                resolvedPath: PathSafety.standardized(standardizedURL).path,
                device: status.st_dev,
                inode: status.st_ino,
                fileType: status.st_mode & S_IFMT
            ))
        }
        return targets
    }

    private func revalidateDeletionTargets(_ targets: [DeletionTargetSnapshot]) -> Bool {
        for target in targets {
            let currentURL = target.url.standardizedFileURL
            guard currentURL.path == target.path,
                  !PathSafety.isProtected(currentURL),
                  PathSafety.standardized(currentURL).path == target.resolvedPath else {
                showError(t("永久删除目标在确认期间发生变化，已取消操作。"))
                return false
            }
            var status = stat()
            guard currentURL.path.withCString({ lstat($0, &status) }) == 0,
                  status.st_dev == target.device,
                  status.st_ino == target.inode,
                  status.st_mode & S_IFMT == target.fileType else {
                showError(t("永久删除目标在确认期间已被替换，已取消操作。"))
                return false
            }
        }
        return true
    }

    private func executePermanentDeletion(_ targets: [DeletionTargetSnapshot]) {
        var deleted = false
        for target in targets where isolateAndDelete(target) {
            deleted = true
        }
        if deleted { playOperationSound() }
    }

    /// 将目标以不可覆盖的原子 rename 移到同一父目录的随机隔离名，再复核
    /// device/inode/type 后删除隔离项。rename 是提交线性化点：原公开路径随后
    /// 即使被创建同名新对象，也不会成为本次删除对象。
    private func isolateAndDelete(_ target: DeletionTargetSnapshot) -> Bool {
        let parentURL = target.url.deletingLastPathComponent()
        let originalName = target.url.lastPathComponent
        let parentDescriptor = parentURL.path.withCString {
            open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        }
        guard parentDescriptor >= 0 else {
            showError(f(
                "无法打开永久删除目标目录（POSIX 错误 %@）。",
                String(errno)
            ))
            return false
        }
        defer { _ = close(parentDescriptor) }

        var immediateStatus = stat()
        let immediateResult = originalName.withCString {
            fstatat(parentDescriptor, $0, &immediateStatus, AT_SYMLINK_NOFOLLOW)
        }
        guard immediateResult == 0,
              deletionIdentity(immediateStatus, matches: target) else {
            showError(t("永久删除目标在提交期间已被替换，已取消操作。"))
            return false
        }

        // 仅用于确定性竞态测试；生产配置恒为 nil。
        permanentDeletionWillIsolate?(target.url)

        var isolatedName: String?
        var isolationFailure: Int32?
        for _ in 0..<16 {
            let candidate = ".superrightclick-delete-\(UUID().uuidString)"
            let result = originalName.withCString { originalPath in
                candidate.withCString { isolatedPath in
                    renameatx_np(
                        parentDescriptor,
                        originalPath,
                        parentDescriptor,
                        isolatedPath,
                        UInt32(RENAME_EXCL)
                    )
                }
            }
            if result == 0 {
                isolatedName = candidate
                break
            }
            let code = errno
            if code == EEXIST { continue }
            isolationFailure = code
            break
        }

        guard let isolatedName else {
            if let isolationFailure {
                showError(f(
                    "无法安全隔离永久删除目标（POSIX 错误 %@）。",
                    String(isolationFailure)
                ))
            } else {
                showError(t("无法生成唯一的永久删除隔离路径。"))
            }
            return false
        }

        let isolatedURL = parentURL.appendingPathComponent(isolatedName)
        var isolatedStatus = stat()
        let isolatedResult = isolatedName.withCString {
            fstatat(parentDescriptor, $0, &isolatedStatus, AT_SYMLINK_NOFOLLOW)
        }
        guard isolatedResult == 0,
              deletionIdentity(isolatedStatus, matches: target) else {
            let restoreResult = isolatedName.withCString { isolatedPath in
                originalName.withCString { originalPath in
                    renameatx_np(
                        parentDescriptor,
                        isolatedPath,
                        parentDescriptor,
                        originalPath,
                        UInt32(RENAME_EXCL)
                    )
                }
            }
            if restoreResult == 0 {
                showError(t("永久删除目标身份复核失败，已恢复原路径并取消操作。"))
            } else {
                showError(f(
                    "永久删除目标身份复核失败，且无法恢复原路径；项目保留在 %@（POSIX 错误 %@）。",
                    isolatedURL.path,
                    String(errno)
                ))
            }
            return false
        }

        do {
            try fileManager.removeItem(at: isolatedURL)
        } catch {
            showError(f(
                "无法删除已隔离的永久删除目标；剩余项目位于 %@：%@",
                isolatedURL.path,
                errorText(error)
            ))
            return false
        }
        return true
    }

    private func deletionIdentity(
        _ status: stat,
        matches target: DeletionTargetSnapshot
    ) -> Bool {
        status.st_dev == target.device
            && status.st_ino == target.inode
            && status.st_mode & S_IFMT == target.fileType
    }

    private static func requestPermanentDeleteConfirmation(for urls: [URL]) async -> Bool {
        guard let hostURL = containingHostApplicationURL(),
              let expectedHostCodeHash = HostCodeIdentity.codeHash(at: hostURL) else {
            return false
        }

        let requestID = UUID()
        let request = DestructiveConfirmationRequest(
            id: requestID,
            createdAt: Date(),
            action: .permanentDelete,
            paths: urls.map { $0.standardizedFileURL.path },
            confirmationMode: urls.count > 1 ? .typeDelete : .standard,
            replySocketPath: AuthenticatedDestructiveConfirmationServer.makeSocketPath()
        )
        let server: AuthenticatedDestructiveConfirmationServer
        do {
            server = try AuthenticatedDestructiveConfirmationServer(
                socketPath: request.replySocketPath,
                requestID: requestID,
                expectedHostCodeHash: expectedHostCodeHash,
                expectedRequestDigest: request.authenticationDigest
            )
        } catch {
            return false
        }
        defer { server.invalidate() }

        let requestURL: URL
        do {
            requestURL = try DestructiveConfirmationBridge.writeRequest(request)
        } catch {
            return false
        }
        defer { DestructiveConfirmationBridge.removeRequest(at: requestURL) }

        launchHostApplicationIfNeeded(at: hostURL, requestURL: requestURL)
        let remainingLifetime = DestructiveConfirmationBridge.remainingResponseLifetime(
            for: request
        )
        guard remainingLifetime > 0 else { return false }
        let timeoutMilliseconds = Int64((remainingLifetime * 1_000).rounded(.down))

        return await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await Task.detached(priority: .userInitiated) {
                    server.receiveResponse()
                }.value
            }
            group.addTask {
                do {
                    try await Task.sleep(for: .milliseconds(timeoutMilliseconds))
                } catch {
                    return false
                }
                return false
            }
            group.addTask {
                // DNC 仅作为不可信的唤醒提示。持续重发直到收到经 socket peer
                // 代码身份验证且与展示上下文绑定的响应或绝对期限届满。
                while !Task.isCancelled {
                    DestructiveConfirmationBridge.postRequest(at: requestURL)
                    do {
                        try await Task.sleep(for: .milliseconds(500))
                    } catch {
                        return false
                    }
                }
                return false
            }
            let result = await group.next() ?? false
            let isUnexpired = DestructiveConfirmationBridge.remainingResponseLifetime(
                for: request
            ) > 0
            server.invalidate()
            group.cancelAll()
            return result && isUnexpired
        }
    }

    private static func launchHostApplicationIfNeeded(
        at hostURL: URL,
        requestURL: URL
    ) {
        let isHostRunning = !NSRunningApplication.runningApplications(
            withBundleIdentifier: RenameRequestBridge.hostBundleIdentifier
        ).isEmpty
        guard !isHostRunning else { return }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false
        configuration.arguments = [
            DestructiveConfirmationBridge.launchArgument,
            requestURL.path,
        ]
        NSWorkspace.shared.openApplication(
            at: hostURL,
            configuration: configuration
        ) { _, _ in }
    }

    // MARK: - B21/B22

    func openInFinder(_ url: URL, newTab: Bool) {
        guard newTab else {
            // 新窗口不依赖 Apple 事件，避免“自动化”授权问题。
            NSWorkspace.shared.open(url)
            return
        }
        let escaped = url.path.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source = """
        tell application "Finder"
            activate
            if (count of windows) is 0 then make new Finder window
            tell front window
                set newTab to make new tab
                set target of newTab to POSIX file "\(escaped)"
            end tell
        end tell
        """
        var error: NSDictionary?
        if NSAppleScript(source: source)?.executeAndReturnError(&error) == nil, let error {
            let code = error[NSAppleScript.errorNumber] as? Int
            if code == -1743 {
                showError(t(
                    "系统未授权 SuperRightClick 控制 Finder。\n"
                        + "请打开「系统设置 → 隐私与安全性 → 自动化」，"
                        + "找到 SuperRightClickFinder 并允许其控制“访达”，然后重试。"
                ))
            } else {
                showError(f(
                    "Finder 自动化失败：%@",
                    code.map(String.init) ?? t("未知错误")
                ))
            }
        }
    }

    // MARK: - D01...D04/D08

    func convertImages(_ urls: [URL], to format: ImageConversionFormat) {
        let quality = configuration.imageQuality
        let backgroundHex = configuration.jpgBackgroundHex
        let language = configuration.language
        Task { [weak self] in
            let failures = await Task.detached(priority: .userInitiated) {
                var failures: [String] = []
                for sourceURL in urls {
                    do {
                        _ = try Self.convertImage(
                            sourceURL,
                            to: format,
                            quality: quality,
                            backgroundHex: backgroundHex,
                            fileManager: .default
                        )
                    } catch {
                        failures.append(Localizer.format(
                            "%@：%@",
                            language: language,
                            sourceURL.lastPathComponent,
                            Self.errorText(error, language: language)
                        ))
                    }
                }
                return failures
            }.value
            guard let self, !Task.isCancelled else { return }
            if failures.isEmpty {
                self.playOperationSound()
            } else {
                self.showError(failures.joined(separator: "\n"))
            }
        }
    }

    @discardableResult
    func convertImage(_ sourceURL: URL, to format: ImageConversionFormat) throws -> URL {
        try Self.convertImage(
            sourceURL,
            to: format,
            quality: configuration.imageQuality,
            backgroundHex: configuration.jpgBackgroundHex,
            fileManager: fileManager
        )
    }

    nonisolated static func convertImage(
        _ sourceURL: URL,
        to format: ImageConversionFormat,
        quality: Double,
        backgroundHex: String,
        fileManager: FileManager
    ) throws -> URL {
        guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw OperationFailure(description: "无法读取图片。")
        }
        let outputDirectory = sourceURL.deletingLastPathComponent()
        let type: CFString
        switch format {
        case .webP: type = UTType.webP.identifier as CFString
        case .heic: type = UTType.heic.identifier as CFString
        case .jpg: type = UTType.jpeg.identifier as CFString
        case .png: type = UTType.png.identifier as CFString
        }
        let supportedTypes = CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []
        guard supportedTypes.contains(type as String) else {
            throw OperationFailure(
                "当前 macOS 不支持编码 %@。",
                arguments: [format.fileExtension.uppercased()]
            )
        }

        // 先在目标目录完整编码随机临时文件，再以 RENAME_EXCL 原子提交。
        // 这样并发转换不会争用同一最终路径，失败任务也只会清理自己的文件。
        let temporaryURL = try createTemporaryImageFile(in: outputDirectory)
        var committed = false
        defer {
            if !committed { try? fileManager.removeItem(at: temporaryURL) }
        }
        guard let destination = CGImageDestinationCreateWithURL(
            temporaryURL as CFURL,
            type,
            1,
            nil
        ) else {
            throw OperationFailure(description: "无法创建输出图片。")
        }

        let outputImage = format == .jpg
            ? flattenedForJPEG(image, backgroundHex: backgroundHex)
            : image
        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: max(0, min(1, quality)),
        ]
        CGImageDestinationAddImage(destination, outputImage, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw OperationFailure(description: "图片编码失败。")
        }

        let output = try commitTemporaryImage(
            temporaryURL,
            in: outputDirectory,
            baseName: sourceURL.deletingPathExtension().lastPathComponent,
            fileExtension: format.fileExtension
        )
        committed = true
        return output
    }

    nonisolated private static func createTemporaryImageFile(in directory: URL) throws -> URL {
        for _ in 0..<16 {
            let url = directory.appendingPathComponent(
                ".superrightclick-conversion-\(UUID().uuidString).tmp"
            )
            let descriptor = url.path.withCString {
                open($0, O_CREAT | O_EXCL | O_WRONLY, mode_t(0o666))
            }
            if descriptor >= 0 {
                guard close(descriptor) == 0 else {
                    let code = errno
                    try? FileManager.default.removeItem(at: url)
                    throw imageFileFailure(
                        "无法关闭临时图片文件（POSIX 错误 %@）。",
                        code: code
                    )
                }
                return url
            }
            let code = errno
            if code == EEXIST { continue }
            throw imageFileFailure(
                "无法创建临时图片文件（POSIX 错误 %@）。",
                code: code
            )
        }
        throw OperationFailure(description: "无法创建唯一的临时图片文件。")
    }

    nonisolated private static func commitTemporaryImage(
        _ temporaryURL: URL,
        in directory: URL,
        baseName: String,
        fileExtension: String
    ) throws -> URL {
        var index = 1
        while true {
            let output = UniqueName.candidateURL(
                in: directory,
                baseName: baseName,
                fileExtension: fileExtension,
                index: index
            )
            let result = temporaryURL.path.withCString { temporaryPath in
                output.path.withCString { outputPath in
                    renameatx_np(
                        AT_FDCWD,
                        temporaryPath,
                        AT_FDCWD,
                        outputPath,
                        UInt32(RENAME_EXCL)
                    )
                }
            }
            if result == 0 { return output }
            let code = errno
            if code == EEXIST {
                index += 1
                continue
            }
            throw imageFileFailure(
                "无法提交输出图片（POSIX 错误 %@）。",
                code: code
            )
        }
    }

    nonisolated private static func imageFileFailure(
        _ key: String,
        code: Int32
    ) -> OperationFailure {
        OperationFailure(key, arguments: [String(code)])
    }

    nonisolated private static func flattenedForJPEG(
        _ image: CGImage,
        backgroundHex: String
    ) -> CGImage {
        let components = hexColorComponents(backgroundHex)
        guard let context = CGContext(
            data: nil,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return image }
        context.setFillColor(red: components.r, green: components.g, blue: components.b, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage() ?? image
    }

    nonisolated private static func hexColorComponents(
        _ value: String
    ) -> (r: CGFloat, g: CGFloat, b: CGFloat) {
        let hex = value.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard hex.count == 6, let number = Int(hex, radix: 16) else {
            return (1, 1, 1)
        }
        return (
            CGFloat((number >> 16) & 0xff) / 255,
            CGFloat((number >> 8) & 0xff) / 255,
            CGFloat(number & 0xff) / 255
        )
    }

    func setWallpaper(_ imageURL: URL) {
        let screens = configuration.wallpaperAllScreens
            ? NSScreen.screens
            : (NSScreen.main.map { [$0] } ?? [])
        var failures: [String] = []
        for screen in screens {
            do {
                try NSWorkspace.shared.setDesktopImageURL(
                    imageURL,
                    for: screen,
                    options: [:]
                )
            } catch {
                failures.append(errorText(error))
            }
        }
        if failures.isEmpty {
            playOperationSound()
        } else {
            showError(failures.joined(separator: "\n"))
        }
    }

    // MARK: - Helpers

    private func persistConfiguration() {
        ConfigurationStore.save(configuration, defaults: configurationDefaults, publish: publishChanges)
    }

    private func playOperationSound() {
        guard configuration.playOperationSound else { return }
        NSSound(named: "Glass")?.play()
    }

    nonisolated func fileHashes(_ url: URL) throws -> (md5: String, sha1: String, sha256: String, sha512: String) {
        try Self.computeFileHashes(url)
    }

    nonisolated private static func computeFileHashes(
        _ url: URL
    ) throws -> (md5: String, sha1: String, sha256: String, sha512: String) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var md5 = Insecure.MD5()
        var sha1 = Insecure.SHA1()
        var sha256 = SHA256()
        var sha512 = SHA512()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
            md5.update(data: data)
            sha1.update(data: data)
            sha256.update(data: data)
            sha512.update(data: data)
        }
        func hex<S: Sequence>(_ value: S) -> String where S.Element == UInt8 {
            value.map { String(format: "%02x", $0) }.joined()
        }
        return (hex(md5.finalize()), hex(sha1.finalize()), hex(sha256.finalize()), hex(sha512.finalize()))
    }

    private func t(_ value: String) -> String {
        Localizer.text(value, language: configuration.language)
    }

    private func f(_ value: String, _ arguments: String...) -> String {
        Localizer.format(
            value,
            language: configuration.language,
            arguments: arguments.map { $0 as CVarArg }
        )
    }

    nonisolated private static func errorText(
        _ error: Error,
        language: AppLanguage
    ) -> String {
        if let failure = error as? OperationFailure {
            return failure.message(language: language)
        }
        if let failure = error as? SecureFileFailure {
            return failure.message(language: language)
        }
        return Localizer.systemErrorText(error, language: language)
    }

    private func errorText(_ error: Error) -> String {
        Self.errorText(error, language: configuration.language)
    }

    private func prompt(title: String, message: String, defaultValue: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: t("确定"))
        alert.addButton(withTitle: t("取消"))
        let field = NSTextField(string: defaultValue)
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field
        return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }

    private func confirm(title: String, message: String) -> Bool {
        if !requiresConfirmation { return true }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: t("继续"))
        alert.addButton(withTitle: t("取消"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func showInfo(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "SuperRightClick"
        alert.informativeText = message
        alert.addButton(withTitle: t("好"))
        alert.runModal()
    }

    private func showError(_ message: String) {
        if let errorPresentation {
            errorPresentation(message)
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = t("操作失败")
        alert.informativeText = message
        alert.addButton(withTitle: t("好"))
        alert.runModal()
    }
}
