import AppKit
import SwiftUI
import CellDockBackupCore

private final class BackupCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func cancel() { lock.lock(); value = true; lock.unlock() }
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

@MainActor
final class BackupRestoreCoordinator: NSObject, ObservableObject, NSWindowDelegate {
    static let shared = BackupRestoreCoordinator()
    static let maintenanceKey = "CellDock.BackupMaintenance.v1"
    static let reviewKey = "CellDock.RestoreReviewRequired.v1"
    nonisolated static var root: URL {
        #if DEBUG
        // LaunchServices can relaunch a test bundle without its shell environment.
        // The dedicated bundle must therefore remain isolated by identity as well.
        if Bundle.main.bundleIdentifier == "app.celldock.backup-ui-test" {
            return Bundle.main.bundleURL.deletingLastPathComponent()
        }
        if let testPath = ProcessInfo.processInfo.environment["CELLDOCK_BACKUP_UI_TEST_DIRECTORY"],
           testPath.hasPrefix("/private/tmp/CellDock-UI-") { return URL(fileURLWithPath: testPath) }
        #endif
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("CellDock")
    }
    nonisolated static var control: URL { root.appendingPathComponent("BackupRecovery") }
    nonisolated static var journal: URL { control.appendingPathComponent("journal.json") }
    nonisolated static var rollback: URL { control.appendingPathComponent("rollback.celldockbackup") }
    nonisolated static var recoveryRequired: Bool {
        do {
            _ = try BackupRestoreTransaction.outcome(at: journal)
            return BackupRestoreTransaction.hasPendingRecovery(at: journal)
        } catch { return true }
    }
    static var maintenanceRequired: Bool {
        #if DEBUG
        if root.path.hasPrefix("/private/tmp/CellDock-UI-") { return true }
        #endif
        return UserDefaults.standard.bool(forKey: maintenanceKey) || UserDefaults.standard.bool(forKey: reviewKey) ||
        recoveryRequired || (try? BackupRestoreTransaction.outcome(at: journal)) == .committed
    }
    @Published private(set) var busy = false
    @Published private(set) var committing = false
    @Published private(set) var message = ""
    @Published private(set) var preview: BackupManifest?
    @Published private(set) var needsRecovery = recoveryRequired
    @Published private(set) var needsReview = (try? BackupRestoreTransaction.outcome(at: journal)) == .committed
    @Published private(set) var bytes: UInt64 = 0
    private var snapshot: BackupSnapshot?
    private var previewPassword = ""
    private var previewDirectory: URL?
    private var cancellation = BackupCancellation()
    private var window: NSWindow?
    var resumeApplication: (() -> Void)?
    @Published var acceptsMigration = false
    private let exitTransition = BackupMaintenanceExit()
    var presentationWindow: NSWindow? { window }

