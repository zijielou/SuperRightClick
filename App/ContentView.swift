import FinderSync
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class SettingsModel: ObservableObject {
    @Published var configuration: MenuConfiguration
    private var observers: [NSObjectProtocol] = []
    private var lastSavedConfiguration: MenuConfiguration

    init() {
        let initialConfiguration = ConfigurationStore.load()
        configuration = initialConfiguration
        lastSavedConfiguration = initialConfiguration
        observers.append(ConfigurationStore.observeUpdates { [weak self] value in
            guard let self else { return }
            // 外部同步值已经持久化，先更新快照，避免 SwiftUI onChange
            // 把相同配置再次广播回 Finder 扩展。
            self.lastSavedConfiguration = value
            self.configuration = value
        })
        observers.append(ConfigurationStore.observeAppRequests())
        ConfigurationStore.requestExtensionConfiguration()
    }

    func save() {
        guard configuration != lastSavedConfiguration else { return }
        lastSavedConfiguration = configuration
        ConfigurationStore.save(configuration)
    }

    func reset() {
        configuration = .default
        save()
    }

    func resetMenuSettings() {
        let defaults = MenuConfiguration.default
        configuration.masterEnabled = defaults.masterEnabled
        configuration.actionPreferences = defaults.actionPreferences
        configuration.showMenuIcons = defaults.showMenuIcons
        configuration.mergeFileOperations = defaults.mergeFileOperations
        configuration.mergeOpenWithApps = defaults.mergeOpenWithApps
        configuration.mergeImageOperations = defaults.mergeImageOperations
        configuration.showMenuBarIcon = defaults.showMenuBarIcon
        configuration.language = defaults.language
        save()
    }

    func resetTemplates() {
        configuration.templates = MenuConfiguration.default.templates
        configuration.autoOpenNewFile = MenuConfiguration.default.autoOpenNewFile
        configuration.playCreationSound = MenuConfiguration.default.playCreationSound
        save()
    }

    func removeTemplate(id: UUID) {
        guard let index = configuration.templates.firstIndex(where: { $0.id == id }) else { return }
        let template = configuration.templates[index]
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "删除模板“\(template.name)”？"
        alert.informativeText = template.kind == .custom
            ? "该模板及 SuperRightClick 保存的模板副本会被删除，此操作无法撤销。"
            : "该内置模板会从新建文件菜单中删除，可通过“重置本页”恢复。"
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        configuration.templates.remove(at: index)
        save()
    }

    func importTemplate() {
        let panel = NSOpenPanel()
        panel.title = "选择模板文件"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        ConfigurationStore.requestTemplateImport(url)
    }

    func resetDirectories() {
        configuration.commonDirectories = MenuConfiguration.default.commonDirectories
        configuration.destinationDirectories = MenuConfiguration.default.destinationDirectories
        configuration.openWithApps = MenuConfiguration.default.openWithApps
        save()
    }

    func resetImageSettings() {
        configuration.imageQuality = MenuConfiguration.default.imageQuality
        configuration.jpgBackgroundHex = MenuConfiguration.default.jpgBackgroundHex
        configuration.wallpaperAllScreens = MenuConfiguration.default.wallpaperAllScreens
        save()
    }

    func resetAdvancedSettings() {
        let defaults = MenuConfiguration.default
        configuration.enableBulkVisibility = defaults.enableBulkVisibility
        configuration.enablePermissionChanges = defaults.enablePermissionChanges
        configuration.enableDissolveFolder = defaults.enableDissolveFolder
        configuration.enablePermanentDelete = defaults.enablePermanentDelete
        configuration.playOperationSound = defaults.playOperationSound
        configuration.hideCutItems = defaults.hideCutItems
        configuration.excludedPaths = defaults.excludedPaths
        save()
    }

    func addDirectory(common: Bool) {
        guard let url = pickDirectory() else { return }
        let list = common ? configuration.commonDirectories : configuration.destinationDirectories
        if isDuplicate(url, in: list) {
            showDuplicateAlert(path: url.path)
            return
        }
        let value = DirectoryShortcut(name: url.lastPathComponent, path: url.path)
        if common {
            configuration.commonDirectories.append(value)
        } else {
            configuration.destinationDirectories.append(value)
        }
        save()
    }

    func changeDirectoryPath(id: UUID, common: Bool) {
        guard let url = pickDirectory() else { return }
        var list = common ? configuration.commonDirectories : configuration.destinationDirectories
        guard let index = list.firstIndex(where: { $0.id == id }) else { return }
        if isDuplicate(url, in: list, excluding: id) {
            showDuplicateAlert(path: url.path)
            return
        }
        list[index].path = url.path
        if common {
            configuration.commonDirectories = list
        } else {
            configuration.destinationDirectories = list
        }
        save()
    }

    func removeDirectory(id: UUID, common: Bool) {
        if common {
            configuration.commonDirectories.removeAll { $0.id == id }
        } else {
            configuration.destinationDirectories.removeAll { $0.id == id }
        }
        save()
    }

    func addOpenWithApp() {
        let panel = NSOpenPanel()
        panel.title = "选择应用"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let path = url.standardizedFileURL.path
        if configuration.openWithApps.contains(where: {
            URL(fileURLWithPath: $0.appPath).standardizedFileURL.path == path
        }) {
            showDuplicateAlert(path: path)
            return
        }
        let name = url.deletingPathExtension().lastPathComponent
        configuration.openWithApps.append(AppShortcut(
            name: name,
            appPath: url.path,
            bundleIdentifier: Bundle(url: url)?.bundleIdentifier
        ))
        save()
    }

    func removeOpenWithApp(id: UUID) {
        configuration.openWithApps.removeAll { $0.id == id }
        save()
    }

    func addExcludedPath() {
        guard let url = pickDirectory() else { return }
        let path = url.standardizedFileURL.path
        guard !configuration.excludedPaths.contains(path) else {
            return showDuplicateAlert(path: path)
        }
        configuration.excludedPaths.append(path)
        save()
    }

    func chooseCustomIcon(for action: FinderMenuAction) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, let source = panel.url,
              let image = NSImage(contentsOf: source),
              image.size.width > 0, image.size.height > 0 else { return }
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/SuperRightClick/Icons", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = directory.appendingPathComponent("\(action.rawValue).png")
            let resized = NSImage(size: NSSize(width: 128, height: 128))
            let scale = min(128 / image.size.width, 128 / image.size.height)
            let drawSize = NSSize(width: image.size.width * scale, height: image.size.height * scale)
            let drawRect = NSRect(
                x: (128 - drawSize.width) / 2,
                y: (128 - drawSize.height) / 2,
                width: drawSize.width,
                height: drawSize.height
            )
            resized.lockFocus()
            image.draw(
                in: drawRect,
                from: .zero,
                operation: .sourceOver,
                fraction: 1
            )
            resized.unlockFocus()
            guard let tiff = resized.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:]) else { return }
            try png.write(to: destination, options: .atomic)
            if let index = configuration.actionPreferences.firstIndex(where: { $0.action == action }) {
                configuration.actionPreferences[index].customIconPath = destination.path
            }
            save()
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
        }
    }

    func clearCustomIcon(for action: FinderMenuAction) {
        if let index = configuration.actionPreferences.firstIndex(where: { $0.action == action }) {
            let expectedURL = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/SuperRightClick/Icons", isDirectory: true)
                .appendingPathComponent("\(action.rawValue).png")
                .standardizedFileURL
            if let storedPath = configuration.actionPreferences[index].customIconPath,
               URL(fileURLWithPath: storedPath).standardizedFileURL == expectedURL {
                try? FileManager.default.removeItem(at: expectedURL)
            }
            configuration.actionPreferences[index].customIconPath = nil
            save()
        }
    }

    private func pickDirectory() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url
    }

    private func isDuplicate(_ url: URL, in list: [DirectoryShortcut], excluding id: UUID? = nil) -> Bool {
        let path = url.standardizedFileURL.path
        return list.contains { $0.id != id && $0.resolvedURL.standardizedFileURL.path == path }
    }

    private func showDuplicateAlert(path: String) {
        let alert = NSAlert()
        alert.messageText = "目录已存在"
        alert.informativeText = "该目录已在列表中：\n\(path)"
        alert.addButton(withTitle: "好")
        alert.runModal()
    }
}

