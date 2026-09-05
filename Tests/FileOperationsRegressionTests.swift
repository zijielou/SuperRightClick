import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest

final class FileOperationsRegressionTests: XCTestCase {
    private var root: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var pasteboard: NSPasteboard!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SuperRightClickFileOperationTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        suiteName = "SuperRightClickFileOperationTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        pasteboard = NSPasteboard(name: NSPasteboard.Name(
            "SuperRightClickFileOperationTests.\(UUID().uuidString)"
        ))
    }

    override func tearDownWithError() throws {
        pasteboard?.releaseGlobally()
        if let root { try? FileManager.default.removeItem(at: root) }
        if let suiteName { defaults?.removePersistentDomain(forName: suiteName) }
    }

    @MainActor
    private func makeCoordinator(
        errors: (@MainActor (String) -> Void)? = nil
    ) -> FeatureCoordinator {
        FeatureCoordinator(
            requiresConfirmation: false,
            configurationDefaults: defaults,
            publishChanges: false,
            safetyPreferencesStore: SafetyPreferencesStore(
                directoryURL: root.appendingPathComponent("Safety", isDirectory: true)
            ),
            pasteboard: pasteboard,
            errorPresentation: errors
        )
    }

    @MainActor
    func testCopyingDirectoryToItselfDoesNotCreateRecursiveResidue() async throws {
        let source = root.appendingPathComponent("folder", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: source.appendingPathComponent("child.txt"))
        var errors: [String] = []
        let coordinator = makeCoordinator { errors.append($0) }

        let failures = await coordinator.transferAndWait([source], to: source, move: false)

        XCTAssertEqual(failures, [source])
        XCTAssertEqual(
            try Data(contentsOf: source.appendingPathComponent("child.txt")),
            Data("keep".utf8)
        )
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: source.appendingPathComponent("folder").path
        ))
        XCTAssertEqual(errors.count, 1)
    }

    @MainActor
    func testMissingSourceEqualToDestinationIsNotCreated() async {
        let missing = root.appendingPathComponent("missing", isDirectory: true)
        let coordinator = makeCoordinator { _ in }

        _ = await coordinator.transferAndWait([missing], to: missing, move: false)

        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
    }

    @MainActor
    func testV2CutSessionMakesPasteMenuAvailableAndCarriesSessionIdentity() throws {
        let source = root.appendingPathComponent("cut-session.txt")
        try Data("cut".utf8).write(to: source)

        makeCoordinator().cut([source])

        XCTAssertTrue(FeatureCoordinator.hasPersistedCutItems(in: defaults))
        let data = try XCTUnwrap(defaults.data(forKey: "cutItemSnapshotsV2"))
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertNotNil(object["id"] as? String)
        XCTAssertEqual((object["items"] as? [[String: Any]])?.count, 1)
    }

    @MainActor
    func testCopyAcceptsSymlinkToDirectoryDestination() async throws {
        let source = root.appendingPathComponent("source.txt")
        let realDestination = root.appendingPathComponent("real-destination", isDirectory: true)
        let linkedDestination = root.appendingPathComponent("linked-destination", isDirectory: true)
        try Data("content".utf8).write(to: source)
        try FileManager.default.createDirectory(
            at: realDestination,
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: linkedDestination,
            withDestinationURL: realDestination
        )

        let failures = await makeCoordinator().transferAndWait(
            [source],
            to: linkedDestination,
            move: false
        )

        XCTAssertTrue(failures.isEmpty)
        XCTAssertEqual(
            try Data(contentsOf: realDestination.appendingPathComponent("source.txt")),
            Data("content".utf8)
        )
    }

    @MainActor
    func testCopyDirectoryBetweenOrdinarySiblingFolders() async throws {
        let source = root.appendingPathComponent("source-folder", isDirectory: true)
        let destination = root.appendingPathComponent("destination-folder", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("sibling".utf8).write(to: source.appendingPathComponent("child.txt"))

        let failures = await makeCoordinator().transferAndWait(
            [source],
            to: destination,
            move: false
        )

        XCTAssertTrue(failures.isEmpty)
        XCTAssertEqual(
            try Data(contentsOf: destination
                .appendingPathComponent("source-folder", isDirectory: true)
                .appendingPathComponent("child.txt")),
            Data("sibling".utf8)
        )
    }

    @MainActor
    func testDirectoryAncestorIdentityRejectsSymlinkedSelfCopyWithoutResidue() async throws {
        let source = root.appendingPathComponent("source-directory", isDirectory: true)
        let alias = root.appendingPathComponent("source-alias", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: source.appendingPathComponent("child.txt"))
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: source)
        let requestedDestination = alias.appendingPathComponent("nested", isDirectory: true)

        let failures = await makeCoordinator { _ in }.transferAndWait(
            [source],
            to: requestedDestination,
            move: false
        )

        XCTAssertEqual(failures, [source])
        XCTAssertFalse(FileManager.default.fileExists(atPath: requestedDestination.path))
    }

    @MainActor
    func testGrantWritePermissionDoesNotFollowSymbolicLinks() throws {
        let target = root.appendingPathComponent("readonly.txt")
        let link = root.appendingPathComponent("readonly-link")
        try Data("keep".utf8).write(to: target)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o400)],
            ofItemAtPath: target.path
        )
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        var errors: [String] = []

        makeCoordinator { errors.append($0) }.grantWritePermission([link])

        let permissions = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions]
                as? NSNumber
        )
        XCTAssertEqual(permissions.intValue & 0o200, 0)
        XCTAssertEqual(errors.count, 1)
    }

    @MainActor
    func testStaleCutIdentityFallsBackToIsolatedSystemPasteboard() async throws {
        let cutSource = root.appendingPathComponent("cut.txt")
        let displaced = root.appendingPathComponent("original-cut.txt")
        let clipboardSource = root.appendingPathComponent("clipboard.txt")
        let destination = root.appendingPathComponent("destination", isDirectory: true)
        try Data("original".utf8).write(to: cutSource)
        try Data("clipboard".utf8).write(to: clipboardSource)
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([clipboardSource as NSURL]))

        let coordinator = makeCoordinator { _ in }
        coordinator.cut([cutSource])
        try FileManager.default.moveItem(at: cutSource, to: displaced)
        try Data("replacement".utf8).write(to: cutSource)

        await coordinator.pasteAndWait(into: destination)

        XCTAssertEqual(try Data(contentsOf: cutSource), Data("replacement".utf8))
        XCTAssertEqual(try Data(contentsOf: displaced), Data("original".utf8))
        XCTAssertEqual(
            try Data(contentsOf: destination.appendingPathComponent("clipboard.txt")),
            Data("clipboard".utf8)
        )
    }

    @MainActor
    func testCutVisibilityRestoreNeverTouchesReplacementAtSamePath() throws {
        let original = root.appendingPathComponent("original.txt")
        let displaced = root.appendingPathComponent("displaced.txt")
        let next = root.appendingPathComponent("next.txt")
        try Data().write(to: original)
        try Data().write(to: next)
        let coordinator = makeCoordinator { _ in }
        var configuration = MenuConfiguration.default
        configuration.hideCutItems = true
        coordinator.updateConfiguration(configuration)
        coordinator.cut([original])
        XCTAssertEqual(try original.resourceValues(forKeys: [.isHiddenKey]).isHidden, true)

        try FileManager.default.moveItem(at: original, to: displaced)
        try Data("replacement".utf8).write(to: original)
        var replacement = original
        var values = URLResourceValues()
        values.isHidden = true
        try replacement.setResourceValues(values)

        coordinator.cut([next])

        XCTAssertEqual(try original.resourceValues(forKeys: [.isHiddenKey]).isHidden, true)
        XCTAssertEqual(try displaced.resourceValues(forKeys: [.isHiddenKey]).isHidden, true)
    }

    @MainActor
    func testImageConversionAppliesEXIFOrientationAndResetsMetadata() throws {
        let source = root.appendingPathComponent("oriented.tiff")
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.displayP3))
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: 12,
            height: 20,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 12, height: 20))
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            source as CFURL,
            UTType.tiff.identifier as CFString,
            1,
            nil
        ))
        CGImageDestinationAddImage(destination, image, [
            kCGImagePropertyOrientation: CGImagePropertyOrientation.right.rawValue,
        ] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))

        let output = try makeCoordinator().convertImage(source, to: .png)
        let outputSource = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
        let outputImage = try XCTUnwrap(CGImageSourceCreateImageAtIndex(outputSource, 0, nil))
        let properties = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(outputSource, 0, nil) as? [CFString: Any]
        )

        XCTAssertEqual(outputImage.width, 20)
        XCTAssertEqual(outputImage.height, 12)
        XCTAssertEqual(
            (properties[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value ?? 1,
            CGImagePropertyOrientation.up.rawValue
        )
        XCTAssertNotNil(outputImage.colorSpace)
    }
}
