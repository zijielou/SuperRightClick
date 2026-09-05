import XCTest

final class HostUIBridgeTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SuperRightClick-HostUIBridgeTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
        root = nil
    }

    func testTransferDestinationRequestRoundTripAndValidation() throws {
        let request = TransferDestinationPickerBridge.makeRequest(
            operation: .copy,
            sourceItemCount: 2,
            replySocketPath: "/tmp/superrightclick-picker-test.sock"
        )
        let requestURL = try TransferDestinationPickerBridge.writeRequest(
            request,
            directoryURL: root.appendingPathComponent("requests", isDirectory: true)
        )
        defer { TransferDestinationPickerBridge.removeRequest(at: requestURL) }

        XCTAssertEqual(try TransferDestinationPickerBridge.readRequest(at: requestURL), request)
        XCTAssertEqual(TransferDestinationPickerBridge.requestID(from: requestURL), request.id)
        let attributes = try FileManager.default.attributesOfItem(atPath: requestURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)

        let stale = TransferDestinationPickerRequest(
            id: UUID(),
            createdAt: Date().addingTimeInterval(
                -(TransferDestinationPickerBridge.responseTimeoutSeconds + 1)
            ),
            operation: .move,
            sourceItemCount: 1,
            replySocketPath: "/tmp/superrightclick-picker-stale.sock"
        )
        let staleURL = try TransferDestinationPickerBridge.writeRequest(
            stale,
            directoryURL: requestURL.deletingLastPathComponent()
        )
        defer { TransferDestinationPickerBridge.removeRequest(at: staleURL) }
        XCTAssertThrowsError(try TransferDestinationPickerBridge.readRequest(at: staleURL))
    }

    func testTransferDestinationDigestCoversOperationCountAndSocket() {
        let id = UUID()
        let date = Date(timeIntervalSinceReferenceDate: 123_456)
        let hostIdentity = HostBundleIdentity(device: 11, inode: 22)
        let baseline = TransferDestinationPickerRequest(
            id: id,
            createdAt: date,
            operation: .copy,
            sourceItemCount: 1,
            replySocketPath: "/tmp/a.sock",
            containingHostBundleIdentity: hostIdentity
        )
        let variants = [
            TransferDestinationPickerRequest(
                id: id,
                createdAt: date,
                operation: .move,
                sourceItemCount: 1,
                replySocketPath: "/tmp/a.sock",
                containingHostBundleIdentity: hostIdentity
            ),
            TransferDestinationPickerRequest(
                id: id,
                createdAt: date,
                operation: .selectFolderIconImage,
                sourceItemCount: 1,
                replySocketPath: "/tmp/a.sock",
                containingHostBundleIdentity: hostIdentity
            ),
            TransferDestinationPickerRequest(
                id: id,
                createdAt: date,
                operation: .copy,
                sourceItemCount: 2,
                replySocketPath: "/tmp/a.sock",
                containingHostBundleIdentity: hostIdentity
            ),
            TransferDestinationPickerRequest(
                id: id,
                createdAt: date,
                operation: .copy,
                sourceItemCount: 1,
                replySocketPath: "/tmp/b.sock",
                containingHostBundleIdentity: hostIdentity
            ),
            TransferDestinationPickerRequest(
                id: id,
                createdAt: date,
                operation: .copy,
                sourceItemCount: 1,
                replySocketPath: "/tmp/a.sock",
                containingHostBundleIdentity: HostBundleIdentity(device: 11, inode: 23)
            ),
        ]

        for variant in variants {
            XCTAssertNotEqual(variant.authenticationDigest, baseline.authenticationDigest)
        }
    }

    func testTransferDestinationResponseShapeValidation() {
        let requestID = UUID()
        let digest = Data("request".utf8)
        XCTAssertTrue(TransferDestinationPickerResponse(
            requestID: requestID,
            requestDigest: digest,
            outcome: .selected,
            destinationBookmark: Data("bookmark".utf8)
        ).isStructurallyValid)
        XCTAssertTrue(TransferDestinationPickerResponse(
            requestID: requestID,
            requestDigest: digest,
            outcome: .cancelled,
            destinationBookmark: nil
        ).isStructurallyValid)
        XCTAssertFalse(TransferDestinationPickerResponse(
            requestID: requestID,
            requestDigest: digest,
            outcome: .selected,
            destinationBookmark: nil
        ).isStructurallyValid)
        XCTAssertFalse(TransferDestinationPickerResponse(
            requestID: requestID,
            requestDigest: digest,
            outcome: .cancelled,
            destinationBookmark: Data("unexpected".utf8)
        ).isStructurallyValid)
    }

    func testAuthenticatedTransferDestinationReplyChannel() async throws {
        let expectedCodeHash = try XCTUnwrap(
            HostCodeIdentity.codeHash(processIdentifier: getpid())
        )
        let expectedDigest = Data("expected-picker-request".utf8)
        let requestID = UUID()
        let socketPath = AuthenticatedHostResponseServer<
            TransferDestinationPickerResponse
        >.makeSocketPath()
        let server = try AuthenticatedHostResponseServer<TransferDestinationPickerResponse>(
            socketPath: socketPath,
            requestID: requestID,
            expectedHostCodeHash: expectedCodeHash,
            expectedRequestDigest: expectedDigest,
            maximumResponseSize: 64 * 1024
        )
        defer { server.invalidate() }

        let responseTask = Task.detached(priority: .userInitiated) {
            server.receiveResponse()
        }
        let sent = TransferDestinationPickerResponse(
            requestID: requestID,
            requestDigest: expectedDigest,
            outcome: .selected,
            destinationBookmark: Data("bookmark-payload".utf8)
        )
        XCTAssertEqual(try LocalUnixSocket.peerCodeHash(at: socketPath), expectedCodeHash)
        try TransferDestinationPickerBridge.sendResponse(
            sent,
            toSocketPath: socketPath,
            expectedPeerCodeHash: expectedCodeHash
        )
        let received = await responseTask.value
        XCTAssertEqual(received, sent)
    }

    func testProductionTransportLocationIsBoundToRequestTemporaryRoot() {
        let identifier = UUID()
        let hostIdentity = HostBundleIdentity(device: 42, inode: 84)
        let temporaryRoot = URL(fileURLWithPath: "/tmp/extension-container/T", isDirectory: true)
        let requestURL = temporaryRoot
            .appendingPathComponent("SuperRightClick-HostUIRequests", isDirectory: true)
            .appendingPathComponent("transfer-destination-\(identifier.uuidString).json")
        let request = TransferDestinationPickerRequest(
            id: identifier,
            createdAt: Date(),
            operation: .copy,
            sourceItemCount: 1,
            replySocketPath: temporaryRoot.appendingPathComponent(".s12345678").path,
            containingHostBundleIdentity: hostIdentity
        )
        XCTAssertTrue(TransferDestinationPickerBridge.hasExpectedProductionTransport(
            request,
            requestURL: requestURL
        ))

        let redirected = TransferDestinationPickerRequest(
            id: identifier,
            createdAt: request.createdAt,
            operation: .copy,
            sourceItemCount: 1,
            replySocketPath: "/tmp/attacker/.s12345678",
            containingHostBundleIdentity: hostIdentity
        )
        XCTAssertFalse(TransferDestinationPickerBridge.hasExpectedProductionTransport(
            redirected,
            requestURL: requestURL
        ))

        let unbound = TransferDestinationPickerRequest(
            id: identifier,
            createdAt: request.createdAt,
            operation: .copy,
            sourceItemCount: 1,
            replySocketPath: request.replySocketPath,
            containingHostBundleIdentity: nil
        )
        XCTAssertFalse(TransferDestinationPickerBridge.hasExpectedProductionTransport(
            unbound,
            requestURL: requestURL
        ))
    }

    func testConcreteContainingApplicationIdentity() throws {
        let applicationURL = root.appendingPathComponent("Fixture.app", isDirectory: true)
        let extensionURL = applicationURL
            .appendingPathComponent("Contents/PlugIns", isDirectory: true)
            .appendingPathComponent("Fixture.appex", isDirectory: true)
        try FileManager.default.createDirectory(
            at: extensionURL,
            withIntermediateDirectories: true
        )

        XCTAssertEqual(
            HostBundleIdentity.containingApplicationURL(for: extensionURL),
            applicationURL
        )
        XCTAssertEqual(
            HostBundleIdentity.capture(at: applicationURL),
            HostBundleIdentity.capture(
                at: try XCTUnwrap(
                    HostBundleIdentity.containingApplicationURL(for: extensionURL)
                )
            )
        )
    }

    func testDestructiveTransportAndDigestBindHostInstance() {
        let identifier = UUID()
        let createdAt = Date(timeIntervalSinceReferenceDate: 321_000)
        let temporaryRoot = URL(fileURLWithPath: "/tmp/extension-container/T", isDirectory: true)
        let requestURL = temporaryRoot
            .appendingPathComponent("SuperRightClick-ConfirmationRequests", isDirectory: true)
            .appendingPathComponent("permanent-delete-\(identifier.uuidString).json")
        let identity = HostBundleIdentity(device: 7, inode: 8)
        let request = DestructiveConfirmationRequest(
            id: identifier,
            createdAt: createdAt,
            action: .permanentDelete,
            paths: ["/tmp/test-item"],
            confirmationMode: .standard,
            replySocketPath: temporaryRoot.appendingPathComponent(".s87654321").path,
            containingHostBundleIdentity: identity
        )
        XCTAssertTrue(DestructiveConfirmationBridge.hasExpectedProductionTransport(
            request,
            requestURL: requestURL
        ))

        let otherHost = DestructiveConfirmationRequest(
            id: identifier,
            createdAt: createdAt,
            action: .permanentDelete,
            paths: request.paths,
            confirmationMode: .standard,
            replySocketPath: request.replySocketPath,
            containingHostBundleIdentity: HostBundleIdentity(device: 7, inode: 9)
        )
        XCTAssertNotEqual(otherHost.authenticationDigest, request.authenticationDigest)

        let redirected = DestructiveConfirmationRequest(
            id: identifier,
            createdAt: createdAt,
            action: .permanentDelete,
            paths: request.paths,
            confirmationMode: .standard,
            replySocketPath: "/tmp/attacker/.s87654321",
            containingHostBundleIdentity: identity
        )
        XCTAssertFalse(DestructiveConfirmationBridge.hasExpectedProductionTransport(
            redirected,
            requestURL: requestURL
        ))
    }

    func testHostUIAdmissionCountsValidationQueueAndActiveRequest() {
        XCTAssertTrue(HostUIRequestAdmission.canAccept(
            validating: 10,
            pending: 10,
            inFlight: 1,
            otherOutstanding: 10
        ))
        XCTAssertFalse(HostUIRequestAdmission.canAccept(
            validating: 10,
            pending: 10,
            inFlight: 1,
            otherOutstanding: 11
        ))
        XCTAssertFalse(HostUIRequestAdmission.canAccept(
            validating: -1,
            pending: 0,
            inFlight: 0
        ))
    }

    func testDestructiveResponseVerifiesActualSocketPeer() async throws {
        let expectedCodeHash = try XCTUnwrap(
            HostCodeIdentity.codeHash(processIdentifier: getpid())
        )
        let digest = Data("delete-request".utf8)
        let requestID = UUID()
        let server = try AuthenticatedHostResponseServer<DestructiveConfirmationResponse>(
            socketPath: AuthenticatedHostResponseServer<
                DestructiveConfirmationResponse
            >.makeSocketPath(),
            requestID: requestID,
            expectedHostCodeHash: expectedCodeHash,
            expectedRequestDigest: digest
        )
        defer { server.invalidate() }
        let responseTask = Task.detached(priority: .userInitiated) {
            server.receiveResponse()
        }
        let response = DestructiveConfirmationResponse(
            requestID: requestID,
            requestDigest: digest,
            approved: true
        )

        XCTAssertThrowsError(try DestructiveConfirmationBridge.sendResponse(
            response,
            toSocketPath: server.socketPath,
            expectedPeerCodeHash: Data(repeating: 0, count: expectedCodeHash.count)
        ))
        try DestructiveConfirmationBridge.sendResponse(
            response,
            toSocketPath: server.socketPath,
            expectedPeerCodeHash: expectedCodeHash
        )
        let received = await responseTask.value
        XCTAssertEqual(received, response)
    }

    func testTransferDestinationReplyListenerStopsWhenTimeoutInvalidatesIt() async throws {
        let expectedCodeHash = try XCTUnwrap(
            HostCodeIdentity.codeHash(processIdentifier: getpid())
        )
        let server = try AuthenticatedHostResponseServer<TransferDestinationPickerResponse>(
            socketPath: AuthenticatedHostResponseServer<
                TransferDestinationPickerResponse
            >.makeSocketPath(),
            requestID: UUID(),
            expectedHostCodeHash: expectedCodeHash,
            expectedRequestDigest: Data("timeout".utf8)
        )
        let responseTask = Task.detached(priority: .userInitiated) {
            server.receiveResponse()
        }

        try await Task.sleep(for: .milliseconds(30))
        server.invalidate()
        let response = await responseTask.value
        XCTAssertNil(response)
    }

    func testImplicitScopedDirectoryBookmarkRoundTrip() throws {
        let directory = root.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bookmark = try directory.bookmarkData(
            options: [],
            includingResourceValuesForKeys: [.isDirectoryKey],
            relativeTo: nil
        )
        var isStale = false
        let resolved = try URL(
            resolvingBookmarkData: bookmark,
            options: [.withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )

        XCTAssertFalse(isStale)
        XCTAssertEqual(resolved.standardizedFileURL, directory.standardizedFileURL)
        XCTAssertEqual(
            try resolved.resourceValues(forKeys: [.isDirectoryKey]).isDirectory,
            true
        )
        resolved.stopAccessingSecurityScopedResource()
    }

    func testStaleEphemeralBookmarkStillResolvesToUsableRenamedDirectory() throws {
        let original = root.appendingPathComponent("before-rename", isDirectory: true)
        let renamed = root.appendingPathComponent("after-rename", isDirectory: true)
        try FileManager.default.createDirectory(
            at: original,
            withIntermediateDirectories: true
        )
        let bookmark = try TransferDestinationPickerBridge.makeEphemeralBookmark(
            for: original
        )
        try FileManager.default.moveItem(at: original, to: renamed)

        let resolved = try TransferDestinationPickerBridge.resolveEphemeralBookmark(
            bookmark
        )
        defer { resolved.url.stopAccessingSecurityScopedResource() }

        XCTAssertTrue(resolved.wasStale)
        XCTAssertEqual(resolved.url.standardizedFileURL, renamed.standardizedFileURL)
        XCTAssertEqual(
            try resolved.url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory,
            true
        )
    }

    func testResponseJSONPreservesResolvableEphemeralBookmarkBytes() throws {
        let directory = root.appendingPathComponent("json-destination", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let bookmark = try TransferDestinationPickerBridge.makeEphemeralBookmark(
            for: directory
        )
        let response = TransferDestinationPickerResponse(
            requestID: UUID(),
            requestDigest: Data("json-round-trip".utf8),
            outcome: .selected,
            destinationBookmark: bookmark
        )

        let encoded = try JSONEncoder().encode(response)
        let decoded = try JSONDecoder().decode(
            TransferDestinationPickerResponse.self,
            from: encoded
        )
        let decodedBookmark = try XCTUnwrap(decoded.destinationBookmark)
        XCTAssertEqual(decodedBookmark, bookmark)

        let resolved = try TransferDestinationPickerBridge.resolveEphemeralBookmark(
            decodedBookmark
        )
        defer { resolved.url.stopAccessingSecurityScopedResource() }
        XCTAssertEqual(resolved.url.standardizedFileURL, directory.standardizedFileURL)
        XCTAssertEqual(
            try resolved.url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory,
            true
        )
    }
}