    func showWindow() {
        if window == nil {
            let value = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 650),
                styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            value.delegate = self
            value.title = L10n.tr("备份与恢复")
            value.contentMinSize = NSSize(width: 560, height: 480)
            value.contentView = NSHostingView(rootView: BackupSettingsView().cellDockLanguageEnvironment())
            value.isReleasedWhenClosed = false
            value.center(); window = value
        }
        NSApp.setActivationPolicy(.regular)
        window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func enterMaintenance() throws {
        UserDefaults.standard.set(true, forKey: Self.maintenanceKey)
        guard UserDefaults.standard.synchronize() else { throw BackupError.invalid("maintenance marker failed") }
        NSApp.terminate(nil)
    }
    func cancel() { if !committing { cancellation.cancel() } }
    func clearPreview() {
        guard !busy else { return }
        snapshot = nil; preview = nil; previewPassword = ""
        if let previewDirectory { try? FileManager.default.removeItem(at: previewDirectory) }
        previewDirectory = nil
    }
    private func begin() throws -> BackupCancellation {
        guard Self.maintenanceRequired, !busy else { throw BackupError.busy }
        clearPreview(); busy = true; bytes = 0; message = ""
        cancellation = BackupCancellation()
        return cancellation
    }
    private func fail(_ error: Error) {
        if case BackupError.cancelled = error { message = L10n.tr("操作已取消，原数据未更改。") }
        else { message = L10n.tr("操作失败。请检查密码、备份完整性、磁盘空间和钥匙串授权。") }
        needsRecovery = Self.recoveryRequired
        needsReview = (try? BackupRestoreTransaction.outcome(at: Self.journal)) == .committed
    }
    func backup(to directory: URL, password: String) async {
        #if DEBUG
        if Self.root.path.hasPrefix("/private/tmp/CellDock-UI-") { return }
        #endif
        guard !needsRecovery, !needsReview else { return }
        do {
            let token = try begin(); defer { busy = false }
            let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
            let root = Self.root
            try await Task.detached {
                let scoped = directory.startAccessingSecurityScopedResource()
                defer { if scoped { directory.stopAccessingSecurityScopedResource() } }
                let scratch = try BackupFiles.privateDirectory()
                defer { try? FileManager.default.removeItem(at: scratch) }
                let captured = try BackupSnapshotBuilder.capture(root: root, into: scratch.appendingPathComponent("snapshot"), settings: BackupSettingsAdapter(), credentials: BackupCredentialAdapter(), appVersion: version)
                try BackupSnapshotProvider.validate(captured)
                let name = "CellDock-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString).celldockbackup"
                try BackupArchive.seal(captured, to: directory.appendingPathComponent(name), password: password,
                    progress: { amount in Task { @MainActor in self.bytes = amount } }, cancelled: { token.cancelled })
            }.value
            message = L10n.tr("加密备份已保存到所选目录；若选择 iCloud，请等待同步完成后再在另一台 Mac 恢复。")
        } catch { fail(error) }
    }
    func inspect(archive: URL, password: String) async {
        #if DEBUG
        if Self.root.path.hasPrefix("/private/tmp/CellDock-UI-") { return }
        #endif
        guard !needsRecovery, !needsReview else { return }
        do {
            let token = try begin(); defer { busy = false }
            let result = try await Task.detached { () -> (URL, BackupSnapshot) in
                let scoped = archive.startAccessingSecurityScopedResource()
                defer { if scoped { archive.stopAccessingSecurityScopedResource() } }
                if try archive.resourceValues(forKeys: [.isUbiquitousItemKey]).isUbiquitousItem == true {
                    try FileManager.default.startDownloadingUbiquitousItem(at: archive)
                    var available = false
                    for _ in 0..<240 {
                        if token.cancelled { throw BackupError.cancelled }
                        let status = try archive.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]).ubiquitousItemDownloadingStatus
                        if status == .current || status == .downloaded { available = true; break }
                        try await Task.sleep(nanoseconds: 500_000_000)
                    }
                    guard available else { throw BackupError.invalid("cloud download pending") }
                }
                let scratch = try BackupFiles.privateDirectory()
                var success = false
                defer { if !success { try? FileManager.default.removeItem(at: scratch) } }
                let local = scratch.appendingPathComponent("input.celldockbackup")
                var coordinationError: NSError?
                var copyError: Error?
                NSFileCoordinator().coordinate(readingItemAt: archive, options: .withoutChanges, error: &coordinationError) { coordinated in
                    do { try FileManager.default.copyItem(at: coordinated, to: local) } catch { copyError = error }
                }
                if let error = coordinationError ?? copyError as NSError? { throw error }
                let opened = try BackupArchive.open(local, into: scratch.appendingPathComponent("snapshot"), password: password,
                    progress: { amount in Task { @MainActor in self.bytes = amount } }, cancelled: { token.cancelled })
                let decoded = try BackupSnapshotBuilder.portableImport(opened)
                try BackupSnapshotProvider.validate(decoded)
                success = true; return (scratch, decoded)
            }.value
            previewDirectory = result.0; snapshot = result.1; preview = result.1.manifest; previewPassword = password
        } catch { fail(error) }
    }
    func confirmRestore() async {
        guard !busy, !needsRecovery, let snapshot else { return }
        busy = true; committing = true
        defer { busy = false; committing = false; clearPreview() }
        let password = previewPassword
        do {
            try await Task.detached {
                try FileManager.default.createDirectory(at: Self.control, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                // Retain old recovery archives; never overwrite a previous rollback package.
                if FileManager.default.fileExists(atPath: Self.rollback.path) {
                    try FileManager.default.moveItem(at: Self.rollback, to: Self.control.appendingPathComponent("rollback-\(UUID().uuidString).celldockbackup"))
                }
                let transaction = BackupRestoreTransaction(root: Self.root, journal: Self.journal, settings: BackupSettingsAdapter(), credentials: BackupCredentialAdapter())
                try BackupSnapshotProvider.validate(snapshot)
                try transaction.apply(snapshot, rollback: Self.rollback, password: password)
            }.value
            needsReview = true
            message = L10n.tr("恢复完成。请确认迁移注意事项，再退出维护模式。")
        } catch { fail(error) }
    }
    func recover(password: String) async {
        guard !busy, needsRecovery else { return }
        busy = true; committing = true
        defer { busy = false; committing = false }
        do {
            try await Task.detached {
                try BackupRestoreTransaction(root: Self.root, journal: Self.journal, settings: BackupSettingsAdapter(), credentials: BackupCredentialAdapter()).recover(rollback: Self.rollback, password: password)
            }.value
            needsRecovery = Self.recoveryRequired
            needsReview = (try? BackupRestoreTransaction.outcome(at: Self.journal)) == .committed
            guard !needsRecovery else { throw BackupError.invalid("restore outcome needs recovery") }
            message = L10n.tr("原数据已恢复。")
        } catch { fail(error) }
    }
    func finish() {
        #if DEBUG
        if Self.root.path.hasPrefix("/private/tmp/CellDock-UI-") { NSApp.terminate(nil); return }
        #endif
        guard let resumeApplication else { return }
        do {
            try exitTransition.finish(busy: busy || window?.attachedSheet != nil,
                recoveryRequired: needsRecovery || Self.recoveryRequired,
                reviewRequired: needsReview, reviewAccepted: acceptsMigration, prepare: {
            if needsReview {
                for (path, nested) in [("CallTranscriptions/settings.json", false), ("CallWelcome/welcome.json", true)] {
                    let url = Self.root.appendingPathComponent(path)
                    if FileManager.default.fileExists(atPath: url.path) {
                        _ = try BackupFiles.checkedFile(root: Self.root, path: path)
                        let data = try BackupMaintenancePolicy.inactiveConfiguration(BackupSnapshotBuilder.metadata(url), nested: nested)
                        try data.write(to: url, options: .atomic)
                        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                        let handle = try FileHandle(forWritingTo: url)
                        try handle.synchronize(); try handle.close()
                    }
                }
                let settings = BackupSettingsAdapter()
                try settings.replace(with: BackupMaintenancePolicy.inactivePreferences(settings.read()))
                for key in ["CallRecordingConsentAcknowledged.v1", "CellDockInitialSetupCompleted.v1", "CellDock.modemNetworkServiceRecord", "SelectedInternetModule.v1", "CellularNetworkingModeByModule.v2", "CellularNetworkingPreferencesByModule.v1"] {
                    UserDefaults.standard.removeObject(forKey: key)
                }
                guard UserDefaults.standard.synchronize() else { throw BackupError.invalid("migration consent save failed") }
            }
            if FileManager.default.fileExists(atPath: Self.control.path) {
                try BackupRestoreTransaction.acknowledge(at: Self.journal)
            }
            clearPreview()
            UserDefaults.standard.removeObject(forKey: Self.reviewKey)
            UserDefaults.standard.removeObject(forKey: Self.maintenanceKey)
            guard UserDefaults.standard.synchronize() else { throw BackupError.invalid("finish failed") }
            }, resume: {
                window?.orderOut(nil)
                window?.close()
                window = nil
                needsReview = false
                resumeApplication()
            })
        } catch { fail(error) }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        finish()
        return false // finish closes the window only after the same safety checks as the button.
    }
}
