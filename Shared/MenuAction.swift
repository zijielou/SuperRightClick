import AppKit
import Darwin
import Foundation

/// 返回真实登录用户目录，而不是 Finder 扩展沙盒容器的 Home。
/// Finder Sync 进程中的 `homeDirectoryForCurrentUser`/`~` 可能指向容器，
/// 所有跨 target 的用户路径都必须通过这里解析。
enum UserPaths {
    static let homeDirectory: URL = {
        guard let passwordEntry = getpwuid(getuid()),
              let homePath = passwordEntry.pointee.pw_dir else {
            return FileManager.default.homeDirectoryForCurrentUser
        }
        return URL(fileURLWithPath: String(cString: homePath), isDirectory: true)
    }()

    static func expandingTilde(in path: String) -> String {
        if path == "~" { return homeDirectory.path }
        if path.hasPrefix("~/") {
            return homeDirectory
                .appendingPathComponent(String(path.dropFirst(2)))
                .path
        }
        return NSString(string: path).expandingTildeInPath
    }
}

extension UserDefaults: @retroactive @unchecked Sendable {}

enum FinderMenuAction: String, Codable, CaseIterable, Sendable {
    case createTemplate
    case createNamedFile
    case importTemplate
    case openCommonDirectory
    case addCommonDirectory
    case paste
    case copyPath
    case copyName
    case copyCurrentDirectoryPath
    case cut
    case moveToDirectory
    case copyToDirectory
    case chooseMoveDirectory
    case chooseCopyDirectory
    case fileInfo
    case setFolderIcon
    case createDesktopAlias
    case openWithApp
    case createSameNameFolder
    case hideSelected
    case showSelected
    case hideAll
    case showAll
    case grantWritePermission
    case dissolveFolder
    case openNewWindow
    case openNewTab
    case permanentDelete
    case convertWebP
    case convertHEIC
    case convertJPG
    case convertPNG
    case setWallpaper

    var title: String {
        switch self {
        case .createTemplate: "新建文件"
        case .createNamedFile: "通过窗口创建新文件…"
        case .importTemplate: "添加为新建模板…"
        case .openCommonDirectory: "打开常用目录"
        case .addCommonDirectory: "添加到常用目录"
        case .paste: "粘贴"
        case .copyPath: "复制路径"
        case .copyName: "复制文件名"
        case .copyCurrentDirectoryPath: "复制当前目录路径"
        case .cut: "剪切"
        case .moveToDirectory: "移动到"
        case .copyToDirectory: "复制到"
        case .chooseMoveDirectory, .chooseCopyDirectory: "选择文件夹…"
        case .fileInfo: "文件信息与摘要"
        case .setFolderIcon: "自定义文件夹图标…"
        case .createDesktopAlias: "发送快捷方式到桌面"
        case .openWithApp: "用 App 打开"
        case .createSameNameFolder: "根据文件名新建文件夹"
        case .hideSelected: "隐藏选中项目"
        case .showSelected: "显示选中项目"
        case .hideAll: "隐藏当前目录全部项目"
        case .showAll: "显示当前目录全部项目"
        case .grantWritePermission: "授予写入权限"
        case .dissolveFolder: "解散文件夹"
        case .openNewWindow: "在 Finder 新窗口中打开"
        case .openNewTab: "在 Finder 新标签页中打开"
        case .permanentDelete: "永久删除…"
        case .convertWebP: "转换为 WebP"
        case .convertHEIC: "转换为 HEIC"
        case .convertJPG: "转换为 JPG"
        case .convertPNG: "转换为 PNG"
        case .setWallpaper: "设置为桌面墙纸"
        }
    }
}

enum AppLanguage: String, Codable, CaseIterable, Sendable {
    case system
    case simplifiedChinese
    case traditionalChinese
    case english

    var displayName: String {
        switch self {
        case .system: "跟随系统"
        case .simplifiedChinese: "简体中文"
        case .traditionalChinese: "繁體中文"
        case .english: "English"
        }
    }
}

enum Localizer {
    static func text(_ simplified: String, language: AppLanguage) -> String {
        let resolved: AppLanguage
        if language == .system {
            let code = Locale.preferredLanguages.first ?? "zh-Hans"
            if code.hasPrefix("en") {
                resolved = .english
            } else if code.hasPrefix("zh-Hant") || code.hasPrefix("zh-TW") || code.hasPrefix("zh-HK") {
                resolved = .traditionalChinese
            } else {
                resolved = .simplifiedChinese
            }
        } else {
            resolved = language
        }
        switch resolved {
        case .simplifiedChinese, .system:
            return simplified
        case .traditionalChinese:
            return traditional[simplified] ?? simplified
        case .english:
            return english[simplified] ?? simplified
        }
    }

    private static let traditional: [String: String] = [
        "新建文件": "新增檔案", "复制路径": "複製路徑", "复制文件名": "複製檔名",
        "剪切": "剪下", "粘贴": "貼上", "移动到": "移動到", "复制到": "複製到",
        "文件操作": "檔案操作", "常用目录": "常用目錄", "打开终端": "開啟終端機",
        "用 App 打开": "使用 App 開啟", "图片转换": "圖片轉換",
        "设置为桌面墙纸": "設為桌面背景", "永久删除…": "永久刪除…",
        "转换为 WebP": "轉換為 WebP", "转换为 HEIC": "轉換為 HEIC",
        "转换为 JPG": "轉換為 JPG", "转换为 PNG": "轉換為 PNG",
        "复制当前目录路径": "複製目前目錄路徑",
        "通过窗口创建新文件…": "透過視窗新增檔案…",
        "添加为新建模板…": "加入為新增檔案範本…",
        "打开常用目录": "開啟常用目錄", "添加到常用目录": "加入常用目錄",
        "选择文件夹…": "選擇資料夾…", "文件信息与摘要": "檔案資訊與摘要",
        "自定义文件夹图标…": "自訂資料夾圖示…",
        "发送快捷方式到桌面": "傳送替身到桌面",
        "根据文件名新建文件夹": "依檔名新增資料夾",
        "隐藏选中项目": "隱藏所選項目", "显示选中项目": "顯示所選項目",
        "隐藏当前目录全部项目": "隱藏目前目錄全部項目",
        "显示当前目录全部项目": "顯示目前目錄全部項目",
        "授予写入权限": "授予寫入權限", "解散文件夹": "解散資料夾",
        "在 Finder 新窗口中打开": "在 Finder 新視窗中開啟",
        "在 Finder 新标签页中打开": "在 Finder 新分頁中開啟",
        "状态": "狀態", "目录": "目錄", "菜单": "選單",
        "图片": "圖片", "高级": "進階",
        "Finder 扩展已启用": "Finder 擴充功能已啟用",
        "Finder 扩展尚未启用": "Finder 擴充功能尚未啟用",
        "所有文件操作均在 Finder 扩展中本地完成，不访问网络。": "所有檔案操作均在 Finder 擴充功能中本機完成，不存取網路。",
        "权限状态": "權限狀態", "打开 Finder 扩展设置": "開啟 Finder 擴充功能設定",
        "刷新状态": "重新整理狀態", "恢复默认配置": "還原預設設定",
        "新建后自动打开": "新增後自動開啟", "创建成功时播放声音": "建立成功時播放聲音",
        "模板（可拖动排序）": "範本（可拖曳排序）",
        "常用目录（名称可直接修改，例如 Desktop 改为“桌面”）": "常用目錄（名稱可直接修改）",
        "移动/复制目标": "移動/複製目標",
        "启用 SuperRightClick 菜单": "啟用 SuperRightClick 選單",
        "显示菜单图标": "顯示選單圖示", "显示菜单栏图标": "顯示選單列圖示",
        "合并文件操作": "合併檔案操作", "合并“用 App 打开”": "合併「使用 App 開啟」",
        "合并图片转换": "合併圖片轉換", "语言": "語言",
        "墙纸应用到全部屏幕": "桌面背景套用至所有螢幕",
        "文件操作合并为二级菜单": "檔案操作合併為次級選單",
        "高风险功能（默认关闭）": "高風險功能（預設關閉）",
        "批量隐藏/显示当前目录": "批次隱藏/顯示目前目錄",
        "修改写入权限": "修改寫入權限",
        "永久删除": "永久刪除", "行为": "行為",
        "操作成功时播放声音": "操作成功時播放聲音",
        "剪切时临时隐藏文件": "剪下時暫時隱藏檔案",
        "排除位置（这些目录及其子目录不显示增强菜单）": "排除位置（這些目錄及其子目錄不顯示增強選單）",
    ]

