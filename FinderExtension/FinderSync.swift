@preconcurrency import Cocoa
import Darwin
@preconcurrency import FinderSync

private final class UnsafeMenuBox: @unchecked Sendable {
    var value: NSMenu?
}

private final class UnsafeMenuItemBox: @unchecked Sendable {
    let value: NSMenuItem

    init(_ value: NSMenuItem) {
        self.value = value
    }
}

final class FinderSync: FIFinderSync, @unchecked Sendable {
    @MainActor private lazy var controller = FIFinderSyncController.default()
    @MainActor private lazy var coordinator = FeatureCoordinator()
    @MainActor private var configurationObservers: [NSObjectProtocol] = []
    /// 菜单项使用跨菜单唯一 tag，保留近期映射，避免 Finder 在重新构建菜单后
    /// 点击旧菜单时按新数组下标误触其他动作。
    @MainActor private var menuCommands: [Int: MenuCommand] = [:]
    @MainActor private var nextMenuTag = 1

    override init() {
        super.init()
        runOnMainSync {
            self.configure()
        }
    }

    @MainActor
    private func configure() {
        let hadConfiguration = ConfigurationStore.hasStoredConfiguration()
        controller.directoryURLs = [UserPaths.homeDirectory]
        configurationObservers.append(ConfigurationStore.observeUpdates { [weak self] value in
            self?.coordinator.updateConfiguration(value)
        })
        configurationObservers.append(ConfigurationStore.observeExtensionRequests())
        configurationObservers.append(
            ConfigurationStore.observeTemplateImportRequests { [weak self] url in
                self?.coordinator.importTemplate(from: url)
            }
        )
        if !hadConfiguration {
            ConfigurationStore.requestAppConfiguration()
        }
    }

