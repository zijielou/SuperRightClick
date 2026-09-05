import AppKit
import CryptoKit
import Darwin
import Foundation
import Security

/// Returns the code-directory hash for an on-disk bundle or a live process.
/// The host and Finder extension use the same implementation for mutual
/// authentication over their local response socket.
enum CodeIdentity {
    static func codeHash(at bundleURL: URL) -> Data? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(
            bundleURL as CFURL,
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

/// Compatibility name retained for existing tests and the confirmation server.
typealias HostCodeIdentity = CodeIdentity

/// Identifies one concrete application bundle on disk. A bundle identifier and
/// code signature identify an application build, but not a particular installed
/// copy. Binding host-UI requests to the containing app's directory entry keeps
/// another copy of the same signed app from responding to the request.
struct HostBundleIdentity: Codable, Equatable, Hashable, Sendable {
    let device: UInt64
    let inode: UInt64

    static func capture(at bundleURL: URL) -> HostBundleIdentity? {
        var status = stat()
        let path = bundleURL.standardizedFileURL.path
        guard path.withCString({ lstat($0, &status) }) == 0,
              status.st_mode & S_IFMT == S_IFDIR else { return nil }
        return HostBundleIdentity(
            device: UInt64(status.st_dev),
            inode: UInt64(status.st_ino)
        )
    }

    /// Finder extensions are embedded at
    /// `Host.app/Contents/PlugIns/Extension.appex`.
    static func containingApplicationURL(
        for extensionBundleURL: URL = Bundle.main.bundleURL
    ) -> URL? {
        let extensionURL = extensionBundleURL.standardizedFileURL
        guard extensionURL.pathExtension == "appex" else { return nil }
        let plugInsURL = extensionURL.deletingLastPathComponent()
        guard plugInsURL.lastPathComponent == "PlugIns" else { return nil }
        let contentsURL = plugInsURL.deletingLastPathComponent()
        guard contentsURL.lastPathComponent == "Contents" else { return nil }
        let applicationURL = contentsURL.deletingLastPathComponent()
        guard applicationURL.pathExtension == "app" else { return nil }
        return applicationURL
    }

    static func currentContainingApplication() -> HostBundleIdentity? {
        guard let applicationURL = containingApplicationURL() else { return nil }
        return capture(at: applicationURL)
    }
}

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

    /// 保留旧调用方的简体中文显示名称；设置界面应使用 `displayName(in:)`。
    var displayName: String { displayName(in: .simplifiedChinese) }

    func displayName(in interfaceLanguage: AppLanguage) -> String {
        let key: String
        switch self {
        case .system: key = "跟随系统"
        case .simplifiedChinese: key = "简体中文"
        case .traditionalChinese: key = "繁體中文"
        case .english: key = "English"
        }
        return Localizer.text(key, language: interfaceLanguage)
    }
}

enum Localizer {
    static func resolvedLanguage(
        _ language: AppLanguage,
        preferredLanguages: [String] = Locale.preferredLanguages
    ) -> AppLanguage {
        guard language == .system else { return language }
        let identifier = (preferredLanguages.first ?? "en")
            .replacingOccurrences(of: "_", with: "-")
            .lowercased()
        guard identifier.hasPrefix("zh") else { return .english }
        if identifier.contains("-hant")
            || identifier.contains("-tw")
            || identifier.contains("-hk")
            || identifier.contains("-mo") {
            return .traditionalChinese
        }
        return .simplifiedChinese
    }

    static func locale(for language: AppLanguage) -> Locale {
        switch resolvedLanguage(language) {
        case .system, .english:
            Locale(identifier: "en_US")
        case .simplifiedChinese:
            Locale(identifier: "zh_Hans_CN")
        case .traditionalChinese:
            Locale(identifier: "zh_Hant_TW")
        }
    }

    static func text(_ simplified: String, language: AppLanguage) -> String {
        switch resolvedLanguage(language) {
        case .simplifiedChinese, .system:
            return simplified
        case .traditionalChinese:
            return traditional[simplified] ?? simplified
        case .english:
            return english[simplified] ?? simplified
        }
    }

    static func format(
        _ simplified: String,
        language: AppLanguage,
        arguments: [CVarArg]
    ) -> String {
        String(
            format: text(simplified, language: language),
            locale: locale(for: language),
            arguments: arguments
        )
    }

    static func format(
        _ simplified: String,
        language: AppLanguage,
        _ arguments: CVarArg...
    ) -> String {
        format(simplified, language: language, arguments: arguments)
    }

    static func hasTranslation(_ simplified: String, language: AppLanguage) -> Bool {
        switch resolvedLanguage(language) {
        case .simplifiedChinese, .system:
            true
        case .traditionalChinese:
            traditional[simplified] != nil
        case .english:
            english[simplified] != nil
        }
    }