    private static let english: [String: String] = [
        "新建文件": "New File", "复制路径": "Copy Path", "复制文件名": "Copy Name",
        "复制当前目录路径": "Copy Current Folder Path", "剪切": "Cut", "粘贴": "Paste",
        "移动到": "Move To", "复制到": "Copy To", "选择文件夹…": "Choose Folder…",
        "文件操作": "File Actions", "常用目录": "Favorite Folders",
        "打开终端": "Open Terminal", "用 App 打开": "Open With App",
        "图片转换": "Convert Image", "设置为桌面墙纸": "Set as Desktop Wallpaper",
        "转换为 WebP": "Convert to WebP", "转换为 HEIC": "Convert to HEIC",
        "转换为 JPG": "Convert to JPG", "转换为 PNG": "Convert to PNG",
        "永久删除…": "Delete Permanently…",
        "通过窗口创建新文件…": "Create New File…",
        "添加为新建模板…": "Add as New File Template…",
        "打开常用目录": "Open Favorite Folder",
        "添加到常用目录": "Add to Favorite Folders",
        "文件信息与摘要": "File Info and Hashes",
        "自定义文件夹图标…": "Set Folder Icon…",
        "发送快捷方式到桌面": "Send Alias to Desktop",
        "根据文件名新建文件夹": "Create Folder from Filename",
        "隐藏选中项目": "Hide Selected Items",
        "显示选中项目": "Show Selected Items",
        "隐藏当前目录全部项目": "Hide All Items in Folder",
        "显示当前目录全部项目": "Show All Items in Folder",
        "授予写入权限": "Grant Write Permission",
        "解散文件夹": "Dissolve Folder",
        "在 Finder 新窗口中打开": "Open in New Finder Window",
        "在 Finder 新标签页中打开": "Open in New Finder Tab",
        "状态": "Status", "目录": "Folders", "菜单": "Menu",
        "图片": "Images", "高级": "Advanced",
        "Finder 扩展已启用": "Finder extension is enabled",
        "Finder 扩展尚未启用": "Finder extension is disabled",
        "所有文件操作均在 Finder 扩展中本地完成，不访问网络。": "All file operations run locally in the Finder extension. No network access.",
        "权限状态": "Permissions", "打开 Finder 扩展设置": "Open Finder Extension Settings",
        "刷新状态": "Refresh", "恢复默认配置": "Restore All Defaults",
        "新建后自动打开": "Open after creation", "创建成功时播放声音": "Play creation sound",
        "模板（可拖动排序）": "Templates (drag to reorder)",
        "常用目录（名称可直接修改，例如 Desktop 改为“桌面”）": "Favorite folders (names are editable)",
        "移动/复制目标": "Move/Copy Destinations",
        "启用 SuperRightClick 菜单": "Enable SuperRightClick Menu",
        "显示菜单图标": "Show Menu Icons", "显示菜单栏图标": "Show Menu Bar Item",
        "合并文件操作": "Group File Actions", "合并“用 App 打开”": "Group Open With Apps",
        "合并图片转换": "Group Image Conversion", "语言": "Language",
        "墙纸应用到全部屏幕": "Apply wallpaper to all displays",
        "文件操作合并为二级菜单": "Group file actions in a submenu",
        "高风险功能（默认关闭）": "High-risk Features (off by default)",
        "批量隐藏/显示当前目录": "Bulk hide/show current folder",
        "修改写入权限": "Change write permissions",
        "永久删除": "Permanent deletion", "行为": "Behavior",
        "操作成功时播放声音": "Play sound after successful operations",
        "剪切时临时隐藏文件": "Temporarily hide cut files",
        "排除位置（这些目录及其子目录不显示增强菜单）": "Excluded locations (hide enhanced menus in these folders)",
    ]
}

enum ImageConversionFormat: String, Codable, CaseIterable, Sendable {
    case webP
    case heic
    case jpg
    case png

    var action: FinderMenuAction {
        switch self {
        case .webP: .convertWebP
        case .heic: .convertHEIC
        case .jpg: .convertJPG
        case .png: .convertPNG
        }
    }

    var fileExtension: String { rawValue.lowercased() }
}

struct ActionPreference: Codable, Identifiable, Hashable, Sendable {
    var action: FinderMenuAction
    var isEnabled: Bool
    var customName: String?
    var showIcon: Bool
    var customIconPath: String?

    var id: FinderMenuAction { action }

    init(
        action: FinderMenuAction,
        isEnabled: Bool = true,
        customName: String? = nil,
        showIcon: Bool = true,
        customIconPath: String? = nil
    ) {
        self.action = action
        self.isEnabled = isEnabled
        self.customName = customName
        self.showIcon = showIcon
        self.customIconPath = customIconPath
    }
}

enum BuiltinTemplateKind: String, Codable, Sendable {
    case text
    case richText
    case xml
    case markdown
    case custom
}

struct NewFileTemplate: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var name: String
    var fileExtension: String
    var kind: BuiltinTemplateKind
    var storedFilename: String?
    var isEnabled: Bool
    var showInMainMenu: Bool
    var iconVariant: Int?

    init(
        id: UUID = UUID(),
        name: String,
        fileExtension: String,
        kind: BuiltinTemplateKind,
        storedFilename: String? = nil,
        isEnabled: Bool = true,
        showInMainMenu: Bool = false,
        iconVariant: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.fileExtension = fileExtension
        self.kind = kind
        self.storedFilename = storedFilename
        self.isEnabled = isEnabled
        self.showInMainMenu = showInMainMenu
        self.iconVariant = iconVariant
    }
}

struct DirectoryShortcut: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var name: String
    var path: String
    var isEnabled: Bool

    init(id: UUID = UUID(), name: String, path: String, isEnabled: Bool = true) {
        self.id = id
        self.name = name
        self.path = path
        self.isEnabled = isEnabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        path = try container.decode(String.self, forKey: .path)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
    }

    var resolvedURL: URL {
        URL(fileURLWithPath: UserPaths.expandingTilde(in: path), isDirectory: true)
    }
}

