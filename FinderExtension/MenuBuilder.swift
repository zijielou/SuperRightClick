@preconcurrency import AppKit
import Foundation
import UniformTypeIdentifiers

struct MenuCommand {
    let action: FinderMenuAction
    let payload: String?

    init(action: FinderMenuAction, payload: String? = nil) {
        self.action = action
        self.payload = payload
    }
}

/// 菜单构建时捕获的 Finder 上下文。点击发生后不再重新查询 Finder，
/// 避免菜单显示对象与最终执行对象不一致。
struct MenuInvocationContext: Equatable {
    let selectedURLs: [URL]
    let targetDirectory: URL?
}

struct MenuInvocation {
    let command: MenuCommand
    let context: MenuInvocationContext

    static func bind(
        _ commands: [MenuCommand],
        to context: MenuInvocationContext
    ) -> [MenuInvocation] {
        commands.map { MenuInvocation(command: $0, context: context) }
    }
}

@MainActor
final class FinderMenuBuilder {
    private let configuration: MenuConfiguration
    private weak var target: AnyObject?
    private let selector: Selector
    private let firstTag: Int

    /// Finder 通过 XPC 序列化菜单时只保留 title、image、tag 等字段，
    /// identifier 会丢失，因此用 tag（1 起始）索引这张命令表来分发点击。
    private(set) var commands: [MenuCommand] = []
    private static var applicationIconCache: [String: NSImage] = [:]

    /// 在一次菜单构建内只解析一次应用位置和安装状态，避免每个分组重复
    /// 调用 Launch Services 与文件系统。
    private lazy var availableApps: [(shortcut: AppShortcut, url: URL)] = {
        configuration.openWithApps.compactMap { shortcut in
            guard shortcut.isEnabled else { return nil }
            let url = shortcut.appURL
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return (shortcut, url)
        }
    }()

    init(
        configuration: MenuConfiguration,
        target: AnyObject,
        selector: Selector,
        firstTag: Int = 1
    ) {
        self.configuration = configuration
        self.target = target
        self.selector = selector
        self.firstTag = firstTag
    }

    func command(forTag tag: Int) -> MenuCommand? {
        let index = tag - firstTag
        guard commands.indices.contains(index) else { return nil }
        return commands[index]
    }

    func containerMenu(hasCutItems: Bool) -> NSMenu {
        let menu = NSMenu(title: "SuperRightClick")
        addNewFileItems(to: menu)
        addTerminalItems(to: menu)
        addOpenWithApps(to: menu)
        addCommonDirectories(to: menu, includeAdd: true)
        if hasCutItems { menu.addItem(item(.paste)) }
        menu.addItem(item(.copyCurrentDirectoryPath))
        if configuration.enableBulkVisibility {
            menu.addItem(item(.hideAll))
            menu.addItem(item(.showAll))
        }
        finish(menu)
        return menu
    }

    func itemsMenu(urls: [URL]) -> NSMenu {
        let menu = NSMenu(title: "SuperRightClick")
        let allDirectories = !urls.isEmpty && urls.allSatisfy(isDirectory)
        let singleDirectory = urls.count == 1 && isDirectory(urls[0])

        menu.addItem(item(.copyPath))
        menu.addItem(item(.copyName))
        menu.addItem(item(.cut))
        menu.addItem(destinationMenu(action: .moveToDirectory))
        menu.addItem(destinationMenu(action: .copyToDirectory))

        let operations = NSMenu(title: localized("文件操作"))
        operations.addItem(item(.fileInfo))
        operations.addItem(item(.createDesktopAlias))
        if !allDirectories { operations.addItem(item(.createSameNameFolder)) }
        operations.addItem(item(.hideSelected))
        operations.addItem(item(.showSelected))
        if urls.count == 1, !allDirectories { operations.addItem(item(.importTemplate)) }
        if configuration.enablePermissionChanges {
            operations.addItem(item(.grantWritePermission))
        }
        if singleDirectory {
            operations.addItem(item(.setFolderIcon))
            if configuration.enableDissolveFolder { operations.addItem(item(.dissolveFolder)) }
        }
        if configuration.mergeFileOperations {
            menu.addItem(wrapping(
                title: localized("文件操作"),
                submenu: operations,
                icon: .fileInfo
            ))
        } else {
            for operation in operations.items {
                operations.removeItem(operation)
                menu.addItem(operation)
            }
        }

        // 用文件打开终端不常见：终端只在选中单个文件夹时以一级菜单项出现。
        addOpenWithApps(to: menu)

        if singleDirectory {
            addTerminalItems(to: menu)
            addCommonDirectories(to: menu, includeAdd: true)
        }

        if !urls.isEmpty && urls.allSatisfy(isImage) {
            addImageOperations(to: menu)
        }

        if configuration.enablePermanentDelete {
            menu.addItem(item(.permanentDelete))
        }
        finish(menu)
        return menu
    }