    /// 任意系统错误的本地化描述可能与 App 内语言不同。这里只显示稳定的
    /// domain/code，确保显式切换语言后不会混入另一种语言的系统文案。
    static func systemErrorText(_ error: Error, language: AppLanguage) -> String {
        let value = error as NSError
        return format(
            "系统错误（%@，代码 %@）。",
            language: language,
            value.domain,
            String(value.code)
        )
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
        "永久删除前要求确认（强烈建议）": "永久刪除前要求確認（強烈建議）",
        "永久删除不经过废纸篓；删除前会要求确认。": "永久刪除不經過垃圾桶；刪除前會要求確認。",
        "永久删除不经过废纸篓；点击菜单后将立即删除，无法撤销。": "永久刪除不經過垃圾桶；點擊選單後將立即刪除，無法復原。",
        "操作成功时播放声音": "操作成功時播放聲音",
        "剪切时临时隐藏文件": "剪下時暫時隱藏檔案",
        "排除位置（这些目录及其子目录不显示增强菜单）": "排除位置（這些目錄及其子目錄不顯示增強選單）",
        "跟随系统": "跟隨系統",
        "简体中文": "簡體中文",
        "繁體中文": "繁體中文",
        "English": "English",
        "终端": "終端機",
        "下载": "下載",
        "文稿": "文件",
        "桌面": "桌面",
        "新建 %@": "新增 %@",
        "用 %@ 打开": "使用 %@ 開啟",
        "新建%@文件": "新增 %@ 檔案",
        "删除模板“%@”？": "刪除範本「%@」？",
        "该模板及 SuperRightClick 保存的模板副本会被删除，此操作无法撤销。": "此範本及 SuperRightClick 儲存的範本副本都會被刪除，此操作無法復原。",
        "该内置模板会从新建文件菜单中删除，可通过“重置本页”恢复。": "此內建範本會從新增檔案選單中刪除，可透過「重設本頁」恢復。",
        "删除": "刪除",
        "取消": "取消",
        "选择模板文件": "選擇範本檔案",
        "关闭永久删除确认？": "關閉永久刪除確認？",
        "关闭后，点击 Finder 菜单中的“永久删除”会立即删除项目，不经过废纸篓且无法撤销。": "關閉後，點擊 Finder 選單中的「永久刪除」會立即刪除項目，不經過垃圾桶且無法復原。",
        "关闭确认": "關閉確認",
        "无法保存永久删除安全设置": "無法儲存永久刪除安全設定",
        "好": "好",
        "选择应用": "選擇應用程式",
        "选择文件夹": "選擇資料夾",
        "目录已存在": "目錄已存在",
        "该目录已在列表中：\n%@": "此目錄已在清單中：\n%@",
        "辅助功能已授权": "輔助使用已授權",
        "辅助功能未授权（新建后重命名需要）": "輔助使用未授權（新增後重新命名需要）",
        "请求辅助功能授权": "要求輔助使用授權",
        "完全磁盘访问": "完整磁碟存取權",
        "导入模板…": "匯入範本…",
        "重置本页": "重設本頁",
        "启用": "啟用",
        "在新建文件菜单中显示此模板": "在新增檔案選單中顯示此範本",
        "模板名称": "範本名稱",
        "后缀": "副檔名",
        "图标": "圖示",
        "文档": "文件",
        "文本": "文字",
        "圆形": "圓形",
        "代码": "程式碼",
        "一级菜单": "第一層選單",
        "删除此新建文件模板": "刪除此新增檔案範本",
        "名称": "名稱",
        "应用未安装，菜单中已自动隐藏": "應用程式未安裝，已自動從選單隱藏",
        "添加…": "加入…",
        "终端、Cursor 等": "終端機、Cursor 等",
        "可启停、改名、拖动排序，并为单项设置自定义图标。": "可啟用或停用、重新命名、拖曳排序，並為單一項目設定自訂圖示。",
        "自定义名称": "自訂名稱",
        "自定义图标…": "自訂圖示…",
        "恢复": "恢復",
        "有损格式质量": "有損格式品質",
        "JPG 透明背景填充色（#RRGGBB）": "JPG 透明背景填滿色（#RRGGBB）",
        "转换结果保存在源图片旁边；同名时自动追加序号。": "轉換結果儲存在來源圖片旁；同名時自動加上序號。",
        "添加排除目录…": "加入排除目錄…",
        "菜单显示名称": "選單顯示名稱",
        "换路径": "變更路徑",
        "名称可直接编辑，拖动可排序": "名稱可直接編輯，拖曳可排序",
        "打开设置": "開啟設定",
        "退出": "結束",
        "将永久删除 1 个项目，此操作不经过废纸篓且无法撤销。": "將永久刪除 1 個項目，此操作不經過垃圾桶且無法復原。",
        "将永久删除 %@ 个项目，此操作不经过废纸篓且无法撤销。": "將永久刪除 %@ 個項目，此操作不經過垃圾桶且無法復原。",
        "请输入 DELETE": "請輸入 DELETE",
        "文件名不能为空，也不能包含“/”。": "檔名不能為空，也不能包含「/」。",
        "文件名过长。": "檔名過長。",
        "文件后缀无效。": "副檔名無效。",
        "模板已不存在。": "範本已不存在。",
        "请输入文件名（可不填写后缀）": "請輸入檔名（可不填寫副檔名）",
        "未命名": "未命名",
        "没有启用的新建模板。": "沒有已啟用的新增範本。",
        "通过窗口创建新文件": "透過視窗新增檔案",
        "输入文件名，并选择文件格式。": "輸入檔名並選擇檔案格式。",
        "创建": "建立",
        "模板文件必须具有扩展名。": "範本檔案必須有副檔名。",
        "添加自定义模板": "加入自訂範本",
        "模板将复制到 SuperRightClick 的独立容器，不会修改原文件。": "範本會複製到 SuperRightClick 的獨立容器，不會修改原始檔案。",
        "模板“%@”已添加。": "已加入範本「%@」。",
        "自定义模板记录不完整。": "自訂範本記錄不完整。",
        "无法定位模板目录。": "無法找到範本目錄。",
        "不能将项目放入它自身的子目录。": "不能將項目放入其自身的子目錄。",
        "%@：%@": "%@：%@",
        "选择移动目标文件夹": "選擇移動目標資料夾",
        "选择复制目标文件夹": "選擇複製目標資料夾",
        "所选目标文件夹已失效，请重新选择。": "所選目標資料夾已失效，請重新選擇。",
        "目标文件夹已被替换或无法访问。": "目標資料夾已被替換或無法存取。",
        "一个或多个源项目已不存在或无法访问。": "一個或多個來源項目已不存在或無法存取。",
        "配置已被其他进程更新，请重试。": "設定已由其他程序更新，請重試。",
        "目录选择超时或宿主应用未响应，请确认 SuperRightClick 主应用已运行。": "資料夾選擇逾時或主應用程式未回應，請確認 SuperRightClick 主應用程式正在執行。",
        "目录选择响应无效或已过期，请重试。": "資料夾選擇回應無效或已過期，請重試。",
        "主应用无法保存所选文件夹的访问权限，请重新选择。": "主應用程式無法儲存所選資料夾的存取權限，請重新選擇。",
        "剪贴板中没有可粘贴的文件。": "剪貼簿中沒有可貼上的檔案。",
        "该目录已在常用目录中。": "此目錄已在常用目錄中。",
        "已添加到常用目录。": "已加入常用目錄。",
        "选择文件夹图标图片": "選擇資料夾圖示圖片",
        "Finder 未能设置文件夹图标。": "Finder 無法設定資料夾圖示。",
        "完成": "完成",
        "路径：%@": "路徑：%@",
        "大小：%@": "大小：%@",
        "修改：%@": "修改：%@",
        "读取失败：%@": "讀取失敗：%@",
        "找不到应用：%@": "找不到應用程式：%@",
        "无法使用“%@”打开所选项目：%@": "無法使用「%@」開啟所選項目：%@",
        "隐藏全部项目": "隱藏全部項目",
        "显示全部项目": "顯示全部項目",
        "将修改“%@”第一层的 %@ 个项目，是否继续？": "將修改「%@」第一層的 %@ 個項目，是否繼續？",
        "所选内容包含受保护路径。": "所選內容包含受保護路徑。",
        "只会为当前用户增加写入权限：\n%@": "只會為目前使用者增加寫入權限：\n%@",
        "不能解散受保护目录。": "不能解散受保護目錄。",
        "上级目录存在同名项目：\n%@": "上層目錄存在同名項目：\n%@",
        "将移动 %@ 个项目到上级目录并删除“%@”。": "將移動 %@ 個項目到上層目錄並刪除「%@」。",
        "将移动文件夹中的项目到上级目录并删除“%@”。": "將移動資料夾中的項目到上層目錄並刪除「%@」。",
        "无法回滚“%@”：%@": "無法回復「%@」：%@",
        "拒绝删除根目录、主目录或系统保护路径。": "拒絕刪除根目錄、個人專屬目錄或系統保護路徑。",
        "%@：目标已不存在或无法访问。": "%@：目標已不存在或無法存取。",
        "永久删除目标在确认期间发生变化，已取消操作。": "永久刪除目標在確認期間發生變更，已取消操作。",
        "永久删除目标在确认期间已被替换，已取消操作。": "永久刪除目標在確認期間已被替換，已取消操作。",
        "无法打开永久删除目标目录（POSIX 错误 %@）。": "無法開啟永久刪除目標目錄（POSIX 錯誤 %@）。",
        "永久删除目标在提交期间已被替换，已取消操作。": "永久刪除目標在提交期間已被替換，已取消操作。",
        "无法安全隔离永久删除目标（POSIX 错误 %@）。": "無法安全隔離永久刪除目標（POSIX 錯誤 %@）。",
        "无法生成唯一的永久删除隔离路径。": "無法產生唯一的永久刪除隔離路徑。",
        "永久删除目标身份复核失败，已恢复原路径并取消操作。": "永久刪除目標身分複核失敗，已恢復原路徑並取消操作。",
        "永久删除目标身份复核失败，且无法恢复原路径；项目保留在 %@（POSIX 错误 %@）。": "永久刪除目標身分複核失敗，且無法恢復原路徑；項目保留在 %@（POSIX 錯誤 %@）。",
        "无法删除已隔离的永久删除目标；剩余项目位于 %@（POSIX 错误 %@）。": "無法刪除已隔離的永久刪除目標；剩餘項目位於 %@（POSIX 錯誤 %@）。",
        "无法删除已隔离的永久删除目标；剩余项目位于 %@：%@": "無法刪除已隔離的永久刪除目標；剩餘項目位於 %@：%@",
        "系统未授权 SuperRightClick 控制 Finder。\n请打开「系统设置 → 隐私与安全性 → 自动化」，找到 SuperRightClickFinder 并允许其控制“访达”，然后重试。": "系統未授權 SuperRightClick 控制 Finder。\n請開啟「系統設定 → 隱私權與安全性 → 自動化」，找到 SuperRightClickFinder 並允許其控制 Finder，然後重試。",
        "Finder 自动化失败：%@": "Finder 自動化失敗：%@",
        "未知错误": "未知錯誤",
        "无法读取图片。": "無法讀取圖片。",
        "当前 macOS 不支持编码 %@。": "目前的 macOS 不支援編碼 %@。",
        "无法创建输出图片。": "無法建立輸出圖片。",
        "图片编码失败。": "圖片編碼失敗。",
        "无法关闭临时图片文件": "無法關閉暫存圖片檔案",
        "无法创建临时图片文件": "無法建立暫存圖片檔案",
        "无法创建唯一的临时图片文件。": "無法建立唯一的暫存圖片檔案。",
        "无法提交输出图片": "無法提交輸出圖片",
        "无法关闭临时图片文件（POSIX 错误 %@）。": "無法關閉暫存圖片檔案（POSIX 錯誤 %@）。",
        "无法创建临时图片文件（POSIX 错误 %@）。": "無法建立暫存圖片檔案（POSIX 錯誤 %@）。",
        "无法提交输出图片（POSIX 错误 %@）。": "無法提交輸出圖片（POSIX 錯誤 %@）。",
        "确定": "確定",
        "继续": "繼續",
        "操作失败": "操作失敗",
        "系统错误（%@，代码 %@）。": "系統錯誤（%@，代碼 %@）。",
        "%@（POSIX 错误 %@）。": "%@（POSIX 錯誤 %@）。",
        "无法检查安全目录": "無法檢查安全目錄",
        "安全目录不是当前用户所有的真实目录。": "安全目錄不是目前使用者擁有的真實目錄。",
        "无法设置安全目录权限": "無法設定安全目錄權限",
        "安全目录类型、所有者或权限无效。": "安全目錄的類型、擁有者或權限無效。",
        "无法原子更新安全文件": "無法以原子方式更新安全檔案",
        "无法创建安全文件": "無法建立安全檔案",
        "无法设置安全文件权限": "無法設定安全檔案權限",
        "无法写入安全文件": "無法寫入安全檔案",
        "安全文件写入未完成。": "安全檔案寫入未完成。",
        "无法同步安全文件": "無法同步安全檔案",
        "无法读取安全文件": "無法讀取安全檔案",
        "无法检查安全文件": "無法檢查安全檔案",
        "安全文件大小无效。": "安全檔案大小無效。",
        "安全文件读取不完整。": "安全檔案讀取不完整。",
        "无法复核安全文件": "無法複核安全檔案",
        "安全文件在读取期间发生变化。": "安全檔案在讀取期間發生變更。",
        "安全文件路径在读取期间发生变化。": "安全檔案路徑在讀取期間發生變更。",
        "安全文件不是普通文件。": "安全檔案不是一般檔案。",
        "安全文件不属于当前用户。": "安全檔案不屬於目前使用者。",
        "安全文件存在异常硬链接。": "安全檔案存在異常硬連結。",
        "安全文件权限过宽。": "安全檔案權限過寬。",
        "本地确认通道路径过长。": "本機確認通道路徑過長。",
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
        "永久删除前要求确认（强烈建议）": "Confirm before permanent deletion (strongly recommended)",
        "永久删除不经过废纸篓；删除前会要求确认。": "Permanent deletion bypasses Trash and asks for confirmation first.",
        "永久删除不经过废纸篓；点击菜单后将立即删除，无法撤销。": "Permanent deletion bypasses Trash and will happen immediately from the menu. It cannot be undone.",
        "操作成功时播放声音": "Play sound after successful operations",
        "剪切时临时隐藏文件": "Temporarily hide cut files",
        "排除位置（这些目录及其子目录不显示增强菜单）": "Excluded locations (hide enhanced menus in these folders)",
        "跟随系统": "Follow System",
        "简体中文": "Simplified Chinese",
        "繁體中文": "Traditional Chinese",
        "English": "English",
        "终端": "Terminal",
        "下载": "Downloads",
        "文稿": "Documents",
        "桌面": "Desktop",
        "新建 %@": "New %@",
        "用 %@ 打开": "Open with %@",
        "新建%@文件": "New %@ File",
        "删除模板“%@”？": "Delete template “%@”?",
        "该模板及 SuperRightClick 保存的模板副本会被删除，此操作无法撤销。": "This template and the copy stored by SuperRightClick will be deleted. This cannot be undone.",
        "该内置模板会从新建文件菜单中删除，可通过“重置本页”恢复。": "This built-in template will be removed from the New File menu. You can restore it with Reset This Page.",
        "删除": "Delete",
        "取消": "Cancel",
        "选择模板文件": "Choose Template File",
        "关闭永久删除确认？": "Disable Permanent Deletion Confirmation?",
        "关闭后，点击 Finder 菜单中的“永久删除”会立即删除项目，不经过废纸篓且无法撤销。": "After confirmation is disabled, choosing Delete Permanently in Finder will immediately delete items without moving them to Trash. This cannot be undone.",
        "关闭确认": "Disable Confirmation",
        "无法保存永久删除安全设置": "Could Not Save Permanent Deletion Safety Setting",
        "好": "OK",
        "选择应用": "Choose Application",
        "选择文件夹": "Choose Folder",
        "目录已存在": "Folder Already Added",
        "该目录已在列表中：\n%@": "This folder is already in the list:\n%@",
        "辅助功能已授权": "Accessibility access is granted",
        "辅助功能未授权（新建后重命名需要）": "Accessibility access is not granted (required to rename new files)",
        "请求辅助功能授权": "Request Accessibility Access",
        "完全磁盘访问": "Full Disk Access",
        "导入模板…": "Import Template…",
        "重置本页": "Reset This Page",
        "启用": "Enable",
        "在新建文件菜单中显示此模板": "Show this template in the New File menu",
        "模板名称": "Template Name",
        "后缀": "Extension",
        "图标": "Icon",
        "文档": "Document",
        "文本": "Text",
        "圆形": "Circle",
        "代码": "Code",
        "一级菜单": "Top-level Menu",
        "删除此新建文件模板": "Delete this new-file template",
        "名称": "Name",
        "应用未安装，菜单中已自动隐藏": "Application is not installed and is hidden from the menu",
        "添加…": "Add…",
        "终端、Cursor 等": "Terminal, Cursor, and others",
        "可启停、改名、拖动排序，并为单项设置自定义图标。": "Enable, rename, and drag items to reorder them, or assign a custom icon to an item.",
        "自定义名称": "Custom Name",
        "自定义图标…": "Custom Icon…",
        "恢复": "Restore",
        "有损格式质量": "Lossy Format Quality",
        "JPG 透明背景填充色（#RRGGBB）": "JPG Transparency Fill Color (#RRGGBB)",
        "转换结果保存在源图片旁边；同名时自动追加序号。": "Converted images are saved next to the source. A number is appended if the name already exists.",
        "添加排除目录…": "Add Excluded Folder…",
        "菜单显示名称": "Menu Display Name",
        "换路径": "Change Path",
        "名称可直接编辑，拖动可排序": "Edit names directly and drag to reorder",
        "打开设置": "Open Settings",
        "退出": "Quit",
        "将永久删除 1 个项目，此操作不经过废纸篓且无法撤销。": "This item will be permanently deleted without being moved to Trash. This cannot be undone.",
        "将永久删除 %@ 个项目，此操作不经过废纸篓且无法撤销。": "%@ items will be permanently deleted without being moved to Trash. This cannot be undone.",
        "请输入 DELETE": "Type DELETE to continue",
        "文件名不能为空，也不能包含“/”。": "The filename cannot be empty or contain “/”.",
        "文件名过长。": "The filename is too long.",
        "文件后缀无效。": "The file extension is invalid.",
        "模板已不存在。": "The template no longer exists.",
        "请输入文件名（可不填写后缀）": "Enter a filename (the extension is optional).",
        "未命名": "Untitled",
        "没有启用的新建模板。": "No new-file templates are enabled.",
        "通过窗口创建新文件": "Create New File",
        "输入文件名，并选择文件格式。": "Enter a filename and choose a file format.",
        "创建": "Create",
        "模板文件必须具有扩展名。": "The template file must have an extension.",
        "添加自定义模板": "Add Custom Template",
        "模板将复制到 SuperRightClick 的独立容器，不会修改原文件。": "The template will be copied into SuperRightClick's private container. The original file will not be modified.",
        "模板“%@”已添加。": "Template “%@” was added.",
        "自定义模板记录不完整。": "The custom template record is incomplete.",
        "无法定位模板目录。": "The template folder could not be located.",
        "不能将项目放入它自身的子目录。": "An item cannot be placed inside its own subfolder.",
        "%@：%@": "%@: %@",
        "选择移动目标文件夹": "Choose Move Destination",
        "选择复制目标文件夹": "Choose Copy Destination",
        "所选目标文件夹已失效，请重新选择。": "The selected destination folder is no longer valid. Choose it again.",
        "目标文件夹已被替换或无法访问。": "The destination folder was replaced or cannot be accessed.",
        "一个或多个源项目已不存在或无法访问。": "One or more source items no longer exist or cannot be accessed.",
        "配置已被其他进程更新，请重试。": "The settings changed in another process. Please try again.",
        "目录选择超时或宿主应用未响应，请确认 SuperRightClick 主应用已运行。": "Folder selection timed out or the host did not respond. Make sure the SuperRightClick app is running.",
        "目录选择响应无效或已过期，请重试。": "The folder selection response is invalid or expired. Try again.",
        "主应用无法保存所选文件夹的访问权限，请重新选择。": "The app could not preserve access to the selected folder. Choose it again.",
        "剪贴板中没有可粘贴的文件。": "The clipboard does not contain files that can be pasted.",
        "该目录已在常用目录中。": "This folder is already in Favorite Folders.",
        "已添加到常用目录。": "Added to Favorite Folders.",
        "选择文件夹图标图片": "Choose Folder Icon Image",
        "Finder 未能设置文件夹图标。": "Finder could not set the folder icon.",
        "完成": "Done",
        "路径：%@": "Path: %@",
        "大小：%@": "Size: %@",
        "修改：%@": "Modified: %@",
        "读取失败：%@": "Could not read: %@",
        "找不到应用：%@": "Application not found: %@",
        "无法使用“%@”打开所选项目：%@": "Could not open the selected items with “%@”: %@",
        "隐藏全部项目": "Hide All Items",
        "显示全部项目": "Show All Items",
        "将修改“%@”第一层的 %@ 个项目，是否继续？": "Inside “%@”, this will modify %@ items. Continue?",
        "所选内容包含受保护路径。": "The selection contains a protected path.",
        "只会为当前用户增加写入权限：\n%@": "Write permission will be added only for the current user:\n%@",
        "不能解散受保护目录。": "A protected folder cannot be dissolved.",
        "上级目录存在同名项目：\n%@": "The parent folder contains items with the same names:\n%@",
        "将移动 %@ 个项目到上级目录并删除“%@”。": "This will move %@ items to the parent folder and delete “%@”.",
        "将移动文件夹中的项目到上级目录并删除“%@”。": "This will move the folder’s items to its parent and delete “%@”.",
        "无法回滚“%@”：%@": "Could not roll back “%@”: %@",
        "拒绝删除根目录、主目录或系统保护路径。": "The root folder, home folder, and protected system paths cannot be deleted.",
        "%@：目标已不存在或无法访问。": "%@: The target no longer exists or cannot be accessed.",
        "永久删除目标在确认期间发生变化，已取消操作。": "A permanent deletion target changed during confirmation. The operation was cancelled.",
        "永久删除目标在确认期间已被替换，已取消操作。": "A permanent deletion target was replaced during confirmation. The operation was cancelled.",
        "无法打开永久删除目标目录（POSIX 错误 %@）。": "Could not open the permanent deletion target folder (POSIX error %@).",
        "永久删除目标在提交期间已被替换，已取消操作。": "A permanent deletion target was replaced during the final commit. The operation was cancelled.",
        "无法安全隔离永久删除目标（POSIX 错误 %@）。": "Could not safely isolate the permanent deletion target (POSIX error %@).",
        "无法生成唯一的永久删除隔离路径。": "Could not create a unique isolation path for permanent deletion.",
        "永久删除目标身份复核失败，已恢复原路径并取消操作。": "The isolated target failed identity verification. Its original path was restored and the operation was cancelled.",
        "永久删除目标身份复核失败，且无法恢复原路径；项目保留在 %@（POSIX 错误 %@）。": "The isolated target failed identity verification and its original path could not be restored. The item remains at %@ (POSIX error %@).",
        "无法删除已隔离的永久删除目标；剩余项目位于 %@（POSIX 错误 %@）。": "Could not delete the isolated permanent deletion target. Any remaining item is at %@ (POSIX error %@).",
        "无法删除已隔离的永久删除目标；剩余项目位于 %@：%@": "Could not delete the isolated permanent deletion target. Any remaining item is at %@: %@",
        "系统未授权 SuperRightClick 控制 Finder。\n请打开「系统设置 → 隐私与安全性 → 自动化」，找到 SuperRightClickFinder 并允许其控制“访达”，然后重试。": "SuperRightClick is not authorized to control Finder.\nOpen System Settings → Privacy & Security → Automation, find SuperRightClickFinder, allow it to control Finder, and try again.",
        "Finder 自动化失败：%@": "Finder automation failed: %@",
        "未知错误": "Unknown error",
        "无法读取图片。": "The image could not be read.",
        "当前 macOS 不支持编码 %@。": "This version of macOS does not support %@ encoding.",
        "无法创建输出图片。": "The output image could not be created.",
        "图片编码失败。": "Image encoding failed.",
        "无法关闭临时图片文件": "Could not close the temporary image file",
        "无法创建临时图片文件": "Could not create a temporary image file",
        "无法创建唯一的临时图片文件。": "A unique temporary image file could not be created.",
        "无法提交输出图片": "Could not commit the output image",
        "无法关闭临时图片文件（POSIX 错误 %@）。": "Could not close the temporary image file (POSIX error %@).",
        "无法创建临时图片文件（POSIX 错误 %@）。": "Could not create a temporary image file (POSIX error %@).",
        "无法提交输出图片（POSIX 错误 %@）。": "Could not commit the output image (POSIX error %@).",
        "确定": "OK",
        "继续": "Continue",
        "操作失败": "Operation Failed",
        "系统错误（%@，代码 %@）。": "System error (%@, code %@).",
        "%@（POSIX 错误 %@）。": "%@ (POSIX error %@).",
        "无法检查安全目录": "Could not inspect the secure folder",
        "安全目录不是当前用户所有的真实目录。": "The secure folder is not a real folder owned by the current user.",
        "无法设置安全目录权限": "Could not set secure folder permissions",
        "安全目录类型、所有者或权限无效。": "The secure folder has an invalid type, owner, or permissions.",
        "无法原子更新安全文件": "Could not atomically update the secure file",
        "无法创建安全文件": "Could not create the secure file",
        "无法设置安全文件权限": "Could not set secure file permissions",
        "无法写入安全文件": "Could not write the secure file",
        "安全文件写入未完成。": "Writing the secure file did not complete.",
        "无法同步安全文件": "Could not synchronize the secure file",
        "无法读取安全文件": "Could not read the secure file",
        "无法检查安全文件": "Could not inspect the secure file",
        "安全文件大小无效。": "The secure file size is invalid.",
        "安全文件读取不完整。": "The secure file was not read completely.",
        "无法复核安全文件": "Could not revalidate the secure file",
        "安全文件在读取期间发生变化。": "The secure file changed while it was being read.",
        "安全文件路径在读取期间发生变化。": "The secure file path changed while it was being read.",
        "安全文件不是普通文件。": "The secure file is not a regular file.",
        "安全文件不属于当前用户。": "The secure file is not owned by the current user.",
        "安全文件存在异常硬链接。": "The secure file has an unexpected hard link.",
        "安全文件权限过宽。": "The secure file permissions are too broad.",
        "本地确认通道路径过长。": "The local confirmation channel path is too long.",
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

    /// 只翻译仍保持历史默认名称和默认路径的内置目录；任何用户编辑值原样显示。
    func displayName(language: AppLanguage) -> String {
        let normalizedPath = resolvedURL.standardizedFileURL.path
        let defaults: [(path: String, name: String)] = [
            (UserPaths.homeDirectory.appendingPathComponent("Downloads").path, "下载"),
            (UserPaths.homeDirectory.appendingPathComponent("Documents").path, "文稿"),
            (UserPaths.homeDirectory.appendingPathComponent("Desktop").path, "桌面"),
        ]
        guard let builtin = defaults.first(where: {
            normalizedPath == URL(fileURLWithPath: $0.path).standardizedFileURL.path
                && name == $0.name
        }) else { return name }
        return Localizer.text(builtin.name, language: language)
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

    /// 只翻译仍保持历史默认名称的内置应用；用户改名后始终原样显示。
    func displayName(language: AppLanguage) -> String {
        if bundleIdentifier == "com.apple.Terminal", name == "终端" {
            return Localizer.text("终端", language: language)
        }
        return name
    }

    var usesDefaultTerminalName: Bool {
        bundleIdentifier == "com.apple.Terminal" && name == "终端"
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
    static let maximumTemplateCount = 512
    static let maximumDirectoryCount = 512
    static let maximumOpenWithAppCount = 512
    static let maximumActionPreferenceCount = 256
    static let maximumExcludedPathCount = 1_024

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
        // FinderMenuBuilder 会把该列表转成 Dictionary 用于排序。历史配置、
        // 手工编辑的 defaults 或损坏的跨进程数据可能含有重复 action，
        // 因此必须在任何消费者看到它之前稳定去重（保留第一项）。
        let unsupported: Set<FinderMenuAction> = [.openNewWindow, .openNewTab, .convertWebP]
        var seenActions = Set<FinderMenuAction>()
        actionPreferences = actionPreferences.filter {
            !unsupported.contains($0.action) && seenActions.insert($0.action).inserted
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

    /// 配置的唯一信任边界。无论数据来自旧 UserDefaults、共享文件
    /// 还是当前设置 UI，在它进入 Finder 菜单或文件操作前都要调用此方法。
    /// 该方法保留合法的旧数据，只移除无法由设置界面产生或会越界的值。
    func validatedAndNormalized() -> MenuConfiguration {
        var value = self

        // Every array exposed as `Identifiable` must have a unique identity before
        // SwiftUI/Finder consume it. Keep the first occurrence so normalization is
        // deterministic and never changes which row an existing binding refers to.
        let uniqueTemplates = Self.stablyDeduplicated(value.templates, by: \.id)
        value.templates = Array(uniqueTemplates.prefix(Self.maximumTemplateCount)).map { template in
            var template = template
            let trimmedName = template.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedName.isEmpty || trimmedName == "." || trimmedName == ".."
                || trimmedName.contains("/") || trimmedName.utf8.count > 255 {
                template.name = "Template"
                template.isEnabled = false
            } else {
                template.name = trimmedName
            }

            let trimmedExtension = template.fileExtension.trimmingCharacters(
                in: CharacterSet(charactersIn: ". ")
            )
            let allowedExtensionCharacters = CharacterSet.alphanumerics.union(
                CharacterSet(charactersIn: "-_")
            )
            if trimmedExtension.isEmpty || trimmedExtension.count > 20
                || !trimmedExtension.unicodeScalars.allSatisfy({
                    allowedExtensionCharacters.contains($0)
                }) {
                template.fileExtension = "txt"
                template.isEnabled = false
            } else {
                template.fileExtension = trimmedExtension
            }

            if template.kind == .custom {
                if let filename = template.storedFilename,
                   Self.isValidStoredTemplateFilename(filename) {
                    template.storedFilename = filename
                } else {
                    // 保留记录以便用户在设置中识别，但绝不允许一个不完整
                    // 或越界的自定义模板进入可执行菜单。
                    template.storedFilename = nil
                    template.isEnabled = false
                }
            } else {
                // 内置模板不需要访问模板存储目录；丢弃伪造的文件名，
                // 防止后续配置差分把它当成待删除的模板副本。
                template.storedFilename = nil
            }

            if let variant = template.iconVariant, !(0...3).contains(variant) {
                template.iconVariant = nil
            }
            return template
        }
        value.deduplicateTemplates()

        value.commonDirectories = Self.normalizedDirectories(value.commonDirectories)
        value.destinationDirectories = Self.normalizedDirectories(value.destinationDirectories)
        value.openWithApps = Self.normalizedApps(value.openWithApps)

        value.actionPreferences = Array(
            value.actionPreferences.prefix(Self.maximumActionPreferenceCount)
        ).map { preference in
            var preference = preference
            if let customName = preference.customName {
                let bounded = String(customName.prefix(512))
                preference.customName = bounded.trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty ? nil : bounded
            }
            if let customIconPath = preference.customIconPath {
                if !ManagedCustomIconStore.isControlledPath(
                    customIconPath,
                    for: preference.action
                ) {
                    preference.customIconPath = nil
                } else {
                    preference.customIconPath = URL(fileURLWithPath: customIconPath)
                        .standardizedFileURL.path
                }
            }
            return preference
        }
        value.mergeMissingDefaults()

        var seenExcludedPaths = Set<String>()
        value.excludedPaths = Array(
            value.excludedPaths.prefix(Self.maximumExcludedPathCount)
        ).compactMap { path in
            guard let normalized = Self.normalizedConfiguredPath(path),
                  seenExcludedPaths.insert(normalized).inserted else { return nil }
            return normalized
        }

        value.imageQuality = min(max(value.imageQuality, 0.1), 1)
        let background = value.jpgBackgroundHex.trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        let hex = background.hasPrefix("#") ? String(background.dropFirst()) : background
        if hex.count == 6,
           hex.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "0123456789ABCDEF").contains($0) }) {
            value.jpgBackgroundHex = "#\(hex)"
        } else {
            value.jpgBackgroundHex = "#FFFFFF"
        }
        return value
    }

    /// Returning false is intentionally different from normalization: silently
    /// truncating a newly appended item would make an import look successful and
    /// can leave an unreferenced template copy behind.
    var isWithinStorageCapacity: Bool {
        templates.count <= Self.maximumTemplateCount
            && commonDirectories.count <= Self.maximumDirectoryCount
            && destinationDirectories.count <= Self.maximumDirectoryCount
            && openWithApps.count <= Self.maximumOpenWithAppCount
            && actionPreferences.count <= Self.maximumActionPreferenceCount
            && excludedPaths.count <= Self.maximumExcludedPathCount
    }

    /// `storedFilename` 必须是单一 basename，且添加到模板根目录后仍在根目录内。
    /// 使用固定虚拟根做纯路径校验，不依赖目标文件已经存在。
    static func isValidStoredTemplateFilename(_ filename: String) -> Bool {
        guard !filename.isEmpty,
              filename != ".",
              filename != "..",
              filename.utf8.count <= 255,
              !filename.contains("/"),
              !filename.contains("\0"),
              (filename as NSString).lastPathComponent == filename else { return false }
        let root = URL(fileURLWithPath: "/SuperRightClick/Templates", isDirectory: true)
            .standardizedFileURL
        let candidate = root.appendingPathComponent(filename).standardizedFileURL
        return candidate.deletingLastPathComponent() == root
    }

    private static func normalizedDirectories(
        _ directories: [DirectoryShortcut]
    ) -> [DirectoryShortcut] {
        var seenIDs = Set<UUID>()
        var seenPaths = Set<String>()
        let unique = stablyDeduplicated(directories, by: \.id)
        return Array(unique.prefix(Self.maximumDirectoryCount)).compactMap { directory in
            guard let path = normalizedConfiguredPath(directory.path),
                  seenIDs.insert(directory.id).inserted,
                  seenPaths.insert(path).inserted else { return nil }
            var directory = directory
            directory.name = String(directory.name.prefix(512))
            directory.path = path
            return directory
        }
    }

    private static func normalizedApps(_ apps: [AppShortcut]) -> [AppShortcut] {
        var seenIDs = Set<UUID>()
        var seen = Set<String>()
        let unique = stablyDeduplicated(apps, by: \.id)
        return Array(unique.prefix(Self.maximumOpenWithAppCount)).compactMap { app in
            guard seenIDs.insert(app.id).inserted else { return nil }
            let rawPath = app.appPath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard rawPath.hasPrefix("/"), !rawPath.contains("\0") else { return nil }
            let path = URL(fileURLWithPath: rawPath).standardizedFileURL.path
            guard URL(fileURLWithPath: path).pathExtension.caseInsensitiveCompare("app") == .orderedSame
            else { return nil }
            var app = app
            app.name = String(app.name.prefix(512))
            app.appPath = path
            if let identifier = app.bundleIdentifier {
                let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
                app.bundleIdentifier = trimmed.isEmpty || trimmed.utf8.count > 255
                    || trimmed.contains("/") || trimmed.contains("\0") ? nil : trimmed
            }
            let identity = app.bundleIdentifier?.lowercased() ?? path.lowercased()
            guard seen.insert(identity).inserted else { return nil }
            return app
        }
    }

    private static func stablyDeduplicated<Element>(
        _ values: [Element],
        by identifier: KeyPath<Element, UUID>
    ) -> [Element] {
        var seen = Set<UUID>()
        return values.filter { seen.insert($0[keyPath: identifier]).inserted }
    }

    private static func normalizedConfiguredPath(_ path: String) -> String? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("\0") else { return nil }
        if trimmed == "~" { return trimmed }
        if trimmed.hasPrefix("~/") {
            let relative = String(trimmed.dropFirst(2))
            guard !relative.isEmpty else { return "~" }
            let root = URL(fileURLWithPath: "/SuperRightClick/Home", isDirectory: true)
            let candidate = root.appendingPathComponent(relative).standardizedFileURL
            guard candidate.path == root.path || candidate.path.hasPrefix(root.path + "/") else {
                return nil
            }
            return trimmed
        }
        guard trimmed.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: trimmed).standardizedFileURL.path
    }