struct AppShortcut: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var name: String
    var appPath: String
    var bundleIdentifier: String?
    var isEnabled: Bool
    var isBuiltin: Bool

    init(
        id: UUID = UUID(),
        name: String,
        appPath: String,
        bundleIdentifier: String? = nil,
        isEnabled: Bool = true,
        isBuiltin: Bool = false
    ) {
        self.id = id
        self.name = name
        self.appPath = appPath
        self.bundleIdentifier = bundleIdentifier ?? Bundle(url: URL(fileURLWithPath: appPath))?.bundleIdentifier
        self.isEnabled = isEnabled
        self.isBuiltin = isBuiltin
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        appPath = try container.decode(String.self, forKey: .appPath)
        bundleIdentifier = try container.decodeIfPresent(String.self, forKey: .bundleIdentifier)
            ?? Bundle(url: URL(fileURLWithPath: appPath))?.bundleIdentifier
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        isBuiltin = try container.decodeIfPresent(Bool.self, forKey: .isBuiltin) ?? false
    }

    var appURL: URL {
        if let bundleIdentifier,
           let located = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            return located
        }
        return URL(fileURLWithPath: appPath, isDirectory: true)
    }

    var isInstalled: Bool {
        FileManager.default.fileExists(atPath: appURL.path)
    }

    /// 终端类应用在菜单中以“打开终端”一级菜单项呈现，
    /// 且选中文件时目标映射为其父目录。
    var isTerminalApp: Bool {
        let terminalBundleIDs: Set<String> = [
            "com.apple.Terminal",
            "com.googlecode.iterm2",
            "dev.warp.Warp-Stable",
            "net.kovidgoyal.kitty",
            "com.github.wez.wezterm",
            "io.alacritty",
        ]
        guard let bundleID = bundleIdentifier ?? Bundle(url: appURL)?.bundleIdentifier else {
            return false
        }
        return terminalBundleIDs.contains(bundleID)
    }
}

struct MenuConfiguration: Codable, Equatable, Sendable {
    var templates: [NewFileTemplate]
    var commonDirectories: [DirectoryShortcut]
    var destinationDirectories: [DirectoryShortcut]
    var openWithApps: [AppShortcut]
    var autoOpenNewFile: Bool
    var playCreationSound: Bool
    var mergeFileOperations: Bool
    var enableBulkVisibility: Bool
    var enablePermissionChanges: Bool
    var enableDissolveFolder: Bool
    var enablePermanentDelete: Bool
    var masterEnabled: Bool
    var actionPreferences: [ActionPreference]
    var showMenuIcons: Bool
    var mergeOpenWithApps: Bool
    var mergeImageOperations: Bool
    var excludedPaths: [String]
    var playOperationSound: Bool
    var hideCutItems: Bool
    var showMenuBarIcon: Bool
    var language: AppLanguage
    var imageQuality: Double
    var jpgBackgroundHex: String
    var wallpaperAllScreens: Bool

    static let defaultOpenWithApps = [
        AppShortcut(
            name: "终端",
            appPath: "/System/Applications/Utilities/Terminal.app",
            bundleIdentifier: "com.apple.Terminal",
            isBuiltin: true
        ),
        AppShortcut(
            name: "Visual Studio Code",
            appPath: "/Applications/Visual Studio Code.app",
            bundleIdentifier: "com.microsoft.VSCode",
            isBuiltin: true
        ),
    ]

    static let defaultActionPreferences = FinderMenuAction.allCases.filter {
        $0 != .openNewWindow && $0 != .openNewTab && $0 != .convertWebP
    }.map {
        ActionPreference(action: $0)
    }

    init(
        templates: [NewFileTemplate],
        commonDirectories: [DirectoryShortcut],
        destinationDirectories: [DirectoryShortcut],
        openWithApps: [AppShortcut] = MenuConfiguration.defaultOpenWithApps,
        autoOpenNewFile: Bool,
        playCreationSound: Bool,
        mergeFileOperations: Bool,
        enableBulkVisibility: Bool,
        enablePermissionChanges: Bool,
        enableDissolveFolder: Bool,
        enablePermanentDelete: Bool,
        masterEnabled: Bool = true,
        actionPreferences: [ActionPreference] = MenuConfiguration.defaultActionPreferences,
        showMenuIcons: Bool = true,
        mergeOpenWithApps: Bool = true,
        mergeImageOperations: Bool = true,
        excludedPaths: [String] = [],
        playOperationSound: Bool = false,
        hideCutItems: Bool = false,
        showMenuBarIcon: Bool = true,
        language: AppLanguage = .system,
        imageQuality: Double = 0.85,
        jpgBackgroundHex: String = "#FFFFFF",
        wallpaperAllScreens: Bool = true
    ) {
        self.templates = templates
        self.commonDirectories = commonDirectories
        self.destinationDirectories = destinationDirectories
        self.openWithApps = openWithApps
        self.autoOpenNewFile = autoOpenNewFile
        self.playCreationSound = playCreationSound
        self.mergeFileOperations = mergeFileOperations
        self.enableBulkVisibility = enableBulkVisibility
        self.enablePermissionChanges = enablePermissionChanges
        self.enableDissolveFolder = enableDissolveFolder
        self.enablePermanentDelete = enablePermanentDelete
        self.masterEnabled = masterEnabled
        self.actionPreferences = actionPreferences
        self.showMenuIcons = showMenuIcons
        self.mergeOpenWithApps = mergeOpenWithApps
        self.mergeImageOperations = mergeImageOperations
        self.excludedPaths = excludedPaths
        self.playOperationSound = playOperationSound
        self.hideCutItems = hideCutItems
        self.showMenuBarIcon = showMenuBarIcon
        self.language = language
        self.imageQuality = imageQuality
        self.jpgBackgroundHex = jpgBackgroundHex
        self.wallpaperAllScreens = wallpaperAllScreens
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        templates = try container.decode([NewFileTemplate].self, forKey: .templates)
        commonDirectories = try container.decode([DirectoryShortcut].self, forKey: .commonDirectories)
        destinationDirectories = try container.decode(
            [DirectoryShortcut].self,
            forKey: .destinationDirectories
        )
        // 旧版本配置没有该字段，缺省时回填默认应用列表。
        openWithApps = try container.decodeIfPresent([AppShortcut].self, forKey: .openWithApps)
            ?? MenuConfiguration.defaultOpenWithApps
        autoOpenNewFile = try container.decode(Bool.self, forKey: .autoOpenNewFile)
        playCreationSound = try container.decode(Bool.self, forKey: .playCreationSound)
        mergeFileOperations = try container.decode(Bool.self, forKey: .mergeFileOperations)
        enableBulkVisibility = try container.decode(Bool.self, forKey: .enableBulkVisibility)
        enablePermissionChanges = try container.decode(Bool.self, forKey: .enablePermissionChanges)
        enableDissolveFolder = try container.decode(Bool.self, forKey: .enableDissolveFolder)
        enablePermanentDelete = try container.decode(Bool.self, forKey: .enablePermanentDelete)
        masterEnabled = try container.decodeIfPresent(Bool.self, forKey: .masterEnabled) ?? true
        actionPreferences = try container.decodeIfPresent(
            [ActionPreference].self,
            forKey: .actionPreferences
        ) ?? MenuConfiguration.defaultActionPreferences
        showMenuIcons = try container.decodeIfPresent(Bool.self, forKey: .showMenuIcons) ?? true
        mergeOpenWithApps = try container.decodeIfPresent(
            Bool.self,
            forKey: .mergeOpenWithApps
        ) ?? true
        mergeImageOperations = try container.decodeIfPresent(
            Bool.self,
            forKey: .mergeImageOperations
        ) ?? true
        excludedPaths = try container.decodeIfPresent([String].self, forKey: .excludedPaths) ?? []
        playOperationSound = try container.decodeIfPresent(
            Bool.self,
            forKey: .playOperationSound
        ) ?? false
        hideCutItems = try container.decodeIfPresent(Bool.self, forKey: .hideCutItems) ?? false
        showMenuBarIcon = try container.decodeIfPresent(
            Bool.self,
            forKey: .showMenuBarIcon
        ) ?? true
        language = try container.decodeIfPresent(AppLanguage.self, forKey: .language) ?? .system
        imageQuality = try container.decodeIfPresent(Double.self, forKey: .imageQuality) ?? 0.85
        jpgBackgroundHex = try container.decodeIfPresent(
            String.self,
            forKey: .jpgBackgroundHex
        ) ?? "#FFFFFF"
        wallpaperAllScreens = try container.decodeIfPresent(
            Bool.self,
            forKey: .wallpaperAllScreens
        ) ?? true
        mergeMissingDefaults()
    }