    private func addNewFileItems(to menu: NSMenu) {
        guard configuration.isActionEnabled(.createTemplate) else { return }
        let enabled = configuration.templates.filter(\.isEnabled)
        guard !enabled.isEmpty else { return }
        for template in enabled where template.showInMainMenu {
            let templateItem = item(
                .createTemplate,
                title: formatted("新建 %@", template.name),
                payload: template.id.uuidString
            )
            templateItem.image = templateImage(for: template)
            menu.addItem(templateItem)
        }
        let submenu = NSMenu(title: configuration.title(for: .createTemplate))
        for template in enabled where !template.showInMainMenu {
            let templateItem = item(
                .createTemplate,
                title: template.name,
                payload: template.id.uuidString
            )
            templateItem.image = templateImage(for: template)
            submenu.addItem(templateItem)
        }
        submenu.addItem(item(.createNamedFile))
        menu.addItem(wrapping(
            title: configuration.title(for: .createTemplate),
            submenu: submenu,
            icon: .createTemplate
        ))
    }

    private func addTerminalItems(to menu: NSMenu) {
        for entry in availableApps where entry.shortcut.isTerminalApp {
            let app = entry.shortcut
            let displayName = app.displayName(language: configuration.language)
            let title = app.usesDefaultTerminalName
                ? localized("打开终端")
                : formatted("用 %@ 打开", displayName)
            let menuItem = item(.openWithApp, title: title, payload: app.id.uuidString)
            menuItem.image = applicationImage(at: entry.url)
            menu.addItem(menuItem)
        }
    }

    private func addOpenWithApps(to menu: NSMenu) {
        let apps = availableApps.filter { !$0.shortcut.isTerminalApp }
        guard !apps.isEmpty else { return }
        if configuration.mergeOpenWithApps {
            let submenu = NSMenu(title: configuration.title(for: .openWithApp))
            for entry in apps {
                let app = entry.shortcut
                let menuItem = item(
                    .openWithApp,
                    title: app.displayName(language: configuration.language),
                    payload: app.id.uuidString
                )
                menuItem.image = applicationImage(at: entry.url)
                submenu.addItem(menuItem)
            }
            menu.addItem(wrapping(
                title: configuration.title(for: .openWithApp),
                submenu: submenu,
                icon: .openWithApp
            ))
        } else {
            for entry in apps {
                let app = entry.shortcut
                let menuItem = item(
                    .openWithApp,
                    title: formatted(
                        "用 %@ 打开",
                        app.displayName(language: configuration.language)
                    ),
                    payload: app.id.uuidString
                )
                menuItem.image = applicationImage(at: entry.url)
                menu.addItem(menuItem)
            }
        }
    }

    private func addImageOperations(to menu: NSMenu) {
        let formats: [ImageConversionFormat] = [.heic, .jpg, .png]
        if configuration.mergeImageOperations {
            let submenu = NSMenu(title: localized("图片转换"))
            for format in formats {
                submenu.addItem(item(format.action))
            }
            menu.addItem(wrapping(
                title: localized("图片转换"),
                submenu: submenu,
                icon: .convertPNG
            ))
        } else {
            formats.forEach { menu.addItem(item($0.action)) }
        }
        menu.addItem(item(.setWallpaper))
    }

    private func addCommonDirectories(to menu: NSMenu, includeAdd: Bool) {
        let submenu = NSMenu(title: configuration.title(for: .openCommonDirectory))
        for directory in configuration.commonDirectories where
            directory.isEnabled && FileManager.default.fileExists(atPath: directory.resolvedURL.path) {
            submenu.addItem(item(
                .openCommonDirectory,
                title: directory.displayName(language: configuration.language),
                payload: directory.id.uuidString
            ))
        }
        if includeAdd {
            submenu.addItem(item(.addCommonDirectory))
        }
        menu.addItem(wrapping(
            title: configuration.title(for: .openCommonDirectory),
            submenu: submenu,
            icon: .openCommonDirectory
        ))
    }

    private func destinationMenu(action: FinderMenuAction) -> NSMenuItem {
        let submenu = NSMenu(title: configuration.title(for: action))
        for directory in configuration.destinationDirectories where
            directory.isEnabled && FileManager.default.fileExists(atPath: directory.resolvedURL.path) {
            submenu.addItem(item(
                action,
                title: directory.displayName(language: configuration.language),
                payload: directory.id.uuidString
            ))
        }
        let choose: FinderMenuAction = action == .moveToDirectory
            ? .chooseMoveDirectory : .chooseCopyDirectory
        submenu.addItem(item(choose))
        return wrapping(title: configuration.title(for: action), submenu: submenu, icon: action)
    }