    func preference(for action: FinderMenuAction) -> ActionPreference {
        actionPreferences.first(where: { $0.action == action })
            ?? ActionPreference(action: action)
    }

    func isActionEnabled(_ action: FinderMenuAction) -> Bool {
        preference(for: action).isEnabled
    }

    func title(for action: FinderMenuAction) -> String {
        let custom = preference(for: action).customName
        if let custom,
           !custom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return custom
        }
        return Localizer.text(action.title, language: language)
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

/// Result of reconciling an unsaved settings draft with a newer authoritative
/// configuration. Non-overlapping changes are combined. When both sides change
/// the same field differently, the visible local draft is retained and marked as
/// conflicted so it is never silently replaced or automatically persisted over
/// the other process's edit.
struct ConfigurationDraftMergeResult: Sendable, Equatable {
    let configuration: MenuConfiguration
    let hasConflicts: Bool
}

enum ConfigurationDraftMerger {
    static func merge(
        base: MenuConfiguration,
        local: MenuConfiguration,
        remote: MenuConfiguration
    ) -> ConfigurationDraftMergeResult {
        var result = remote
        var hasConflicts = false

        func resolved<Value: Equatable>(
            _ baseValue: Value,
            _ localValue: Value,
            _ remoteValue: Value
        ) -> Value {
            if localValue == baseValue { return remoteValue }
            if remoteValue == baseValue || localValue == remoteValue { return localValue }
            hasConflicts = true
            return localValue
        }

        result.templates = resolved(base.templates, local.templates, remote.templates)
        result.commonDirectories = resolved(
            base.commonDirectories,
            local.commonDirectories,
            remote.commonDirectories
        )
        result.destinationDirectories = resolved(
            base.destinationDirectories,
            local.destinationDirectories,
            remote.destinationDirectories
        )
        result.openWithApps = resolved(base.openWithApps, local.openWithApps, remote.openWithApps)
        result.autoOpenNewFile = resolved(
            base.autoOpenNewFile,
            local.autoOpenNewFile,
            remote.autoOpenNewFile
        )
        result.playCreationSound = resolved(
            base.playCreationSound,
            local.playCreationSound,
            remote.playCreationSound
        )
        result.mergeFileOperations = resolved(
            base.mergeFileOperations,
            local.mergeFileOperations,
            remote.mergeFileOperations
        )
        result.enableBulkVisibility = resolved(
            base.enableBulkVisibility,
            local.enableBulkVisibility,
            remote.enableBulkVisibility
        )
        result.enablePermissionChanges = resolved(
            base.enablePermissionChanges,
            local.enablePermissionChanges,
            remote.enablePermissionChanges
        )
        result.enableDissolveFolder = resolved(
            base.enableDissolveFolder,
            local.enableDissolveFolder,
            remote.enableDissolveFolder
        )
        result.enablePermanentDelete = resolved(
            base.enablePermanentDelete,
            local.enablePermanentDelete,
            remote.enablePermanentDelete
        )
        result.masterEnabled = resolved(
            base.masterEnabled,
            local.masterEnabled,
            remote.masterEnabled
        )
        result.actionPreferences = resolved(
            base.actionPreferences,
            local.actionPreferences,
            remote.actionPreferences
        )
        result.showMenuIcons = resolved(
            base.showMenuIcons,
            local.showMenuIcons,
            remote.showMenuIcons
        )
        result.mergeOpenWithApps = resolved(
            base.mergeOpenWithApps,
            local.mergeOpenWithApps,
            remote.mergeOpenWithApps
        )
        result.mergeImageOperations = resolved(
            base.mergeImageOperations,
            local.mergeImageOperations,
            remote.mergeImageOperations
        )
        result.excludedPaths = resolved(
            base.excludedPaths,
            local.excludedPaths,
            remote.excludedPaths
        )
        result.playOperationSound = resolved(
            base.playOperationSound,
            local.playOperationSound,
            remote.playOperationSound
        )
        result.hideCutItems = resolved(base.hideCutItems, local.hideCutItems, remote.hideCutItems)
        result.showMenuBarIcon = resolved(
            base.showMenuBarIcon,
            local.showMenuBarIcon,
            remote.showMenuBarIcon
        )
        result.language = resolved(base.language, local.language, remote.language)
        result.imageQuality = resolved(base.imageQuality, local.imageQuality, remote.imageQuality)
        result.jpgBackgroundHex = resolved(
            base.jpgBackgroundHex,
            local.jpgBackgroundHex,
            remote.jpgBackgroundHex
        )
        result.wallpaperAllScreens = resolved(
            base.wallpaperAllScreens,
            local.wallpaperAllScreens,
            remote.wallpaperAllScreens
        )

        return ConfigurationDraftMergeResult(
            configuration: result,
            hasConflicts: hasConflicts
        )
    }
}

/// Owns the versioned files used by action-specific custom menu icons. The
/// configuration commit is supplied as a closure so file replacement follows a
/// small transaction: write the new bytes, commit their path, then retire the old
/// version. A failed commit removes only the new unreferenced file.
enum ManagedCustomIconStore {
    static let directoryURL = UserPaths.homeDirectory
        .appendingPathComponent(
            "Library/Application Support/SuperRightClick/Icons",
            isDirectory: true
        )
        .standardizedFileURL