    /// 去掉名称+扩展名重复的模板（保留最后一次导入的），修复历史上重复导入造成的污染。
    mutating func deduplicateTemplates() {
        var seen = Set<String>()
        var result: [NewFileTemplate] = []
        for template in templates.reversed() {
            let key = "\(template.name.lowercased())|\(template.fileExtension.lowercased())"
            if seen.insert(key).inserted {
                result.append(template)
            }
        }
        templates = result.reversed()
    }

    mutating func mergeMissingDefaults() {
        actionPreferences.removeAll {
            $0.action == .openNewWindow || $0.action == .openNewTab || $0.action == .convertWebP
        }
        let known = Set(actionPreferences.map(\.action))
        actionPreferences.append(contentsOf: Self.defaultActionPreferences.filter {
            !known.contains($0.action)
        })
        for builtin in Self.defaultOpenWithApps where !openWithApps.contains(where: {
            $0.bundleIdentifier == builtin.bundleIdentifier
        }) {
            openWithApps.append(builtin)
        }
    }

    func preference(for action: FinderMenuAction) -> ActionPreference {
        actionPreferences.first(where: { $0.action == action })
            ?? ActionPreference(action: action)
    }

    func isActionEnabled(_ action: FinderMenuAction) -> Bool {
        preference(for: action).isEnabled
    }

    func title(for action: FinderMenuAction) -> String {
        let custom = preference(for: action).customName?.trimmingCharacters(in: .whitespacesAndNewlines)
        return custom?.isEmpty == false ? custom! : Localizer.text(action.title, language: language)
    }

    func isExcluded(_ url: URL) -> Bool {
        let candidate = url.standardizedFileURL.resolvingSymlinksInPath().path
        return excludedPaths.contains {
            let excluded = URL(
                fileURLWithPath: UserPaths.expandingTilde(in: $0),
                isDirectory: true
            )
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
            return candidate == excluded || candidate.hasPrefix(excluded + "/")
        }
    }

    static let `default` = MenuConfiguration(
        templates: [
            NewFileTemplate(name: "TXT", fileExtension: "txt", kind: .text, showInMainMenu: true),
            NewFileTemplate(name: "RTF", fileExtension: "rtf", kind: .richText),
            NewFileTemplate(name: "XML", fileExtension: "xml", kind: .xml),
            NewFileTemplate(name: "Markdown", fileExtension: "md", kind: .markdown, showInMainMenu: true),
        ],
        commonDirectories: [
            DirectoryShortcut(name: "下载", path: "~/Downloads"),
            DirectoryShortcut(name: "文稿", path: "~/Documents"),
        ],
        destinationDirectories: [
            DirectoryShortcut(name: "下载", path: "~/Downloads"),
            DirectoryShortcut(name: "桌面", path: "~/Desktop"),
            DirectoryShortcut(name: "文稿", path: "~/Documents"),
        ],
        autoOpenNewFile: false,
        playCreationSound: false,
        mergeFileOperations: true,
        enableBulkVisibility: false,
        enablePermissionChanges: false,
        enableDissolveFolder: false,
        enablePermanentDelete: false
    )
}

/// Finder 扩展与主应用之间的重命名启动协议。
/// 分布式通知只用于主应用已运行的快速路径；冷启动通过命令行参数传递，
/// 避免应用尚未注册观察者时丢失请求。
enum RenameRequestBridge {
    static let hostBundleIdentifier = "local.SuperRightClick"
    static let launchArgument = "--superrightclick-rename"
}

enum ConfigurationStore {
    private static let key = "menuConfiguration.v2"
    private static let updateNotification = Notification.Name("local.SuperRightClick.configuration.updated")
    private static let extensionRequestNotification = Notification.Name(
        "local.SuperRightClick.configuration.requestExtension"
    )
    private static let appRequestNotification = Notification.Name(
        "local.SuperRightClick.configuration.requestApp"
    )
    private static let renameRequestNotification = Notification.Name(
        "local.SuperRightClick.rename.request"
    )
    private static let templateImportRequestNotification = Notification.Name(
        "local.SuperRightClick.template.import"
    )

    static func hasStoredConfiguration(defaults: UserDefaults = .standard) -> Bool {
        defaults.data(forKey: key) != nil
    }

    static func load(defaults: UserDefaults = .standard) -> MenuConfiguration {
        guard let data = defaults.data(forKey: key),
              var value = try? JSONDecoder().decode(MenuConfiguration.self, from: data) else {
            return .default
        }
        value.deduplicateTemplates()
        return value
    }

    static func save(
        _ configuration: MenuConfiguration,
        defaults: UserDefaults = .standard,
        publish: Bool = true
    ) {
        guard let data = try? JSONEncoder().encode(configuration) else { return }
        defaults.set(data, forKey: key)
        if publish {
            let source = Bundle.main.bundleIdentifier ?? "unknown"
            let payload = "\(source)|\(data.base64EncodedString())"
            DistributedNotificationCenter.default().postNotificationName(
                updateNotification,
                object: payload,
                userInfo: nil,
                deliverImmediately: true
            )
        }
    }

    static func observeUpdates(
        defaults: UserDefaults = .standard,
        handler: @escaping @MainActor @Sendable (MenuConfiguration) -> Void
    ) -> NSObjectProtocol {
        DistributedNotificationCenter.default().addObserver(
            forName: updateNotification,
            object: nil,
            queue: .main
        ) { notification in
            guard let payload = notification.object as? String,
                  let separator = payload.firstIndex(of: "|") else { return }
            let source = String(payload[..<separator])
            guard source != Bundle.main.bundleIdentifier else { return }
            let encoded = String(payload[payload.index(after: separator)...])
            guard let data = Data(base64Encoded: encoded),
                  var configuration = try? JSONDecoder().decode(MenuConfiguration.self, from: data)
            else { return }
            configuration.deduplicateTemplates()
            configuration.mergeMissingDefaults()
            MainActor.assumeIsolated {
                save(configuration, defaults: defaults, publish: false)
                handler(configuration)
            }
        }
    }

    static func requestExtensionConfiguration() {
        DistributedNotificationCenter.default().postNotificationName(
            extensionRequestNotification,
            object: Bundle.main.bundleIdentifier,
            userInfo: nil,
            deliverImmediately: true
        )
    }

    static func requestAppConfiguration() {
        DistributedNotificationCenter.default().postNotificationName(
            appRequestNotification,
            object: Bundle.main.bundleIdentifier,
            userInfo: nil,
            deliverImmediately: true
        )
    }

    static func observeExtensionRequests(
        defaults: UserDefaults = .standard
    ) -> NSObjectProtocol {
        observeRequests(named: extensionRequestNotification, defaults: defaults)
    }