    private func submenuItem(title: String, items: [NSMenuItem]) -> NSMenuItem {
        let submenu = NSMenu(title: title)
        items.forEach(submenu.addItem)
        return wrapping(title: title, submenu: submenu, icon: .openNewWindow)
    }

    private func wrapping(
        title: String,
        submenu: NSMenu,
        icon action: FinderMenuAction
    ) -> NSMenuItem {
        let result = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        result.submenu = submenu
        commands.append(MenuCommand(action: action))
        result.tag = firstTag + commands.count - 1
        result.image = menuImage(for: action)
        return result
    }

    private func item(
        _ action: FinderMenuAction,
        title: String? = nil,
        payload: String? = nil
    ) -> NSMenuItem {
        let resolvedTitle = payload == nil
            ? configuration.title(for: action)
            : (title ?? configuration.title(for: action))
        let result = NSMenuItem(
            title: resolvedTitle,
            action: selector,
            keyEquivalent: ""
        )
        result.target = target
        commands.append(MenuCommand(action: action, payload: payload))
        result.tag = firstTag + commands.count - 1
        result.image = menuImage(for: action)
        result.isHidden = !configuration.isActionEnabled(action)
        return result
    }

    private func shouldShowIcon(for action: FinderMenuAction) -> Bool {
        configuration.showMenuIcons && configuration.preference(for: action).showIcon
    }

    private func templateImage(for template: NewFileTemplate) -> NSImage? {
        guard shouldShowIcon(for: .createTemplate) else { return nil }
        return OriginalMenuIcon.image(for: template)
    }

    private func applicationImage(at url: URL) -> NSImage? {
        guard shouldShowIcon(for: .openWithApp) else { return nil }
        let key = url.standardizedFileURL.path
        if let cached = Self.applicationIconCache[key] { return cached }
        guard let image = serializedIcon(NSWorkspace.shared.icon(forFile: key)) else { return nil }
        Self.applicationIconCache[key] = image
        return image
    }

    private func menuImage(for action: FinderMenuAction) -> NSImage? {
        let preference = configuration.preference(for: action)
        guard shouldShowIcon(for: action) else { return nil }
        if let path = preference.customIconPath, let image = NSImage(contentsOfFile: path) {
            image.size = NSSize(width: 18, height: 18)
            return serializedIcon(image)
        }
        return OriginalMenuIcon.image(for: action)
    }

    private func serializedIcon(_ image: NSImage) -> NSImage? {
        guard let data = image.tiffRepresentation, let rendered = NSImage(data: data) else {
            return nil
        }
        rendered.size = NSSize(width: 18, height: 18)
        return rendered
    }

    private func localized(_ value: String) -> String {
        Localizer.text(value, language: configuration.language)
    }

    private func formatted(_ value: String, _ arguments: CVarArg...) -> String {
        Localizer.format(value, language: configuration.language, arguments: arguments)
    }

    private func finish(_ menu: NSMenu) {
        removeHiddenItems(in: menu)
        sortItems(in: menu)
    }

    private func sortItems(in menu: NSMenu) {
        for item in menu.items {
            if let submenu = item.submenu { sortItems(in: submenu) }
        }
        let order = Dictionary(
            uniqueKeysWithValues: configuration.actionPreferences.enumerated().map {
                ($0.element.action, $0.offset)
            }
        )
        let sorted = menu.items.enumerated().sorted { lhs, rhs in
            let leftCommand = command(forTag: lhs.element.tag)
            let rightCommand = command(forTag: rhs.element.tag)
            // 永久删除无论用户如何排序都固定在当前菜单末尾。
            let left = leftCommand?.action == .permanentDelete
                ? Int.max
                : (leftCommand.flatMap { order[$0.action] } ?? 1_000_000 + lhs.offset)
            let right = rightCommand?.action == .permanentDelete
                ? Int.max
                : (rightCommand.flatMap { order[$0.action] } ?? 1_000_000 + rhs.offset)
            return left == right ? lhs.offset < rhs.offset : left < right
        }.map(\.element)
        menu.removeAllItems()
        sorted.forEach(menu.addItem)
    }

    private func removeHiddenItems(in menu: NSMenu) {
        for item in menu.items {
            if let submenu = item.submenu {
                removeHiddenItems(in: submenu)
                if submenu.items.isEmpty { item.isHidden = true }
            }
        }
        for item in menu.items.reversed() where item.isHidden {
            menu.removeItem(item)
        }
    }

    private func isImage(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.contentTypeKey]),
              let type = values.contentType else { return false }
        return type.conforms(to: .image)
    }

    private func isDirectory(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        return values?.isDirectory == true && values?.isPackage != true
    }
}
