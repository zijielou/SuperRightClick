@preconcurrency import AppKit
import CoreImage
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Receives one response from the signed containing application. Request ID and
/// digest prevent a valid host response from being replayed for another request.
final class AuthenticatedHostResponseServer<Response: AuthenticatedHostResponse>:
    @unchecked Sendable {
    let socketPath: String

    private static var pollIntervalMilliseconds: Int32 { 100 }
    private static var responseReadTimeout: Duration { .seconds(2) }
    private let maximumResponseSize: Int
    private let requestID: UUID
    private let expectedHostCodeHash: Data
    private let expectedRequestDigest: Data
    private let lock = NSLock()
    private var descriptor: Int32 = -1

    static func makeSocketPath() -> String {
        let directory = FileManager.default.temporaryDirectory.path
        let sunPathCapacity = 104
        let prefix = directory + "/.s"
        let available = sunPathCapacity - prefix.utf8.count - 1
        let tokenLength = min(16, max(4, available))
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
            .prefix(tokenLength)
        return "\(prefix)\(token)"
    }

    init(
        socketPath: String,
        requestID: UUID,
        expectedHostCodeHash: Data,
        expectedRequestDigest: Data,
        maximumResponseSize: Int = 4 * 1024
    ) throws {
        self.socketPath = socketPath
        self.requestID = requestID
        self.expectedHostCodeHash = expectedHostCodeHash
        self.expectedRequestDigest = expectedRequestDigest
        self.maximumResponseSize = maximumResponseSize

        let socketDescriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketDescriptor >= 0 else {
            throw SecureFileFailure.posix("无法创建宿主界面响应通道", errno)
        }
        descriptor = socketDescriptor
        do {
            let flags = fcntl(socketDescriptor, F_GETFL)
            guard flags >= 0,
                  fcntl(socketDescriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
                throw SecureFileFailure.posix("无法配置宿主界面响应通道", errno)
            }
            var (address, length) = try LocalUnixSocket.address(for: socketPath)
            socketPath.withCString { path in
                _ = unlink(path)
            }
            let bindResult = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(socketDescriptor, $0, length)
                }
            }
            guard bindResult == 0 else {
                throw SecureFileFailure.posix("无法绑定宿主界面响应通道", errno)
            }
            guard socketPath.withCString({ chmod($0, 0o600) }) == 0 else {
                throw SecureFileFailure.posix("无法设置宿主界面响应通道权限", errno)
            }
            guard listen(socketDescriptor, 4) == 0 else {
                throw SecureFileFailure.posix("无法监听宿主界面响应通道", errno)
            }
        } catch {
            invalidate()
            throw error
        }
    }

    func receiveResponse() -> Response? {
        while true {
            let listeningDescriptor = currentDescriptor()
            guard listeningDescriptor >= 0 else { return nil }

            var pollDescriptor = pollfd(
                fd: listeningDescriptor,
                events: Int16(POLLIN),
                revents: 0
            )
            let pollResult = Darwin.poll(
                &pollDescriptor,
                1,
                Self.pollIntervalMilliseconds
            )
            guard isActive(listeningDescriptor) else { return nil }
            if pollResult < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if pollResult == 0 { continue }
            let failureEvents = Int16(POLLERR | POLLHUP | POLLNVAL)
            if pollDescriptor.revents & failureEvents != 0 { return nil }
            guard pollDescriptor.revents & Int16(POLLIN) != 0 else { continue }

            lock.lock()
            guard descriptor == listeningDescriptor else {
                lock.unlock()
                return nil
            }
            let client = accept(listeningDescriptor, nil, nil)
            let acceptError = errno
            lock.unlock()
            if client < 0 {
                if acceptError == EINTR ||
                    acceptError == EAGAIN ||
                    acceptError == EWOULDBLOCK {
                    continue
                }
                return nil
            }
            defer { _ = close(client) }

            let clientFlags = fcntl(client, F_GETFL)
            guard clientFlags >= 0,
                  fcntl(client, F_SETFL, clientFlags | O_NONBLOCK) == 0 else {
                continue
            }

            var peerPID: pid_t = 0
            var peerPIDSize = socklen_t(MemoryLayout<pid_t>.size)
            guard getsockopt(
                client,
                SOL_LOCAL,
                LOCAL_PEERPID,
                &peerPID,
                &peerPIDSize
            ) == 0,
            HostCodeIdentity.codeHash(processIdentifier: peerPID) == expectedHostCodeHash else {
                continue
            }

            // A host probe connects only to authenticate this server and closes
            // without a payload. Malformed/truncated authenticated connections
            // must not terminate the real request listener.
            guard let response = readResponse(
                from: client,
                whileListeningOn: listeningDescriptor
            ) else { continue }
            guard response.requestID == requestID,
                  response.requestDigest == expectedRequestDigest else {
                continue
            }
            return response
        }
    }

    func invalidate() {
        lock.lock()
        let socketDescriptor = descriptor
        descriptor = -1
        lock.unlock()
        if socketDescriptor >= 0 {
            _ = shutdown(socketDescriptor, SHUT_RDWR)
            _ = close(socketDescriptor)
        }
        socketPath.withCString { _ = unlink($0) }
    }

    private func readResponse(
        from client: Int32,
        whileListeningOn listeningDescriptor: Int32
    ) -> Response? {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: Self.responseReadTimeout)
        var data = Data()
        var reachedEndOfStream = false
        var buffer = [UInt8](repeating: 0, count: 1024)

        while data.count <= maximumResponseSize, clock.now < deadline {
            guard isActive(listeningDescriptor) else { return nil }
            var pollDescriptor = pollfd(
                fd: client,
                events: Int16(POLLIN | POLLHUP),
                revents: 0
            )
            let pollResult = Darwin.poll(
                &pollDescriptor,
                1,
                Self.pollIntervalMilliseconds
            )
            guard isActive(listeningDescriptor) else { return nil }
            if pollResult < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if pollResult == 0 { continue }
            let failureEvents = Int16(POLLERR | POLLNVAL)
            if pollDescriptor.revents & failureEvents != 0 { return nil }
            guard pollDescriptor.revents & Int16(POLLIN | POLLHUP) != 0 else {
                continue
            }

            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(client, $0.baseAddress, $0.count)
            }
            if count < 0 {
                if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK {
                    continue
                }
                return nil
            }
            if count == 0 {
                reachedEndOfStream = true
                break
            }
            data.append(contentsOf: buffer.prefix(count))
        }

        guard reachedEndOfStream,
              isActive(listeningDescriptor),
              !data.isEmpty,
              data.count <= maximumResponseSize else {
            return nil
        }
        return try? JSONDecoder().decode(
            Response.self,
            from: data
        )
    }

    private func currentDescriptor() -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        return descriptor
    }

    private func isActive(_ candidate: Int32) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return descriptor == candidate
    }

    deinit {
        invalidate()
    }
}

/// Compatibility wrapper retained for the permanent-delete path and its tests.
/// New host-owned UI should use `AuthenticatedHostResponseServer` directly.
final class AuthenticatedDestructiveConfirmationServer: @unchecked Sendable {
    private let server: AuthenticatedHostResponseServer<DestructiveConfirmationResponse>

    var socketPath: String { server.socketPath }

    static func makeSocketPath() -> String {
        AuthenticatedHostResponseServer<DestructiveConfirmationResponse>.makeSocketPath()
    }

    init(
        socketPath: String,
        requestID: UUID,
        expectedHostCodeHash: Data,
        expectedRequestDigest: Data
    ) throws {
        server = try AuthenticatedHostResponseServer(
            socketPath: socketPath,
            requestID: requestID,
            expectedHostCodeHash: expectedHostCodeHash,
            expectedRequestDigest: expectedRequestDigest
        )
    }

    func receiveResponse() -> Bool {
        server.receiveResponse()?.approved ?? false
    }

    func invalidate() {
        server.invalidate()
    }
}

struct OperationFailure: LocalizedError, CustomStringConvertible, Sendable {
    let key: String
    let arguments: [String]

    init(description: String) {
        key = description
        arguments = []
    }

    init(_ key: String, arguments: [String] = []) {
        self.key = key
        self.arguments = arguments
    }

    var description: String {
        message(language: .simplifiedChinese)
    }

    var errorDescription: String? { description }

    func message(language: AppLanguage) -> String {
        Localizer.format(
            key,
            language: language,
            arguments: arguments.map { $0 as CVarArg }
        )
    }
}

enum PathSafety {
    static func standardized(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    static func isProtected(_ url: URL) -> Bool {
        let path = standardized(url).path
        let home = standardized(Self.realHome).path
        if path == "/" || path == home { return true }
        let protectedRoots = [
            "/System", "/usr", "/bin", "/sbin", "/Library",
            "/Applications", "/private",
        ]
        if protectedRoots.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
            return true
        }
        let bundle = standardized(Bundle.main.bundleURL).path
        return path == bundle || path.hasPrefix(bundle + "/") || bundle.hasPrefix(path + "/")
    }

    static var realHome: URL {
        UserPaths.homeDirectory
    }
}

enum UniqueName {
    static func candidateURL(
        in directory: URL,
        baseName: String,
        fileExtension: String?,
        index: Int
    ) -> URL {
        let ext = fileExtension?.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let suffix = index == 1 ? "" : " \(index)"
        let name = baseName + suffix
        if let ext, !ext.isEmpty {
            return directory.appendingPathComponent(name).appendingPathExtension(ext)
        }
        return directory.appendingPathComponent(name)
    }

    static func availableURL(
        in directory: URL,
        baseName: String,
        fileExtension: String?,
        fileManager: FileManager = .default
    ) -> URL {
        var index = 1
        while fileManager.fileExists(atPath: candidateURL(
            in: directory,
            baseName: baseName,
            fileExtension: fileExtension,
            index: index
        ).path) {
            index += 1
        }
        return candidateURL(
            in: directory,
            baseName: baseName,
            fileExtension: fileExtension,
            index: index
        )
    }

    static func validatedFilename(_ value: String) throws -> String {
        let result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty, result != ".", result != "..", !result.contains("/") else {
            throw OperationFailure(description: "文件名不能为空，也不能包含“/”。")
        }
        guard result.utf8.count <= 255 else {
            throw OperationFailure(description: "文件名过长。")
        }
        return result
    }

    static func validatedExtension(_ value: String) throws -> String {
        let result = value.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        guard !result.isEmpty, result.count <= 20,
              result.unicodeScalars.allSatisfy({
                  CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_")).contains($0)
              }) else {
            throw OperationFailure(description: "文件后缀无效。")
        }
        return result
    }
}

typealias PermanentDeleteConfirmationProvider = @MainActor @Sendable ([URL]) async -> Bool

/// A stable identity for a directory entry. Paths alone are unsafe for deferred
/// destructive operations because another item can replace the original path
/// between the menu action and execution on the file-operation queue.
private struct FileIdentity: Codable, Hashable, Sendable {
    let device: UInt64
    let inode: UInt64
    let fileType: UInt32

    init(status: stat) {
        device = UInt64(status.st_dev)
        inode = UInt64(status.st_ino)
        fileType = UInt32(status.st_mode & S_IFMT)
    }

    static func capture(at url: URL) -> FileIdentity? {
        guard case let .found(identity) = captureResult(at: url) else {
            return nil
        }
        return identity
    }

    static func captureResult(at url: URL) -> FileIdentityCaptureResult {
        var status = stat()
        guard url.standardizedFileURL.path.withCString({ lstat($0, &status) }) == 0 else {
            let code = errno
            return code == ENOENT ? .missing : .unavailable(code)
        }
        return .found(FileIdentity(status: status))
    }

    func matchesEntry(at url: URL) -> Bool {
        guard let current = Self.capture(at: url) else { return false }
        return current == self
    }

    /// Resolves the source and target independently through kernel-backed file
    /// descriptors. Do not walk `..` from the target descriptor: an implicit
    /// NSOpenPanel scope grants the selected directory and its descendants, but
    /// intentionally may not grant its parent (a normal sibling transfer).
    ///
    /// `F_GETPATH` supplies the kernel-resolved spelling for both sides, which
    /// handles symlinked paths and case-insensitive volumes. If the requested
    /// target does not exist yet, only its nearest lexically-addressable existing
    /// ancestor is opened and the missing components are appended. `nil` means
    /// the relationship could not be verified safely.
    func isAncestor(
        entryAt sourceURL: URL,
        ofDirectoryAt requestedURL: URL
    ) -> Bool? {
        guard fileType == UInt32(S_IFDIR) else { return false }

        guard let source = Self.openedDirectoryLocation(
            at: sourceURL,
            followFinalSymlink: false,
            allowMissing: false
        ), source.identity == self,
        let target = Self.openedDirectoryLocation(
            at: requestedURL,
            followFinalSymlink: true,
            allowMissing: true
        ) else { return nil }

        if source.identity.device == target.identity.device,
           source.identity.inode == target.identity.inode {
            return true
        }

        guard target.pathComponents.count >= source.pathComponents.count else {
            return false
        }
        let caseSensitive = source.volumeIsCaseSensitive
        for index in source.pathComponents.indices {
            let sourceComponent = source.pathComponents[index]
            let targetComponent = target.pathComponents[index]
            if caseSensitive {
                guard sourceComponent == targetComponent else { return false }
            } else {
                guard sourceComponent.compare(
                    targetComponent,
                    options: [.caseInsensitive],
                    range: nil,
                    locale: Locale(identifier: "en_US_POSIX")
                ) == .orderedSame else { return false }
            }
        }
        return true
    }