struct ContentView: View {
    @State private var isExtensionEnabled = FIFinderSyncController.isExtensionEnabled
    @State private var isAccessibilityTrusted = CGPreflightPostEventAccess()
    @StateObject private var model = SettingsModel()

    var body: some View {
        TabView {
            statusView
                .tabItem { Text(t("状态")) }
            templatesView
                .tabItem { Text(t("新建文件")) }
            directoriesView
                .tabItem { Text(t("目录")) }
            menuSettingsView
                .tabItem { Text(t("菜单")) }
            imageSettingsView
                .tabItem { Text(t("图片")) }
            safetyView
                .tabItem { Text(t("高级")) }
        }
        .padding(20)
        .frame(minWidth: 820, minHeight: 600)
        .onAppear(perform: refreshExtensionStatus)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshExtensionStatus()
        }
    }

    private var statusView: some View {
        VStack(spacing: 20) {
            Text("SuperRightClick").font(.largeTitle.bold())
            Text(t(isExtensionEnabled ? "Finder 扩展已启用" : "Finder 扩展尚未启用"))
                .foregroundStyle(isExtensionEnabled ? .green : .orange)
            Text(t("所有文件操作均在 Finder 扩展中本地完成，不访问网络。"))
                .foregroundStyle(.secondary)
            GroupBox(t("权限状态")) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(
                        isAccessibilityTrusted ? "辅助功能已授权" : "辅助功能未授权（新建后重命名需要）"
                    )
                    .foregroundStyle(isAccessibilityTrusted ? Color.green : Color.orange)
                    HStack {
                        Button("请求辅助功能授权") {
                            requestAccessibilityAuthorization()
                        }
                        Button("完全磁盘访问") {
                            openSystemSettings("Privacy_AllFiles")
                        }
                    }
                }
                .padding(4)
            }
            HStack {
                Button(t("打开 Finder 扩展设置")) {
                    FIFinderSyncController.showExtensionManagementInterface()
                }
                .buttonStyle(.borderedProminent)
                Button(t("刷新状态")) {
                    refreshExtensionStatus()
                }
            }
            Button(t("恢复默认配置"), role: .destructive) {
                model.reset()
            }
        }
    }

    private var templatesView: some View {
        Form {
            HStack {
                Button("导入模板…") { model.importTemplate() }
                Spacer()
                Button("重置本页") { model.resetTemplates() }
            }
            Toggle(t("新建后自动打开"), isOn: binding(\.autoOpenNewFile))
            Toggle(t("创建成功时播放声音"), isOn: binding(\.playCreationSound))
            Section(t("模板（可拖动排序）")) {
                List {
                    ForEach($model.configuration.templates) { $template in
                        HStack(spacing: 8) {
                            Toggle("启用", isOn: $template.isEnabled)
                                .labelsHidden()
                                .help("在新建文件菜单中显示此模板")
                            TextField("模板名称", text: $template.name)
                                .textFieldStyle(.roundedBorder)
                                .frame(minWidth: 110)
                                .onSubmit { model.save() }
                            Text(".")
                                .foregroundStyle(.secondary)
                            TextField("后缀", text: $template.fileExtension)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 72)
                                .onSubmit { model.save() }
                            Picker("图标", selection: $template.iconVariant) {
                                Text("文档").tag(Optional(0))
                                Text("文本").tag(Optional(1))
                                Text("圆形").tag(Optional(2))
                                Text("代码").tag(Optional(3))
                            }
                            .frame(width: 108)
                            Toggle("一级菜单", isOn: $template.showInMainMenu)
                            Button("删除", role: .destructive) {
                                model.removeTemplate(id: template.id)
                            }
                            .help("删除此新建文件模板")
                        }
                    }
                    .onMove { indices, destination in
                        model.configuration.templates.move(fromOffsets: indices, toOffset: destination)
                        model.save()
                    }
                }
                .frame(minHeight: 260)
            }
        }
        .onChange(of: model.configuration) { _, _ in model.save() }
    }

    private var directoriesView: some View {
        ScrollView {
            VStack(spacing: 16) {
                HStack {
                    Spacer()
                    Button("重置本页") { model.resetDirectories() }
                }
                directoryList(
                    title: t("常用目录（名称可直接修改，例如 Desktop 改为“桌面”）"),
                    values: $model.configuration.commonDirectories,
                    common: true
                )
                directoryList(
                    title: t("移动/复制目标"),
                    values: $model.configuration.destinationDirectories,
                    common: false
                )
                openWithAppList
            }
        }
        .onChange(of: model.configuration) { _, _ in model.save() }
    }

    private var openWithAppList: some View {
        GroupBox("用 App 打开") {
            VStack {
                List {
                    ForEach($model.configuration.openWithApps) { $app in
                        HStack(spacing: 8) {
                            Toggle("", isOn: $app.isEnabled).labelsHidden()
                            Image(nsImage: NSWorkspace.shared.icon(forFile: app.appURL.path))
                                .resizable()
                                .frame(width: 22, height: 22)
                            VStack(alignment: .leading, spacing: 2) {
                                TextField("名称", text: $app.name)
                                Text(app.appPath)
                                    .font(.caption)
                                    .foregroundStyle(app.isInstalled ? Color.secondary : Color.red)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                if !app.isInstalled {
                                    Text("应用未安装，菜单中已自动隐藏")
                                        .font(.caption2)
                                        .foregroundStyle(.red)
                                }
                            }
                            Spacer()
                            Button("删除", role: .destructive) {
                                model.removeOpenWithApp(id: app.id)
                            }
                        }
                    }
                    .onMove { indices, destination in
                        model.configuration.openWithApps.move(fromOffsets: indices, toOffset: destination)
                        model.save()
                    }
                }
                .frame(minHeight: 170)
                HStack {
                    Button("添加…") { model.addOpenWithApp() }
                    Spacer()
                    Text("终端、Cursor 等")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var menuSettingsView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Toggle(t("启用 SuperRightClick 菜单"), isOn: binding(\.masterEnabled))
                Toggle(t("显示菜单图标"), isOn: binding(\.showMenuIcons))
                Toggle(t("显示菜单栏图标"), isOn: binding(\.showMenuBarIcon))
                Spacer()
                Button("重置本页") { model.resetMenuSettings() }
            }
            HStack {
                Toggle(t("合并文件操作"), isOn: binding(\.mergeFileOperations))
                Toggle(t("合并“用 App 打开”"), isOn: binding(\.mergeOpenWithApps))
                Toggle(t("合并图片转换"), isOn: binding(\.mergeImageOperations))
                Picker(t("语言"), selection: binding(\.language)) {
                    ForEach(AppLanguage.allCases, id: \.self) { language in
                        Text(language.displayName).tag(language)
                    }
                }
                .frame(width: 190)
            }
            Text("可启停、改名、拖动排序，并为单项设置自定义图标。")
                .font(.caption)
                .foregroundStyle(.secondary)
            List {
                ForEach($model.configuration.actionPreferences) { $preference in
                    HStack {
                        Toggle("", isOn: $preference.isEnabled).labelsHidden()
                        Text(preference.action.title)
                            .frame(width: 160, alignment: .leading)
                        TextField("自定义名称", text: Binding(
                            get: { preference.customName ?? "" },
                            set: { preference.customName = $0.isEmpty ? nil : $0 }
                        ))
                        Toggle("图标", isOn: $preference.showIcon)
                        Button("自定义图标…") {
                            model.chooseCustomIcon(for: preference.action)
                        }
                        if preference.customIconPath != nil {
                            Button("恢复") {
                                model.clearCustomIcon(for: preference.action)
                            }
                        }
                    }
                }
                .onMove { indices, destination in
                    model.configuration.actionPreferences.move(
                        fromOffsets: indices,
                        toOffset: destination
                    )
                    model.save()
                }
            }
        }
        .onChange(of: model.configuration) { _, _ in model.save() }
    }

    private var imageSettingsView: some View {
        Form {
            HStack {
                Spacer()
                Button("重置本页") { model.resetImageSettings() }
            }
            Section(t("图片转换")) {
                HStack {
                    Text("有损格式质量")
                    Slider(value: binding(\.imageQuality), in: 0.1...1, step: 0.05)
                    Text("\(Int(model.configuration.imageQuality * 100))%")
                        .monospacedDigit()
                        .frame(width: 45)
                }
                TextField("JPG 透明背景填充色（#RRGGBB）", text: binding(\.jpgBackgroundHex))
                Toggle(t("墙纸应用到全部屏幕"), isOn: binding(\.wallpaperAllScreens))
                Text("转换结果保存在源图片旁边；同名时自动追加序号。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var safetyView: some View {
        Form {
            HStack {
                Spacer()
                Button("重置本页") { model.resetAdvancedSettings() }
            }
            Toggle(t("文件操作合并为二级菜单"), isOn: binding(\.mergeFileOperations))
            Section(t("高风险功能（默认关闭）")) {
                Toggle(t("批量隐藏/显示当前目录"), isOn: binding(\.enableBulkVisibility))
                Toggle(t("修改写入权限"), isOn: binding(\.enablePermissionChanges))
                Toggle(t("解散文件夹"), isOn: binding(\.enableDissolveFolder))
                Toggle(t("永久删除"), isOn: binding(\.enablePermanentDelete))
            }
            Text("永久删除不经过废纸篓；每次操作都会强制确认。")
                .foregroundStyle(.red)
            Section(t("行为")) {
                Toggle(t("操作成功时播放声音"), isOn: binding(\.playOperationSound))
                Toggle(t("剪切时临时隐藏文件"), isOn: binding(\.hideCutItems))
            }
            Section(t("排除位置（这些目录及其子目录不显示增强菜单）")) {
                ForEach(model.configuration.excludedPaths, id: \.self) { path in
                    HStack {
                        Text(path).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("删除", role: .destructive) {
                            model.configuration.excludedPaths.removeAll { $0 == path }
                            model.save()
                        }
                    }
                }
                Button("添加排除目录…") { model.addExcludedPath() }
            }
        }
    }

    private func directoryList(
        title: String,
        values: Binding<[DirectoryShortcut]>,
        common: Bool
    ) -> some View {
        GroupBox(title) {
            VStack {
                List {
                    ForEach(values) { $value in
                        HStack(spacing: 8) {
                            Toggle("", isOn: $value.isEnabled).labelsHidden()
                            VStack(alignment: .leading, spacing: 2) {
                                TextField("菜单显示名称", text: $value.name)
                                    .onSubmit { model.save() }
                                Text(value.path)
                                    .font(.caption)
                                    .foregroundStyle(
                                        FileManager.default.fileExists(atPath: value.resolvedURL.path)
                                            ? Color.secondary : Color.red
                                    )
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer()
                            Button("换路径") {
                                model.changeDirectoryPath(id: value.id, common: common)
                            }
                            Button("删除", role: .destructive) {
                                model.removeDirectory(id: value.id, common: common)
                            }
                        }
                    }
                    .onMove { indices, destination in
                        if common {
                            model.configuration.commonDirectories.move(fromOffsets: indices, toOffset: destination)
                        } else {
                            model.configuration.destinationDirectories.move(fromOffsets: indices, toOffset: destination)
                        }
                        model.save()
                    }
                }
                .frame(minHeight: 170)
                HStack {
                    Button("添加…") { model.addDirectory(common: common) }
                    Spacer()
                    Text("名称可直接编辑，拖动可排序")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<MenuConfiguration, Value>) -> Binding<Value> {
        Binding(
            get: { model.configuration[keyPath: keyPath] },
            set: {
                model.configuration[keyPath: keyPath] = $0
                model.save()
            }
        )
    }

    private func t(_ value: String) -> String {
        Localizer.text(value, language: model.configuration.language)
    }

    private func refreshExtensionStatus() {
        isExtensionEnabled = FIFinderSyncController.isExtensionEnabled
        isAccessibilityTrusted = CGPreflightPostEventAccess()
    }

    private func requestAccessibilityAuthorization() {
        if !CGPreflightPostEventAccess(), !CGRequestPostEventAccess() {
            openSystemSettings("Privacy_Accessibility")
        }
    }

    private func openSystemSettings(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}