    static func observeAppRequests(
        defaults: UserDefaults = .standard
    ) -> NSObjectProtocol {
        observeRequests(named: appRequestNotification, defaults: defaults)
    }

    static func requestRename(_ url: URL) {
        DistributedNotificationCenter.default().postNotificationName(
            renameRequestNotification,
            object: url.path,
            userInfo: nil,
            deliverImmediately: true
        )
    }

    static func observeRenameRequests(
        handler: @escaping @MainActor @Sendable (URL) -> Void
    ) -> NSObjectProtocol {
        DistributedNotificationCenter.default().addObserver(
            forName: renameRequestNotification,
            object: nil,
            queue: .main
        ) { notification in
            guard let path = notification.object as? String else { return }
            MainActor.assumeIsolated {
                handler(URL(fileURLWithPath: path))
            }
        }
    }

    static func requestTemplateImport(_ url: URL) {
        DistributedNotificationCenter.default().postNotificationName(
            templateImportRequestNotification,
            object: url.path,
            userInfo: nil,
            deliverImmediately: true
        )
    }

    static func observeTemplateImportRequests(
        handler: @escaping @MainActor @Sendable (URL) -> Void
    ) -> NSObjectProtocol {
        DistributedNotificationCenter.default().addObserver(
            forName: templateImportRequestNotification,
            object: nil,
            queue: .main
        ) { notification in
            guard let path = notification.object as? String else { return }
            MainActor.assumeIsolated {
                handler(URL(fileURLWithPath: path))
            }
        }
    }

    private static func observeRequests(
        named name: Notification.Name,
        defaults: UserDefaults
    ) -> NSObjectProtocol {
        DistributedNotificationCenter.default().addObserver(
            forName: name,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                save(load(defaults: defaults), defaults: defaults, publish: true)
            }
        }
    }
}

/// 全部图标均为程序化原创绘制，不使用任何第三方素材。
@MainActor
enum OriginalMenuIcon {
    private static let iconSize = NSSize(width: 18, height: 18)

    private struct ActionImageKey: Hashable {
        let action: FinderMenuAction
        let appearance: String
    }

    private struct TemplateImageKey: Hashable {
        let variant: Int
        let appearance: String
    }

    private static var actionImages: [ActionImageKey: NSImage] = [:]
    private static var templateImages: [TemplateImageKey: NSImage] = [:]
    private static var statusBarImageCache: NSImage?

    private static var appearanceKey: String {
        NSAppearance.currentDrawing().bestMatch(from: [.aqua, .darkAqua])?.rawValue
            ?? NSAppearance.Name.aqua.rawValue
    }

    /// 借鉴成熟 Finder 工具“小卡片 + 彩色语义符号”的视觉语言，
    /// 但所有轮廓、路径和配色均在本项目中重新设计与程序化绘制。
    private enum Palette {
        static let folder = NSColor(srgbRed: 0.35, green: 0.72, blue: 0.96, alpha: 1)
        static let folderEdge = NSColor(srgbRed: 0.16, green: 0.55, blue: 0.86, alpha: 1)
        static let paper = NSColor.white
        static let paperEdge = NSColor(srgbRed: 0.62, green: 0.68, blue: 0.75, alpha: 1)
        static let ink = NSColor(srgbRed: 0.28, green: 0.33, blue: 0.40, alpha: 1)
        static let blue = NSColor(srgbRed: 0.20, green: 0.65, blue: 0.96, alpha: 1)
        static let cyan = NSColor(srgbRed: 0.28, green: 0.82, blue: 0.87, alpha: 1)
        static let green = NSColor(srgbRed: 0.34, green: 0.78, blue: 0.43, alpha: 1)
        static let red = NSColor(srgbRed: 0.94, green: 0.30, blue: 0.25, alpha: 1)
        static let orange = NSColor(srgbRed: 1.00, green: 0.58, blue: 0.23, alpha: 1)
        static let gold = NSColor(srgbRed: 1.00, green: 0.76, blue: 0.20, alpha: 1)
        static let purple = NSColor(srgbRed: 0.48, green: 0.42, blue: 0.90, alpha: 1)
        static let pink = NSColor(srgbRed: 0.94, green: 0.38, blue: 0.58, alpha: 1)
        static let steel = NSColor(srgbRed: 0.24, green: 0.29, blue: 0.36, alpha: 1)
    }

    // MARK: - 渲染基础