    private struct OpenedDirectoryLocation {
        let identity: FileIdentity
        let pathComponents: [String]
        let volumeIsCaseSensitive: Bool
    }

    private static func openedDirectoryLocation(
        at input: URL,
        followFinalSymlink: Bool,
        allowMissing: Bool
    ) -> OpenedDirectoryLocation? {
        var candidate = input.standardizedFileURL
        var missingComponents: [String] = []

        while true {
            let noFollow = followFinalSymlink ? 0 : O_NOFOLLOW
            let descriptor = candidate.path.withCString {
                open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | noFollow)
            }
            if descriptor >= 0 {
                defer { _ = close(descriptor) }
                var status = stat()
                guard fstat(descriptor, &status) == 0,
                      let kernelPath = kernelPath(for: descriptor) else {
                    return nil
                }
                var components = URL(fileURLWithPath: kernelPath)
                    .standardizedFileURL.pathComponents
                components.append(contentsOf: missingComponents)
                // If volume metadata is unavailable, assuming case-insensitive
                // can only reject an otherwise safe transfer; it cannot permit a
                // recursive self-copy on a case-insensitive volume.
                let caseSensitive = (try? URL(fileURLWithPath: kernelPath)
                    .resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
                    .volumeSupportsCaseSensitiveNames) ?? false
                return OpenedDirectoryLocation(
                    identity: FileIdentity(status: status),
                    pathComponents: components,
                    volumeIsCaseSensitive: caseSensitive
                )
            }

            let code = errno
            guard allowMissing, code == ENOENT else { return nil }
            let parent = candidate.deletingLastPathComponent()
            let component = candidate.lastPathComponent
            guard !component.isEmpty,
                  component != ".",
                  component != "..",
                  parent.path != candidate.path else { return nil }
            missingComponents.insert(component, at: 0)
            candidate = parent
        }
    }

    private static func kernelPath(for descriptor: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let result = buffer.withUnsafeMutableBufferPointer { pointer in
            fcntl(
                descriptor,
                F_GETPATH,
                UnsafeMutableRawPointer(pointer.baseAddress!)
            )
        }
        guard result == 0 else { return nil }
        let end = buffer.firstIndex(of: 0) ?? buffer.endIndex
        return String(
            decoding: buffer[..<end].map { UInt8(bitPattern: $0) },
            as: UTF8.self
        )
    }
}

private enum FileIdentityCaptureResult: Sendable {
    case found(FileIdentity)
    case missing
    case unavailable(Int32)
}

/// Captures both the directory entry and the directory reached by following a
/// final symlink. This preserves symlink-to-directory shortcuts while detecting
/// replacement of either the link or its destination before every mutation.
private struct DirectoryIdentity: Sendable, Equatable {
    let entry: FileIdentity
    let resolvedDirectory: FileIdentity

    static func captureResult(at url: URL) -> DirectoryIdentityCaptureResult {
        switch FileIdentity.captureResult(at: url) {
        case let .found(entry):
            var status = stat()
            guard url.standardizedFileURL.path.withCString({ stat($0, &status) }) == 0 else {
                return .unavailable(errno)
            }
            let resolved = FileIdentity(status: status)
            guard resolved.fileType == UInt32(S_IFDIR) else {
                return .notDirectory
            }
            return .found(DirectoryIdentity(entry: entry, resolvedDirectory: resolved))
        case .missing:
            return .missing
        case let .unavailable(code):
            return .unavailable(code)
        }
    }

    func stillMatches(at url: URL) -> Bool {
        guard case let .found(current) = Self.captureResult(at: url) else {
            return false
        }
        return current == self
    }
}

private enum DirectoryIdentityCaptureResult: Sendable {
    case found(DirectoryIdentity)
    case missing
    case notDirectory
    case unavailable(Int32)
}

private enum DirectoryTargetExpectation: Sendable {
    case existing(DirectoryIdentity)
    case missing
    case invalid
    case unavailable(Int32)

    static func capture(at url: URL) -> DirectoryTargetExpectation {
        switch DirectoryIdentity.captureResult(at: url) {
        case let .found(identity): .existing(identity)
        case .missing: .missing
        case .notDirectory: .invalid
        case let .unavailable(code): .unavailable(code)
        }
    }
}

private struct CutItemSnapshot: Codable, Hashable, Sendable {
    let path: String
    let identity: FileIdentity
    var wasTemporarilyHidden: Bool

    var url: URL { URL(fileURLWithPath: path) }

    func stillMatches() -> Bool {
        identity.matchesEntry(at: url)
    }
}

private struct CutSession: Codable, Hashable, Sendable {
    let id: UUID
    var items: [CutItemSnapshot]
}

/// A tiny awaitable result used by `FileOperationWorker`. The serial Dispatch
/// queue is entered synchronously in `enqueue`, so jobs retain the exact order
/// in which Finder menu actions submitted them.
private final class FileOperationResultBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Value?
    private var waiters: [CheckedContinuation<Value, Never>] = []

    func resolve(_ value: Value) {
        lock.lock()
        precondition(result == nil, "A file-operation result can only be resolved once")
        result = value
        let pending = waiters
        waiters.removeAll()
        lock.unlock()
        pending.forEach { $0.resume(returning: value) }
    }

    func value() async -> Value {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(returning: result)
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }
}

private struct FileOperationTicket<Value: Sendable>: Sendable {
    private let box: FileOperationResultBox<Value>

    init(box: FileOperationResultBox<Value>) {
        self.box = box
    }

    func value() async -> Value {
        await box.value()
    }
}

private final class FileOperationWorker: @unchecked Sendable {
    private let queue = DispatchQueue(
        label: "local.SuperRightClick.file-operations",
        qos: .userInitiated
    )

    func enqueue<Value: Sendable>(
        _ operation: @escaping @Sendable () -> Value
    ) -> FileOperationTicket<Value> {
        let box = FileOperationResultBox<Value>()
        queue.async {
            box.resolve(operation())
        }
        return FileOperationTicket(box: box)
    }
}

/// Foundation documents FileManager's methods as safe to call from multiple
/// threads. The SDK type has not adopted Sendable, so confine this explicit
/// unchecked wrapper to the single serial file-operation queue.
private final class SendableFileManager: @unchecked Sendable {
    let value: FileManager

    init(_ value: FileManager) {
        self.value = value
    }
}

private struct FileOperationIssue: Sendable {
    let url: URL
    let message: String
}

private struct TransferSource: Sendable {
    let url: URL
    let expectedIdentity: FileIdentity?
    let restoreVisibilityAfterMove: Bool
}

private struct TransferResult: Sendable {
    let failedSources: [URL]
    let issues: [FileOperationIssue]
    let movedSources: [URL]
    let visibilityRestorationFailures: [CutItemSnapshot]
    let didPerformOperation: Bool
}

private struct PendingPaste: Sendable {
    let ticket: FileOperationTicket<TransferResult>
    /// Non-nil means this paste consumes SuperRightClick's cut session. An
    /// empty array is meaningful when every recorded item became stale.
    let cutItems: [CutItemSnapshot]?
    /// Completion may update persisted cut state only if this exact session is
    /// still current. A later Cut action must always win over an older paste.
    let cutSessionID: UUID?
    let preliminaryIssues: [String]
}

private struct DissolveResult: Sendable {
    let didDissolve: Bool
    let issues: [FileOperationIssue]
}

private struct DeletionResult: Sendable {
    let deletedCount: Int
    let issues: [FileOperationIssue]
}

@MainActor
final class FeatureCoordinator {
    private let fileManager: FileManager
    private let backgroundFileManager: SendableFileManager
    private let requiresConfirmation: Bool
    private let templateStorageURL: URL?
    private let safetyPreferencesStore: SafetyPreferencesStore
    private let pasteboard: NSPasteboard
    private var permanentDeleteConfirmation: PermanentDeleteConfirmationProvider
    private let permanentDeletionWillIsolate: (@MainActor (URL) -> Void)?
    private let errorPresentation: (@MainActor (String) -> Void)?
    private let fileOperationWorker = FileOperationWorker()
    private var visibilityRestorationRetryTask: Task<Void, Never>?
    private(set) var configuration: MenuConfiguration
    private var configurationSnapshot: ConfigurationSnapshot
    private var legacyConfigurationMigrationComplete: Bool

    /// 测试必须传入独立的 configurationDefaults 并关闭 publishChanges，
    /// 否则测试数据会写入真实配置并通过分布式通知污染正在运行的应用。
    private let configurationDefaults: UserDefaults
    private let publishChanges: Bool

    init(
        fileManager: FileManager = .default,
        requiresConfirmation: Bool = true,
        templateStorageURL: URL? = nil,
        configurationDefaults: UserDefaults = .standard,
        publishChanges: Bool = true,
        safetyPreferencesStore: SafetyPreferencesStore = .production,
        pasteboard: NSPasteboard = .general,
        permanentDeleteConfirmation: PermanentDeleteConfirmationProvider? = nil,
        permanentDeletionWillIsolate: (@MainActor (URL) -> Void)? = nil,
        errorPresentation: (@MainActor (String) -> Void)? = nil
    ) {
        self.fileManager = fileManager
        backgroundFileManager = SendableFileManager(fileManager)
        self.requiresConfirmation = requiresConfirmation
        self.templateStorageURL = templateStorageURL
        self.configurationDefaults = configurationDefaults
        self.publishChanges = publishChanges
        self.safetyPreferencesStore = safetyPreferencesStore
        self.pasteboard = pasteboard
        self.permanentDeletionWillIsolate = permanentDeletionWillIsolate
        self.errorPresentation = errorPresentation
        self.permanentDeleteConfirmation = permanentDeleteConfirmation ?? { _ in false }
        let initialSnapshot = ConfigurationStore.loadSnapshot(defaults: configurationDefaults)
        let migration = ConfigurationStore.migrateLegacyExtensionAdditions(
            basedOn: initialSnapshot,
            defaults: configurationDefaults,
            publish: publishChanges
        )
        configurationSnapshot = migration.snapshot
        configuration = migration.snapshot.configuration
        legacyConfigurationMigrationComplete = migration.isComplete
        if permanentDeleteConfirmation == nil {
            self.permanentDeleteConfirmation = { [weak self] urls in
                guard let self else { return false }
                return await self.requestPermanentDeleteConfirmation(for: urls)
            }
        }
        if !loadPendingVisibilityRestorations().isEmpty {
            scheduleVisibilityRestorationRetry()
        }
    }

    func updateConfiguration(_ value: MenuConfiguration) {
        // Direct injection is used by tests and local feature toggles. It is not
        // evidence of a committed authoritative revision, so it must never run
        // resource garbage collection.
        configuration = value.validatedAndNormalized()
    }

    func updateConfiguration(_ snapshot: ConfigurationSnapshot) {
        guard snapshot.isAuthoritative else { return }
        var effectiveSnapshot = snapshot
        if !legacyConfigurationMigrationComplete {
            let migration = ConfigurationStore.migrateLegacyExtensionAdditions(
                basedOn: snapshot,
                defaults: configurationDefaults,
                publish: publishChanges
            )
            effectiveSnapshot = migration.snapshot
            legacyConfigurationMigrationComplete = migration.isComplete
        }
        let value = effectiveSnapshot.configuration.validatedAndNormalized()
        // Never garbage-collect against a fallback/non-authoritative baseline or
        // before every viable extension-only legacy template has committed to
        // the shared file. This keeps old template bytes recoverable throughout
        // migration and across transient shared-store failures.
        if legacyConfigurationMigrationComplete, configurationSnapshot.isAuthoritative {
            let retained = Set(value.templates.compactMap(\.storedFilename))
            let removed = configuration.templates.compactMap(\.storedFilename).filter {
                MenuConfiguration.isValidStoredTemplateFilename($0) && !retained.contains($0)
            }
            if !removed.isEmpty, let directory = try? templatesDirectory() {
                for filename in removed {
                    try? fileManager.removeItem(at: directory.appendingPathComponent(filename))
                }
            }
        }
        configuration = value
        configurationSnapshot = effectiveSnapshot
    }

    // MARK: - A class

    func create(templateID: UUID, in directory: URL, askForName: Bool = false) {
        guard let template = configuration.templates.first(where: { $0.id == templateID }) else {
            return showError(t("模板已不存在。"))
        }
        do {
            let requestedName: String
            if askForName {
                guard let value = prompt(
                    title: f("新建%@文件", template.name),
                    message: t("请输入文件名（可不填写后缀）"),
                    defaultValue: t("未命名")
                ) else { return }
                requestedName = try UniqueName.validatedFilename(value)
            } else {
                requestedName = t("未命名")
            }

            let supplied = URL(fileURLWithPath: requestedName)
            let baseName = supplied.deletingPathExtension().lastPathComponent
            let requestedExtension = supplied.pathExtension
            let finalExtension = try UniqueName.validatedExtension(
                requestedExtension.isEmpty ? template.fileExtension : requestedExtension
            )
            let output = UniqueName.availableURL(
                in: directory,
                baseName: baseName,
                fileExtension: finalExtension,
                fileManager: fileManager
            )
            try write(template: template, to: output)
            if configuration.playCreationSound { NSSound.beep() }
            if configuration.autoOpenNewFile {
                NSWorkspace.shared.open(output)
            } else {
                beginRename(of: output)
            }
        } catch {
            showError(errorText(error))
        }
    }

