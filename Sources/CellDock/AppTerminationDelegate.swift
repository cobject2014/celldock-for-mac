import AppKit
import Foundation
import Combine

@MainActor
final class AppTerminationDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    private lazy var updaterManager = UpdaterManager.shared
    private var menuBarPanelController: MenuBarPanelController?
    @Published private(set) var appState: AppState?
    private var didFinishLaunching = false
    private var didShowInitialCommunicationWindow = false
    private var didScheduleStartupPermissionRequest = false

    func startNormalMode() {
        guard appState == nil, !BackupRestoreCoordinator.maintenanceRequired else { return }
        AppIdentityMigration.migratePreferencesIfNeeded()
        let state = AppState()
        state.start()
        configure(appState: state)
    }

    func configure(appState: AppState) {
        self.appState = appState
        menuBarPanelController = MenuBarPanelController(appState: appState)
        if didFinishLaunching {
            AppAppearanceMode.storedPreference.apply()
            updaterManager.start()
            menuBarPanelController?.start()
            showInitialCommunicationWindowIfNeeded()
            scheduleStartupPermissionRequestIfNeeded()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        didFinishLaunching = true
        if BackupRestoreCoordinator.maintenanceRequired && appState == nil {
            BackupRestoreCoordinator.shared.showWindow()
            return
        }
        AppAppearanceMode.storedPreference.apply()
        updaterManager.start()
        menuBarPanelController?.start()
        showInitialCommunicationWindowIfNeeded()
        scheduleStartupPermissionRequestIfNeeded()
    }

    func applicationWillTerminate(_ notification: Notification) {
        menuBarPanelController?.stop()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if appState == nil && BackupRestoreCoordinator.shared.busy { return .terminateCancel }
        return AppTerminationCoordinator.shared.beginTermination(of: sender)
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        if !flag {
            if appState == nil { BackupRestoreCoordinator.shared.showWindow() }
            else { CommunicationWindowController.shared.handleApplicationReopen() }
        }
        return true
    }

    private func showInitialCommunicationWindowIfNeeded() {
        guard !didShowInitialCommunicationWindow, let appState else { return }
        didShowInitialCommunicationWindow = true
        DispatchQueue.main.async {
            appState.showMessagesWindow()
        }
    }

    private func scheduleStartupPermissionRequestIfNeeded() {
        guard !didScheduleStartupPermissionRequest else { return }
        didScheduleStartupPermissionRequest = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.appState?.requestStartupPermissionsIfNeeded()
        }
    }
}

final class AppTerminationCoordinator {
    static let shared = AppTerminationCoordinator()

    var cleanup: ((@escaping (Bool) -> Void) -> Void)?
    private var terminationPending = false

    private init() {}

    func beginTermination(of application: NSApplication) -> NSApplication.TerminateReply {
        guard !terminationPending else { return .terminateLater }
        guard let cleanup else { return .terminateNow }
        terminationPending = true
        var replied = false
        let reply: (Bool) -> Void = { shouldTerminate in
            DispatchQueue.main.async {
                guard !replied else { return }
                replied = true
                self.terminationPending = false
                application.reply(toApplicationShouldTerminate: shouldTerminate)
            }
        }
        cleanup(reply)
        DispatchQueue.main.asyncAfter(deadline: .now() + 45) { reply(false) }
        return .terminateLater
    }
}
