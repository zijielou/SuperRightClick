import AppKit
import Darwin
import ImageIO
import UniformTypeIdentifiers
import XCTest

private final class MenuTarget: NSObject {
    @objc func perform(_ sender: NSMenuItem) {}
}

private final class ConcurrentImageResults: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []
    private var errors: [String] = []

    func record(_ result: Result<URL, Error>) {
        lock.lock()
        defer { lock.unlock() }
        switch result {
        case let .success(url):
            urls.append(url)
        case let .failure(error):
            errors.append(error.localizedDescription)
        }
    }

    func snapshot() -> (urls: [URL], errors: [String]) {
        lock.lock()
        defer { lock.unlock() }
        return (urls, errors)
    }
}

@MainActor
private final class PermanentDeleteConfirmationStub {
    private(set) var requestedURLs: [[URL]] = []
    var approved: Bool

    init(approved: Bool) {
        self.approved = approved
    }

    func confirm(_ urls: [URL]) async -> Bool {
        requestedURLs.append(urls)
        return approved
    }
}

final class CoreTests: XCTestCase {
    private var root: URL!
    private var suiteName: String!
    private var isolatedDefaults: UserDefaults!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SuperRightClickTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        suiteName = "SuperRightClickTests.\(UUID().uuidString)"
        isolatedDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
        if let suiteName {
            isolatedDefaults?.removePersistentDomain(forName: suiteName)
        }
    }

    /// 一律使用隔离的 UserDefaults 和安全偏好目录且不广播，避免测试数据污染真实配置。
    @MainActor
    private func makeCoordinator(
        templateStorage: URL? = nil,
        requiresConfirmation: Bool = false,
        safetyPreferencesStore: SafetyPreferencesStore? = nil,
        permanentDeleteConfirmation: PermanentDeleteConfirmationProvider? = nil,
        permanentDeletionWillIsolate: (@MainActor (URL) -> Void)? = nil,
        errorPresentation: (@MainActor (String) -> Void)? = nil
    ) -> FeatureCoordinator {
        FeatureCoordinator(
            requiresConfirmation: requiresConfirmation,
            templateStorageURL: templateStorage,
            configurationDefaults: isolatedDefaults,
            publishChanges: false,
            safetyPreferencesStore: safetyPreferencesStore ?? SafetyPreferencesStore(
                directoryURL: root.appendingPathComponent("SafetyPreferences", isDirectory: true)
            ),
            permanentDeleteConfirmation: permanentDeleteConfirmation,
            permanentDeletionWillIsolate: permanentDeletionWillIsolate,
            errorPresentation: errorPresentation
        )
    }

    func testFilenameValidation() throws {
        XCTAssertEqual(try UniqueName.validatedFilename("报告 😀"), "报告 😀")
        XCTAssertThrowsError(try UniqueName.validatedFilename(""))
        XCTAssertThrowsError(try UniqueName.validatedFilename("../secret"))
        XCTAssertThrowsError(try UniqueName.validatedFilename("a/b"))
        XCTAssertEqual(try UniqueName.validatedExtension(".docx"), "docx")
        XCTAssertThrowsError(try UniqueName.validatedExtension("../app"))
    }

    func testUniqueNameGeneration() throws {
        let first = root.appendingPathComponent("未命名.txt")
        FileManager.default.createFile(atPath: first.path, contents: Data())
        let second = UniqueName.availableURL(
            in: root,
            baseName: "未命名",
            fileExtension: "txt"
        )
        XCTAssertEqual(second.lastPathComponent, "未命名 2.txt")
    }

    func testConfigurationRoundTrip() throws {
        let suite = "SuperRightClickTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var configuration = MenuConfiguration.default
        configuration.enablePermanentDelete = true
        configuration.language = .english
        XCTAssertTrue(ConfigurationStore.save(configuration, defaults: defaults, publish: false))
        XCTAssertEqual(ConfigurationStore.load(defaults: defaults), configuration)
        XCTAssertEqual(ConfigurationStore.load(defaults: defaults).language, .english)
    }

    func testConfigurationSaveFailureDoesNotAdvanceStoredValue() throws {
        var invalid = MenuConfiguration.default
        invalid.imageQuality = .infinity
        XCTAssertFalse(ConfigurationStore.save(invalid, defaults: isolatedDefaults, publish: false))
        XCTAssertFalse(ConfigurationStore.hasStoredConfiguration(defaults: isolatedDefaults))
    }

    func testSafetyPreferencesDefaultSaveAndFailClosedLoading() throws {
        let store = SafetyPreferencesStore(
            directoryURL: root.appendingPathComponent("safety", isDirectory: true)
        )
        XCTAssertTrue(store.load().confirmBeforePermanentDelete)

        let disabled = try store.save(confirmBeforePermanentDelete: false)
        XCTAssertFalse(store.load().confirmBeforePermanentDelete)
        let attributes = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)

        let enabled = try store.save(confirmBeforePermanentDelete: true)
        XCTAssertTrue(enabled.confirmBeforePermanentDelete)
        XCTAssertNotEqual(enabled.revision, disabled.revision)

        try Data("not-json".utf8).write(to: store.fileURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: store.fileURL.path
        )
        XCTAssertTrue(store.load().confirmBeforePermanentDelete)
    }

    func testSafetyPreferencesRejectsSymlinkAndUnknownSchema() throws {
        let validStore = SafetyPreferencesStore(
            directoryURL: root.appendingPathComponent("valid-safety", isDirectory: true)
        )
        _ = try validStore.save(confirmBeforePermanentDelete: false)

        let linkedStore = SafetyPreferencesStore(
            directoryURL: root.appendingPathComponent("linked-safety", isDirectory: true)
        )
        try FileManager.default.createDirectory(
            at: linkedStore.directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.createSymbolicLink(
            at: linkedStore.fileURL,
            withDestinationURL: validStore.fileURL
        )
        XCTAssertTrue(linkedStore.load().confirmBeforePermanentDelete)

        var unknown = try JSONDecoder().decode(
            SafetyPreferences.self,
            from: Data(contentsOf: validStore.fileURL)
        )
        unknown.schemaVersion += 1
        try JSONEncoder().encode(unknown).write(to: validStore.fileURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: validStore.fileURL.path
        )
        XCTAssertTrue(validStore.load().confirmBeforePermanentDelete)
    }

    func testDestructiveConfirmationRequestFileValidation() throws {
        let first = root.appendingPathComponent("first.txt")
        let second = root.appendingPathComponent("second.txt")
        let request = DestructiveConfirmationBridge.makeRequest(
            for: [first, second],
            replySocketPath: "/tmp/superrightclick-test.sock"
        )
        let directory = root.appendingPathComponent("requests", isDirectory: true)
        let requestURL = try DestructiveConfirmationBridge.writeRequest(
            request,
            directoryURL: directory
        )
        defer { DestructiveConfirmationBridge.removeRequest(at: requestURL) }

        XCTAssertEqual(try DestructiveConfirmationBridge.readRequest(at: requestURL), request)
        let attributes = try FileManager.default.attributesOfItem(atPath: requestURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(DestructiveConfirmationBridge.requestID(from: requestURL), request.id)

        let stale = DestructiveConfirmationRequest(
            id: UUID(),
            createdAt: Date().addingTimeInterval(
                -(DestructiveConfirmationBridge.responseTimeoutSeconds + 1)
            ),
            action: .permanentDelete,
            paths: [first.path],
            confirmationMode: .standard,
            replySocketPath: "/tmp/superrightclick-stale-test.sock"
        )
        let staleURL = try DestructiveConfirmationBridge.writeRequest(
            stale,
            directoryURL: directory
        )
        defer { DestructiveConfirmationBridge.removeRequest(at: staleURL) }
        XCTAssertThrowsError(try DestructiveConfirmationBridge.readRequest(at: staleURL))
    }

    func testAuthenticatedConfirmationReplyChannel() async throws {
        let expectedCodeHash = try XCTUnwrap(
            HostCodeIdentity.codeHash(processIdentifier: getpid())
        )
        let expectedRequestDigest = Data("expected-request-context".utf8)
        let requestID = UUID()
        let server = try AuthenticatedDestructiveConfirmationServer(
            socketPath: AuthenticatedDestructiveConfirmationServer.makeSocketPath(),
            requestID: requestID,
            expectedHostCodeHash: expectedCodeHash,
            expectedRequestDigest: expectedRequestDigest
        )
        defer { server.invalidate() }
        let responseTask = Task.detached(priority: .userInitiated) {
            server.receiveResponse()
        }
        try DestructiveConfirmationBridge.sendResponse(
            DestructiveConfirmationResponse(
                requestID: requestID,
                requestDigest: expectedRequestDigest,
                approved: true
            ),
            toSocketPath: server.socketPath
        )
        let accepted = await responseTask.value
        XCTAssertTrue(accepted)

        let rejectedRequestID = UUID()
        let rejectedServer = try AuthenticatedDestructiveConfirmationServer(
            socketPath: AuthenticatedDestructiveConfirmationServer.makeSocketPath(),
            requestID: rejectedRequestID,
            expectedHostCodeHash: Data(repeating: 0, count: expectedCodeHash.count),
            expectedRequestDigest: expectedRequestDigest
        )
        let rejectedTask = Task.detached(priority: .userInitiated) {
            rejectedServer.receiveResponse()
        }
        try DestructiveConfirmationBridge.sendResponse(
            DestructiveConfirmationResponse(
                requestID: rejectedRequestID,
                requestDigest: expectedRequestDigest,
                approved: true
            ),
            toSocketPath: rejectedServer.socketPath
        )
        try await Task.sleep(for: .milliseconds(50))
        rejectedServer.invalidate()
        let rejected = await rejectedTask.value
        XCTAssertFalse(rejected)

        let substitutedRequestID = UUID()
        let substitutedServer = try AuthenticatedDestructiveConfirmationServer(
            socketPath: AuthenticatedDestructiveConfirmationServer.makeSocketPath(),
            requestID: substitutedRequestID,
            expectedHostCodeHash: expectedCodeHash,
            expectedRequestDigest: expectedRequestDigest
        )
        let substitutedTask = Task.detached(priority: .userInitiated) {
            substitutedServer.receiveResponse()
        }
        try DestructiveConfirmationBridge.sendResponse(
            DestructiveConfirmationResponse(
                requestID: substitutedRequestID,
                requestDigest: Data("substituted-request-context".utf8),
                approved: true
            ),
            toSocketPath: substitutedServer.socketPath
        )
        try await Task.sleep(for: .milliseconds(50))
        substitutedServer.invalidate()
        let substituted = await substitutedTask.value
        XCTAssertFalse(substituted)
    }

    func testPermanentDeleteSafetyPreferenceIsNotStoredInMenuConfiguration() throws {
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(MenuConfiguration.default)
            ) as? [String: Any]
        )
        XCTAssertNil(object["confirmBeforePermanentDelete"])
    }

    /// 旧版本存储的配置没有 openWithApps/language 字段，解码时必须回填默认值。
    func testLegacyConfigurationDecodesWithDefaultAppsAndSystemLanguage() throws {
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(MenuConfiguration.default)
            ) as? [String: Any]
        )
        object.removeValue(forKey: "openWithApps")
        object.removeValue(forKey: "language")
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(MenuConfiguration.self, from: legacyData)
        XCTAssertEqual(decoded.openWithApps.map(\.name), ["终端", "Visual Studio Code"])
        XCTAssertEqual(decoded.language, .system)
    }

    func testCompleteEnglishLocalizationAndCustomNames() throws {
        XCTAssertEqual(
            Localizer.resolvedLanguage(.system, preferredLanguages: ["fr-FR"]),
            .english
        )
        XCTAssertEqual(
            Localizer.resolvedLanguage(.system, preferredLanguages: ["zh-Hant-HK"]),
            .traditionalChinese
        )
        XCTAssertEqual(
            Localizer.resolvedLanguage(.system, preferredLanguages: ["zh-Hans-CN"]),
            .simplifiedChinese
        )

        for action in FinderMenuAction.allCases {
            XCTAssertTrue(
                Localizer.hasTranslation(action.title, language: .english),
                "Missing English action title: \(action.title)"
            )
            XCTAssertTrue(
                Localizer.hasTranslation(action.title, language: .traditionalChinese),
                "Missing Traditional Chinese action title: \(action.title)"
            )
            let englishTitle = Localizer.text(action.title, language: .english)
            XCTAssertFalse(
                englishTitle.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) },
                "English action title contains Chinese: \(action.title)"
            )
        }

        let dynamicKeys = [
            "新建 %@", "用 %@ 打开", "新建%@文件", "未命名",
            "删除模板“%@”？", "关闭永久删除确认？", "打开设置", "退出",
            "将永久删除 1 个项目，此操作不经过废纸篓且无法撤销。",
            "将永久删除 %@ 个项目，此操作不经过废纸篓且无法撤销。",
            "文件名不能为空，也不能包含“/”。", "文件名过长。", "文件后缀无效。",
            "模板已不存在。", "没有启用的新建模板。", "通过窗口创建新文件",
            "模板“%@”已添加。", "%@：%@", "选择移动目标文件夹",
            "选择复制目标文件夹", "剪贴板中没有可粘贴的文件。",
            "文件信息与摘要", "路径：%@", "大小：%@", "修改：%@", "读取失败：%@",
            "找不到应用：%@", "隐藏全部项目", "显示全部项目",
            "将修改“%@”第一层的 %@ 个项目，是否继续？",
            "所选内容包含受保护路径。", "不能解散受保护目录。",
            "拒绝删除根目录、主目录或系统保护路径。",
            "永久删除目标在确认期间发生变化，已取消操作。",
            "永久删除目标在确认期间已被替换，已取消操作。",
            "无法打开永久删除目标目录（POSIX 错误 %@）。",
            "永久删除目标在提交期间已被替换，已取消操作。",
            "无法安全隔离永久删除目标（POSIX 错误 %@）。",
            "无法生成唯一的永久删除隔离路径。",
            "永久删除目标身份复核失败，已恢复原路径并取消操作。",
            "永久删除目标身份复核失败，且无法恢复原路径；项目保留在 %@（POSIX 错误 %@）。",
            "无法删除已隔离的永久删除目标；剩余项目位于 %@（POSIX 错误 %@）。",
            "无法删除已隔离的永久删除目标；剩余项目位于 %@：%@",
            "Finder 自动化失败：%@", "无法读取图片。",
            "当前 macOS 不支持编码 %@。", "无法创建输出图片。", "图片编码失败。",
            "操作失败", "系统错误（%@，代码 %@）。",
        ]
        for key in dynamicKeys {
            XCTAssertTrue(Localizer.hasTranslation(key, language: .english), key)
            XCTAssertTrue(Localizer.hasTranslation(key, language: .traditionalChinese), key)
        }

        var configuration = MenuConfiguration.default
        configuration.language = .english
        let copyPathIndex = try XCTUnwrap(configuration.actionPreferences.firstIndex {
            $0.action == .copyPath
        })
        configuration.actionPreferences[copyPathIndex].customName = "  用户 %@ 名称  "
        XCTAssertEqual(configuration.title(for: .copyPath), "  用户 %@ 名称  ")
        configuration.actionPreferences[copyPathIndex].customName = "   \n"
        XCTAssertEqual(configuration.title(for: .copyPath), "Copy Path")

        XCTAssertEqual(
            Localizer.format("用 %@ 打开", language: .english, "Tool %@ 100%"),
            "Open with Tool %@ 100%"
        )
        XCTAssertEqual(
            OperationFailure("当前 macOS 不支持编码 %@。", arguments: ["WEBP"])
                .message(language: .english),
            "This version of macOS does not support WEBP encoding."
        )
    }

    func testBuiltinShortcutNamesLocalizeWithoutChangingUserNames() {
        let downloads = MenuConfiguration.default.commonDirectories[0]
        XCTAssertEqual(downloads.displayName(language: .english), "Downloads")
        var renamedDirectory = downloads
        renamedDirectory.name = "我的下载"
        XCTAssertEqual(renamedDirectory.displayName(language: .english), "我的下载")

        let terminal = MenuConfiguration.defaultOpenWithApps[0]
        XCTAssertEqual(terminal.displayName(language: .english), "Terminal")
        XCTAssertTrue(terminal.usesDefaultTerminalName)
        var renamedTerminal = terminal
        renamedTerminal.name = "我的终端"
        XCTAssertEqual(renamedTerminal.displayName(language: .english), "我的终端")
        XCTAssertFalse(renamedTerminal.usesDefaultTerminalName)
    }

    func testTemplateDeduplication() throws {
        var configuration = MenuConfiguration.default
        let older = NewFileTemplate(name: "我的word", fileExtension: "docx", kind: .custom, storedFilename: "a.docx")
        let newer = NewFileTemplate(name: "我的Word", fileExtension: "docx", kind: .custom, storedFilename: "b.docx")
        configuration.templates.append(contentsOf: [older, newer, older])
        configuration.deduplicateTemplates()
        let duplicates = configuration.templates.filter { $0.fileExtension == "docx" }
        XCTAssertEqual(duplicates.count, 1)
        XCTAssertEqual(duplicates.first?.storedFilename, "a.docx")
    }

    @MainActor
    func testRegisterTemplateReplacesSameName() throws {
        let templateStorage = root.appendingPathComponent("dedup-templates", isDirectory: true)
        let coordinator = makeCoordinator(templateStorage: templateStorage)
        let source = root.appendingPathComponent("dup.docx")
        try Data("v1".utf8).write(to: source)
        let baseline = coordinator.configuration.templates.count
        try coordinator.registerTemplate(from: source, name: "我的word")
        try Data("v2".utf8).write(to: source)
        let replaced = try coordinator.registerTemplate(from: source, name: "我的word")
        XCTAssertEqual(coordinator.configuration.templates.count, baseline + 1)
        let stored = try XCTUnwrap(replaced.storedFilename)
        XCTAssertEqual(
            try Data(contentsOf: templateStorage.appendingPathComponent(stored)),
            Data("v2".utf8)
        )
    }

    @MainActor
    func testCustomTemplateAndKnownHashes() throws {
        let templateStorage = root.appendingPathComponent("templates", isDirectory: true)
        let coordinator = makeCoordinator(templateStorage: templateStorage)
        var configuration = MenuConfiguration.default
        configuration.language = .simplifiedChinese
        coordinator.updateConfiguration(configuration)
        let source = root.appendingPathComponent("sample.docx")
        try Data("abc".utf8).write(to: source)
        let template = try coordinator.registerTemplate(from: source, name: "我的 Word")
        let outputDirectory = root.appendingPathComponent("output", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        coordinator.create(templateID: template.id, in: outputDirectory)
        XCTAssertEqual(
            try Data(contentsOf: outputDirectory.appendingPathComponent("未命名.docx")),
            Data("abc".utf8)
        )

        let hashes = try coordinator.fileHashes(source)
        XCTAssertEqual(hashes.md5, "900150983cd24fb0d6963f7d28e17f72")
        XCTAssertEqual(hashes.sha1, "a9993e364706816aba3e25717850c26c9cd0d89d")
        XCTAssertEqual(hashes.sha256, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @MainActor
    func testBuiltinTemplateCreation() throws {
        let coordinator = makeCoordinator()
        var configuration = MenuConfiguration.default
        configuration.language = .simplifiedChinese
        coordinator.updateConfiguration(configuration)
        let template = try XCTUnwrap(configuration.templates.first { $0.kind == .xml })
        coordinator.create(templateID: template.id, in: root)
        let output = root.appendingPathComponent("未命名.xml")
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        XCTAssertTrue(try String(contentsOf: output, encoding: .utf8).hasPrefix("<?xml"))
    }

    @MainActor
    func testEnglishTemplateCreationUsesLocalizedUntitledName() throws {
        let coordinator = makeCoordinator()
        var configuration = MenuConfiguration.default
        configuration.language = .english
        coordinator.updateConfiguration(configuration)
        let template = try XCTUnwrap(configuration.templates.first { $0.kind == .xml })
        coordinator.create(templateID: template.id, in: root)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("Untitled.xml").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("未命名.xml").path
        ))
    }

    @MainActor
    func testCopyAndMoveUseConflictSafeNames() throws {
        let coordinator = makeCoordinator()
        let source = root.appendingPathComponent("source.txt")
        try Data("one".utf8).write(to: source)
        let destination = root.appendingPathComponent("destination", isDirectory: true)
        coordinator.transfer([source], to: destination, move: false)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: destination.appendingPathComponent("source.txt").path
        ))
        coordinator.transfer([source], to: destination, move: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: destination.appendingPathComponent("source 2.txt").path
        ))
    }

    @MainActor
    func testAliasCreationInTemporaryDirectory() throws {
        let coordinator = makeCoordinator()
        let source = root.appendingPathComponent("source.txt")
        try Data("alias".utf8).write(to: source)
        let aliases = root.appendingPathComponent("aliases", isDirectory: true)
        try FileManager.default.createDirectory(at: aliases, withIntermediateDirectories: true)
        coordinator.createAliases(for: [source], in: aliases)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: aliases.appendingPathComponent("source.txt.alias").path
        ))
    }

    @MainActor
    func testHiddenAndPermissionOperationsInTemporaryDirectory() throws {
        let coordinator = makeCoordinator()
        let file = root.appendingPathComponent("item.txt")
        FileManager.default.createFile(atPath: file.path, contents: Data())
        coordinator.setHidden([file], hidden: true)
        XCTAssertEqual(try file.resourceValues(forKeys: [.isHiddenKey]).isHidden, true)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o400)],
            ofItemAtPath: file.path
        )
        coordinator.grantWritePermission([file])
        let value = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        )
        XCTAssertNotEqual(value.intValue & 0o200, 0)
    }

    @MainActor
    func testCutHideRestoresAndPasteMakesDestinationVisible() throws {
        let coordinator = makeCoordinator()
        var configuration = MenuConfiguration.default
        configuration.hideCutItems = true
        coordinator.updateConfiguration(configuration)
        let first = root.appendingPathComponent("first.txt")
        let second = root.appendingPathComponent("second.txt")
        try Data().write(to: first)
        try Data().write(to: second)

        coordinator.cut([first])
        XCTAssertEqual(
            try URL(fileURLWithPath: first.path).resourceValues(forKeys: [.isHiddenKey]).isHidden,
            true
        )
        coordinator.cut([second])
        XCTAssertEqual(
            try URL(fileURLWithPath: first.path).resourceValues(forKeys: [.isHiddenKey]).isHidden,
            false
        )
        XCTAssertEqual(
            try URL(fileURLWithPath: second.path).resourceValues(forKeys: [.isHiddenKey]).isHidden,
            true
        )

        let destination = root.appendingPathComponent("destination", isDirectory: true)
        coordinator.paste(into: destination)
        let pasted = destination.appendingPathComponent("second.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: pasted.path))
        XCTAssertEqual(
            try URL(fileURLWithPath: pasted.path).resourceValues(forKeys: [.isHiddenKey]).isHidden,
            false
        )
    }

    /// Finder 序列化菜单时会丢失 identifier，动作分发依赖 tag → 命令表，
    /// 这里验证每个可点击菜单项的 tag 都能解析回对应命令。
    @MainActor
    func testMenuItemTagsResolveToCommands() throws {
        let target = MenuTarget()
        let builder = FinderMenuBuilder(
            configuration: .default,
            target: target,
            selector: #selector(MenuTarget.perform(_:))
        )
        let file = root.appendingPathComponent("tagfile.txt")
        FileManager.default.createFile(atPath: file.path, contents: Data())
        let menu = builder.itemsMenu(urls: [file])

        var stack = menu.items
        var actionableCount = 0
        while let item = stack.popLast() {
            // 带子菜单的父项会被 AppKit 自动赋予 submenuAction:，不经过我们的分发。
            if let submenu = item.submenu {
                stack.append(contentsOf: submenu.items)
                continue
            }
            guard item.action != nil else { continue }
            actionableCount += 1
            XCTAssertNotNil(builder.command(forTag: item.tag), "菜单项「\(item.title)」的 tag 无法解析")
        }
        XCTAssertGreaterThan(actionableCount, 0)
        let first = try XCTUnwrap(menu.items.first)
        XCTAssertEqual(builder.command(forTag: first.tag)?.action, .copyPath)
    }

    @MainActor
    func testMenuCommandsBindBuildContext() throws {
        let target = MenuTarget()
        let selected = [
            root.appendingPathComponent("first.txt"),
            root.appendingPathComponent("second.txt"),
        ]
        selected.forEach { FileManager.default.createFile(atPath: $0.path, contents: Data()) }
        let context = MenuInvocationContext(
            selectedURLs: selected,
            targetDirectory: root
        )
        let builder = FinderMenuBuilder(
            configuration: .default,
            target: target,
            selector: #selector(MenuTarget.perform(_:))
        )
        _ = builder.itemsMenu(urls: selected)

        let invocations = MenuInvocation.bind(builder.commands, to: context)
        XCTAssertEqual(invocations.count, builder.commands.count)
        XCTAssertTrue(invocations.allSatisfy { $0.context == context })
        XCTAssertEqual(
            invocations.map(\.command.action),
            builder.commands.map(\.action)
        )
    }

    /// Finder 通过 XPC 在非主线程序列化菜单图标（TIFF），
    /// 图标必须是已渲染好的位图，不能持有主线程隔离的绘制闭包。
    @MainActor
    func testMenuIconsCanBeSerializedOffMainThread() {
        final class ImageBox: @unchecked Sendable {
            let images: [NSImage]
            init(_ images: [NSImage]) { self.images = images }
        }

        var images = FinderMenuAction.allCases.map { OriginalMenuIcon.image(for: $0) }
        images.append(OriginalMenuIcon.image(for: NewFileTemplate(name: "测试", fileExtension: "txt", kind: .text)))
        let box = ImageBox(images)
        let expectation = expectation(description: "serialize icons off main thread")
        DispatchQueue.global().async {
            for image in box.images {
                XCTAssertNotNil(image.tiffRepresentation)
            }
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 10)
    }

    func testProtectedPaths() {
        XCTAssertTrue(PathSafety.isProtected(URL(fileURLWithPath: "/")))
        XCTAssertTrue(PathSafety.isProtected(FileManager.default.homeDirectoryForCurrentUser))
        XCTAssertFalse(PathSafety.isProtected(root))
    }

    @MainActor
    func testMenuHierarchyAndDangerousDefaults() {
        let target = MenuTarget()
        var configuration = MenuConfiguration.default
        configuration.language = .simplifiedChinese
        let builder = FinderMenuBuilder(
            configuration: configuration,
            target: target,
            selector: #selector(MenuTarget.perform(_:))
        )
        let container = builder.containerMenu(hasCutItems: false)
        XCTAssertNotNil(container.items.first(where: { $0.title == "新建文件" })?.submenu)
        XCTAssertFalse(container.items.contains(where: { $0.title == "在此打开" }))
        XCTAssertTrue(container.items.contains(where: { $0.title == "打开终端" }))
        XCTAssertFalse(container.items.contains(where: { $0.title == "永久删除…" }))

        let file = root.appendingPathComponent("file.txt")
        FileManager.default.createFile(atPath: file.path, contents: Data())
        let items = builder.itemsMenu(urls: [file])
        XCTAssertEqual(items.items.first?.title, "复制路径")
        XCTAssertNotNil(items.items.first(where: { $0.title == "文件操作" })?.submenu)
        XCTAssertFalse(items.items.contains(where: { $0.title == "永久删除…" }))
    }

    @MainActor
    func testEnglishMenuIncludesLocalizedDynamicTitles() throws {
        let fakeApp = root.appendingPathComponent("Preview.app", isDirectory: true)
        try FileManager.default.createDirectory(at: fakeApp, withIntermediateDirectories: true)

        var configuration = MenuConfiguration.default
        configuration.language = .english
        configuration.mergeOpenWithApps = false
        configuration.enablePermanentDelete = true
        configuration.openWithApps = [
            MenuConfiguration.defaultOpenWithApps[0],
            AppShortcut(
                name: "Preview",
                appPath: fakeApp.path,
                bundleIdentifier: "local.SuperRightClickTests.Preview"
            ),
        ]
        let target = MenuTarget()
        let builder = FinderMenuBuilder(
            configuration: configuration,
            target: target,
            selector: #selector(MenuTarget.perform(_:))
        )
        let menu = builder.containerMenu(hasCutItems: false)

        func flattenedTitles(_ menu: NSMenu) -> [String] {
            menu.items.flatMap { item in
                [item.title] + (item.submenu.map(flattenedTitles) ?? [])
            }
        }
        let titles = flattenedTitles(menu)
        XCTAssertTrue(titles.contains("New TXT"))
        XCTAssertTrue(titles.contains("Open Terminal"))
        XCTAssertTrue(titles.contains("Open with Preview"))
        XCTAssertFalse(titles.contains { title in
            title.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
        })

        let file = root.appendingPathComponent("english-menu.txt")
        try Data().write(to: file)
        let itemTitles = flattenedTitles(builder.itemsMenu(urls: [file]))
        XCTAssertTrue(itemTitles.contains("Copy Path"))
        XCTAssertTrue(itemTitles.contains("File Actions"))
        XCTAssertEqual(itemTitles.last, "Delete Permanently…")
        XCTAssertFalse(itemTitles.contains { title in
            title.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
        })
    }

    @MainActor
    func testMenuPersonalizationAndImageContext() throws {
        var configuration = MenuConfiguration.default
        configuration.language = .simplifiedChinese
        if let index = configuration.actionPreferences.firstIndex(where: {
            $0.action == .copyPath
        }) {
            configuration.actionPreferences[index].isEnabled = false
        }
        if let index = configuration.actionPreferences.firstIndex(where: {
            $0.action == .copyName
        }) {
            configuration.actionPreferences[index].customName = "复制名称（自定义）"
            let preference = configuration.actionPreferences.remove(at: index)
            configuration.actionPreferences.insert(preference, at: 0)
        }
        configuration.showMenuIcons = false
        configuration.enablePermanentDelete = true
        if let index = configuration.actionPreferences.firstIndex(where: {
            $0.action == .permanentDelete
        }) {
            let preference = configuration.actionPreferences.remove(at: index)
            configuration.actionPreferences.insert(preference, at: 0)
        }
        if let index = configuration.actionPreferences.firstIndex(where: {
            $0.action == .convertPNG
        }) {
            let preference = configuration.actionPreferences.remove(at: index)
            configuration.actionPreferences.insert(preference, at: 0)
        }
        let target = MenuTarget()
        let builder = FinderMenuBuilder(
            configuration: configuration,
            target: target,
            selector: #selector(MenuTarget.perform(_:))
        )
        let imageURL = root.appendingPathComponent("menu-image.png")
        let image = NSImage(size: NSSize(width: 2, height: 2))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 2, height: 2).fill()
        image.unlockFocus()
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: imageURL)

        let menu = builder.itemsMenu(urls: [imageURL])
        XCTAssertFalse(menu.items.contains(where: { $0.title == "复制路径" }))
        XCTAssertTrue(menu.items.contains(where: { $0.title == "复制名称（自定义）" }))
        XCTAssertNotNil(menu.items.first(where: { $0.title == "图片转换" })?.submenu)
        XCTAssertTrue(menu.items.allSatisfy { $0.image == nil })
        XCTAssertEqual(menu.items.last?.title, "永久删除…")
        XCTAssertEqual(
            menu.items.first(where: { $0.title == "图片转换" })?.submenu?.items.first?.title,
            "转换为 PNG"
        )
    }

    func testDirectoryRenameAndActionOverridesRoundTrip() throws {
        var configuration = MenuConfiguration.default
        configuration.commonDirectories[0].name = "我的下载"
        configuration.actionPreferences[0].customName = "新建文档"
        configuration.actionPreferences[0].isEnabled = false
        ConfigurationStore.save(configuration, defaults: isolatedDefaults, publish: false)
        let loaded = ConfigurationStore.load(defaults: isolatedDefaults)
        XCTAssertEqual(loaded.commonDirectories[0].name, "我的下载")
        XCTAssertEqual(loaded.actionPreferences[0].customName, "新建文档")
        XCTAssertFalse(loaded.actionPreferences[0].isEnabled)
    }

    func testExclusionMatchesDescendants() {
        var configuration = MenuConfiguration.default
        configuration.excludedPaths = [root.path]
        XCTAssertTrue(configuration.isExcluded(root))
        XCTAssertTrue(configuration.isExcluded(root.appendingPathComponent("nested/file.txt")))
        XCTAssertFalse(configuration.isExcluded(root.deletingLastPathComponent()))
    }

    @MainActor
    func testPNGToJPGConversionAndUniqueName() throws {
        let source = root.appendingPathComponent("sample.png")
        let image = NSImage(size: NSSize(width: 8, height: 8))
        image.lockFocus()
        NSColor.systemRed.setFill()
        NSRect(x: 0, y: 0, width: 8, height: 8).fill()
        image.unlockFocus()
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: source)

        let coordinator = makeCoordinator()
        let first = try coordinator.convertImage(source, to: .jpg)
        let second = try coordinator.convertImage(source, to: .jpg)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
        XCTAssertEqual(first.lastPathComponent, "sample.jpg")
        XCTAssertEqual(second.lastPathComponent, "sample 2.jpg")
        XCTAssertEqual(
            CGImageSourceGetType(try XCTUnwrap(CGImageSourceCreateWithURL(first as CFURL, nil))) as String?,
            UTType.jpeg.identifier
        )
    }

    @MainActor
    func testImageConversionSkipsDanglingSymlinkOutput() throws {
        let source = root.appendingPathComponent("dangling.png")
        let image = NSImage(size: NSSize(width: 8, height: 8))
        image.lockFocus()
        NSColor.systemGreen.setFill()
        NSRect(x: 0, y: 0, width: 8, height: 8).fill()
        image.unlockFocus()
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: source)

        let occupied = root.appendingPathComponent("dangling.jpg")
        let missingTarget = root.appendingPathComponent("missing-target.jpg")
        try FileManager.default.createSymbolicLink(at: occupied, withDestinationURL: missingTarget)
        XCTAssertFalse(FileManager.default.fileExists(atPath: occupied.path))

        let output = try makeCoordinator().convertImage(source, to: .jpg)
        XCTAssertEqual(output.lastPathComponent, "dangling 2.jpg")
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: occupied.path),
            missingTarget.path
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.path).filter {
            $0.hasPrefix(".superrightclick-conversion-")
        }
        XCTAssertTrue(leftovers.isEmpty)
    }

    func testConcurrentImageConversionsCommitUniqueOutputsAtomically() throws {
        let source = root.appendingPathComponent("parallel.png")
        let image = NSImage(size: NSSize(width: 16, height: 16))
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: 16, height: 16).fill()
        image.unlockFocus()
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: source)

        let conversionCount = 8
        let results = ConcurrentImageResults()
        DispatchQueue.concurrentPerform(iterations: conversionCount) { _ in
            do {
                results.record(.success(try FeatureCoordinator.convertImage(
                    source,
                    to: .jpg,
                    quality: 0.85,
                    backgroundHex: "#FFFFFF",
                    fileManager: .default
                )))
            } catch {
                results.record(.failure(error))
            }
        }

        let snapshot = results.snapshot()
        XCTAssertEqual(snapshot.errors, [])
        XCTAssertEqual(snapshot.urls.count, conversionCount)
        XCTAssertEqual(Set(snapshot.urls.map(\.path)).count, conversionCount)
        let expectedNames = Set((1...conversionCount).map { index in
            index == 1 ? "parallel.jpg" : "parallel \(index).jpg"
        })
        XCTAssertEqual(Set(snapshot.urls.map(\.lastPathComponent)), expectedNames)
        for output in snapshot.urls {
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
            XCTAssertEqual(CGImageSourceGetType(source) as String?, UTType.jpeg.identifier)
        }
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.path).filter {
            $0.hasPrefix(".superrightclick-conversion-")
        }
        XCTAssertTrue(leftovers.isEmpty)
    }

    @MainActor
    func testPermanentDeleteRequiresExplicitApprovalByDefault() async throws {
        let target = root.appendingPathComponent("approval-required.txt")
        try Data("content".utf8).write(to: target)
        let confirmation = PermanentDeleteConfirmationStub(approved: false)
        var isolationCount = 0
        let coordinator = makeCoordinator(
            requiresConfirmation: true,
            permanentDeleteConfirmation: confirmation.confirm,
            permanentDeletionWillIsolate: { _ in isolationCount += 1 }
        )

        await coordinator.permanentlyDelete([target])
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
        XCTAssertEqual(confirmation.requestedURLs, [[target]])
        XCTAssertEqual(isolationCount, 0)

        confirmation.approved = true
        await coordinator.permanentlyDelete([target])
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        XCTAssertEqual(confirmation.requestedURLs, [[target], [target]])
        XCTAssertEqual(isolationCount, 1)
    }

    @MainActor
    func testPermanentDeleteSkipsBridgeOnlyForStableDisabledPreference() async throws {
        let target = root.appendingPathComponent("confirmation-disabled.txt")
        try Data("content".utf8).write(to: target)
        let safetyStore = SafetyPreferencesStore(
            directoryURL: root.appendingPathComponent("disabled-safety", isDirectory: true)
        )
        _ = try safetyStore.save(confirmBeforePermanentDelete: false)
        let confirmation = PermanentDeleteConfirmationStub(approved: false)
        let coordinator = makeCoordinator(
            requiresConfirmation: true,
            safetyPreferencesStore: safetyStore,
            permanentDeleteConfirmation: confirmation.confirm
        )

        await coordinator.permanentlyDelete([target])
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        XCTAssertTrue(confirmation.requestedURLs.isEmpty)
    }

    @MainActor
    func testPermanentDeleteDoesNotDeleteReplacementInsertedBeforeIsolation() async throws {
        let target = root.appendingPathComponent("race-target.txt")
        let originalBackup = root.appendingPathComponent("race-original-backup.txt")
        try Data("original".utf8).write(to: target)

        var swapError: Error?
        var didSwap = false
        var presentedErrors: [String] = []
        let coordinator = makeCoordinator(
            permanentDeletionWillIsolate: { url in
                guard !didSwap else { return }
                didSwap = true
                do {
                    try FileManager.default.moveItem(at: url, to: originalBackup)
                    try Data("replacement".utf8).write(to: url)
                } catch {
                    swapError = error
                }
            },
            errorPresentation: { presentedErrors.append($0) }
        )
        var configuration = MenuConfiguration.default
        configuration.language = .english
        coordinator.updateConfiguration(configuration)

        await coordinator.permanentlyDelete([target])

        XCTAssertNil(swapError)
        XCTAssertEqual(try Data(contentsOf: target), Data("replacement".utf8))
        XCTAssertEqual(try Data(contentsOf: originalBackup), Data("original".utf8))
        XCTAssertEqual(presentedErrors.count, 1)
        XCTAssertTrue(presentedErrors[0].contains("identity verification"))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains {
            $0.hasPrefix(".superrightclick-delete-")
        })
    }

    @MainActor
    func testPermanentDeleteHandlesDirectoriesAndSymlinksWithoutFollowingThem() async throws {
        let outside = root.appendingPathComponent("outside.txt")
        try Data("keep".utf8).write(to: outside)

        let directory = root.appendingPathComponent("delete-directory", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("child".utf8).write(to: directory.appendingPathComponent("child.txt"))
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent("outside-link"),
            withDestinationURL: outside
        )
        await makeCoordinator().permanentlyDelete([directory])
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertEqual(try Data(contentsOf: outside), Data("keep".utf8))

        let link = root.appendingPathComponent("delete-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        await makeCoordinator().permanentlyDelete([link])
        var linkStatus = stat()
        XCTAssertNotEqual(link.path.withCString { lstat($0, &linkStatus) }, 0)
        XCTAssertEqual(try Data(contentsOf: outside), Data("keep".utf8))
    }

    @MainActor
    func testDissolveAndPermanentDeleteAreConfinedToTemporaryDirectory() async throws {
        let coordinator = makeCoordinator()
        let parent = root.appendingPathComponent("parent", isDirectory: true)
        let folder = parent.appendingPathComponent("folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let child = folder.appendingPathComponent("child.txt")
        try Data("content".utf8).write(to: child)
        coordinator.dissolve(folder)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        let moved = parent.appendingPathComponent("child.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: moved.path))

        await coordinator.permanentlyDelete([moved])
        XCTAssertFalse(FileManager.default.fileExists(atPath: moved.path))
    }

    @MainActor
    func testBulkVisibilityOnlyTouchesFirstDirectoryLevel() throws {
        let coordinator = makeCoordinator()
        let direct = root.appendingPathComponent("direct.txt")
        let nestedDirectory = root.appendingPathComponent("nested", isDirectory: true)
        let nested = nestedDirectory.appendingPathComponent("nested.txt")
        try FileManager.default.createDirectory(at: nestedDirectory, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: direct.path, contents: Data())
        FileManager.default.createFile(atPath: nested.path, contents: Data())
        coordinator.setAllHidden(in: root, hidden: true)
        XCTAssertEqual(try direct.resourceValues(forKeys: [.isHiddenKey]).isHidden, true)
        XCTAssertNotEqual(try nested.resourceValues(forKeys: [.isHiddenKey]).isHidden, true)
    }
}