    static func isControlledPath(_ path: String, for action: FinderMenuAction) -> Bool {
        guard !path.contains("\0") else { return false }
        let candidate = URL(fileURLWithPath: path).standardizedFileURL
        guard candidate.deletingLastPathComponent() == directoryURL else { return false }
        let filename = candidate.lastPathComponent
        let legacyFilename = "\(action.rawValue).png"
        if filename == legacyFilename { return true }

        let prefix = "\(action.rawValue)-"
        guard filename.hasPrefix(prefix), filename.hasSuffix(".png") else { return false }
        let identifierStart = filename.index(filename.startIndex, offsetBy: prefix.count)
        let identifierEnd = filename.index(filename.endIndex, offsetBy: -4)
        guard identifierStart < identifierEnd else { return false }
        return UUID(uuidString: String(filename[identifierStart..<identifierEnd])) != nil
    }

    static func install(
        pngData: Data,
        for action: FinderMenuAction,
        replacing oldPath: String?,
        directory: URL = directoryURL,
        commit: (String) -> Bool
    ) throws -> Bool {
        try ensurePrivateDirectory(directory)
        let destination = directory.appendingPathComponent(
            "\(action.rawValue)-\(UUID().uuidString.lowercased()).png"
        )
        try pngData.write(to: destination, options: [.atomic])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: destination.path
        )

        guard commit(destination.path) else {
            try? FileManager.default.removeItem(at: destination)
            return false
        }
        removeControlledFileIfNeeded(oldPath, for: action, excluding: destination, directory: directory)
        return true
    }

    static func clear(
        path oldPath: String?,
        for action: FinderMenuAction,
        directory: URL = directoryURL,
        commit: () -> Bool
    ) -> Bool {
        guard commit() else { return false }
        removeControlledFileIfNeeded(oldPath, for: action, excluding: nil, directory: directory)
        return true
    }

    private static func removeControlledFileIfNeeded(
        _ path: String?,
        for action: FinderMenuAction,
        excluding retainedURL: URL?,
        directory: URL
    ) {
        guard let path else { return }
        let candidate = URL(fileURLWithPath: path).standardizedFileURL
        let productionDirectory = directoryURL
        let isControlled: Bool
        if directory.standardizedFileURL == productionDirectory {
            isControlled = isControlledPath(path, for: action)
        } else {
            // Test/custom roots retain the same strict basename grammar while
            // never permitting a path to escape the injected root.
            isControlled = candidate.deletingLastPathComponent() == directory.standardizedFileURL
                && isControlledFilename(candidate.lastPathComponent, for: action)
        }
        guard isControlled, candidate != retainedURL?.standardizedFileURL else { return }
        try? FileManager.default.removeItem(at: candidate)
    }

    private static func isControlledFilename(
        _ filename: String,
        for action: FinderMenuAction
    ) -> Bool {
        if filename == "\(action.rawValue).png" { return true }
        let prefix = "\(action.rawValue)-"
        guard filename.hasPrefix(prefix), filename.hasSuffix(".png") else { return false }
        let identifierStart = filename.index(filename.startIndex, offsetBy: prefix.count)
        let identifierEnd = filename.index(filename.endIndex, offsetBy: -4)
        return identifierStart < identifierEnd
            && UUID(uuidString: String(filename[identifierStart..<identifierEnd])) != nil
    }

    private static func ensurePrivateDirectory(_ directory: URL) throws {
        let manager = FileManager.default
        if !manager.fileExists(atPath: directory.path) {
            try manager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        var status = stat()
        guard directory.path.withCString({ lstat($0, &status) }) == 0 else {
            throw SecureFileFailure.posix("无法检查安全目录", errno)
        }
        guard (status.st_mode & S_IFMT) == S_IFDIR, status.st_uid == getuid() else {
            throw SecureFileFailure.invalid("安全目录不是当前用户所有的真实目录。")
        }
        guard directory.path.withCString({ chmod($0, 0o700) }) == 0 else {
            throw SecureFileFailure.posix("无法设置安全目录权限", errno)
        }
    }
}

struct SafetyPreferences: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var confirmBeforePermanentDelete: Bool
    var revision: UUID
    var updatedAt: Date

    static var secureDefault: SafetyPreferences {
        SafetyPreferences(
            schemaVersion: currentSchemaVersion,
            confirmBeforePermanentDelete: true,
            revision: UUID(),
            updatedAt: .distantPast
        )
    }
}

enum SecureFileFailure: LocalizedError {
    case invalid(String)
    case posix(String, Int32)

    var errorDescription: String? {
        switch self {
        case let .invalid(message):
            message
        case let .posix(operation, code):
            "\(operation)：\(String(cString: strerror(code)))"
        }
    }

    func message(language: AppLanguage) -> String {
        switch self {
        case let .invalid(message):
            Localizer.text(message, language: language)
        case let .posix(operation, code):
            Localizer.format(
                "%@（POSIX 错误 %@）。",
                language: language,
                Localizer.text(operation, language: language),
                String(code)
            )
        }
    }
}

/// 安全偏好和跨进程请求共用的受控文件 I/O。所有文件均要求为当前用户所有的
/// 单硬链接普通文件，且组/其他用户无任何权限。
private enum SecureJSONFile {
    static func ensurePrivateDirectory(_ directory: URL) throws {
        let manager = FileManager.default
        if !manager.fileExists(atPath: directory.path) {
            try manager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }

        var status = stat()
        guard directory.path.withCString({ lstat($0, &status) }) == 0 else {
            throw SecureFileFailure.posix("无法检查安全目录", errno)
        }
        guard (status.st_mode & S_IFMT) == S_IFDIR,
              status.st_uid == getuid() else {
            throw SecureFileFailure.invalid("安全目录不是当前用户所有的真实目录。")
        }
        guard directory.path.withCString({ chmod($0, 0o700) }) == 0 else {
            throw SecureFileFailure.posix("无法设置安全目录权限", errno)
        }
        try validatePrivateDirectory(directory)
    }

    static func validatePrivateDirectory(_ directory: URL) throws {
        var status = stat()
        guard directory.path.withCString({ lstat($0, &status) }) == 0 else {
            throw SecureFileFailure.posix("无法检查安全目录", errno)
        }
        guard (status.st_mode & S_IFMT) == S_IFDIR,
              status.st_uid == getuid(),
              status.st_mode & mode_t(0o077) == 0 else {
            throw SecureFileFailure.invalid("安全目录类型、所有者或权限无效。")
        }
    }

