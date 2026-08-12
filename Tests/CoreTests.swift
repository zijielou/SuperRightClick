import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest

private final class MenuTarget: NSObject {
    @objc func perform(_ sender: NSMenuItem) {}
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

    /// 一律使用隔离的 UserDefaults 且不广播，避免测试数据污染真实配置。
    @MainActor
    private func makeCoordinator(templateStorage: URL? = nil) -> FeatureCoordinator {
        FeatureCoordinator(
            requiresConfirmation: false,
            templateStorageURL: templateStorage,
            configurationDefaults: isolatedDefaults,
            publishChanges: false
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
        ConfigurationStore.save(configuration, defaults: defaults, publish: false)
        XCTAssertEqual(ConfigurationStore.load(defaults: defaults), configuration)
    }

    /// 旧版本存储的配置没有 openWithApps 字段，解码时必须回填默认应用而不是解码失败。
    func testLegacyConfigurationDecodesWithDefaultApps() throws {
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(MenuConfiguration.default)
            ) as? [String: Any]
        )
        object.removeValue(forKey: "openWithApps")
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(MenuConfiguration.self, from: legacyData)
        XCTAssertEqual(decoded.openWithApps.map(\.name), ["终端", "Visual Studio Code"])
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
        let configuration = MenuConfiguration.default
        coordinator.updateConfiguration(configuration)
        let template = try XCTUnwrap(configuration.templates.first { $0.kind == .xml })
        coordinator.create(templateID: template.id, in: root)
        let output = root.appendingPathComponent("未命名.xml")
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        XCTAssertTrue(try String(contentsOf: output, encoding: .utf8).hasPrefix("<?xml"))
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
        let builder = FinderMenuBuilder(
            configuration: .default,
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
    func testMenuPersonalizationAndImageContext() throws {
        var configuration = MenuConfiguration.default
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
    func testDissolveAndPermanentDeleteAreConfinedToTemporaryDirectory() throws {
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

        coordinator.permanentlyDelete([moved])
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