    private func runOnMainSync(_ operation: @escaping @MainActor @Sendable () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                operation()
            }
        } else {
            DispatchQueue.main.sync {
                MainActor.assumeIsolated {
                    operation()
                }
            }
        }
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        let box = UnsafeMenuBox()
        runOnMainSync {
            box.value = self.buildMenu(for: menuKind)
        }
        return box.value
    }

    @MainActor
    private func buildMenu(for menuKind: FIMenuKind) -> NSMenu? {
        let configuration = coordinator.configuration
        guard configuration.masterEnabled else { return nil }
        // Finder 的 selection/target 查询会跨进程；每次菜单构建只读取一次，
        // 同时确保排除判断与最终菜单使用完全相同的上下文快照。
        let contextURLs = selectedURLs()
        let targetedURL = controller.targetedURL()
        if contextURLs.contains(where: configuration.isExcluded)
            || (targetedURL.map(configuration.isExcluded) ?? false) {
            return nil
        }
        let firstTag = nextMenuTag
        let builder = FinderMenuBuilder(
            configuration: configuration,
            target: self,
            selector: #selector(performMenuAction(_:)),
            firstTag: firstTag
        )

        let menu: NSMenu?
        switch menuKind {
        case .contextualMenuForItems, .contextualMenuForSidebar:
            menu = builder.itemsMenu(urls: contextURLs)
        case .contextualMenuForContainer:
            menu = builder.containerMenu(hasCutItems: hasPasteItems())
        case .toolbarItemMenu:
            menu = contextURLs.isEmpty
                ? builder.containerMenu(hasCutItems: hasPasteItems())
                : builder.itemsMenu(urls: contextURLs)
        @unknown default:
            menu = nil
        }
        for (offset, command) in builder.commands.enumerated() {
            menuCommands[firstTag + offset] = command
        }
        nextMenuTag = firstTag + builder.commands.count
        if menuCommands.count > 4_096 {
            let oldestRetainedTag = max(1, nextMenuTag - 2_048)
            menuCommands = menuCommands.filter { $0.key >= oldestRetainedTag }
        }
        return menu
    }

    @objc private func performMenuAction(_ sender: NSMenuItem) {
        let box = UnsafeMenuItemBox(sender)
        runOnMainSync {
            self.performMenuActionOnMain(box.value)
        }
    }

    @MainActor
    private func performMenuActionOnMain(_ sender: NSMenuItem) {
        let tag = sender.tag
        guard let command = menuCommands[tag] else { return }
        let urls = selectedURLs()
        let currentDirectory = targetDirectory(for: urls)

        switch command.action {
        case .createTemplate:
            guard let payload = command.payload, let id = UUID(uuidString: payload),
                  let currentDirectory else { return }
            coordinator.create(templateID: id, in: currentDirectory)
        case .createNamedFile:
            if let currentDirectory { coordinator.createNamedFile(in: currentDirectory) }
        case .importTemplate:
            if let source = urls.first { coordinator.importTemplate(from: source) }
        case .openCommonDirectory:
            if let payload = command.payload, let id = UUID(uuidString: payload) {
                coordinator.openDirectory(id)
            }
        case .addCommonDirectory:
            if let directory = urls.first(where: isDirectory) ?? currentDirectory {
                coordinator.addCommonDirectory(directory)
            }
        case .paste:
            if let currentDirectory { coordinator.paste(into: currentDirectory) }
        case .copyPath:
            copyToPasteboard(urls.map(\.path))
        case .copyName:
            copyToPasteboard(urls.map(\.lastPathComponent))
        case .copyCurrentDirectoryPath:
            if let currentDirectory { copyToPasteboard([currentDirectory.path]) }
        case .cut:
            coordinator.cut(urls)
        case .moveToDirectory, .copyToDirectory:
            guard let payload = command.payload,
                  let id = UUID(uuidString: payload),
                  let shortcut = coordinator.configuration.destinationDirectories.first(where: {
                      $0.id == id
                  }) else { return }
            coordinator.transfer(
                urls,
                to: shortcut.resolvedURL,
                move: command.action == .moveToDirectory
            )
        case .chooseMoveDirectory:
            coordinator.chooseTransferDestination(for: urls, move: true)
        case .chooseCopyDirectory:
            coordinator.chooseTransferDestination(for: urls, move: false)
        case .fileInfo:
            coordinator.showFileInfo(urls)
        case .setFolderIcon:
            if let folder = urls.first { coordinator.setFolderIcon(folder) }
        case .createDesktopAlias:
            coordinator.createDesktopAliases(for: urls)
        case .openWithApp:
            guard let payload = command.payload, let id = UUID(uuidString: payload) else { return }
            coordinator.openWith(id, urls: urls, currentDirectory: currentDirectory)
        case .createSameNameFolder:
            coordinator.createSameNameFolders(for: urls)
        case .hideSelected:
            coordinator.setHidden(urls, hidden: true)
        case .showSelected:
            coordinator.setHidden(urls, hidden: false)
        case .hideAll:
            if let currentDirectory { coordinator.setAllHidden(in: currentDirectory, hidden: true) }
        case .showAll:
            if let currentDirectory { coordinator.setAllHidden(in: currentDirectory, hidden: false) }
        case .grantWritePermission:
            coordinator.grantWritePermission(urls)
        case .dissolveFolder:
            if let folder = urls.first { coordinator.dissolve(folder) }
        case .openNewWindow:
            if let location = urls.first(where: isDirectory) ?? currentDirectory {
                coordinator.openInFinder(location, newTab: false)
            }
        case .openNewTab:
            if let location = urls.first(where: isDirectory) ?? currentDirectory {
                coordinator.openInFinder(location, newTab: true)
            }
        case .permanentDelete:
            coordinator.permanentlyDelete(urls)
        case .convertWebP:
            coordinator.convertImages(urls, to: .webP)
        case .convertHEIC:
            coordinator.convertImages(urls, to: .heic)
        case .convertJPG:
            coordinator.convertImages(urls, to: .jpg)
        case .convertPNG:
            coordinator.convertImages(urls, to: .png)
        case .setWallpaper:
            if let image = urls.first { coordinator.setWallpaper(image) }
        }
    }

    @MainActor
    private func selectedURLs() -> [URL] {
        if let selectedURLs = controller.selectedItemURLs(), !selectedURLs.isEmpty {
            return selectedURLs
        }

        if let targetedURL = controller.targetedURL() {
            return [targetedURL]
        }

        return []
    }

    @MainActor
    private func targetDirectory(for selected: [URL]) -> URL? {
        if let target = controller.targetedURL() {
            return isDirectory(target) ? target : target.deletingLastPathComponent()
        }
        if let first = selected.first {
            return first.hasDirectoryPath
                ? first.deletingLastPathComponent()
                : first.deletingLastPathComponent()
        }
        return nil
    }

    @MainActor
    private func isDirectory(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        return values?.isDirectory == true && values?.isPackage != true
    }

    @MainActor
    private func copyToPasteboard(_ values: [String]) {
        guard !values.isEmpty else {
            return
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(values.joined(separator: "\n"), forType: .string)
    }

    @MainActor
    private func hasPasteItems() -> Bool {
        if !(UserDefaults.standard.stringArray(forKey: "cutPaths") ?? []).isEmpty {
            return true
        }
        return NSPasteboard.general.canReadObject(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        )
    }
}