    static func writeReplacing(_ data: Data, to url: URL) throws {
        try ensurePrivateDirectory(url.deletingLastPathComponent())
        let temporaryURL = url.deletingLastPathComponent().appendingPathComponent(
            ".\(url.lastPathComponent).\(UUID().uuidString).tmp"
        )
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        try writeExclusive(data, to: temporaryURL, prepareDirectory: false)
        guard temporaryURL.path.withCString({ temporaryPath in
            url.path.withCString { destinationPath in
                rename(temporaryPath, destinationPath)
            }
        }) == 0 else {
            throw SecureFileFailure.posix("无法原子更新安全文件", errno)
        }
        _ = try read(url, maximumSize: max(1, data.count))
        syncDirectory(url.deletingLastPathComponent())
    }

    static func writeExclusive(
        _ data: Data,
        to url: URL,
        prepareDirectory: Bool = true
    ) throws {
        if prepareDirectory {
            try ensurePrivateDirectory(url.deletingLastPathComponent())
        }
        let descriptor = url.path.withCString {
            open($0, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, mode_t(0o600))
        }
        guard descriptor >= 0 else {
            throw SecureFileFailure.posix("无法创建安全文件", errno)
        }
        var shouldRemove = true
        defer {
            _ = close(descriptor)
            if shouldRemove { try? FileManager.default.removeItem(at: url) }
        }

        guard fchmod(descriptor, mode_t(0o600)) == 0 else {
            throw SecureFileFailure.posix("无法设置安全文件权限", errno)
        }
        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset
                )
                if written < 0 {
                    if errno == EINTR { continue }
                    throw SecureFileFailure.posix("无法写入安全文件", errno)
                }
                guard written > 0 else {
                    throw SecureFileFailure.invalid("安全文件写入未完成。")
                }
                offset += written
            }
        }
        guard fsync(descriptor) == 0 else {
            throw SecureFileFailure.posix("无法同步安全文件", errno)
        }
        shouldRemove = false
    }

    static func read(_ url: URL, maximumSize: Int) throws -> Data {
        let descriptor = url.path.withCString { open($0, O_RDONLY | O_NOFOLLOW) }
        guard descriptor >= 0 else {
            throw SecureFileFailure.posix("无法读取安全文件", errno)
        }
        defer { _ = close(descriptor) }

        var initial = stat()
        guard fstat(descriptor, &initial) == 0 else {
            throw SecureFileFailure.posix("无法检查安全文件", errno)
        }
        try validateRegularFile(initial)
        guard initial.st_size > 0, initial.st_size <= off_t(maximumSize) else {
            throw SecureFileFailure.invalid("安全文件大小无效。")
        }

        let expectedCount = Int(initial.st_size)
        var data = Data(count: expectedCount)
        let readCount = try data.withUnsafeMutableBytes { bytes -> Int in
            guard let baseAddress = bytes.baseAddress else { return 0 }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.read(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset
                )
                if count < 0 {
                    if errno == EINTR { continue }
                    throw SecureFileFailure.posix("无法读取安全文件", errno)
                }
                if count == 0 { break }
                offset += count
            }
            return offset
        }
        guard readCount == expectedCount else {
            throw SecureFileFailure.invalid("安全文件读取不完整。")
        }

        var final = stat()
        guard fstat(descriptor, &final) == 0 else {
            throw SecureFileFailure.posix("无法复核安全文件", errno)
        }
        try validateRegularFile(final)
        guard initial.st_dev == final.st_dev,
              initial.st_ino == final.st_ino,
              initial.st_size == final.st_size,
              initial.st_mtimespec.tv_sec == final.st_mtimespec.tv_sec,
              initial.st_mtimespec.tv_nsec == final.st_mtimespec.tv_nsec else {
            throw SecureFileFailure.invalid("安全文件在读取期间发生变化。")
        }

        var pathStatus = stat()
        guard url.path.withCString({ lstat($0, &pathStatus) }) == 0,
              pathStatus.st_dev == final.st_dev,
              pathStatus.st_ino == final.st_ino else {
            throw SecureFileFailure.invalid("安全文件路径在读取期间发生变化。")
        }
        return data
    }

    private static func validateRegularFile(_ status: stat) throws {
        guard (status.st_mode & S_IFMT) == S_IFREG else {
            throw SecureFileFailure.invalid("安全文件不是普通文件。")
        }
        guard status.st_uid == getuid() else {
            throw SecureFileFailure.invalid("安全文件不属于当前用户。")
        }
        guard status.st_nlink == 1 else {
            throw SecureFileFailure.invalid("安全文件存在异常硬链接。")
        }
        guard status.st_mode & mode_t(0o077) == 0 else {
            throw SecureFileFailure.invalid("安全文件权限过宽。")
        }
    }

    private static func syncDirectory(_ directory: URL) {
        let descriptor = directory.path.withCString { open($0, O_RDONLY) }
        guard descriptor >= 0 else { return }
        _ = fsync(descriptor)
        _ = close(descriptor)
    }
}

/// 危险操作偏好的唯一来源。主 App 写入，Finder 扩展每次操作即时读取；
/// 任何读取或校验失败都会安全降级为“必须确认”。
struct SafetyPreferencesStore: Sendable {
    static let didChangeNotification = Notification.Name(
        "local.SuperRightClick.safetyPreferences.updatedInProcess"
    )

    let directoryURL: URL

    static var production: SafetyPreferencesStore {
        SafetyPreferencesStore(
            directoryURL: UserPaths.homeDirectory
                .appendingPathComponent("Library/Application Support", isDirectory: true)
                .appendingPathComponent("SuperRightClick", isDirectory: true)
        )
    }

    var fileURL: URL {
        directoryURL.appendingPathComponent("SafetyPreferences.json")
    }

    func load() -> SafetyPreferences {
        guard (try? SecureJSONFile.validatePrivateDirectory(directoryURL)) != nil,
              let data = try? SecureJSONFile.read(fileURL, maximumSize: 64 * 1024),
              let value = try? JSONDecoder().decode(SafetyPreferences.self, from: data),
              value.schemaVersion == SafetyPreferences.currentSchemaVersion else {
            return .secureDefault
        }
        return value
    }

    @discardableResult
    func save(confirmBeforePermanentDelete: Bool) throws -> SafetyPreferences {
        let value = SafetyPreferences(
            schemaVersion: SafetyPreferences.currentSchemaVersion,
            confirmBeforePermanentDelete: confirmBeforePermanentDelete,
            revision: UUID(),
            updatedAt: Date()
        )
        let data = try JSONEncoder().encode(value)
        try SecureJSONFile.writeReplacing(data, to: fileURL)
        NotificationCenter.default.post(
            name: Self.didChangeNotification,
            object: value
        )
        return value
    }

    static func observeLocalUpdates(
        handler: @escaping @MainActor @Sendable (SafetyPreferences) -> Void
    ) -> NSObjectProtocol {
        NotificationCenter.default.addObserver(
            forName: didChangeNotification,
            object: nil,
            queue: .main
        ) { notification in
            guard let value = notification.object as? SafetyPreferences else { return }
            MainActor.assumeIsolated { handler(value) }
        }
    }
}

enum DestructiveConfirmationAction: String, Codable, Sendable {
    case permanentDelete
}

enum DestructiveConfirmationMode: String, Codable, Sendable {
    case standard
    case typeDelete
}

struct DestructiveConfirmationRequest: Codable, Equatable, Sendable {
    let id: UUID
    let createdAt: Date
    let action: DestructiveConfirmationAction
    let paths: [String]
    let confirmationMode: DestructiveConfirmationMode
    let replySocketPath: String
    let containingHostBundleIdentity: HostBundleIdentity?

    init(
        id: UUID,
        createdAt: Date,
        action: DestructiveConfirmationAction,
        paths: [String],
        confirmationMode: DestructiveConfirmationMode,
        replySocketPath: String,
        containingHostBundleIdentity: HostBundleIdentity? =
            HostBundleIdentity.currentContainingApplication()
    ) {
        self.id = id
        self.createdAt = createdAt
        self.action = action
        self.paths = paths
        self.confirmationMode = confirmationMode
        self.replySocketPath = replySocketPath
        self.containingHostBundleIdentity = containingHostBundleIdentity
    }

    /// Binds an authenticated reply to the exact request context parsed and shown by the host.
    var authenticationDigest: Data {
        var canonical = Data()
        func appendField(_ data: Data) {
            var length = UInt64(data.count).bigEndian
            withUnsafeBytes(of: &length) { canonical.append(contentsOf: $0) }
            canonical.append(data)
        }
        func appendString(_ value: String) {
            appendField(Data(value.utf8))
        }

        appendString("SuperRightClick.DestructiveConfirmationRequest.v2")
        var identifier = id.uuid
        appendField(withUnsafeBytes(of: &identifier) { Data($0) })
        var timestamp = createdAt.timeIntervalSinceReferenceDate.bitPattern.bigEndian
        appendField(withUnsafeBytes(of: &timestamp) { Data($0) })
        appendString(action.rawValue)
        var pathCount = UInt64(paths.count).bigEndian
        appendField(withUnsafeBytes(of: &pathCount) { Data($0) })
        paths.forEach(appendString)
        appendString(confirmationMode.rawValue)
        appendString(replySocketPath)
        if let containingHostBundleIdentity {
            appendString("host-present")
            var device = containingHostBundleIdentity.device.bigEndian
            appendField(withUnsafeBytes(of: &device) { Data($0) })
            var inode = containingHostBundleIdentity.inode.bigEndian
            appendField(withUnsafeBytes(of: &inode) { Data($0) })
        } else {
            appendString("host-missing")
        }
        return Data(SHA256.hash(data: canonical))
    }
}

struct DestructiveConfirmationResponse: Codable, Equatable, Sendable {
    let requestID: UUID
    let requestDigest: Data
    let approved: Bool
}

/// Every response accepted from the host must identify and authenticate the exact
/// request that caused the UI to be shown. The extension additionally verifies
/// the peer process' code signature before decoding one of these responses.
protocol AuthenticatedHostResponse: Codable, Sendable {
    var requestID: UUID { get }
    var requestDigest: Data { get }
}

extension DestructiveConfirmationResponse: AuthenticatedHostResponse { }

/// Shared admission policy for modal host UI. Keeping validation work in the
/// same budget as queued and displayed requests prevents a notification burst
/// from creating an unbounded number of validation tasks before the queue fills.
enum HostUIRequestAdmission {
    static let maximumOutstanding = 32

    static func canAccept(
        validating: Int,
        pending: Int,
        inFlight: Int,
        otherOutstanding: Int = 0
    ) -> Bool {
        let counts = [validating, pending, inFlight, otherOutstanding]
        guard counts.allSatisfy({ $0 >= 0 }) else { return false }
        return counts.reduce(0, +) < maximumOutstanding
    }
}

enum TransferDestinationOperation: String, Codable, Sendable {
    case copy
    case move
    case selectFolderIconImage
}

struct TransferDestinationPickerRequest: Codable, Equatable, Sendable {
    let id: UUID
    let createdAt: Date
    let operation: TransferDestinationOperation
    let sourceItemCount: Int
    let replySocketPath: String
    let containingHostBundleIdentity: HostBundleIdentity?

    init(
        id: UUID,
        createdAt: Date,
        operation: TransferDestinationOperation,
        sourceItemCount: Int,
        replySocketPath: String,
        containingHostBundleIdentity: HostBundleIdentity? =
            HostBundleIdentity.currentContainingApplication()
    ) {
        self.id = id
        self.createdAt = createdAt
        self.operation = operation
        self.sourceItemCount = sourceItemCount
        self.replySocketPath = replySocketPath
        self.containingHostBundleIdentity = containingHostBundleIdentity
    }

    /// Binds the reply to the exact operation shown by the host. Source URLs are
    /// deliberately retained by the extension and never delegated to the host.
    var authenticationDigest: Data {
        var canonical = Data()
        func appendField(_ data: Data) {
            var length = UInt64(data.count).bigEndian
            withUnsafeBytes(of: &length) { canonical.append(contentsOf: $0) }
            canonical.append(data)
        }
        func appendString(_ value: String) {
            appendField(Data(value.utf8))
        }

        appendString("SuperRightClick.TransferDestinationPickerRequest.v2")
        var identifier = id.uuid
        appendField(withUnsafeBytes(of: &identifier) { Data($0) })
        var timestamp = createdAt.timeIntervalSinceReferenceDate.bitPattern.bigEndian
        appendField(withUnsafeBytes(of: &timestamp) { Data($0) })
        appendString(operation.rawValue)
        var count = UInt64(sourceItemCount).bigEndian
        appendField(withUnsafeBytes(of: &count) { Data($0) })
        appendString(replySocketPath)
        if let containingHostBundleIdentity {
            appendString("host-present")
            var device = containingHostBundleIdentity.device.bigEndian
            appendField(withUnsafeBytes(of: &device) { Data($0) })
            var inode = containingHostBundleIdentity.inode.bigEndian
            appendField(withUnsafeBytes(of: &inode) { Data($0) })
        } else {
            appendString("host-missing")
        }
        return Data(SHA256.hash(data: canonical))
    }
}