    /// 新建文件后选中它并触发 Finder 的重命名编辑状态。
    /// 主应用已运行时使用低延迟分布式通知；主应用未运行时从 Finder 扩展
    /// 包路径定位宿主 App，并以不抢焦点的方式携带文件路径启动它。
    private func beginRename(of url: URL) {
        guard requiresConfirmation else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])

        let isHostRunning = !NSRunningApplication.runningApplications(
            withBundleIdentifier: RenameRequestBridge.hostBundleIdentifier
        ).isEmpty
        if isHostRunning {
            ConfigurationStore.requestRename(url)
            return
        }

        guard let hostURL = Self.containingHostApplicationURL() else {
            ConfigurationStore.requestRename(url)
            return
        }
        let launchConfiguration = NSWorkspace.OpenConfiguration()
        launchConfiguration.activates = false
        launchConfiguration.addsToRecentItems = false
        launchConfiguration.arguments = [RenameRequestBridge.launchArgument, url.path]
        NSWorkspace.shared.openApplication(
            at: hostURL,
            configuration: launchConfiguration
        ) { _, error in
            // 极少数情况下 Launch Services 已启动 App 却仍返回错误；通知作为
            // 最后的无害回退，若 App 未启动则文件仍保持被 Finder 选中。
            if error != nil { ConfigurationStore.requestRename(url) }
        }
    }

    private static func containingHostApplicationURL() -> URL? {
        var candidate = Bundle.main.bundleURL.standardizedFileURL
        while candidate.path != "/" {
            if candidate.pathExtension.caseInsensitiveCompare("app") == .orderedSame {
                return candidate
            }
            candidate.deleteLastPathComponent()
        }
        return nil
    }

    func createNamedFile(in directory: URL) {
        let enabled = configuration.templates.filter(\.isEnabled)
        guard !enabled.isEmpty else { return showError(t("没有启用的新建模板。")) }
        let alert = NSAlert()
        alert.messageText = t("通过窗口创建新文件")
        alert.informativeText = t("输入文件名，并选择文件格式。")
        alert.addButton(withTitle: t("创建"))
        alert.addButton(withTitle: t("取消"))
        let field = NSTextField(string: t("未命名"))
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 260, height: 26))
        enabled.forEach { popup.addItem(withTitle: "\($0.name) (.\($0.fileExtension))") }
        let stack = NSStackView(views: [field, popup])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 280, height: 62)
        alert.accessoryView = stack
        guard runModalInFront(alert) == .alertFirstButtonReturn else { return }
        do {
            let filename = try UniqueName.validatedFilename(field.stringValue)
            let template = enabled[popup.indexOfSelectedItem]
            let supplied = URL(fileURLWithPath: filename)
            let ext = try UniqueName.validatedExtension(
                supplied.pathExtension.isEmpty ? template.fileExtension : supplied.pathExtension
            )
            let output = UniqueName.availableURL(
                in: directory,
                baseName: supplied.deletingPathExtension().lastPathComponent,
                fileExtension: ext,
                fileManager: fileManager
            )
            try write(template: template, to: output)
            if configuration.playCreationSound { NSSound.beep() }
            if configuration.autoOpenNewFile {
                NSWorkspace.shared.open(output)
            } else {
                beginRename(of: output)
            }
        } catch {
            showError(errorText(error))
        }
    }

    func importTemplate(from source: URL) {
        let rawExtension = source.pathExtension.lowercased()
        guard !rawExtension.isEmpty else {
            return showError(t("模板文件必须具有扩展名。"))
        }
        guard let name = prompt(
            title: t("添加自定义模板"),
            message: t("模板将复制到 SuperRightClick 的独立容器，不会修改原文件。"),
            defaultValue: source.deletingPathExtension().lastPathComponent
        ) else { return }
        do {
            try registerTemplate(from: source, name: name)
            showInfo(f("模板“%@”已添加。", name))
        } catch {
            showError(errorText(error))
        }
    }

    @discardableResult
    func registerTemplate(from source: URL, name: String) throws -> NewFileTemplate {
        let validName = try UniqueName.validatedFilename(name)
        let ext = try UniqueName.validatedExtension(source.pathExtension.lowercased())
        let directory = try templatesDirectory()
        let id = UUID()
        let storedName = "\(id.uuidString).\(ext)"
        let destination = directory.appendingPathComponent(storedName)
        try fileManager.copyItem(at: source, to: destination)
        let template = NewFileTemplate(
            id: id,
            name: validName,
            fileExtension: ext,
            kind: .custom,
            storedFilename: storedName
        )
        var workingSnapshot = configurationSnapshot
        var proposedBase = configuration

        for _ in 0..<2 {
            var proposed = proposedBase
            var replacedStoredFilename: String?
            // 同名同扩展名的模板视为替换，避免重复导入时菜单里堆积重复项。
            if let existing = proposed.templates.firstIndex(where: {
                $0.name.lowercased() == validName.lowercased()
                    && $0.fileExtension.lowercased() == ext
            }) {
                replacedStoredFilename = proposed.templates[existing].storedFilename
                proposed.templates[existing] = template
            } else {
                proposed.templates.append(template)
            }

            let result = ConfigurationStore.save(
                proposed,
                basedOn: workingSnapshot,
                defaults: configurationDefaults,
                publish: publishChanges
            )
            if let committed = result.committedSnapshot {
                configurationSnapshot = committed
                configuration = committed.configuration
                // The old referenced copy is removed only after the replacement
                // configuration has committed. A CAS failure can never destroy it.
                if let old = replacedStoredFilename,
                   old != storedName,
                   MenuConfiguration.isValidStoredTemplateFilename(old) {
                    try? fileManager.removeItem(at: directory.appendingPathComponent(old))
                }
                return template
            }
            if case let .conflict(latest?) = result {
                workingSnapshot = latest
                proposedBase = latest.configuration
                continue
            }
            break
        }

        // Roll back only the UUID-named file created by this invocation. Existing
        // user template data and the last committed configuration stay untouched.
        try? fileManager.removeItem(at: destination)
        let latest = ConfigurationStore.loadSnapshot(defaults: configurationDefaults)
        if latest.isAuthoritative {
            configurationSnapshot = latest
            configuration = latest.configuration
        } else if configurationDefaults === UserDefaults.standard {
            ConfigurationStore.requestAppConfiguration()
        }
        throw OperationFailure(description: "配置已被其他进程更新，请重试。")
    }

    private func write(template: NewFileTemplate, to output: URL) throws {
        switch template.kind {
        case .text, .markdown:
            try Data().write(to: output, options: .withoutOverwriting)
        case .richText:
            try Data("{\\rtf1\\ansi\\deff0\\n}".utf8).write(to: output, options: .withoutOverwriting)
        case .xml:
            try Data("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n".utf8)
                .write(to: output, options: .withoutOverwriting)
        case .custom:
            guard let filename = template.storedFilename,
                  MenuConfiguration.isValidStoredTemplateFilename(filename) else {
                throw OperationFailure(description: "自定义模板记录不完整。")
            }
            let source = try templatesDirectory().appendingPathComponent(filename)
            try fileManager.copyItem(at: source, to: output)
        }
    }

    private func templatesDirectory() throws -> URL {
        if let templateStorageURL {
            try fileManager.createDirectory(at: templateStorageURL, withIntermediateDirectories: true)
            return templateStorageURL
        }
        guard let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { throw OperationFailure(description: "无法定位模板目录。") }
        let directory = support
            .appendingPathComponent("SuperRightClick", isDirectory: true)
            .appendingPathComponent("Templates", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    // MARK: - B01/B02/B10/B11/B12

    /// Submits a transfer without blocking Finder's main thread. The serial
    /// worker preserves menu-action order even when a previous copy is large.
    func transfer(_ sources: [URL], to directory: URL, move: Bool) {
        guard !sources.isEmpty else { return }
        let transferSources = sources.map {
            TransferSource(
                url: $0,
                expectedIdentity: move ? FileIdentity.capture(at: $0) : nil,
                restoreVisibilityAfterMove: false
            )
        }
        let ticket = enqueueTransfer(transferSources, to: directory, move: move)
        Task { @MainActor [weak self] in
            let result = await ticket.value()
            self?.presentTransferResult(result)
        }
    }

    /// Deterministic async entry point used by regression tests and internal
    /// workflows that must update state only after the transfer has completed.
    @discardableResult
    func transferAndWait(_ sources: [URL], to directory: URL, move: Bool) async -> [URL] {
        guard !sources.isEmpty else { return [] }
        let transferSources = sources.map {
            TransferSource(
                url: $0,
                expectedIdentity: move ? FileIdentity.capture(at: $0) : nil,
                restoreVisibilityAfterMove: false
            )
        }
        let result = await enqueueTransfer(
            transferSources,
            to: directory,
            move: move
        ).value()
        presentTransferResult(result)
        return result.failedSources
    }

    private func enqueueTransfer(
        _ sources: [TransferSource],
        to directory: URL,
        move: Bool
    ) -> FileOperationTicket<TransferResult> {
        let fileManager = backgroundFileManager
        let language = configuration.language
        let targetExpectation = DirectoryTargetExpectation.capture(at: directory)
        return fileOperationWorker.enqueue {
            Self.performTransfer(
                sources,
                to: directory,
                move: move,
                targetExpectation: targetExpectation,
                fileManager: fileManager.value,
                language: language
            )
        }
    }

    nonisolated private static func performTransfer(
        _ sources: [TransferSource],
        to directory: URL,
        move: Bool,
        targetExpectation: DirectoryTargetExpectation,
        fileManager: FileManager,
        language: AppLanguage
    ) -> TransferResult {
        var failedSources: [URL] = []
        var issues: [FileOperationIssue] = []
        var movedSources: [URL] = []
        var visibilityRestorationFailures: [CutItemSnapshot] = []
        var didPerformOperation = false

        func issue(for url: URL, _ error: Error) -> FileOperationIssue {
            FileOperationIssue(
                url: url,
                message: Localizer.format(
                    "%@：%@",
                    language: language,
                    url.lastPathComponent,
                    errorText(error, language: language)
                )
            )
        }

        switch targetExpectation {
        case let .existing(identity) where !identity.stillMatches(at: directory):
            let failure = OperationFailure(description: "目标文件夹已被替换或无法访问。")
            return TransferResult(
                failedSources: sources.map(\.url),
                issues: [issue(for: directory, failure)],
                movedSources: [],
                visibilityRestorationFailures: [],
                didPerformOperation: false
            )
        case .invalid:
            let failure = OperationFailure(description: "目标位置不是文件夹。")
            return TransferResult(
                failedSources: sources.map(\.url),
                issues: [issue(for: directory, failure)],
                movedSources: [],
                visibilityRestorationFailures: [],
                didPerformOperation: false
            )
        case let .unavailable(code):
            let failure = OperationFailure(
                "目标文件夹无法安全验证（POSIX 错误 %@）。",
                arguments: [String(code)]
            )
            return TransferResult(
                failedSources: sources.map(\.url),
                issues: [issue(for: directory, failure)],
                movedSources: [],
                visibilityRestorationFailures: [],
                didPerformOperation: false
            )
        case .existing, .missing:
            break
        }

        // Validate sources before creating the destination. In particular, a
        // stale source whose path equals the requested destination must not be
        // recreated as a directory and then recursively copied into itself.
        var validated: [(source: TransferSource, identity: FileIdentity)] = []
        for source in sources {
            guard let currentIdentity = FileIdentity.capture(at: source.url) else {
                failedSources.append(source.url)
                issues.append(FileOperationIssue(
                    url: source.url,
                    message: Localizer.format(
                        "%@：目标已不存在或无法访问。",
                        language: language,
                        source.url.lastPathComponent
                    )
                ))
                continue
            }
            // A move is destructive. Identity capture failure at submission is
            // not permission to recapture later and move a replacement object.
            if move {
                guard let expectedIdentity = source.expectedIdentity,
                      expectedIdentity == currentIdentity else {
                    failedSources.append(source.url)
                    issues.append(FileOperationIssue(
                        url: source.url,
                        message: Localizer.format(
                            "%@：源项目身份无法安全验证或已被替换。",
                            language: language,
                            source.url.lastPathComponent
                        )
                    ))
                    continue
                }
            }
            validated.append((source, currentIdentity))
        }

        var eligible: [(source: TransferSource, identity: FileIdentity)] = []
        for item in validated {
            switch item.identity.isAncestor(
                entryAt: item.source.url,
                ofDirectoryAt: directory
            ) {
            case true:
                failedSources.append(item.source.url)
                issues.append(issue(
                    for: item.source.url,
                    OperationFailure(description: "不能将项目放入它自身的子目录。")
                ))
            case nil where item.identity.fileType == UInt32(S_IFDIR):
                failedSources.append(item.source.url)
                issues.append(issue(
                    for: item.source.url,
                    OperationFailure(description: "无法安全验证源文件夹与目标文件夹的关系。")
                ))
            default:
                eligible.append(item)
            }
        }

        guard !eligible.isEmpty else {
            return TransferResult(
                failedSources: failedSources,
                issues: issues,
                movedSources: [],
                visibilityRestorationFailures: [],
                didPerformOperation: false
            )
        }

        if case .missing = targetExpectation {
            do {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                let pending = eligible.map(\.source.url)
                failedSources.append(contentsOf: pending)
                issues.append(issue(for: directory, error))
                return TransferResult(
                    failedSources: failedSources,
                    issues: issues,
                    movedSources: [],
                    visibilityRestorationFailures: [],
                    didPerformOperation: false
                )
            }
        }

        guard case let .found(activeDirectoryIdentity) = DirectoryIdentity.captureResult(at: directory),
              {
                  if case let .existing(expectedIdentity) = targetExpectation {
                      return expectedIdentity == activeDirectoryIdentity
                  }
                  return true
              }() else {
            let pending = eligible.map(\.source.url)
            failedSources.append(contentsOf: pending)
            issues.append(issue(
                for: directory,
                OperationFailure(description: "目标文件夹已被替换或无法访问。")
            ))
            return TransferResult(
                failedSources: failedSources,
                issues: issues,
                movedSources: [],
                visibilityRestorationFailures: [],
                didPerformOperation: false
            )
        }

        for (source, capturedIdentity) in eligible {
            do {
                guard activeDirectoryIdentity.stillMatches(at: directory) else {
                    throw OperationFailure(description: "目标文件夹已被替换或无法访问。")
                }
                // Revalidate deferred move operations immediately before the
                // destructive rename; never move a replacement at the same path.
                if move, !capturedIdentity.matchesEntry(at: source.url) {
                    throw OperationFailure(description: "目标已不存在或无法访问。")
                }

                // Moving to the current parent is a completed no-op. A cut item
                // still needs its temporary hidden flag restored.
                let sourceParentIdentity: DirectoryIdentity? = {
                    guard case let .found(identity) = DirectoryIdentity.captureResult(
                        at: source.url.deletingLastPathComponent()
                    ) else { return nil }
                    return identity
                }()
                if move,
                   sourceParentIdentity?.resolvedDirectory
                    == activeDirectoryIdentity.resolvedDirectory {
                    if source.restoreVisibilityAfterMove {
                        try setHidden(false, at: source.url)
                        didPerformOperation = true
                    }
                    movedSources.append(source.url)
                    continue
                }

                let destination = UniqueName.availableURL(
                    in: directory,
                    baseName: source.url.deletingPathExtension().lastPathComponent,
                    fileExtension: source.url.pathExtension.isEmpty
                        ? nil
                        : source.url.pathExtension,
                    fileManager: fileManager
                )
                if move {
                    try fileManager.moveItem(at: source.url, to: destination)
                    movedSources.append(source.url)
                    if source.restoreVisibilityAfterMove {
                        do {
                            try setHidden(false, at: destination)
                        } catch {
                            issues.append(issue(for: destination, error))
                            if let identity = FileIdentity.capture(at: destination) {
                                visibilityRestorationFailures.append(CutItemSnapshot(
                                    path: destination.standardizedFileURL.path,
                                    identity: identity,
                                    wasTemporarilyHidden: true
                                ))
                            }
                        }
                    }
                } else {
                    try fileManager.copyItem(at: source.url, to: destination)
                }
                didPerformOperation = true
            } catch {
                failedSources.append(source.url)
                issues.append(issue(for: source.url, error))
            }
        }

        return TransferResult(
            failedSources: failedSources,
            issues: issues,
            movedSources: movedSources,
            visibilityRestorationFailures: visibilityRestorationFailures,
            didPerformOperation: didPerformOperation
        )
    }

    nonisolated private static func setHidden(_ hidden: Bool, at input: URL) throws {
        var url = input
        var values = URLResourceValues()
        values.isHidden = hidden
        try url.setResourceValues(values)
    }

    private func presentTransferResult(
        _ result: TransferResult,
        additionalIssues: [String] = []
    ) {
        let messages = additionalIssues + result.issues.map(\.message)
        if messages.isEmpty {
            if result.didPerformOperation { playOperationSound() }
        } else {
            showError(messages.joined(separator: "\n"))
        }
    }

    func chooseTransferDestination(for sources: [URL], move: Bool) async {
        guard !sources.isEmpty else { return }
        // Capture destructive source identities before the user spends time in
        // the picker. A replacement appearing at the same path must never be
        // moved when the panel eventually closes.
        let preparedSources = sources.map {
            TransferSource(
                url: $0,
                expectedIdentity: move ? FileIdentity.capture(at: $0) : nil,
                restoreVisibilityAfterMove: false
            )
        }
        guard !move || preparedSources.allSatisfy({ $0.expectedIdentity != nil }) else {
            showError(t("一个或多个源项目已不存在或无法访问。"))
            return
        }
        guard
              let bookmark = await requestTransferDestination(
                  operation: move ? .move : .copy,
                  sourceItemCount: sources.count
              ) else { return }

        do {
            let resolution = try TransferDestinationPickerBridge
                .resolveEphemeralBookmark(bookmark)
            let target = resolution.url
            // Resolving an interprocess bookmark implicitly starts its
            // ephemeral sandbox scope for this extension process. Balance that
            // scope even when resource validation below fails.
            defer { target.stopAccessingSecurityScopedResource() }
            guard try target.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
                throw OperationFailure(description: "所选目标文件夹已失效，请重新选择。")
            }

            let result = await enqueueTransfer(
                preparedSources,
                to: target,
                move: move
            ).value()
            presentTransferResult(result)
        } catch {
            showError(errorText(error))
        }
    }

    func cut(_ urls: [URL]) {
        // Do not overwrite the only recovery record when a previous hidden cut
        // item could not be made visible again. The user can retry after fixing
        // permissions, while replacement objects are never touched.
        guard restorePreviouslyHiddenCutItems() else { return }
        var snapshots: [CutItemSnapshot] = []
        var issues: [String] = []
        var seen = Set<String>()

        for input in urls {
            let url = input.standardizedFileURL
            guard seen.insert(url.path).inserted else { continue }
            guard let identity = FileIdentity.capture(at: url) else {
                issues.append(f("%@：目标已不存在或无法访问。", url.lastPathComponent))
                continue
            }

            var snapshot = CutItemSnapshot(
                path: url.path,
                identity: identity,
                wasTemporarilyHidden: false
            )
            if configuration.hideCutItems,
               (try? url.resourceValues(forKeys: [.isHiddenKey]).isHidden) != true {
                do {
                    try Self.setHidden(true, at: url)
                    snapshot.wasTemporarilyHidden = true
                } catch {
                    issues.append(f("%@：%@", url.lastPathComponent, errorText(error)))
                }
            }
            snapshots.append(snapshot)
        }

        saveCutSession(
            snapshots.isEmpty ? nil : CutSession(id: UUID(), items: snapshots)
        )
        if !issues.isEmpty { showError(issues.joined(separator: "\n")) }
    }

    func paste(into directory: URL) {
        guard let pending = preparePaste(into: directory) else { return }
        Task { @MainActor [weak self] in
            let result = await pending.ticket.value()
            self?.completePaste(pending, result: result)
        }
    }

    func pasteAndWait(into directory: URL) async {
        guard let pending = preparePaste(into: directory) else { return }
        let result = await pending.ticket.value()
        completePaste(pending, result: result)
    }

    private func preparePaste(into directory: URL) -> PendingPaste? {
        let session = loadCutSession()
        let recorded = session?.items ?? []
        let valid = recorded.filter { $0.stillMatches() }
        let stale = recorded.filter { !$0.stillMatches() }

        if !valid.isEmpty, let session {
            // Drop stale records before deferring the move. This prevents a new
            // filesystem object at an old path from ever becoming a cut target.
            guard compareAndSetCutSession(
                expectedID: session.id,
                replacementItems: valid
            ) else {
                showError(t("剪切内容已在另一个 Finder 窗口中更新，请重试粘贴。"))
                return nil
            }
            let sources = valid.map {
                TransferSource(
                    url: $0.url,
                    expectedIdentity: $0.identity,
                    restoreVisibilityAfterMove: $0.wasTemporarilyHidden
                )
            }
            let staleIssues = stale.map {
                f("%@：目标已不存在或无法访问。", $0.url.lastPathComponent)
            }
            return PendingPaste(
                ticket: enqueueTransfer(sources, to: directory, move: true),
                cutItems: valid,
                cutSessionID: session.id,
                preliminaryIssues: staleIssues
            )
        }

        // An all-stale SuperRightClick cut session must not shadow the current
        // system clipboard. Clear it and continue with ordinary copy/paste.
        if let session {
            _ = compareAndSetCutSession(expectedID: session.id, replacementItems: [])
        } else if hasLegacyCutState {
            clearCutState()
        }
        let copied = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
        guard !copied.isEmpty else {
            showError(t("剪贴板中没有可粘贴的文件。"))
            return nil
        }
        let sources = copied.map {
            TransferSource(
                url: $0,
                expectedIdentity: nil,
                restoreVisibilityAfterMove: false
            )
        }
        return PendingPaste(
            ticket: enqueueTransfer(sources, to: directory, move: false),
            cutItems: nil,
            cutSessionID: nil,
            preliminaryIssues: []
        )
    }

    private func completePaste(_ pending: PendingPaste, result: TransferResult) {
        if let cutItems = pending.cutItems, let sessionID = pending.cutSessionID {
            let failedPaths = Set(result.failedSources.map { $0.standardizedFileURL.path })
            let remaining = cutItems.filter {
                failedPaths.contains($0.path) && $0.stillMatches()
            }
            // A Cut action performed while this paste was running owns a new
            // session UUID. Never let this older completion erase it.
            _ = compareAndSetCutSession(
                expectedID: sessionID,
                replacementItems: remaining
            )
        }
        if !result.visibilityRestorationFailures.isEmpty {
            let combined = loadPendingVisibilityRestorations()
                + result.visibilityRestorationFailures
            var seen = Set<CutItemSnapshot>()
            savePendingVisibilityRestorations(combined.filter { seen.insert($0).inserted })
            scheduleVisibilityRestorationRetry()
        }
        presentTransferResult(result, additionalIssues: pending.preliminaryIssues)
    }

    private static let cutItemsKey = "cutItemSnapshotsV2"
    private static let pendingVisibilityRestorationsKey = "pendingVisibilityRestorationsV2"
    private static let legacyCutPathsKey = "cutPaths"
    private static let legacyHiddenCutPathsKey = "hiddenCutPaths"

    private var hasLegacyCutState: Bool {
        !(configurationDefaults.stringArray(forKey: Self.legacyCutPathsKey) ?? []).isEmpty
            || !(configurationDefaults.stringArray(
                forKey: Self.legacyHiddenCutPathsKey
            ) ?? []).isEmpty
    }

    static func hasPersistedCutItems(in defaults: UserDefaults = .standard) -> Bool {
        guard let data = defaults.data(forKey: cutItemsKey) else {
            return !(defaults.stringArray(forKey: legacyCutPathsKey) ?? []).isEmpty
        }
        if let session = try? JSONDecoder().decode(CutSession.self, from: data) {
            return !session.items.isEmpty
        }
        // Backward compatibility with the initial V2 array representation.
        return (try? JSONDecoder().decode([CutItemSnapshot].self, from: data).isEmpty) == false
    }

    private func loadCutSession() -> CutSession? {
        guard let data = configurationDefaults.data(forKey: Self.cutItemsKey) else {
            return nil
        }
        if let session = try? JSONDecoder().decode(CutSession.self, from: data),
           !session.items.isEmpty {
            return session
        }
        // Migrate the initial V2 array in-place. The UUID makes all subsequent
        // asynchronous completion updates compare-and-set operations.
        if let items = try? JSONDecoder().decode([CutItemSnapshot].self, from: data),
           !items.isEmpty {
            let session = CutSession(id: UUID(), items: items)
            saveCutSession(session)
            return session
        }
        return nil
    }

    private func saveCutSession(_ session: CutSession?) {
        configurationDefaults.removeObject(forKey: Self.legacyCutPathsKey)
        configurationDefaults.removeObject(forKey: Self.legacyHiddenCutPathsKey)
        guard let session, !session.items.isEmpty else {
            configurationDefaults.removeObject(forKey: Self.cutItemsKey)
            return
        }
        if let data = try? JSONEncoder().encode(session) {
            configurationDefaults.set(data, forKey: Self.cutItemsKey)
        }
    }

    @discardableResult
    private func compareAndSetCutSession(
        expectedID: UUID,
        replacementItems: [CutItemSnapshot]
    ) -> Bool {
        guard let current = loadCutSession(), current.id == expectedID else {
            return false
        }
        saveCutSession(
            replacementItems.isEmpty
                ? nil
                : CutSession(id: expectedID, items: replacementItems)
        )
        return true
    }

    private func clearCutState() {
        configurationDefaults.removeObject(forKey: Self.cutItemsKey)
        configurationDefaults.removeObject(forKey: Self.legacyCutPathsKey)
        configurationDefaults.removeObject(forKey: Self.legacyHiddenCutPathsKey)
    }

    private func loadPendingVisibilityRestorations() -> [CutItemSnapshot] {
        guard let data = configurationDefaults.data(
            forKey: Self.pendingVisibilityRestorationsKey
        ), let items = try? JSONDecoder().decode([CutItemSnapshot].self, from: data) else {
            return []
        }
        return items
    }

    private func savePendingVisibilityRestorations(_ items: [CutItemSnapshot]) {
        guard !items.isEmpty else {
            configurationDefaults.removeObject(forKey: Self.pendingVisibilityRestorationsKey)
            return
        }
        if let data = try? JSONEncoder().encode(items) {
            configurationDefaults.set(data, forKey: Self.pendingVisibilityRestorationsKey)
        }
    }

    /// Visibility restoration failures are recoverable (for example, a volume
    /// can be briefly unavailable). Retry quietly while this extension instance
    /// remains alive instead of waiting for the user to perform another Cut.
    private func scheduleVisibilityRestorationRetry() {
        visibilityRestorationRetryTask?.cancel()
        visibilityRestorationRetryTask = Task { @MainActor [weak self] in
            for delay in [1, 5, 30] {
                do {
                    try await Task.sleep(for: .seconds(delay))
                } catch {
                    return
                }
                guard let self else { return }
                if self.retryPendingVisibilityRestorations() { break }
            }
            self?.visibilityRestorationRetryTask = nil
        }
    }

    @discardableResult
    private func retryPendingVisibilityRestorations() -> Bool {
        var unresolved: [CutItemSnapshot] = []
        for snapshot in loadPendingVisibilityRestorations() where snapshot.stillMatches() {
            do {
                try Self.setHidden(false, at: snapshot.url)
            } catch {
                unresolved.append(snapshot)
            }
        }
        savePendingVisibilityRestorations(unresolved)
        return unresolved.isEmpty
    }

    @discardableResult
    private func restorePreviouslyHiddenCutItems() -> Bool {
        var issues: [String] = []
        let session = loadCutSession()
        let candidates = (session?.items ?? []).filter(\.wasTemporarilyHidden)
            + loadPendingVisibilityRestorations()
        var unresolved: [CutItemSnapshot] = []
        for snapshot in candidates where snapshot.stillMatches() {
            do {
                try Self.setHidden(false, at: snapshot.url)
            } catch {
                issues.append(f("%@：%@", snapshot.url.lastPathComponent, errorText(error)))
                unresolved.append(snapshot)
            }
        }
        // Legacy path-only state cannot be restored safely: the path may now
        // name an unrelated item. It is cleared without touching that entry.
        if let session {
            _ = compareAndSetCutSession(expectedID: session.id, replacementItems: [])
        } else {
            clearCutState()
        }
        savePendingVisibilityRestorations(unresolved)
        if !unresolved.isEmpty { scheduleVisibilityRestorationRetry() }
        if !issues.isEmpty { showError(issues.joined(separator: "\n")) }
        return unresolved.isEmpty
    }

    func createSameNameFolders(for urls: [URL]) {
        var created = false
        for url in urls where !url.hasDirectoryPath {
            let folder = UniqueName.availableURL(
                in: url.deletingLastPathComponent(),
                baseName: url.deletingPathExtension().lastPathComponent,
                fileExtension: nil,
                fileManager: fileManager
            )
            do {
                try fileManager.createDirectory(at: folder, withIntermediateDirectories: false)
                created = true
            } catch {
                showError(errorText(error))
            }
        }
        if created { playOperationSound() }
    }

    // MARK: - B03/B04

    func openDirectory(_ shortcutID: UUID) {
        guard let shortcut = configuration.commonDirectories.first(where: { $0.id == shortcutID })
        else { return }
        NSWorkspace.shared.open(shortcut.resolvedURL)
    }

    func addCommonDirectory(_ url: URL) {
        let normalized = PathSafety.standardized(url)
        var workingSnapshot = configurationSnapshot
        var proposedBase = configuration
        for _ in 0..<2 {
            guard !proposedBase.commonDirectories.contains(where: {
                PathSafety.standardized($0.resolvedURL) == normalized
            }) else {
                configuration = proposedBase
                if proposedBase == workingSnapshot.configuration {
                    configurationSnapshot = workingSnapshot
                }
                return showInfo(t("该目录已在常用目录中。"))
            }
            var proposed = proposedBase
            proposed.commonDirectories.append(
                DirectoryShortcut(name: url.lastPathComponent, path: url.path)
            )
            let result = ConfigurationStore.save(
                proposed,
                basedOn: workingSnapshot,
                defaults: configurationDefaults,
                publish: publishChanges
            )
            if let committed = result.committedSnapshot {
                configurationSnapshot = committed
                configuration = committed.configuration
                showInfo(t("已添加到常用目录。"))
                return
            }
            if case let .conflict(latest?) = result {
                workingSnapshot = latest
                proposedBase = latest.configuration
                continue
            }
            break
        }
        let latest = ConfigurationStore.loadSnapshot(defaults: configurationDefaults)
        if latest.isAuthoritative {
            configurationSnapshot = latest
            configuration = latest.configuration
        } else if configurationDefaults === UserDefaults.standard {
            ConfigurationStore.requestAppConfiguration()
        }
        showError(t("配置已被其他进程更新，请重试。"))
    }

    // MARK: - B05/B06/B07/B08

    func setFolderIcon(_ folder: URL) {
        guard let folderIdentity = FileIdentity.capture(at: folder),
              folderIdentity.fileType == UInt32(S_IFDIR) else {
            showError(t("所选文件夹已不存在或无法访问。"))
            return
        }
        Task { @MainActor [weak self] in
            guard let self,
                  let bookmark = await self.requestTransferDestination(
                      operation: .selectFolderIconImage,
                      sourceItemCount: 1
                  ) else { return }
            do {
                let resolution = try TransferDestinationPickerBridge
                    .resolveEphemeralBookmark(bookmark)
                let imageURL = resolution.url
                defer { imageURL.stopAccessingSecurityScopedResource() }
                guard let image = NSImage(contentsOf: imageURL) else {
                    throw OperationFailure(description: "无法读取所选图标图片。")
                }
                guard folderIdentity.matchesEntry(at: folder) else {
                    throw OperationFailure(description: "文件夹在选择图片期间已被替换，未设置图标。")
                }
                if !NSWorkspace.shared.setIcon(image, forFile: folder.path, options: []) {
                    throw OperationFailure(description: "Finder 未能设置文件夹图标。")
                }
                self.playOperationSound()
            } catch {
                self.showError(self.errorText(error))
            }
        }
    }

    func showFileInfo(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let language = configuration.language
        Task {
            let lines = await Task.detached(priority: .userInitiated) {
                Self.fileInfoLines(for: urls, language: language)
            }.value
            guard !Task.isCancelled else { return }
            let alert = NSAlert()
            alert.messageText = t("文件信息与摘要")
            alert.informativeText = lines.joined(separator: "\n")
            alert.addButton(withTitle: t("完成"))
            self.runModalInFront(alert)
        }
    }

    nonisolated private static func fileInfoLines(
        for urls: [URL],
        language: AppLanguage
    ) -> [String] {
        let locale = Localizer.locale(for: language)
        let dateFormatter = DateFormatter()
        dateFormatter.locale = locale
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .medium

        func byteCount(_ count: Int) -> String {
            let units = ["B", "KB", "MB", "GB", "TB", "PB"]
            var value = Double(count)
            var unitIndex = 0
            while value >= 1_000, unitIndex < units.count - 1 {
                value /= 1_000
                unitIndex += 1
            }
            let number = NumberFormatter()
            number.locale = locale
            number.maximumFractionDigits = unitIndex == 0 ? 0 : 1
            number.minimumFractionDigits = 0
            return "\(number.string(from: NSNumber(value: value)) ?? String(Int(value))) \(units[unitIndex])"
        }

        var lines: [String] = []
        for url in urls {
            lines.append(url.lastPathComponent)
            do {
                let values = try url.resourceValues(forKeys: [
                    .fileSizeKey, .totalFileAllocatedSizeKey, .contentModificationDateKey,
                    .isDirectoryKey,
                ])
                lines.append(Localizer.format(
                    "路径：%@",
                    language: language,
                    url.path
                ))
                if let size = values.totalFileAllocatedSize ?? values.fileSize {
                    lines.append(Localizer.format(
                        "大小：%@",
                        language: language,
                        byteCount(size)
                    ))
                }
                if let date = values.contentModificationDate {
                    lines.append(Localizer.format(
                        "修改：%@",
                        language: language,
                        dateFormatter.string(from: date)
                    ))
                }
                if values.isDirectory != true {
                    let hashes = try computeFileHashes(url)
                    lines.append("MD5: \(hashes.md5)")
                    lines.append("SHA1: \(hashes.sha1)")
                    lines.append("SHA256: \(hashes.sha256)")
                    lines.append("SHA512: \(hashes.sha512)")
                }
            } catch {
                lines.append(Localizer.format(
                    "读取失败：%@",
                    language: language,
                    errorText(error, language: language)
                ))
            }
            lines.append("")
        }
        return lines
    }

    func createDesktopAliases(for urls: [URL]) {
        let desktop = PathSafety.realHome.appendingPathComponent("Desktop", isDirectory: true)
        createAliases(for: urls, in: desktop)
    }

    func createAliases(for urls: [URL], in directory: URL) {
        var created = false
        for source in urls {
            do {
                let target = UniqueName.availableURL(
                    in: directory,
                    baseName: source.lastPathComponent,
                    fileExtension: "alias",
                    fileManager: fileManager
                )
                let data = try source.bookmarkData(
                    options: .suitableForBookmarkFile,
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
                try URL.writeBookmarkData(data, to: target)
                created = true
            } catch {
                showError(f(
                    "%@：%@",
                    source.lastPathComponent,
                    errorText(error)
                ))
            }
        }
        if created { playOperationSound() }
    }

    // MARK: - C01/C06/C27 用 App 打开

    func openWith(_ shortcutID: UUID, urls: [URL], currentDirectory: URL?) {
        guard let shortcut = configuration.openWithApps.first(where: { $0.id == shortcutID })
        else { return }
        let appURL = shortcut.appURL
        guard fileManager.fileExists(atPath: appURL.path) else {
            return showError(f("找不到应用：%@", shortcut.appPath))
        }
        var targets = urls.isEmpty ? (currentDirectory.map { [$0] } ?? []) : urls
        if shortcut.isTerminalApp {
            // 终端类应用：选中文件时进入其父目录。
            var seen = Set<String>()
            targets = targets
                .map { isDirectoryTarget($0) ? $0 : $0.deletingLastPathComponent() }
                .filter { seen.insert($0.path).inserted }
        }
        var preliminaryIssues: [String] = []
        targets = targets.filter { target in
            guard FileIdentity.capture(at: target) != nil else {
                preliminaryIssues.append(f(
                    "%@：目标已不存在或无法访问。",
                    target.lastPathComponent
                ))
                return false
            }
            return true
        }
        guard !targets.isEmpty else {
            if !preliminaryIssues.isEmpty {
                showError(preliminaryIssues.joined(separator: "\n"))
            }
            return
        }
        let language = configuration.language
        let appName = appURL.deletingPathExtension().lastPathComponent
        NSWorkspace.shared.open(
            targets,
            withApplicationAt: appURL,
            configuration: NSWorkspace.OpenConfiguration()
        ) { [weak self] _, error in
            let launchIssue = error.map {
                Localizer.format(
                    "无法使用“%@”打开所选项目：%@",
                    language: language,
                    appName,
                    Self.errorText($0, language: language)
                )
            }
            Task { @MainActor in
                guard let self else { return }
                let issues = preliminaryIssues + (launchIssue.map { [$0] } ?? [])
                if !issues.isEmpty {
                    self.showError(issues.joined(separator: "\n"))
                }
            }
        }
    }

    private func isDirectoryTarget(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        return values?.isDirectory == true && values?.isPackage != true
    }

    // MARK: - B15...B20/B23

    func setHidden(_ urls: [URL], hidden: Bool) {
        var failures: [String] = []
        for var url in urls {
            do {
                var values = URLResourceValues()
                values.isHidden = hidden
                try url.setResourceValues(values)
            } catch {
                failures.append(f(
                    "%@：%@",
                    url.lastPathComponent,
                    errorText(error)
                ))
            }
        }
        if failures.isEmpty {
            playOperationSound()
        } else {
            showError(failures.joined(separator: "\n"))
        }
    }

    func setAllHidden(in directory: URL, hidden: Bool) {
        do {
            let children = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isHiddenKey],
                options: []
            )
            guard confirm(
                title: t(hidden ? "隐藏全部项目" : "显示全部项目"),
                message: f(
                    "将修改“%@”第一层的 %@ 个项目，是否继续？",
                    directory.lastPathComponent,
                    String(children.count)
                )
            ) else { return }
            setHidden(children, hidden: hidden)
        } catch {
            showError(errorText(error))
        }
    }

    func grantWritePermission(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        guard urls.allSatisfy({ !PathSafety.isProtected($0) }) else {
            return showError(t("所选内容包含受保护路径。"))
        }
        struct PermissionTarget {
            let url: URL
            let descriptor: Int32
            let identity: FileIdentity
            let permissions: mode_t
        }

        var targets: [PermissionTarget] = []
        var failures: [String] = []
        defer { targets.forEach { _ = close($0.descriptor) } }

        for input in urls {
            let url = input.standardizedFileURL
            let descriptor = url.path.withCString {
                open($0, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
            }
            guard descriptor >= 0 else {
                failures.append(f(
                    "%@：无法安全打开所选项目（POSIX 错误 %@）。",
                    url.lastPathComponent,
                    String(errno)
                ))
                continue
            }
            var status = stat()
            guard fstat(descriptor, &status) == 0 else {
                let code = errno
                _ = close(descriptor)
                failures.append(f(
                    "%@：无法读取所选项目身份（POSIX 错误 %@）。",
                    url.lastPathComponent,
                    String(code)
                ))
                continue
            }
            targets.append(PermissionTarget(
                url: url,
                descriptor: descriptor,
                identity: FileIdentity(status: status),
                permissions: status.st_mode & 0o7777
            ))
        }

        guard !targets.isEmpty else {
            if !failures.isEmpty { showError(failures.joined(separator: "\n")) }
            return
        }
        let preview = targets.map { target in
            f(
                "%@：%@",
                target.url.lastPathComponent,
                "\(String(target.permissions, radix: 8)) → "
                    + "\(String(target.permissions | mode_t(S_IWUSR), radix: 8))"
            )
        }
        guard confirm(
            title: t("授予写入权限"),
            message: f("只会为当前用户增加写入权限：\n%@", preview.joined(separator: "\n"))
        )
        else { return }
        var changedCount = 0
        for target in targets {
            var status = stat()
            guard fstat(target.descriptor, &status) == 0,
                  FileIdentity(status: status) == target.identity,
                  target.identity.matchesEntry(at: target.url) else {
                failures.append(f(
                    "%@：%@",
                    target.url.lastPathComponent,
                    t("所选项目在确认期间已被替换，未修改权限。")
                ))
                continue
            }
            let permissions = status.st_mode & 0o7777
            guard fchmod(target.descriptor, permissions | mode_t(S_IWUSR)) == 0 else {
                failures.append(f(
                    "%@：无法修改权限（POSIX 错误 %@）。",
                    target.url.lastPathComponent,
                    String(errno)
                ))
                continue
            }
            changedCount += 1
        }
        if failures.isEmpty {
            if changedCount > 0 { playOperationSound() }
        } else {
            showError(failures.joined(separator: "\n"))
        }
    }

    func dissolve(_ folder: URL) {
        guard let ticket = prepareDissolve(folder) else { return }
        Task { @MainActor [weak self] in
            let result = await ticket.value()
            self?.presentDissolveResult(result)
        }
    }

    func dissolveAndWait(_ folder: URL) async {
        guard let ticket = prepareDissolve(folder) else { return }
        presentDissolveResult(await ticket.value())
    }

    private func prepareDissolve(_ input: URL) -> FileOperationTicket<DissolveResult>? {
        let folder = input.standardizedFileURL
        guard !PathSafety.isProtected(folder) else {
            showError(t("不能解散受保护目录。"))
            return nil
        }
        guard let identity = FileIdentity.capture(at: folder),
              identity.fileType == UInt32(S_IFDIR) else {
            showError(f("%@：目标已不存在或无法访问。", folder.lastPathComponent))
            return nil
        }
        guard confirm(
            title: t("解散文件夹"),
            message: f(
                "将移动文件夹中的项目到上级目录并删除“%@”。",
                folder.lastPathComponent
            )
        ) else { return nil }

        let fileManager = backgroundFileManager
        let language = configuration.language
        return fileOperationWorker.enqueue {
            Self.performDissolve(
                folder,
                expectedIdentity: identity,
                fileManager: fileManager.value,
                language: language
            )
        }
    }

    nonisolated private static func performDissolve(
        _ folder: URL,
        expectedIdentity: FileIdentity,
        fileManager: FileManager,
        language: AppLanguage
    ) -> DissolveResult {
        func issue(_ url: URL, _ error: Error) -> FileOperationIssue {
            FileOperationIssue(
                url: url,
                message: Localizer.format(
                    "%@：%@",
                    language: language,
                    url.lastPathComponent,
                    errorText(error, language: language)
                )
            )
        }

        guard !PathSafety.isProtected(folder), expectedIdentity.matchesEntry(at: folder) else {
            return DissolveResult(
                didDissolve: false,
                issues: [FileOperationIssue(
                    url: folder,
                    message: Localizer.format(
                        "%@：目标已不存在或无法访问。",
                        language: language,
                        folder.lastPathComponent
                    )
                )]
            )
        }

        let parent = folder.deletingLastPathComponent()
        let children: [URL]
        do {
            children = try fileManager.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: nil
            )
        } catch {
            return DissolveResult(didDissolve: false, issues: [issue(folder, error)])
        }
        let conflicts = children.filter {
            FileIdentity.capture(
                at: parent.appendingPathComponent($0.lastPathComponent)
            ) != nil
        }
        guard conflicts.isEmpty else {
            return DissolveResult(
                didDissolve: false,
                issues: [FileOperationIssue(
                    url: folder,
                    message: Localizer.format(
                        "上级目录存在同名项目：\n%@",
                        language: language,
                        conflicts.map(\.lastPathComponent).joined(separator: "\n")
                    )
                )]
            )
        }

        var moved: [(from: URL, to: URL)] = []
        do {
            for child in children {
                guard expectedIdentity.matchesEntry(at: folder) else {
                    throw OperationFailure(description: "目标已不存在或无法访问。")
                }
                let destination = parent.appendingPathComponent(child.lastPathComponent)
                try fileManager.moveItem(at: child, to: destination)
                moved.append((child, destination))
            }
            guard expectedIdentity.matchesEntry(at: folder) else {
                throw OperationFailure(description: "目标已不存在或无法访问。")
            }
            // `FileManager.removeItem` recursively deletes a directory. A new
            // child created after enumeration would therefore be lost. rmdir
            // removes only the now-empty directory and safely fails otherwise.
            let removeResult = folder.path.withCString { rmdir($0) }
            guard removeResult == 0 else {
                throw SecureFileFailure.posix("无法删除已解散文件夹", errno)
            }
            return DissolveResult(didDissolve: true, issues: [])
        } catch {
            var issues = [issue(folder, error)]
            for item in moved.reversed() {
                do {
                    try fileManager.moveItem(at: item.to, to: item.from)
                } catch {
                    issues.append(FileOperationIssue(
                        url: item.to,
                        message: Localizer.format(
                            "无法回滚“%@”：%@",
                            language: language,
                            item.to.lastPathComponent,
                            errorText(error, language: language)
                        )
                    ))
                }
            }
            return DissolveResult(didDissolve: false, issues: issues)
        }
    }

    private func presentDissolveResult(_ result: DissolveResult) {
        if result.issues.isEmpty {
            if result.didDissolve { playOperationSound() }
        } else {
            showError(result.issues.map(\.message).joined(separator: "\n"))
        }
    }

    private struct DeletionTargetSnapshot: Sendable {
        let url: URL
        let path: String
        let resolvedPath: String
        let device: dev_t
        let inode: ino_t
        let fileType: mode_t
    }

    func permanentlyDelete(_ urls: [URL]) async {
        guard !urls.isEmpty else { return }
        guard let targets = captureDeletionTargets(urls) else { return }

        if requiresConfirmation {
            let preference = safetyPreferencesStore.load()
            if preference.confirmBeforePermanentDelete {
                guard await permanentDeleteConfirmation(targets.map(\.url)) else { return }
                guard revalidateDeletionTargets(targets) else { return }
            } else {
                guard revalidateDeletionTargets(targets) else { return }
                let latestPreference = safetyPreferencesStore.load()
                if latestPreference.confirmBeforePermanentDelete
                    || latestPreference.revision != preference.revision {
                    guard await permanentDeleteConfirmation(targets.map(\.url)) else { return }
                    guard revalidateDeletionTargets(targets) else { return }
                }
            }
        } else {
            guard revalidateDeletionTargets(targets) else { return }
        }

        // Test-only race hook remains on MainActor. Production is nil. The
        // worker performs one final identity check before its atomic rename.
        for target in targets {
            permanentDeletionWillIsolate?(target.url)
        }
        let language = configuration.language
        let result = await fileOperationWorker.enqueue {
            Self.executePermanentDeletion(
                targets,
                language: language
            )
        }.value()
        presentDeletionResult(result)
    }

    private func captureDeletionTargets(_ urls: [URL]) -> [DeletionTargetSnapshot]? {
        var targets: [DeletionTargetSnapshot] = []
        targets.reserveCapacity(urls.count)
        for url in urls {
            let standardizedURL = url.standardizedFileURL
            guard !PathSafety.isProtected(standardizedURL) else {
                showError(t("拒绝删除根目录、主目录或系统保护路径。"))
                return nil
            }
            var status = stat()
            guard standardizedURL.path.withCString({ lstat($0, &status) }) == 0 else {
                showError(f("%@：目标已不存在或无法访问。", url.lastPathComponent))
                return nil
            }
            targets.append(DeletionTargetSnapshot(
                url: standardizedURL,
                path: standardizedURL.path,
                resolvedPath: PathSafety.standardized(standardizedURL).path,
                device: status.st_dev,
                inode: status.st_ino,
                fileType: status.st_mode & S_IFMT
            ))
        }
        return targets
    }

    private func revalidateDeletionTargets(_ targets: [DeletionTargetSnapshot]) -> Bool {
        for target in targets {
            let currentURL = target.url.standardizedFileURL
            guard currentURL.path == target.path,
                  !PathSafety.isProtected(currentURL),
                  PathSafety.standardized(currentURL).path == target.resolvedPath else {
                showError(t("永久删除目标在确认期间发生变化，已取消操作。"))
                return false
            }
            var status = stat()
            guard currentURL.path.withCString({ lstat($0, &status) }) == 0,
                  status.st_dev == target.device,
                  status.st_ino == target.inode,
                  status.st_mode & S_IFMT == target.fileType else {
                showError(t("永久删除目标在确认期间已被替换，已取消操作。"))
                return false
            }
        }
        return true
    }

    nonisolated private static func executePermanentDeletion(
        _ targets: [DeletionTargetSnapshot],
        language: AppLanguage
    ) -> DeletionResult {
        var deletedCount = 0
        var issues: [FileOperationIssue] = []
        for target in targets {
            if let issue = isolateAndDelete(
                target,
                language: language
            ) {
                issues.append(issue)
            } else {
                deletedCount += 1
            }
        }
        return DeletionResult(deletedCount: deletedCount, issues: issues)
    }

    private func presentDeletionResult(_ result: DeletionResult) {
        if result.issues.isEmpty {
            if result.deletedCount > 0 { playOperationSound() }
        } else {
            showError(result.issues.map(\.message).joined(separator: "\n"))
        }
    }

    /// 将目标以不可覆盖的原子 rename 移到同一父目录的随机隔离名，再复核
    /// device/inode/type 后删除隔离项。rename 是提交线性化点：原公开路径随后
    /// 即使被创建同名新对象，也不会成为本次删除对象。
    nonisolated private static func isolateAndDelete(
        _ target: DeletionTargetSnapshot,
        language: AppLanguage
    ) -> FileOperationIssue? {
        func failure(_ key: String, _ arguments: String...) -> FileOperationIssue {
            FileOperationIssue(
                url: target.url,
                message: Localizer.format(
                    key,
                    language: language,
                    arguments: arguments.map { $0 as CVarArg }
                )
            )
        }
        let parentURL = target.url.deletingLastPathComponent()
        let originalName = target.url.lastPathComponent
        let parentDescriptor = parentURL.path.withCString {
            open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        }
        guard parentDescriptor >= 0 else {
            return failure(
                "无法打开永久删除目标目录（POSIX 错误 %@）。",
                String(errno)
            )
        }
        defer { _ = close(parentDescriptor) }

        var immediateStatus = stat()
        let immediateResult = originalName.withCString {
            fstatat(parentDescriptor, $0, &immediateStatus, AT_SYMLINK_NOFOLLOW)
        }
        guard immediateResult == 0,
              deletionIdentity(immediateStatus, matches: target) else {
            return failure("永久删除目标在提交期间已被替换，已取消操作。")
        }

        var isolatedName: String?
        var isolationFailure: Int32?
        for _ in 0..<16 {
            let candidate = ".superrightclick-delete-\(UUID().uuidString)"
            let result = originalName.withCString { originalPath in
                candidate.withCString { isolatedPath in
                    renameatx_np(
                        parentDescriptor,
                        originalPath,
                        parentDescriptor,
                        isolatedPath,
                        UInt32(RENAME_EXCL)
                    )
                }
            }
            if result == 0 {
                isolatedName = candidate
                break
            }
            let code = errno
            if code == EEXIST { continue }
            isolationFailure = code
            break
        }

        guard let isolatedName else {
            if let isolationFailure {
                return failure(
                    "无法安全隔离永久删除目标（POSIX 错误 %@）。",
                    String(isolationFailure)
                )
            } else {
                return failure("无法生成唯一的永久删除隔离路径。")
            }
        }

        let isolatedURL = parentURL.appendingPathComponent(isolatedName)
        var isolatedStatus = stat()
        let isolatedResult = isolatedName.withCString {
            fstatat(parentDescriptor, $0, &isolatedStatus, AT_SYMLINK_NOFOLLOW)
        }
        guard isolatedResult == 0,
              deletionIdentity(isolatedStatus, matches: target) else {
            let restoreResult = isolatedName.withCString { isolatedPath in
                originalName.withCString { originalPath in
                    renameatx_np(
                        parentDescriptor,
                        isolatedPath,
                        parentDescriptor,
                        originalPath,
                        UInt32(RENAME_EXCL)
                    )
                }
            }
            if restoreResult == 0 {
                return failure("永久删除目标身份复核失败，已恢复原路径并取消操作。")
            } else {
                return failure(
                    "永久删除目标身份复核失败，且无法恢复原路径；项目保留在 %@（POSIX 错误 %@）。",
                    isolatedURL.path,
                    String(errno)
                )
            }
        }

        do {
            // Keep the final recursive removal anchored to the already-open
            // parent directory. Replacing or renaming the parent's public path
            // after isolation can no longer redirect deletion elsewhere.
            try removeEntryRecursively(
                named: isolatedName,
                from: parentDescriptor
            )
        } catch {
            return failure(
                "无法删除已隔离的永久删除目标；剩余项目位于 %@：%@",
                isolatedURL.path,
                errorText(error, language: language)
            )
        }
        return nil
    }

    /// Recursively removes a directory entry using only `*at` operations rooted
    /// at stable descriptors. Symlinks are always unlinked as entries and are
    /// never traversed. On concurrent modification, the operation fails closed
    /// and leaves the remaining isolated tree for manual recovery.
    nonisolated private static func removeEntryRecursively(
        named name: String,
        from parentDescriptor: Int32
    ) throws {
        var status = stat()
        guard name.withCString({
            fstatat(parentDescriptor, $0, &status, AT_SYMLINK_NOFOLLOW)
        }) == 0 else {
            throw OperationFailure(
                "无法读取隔离项目（POSIX 错误 %@）。",
                arguments: [String(errno)]
            )
        }

        if status.st_mode & S_IFMT != S_IFDIR {
            guard name.withCString({ unlinkat(parentDescriptor, $0, 0) }) == 0 else {
                throw OperationFailure(
                    "无法删除隔离项目（POSIX 错误 %@）。",
                    arguments: [String(errno)]
                )
            }
            return
        }

        let childDescriptor = name.withCString {
            openat(
                parentDescriptor,
                $0,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard childDescriptor >= 0 else {
            throw OperationFailure(
                "无法打开隔离目录（POSIX 错误 %@）。",
                arguments: [String(errno)]
            )
        }
        var openedStatus = stat()
        guard fstat(childDescriptor, &openedStatus) == 0,
              openedStatus.st_dev == status.st_dev,
              openedStatus.st_ino == status.st_ino,
              openedStatus.st_mode & S_IFMT == S_IFDIR else {
            let code = errno
            _ = close(childDescriptor)
            throw OperationFailure(
                "隔离目录身份已变化（POSIX 错误 %@）。",
                arguments: [String(code)]
            )
        }
        guard let directory = fdopendir(childDescriptor) else {
            let code = errno
            _ = close(childDescriptor)
            throw OperationFailure(
                "无法读取隔离目录（POSIX 错误 %@）。",
                arguments: [String(code)]
            )
        }

        var removalError: Error?
        errno = 0
        while let entry = readdir(directory) {
            let entryName = withUnsafePointer(to: entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) {
                    String(cString: $0)
                }
            }
            if entryName == "." || entryName == ".." { continue }
            do {
                try removeEntryRecursively(named: entryName, from: childDescriptor)
            } catch {
                removalError = error
                break
            }
            errno = 0
        }
        let enumerationError = errno
        _ = closedir(directory) // closes childDescriptor

        if let removalError { throw removalError }
        guard enumerationError == 0 else {
            throw OperationFailure(
                "读取隔离目录时失败（POSIX 错误 %@）。",
                arguments: [String(enumerationError)]
            )
        }
        guard name.withCString({
            unlinkat(parentDescriptor, $0, AT_REMOVEDIR)
        }) == 0 else {
            throw OperationFailure(
                "无法删除隔离目录（POSIX 错误 %@）。",
                arguments: [String(errno)]
            )
        }
    }

    nonisolated private static func deletionIdentity(
        _ status: stat,
        matches target: DeletionTargetSnapshot
    ) -> Bool {
        status.st_dev == target.device
            && status.st_ino == target.inode
            && status.st_mode & S_IFMT == target.fileType
    }

    private func requestTransferDestination(
        operation: TransferDestinationOperation,
        sourceItemCount: Int
    ) async -> Data? {
        guard let hostURL = Self.containingHostApplicationURL() else {
            showError(t("无法定位宿主应用，请确认扩展已正确嵌入 App 包内。"))
            return nil
        }
        guard let expectedHostCodeHash = HostCodeIdentity.codeHash(at: hostURL) else {
            showError(t("无法验证宿主应用的代码签名。"))
            return nil
        }

        let socketPath = AuthenticatedHostResponseServer<
            TransferDestinationPickerResponse
        >.makeSocketPath()
        let request = TransferDestinationPickerBridge.makeRequest(
            operation: operation,
            sourceItemCount: sourceItemCount,
            replySocketPath: socketPath
        )
        let server: AuthenticatedHostResponseServer<TransferDestinationPickerResponse>
        do {
            server = try AuthenticatedHostResponseServer(
                socketPath: socketPath,
                requestID: request.id,
                expectedHostCodeHash: expectedHostCodeHash,
                expectedRequestDigest: request.authenticationDigest,
                maximumResponseSize: TransferDestinationPickerBridge.maximumBookmarkSize + 64 * 1024
            )
        } catch {
            showError(t("无法建立目录选择通道：\(error.localizedDescription)"))
            return nil
        }
        defer { server.invalidate() }

        let requestURL: URL
        do {
            requestURL = try TransferDestinationPickerBridge.writeRequest(request)
        } catch {
            showError(t("无法写入目录选择请求：\(error.localizedDescription)"))
            return nil
        }
        defer { TransferDestinationPickerBridge.removeRequest(at: requestURL) }

        Self.launchOrActivateHostForTransferDestination(
            at: hostURL,
            requestURL: requestURL
        )
        TransferDestinationPickerBridge.postRequest(at: requestURL)

        let remaining = TransferDestinationPickerBridge.remainingResponseLifetime(for: request)
        guard remaining > 0 else { return nil }
        let timeoutMilliseconds = Int64((remaining * 1_000).rounded(.down))
        let response: TransferDestinationPickerResponse? = await withTaskGroup(
            of: TransferDestinationPickerResponse?.self
        ) { group in
            group.addTask {
                await Task.detached(priority: .userInitiated) {
                    server.receiveResponse()
                }.value
            }
            group.addTask {
                do {
                    try await Task.sleep(for: .milliseconds(timeoutMilliseconds))
                } catch {
                    return nil
                }
                // Task cancellation cannot interrupt the synchronous poll loop;
                // close the listener so the receive child is guaranteed to exit.
                server.invalidate()
                return nil
            }
            group.addTask {
                var delay = 150
                while !Task.isCancelled {
                    do {
                        try await Task.sleep(for: .milliseconds(delay))
                    } catch { break }
                    TransferDestinationPickerBridge.postRequest(at: requestURL)
                    delay = min(delay * 2, 5_000)
                }
                return nil
            }

            let first = await group.next() ?? nil
            server.invalidate()
            group.cancelAll()
            return first
        }

        guard let response else {
            showError(t(
                "目录选择超时或宿主应用未响应，请确认 SuperRightClick 主应用已运行。"
            ))
            return nil
        }
        guard TransferDestinationPickerBridge.remainingResponseLifetime(for: request) > 0,
              response.isStructurallyValid else {
            showError(t("目录选择响应无效或已过期，请重试。"))
            return nil
        }
        switch response.outcome {
        case .selected:
            return response.destinationBookmark
        case .cancelled:
            return nil
        case .failed:
            showError(t("主应用无法保存所选文件夹的访问权限，请重新选择。"))
            return nil
        }
    }

    private static func launchOrActivateHostForTransferDestination(
        at hostURL: URL,
        requestURL: URL
    ) {
        let expectedURL = hostURL.standardizedFileURL.resolvingSymlinksInPath()
        let runningApplications = NSRunningApplication.runningApplications(
            withBundleIdentifier: RenameRequestBridge.hostBundleIdentifier
        )
        if let runningHost = runningApplications.first(where: {
            $0.bundleURL?.standardizedFileURL.resolvingSymlinksInPath() == expectedURL
        }) {
            _ = runningHost.activate(options: [.activateAllWindows])
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false
        configuration.createsNewApplicationInstance = !runningApplications.isEmpty
        configuration.arguments = [
            TransferDestinationPickerBridge.launchArgument,
            requestURL.path,
        ]
        NSWorkspace.shared.openApplication(
            at: hostURL,
            configuration: configuration
        ) { _, _ in }
    }

    private func requestPermanentDeleteConfirmation(for urls: [URL]) async -> Bool {
        guard let hostURL = Self.containingHostApplicationURL() else {
            showError(t("无法定位宿主应用，请确认扩展已正确嵌入 App 包内。"))
            return false
        }
        guard let expectedHostCodeHash = HostCodeIdentity.codeHash(at: hostURL) else {
            showError(t("无法验证宿主应用的代码签名。"))
            return false
        }

        let requestID = UUID()
        let request = DestructiveConfirmationRequest(
            id: requestID,
            createdAt: Date(),
            action: .permanentDelete,
            paths: urls.map { $0.standardizedFileURL.path },
            confirmationMode: urls.count > 1 ? .typeDelete : .standard,
            replySocketPath: AuthenticatedDestructiveConfirmationServer.makeSocketPath()
        )
        let server: AuthenticatedDestructiveConfirmationServer
        do {
            server = try AuthenticatedDestructiveConfirmationServer(
                socketPath: request.replySocketPath,
                requestID: requestID,
                expectedHostCodeHash: expectedHostCodeHash,
                expectedRequestDigest: request.authenticationDigest
            )
        } catch {
            showError(t("无法建立确认通道：\(error.localizedDescription)"))
            return false
        }
        defer { server.invalidate() }

        let requestURL: URL
        do {
            requestURL = try DestructiveConfirmationBridge.writeRequest(request)
        } catch {
            showError(t("无法写入确认请求文件：\(error.localizedDescription)"))
            return false
        }
        defer { DestructiveConfirmationBridge.removeRequest(at: requestURL) }

        Self.launchHostApplicationIfNeeded(at: hostURL, requestURL: requestURL)
        DestructiveConfirmationBridge.postRequest(at: requestURL)
        let remainingLifetime = DestructiveConfirmationBridge.remainingResponseLifetime(
            for: request
        )
        guard remainingLifetime > 0 else { return false }
        let timeoutMilliseconds = Int64((remainingLifetime * 1_000).rounded(.down))

        let confirmedResult: Bool? = await withTaskGroup(of: Bool?.self) { group in
            group.addTask {
                await Task.detached(priority: .userInitiated) {
                    server.receiveResponse()
                }.value
            }
            group.addTask {
                do {
                    try await Task.sleep(for: .milliseconds(timeoutMilliseconds))
                } catch { }
                return nil
            }
            group.addTask {
                var delay = 150
                while !Task.isCancelled {
                    do {
                        try await Task.sleep(for: .milliseconds(delay))
                    } catch { break }
                    DestructiveConfirmationBridge.postRequest(at: requestURL)
                    delay = min(delay * 2, 5_000)
                }
                return nil
            }
            let firstResult = await group.next() ?? nil
            let isUnexpired = DestructiveConfirmationBridge.remainingResponseLifetime(
                for: request
            ) > 0
            server.invalidate()
            group.cancelAll()
            if let approved = firstResult {
                return approved && isUnexpired
            }
            return nil
        }
        if confirmedResult == nil {
            showError(t("确认超时或宿主应用未响应，请确认 SuperRightClick 主应用已运行。"))
        }
        return confirmedResult ?? false
    }

    private static func launchHostApplicationIfNeeded(
        at hostURL: URL,
        requestURL: URL
    ) {
        let expectedURL = hostURL.standardizedFileURL.resolvingSymlinksInPath()
        let runningApplications = NSRunningApplication.runningApplications(
            withBundleIdentifier: RenameRequestBridge.hostBundleIdentifier
        )
        if let runningHost = runningApplications.first(where: {
            $0.bundleURL?.standardizedFileURL.resolvingSymlinksInPath() == expectedURL
        }) {
            _ = runningHost.activate(options: [.activateAllWindows])
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false
        configuration.createsNewApplicationInstance = !runningApplications.isEmpty
        configuration.arguments = [
            DestructiveConfirmationBridge.launchArgument,
            requestURL.path,
        ]
        NSWorkspace.shared.openApplication(
            at: hostURL,
            configuration: configuration
        ) { _, _ in }
    }

    // MARK: - B21/B22

    func openInFinder(_ url: URL, newTab: Bool) {
        guard newTab else {
            // 新窗口不依赖 Apple 事件，避免“自动化”授权问题。
            NSWorkspace.shared.open(url)
            return
        }
        let escaped = url.path.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source = """
        tell application "Finder"
            activate
            if (count of windows) is 0 then make new Finder window
            tell front window
                set newTab to make new tab
                set target of newTab to POSIX file "\(escaped)"
            end tell
        end tell
        """
        var error: NSDictionary?
        if NSAppleScript(source: source)?.executeAndReturnError(&error) == nil, let error {
            let code = error[NSAppleScript.errorNumber] as? Int
            if code == -1743 {
                showError(t(
                    "系统未授权 SuperRightClick 控制 Finder。\n"
                        + "请打开「系统设置 → 隐私与安全性 → 自动化」，"
                        + "找到 SuperRightClickFinder 并允许其控制“访达”，然后重试。"
                ))
            } else {
                showError(f(
                    "Finder 自动化失败：%@",
                    code.map(String.init) ?? t("未知错误")
                ))
            }
        }
    }

    // MARK: - D01...D04/D08

    func convertImages(_ urls: [URL], to format: ImageConversionFormat) {
        let quality = configuration.imageQuality
        let backgroundHex = configuration.jpgBackgroundHex
        let language = configuration.language
        Task { [weak self] in
            let failures = await Task.detached(priority: .userInitiated) {
                var failures: [String] = []
                for sourceURL in urls {
                    do {
                        _ = try Self.convertImage(
                            sourceURL,
                            to: format,
                            quality: quality,
                            backgroundHex: backgroundHex,
                            fileManager: .default
                        )
                    } catch {
                        failures.append(Localizer.format(
                            "%@：%@",
                            language: language,
                            sourceURL.lastPathComponent,
                            Self.errorText(error, language: language)
                        ))
                    }
                }
                return failures
            }.value
            guard let self, !Task.isCancelled else { return }
            if failures.isEmpty {
                self.playOperationSound()
            } else {
                self.showError(failures.joined(separator: "\n"))
            }
        }
    }

    @discardableResult
    func convertImage(_ sourceURL: URL, to format: ImageConversionFormat) throws -> URL {
        try Self.convertImage(
            sourceURL,
            to: format,
            quality: configuration.imageQuality,
            backgroundHex: configuration.jpgBackgroundHex,
            fileManager: fileManager
        )
    }

    nonisolated static func convertImage(
        _ sourceURL: URL,
        to format: ImageConversionFormat,
        quality: Double,
        backgroundHex: String,
        fileManager: FileManager
    ) throws -> URL {
        guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
              let sourceImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw OperationFailure(description: "无法读取图片。")
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
            as? [CFString: Any]
        let orientationRaw = (properties?[kCGImagePropertyOrientation] as? NSNumber)?
            .uint32Value ?? CGImagePropertyOrientation.up.rawValue
        let orientation = CGImagePropertyOrientation(rawValue: orientationRaw) ?? .up
        let image = imageByApplyingMetadataOrientation(sourceImage, orientation: orientation)
        let outputDirectory = sourceURL.deletingLastPathComponent()
        let type: CFString
        switch format {
        case .webP: type = UTType.webP.identifier as CFString
        case .heic: type = UTType.heic.identifier as CFString
        case .jpg: type = UTType.jpeg.identifier as CFString
        case .png: type = UTType.png.identifier as CFString
        }
        let supportedTypes = CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []
        guard supportedTypes.contains(type as String) else {
            throw OperationFailure(
                "当前 macOS 不支持编码 %@。",
                arguments: [format.fileExtension.uppercased()]
            )
        }

        // 先在目标目录完整编码随机临时文件，再以 RENAME_EXCL 原子提交。
        // 这样并发转换不会争用同一最终路径，失败任务也只会清理自己的文件。
        let temporaryURL = try createTemporaryImageFile(in: outputDirectory)
        var committed = false
        defer {
            if !committed { try? fileManager.removeItem(at: temporaryURL) }
        }
        guard let destination = CGImageDestinationCreateWithURL(
            temporaryURL as CFURL,
            type,
            1,
            nil
        ) else {
            throw OperationFailure(description: "无法创建输出图片。")
        }

        let outputImage = format == .jpg
            ? flattenedForJPEG(image, backgroundHex: backgroundHex)
            : image
        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: max(0, min(1, quality)),
            // Pixels have already been transformed. Explicitly reset metadata so
            // readers do not rotate or mirror the converted image a second time.
            kCGImagePropertyOrientation: CGImagePropertyOrientation.up.rawValue,
        ]
        CGImageDestinationAddImage(destination, outputImage, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw OperationFailure(description: "图片编码失败。")
        }

        let output = try commitTemporaryImage(
            temporaryURL,
            in: outputDirectory,
            baseName: sourceURL.deletingPathExtension().lastPathComponent,
            fileExtension: format.fileExtension
        )
        committed = true
        return output
    }

    nonisolated private static func createTemporaryImageFile(in directory: URL) throws -> URL {
        for _ in 0..<16 {
            let url = directory.appendingPathComponent(
                ".superrightclick-conversion-\(UUID().uuidString).tmp"
            )
            let descriptor = url.path.withCString {
                open($0, O_CREAT | O_EXCL | O_WRONLY, mode_t(0o666))
            }
            if descriptor >= 0 {
                guard close(descriptor) == 0 else {
                    let code = errno
                    try? FileManager.default.removeItem(at: url)
                    throw imageFileFailure(
                        "无法关闭临时图片文件（POSIX 错误 %@）。",
                        code: code
                    )
                }
                return url
            }
            let code = errno
            if code == EEXIST { continue }
            throw imageFileFailure(
                "无法创建临时图片文件（POSIX 错误 %@）。",
                code: code
            )
        }
        throw OperationFailure(description: "无法创建唯一的临时图片文件。")
    }

    nonisolated private static func commitTemporaryImage(
        _ temporaryURL: URL,
        in directory: URL,
        baseName: String,
        fileExtension: String
    ) throws -> URL {
        var index = 1
        while true {
            let output = UniqueName.candidateURL(
                in: directory,
                baseName: baseName,
                fileExtension: fileExtension,
                index: index
            )
            let result = temporaryURL.path.withCString { temporaryPath in
                output.path.withCString { outputPath in
                    renameatx_np(
                        AT_FDCWD,
                        temporaryPath,
                        AT_FDCWD,
                        outputPath,
                        UInt32(RENAME_EXCL)
                    )
                }
            }
            if result == 0 { return output }
            let code = errno
            if code == EEXIST {
                index += 1
                continue
            }
            throw imageFileFailure(
                "无法提交输出图片（POSIX 错误 %@）。",
                code: code
            )
        }
    }

    nonisolated private static func imageFileFailure(
        _ key: String,
        code: Int32
    ) -> OperationFailure {
        OperationFailure(key, arguments: [String(code)])
    }

    nonisolated private static func imageByApplyingMetadataOrientation(
        _ image: CGImage,
        orientation: CGImagePropertyOrientation
    ) -> CGImage {
        guard orientation != .up else { return image }

        let oriented = CIImage(cgImage: image).oriented(orientation)
        let extent = oriented.extent.integral
        guard !extent.isEmpty, !extent.isInfinite else { return image }
        let normalized = oriented.transformed(by: CGAffineTransform(
            translationX: -extent.minX,
            y: -extent.minY
        ))
        let outputRect = CGRect(origin: .zero, size: extent.size)
        let context = CIContext(options: [.cacheIntermediates: false])
        let outputFormat: CIFormat = image.bitsPerComponent > 8 ? .RGBA16 : .RGBA8
        if let colorSpace = image.colorSpace,
           let rendered = context.createCGImage(
               normalized,
               from: outputRect,
               format: outputFormat,
               colorSpace: colorSpace
           ) {
            return rendered
        }
        return context.createCGImage(normalized, from: outputRect) ?? image
    }

    nonisolated private static func flattenedForJPEG(
        _ image: CGImage,
        backgroundHex: String
    ) -> CGImage {
        let components = hexColorComponents(backgroundHex)
        guard let context = CGContext(
            data: nil,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return image }
        context.setFillColor(red: components.r, green: components.g, blue: components.b, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage() ?? image
    }

    nonisolated private static func hexColorComponents(
        _ value: String
    ) -> (r: CGFloat, g: CGFloat, b: CGFloat) {
        let hex = value.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard hex.count == 6, let number = Int(hex, radix: 16) else {
            return (1, 1, 1)
        }
        return (
            CGFloat((number >> 16) & 0xff) / 255,
            CGFloat((number >> 8) & 0xff) / 255,
            CGFloat(number & 0xff) / 255
        )
    }

    func setWallpaper(_ imageURL: URL) {
        let screens = configuration.wallpaperAllScreens
            ? NSScreen.screens
            : (NSScreen.main.map { [$0] } ?? [])
        var failures: [String] = []
        for screen in screens {
            do {
                try NSWorkspace.shared.setDesktopImageURL(
                    imageURL,
                    for: screen,
                    options: [:]
                )
            } catch {
                failures.append(errorText(error))
            }
        }
        if failures.isEmpty {
            playOperationSound()
        } else {
            showError(failures.joined(separator: "\n"))
        }
    }

    // MARK: - Helpers

    /// Finder Sync should delegate complex UI to the containing app. The
    /// destination picker does so above; these remaining legacy one-shot alerts
    /// are explicitly promoted while they are migrated incrementally, preventing
    /// them from opening behind Finder or on another Space.
    private func prepareLegacyModalWindow(_ window: NSWindow) {
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        NSApp.activate()
        window.level = .modalPanel
        window.collectionBehavior.formUnion([.moveToActiveSpace, .fullScreenAuxiliary])
        window.hidesOnDeactivate = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    @discardableResult
    private func runModalInFront(_ alert: NSAlert) -> NSApplication.ModalResponse {
        prepareLegacyModalWindow(alert.window)
        return alert.runModal()
    }

    @discardableResult
    private func runModalInFront(_ panel: NSOpenPanel) -> NSApplication.ModalResponse {
        prepareLegacyModalWindow(panel)
        return panel.runModal()
    }

    private func playOperationSound() {
        guard configuration.playOperationSound else { return }
        NSSound(named: "Glass")?.play()
    }

    nonisolated func fileHashes(_ url: URL) throws -> (md5: String, sha1: String, sha256: String, sha512: String) {
        try Self.computeFileHashes(url)
    }

    nonisolated private static func computeFileHashes(
        _ url: URL
    ) throws -> (md5: String, sha1: String, sha256: String, sha512: String) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var md5 = Insecure.MD5()
        var sha1 = Insecure.SHA1()
        var sha256 = SHA256()
        var sha512 = SHA512()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
            md5.update(data: data)
            sha1.update(data: data)
            sha256.update(data: data)
            sha512.update(data: data)
        }
        func hex<S: Sequence>(_ value: S) -> String where S.Element == UInt8 {
            value.map { String(format: "%02x", $0) }.joined()
        }
        return (hex(md5.finalize()), hex(sha1.finalize()), hex(sha256.finalize()), hex(sha512.finalize()))
    }

    private func t(_ value: String) -> String {
        Localizer.text(value, language: configuration.language)
    }

    private func f(_ value: String, _ arguments: String...) -> String {
        Localizer.format(
            value,
            language: configuration.language,
            arguments: arguments.map { $0 as CVarArg }
        )
    }

    nonisolated private static func errorText(
        _ error: Error,
        language: AppLanguage
    ) -> String {
        if let failure = error as? OperationFailure {
            return failure.message(language: language)
        }
        if let failure = error as? SecureFileFailure {
            return failure.message(language: language)
        }
        return Localizer.systemErrorText(error, language: language)
    }

    private func errorText(_ error: Error) -> String {
        Self.errorText(error, language: configuration.language)
    }

    private func prompt(title: String, message: String, defaultValue: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: t("确定"))
        alert.addButton(withTitle: t("取消"))
        let field = NSTextField(string: defaultValue)
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field
        return runModalInFront(alert) == .alertFirstButtonReturn ? field.stringValue : nil
    }

    private func confirm(title: String, message: String) -> Bool {
        if !requiresConfirmation { return true }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: t("继续"))
        alert.addButton(withTitle: t("取消"))
        return runModalInFront(alert) == .alertFirstButtonReturn
    }

    private func showInfo(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "SuperRightClick"
        alert.informativeText = message
        alert.addButton(withTitle: t("好"))
        runModalInFront(alert)
    }

    private func showError(_ message: String) {
        if let errorPresentation {
            errorPresentation(message)
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = t("操作失败")
        alert.informativeText = message
        alert.addButton(withTitle: t("好"))
        runModalInFront(alert)
    }
}
