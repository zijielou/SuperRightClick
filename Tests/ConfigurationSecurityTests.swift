import AppKit
import Foundation
import XCTest

/// 配置信任边界的独立回归用例。该文件故意不修改 project.pbxproj，
/// 便于在 Xcode 中审阅后再加入测试 target。
final class ConfigurationSecurityTests: XCTestCase {
    func testDuplicateActionPreferencesAreStablyDeduplicated() throws {
        var configuration = MenuConfiguration.default
        let action = FinderMenuAction.copyPath
        let first = ActionPreference(action: action, isEnabled: false, customName: "first")
        let second = ActionPreference(action: action, isEnabled: true, customName: "second")
        configuration.actionPreferences.insert(contentsOf: [first, second], at: 0)

        let normalized = configuration.validatedAndNormalized()
        let matches = normalized.actionPreferences.filter { $0.action == action }
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches.first?.customName, "first")
        XCTAssertEqual(matches.first?.isEnabled, false)
        XCTAssertEqual(Set(normalized.actionPreferences.map(\.action)).count,
                       normalized.actionPreferences.count)
    }

    func testEveryUUIDIdentifiedConfigurationArrayKeepsFirstDuplicate() throws {
        let templateID = UUID()
        let commonID = UUID()
        let destinationID = UUID()
        let appID = UUID()
        var configuration = MenuConfiguration.default
        configuration.templates = [
            NewFileTemplate(id: templateID, name: "First", fileExtension: "txt", kind: .text),
            NewFileTemplate(id: templateID, name: "Second", fileExtension: "md", kind: .markdown),
        ]
        configuration.commonDirectories = [
            DirectoryShortcut(id: commonID, name: "First", path: "/tmp/first-common"),
            DirectoryShortcut(id: commonID, name: "Second", path: "/tmp/second-common"),
        ]
        configuration.destinationDirectories = [
            DirectoryShortcut(id: destinationID, name: "First", path: "/tmp/first-destination"),
            DirectoryShortcut(id: destinationID, name: "Second", path: "/tmp/second-destination"),
        ]
        configuration.openWithApps = [
            AppShortcut(
                id: appID,
                name: "First",
                appPath: "/Applications/First.app",
                bundleIdentifier: "test.first"
            ),
            AppShortcut(
                id: appID,
                name: "Second",
                appPath: "/Applications/Second.app",
                bundleIdentifier: "test.second"
            ),
        ]

        let normalized = configuration.validatedAndNormalized()
        XCTAssertEqual(normalized.templates.filter { $0.id == templateID }.map(\.name), ["First"])
        XCTAssertEqual(
            normalized.commonDirectories.filter { $0.id == commonID }.map(\.path),
            ["/tmp/first-common"]
        )
        XCTAssertEqual(
            normalized.destinationDirectories.filter { $0.id == destinationID }.map(\.path),
            ["/tmp/first-destination"]
        )
        XCTAssertEqual(normalized.openWithApps.filter { $0.id == appID }.map(\.name), ["First"])
        XCTAssertEqual(Set(normalized.templates.map(\.id)).count, normalized.templates.count)
        XCTAssertEqual(
            Set(normalized.commonDirectories.map(\.id)).count,
            normalized.commonDirectories.count
        )
        XCTAssertEqual(
            Set(normalized.destinationDirectories.map(\.id)).count,
            normalized.destinationDirectories.count
        )
        XCTAssertEqual(Set(normalized.openWithApps.map(\.id)).count, normalized.openWithApps.count)
    }

    func testDraftMergeCombinesIndependentFieldsAndRetainsLocalConflict() {
        let base = MenuConfiguration.default
        var local = base
        local.language = .english
        var remote = base
        remote.masterEnabled = false

        let independent = ConfigurationDraftMerger.merge(
            base: base,
            local: local,
            remote: remote
        )
        XCTAssertFalse(independent.hasConflicts)
        XCTAssertEqual(independent.configuration.language, .english)
        XCTAssertFalse(independent.configuration.masterEnabled)

        remote.language = .traditionalChinese
        let conflict = ConfigurationDraftMerger.merge(base: base, local: local, remote: remote)
        XCTAssertTrue(conflict.hasConflicts)
        XCTAssertEqual(
            conflict.configuration.language,
            .english,
            "The visible local draft must not be silently replaced"
        )
        XCTAssertFalse(conflict.configuration.masterEnabled)
    }

    func testStoredTemplateFilenameMustBeAConfinedBasename() throws {
        XCTAssertTrue(MenuConfiguration.isValidStoredTemplateFilename("template.docx"))
        XCTAssertFalse(MenuConfiguration.isValidStoredTemplateFilename("../outside.docx"))
        XCTAssertFalse(MenuConfiguration.isValidStoredTemplateFilename("folder/template.docx"))
        XCTAssertFalse(MenuConfiguration.isValidStoredTemplateFilename("/tmp/template.docx"))
        XCTAssertFalse(MenuConfiguration.isValidStoredTemplateFilename(".."))

        let identifier = UUID()
        var configuration = MenuConfiguration.default
        configuration.templates.append(NewFileTemplate(
            id: identifier,
            name: "Unsafe",
            fileExtension: "docx",
            kind: .custom,
            storedFilename: "../outside.docx"
        ))
        let normalized = configuration.validatedAndNormalized()
        let template = try XCTUnwrap(normalized.templates.first { $0.id == identifier })
        XCTAssertNil(template.storedFilename)
        XCTAssertFalse(template.isEnabled)
    }

    func testUntrustedPathsAndUnsafeIconPathsAreRemoved() throws {
        var configuration = MenuConfiguration.default
        configuration.destinationDirectories.append(
            DirectoryShortcut(name: "Relative", path: "../../tmp")
        )
        let actionIndex = try XCTUnwrap(configuration.actionPreferences.firstIndex {
            $0.action == .copyPath
        })
        configuration.actionPreferences[actionIndex].customIconPath = "/tmp/untrusted.png"

        let normalized = configuration.validatedAndNormalized()
        XCTAssertFalse(normalized.destinationDirectories.contains { $0.name == "Relative" })
        XCTAssertNil(normalized.preference(for: .copyPath).customIconPath)
    }

    func testOnlyLegacyOrVersionedCustomIconFilesInsideManagedRootAreAccepted() throws {
        let action = FinderMenuAction.copyPath
        let root = ManagedCustomIconStore.directoryURL
        let legacy = root.appendingPathComponent("\(action.rawValue).png").path
        let versioned = root.appendingPathComponent(
            "\(action.rawValue)-\(UUID().uuidString.lowercased()).png"
        ).path
        XCTAssertTrue(ManagedCustomIconStore.isControlledPath(legacy, for: action))
        XCTAssertTrue(ManagedCustomIconStore.isControlledPath(versioned, for: action))
        XCTAssertFalse(ManagedCustomIconStore.isControlledPath(
            root.appendingPathComponent("\(action.rawValue)-not-a-uuid.png").path,
            for: action
        ))
        XCTAssertFalse(ManagedCustomIconStore.isControlledPath(
            root.deletingLastPathComponent().appendingPathComponent("\(action.rawValue).png").path,
            for: action
        ))

        var configuration = MenuConfiguration.default
        let index = try XCTUnwrap(configuration.actionPreferences.firstIndex {
            $0.action == action
        })
        configuration.actionPreferences[index].customIconPath = versioned
        XCTAssertEqual(
            configuration.validatedAndNormalized().preference(for: action).customIconPath,
            versioned
        )
    }

    func testCustomIconFilesFollowConfigurationCommitTransaction() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SuperRightClick-IconTransaction-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let action = FinderMenuAction.copyPath
        let old = root.appendingPathComponent("\(action.rawValue)-\(UUID().uuidString).png")
        try Data("old".utf8).write(to: old)

        var rejectedPath: String?
        XCTAssertFalse(try ManagedCustomIconStore.install(
            pngData: Data("new".utf8),
            for: action,
            replacing: old.path,
            directory: root
        ) { path in
            rejectedPath = path
            return false
        })
        XCTAssertTrue(FileManager.default.fileExists(atPath: old.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(rejectedPath)))

        var committedPath: String?
        XCTAssertTrue(try ManagedCustomIconStore.install(
            pngData: Data("committed".utf8),
            for: action,
            replacing: old.path,
            directory: root
        ) { path in
            XCTAssertTrue(FileManager.default.fileExists(atPath: path))
            committedPath = path
            return true
        })
        let committed = try XCTUnwrap(committedPath)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: committed))

        XCTAssertFalse(ManagedCustomIconStore.clear(
            path: committed,
            for: action,
            directory: root,
            commit: { false }
        ))
        XCTAssertTrue(FileManager.default.fileExists(atPath: committed))
        XCTAssertTrue(ManagedCustomIconStore.clear(
            path: committed,
            for: action,
            directory: root,
            commit: { true }
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: committed))
    }

    func testCustomDefaultsRemainIsolatedFromProductionSharedStore() throws {
        let suiteName = "SuperRightClick.ConfigurationSecurityTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var configuration = MenuConfiguration.default
        configuration.language = .english
        XCTAssertTrue(ConfigurationStore.save(configuration, defaults: defaults, publish: false))
        XCTAssertNotNil(defaults.data(forKey: "menuConfiguration.v2"))
        XCTAssertEqual(ConfigurationStore.load(defaults: defaults).language, .english)
    }

    func testIsolatedStoreRejectsStaleSnapshotWithCASConflict() throws {
        let suiteName = "SuperRightClick.ConfigurationCASTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let firstEditor = ConfigurationStore.loadSnapshot(defaults: defaults)
        let staleEditor = ConfigurationStore.loadSnapshot(defaults: defaults)
        var firstValue = firstEditor.configuration
        firstValue.language = .english
        guard case .saved = ConfigurationStore.save(
            firstValue,
            basedOn: firstEditor,
            defaults: defaults,
            publish: false
        ) else {
            return XCTFail("The first editor should commit")
        }

        var staleValue = staleEditor.configuration
        staleValue.masterEnabled = false
        let staleResult = ConfigurationStore.save(
            staleValue,
            basedOn: staleEditor,
            defaults: defaults,
            publish: false
        )
        guard case let .conflict(winner?) = staleResult else {
            return XCTFail("A stale editor must receive the winning snapshot")
        }
        XCTAssertEqual(winner.configuration.language, .english)
        XCTAssertTrue(winner.configuration.masterEnabled)
    }

    func testStorageCapacityIsRejectedInsteadOfSilentlyTruncated() throws {
        let suiteName = "SuperRightClick.ConfigurationCapacityTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let baseline = ConfigurationStore.loadSnapshot(defaults: defaults)
        var overflow = MenuConfiguration.default
        overflow.templates = (0...MenuConfiguration.maximumTemplateCount).map {
            NewFileTemplate(name: "Template \($0)", fileExtension: "txt", kind: .text)
        }
        let result = ConfigurationStore.save(
            overflow,
            basedOn: baseline,
            defaults: defaults,
            publish: false
        )
        guard case .unavailable = result else {
            return XCTFail("Over-capacity configuration must not commit")
        }
        XCTAssertFalse(ConfigurationStore.hasStoredConfiguration(defaults: defaults))
    }

    func testLegacyExtensionAdditionsMergeWithoutReplacingSharedSettings() throws {
        var shared = MenuConfiguration.default
        shared.language = .english
        var legacy = MenuConfiguration.default
        let templateID = UUID()
        legacy.templates.append(NewFileTemplate(
            id: templateID,
            name: "Legacy Template",
            fileExtension: "docx",
            kind: .custom,
            storedFilename: "legacy-template.docx"
        ))
        legacy.commonDirectories.append(
            DirectoryShortcut(name: "Legacy Folder", path: "/tmp/legacy-folder")
        )

        let merged = try XCTUnwrap(
            ConfigurationStore.mergingLegacyExtensionAdditions(legacy, into: shared)
        )
        XCTAssertEqual(merged.language, .english)
        XCTAssertTrue(merged.templates.contains { $0.id == templateID })
        XCTAssertTrue(merged.commonDirectories.contains { $0.path == "/tmp/legacy-folder" })
    }

    func testLegacyMergeNeverReplacesSharedRowsWithCollidingUUIDs() throws {
        let templateID = UUID()
        let directoryID = UUID()
        var shared = MenuConfiguration.default
        shared.templates.append(NewFileTemplate(
            id: templateID,
            name: "Shared Template",
            fileExtension: "docx",
            kind: .custom,
            storedFilename: "shared.docx"
        ))
        shared.commonDirectories.append(DirectoryShortcut(
            id: directoryID,
            name: "Shared Folder",
            path: "/tmp/shared-folder"
        ))
        var legacy = MenuConfiguration.default
        legacy.templates.append(NewFileTemplate(
            id: templateID,
            name: "Legacy Collision",
            fileExtension: "pages",
            kind: .custom,
            storedFilename: "legacy.pages"
        ))
        legacy.commonDirectories.append(DirectoryShortcut(
            id: directoryID,
            name: "Legacy Collision",
            path: "/tmp/legacy-collision"
        ))

        let merged = try XCTUnwrap(
            ConfigurationStore.mergingLegacyExtensionAdditions(legacy, into: shared)
        )
        XCTAssertEqual(
            merged.templates.filter { $0.id == templateID }.map(\.name),
            ["Shared Template"]
        )
        XCTAssertEqual(
            merged.commonDirectories.filter { $0.id == directoryID }.map(\.name),
            ["Shared Folder"]
        )
        XCTAssertFalse(merged.commonDirectories.contains { $0.path == "/tmp/legacy-collision" })
    }

    func testLegacyMergeRemainsPendingWhenSharedCapacityIsFull() {
        var shared = MenuConfiguration.default
        shared.templates = (0..<MenuConfiguration.maximumTemplateCount).map {
            NewFileTemplate(name: "Shared \($0)", fileExtension: "txt", kind: .text)
        }
        var legacy = MenuConfiguration.default
        legacy.templates.append(NewFileTemplate(
            name: "Legacy Extra",
            fileExtension: "docx",
            kind: .custom,
            storedFilename: "legacy-extra.docx"
        ))
        XCTAssertNil(ConfigurationStore.mergingLegacyExtensionAdditions(legacy, into: shared))
    }

    @MainActor
    func testTemplateImportRollsBackCopiedFileAtCapacity() throws {
        let suiteName = "SuperRightClick.TemplateCapacityTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SuperRightClick-TemplateCapacity-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = root.appendingPathComponent("Templates", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        var full = MenuConfiguration.default
        full.templates = (0..<MenuConfiguration.maximumTemplateCount).map {
            NewFileTemplate(name: "Existing \($0)", fileExtension: "txt", kind: .text)
        }
        XCTAssertTrue(ConfigurationStore.save(full, defaults: defaults, publish: false))
        let coordinator = FeatureCoordinator(
            requiresConfirmation: false,
            templateStorageURL: storage,
            configurationDefaults: defaults,
            publishChanges: false,
            safetyPreferencesStore: SafetyPreferencesStore(
                directoryURL: root.appendingPathComponent("Safety", isDirectory: true)
            ),
            errorPresentation: { _ in }
        )
        let source = root.appendingPathComponent("new.docx")
        try Data("new template".utf8).write(to: source)

        XCTAssertThrowsError(try coordinator.registerTemplate(from: source, name: "New Template"))
        let remaining = (try? FileManager.default.contentsOfDirectory(
            at: storage,
            includingPropertiesForKeys: nil
        )) ?? []
        XCTAssertTrue(remaining.isEmpty, "Failed import must remove its new UUID-named copy")
        XCTAssertEqual(coordinator.configuration.templates.count,
                       MenuConfiguration.maximumTemplateCount)
    }

    @MainActor
    func testAddingCommonDirectoryAtCapacityDoesNotReportSuccessOrPersistIt() throws {
        let suiteName = "SuperRightClick.DirectoryCapacityTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var full = MenuConfiguration.default
        full.commonDirectories = (0..<MenuConfiguration.maximumDirectoryCount).map {
            DirectoryShortcut(name: "Folder \($0)", path: "/tmp/folder-\($0)")
        }
        XCTAssertTrue(ConfigurationStore.save(full, defaults: defaults, publish: false))

        var errors: [String] = []
        let coordinator = FeatureCoordinator(
            requiresConfirmation: false,
            configurationDefaults: defaults,
            publishChanges: false,
            safetyPreferencesStore: SafetyPreferencesStore(
                directoryURL: FileManager.default.temporaryDirectory.appendingPathComponent(
                    "SuperRightClick-DirectoryCapacity-Safety-\(UUID().uuidString)",
                    isDirectory: true
                )
            ),
            errorPresentation: { errors.append($0) }
        )
        coordinator.addCommonDirectory(URL(fileURLWithPath: "/tmp/not-persisted"))

        XCTAssertFalse(errors.isEmpty)
        XCTAssertEqual(coordinator.configuration.commonDirectories.count,
                       MenuConfiguration.maximumDirectoryCount)
        XCTAssertFalse(coordinator.configuration.commonDirectories.contains {
            $0.path == "/tmp/not-persisted"
        })
        XCTAssertFalse(ConfigurationStore.load(defaults: defaults).commonDirectories.contains {
            $0.path == "/tmp/not-persisted"
        })
    }
}