struct TransferDestinationPickerResponse: Codable, Equatable, Sendable,
    AuthenticatedHostResponse {
    enum Outcome: String, Codable, Sendable {
        case selected
        case cancelled
        case failed
    }

    let requestID: UUID
    let requestDigest: Data
    let outcome: Outcome
    /// An implicit-scope bookmark created from the user's NSOpenPanel selection.
    /// A raw destination path is intentionally never returned across the process boundary.
    let destinationBookmark: Data?

    var isStructurallyValid: Bool {
        switch outcome {
        case .selected:
            return destinationBookmark?.isEmpty == false
                && (destinationBookmark?.count ?? 0) <= TransferDestinationPickerBridge.maximumBookmarkSize
        case .cancelled, .failed:
            return destinationBookmark == nil
        }
    }
}

enum LocalUnixSocket {
    static func address(for path: String) throws -> (sockaddr_un, socklen_t) {
        let bytes = path.utf8CString.map { UInt8(bitPattern: $0) }
        var address = sockaddr_un()
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard !bytes.isEmpty, bytes.count <= capacity else {
            throw SecureFileFailure.invalid("本地确认通道路径过长。")
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.copyBytes(from: bytes)
        }
        return (address, socklen_t(MemoryLayout<sockaddr_un>.size))
    }

    private static let exchangeTimeout: Duration = .seconds(2)
    private static let pollIntervalMilliseconds: Int32 = 100

    /// Opens a short-lived probe connection and returns the peer's signed-code
    /// identity. Closing the probe without a payload is intentional; the server
    /// continues accepting until the request deadline.
    static func peerCodeHash(at path: String) throws -> Data {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: exchangeTimeout)
        let descriptor = try connectedDescriptor(
            to: path,
            clock: clock,
            deadline: deadline
        )
        defer { _ = close(descriptor) }
        return try peerCodeHash(on: descriptor)
    }

    static func send(
        _ data: Data,
        to path: String,
        expectedPeerCodeHash: Data? = nil
    ) throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: exchangeTimeout)
        let descriptor = try connectedDescriptor(
            to: path,
            clock: clock,
            deadline: deadline
        )
        defer { _ = close(descriptor) }

        if let expectedPeerCodeHash {
            guard try peerCodeHash(on: descriptor) == expectedPeerCodeHash else {
                throw SecureFileFailure.invalid("本地确认通道对端身份无效。")
            }
        }

        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset
                )
                if written < 0 {
                    if errno == EINTR { continue }
                    if errno == EAGAIN || errno == EWOULDBLOCK {
                        let events = try waitForEvents(
                            descriptor,
                            events: Int16(POLLOUT),
                            clock: clock,
                            deadline: deadline,
                            timeoutMessage: "发送确认结果超时。"
                        )
                        let failureEvents = Int16(POLLERR | POLLHUP | POLLNVAL)
                        guard events & failureEvents == 0 else {
                            throw SecureFileFailure.invalid("本地确认通道异常关闭。")
                        }
                        continue
                    }
                    throw SecureFileFailure.posix("无法发送确认结果", errno)
                }
                guard written > 0 else {
                    throw SecureFileFailure.invalid("确认结果发送未完成。")
                }
                offset += written
            }
        }
        guard shutdown(descriptor, SHUT_WR) == 0 else {
            throw SecureFileFailure.posix("无法完成确认结果发送", errno)
        }
        try waitForPeerClosure(descriptor, clock: clock, deadline: deadline)
    }

    private static func connectedDescriptor(
        to path: String,
        clock: ContinuousClock,
        deadline: ContinuousClock.Instant
    ) throws -> Int32 {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw SecureFileFailure.posix("无法创建本地确认连接", errno)
        }
        var shouldClose = true
        defer {
            if shouldClose { _ = close(descriptor) }
        }

        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0,
              fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw SecureFileFailure.posix("无法配置本地确认连接", errno)
        }
        var noSigPipe: Int32 = 1
        guard setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSigPipe,
            socklen_t(MemoryLayout<Int32>.size)
        ) == 0 else {
            throw SecureFileFailure.posix("无法保护本地确认连接", errno)
        }

        var (address, length) = try address(for: path)
        let connectResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, length)
            }
        }
        if connectResult != 0 {
            let connectError = errno
            guard connectError == EINPROGRESS ||
                    connectError == EALREADY ||
                    connectError == EAGAIN ||
                    connectError == EWOULDBLOCK ||
                    connectError == EINTR else {
                throw SecureFileFailure.posix("无法连接本地确认通道", connectError)
            }
            let events = try waitForEvents(
                descriptor,
                events: Int16(POLLOUT),
                clock: clock,
                deadline: deadline,
                timeoutMessage: "连接本地确认通道超时。"
            )
            var socketError: Int32 = 0
            var socketErrorSize = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(
                descriptor,
                SOL_SOCKET,
                SO_ERROR,
                &socketError,
                &socketErrorSize
            ) == 0 else {
                throw SecureFileFailure.posix("无法检查本地确认连接", errno)
            }
            guard socketError == 0 else {
                throw SecureFileFailure.posix("无法连接本地确认通道", socketError)
            }
            guard events & Int16(POLLOUT) != 0 else {
                throw SecureFileFailure.invalid("本地确认通道连接异常。")
            }
        }
        shouldClose = false
        return descriptor
    }

    private static func peerCodeHash(on descriptor: Int32) throws -> Data {
        var peerPID: pid_t = 0
        var peerPIDSize = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(
            descriptor,
            SOL_LOCAL,
            LOCAL_PEERPID,
            &peerPID,
            &peerPIDSize
        ) == 0 else {
            throw SecureFileFailure.posix("无法验证本地确认通道对端", errno)
        }
        guard let codeHash = CodeIdentity.codeHash(processIdentifier: peerPID) else {
            throw SecureFileFailure.invalid("无法读取本地确认通道对端签名。")
        }
        return codeHash
    }

    private static func waitForPeerClosure(
        _ descriptor: Int32,
        clock: ContinuousClock,
        deadline: ContinuousClock.Instant
    ) throws {
        var buffer = [UInt8](repeating: 0, count: 64)
        while clock.now < deadline {
            let events = try waitForEvents(
                descriptor,
                events: Int16(POLLIN | POLLHUP),
                clock: clock,
                deadline: deadline,
                timeoutMessage: "等待本地确认通道关闭超时。"
            )
            if events & Int16(POLLNVAL) != 0 {
                throw SecureFileFailure.invalid("本地确认通道已失效。")
            }
            if events & Int16(POLLIN | POLLHUP) != 0 {
                let count = buffer.withUnsafeMutableBytes {
                    Darwin.read(descriptor, $0.baseAddress, $0.count)
                }
                if count < 0 {
                    if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK {
                        continue
                    }
                    throw SecureFileFailure.posix("读取本地确认通道状态失败", errno)
                }
                if count == 0 { return }
                continue
            }
            if events & Int16(POLLERR) != 0 {
                throw SecureFileFailure.invalid("本地确认通道异常关闭。")
            }
        }
        throw SecureFileFailure.invalid("等待本地确认通道关闭超时。")
    }

    private static func waitForEvents(
        _ descriptor: Int32,
        events: Int16,
        clock: ContinuousClock,
        deadline: ContinuousClock.Instant,
        timeoutMessage: String
    ) throws -> Int16 {
        while clock.now < deadline {
            var pollDescriptor = pollfd(fd: descriptor, events: events, revents: 0)
            let pollResult = Darwin.poll(
                &pollDescriptor,
                1,
                pollIntervalMilliseconds
            )
            if pollResult < 0 {
                if errno == EINTR { continue }
                throw SecureFileFailure.posix("等待本地确认通道失败", errno)
            }
            if pollResult > 0 { return pollDescriptor.revents }
        }
        throw SecureFileFailure.invalid(timeoutMessage)
    }
}

/// 永久删除前台确认协议。路径只用于主 App 展示；真正的删除目标始终由扩展持有。
enum DestructiveConfirmationBridge {
    static let launchArgument = "--superrightclick-confirm-permanent-delete"
    static let responseTimeoutSeconds: TimeInterval = 120
    static let responseTimeout: Duration = .seconds(120)

    static func remainingResponseLifetime(
        for request: DestructiveConfirmationRequest,
        now: Date = Date()
    ) -> TimeInterval {
        min(
            responseTimeoutSeconds,
            responseTimeoutSeconds - now.timeIntervalSince(request.createdAt)
        )
    }

    private static let requestNotification = Notification.Name(
        "local.SuperRightClick.destructiveConfirmation.request"
    )
    private static let requestPrefix = "permanent-delete-"
    private static let requestSuffix = ".json"

    static func makeRequest(
        for urls: [URL],
        replySocketPath: String
    ) -> DestructiveConfirmationRequest {
        DestructiveConfirmationRequest(
            id: UUID(),
            createdAt: Date(),
            action: .permanentDelete,
            paths: urls.map { $0.standardizedFileURL.path },
            confirmationMode: urls.count > 1 ? .typeDelete : .standard,
            replySocketPath: replySocketPath
        )
    }

    static func writeRequest(
        _ request: DestructiveConfirmationRequest,
        directoryURL: URL? = nil
    ) throws -> URL {
        let directory = directoryURL ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("SuperRightClick-ConfirmationRequests", isDirectory: true)
        let url = directory.appendingPathComponent(
            "\(requestPrefix)\(request.id.uuidString)\(requestSuffix)"
        )
        try SecureJSONFile.writeExclusive(try JSONEncoder().encode(request), to: url)
        return url
    }

    static func readRequest(at url: URL, now: Date = Date()) throws -> DestructiveConfirmationRequest {
        try SecureJSONFile.validatePrivateDirectory(url.deletingLastPathComponent())
        let data = try SecureJSONFile.read(url, maximumSize: 2 * 1024 * 1024)
        let request = try JSONDecoder().decode(DestructiveConfirmationRequest.self, from: data)
        guard url.lastPathComponent == "\(requestPrefix)\(request.id.uuidString)\(requestSuffix)" else {
            throw SecureFileFailure.invalid("确认请求文件名与请求 ID 不匹配。")
        }
        let age = now.timeIntervalSince(request.createdAt)
        guard age >= -5, age < responseTimeoutSeconds else {
            throw SecureFileFailure.invalid("确认请求已过期。")
        }
        guard request.action == .permanentDelete,
              !request.paths.isEmpty,
              request.paths.allSatisfy({ $0.hasPrefix("/") }),
              request.confirmationMode == (request.paths.count > 1 ? .typeDelete : .standard),
              request.replySocketPath.hasPrefix("/"),
              !request.replySocketPath.contains("\0"),
              request.replySocketPath.utf8.count < 104
        else {
            throw SecureFileFailure.invalid("确认请求内容无效。")
        }
        return request
    }

    static func requestID(from url: URL) -> UUID? {
        let name = url.lastPathComponent
        guard name.hasPrefix(requestPrefix), name.hasSuffix(requestSuffix) else { return nil }
        let start = name.index(name.startIndex, offsetBy: requestPrefix.count)
        let end = name.index(name.endIndex, offsetBy: -requestSuffix.count)
        return UUID(uuidString: String(name[start..<end]))
    }

    static func removeRequest(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    static func postRequest(at url: URL) {
        DistributedNotificationCenter.default().postNotificationName(
            requestNotification,
            object: url.path,
            userInfo: nil,
            deliverImmediately: true
        )
    }

    static func observeRequests(
        handler: @escaping @MainActor @Sendable (URL) -> Void
    ) -> NSObjectProtocol {
        DistributedNotificationCenter.default().addObserver(
            forName: requestNotification,
            object: nil,
            queue: .main
        ) { notification in
            guard let path = notification.object as? String else { return }
            MainActor.assumeIsolated {
                handler(URL(fileURLWithPath: path).standardizedFileURL)
            }
        }
    }

    static func sendResponse(
        _ response: DestructiveConfirmationResponse,
        toSocketPath path: String,
        expectedPeerCodeHash: Data? = nil
    ) throws {
        try LocalUnixSocket.send(
            try JSONEncoder().encode(response),
            to: path,
            expectedPeerCodeHash: expectedPeerCodeHash
        )
    }

    /// Production sockets and request files must share the extension's private
    /// temporary root. Tests can still use an injected request directory and
    /// call `readRequest` independently of this production-only check.
    static func hasExpectedProductionTransport(
        _ request: DestructiveConfirmationRequest,
        requestURL: URL
    ) -> Bool {
        let requestDirectory = requestURL.deletingLastPathComponent().standardizedFileURL
        let temporaryRoot = requestDirectory.deletingLastPathComponent().standardizedFileURL
        let socketURL = URL(fileURLWithPath: request.replySocketPath).standardizedFileURL
        return request.containingHostBundleIdentity != nil
            && requestDirectory.lastPathComponent ==
                "SuperRightClick-ConfirmationRequests"
            && socketURL.deletingLastPathComponent() == temporaryRoot
            && socketURL.lastPathComponent.hasPrefix(".s")
            && socketURL.lastPathComponent.count >= 6
            && !request.replySocketPath.contains("\0")
    }
}

/// Secure request transport for UI that must be owned by the foreground host app.
///
/// Distributed notifications are only a wake-up hint. The actual request is read
/// from an owner-only file and the result is returned over an authenticated local
/// socket. A launch argument provides the lossless cold-start path.
enum TransferDestinationPickerBridge {
    static let launchArgument = "--superrightclick-choose-transfer-destination"
    static let responseTimeoutSeconds: TimeInterval = 120
    static let responseTimeout: Duration = .seconds(120)
    static let maximumBookmarkSize = 1024 * 1024