    /// Finder 会在非主线程序列化菜单图标（TIFF），因此必须立即渲染成位图，
    /// 绝不能使用 NSImage(size:flipped:drawingHandler:) 这类延迟绘制闭包。
    private static func renderedIcon(_ draw: (NSRect) -> Void) -> NSImage {
        let image = NSImage(size: iconSize)
        for scale in [1, 2] {
            guard let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(iconSize.width) * scale,
                pixelsHigh: Int(iconSize.height) * scale,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            ) else { continue }
            rep.size = iconSize
            NSGraphicsContext.saveGraphicsState()
            if let context = NSGraphicsContext(bitmapImageRep: rep) {
                NSGraphicsContext.current = context
                // rep.size 已把 18pt 映射到对应的 1×/2× 像素尺寸；
                // NSGraphicsContext 会建立正确 CTM，不能再次手动缩放，否则
                // Retina 表示会被放大两次并只剩左下四分之一。
                NSAppearance.currentDrawing().performAsCurrentDrawingAppearance {
                    draw(NSRect(origin: .zero, size: iconSize))
                }
                context.flushGraphics()
            }
            NSGraphicsContext.restoreGraphicsState()
            image.addRepresentation(rep)
        }
        return image
    }

    /// 菜单栏专用品牌图标：从 App 图标提炼鼠标轮廓、左右键分隔和
    /// 右键点击圆环。只使用透明度蒙版，让 macOS 自动适配深浅菜单栏。
    static func statusBarImage() -> NSImage {
        if let cached = statusBarImageCache { return cached }
        let image = renderedIcon { _ in
            let ink = NSColor.black

            let mouse = NSBezierPath(
                roundedRect: NSRect(x: 4.25, y: 1.25, width: 9.5, height: 15.5),
                xRadius: 4.75,
                yRadius: 4.75
            )
            ink.setStroke()
            mouse.lineWidth = 1.45
            mouse.stroke()

            let buttons = NSBezierPath()
            buttons.move(to: NSPoint(x: 4.65, y: 10.15))
            buttons.line(to: NSPoint(x: 13.35, y: 10.15))
            buttons.move(to: NSPoint(x: 9, y: 10.15))
            buttons.line(to: NSPoint(x: 9, y: 16.15))
            buttons.lineWidth = 1.25
            buttons.lineCapStyle = .round
            ink.setStroke()
            buttons.stroke()

            let clickRing = NSBezierPath(
                ovalIn: NSRect(x: 10.35, y: 12.05, width: 2.55, height: 2.55)
            )
            clickRing.lineWidth = 0.9
            ink.setStroke()
            clickRing.stroke()

            ink.setFill()
            NSBezierPath(ovalIn: NSRect(x: 11.18, y: 12.88, width: 0.9, height: 0.9)).fill()
        }
        image.isTemplate = true
        statusBarImageCache = image
        return image
    }

    /// Finder 菜单中的统一圆角承载卡片。浅色外观使用柔白渐变，深色外观
    /// 使用石墨渐变；细描边和轻阴影保证缩至 18pt 后仍有清晰边界。
    private static func drawCardBase() {
        let match = NSAppearance.currentDrawing().bestMatch(from: [.aqua, .darkAqua])
        let isDark = match == .darkAqua
        let card = NSBezierPath(
            roundedRect: NSRect(x: 1.35, y: 1.45, width: 15.3, height: 15.1),
            xRadius: 3.4,
            yRadius: 3.4
        )

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(isDark ? 0.38 : 0.18)
        shadow.shadowBlurRadius = 1.15
        shadow.shadowOffset = NSSize(width: 0, height: -0.55)
        shadow.set()
        let top = isDark
            ? NSColor(srgbRed: 0.25, green: 0.27, blue: 0.31, alpha: 1)
            : NSColor.white
        let bottom = isDark
            ? NSColor(srgbRed: 0.15, green: 0.17, blue: 0.20, alpha: 1)
            : NSColor(srgbRed: 0.96, green: 0.97, blue: 0.99, alpha: 1)
        NSGradient(starting: bottom, ending: top)?.draw(in: card, angle: 90)
        NSGraphicsContext.restoreGraphicsState()

        (isDark ? NSColor.white.withAlphaComponent(0.18) : NSColor.black.withAlphaComponent(0.12)).setStroke()
        card.lineWidth = 0.55
        card.stroke()
    }

    /// 把旧的 18pt 全画布坐标压入卡片内容区，统一留白和视觉重量。
    private static func scaleGlyph(by scale: CGFloat = 0.76) {
        let transform = NSAffineTransform()
        transform.translateX(by: 9, yBy: 9)
        transform.scale(by: scale)
        transform.translateX(by: -9, yBy: -9)
        transform.concat()
    }

    private static func fillGradient(
        _ path: NSBezierPath,
        from start: NSColor,
        to end: NSColor,
        angle: CGFloat = -45
    ) {
        NSGradient(starting: start, ending: end)?.draw(in: path, angle: angle)
    }

    // MARK: - 基础形状

    private static func drawFolderBase() {
        let tab = NSBezierPath(
            roundedRect: NSRect(x: 2, y: 9, width: 7.5, height: 5),
            xRadius: 1.5,
            yRadius: 1.5
        )
        fillGradient(tab, from: Palette.cyan, to: Palette.folderEdge, angle: -35)
        let body = NSBezierPath(
            roundedRect: NSRect(x: 2, y: 2.5, width: 14, height: 10),
            xRadius: 1.5,
            yRadius: 1.5
        )
        fillGradient(body, from: Palette.folder, to: Palette.folderEdge, angle: -55)
        Palette.folderEdge.withAlphaComponent(0.8).setStroke()
        body.lineWidth = 0.8
        body.stroke()
    }

    private static func drawPaperBase(ruled: Bool) {
        let paper = NSBezierPath()
        paper.move(to: NSPoint(x: 4, y: 2))
        paper.line(to: NSPoint(x: 14, y: 2))
        paper.line(to: NSPoint(x: 14, y: 12.5))
        paper.line(to: NSPoint(x: 10.5, y: 16))
        paper.line(to: NSPoint(x: 4, y: 16))
        paper.close()
        Palette.paper.setFill()
        paper.fill()
        Palette.paperEdge.setStroke()
        paper.lineWidth = 1
        paper.stroke()
        let fold = NSBezierPath()
        fold.move(to: NSPoint(x: 10.5, y: 16))
        fold.line(to: NSPoint(x: 10.5, y: 12.5))
        fold.line(to: NSPoint(x: 14, y: 12.5))
        Palette.paperEdge.setStroke()
        fold.lineWidth = 1
        fold.stroke()
        if ruled {
            let lines = NSBezierPath()
            for y in [4.8, 7.2, 9.6] {
                lines.move(to: NSPoint(x: 6, y: y))
                lines.line(to: NSPoint(x: 12, y: y))
            }
            Palette.ink.setStroke()
            lines.lineWidth = 1.1
            lines.lineCapStyle = .round
            lines.stroke()
        }
    }

    private static func strokeAccent(_ path: NSBezierPath, color: NSColor = Palette.paper, width: CGFloat = 1.7) {
        color.setStroke()
        path.lineWidth = width
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.stroke()
    }

    private static func drawPlus(center: NSPoint, arm: CGFloat, color: NSColor, width: CGFloat = 1.7) {
        let plus = NSBezierPath()
        plus.move(to: NSPoint(x: center.x - arm, y: center.y))
        plus.line(to: NSPoint(x: center.x + arm, y: center.y))
        plus.move(to: NSPoint(x: center.x, y: center.y - arm))
        plus.line(to: NSPoint(x: center.x, y: center.y + arm))
        strokeAccent(plus, color: color, width: width)
    }

    private static func drawBadge(color: NSColor, plus: Bool = true) {
        let circle = NSBezierPath(ovalIn: NSRect(x: 10, y: 1, width: 7.5, height: 7.5))
        color.setFill()
        circle.fill()
        if plus {
            drawPlus(center: NSPoint(x: 13.75, y: 4.75), arm: 2, color: Palette.paper, width: 1.5)
        }
    }

    private static func starPath(center: NSPoint, points: Int, outer: CGFloat, inner: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        let step = CGFloat.pi / CGFloat(points)
        for index in 0..<(points * 2) {
            let radius = index.isMultiple(of: 2) ? outer : inner
            let angle = CGFloat.pi / 2 + CGFloat(index) * step
            let point = NSPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
            if index == 0 {
                path.move(to: point)
            } else {
                path.line(to: point)
            }
        }
        path.close()
        return path
    }

    private static func drawArrow(
        from start: NSPoint,
        to end: NSPoint,
        headLength: CGFloat,
        color: NSColor,
        width: CGFloat = 1.7
    ) {
        let stem = NSBezierPath()
        stem.move(to: start)
        stem.line(to: end)
        strokeAccent(stem, color: color, width: width)

        let angle = atan2(end.y - start.y, end.x - start.x)
        let head = NSBezierPath()
        head.move(to: end)
        head.line(to: NSPoint(
            x: end.x - headLength * cos(angle - 0.5),
            y: end.y - headLength * sin(angle - 0.5)
        ))
        head.move(to: end)
        head.line(to: NSPoint(
            x: end.x - headLength * cos(angle + 0.5),
            y: end.y - headLength * sin(angle + 0.5)
        ))
        strokeAccent(head, color: color, width: width)
    }

    private static func drawCopyRects(front: NSColor, back: NSColor) {
        let backRect = NSBezierPath(roundedRect: NSRect(x: 3, y: 5.5, width: 9, height: 10), xRadius: 1.5, yRadius: 1.5)
        back.setFill()
        backRect.fill()
        let frontRect = NSBezierPath(roundedRect: NSRect(x: 6.5, y: 2, width: 9, height: 10), xRadius: 1.5, yRadius: 1.5)
        front.setFill()
        frontRect.fill()
    }

    private static func drawEye(open: Bool) {
        let eye = NSBezierPath(ovalIn: NSRect(x: 2, y: 5, width: 14, height: 8))
        Palette.paper.setFill()
        eye.fill()
        Palette.steel.setStroke()
        eye.lineWidth = 1.2
        eye.stroke()
        let pupil = NSBezierPath(ovalIn: NSRect(x: 6.8, y: 6.8, width: 4.4, height: 4.4))
        Palette.blue.setFill()
        pupil.fill()
        if !open {
            let slash = NSBezierPath()
            slash.move(to: NSPoint(x: 3, y: 2.5))
            slash.line(to: NSPoint(x: 15, y: 15.5))
            strokeAccent(slash, color: Palette.red, width: 1.7)
        }
    }

    // MARK: - 图标入口

    static func image(for action: FinderMenuAction) -> NSImage {
        let cacheKey = ActionImageKey(action: action, appearance: appearanceKey)
        if let cached = actionImages[cacheKey] { return cached }
        let image = renderedIcon { _ in
            drawCardBase()
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            scaleGlyph()
            switch action {
            case .copyPath:
                drawCopyRects(front: Palette.blue, back: Palette.blue.withAlphaComponent(0.35))
                let slash = NSBezierPath()
                slash.move(to: NSPoint(x: 9.2, y: 4))
                slash.line(to: NSPoint(x: 12.8, y: 10))
                strokeAccent(slash, width: 1.6)
            case .copyName:
                drawCopyRects(front: Palette.purple, back: Palette.purple.withAlphaComponent(0.35))
                NSString(string: "A").draw(
                    at: NSPoint(x: 8.7, y: 2.8),
                    withAttributes: [
                        .font: NSFont.systemFont(ofSize: 8, weight: .bold),
                        .foregroundColor: Palette.paper,
                    ]
                )
            case .copyCurrentDirectoryPath:
                drawFolderBase()
                let small = NSBezierPath(roundedRect: NSRect(x: 6.5, y: 4.5, width: 4, height: 5), xRadius: 1, yRadius: 1)
                strokeAccent(small, width: 1.3)
                let smallFront = NSBezierPath(roundedRect: NSRect(x: 8.5, y: 6, width: 4, height: 5), xRadius: 1, yRadius: 1)
                Palette.paper.withAlphaComponent(0.25).setFill()
                smallFront.fill()
                strokeAccent(smallFront, width: 1.3)
            case .cut:
                let blades = NSBezierPath()
                blades.move(to: NSPoint(x: 5.5, y: 15.5))
                blades.line(to: NSPoint(x: 12, y: 5.5))
                blades.move(to: NSPoint(x: 12.5, y: 15.5))
                blades.line(to: NSPoint(x: 6, y: 5.5))
                strokeAccent(blades, color: Palette.steel, width: 1.6)
                for x in [3.6, 10.6] {
                    let ring = NSBezierPath(ovalIn: NSRect(x: x, y: 1.5, width: 4, height: 4))
                    Palette.blue.setFill()
                    ring.fill()
                }
            case .paste:
                let board = NSBezierPath(roundedRect: NSRect(x: 3.5, y: 1.5, width: 11, height: 13.5), xRadius: 1.5, yRadius: 1.5)
                fillGradient(board, from: Palette.orange, to: Palette.gold, angle: 90)
                let clip = NSBezierPath(roundedRect: NSRect(x: 6.5, y: 13.8, width: 5, height: 2.8), xRadius: 1.2, yRadius: 1.2)
                Palette.orange.setFill()
                clip.fill()
                let sheet = NSBezierPath(roundedRect: NSRect(x: 5.2, y: 3, width: 7.6, height: 10), xRadius: 1, yRadius: 1)
                Palette.paper.setFill()
                sheet.fill()
                let lines = NSBezierPath()
                for y in [5.2, 7.4, 9.6] {
                    lines.move(to: NSPoint(x: 6.7, y: y))
                    lines.line(to: NSPoint(x: 11.3, y: y))
                }
                strokeAccent(lines, color: Palette.orange, width: 1)
            case .moveToDirectory, .chooseMoveDirectory:
                drawFolderBase()
                drawArrow(
                    from: NSPoint(x: 5.5, y: 7),
                    to: NSPoint(x: 12.5, y: 7),
                    headLength: 3,
                    color: Palette.paper
                )
            case .copyToDirectory, .chooseCopyDirectory:
                drawFolderBase()
                drawPlus(center: NSPoint(x: 9, y: 7), arm: 2.8, color: Palette.paper, width: 1.8)
            case .createTemplate:
                drawPaperBase(ruled: true)
                drawBadge(color: Palette.green)
            case .createNamedFile:
                drawPaperBase(ruled: true)
                drawBadge(color: Palette.orange)
            case .importTemplate:
                drawPaperBase(ruled: true)
                let circle = NSBezierPath(ovalIn: NSRect(x: 10, y: 1, width: 7.5, height: 7.5))
                Palette.blue.setFill()
                circle.fill()
                drawArrow(
                    from: NSPoint(x: 13.75, y: 7),
                    to: NSPoint(x: 13.75, y: 3),
                    headLength: 2,
                    color: Palette.paper,
                    width: 1.4
                )
            case .createSameNameFolder:
                drawFolderBase()
                let sheet = NSBezierPath(roundedRect: NSRect(x: 6.8, y: 4.3, width: 4.4, height: 5.6), xRadius: 0.8, yRadius: 0.8)
                Palette.paper.setFill()
                sheet.fill()
            case .openCommonDirectory:
                drawFolderBase()
                let star = starPath(center: NSPoint(x: 9, y: 7), points: 5, outer: 3.2, inner: 1.4)
                Palette.paper.setFill()
                star.fill()
            case .addCommonDirectory:
                drawFolderBase()
                drawBadge(color: Palette.green)
            case .openNewWindow, .openNewTab:
                let frame = NSBezierPath(roundedRect: NSRect(x: 2, y: 2.5, width: 14, height: 12.5), xRadius: 1.8, yRadius: 1.8)
                Palette.paper.setFill()
                frame.fill()
                NSGraphicsContext.saveGraphicsState()
                frame.addClip()
                Palette.blue.setFill()
                NSRect(x: 2, y: 11.5, width: 14, height: 3.5).fill()
                NSGraphicsContext.restoreGraphicsState()
                Palette.steel.setStroke()
                frame.lineWidth = 1
                frame.stroke()
                for (index, x) in [3.8, 6.0].enumerated() {
                    let dot = NSBezierPath(ovalIn: NSRect(x: x, y: 12.5, width: 1.6, height: 1.6))
                    (index == 0 ? Palette.red : Palette.orange).setFill()
                    dot.fill()
                }
                if action == .openNewTab {
                    drawPlus(center: NSPoint(x: 9, y: 7), arm: 2.6, color: Palette.blue, width: 1.8)
                }
            case .fileInfo:
                let circle = NSBezierPath(ovalIn: NSRect(x: 2.5, y: 2.5, width: 13, height: 13))
                Palette.blue.setFill()
                circle.fill()
                let dot = NSBezierPath(ovalIn: NSRect(x: 8.1, y: 11, width: 1.9, height: 1.9))
                Palette.paper.setFill()
                dot.fill()
                let bar = NSBezierPath(roundedRect: NSRect(x: 8.15, y: 4.5, width: 1.8, height: 5.2), xRadius: 0.9, yRadius: 0.9)
                Palette.paper.setFill()
                bar.fill()
            case .setFolderIcon:
                drawFolderBase()
                let sparkle = starPath(center: NSPoint(x: 9, y: 7), points: 4, outer: 3.4, inner: 1.2)
                Palette.paper.setFill()
                sparkle.fill()
            case .createDesktopAlias:
                let tile = NSBezierPath(roundedRect: NSRect(x: 2.5, y: 2.5, width: 13, height: 13), xRadius: 2.5, yRadius: 2.5)
                Palette.paper.setFill()
                tile.fill()
                Palette.paperEdge.setStroke()
                tile.lineWidth = 1
                tile.stroke()
                drawArrow(
                    from: NSPoint(x: 6, y: 6),
                    to: NSPoint(x: 12, y: 12),
                    headLength: 3,
                    color: Palette.purple,
                    width: 1.8
                )
            case .openWithApp:
                let screen = NSBezierPath(roundedRect: NSRect(x: 2.5, y: 2.5, width: 13, height: 13), xRadius: 2.5, yRadius: 2.5)
                Palette.blue.setFill()
                screen.fill()
                let prompt = NSBezierPath()
                prompt.move(to: NSPoint(x: 5, y: 11))
                prompt.line(to: NSPoint(x: 8, y: 8.5))
                prompt.line(to: NSPoint(x: 5, y: 6))
                prompt.move(to: NSPoint(x: 9.5, y: 5.5))
                prompt.line(to: NSPoint(x: 13, y: 5.5))
                strokeAccent(prompt, color: Palette.paper, width: 1.6)
            case .hideSelected, .hideAll:
                drawEye(open: false)
            case .showSelected, .showAll:
                drawEye(open: true)
            case .grantWritePermission:
                let shackle = NSBezierPath()
                shackle.appendArc(
                    withCenter: NSPoint(x: 9, y: 10),
                    radius: 3.2,
                    startAngle: 0,
                    endAngle: 180
                )
                strokeAccent(shackle, color: Palette.steel, width: 1.7)
                let body = NSBezierPath(roundedRect: NSRect(x: 4.5, y: 2.5, width: 9, height: 7.5), xRadius: 1.5, yRadius: 1.5)
                Palette.orange.setFill()
                body.fill()
                let keyhole = NSBezierPath(ovalIn: NSRect(x: 8, y: 5.2, width: 2, height: 2))
                Palette.paper.setFill()
                keyhole.fill()
            case .dissolveFolder:
                drawFolderBase()
                drawArrow(
                    from: NSPoint(x: 9, y: 4.5),
                    to: NSPoint(x: 9, y: 10),
                    headLength: 2.8,
                    color: Palette.paper
                )
            case .permanentDelete:
                let lid = NSBezierPath(roundedRect: NSRect(x: 3.5, y: 12.8, width: 11, height: 1.8), xRadius: 0.9, yRadius: 0.9)
                Palette.red.setFill()
                lid.fill()
                let handle = NSBezierPath(roundedRect: NSRect(x: 7, y: 14.4, width: 4, height: 1.6), xRadius: 0.8, yRadius: 0.8)
                Palette.red.setFill()
                handle.fill()
                let body = NSBezierPath()
                body.move(to: NSPoint(x: 4.5, y: 12))
                body.line(to: NSPoint(x: 13.5, y: 12))
                body.line(to: NSPoint(x: 12.5, y: 2.5))
                body.line(to: NSPoint(x: 5.5, y: 2.5))
                body.close()
                Palette.red.setFill()
                body.fill()
                let stripes = NSBezierPath()
                for x in [7.0, 9.0, 11.0] {
                    stripes.move(to: NSPoint(x: x, y: 4.5))
                    stripes.line(to: NSPoint(x: x, y: 10))
                }
                strokeAccent(stripes, width: 1.2)
            case .convertWebP, .convertHEIC, .convertJPG, .convertPNG:
                let colors: (NSColor, NSColor)
                switch action {
                case .convertWebP: colors = (Palette.purple, Palette.pink)
                case .convertHEIC: colors = (Palette.green, Palette.cyan)
                case .convertJPG: colors = (Palette.orange, Palette.gold)
                default: colors = (Palette.blue, Palette.cyan)
                }
                let photo = NSBezierPath(roundedRect: NSRect(x: 2, y: 3, width: 14, height: 12), xRadius: 2, yRadius: 2)
                fillGradient(photo, from: colors.0, to: colors.1, angle: 45)
                let mountain = NSBezierPath()
                mountain.move(to: NSPoint(x: 3.5, y: 5))
                mountain.line(to: NSPoint(x: 7, y: 9))
                mountain.line(to: NSPoint(x: 9, y: 7))
                mountain.line(to: NSPoint(x: 14.5, y: 12))
                mountain.line(to: NSPoint(x: 14.5, y: 5))
                mountain.close()
                Palette.paper.withAlphaComponent(0.76).setFill()
                mountain.fill()
                drawArrow(
                    from: NSPoint(x: 9, y: 12),
                    to: NSPoint(x: 9, y: 5),
                    headLength: 2.5,
                    color: Palette.paper,
                    width: 1.4
                )
            case .setWallpaper:
                let screen = NSBezierPath(roundedRect: NSRect(x: 1.5, y: 4, width: 15, height: 11), xRadius: 2, yRadius: 2)
                Palette.purple.setFill()
                screen.fill()
                let stand = NSBezierPath()
                stand.move(to: NSPoint(x: 9, y: 4))
                stand.line(to: NSPoint(x: 9, y: 2))
                stand.move(to: NSPoint(x: 6.5, y: 2))
                stand.line(to: NSPoint(x: 11.5, y: 2))
                strokeAccent(stand, color: Palette.steel, width: 1.5)
                let sun = NSBezierPath(ovalIn: NSRect(x: 10.5, y: 10, width: 3, height: 3))
                Palette.paper.setFill()
                sun.fill()
            }
        }
        actionImages[cacheKey] = image
        return image
    }

    static func image(for template: NewFileTemplate) -> NSImage {
        let variant = template.iconVariant ?? {
            switch template.kind {
            case .text: 1
            case .richText: 2
            case .xml: 3
            case .markdown: 1
            case .custom: 0
            }
        }()
        let cacheKey = TemplateImageKey(variant: variant, appearance: appearanceKey)
        if let cached = templateImages[cacheKey] { return cached }
        let image = renderedIcon { _ in
            drawCardBase()
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            scaleGlyph(by: 0.74)
            switch variant {
            case 1:
                drawPaperBase(ruled: true)
            case 2:
                drawPaperBase(ruled: false)
                let picture = NSBezierPath(roundedRect: NSRect(x: 6, y: 8, width: 6, height: 4.5), xRadius: 0.8, yRadius: 0.8)
                Palette.green.setFill()
                picture.fill()
                let sun = NSBezierPath(ovalIn: NSRect(x: 7, y: 10.3, width: 1.6, height: 1.6))
                Palette.paper.setFill()
                sun.fill()
                let line = NSBezierPath()
                line.move(to: NSPoint(x: 6, y: 5.5))
                line.line(to: NSPoint(x: 12, y: 5.5))
                line.move(to: NSPoint(x: 6, y: 3.8))
                line.line(to: NSPoint(x: 10.5, y: 3.8))
                strokeAccent(line, color: Palette.ink, width: 1.1)
            case 3:
                drawPaperBase(ruled: false)
                let brackets = NSBezierPath()
                brackets.move(to: NSPoint(x: 7.6, y: 5))
                brackets.line(to: NSPoint(x: 5.6, y: 8))
                brackets.line(to: NSPoint(x: 7.6, y: 11))
                brackets.move(to: NSPoint(x: 10.4, y: 5))
                brackets.line(to: NSPoint(x: 12.4, y: 8))
                brackets.line(to: NSPoint(x: 10.4, y: 11))
                strokeAccent(brackets, color: Palette.blue, width: 1.4)
            default:
                drawPaperBase(ruled: false)
                let line = NSBezierPath()
                line.move(to: NSPoint(x: 6, y: 7.5))
                line.line(to: NSPoint(x: 12, y: 7.5))
                strokeAccent(line, color: Palette.ink, width: 1.2)
            }
        }
        templateImages[cacheKey] = image
        return image
    }
}