    /// Creates a short-lived bookmark for an immediate, authenticated IPC
    /// handoff. A bookmark without an explicit security scope preserves the
    /// ephemeral scope supplied by the open panel and can be consumed by the
    /// separately sandboxed Finder extension.
    static func makeEphemeralBookmark(for url: URL) throws -> Data {
        try url.bookmarkData(
            options: [.minimalBookmark],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    /// Resolves a one-shot interprocess bookmark. A stale bookmark still
    /// returns a usable, relocated URL; staleness only means a persisted copy
    /// should be regenerated. These bookmarks are never persisted, so callers
    /// must validate the returned resource itself instead of rejecting it only
    /// because `wasStale` is true.
    static func resolveEphemeralBookmark(
        _ bookmark: Data
    ) throws -> (url: URL, wasStale: Bool) {
        var wasStale = false
        let url = try URL(
            resolvingBookmarkData: bookmark,
            options: [.withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &wasStale
        )
        return (url, wasStale)
    }

    private static let requestNotification = Notification.Name(
        "local.SuperRightClick.transferDestinationPicker.request"
    )
    private static let requestPrefix = "transfer-destination-"
    private static let requestSuffix = ".json"

    static func remainingResponseLifetime(
        for request: TransferDestinationPickerRequest,
        now: Date = Date()
    ) -> TimeInterval {
        min(
            responseTimeoutSeconds,
            responseTimeoutSeconds - now.timeIntervalSince(request.createdAt)
        )
    }

    static func makeRequest(
        operation: TransferDestinationOperation,
        sourceItemCount: Int,
        replySocketPath: String
    ) -> TransferDestinationPickerRequest {
        TransferDestinationPickerRequest(
            id: UUID(),
            createdAt: Date(),
            operation: operation,
            sourceItemCount: sourceItemCount,
            replySocketPath: replySocketPath
        )
    }

    static func writeRequest(
        _ request: TransferDestinationPickerRequest,
        directoryURL: URL? = nil
    ) throws -> URL {
        let directory = directoryURL ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("SuperRightClick-HostUIRequests", isDirectory: true)
        let url = directory.appendingPathComponent(
            "\(requestPrefix)\(request.id.uuidString)\(requestSuffix)"
        )
        try SecureJSONFile.writeExclusive(try JSONEncoder().encode(request), to: url)
        return url
    }

    static func readRequest(
        at url: URL,
        now: Date = Date()
    ) throws -> TransferDestinationPickerRequest {
        try SecureJSONFile.validatePrivateDirectory(url.deletingLastPathComponent())
        let data = try SecureJSONFile.read(url, maximumSize: 64 * 1024)
        let request = try JSONDecoder().decode(TransferDestinationPickerRequest.self, from: data)
        guard url.lastPathComponent ==
                "\(requestPrefix)\(request.id.uuidString)\(requestSuffix)" else {
            throw SecureFileFailure.invalid("目录选择请求文件名与请求 ID 不匹配。")
        }
        let age = now.timeIntervalSince(request.createdAt)
        guard age >= -5, age < responseTimeoutSeconds else {
            throw SecureFileFailure.invalid("目录选择请求已过期。")
        }
        guard request.sourceItemCount > 0,
              request.sourceItemCount <= 100_000,
              request.replySocketPath.hasPrefix("/"),
              !request.replySocketPath.contains("\0"),
              request.replySocketPath.utf8.count < 104 else {
            throw SecureFileFailure.invalid("目录选择请求内容无效。")
        }
        return request
    }

    /// Production requests put the socket beside the fixed private request
    /// directory in the extension's temporary container. Tests may inject a
    /// different directory and therefore call `readRequest` without this check.
    static func hasExpectedProductionTransport(
        _ request: TransferDestinationPickerRequest,
        requestURL: URL
    ) -> Bool {
        let requestDirectory = requestURL.deletingLastPathComponent().standardizedFileURL
        let temporaryRoot = requestDirectory.deletingLastPathComponent().standardizedFileURL
        let socketURL = URL(fileURLWithPath: request.replySocketPath).standardizedFileURL
        return request.containingHostBundleIdentity != nil
            && requestDirectory.lastPathComponent == "SuperRightClick-HostUIRequests"
            && socketURL.deletingLastPathComponent() == temporaryRoot
            && socketURL.lastPathComponent.hasPrefix(".s")
            && socketURL.lastPathComponent.count >= 6
            && !request.replySocketPath.contains("\0")
    }

    static func requestID(from url: URL) -> UUID? {
        let name = url.lastPathComponent
        guard name.hasPrefix(requestPrefix), name.hasSuffix(requestSuffix) else { return nil }
        let start = name.index(name.startIndex, offsetBy: requestPrefix.count)
        let end = name.index(name.endIndex, offsetBy: -requestSuffix.count)
        return UUID(uuidString: String(name[start..<end]))
    }

    static func removeRequest(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    static func postRequest(at url: URL) {
        DistributedNotificationCenter.default().postNotificationName(
            requestNotification,
            object: url.path,
            userInfo: nil,
            deliverImmediately: true
        )
    }

    static func observeRequests(
        handler: @escaping @MainActor @Sendable (URL) -> Void
    ) -> NSObjectProtocol {
        DistributedNotificationCenter.default().addObserver(
            forName: requestNotification,
            object: nil,
            queue: .main
        ) { notification in
            guard let path = notification.object as? String else { return }
            MainActor.assumeIsolated {
                handler(URL(fileURLWithPath: path).standardizedFileURL)
            }
        }
    }

    static func sendResponse(
        _ response: TransferDestinationPickerResponse,
        toSocketPath path: String,
        expectedPeerCodeHash: Data? = nil
    ) throws {
        guard response.isStructurallyValid else {
            throw SecureFileFailure.invalid("目录选择响应内容无效。")
        }
        let data = try JSONEncoder().encode(response)
        guard data.count <= maximumBookmarkSize + 64 * 1024 else {
            throw SecureFileFailure.invalid("目录选择响应过大。")
        }
        try LocalUnixSocket.send(
            data,
            to: path,
            expectedPeerCodeHash: expectedPeerCodeHash
        )
    }
}

/// Finder 扩展与主应用之间的重命名启动协议。
/// 分布式通知只用于主应用已运行的快速路径；冷启动通过命令行参数传递，
/// 避免应用尚未注册观察者时丢失请求。
enum RenameRequestBridge {
    static let hostBundleIdentifier = "local.SuperRightClick"
    static let launchArgument = "--superrightclick-rename"
}

/// 统一持有通知观察者，并在 owner 释放时自动解除注册。
/// 通知中心会强持有 block observer；如果只保存 token 而不移除，反复创建
/// 设置窗口或 FinderSync 实例后会留下重复响应者。
final class NotificationObservationBag: @unchecked Sendable {
    private let lock = NSLock()
    private var distributedObservers: [NSObjectProtocol] = []
    private var localObservers: [NSObjectProtocol] = []

    func addDistributed(_ observer: NSObjectProtocol) {
        lock.lock()
        distributedObservers.append(observer)
        lock.unlock()
    }

    func addLocal(_ observer: NSObjectProtocol) {
        lock.lock()
        localObservers.append(observer)
        lock.unlock()
    }

    func removeAll() {
        lock.lock()
        let distributed = distributedObservers
        let local = localObservers
        distributedObservers.removeAll()
        localObservers.removeAll()
        lock.unlock()

        let distributedCenter = DistributedNotificationCenter.default()
        distributed.forEach(distributedCenter.removeObserver)
        let localCenter = NotificationCenter.default
        local.forEach(localCenter.removeObserver)
    }

    deinit {
        removeAll()
    }
}

/// A caller-owned view of the authoritative configuration. The revision travels
/// with the exact value that was loaded; unrelated loads in the same process
/// cannot advance another editor's compare-and-swap token.
struct ConfigurationSnapshot: Sendable, Equatable {
    let configuration: MenuConfiguration
    fileprivate let revision: String?
    fileprivate let isSharedStore: Bool
    let isAuthoritative: Bool
}

struct ExtensionLegacyMigrationResult: Sendable {
    let snapshot: ConfigurationSnapshot
    let isComplete: Bool
}

enum ConfigurationSaveResult: Sendable {
    case saved(ConfigurationSnapshot)
    case unchanged(ConfigurationSnapshot)
    case conflict(ConfigurationSnapshot?)
    case unavailable

    var committedSnapshot: ConfigurationSnapshot? {
        switch self {
        case let .saved(snapshot), let .unchanged(snapshot): snapshot
        case .conflict, .unavailable: nil
        }
    }
}

enum ConfigurationStore {
    private static let key = "menuConfiguration.v2"
    private static let isolatedRevisionKey = "menuConfiguration.v2.revision"
    private static let extensionLegacyMigrationKey = "menuConfiguration.sharedMigration.v1"
    private static let schemaVersion = 1
    private static let maximumConfigurationSize = 4 * 1024 * 1024
    private static let hostBundleIdentifier = "local.SuperRightClick"
    private static let updateNotification = Notification.Name("local.SuperRightClick.configuration.updated")
    private static let localUpdateNotification = Notification.Name(
        "local.SuperRightClick.configuration.updatedInProcess"
    )
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
    private static let isolatedDefaultsLock = NSLock()

    /// 不把存储元数据塞进 MenuConfiguration，避免影响 SwiftUI 的值比较。
    /// revision 在文件锁内作为 CAS token，使迟到的写入只会失败，
    /// 不会静默覆盖另一进程已经提交的新版本。
    private struct StoredEnvelope: Codable, Sendable {
        var schemaVersion: Int
        var revision: String
        var updatedAt: Date
        var writerIdentifier: String
        var configuration: MenuConfiguration
    }

    private static var sharedDirectoryURL: URL {
        UserPaths.homeDirectory
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent("SuperRightClick", isDirectory: true)
    }

    private static var sharedFileURL: URL {
        sharedDirectoryURL.appendingPathComponent("MenuConfiguration.json")
    }

    private static var sharedLockFileURL: URL {
        sharedDirectoryURL.appendingPathComponent(".MenuConfiguration.lock")
    }

    private static func usesSharedStore(_ defaults: UserDefaults) -> Bool {
        defaults === UserDefaults.standard
    }

    static func hasStoredConfiguration(defaults: UserDefaults = .standard) -> Bool {
        guard usesSharedStore(defaults) else {
            return defaults.data(forKey: key) != nil
        }
        return (try? withSharedFileLock {
            try readSharedEnvelopeLocked() != nil
        }) ?? false
    }

    static func load(defaults: UserDefaults = .standard) -> MenuConfiguration {
        loadSnapshot(defaults: defaults).configuration
    }

    static func loadSnapshot(
        defaults: UserDefaults = .standard
    ) -> ConfigurationSnapshot {
        guard usesSharedStore(defaults) else {
            isolatedDefaultsLock.lock()
            defer { isolatedDefaultsLock.unlock() }
            return isolatedSnapshotLocked(defaults: defaults)
        }

        let legacy = loadLegacy(defaults: defaults) ?? .default
        do {
            return try withSharedFileLock {
                if let envelope = try readSharedEnvelopeLocked() {
                    return snapshot(for: envelope)
                }

                // Only the containing app may choose which target's legacy
                // UserDefaults domain becomes authoritative during migration.
                guard Bundle.main.bundleIdentifier == hostBundleIdentifier else {
                    return ConfigurationSnapshot(
                        configuration: legacy,
                        revision: nil,
                        isSharedStore: true,
                        isAuthoritative: false
                    )
                }
                let envelope = makeEnvelope(configuration: legacy)
                try writeSharedEnvelopeLocked(envelope)
                return snapshot(for: envelope)
            }
        } catch {
            // The fallback is safe for display/menu continuity, but is explicitly
            // non-authoritative. Observers must never use it for template GC or
            // as the baseline of a write.
            return ConfigurationSnapshot(
                configuration: legacy,
                revision: nil,
                isSharedStore: true,
                isAuthoritative: false
            )
        }
    }

    /// Compatibility API for isolated test UserDefaults. Production shared
    /// writes must use `save(_:basedOn:)` so a stale editor cannot borrow a
    /// revision advanced by another object in the same process.
    @discardableResult
    static func save(
        _ configuration: MenuConfiguration,
        defaults: UserDefaults = .standard,
        publish: Bool = true
    ) -> Bool {
        guard !usesSharedStore(defaults) else { return false }
        let baseline = loadSnapshot(defaults: defaults)
        return save(
            configuration,
            basedOn: baseline,
            defaults: defaults,
            publish: publish
        ).committedSnapshot != nil
    }

    @discardableResult
    static func save(
        _ configuration: MenuConfiguration,
        basedOn baseline: ConfigurationSnapshot,
        defaults: UserDefaults = .standard,
        publish: Bool = true
    ) -> ConfigurationSaveResult {
        guard configuration.imageQuality.isFinite,
              configuration.isWithinStorageCapacity else { return .unavailable }
        let normalized = configuration.validatedAndNormalized()
        guard let encoded = try? JSONEncoder().encode(normalized),
              encoded.count <= maximumConfigurationSize else { return .unavailable }

        guard usesSharedStore(defaults) else {
            guard !baseline.isSharedStore, baseline.isAuthoritative,
                  let expectedRevision = baseline.revision else { return .unavailable }
            isolatedDefaultsLock.lock()
            defer { isolatedDefaultsLock.unlock() }
            let current = isolatedSnapshotLocked(defaults: defaults)
            if current.configuration == normalized {
                return .unchanged(current)
            }
            guard current.revision == expectedRevision else { return .conflict(current) }
            let revision = UUID().uuidString
            defaults.set(encoded, forKey: key)
            defaults.set(revision, forKey: isolatedRevisionKey)
            // Isolated stores never emit process/global notifications; tests and
            // previews cannot wake production observers by accident.
            return .saved(ConfigurationSnapshot(
                configuration: normalized,
                revision: revision,
                isSharedStore: false,
                isAuthoritative: true
            ))
        }
        guard baseline.isSharedStore, baseline.isAuthoritative,
              let expectedRevision = baseline.revision else { return .unavailable }

        let result: ConfigurationSaveResult
        do {
            result = try withSharedFileLock {
                guard let envelope = try readSharedEnvelopeLocked() else {
                    return .conflict(nil)
                }
                let current = snapshot(for: envelope)
                if current.configuration == normalized {
                    return .unchanged(current)
                }
                guard envelope.revision == expectedRevision else {
                    return .conflict(current)
                }
                let replacement = makeEnvelope(configuration: normalized)
                try writeSharedEnvelopeLocked(replacement)
                return .saved(snapshot(for: replacement))
            }
        } catch {
            return .unavailable
        }

        if case .saved = result {
            postLocalWake()
            if publish { postConfigurationWake() }
        }
        return result
    }

    /// Merge only data that historically lived solely in the Finder extension's
    /// preferences domain. Current shared values win conflicts; legacy entries
    /// are appended in their existing order. `nil` means every unique entry
    /// cannot be represented without crossing a configured capacity boundary.
    static func mergingLegacyExtensionAdditions(
        _ legacyConfiguration: MenuConfiguration,
        into sharedConfiguration: MenuConfiguration
    ) -> MenuConfiguration? {
        guard legacyConfiguration.isWithinStorageCapacity,
              sharedConfiguration.isWithinStorageCapacity else { return nil }
        let legacy = legacyConfiguration.validatedAndNormalized()
        var merged = sharedConfiguration.validatedAndNormalized()

        var templateIDs = Set(merged.templates.map(\.id))
        var templateKeys = Set(merged.templates.map {
            "\($0.name.lowercased())|\($0.fileExtension.lowercased())"
        })
        for template in legacy.templates where template.kind == .custom {
            guard let filename = template.storedFilename,
                  MenuConfiguration.isValidStoredTemplateFilename(filename) else { continue }
            let key = "\(template.name.lowercased())|\(template.fileExtension.lowercased())"
            guard !templateIDs.contains(template.id), !templateKeys.contains(key) else { continue }
            guard merged.templates.count < MenuConfiguration.maximumTemplateCount else {
                return nil
            }
            merged.templates.append(template)
            templateIDs.insert(template.id)
            templateKeys.insert(key)
        }

        var commonPaths = Set(merged.commonDirectories.map {
            $0.resolvedURL.standardizedFileURL.path
        })
        var commonIDs = Set(merged.commonDirectories.map(\.id))
        for directory in legacy.commonDirectories {
            let path = directory.resolvedURL.standardizedFileURL.path
            // A legacy row with the same stable identity never replaces the
            // authoritative shared row, even if its path was edited separately.
            guard !commonIDs.contains(directory.id), !commonPaths.contains(path) else { continue }
            guard merged.commonDirectories.count < MenuConfiguration.maximumDirectoryCount else {
                return nil
            }
            merged.commonDirectories.append(directory)
            commonIDs.insert(directory.id)
            commonPaths.insert(path)
        }
        return merged.validatedAndNormalized()
    }

    /// One-shot extension-domain migration. The marker is written only after a
    /// successful CAS (or after proving the shared value already contains every
    /// addition). A crash between commit and marker is harmless: the next retry
    /// observes an unchanged value and then writes the marker.
    static func migrateLegacyExtensionAdditions(
        basedOn baseline: ConfigurationSnapshot,
        defaults: UserDefaults = .standard,
        publish: Bool = true
    ) -> ExtensionLegacyMigrationResult {
        guard usesSharedStore(defaults) else {
            return ExtensionLegacyMigrationResult(snapshot: baseline, isComplete: true)
        }
        if defaults.string(forKey: extensionLegacyMigrationKey) != nil {
            return ExtensionLegacyMigrationResult(snapshot: baseline, isComplete: true)
        }
        guard baseline.isSharedStore, baseline.isAuthoritative else {
            return ExtensionLegacyMigrationResult(snapshot: baseline, isComplete: false)
        }

        guard let legacyData = defaults.data(forKey: key) else {
            return ExtensionLegacyMigrationResult(
                snapshot: baseline,
                isComplete: markExtensionLegacyMigrationComplete(
                    at: baseline,
                    defaults: defaults
                )
            )
        }
        guard legacyData.count <= maximumConfigurationSize,
              let decodedLegacy = try? JSONDecoder().decode(
                MenuConfiguration.self,
                from: legacyData
              ),
              decodedLegacy.imageQuality.isFinite,
              decodedLegacy.isWithinStorageCapacity else {
            return ExtensionLegacyMigrationResult(snapshot: baseline, isComplete: false)
        }

        var workingSnapshot = baseline
        for _ in 0..<3 {
            guard let merged = mergingLegacyExtensionAdditions(
                decodedLegacy,
                into: workingSnapshot.configuration
            ) else {
                return ExtensionLegacyMigrationResult(
                    snapshot: workingSnapshot,
                    isComplete: false
                )
            }
            let result = save(
                merged,
                basedOn: workingSnapshot,
                defaults: defaults,
                publish: publish
            )
            if let committed = result.committedSnapshot {
                return ExtensionLegacyMigrationResult(
                    snapshot: committed,
                    isComplete: markExtensionLegacyMigrationComplete(
                        at: committed,
                        defaults: defaults
                    )
                )
            }
            if case let .conflict(latest?) = result {
                workingSnapshot = latest
                continue
            }
            return ExtensionLegacyMigrationResult(
                snapshot: workingSnapshot,
                isComplete: false
            )
        }
        return ExtensionLegacyMigrationResult(snapshot: workingSnapshot, isComplete: false)
    }

    static func observeLocalUpdates(
        defaults: UserDefaults = .standard,
        handler: @escaping @MainActor @Sendable (MenuConfiguration) -> Void
    ) -> NSObjectProtocol {
        observeLocalSnapshots(defaults: defaults) { snapshot in
            guard snapshot.isAuthoritative else { return }
            handler(snapshot.configuration)
        }
    }

    static func observeLocalSnapshots(
        defaults: UserDefaults = .standard,
        handler: @escaping @MainActor @Sendable (ConfigurationSnapshot) -> Void
    ) -> NSObjectProtocol {
        NotificationCenter.default.addObserver(
            forName: localUpdateNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                handler(loadSnapshot(defaults: defaults))
            }
        }
    }

    static func observeUpdates(
        defaults: UserDefaults = .standard,
        handler: @escaping @MainActor @Sendable (MenuConfiguration) -> Void
    ) -> NSObjectProtocol {
        observeSnapshotUpdates(defaults: defaults) { snapshot in
            handler(snapshot.configuration)
        }
    }

    static func observeSnapshotUpdates(
        defaults: UserDefaults = .standard,
        handler: @escaping @MainActor @Sendable (ConfigurationSnapshot) -> Void
    ) -> NSObjectProtocol {
        DistributedNotificationCenter.default().addObserver(
            forName: updateNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                // Do not filter notifications from this bundle: Finder may host
                // multiple extension instances whose in-memory coordinators all
                // need the newly committed snapshot.
                let snapshot = loadSnapshot(defaults: defaults)
                guard snapshot.isAuthoritative else { return }
                postLocalWake()
                handler(snapshot)
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
                // 请求和响应都只是唤醒信号；权威值始终来自共享文件。
                let snapshot = loadSnapshot(defaults: defaults)
                if snapshot.isAuthoritative { postConfigurationWake() }
            }
        }
    }

    private static func loadLegacy(defaults: UserDefaults) -> MenuConfiguration? {
        guard let data = defaults.data(forKey: key),
              data.count <= maximumConfigurationSize,
              let value = try? JSONDecoder().decode(MenuConfiguration.self, from: data),
              value.imageQuality.isFinite else { return nil }
        return value.validatedAndNormalized()
    }

    private static func isolatedSnapshotLocked(
        defaults: UserDefaults
    ) -> ConfigurationSnapshot {
        let data = defaults.data(forKey: key)
        let revision: String
        if let storedRevision = defaults.string(forKey: isolatedRevisionKey),
           UUID(uuidString: storedRevision) != nil {
            revision = storedRevision
        } else if let data {
            revision = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        } else {
            revision = "empty"
        }
        return ConfigurationSnapshot(
            configuration: loadLegacy(defaults: defaults) ?? .default,
            revision: revision,
            isSharedStore: false,
            isAuthoritative: true
        )
    }

    private static func markExtensionLegacyMigrationComplete(
        at snapshot: ConfigurationSnapshot,
        defaults: UserDefaults
    ) -> Bool {
        guard snapshot.isSharedStore, snapshot.isAuthoritative,
              let revision = snapshot.revision else { return false }
        defaults.set(revision, forKey: extensionLegacyMigrationKey)
        return defaults.string(forKey: extensionLegacyMigrationKey) == revision
    }

    private static func makeEnvelope(configuration: MenuConfiguration) -> StoredEnvelope {
        StoredEnvelope(
            schemaVersion: schemaVersion,
            revision: UUID().uuidString,
            updatedAt: Date(),
            writerIdentifier: Bundle.main.bundleIdentifier ?? "unknown",
            configuration: configuration.validatedAndNormalized()
        )
    }

    private static func snapshot(for envelope: StoredEnvelope) -> ConfigurationSnapshot {
        ConfigurationSnapshot(
            configuration: envelope.configuration.validatedAndNormalized(),
            revision: envelope.revision,
            isSharedStore: true,
            isAuthoritative: true
        )
    }

    private static func readSharedEnvelopeLocked() throws -> StoredEnvelope? {
        guard FileManager.default.fileExists(atPath: sharedFileURL.path) else { return nil }
        let data = try SecureJSONFile.read(
            sharedFileURL,
            maximumSize: maximumConfigurationSize
        )
        if var envelope = try? JSONDecoder().decode(StoredEnvelope.self, from: data) {
            guard envelope.schemaVersion == schemaVersion,
                  UUID(uuidString: envelope.revision) != nil,
                  envelope.configuration.imageQuality.isFinite else {
                throw SecureFileFailure.invalid("共享配置元数据无效。")
            }
            envelope.configuration = envelope.configuration.validatedAndNormalized()
            return envelope
        }

        // 为早期预览版可能写入的“裸 MenuConfiguration JSON”保留一次
        // 无损迁移路径。内容摘要是稳定的临时 CAS token，下次写入会升级为 envelope。
        guard let configuration = try? JSONDecoder().decode(MenuConfiguration.self, from: data),
              configuration.imageQuality.isFinite else {
            throw SecureFileFailure.invalid("共享配置文件无效。")
        }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return StoredEnvelope(
            schemaVersion: schemaVersion,
            revision: digest,
            updatedAt: .distantPast,
            writerIdentifier: "legacy-shared-file",
            configuration: configuration.validatedAndNormalized()
        )
    }

    private static func writeSharedEnvelopeLocked(_ envelope: StoredEnvelope) throws {
        let data = try JSONEncoder().encode(envelope)
        guard data.count <= maximumConfigurationSize else {
            throw SecureFileFailure.invalid("共享配置文件过大。")
        }
        try SecureJSONFile.writeReplacing(data, to: sharedFileURL)
    }

    private static func withSharedFileLock<T>(_ body: () throws -> T) throws -> T {
        try SecureJSONFile.ensurePrivateDirectory(sharedDirectoryURL)
        let descriptor = sharedLockFileURL.path.withCString {
            open($0, O_CREAT | O_RDWR | O_NOFOLLOW, mode_t(0o600))
        }
        guard descriptor >= 0 else {
            throw SecureFileFailure.posix("无法打开共享配置锁", errno)
        }
        defer { _ = close(descriptor) }
        guard fchmod(descriptor, mode_t(0o600)) == 0 else {
            throw SecureFileFailure.posix("无法设置共享配置锁权限", errno)
        }
        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            throw SecureFileFailure.posix("无法检查共享配置锁", errno)
        }
        guard (status.st_mode & S_IFMT) == S_IFREG,
              status.st_uid == getuid(),
              status.st_nlink == 1,
              status.st_mode & mode_t(0o077) == 0 else {
            throw SecureFileFailure.invalid("共享配置锁的类型、所有者或权限无效。")
        }
        while flock(descriptor, LOCK_EX) != 0 {
            if errno == EINTR { continue }
            throw SecureFileFailure.posix("无法锁定共享配置", errno)
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try body()
    }

    private static func postLocalWake() {
        NotificationCenter.default.post(name: localUpdateNotification, object: nil)
    }

    private static func postConfigurationWake() {
        DistributedNotificationCenter.default().postNotificationName(
            updateNotification,
            object: Bundle.main.bundleIdentifier ?? "unknown",
            userInfo: nil,
            deliverImmediately: true
        )
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
