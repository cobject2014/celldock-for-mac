import AppKit
import SwiftUI

struct BackupSettingsView: View {
    @ObservedObject private var coordinator = BackupRestoreCoordinator.shared
    @State private var password = ""
    @State private var confirmation = ""
    @State private var confirmsRestore = false
    @State private var choosingLocation = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(L10n.tr("备份与恢复")).font(.largeTitle.bold())
                Text(L10n.tr("维护模式中已暂停通信。备份包含短信、通话、原始录音、音效、可迁移设置和转发凭据。"))
                Text(L10n.tr("系统权限、登录启动、USB 和网络绑定不会迁移；不会修改 SIM 或模块固件。"))
                    .foregroundStyle(.secondary)
                Text(L10n.tr("备份密码（至少 12 个字符）"))
                    .font(.callout)
                SecureField(L10n.tr("备份密码（至少 12 个字符）"), text: $password)
                if !coordinator.needsRecovery && !coordinator.needsReview && coordinator.preview == nil {
                    Text(L10n.tr("创建备份时再次输入密码"))
                        .font(.callout)
                    SecureField(L10n.tr("创建备份时再次输入密码"), text: $confirmation)
                    Text(L10n.tr("请妥善保存密码，遗失后无法恢复。备份中包含敏感信息，请勿分享。"))
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button(L10n.tr("选择目录并备份…")) { chooseDirectory() }
                            .disabled(password.count < 12 || password != confirmation)
                        Button(L10n.tr("选择备份并预览…")) { chooseArchive() }
                            .disabled(password.isEmpty)
                    }
                    if !password.isEmpty && password.count < 12 {
                        Text(L10n.tr("密码不足 12 个字符，暂时无法创建备份。"))
                            .font(.caption).foregroundStyle(.orange)
                    } else if !password.isEmpty && password != confirmation {
                        Text(L10n.tr("两次密码不一致，请再次输入相同的密码。"))
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
                if let preview = coordinator.preview {
                    Text("\(L10n.tr("短信")): \(preview.messageCount) · \(L10n.tr("通话")): \(preview.callCount) · \(L10n.tr("录音")): \(preview.recordingCount)")
                    Text(preview.createdAt, style: .date)
                    Text(L10n.tr("恢复将替换本机 CellDock 数据和可迁移配置，不是合并。覆盖前会保存加密回滚备份。"))
                    HStack {
                        Button(L10n.tr("确认恢复…"), role: .destructive) { confirmsRestore = true }
                        Button(L10n.tr("取消")) { coordinator.clearPreview(); password = "" }
                    }
                }
                if coordinator.needsRecovery {
                    Text(L10n.tr("上次恢复未完成。请输入当时的备份密码，先回滚到恢复前状态；通信保持停用。"))
                        .foregroundStyle(.orange)
                    Button(L10n.tr("恢复原数据")) {
                        let value = password; password = ""
                        Task { await coordinator.recover(password: value) }
                    }.disabled(password.isEmpty)
                }
                if coordinator.needsReview && !coordinator.needsRecovery {
                    Toggle(L10n.tr("我了解：自动接听、自动录音、自动删除、短信转发和代理将保持关闭，需在目标 Mac 重新确认开启。"), isOn: $coordinator.acceptsMigration)
                    Text(L10n.tr("请重新检查模块路由及系统权限。历史短信不会作为新短信转发。"))
                }
                if coordinator.busy {
                    ProgressView()
                    Text(ByteCountFormatter.string(fromByteCount: Int64(clamping: coordinator.bytes), countStyle: .file))
                    if !coordinator.committing { Button(L10n.tr("取消操作")) { coordinator.cancel() } }
                    else { Text(L10n.tr("正在提交或回滚，请勿关闭应用。")) }
                }
                if !coordinator.message.isEmpty { Text(coordinator.message).textSelection(.enabled) }
                Divider()
                Button(L10n.tr("在 Finder 中查看本机加密回滚备份")) {
                    NSWorkspace.shared.open(BackupRestoreCoordinator.control)
                }
                Button(L10n.tr("完成，返回 CellDock")) { coordinator.finish() }
                    .disabled(coordinator.busy || coordinator.needsRecovery || (coordinator.needsReview && !coordinator.acceptsMigration))
            }
            .padding(28)
            .disabled(coordinator.busy || choosingLocation) // Cancellation remains available below.
        }
        .overlay(alignment: .bottomTrailing) {
            if coordinator.busy && !coordinator.committing {
                Button(L10n.tr("取消操作")) { coordinator.cancel() }.padding()
            }
        }
        .onAppear {
            #if DEBUG
            if BackupRestoreCoordinator.root.path.hasPrefix("/private/tmp/CellDock-UI-") {
                password = "test-only-password-123"
                confirmation = password
            }
            #endif
        }
        .alert(L10n.tr("替换本机数据？"), isPresented: $confirmsRestore) {
            Button(L10n.tr("取消"), role: .cancel) { }
            Button(L10n.tr("替换并恢复"), role: .destructive) {
                password = ""; confirmation = ""
                Task { await coordinator.confirmRestore() }
            }
        } message: { Text(L10n.tr("这将覆盖本机短信、通话、录音和可迁移配置。确认已选择正确的备份。")) }
    }
    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        show(panel) { url in
            let value = password; password = ""; confirmation = ""
            Task { await coordinator.backup(to: url, password: value) }
        }
    }
    private func chooseArchive() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false; panel.canChooseFiles = true; panel.allowsMultipleSelection = false
        show(panel) { url in
            let value = password; password = ""; confirmation = ""
            Task { await coordinator.inspect(archive: url, password: value) }
        }
    }
    private func show(_ panel: NSOpenPanel, selected: @escaping (URL) -> Void) {
        guard !choosingLocation, let window = coordinator.presentationWindow else { return }
        #if DEBUG
        if BackupRestoreCoordinator.root.path.hasPrefix("/private/tmp/CellDock-UI-") { panel.directoryURL = BackupRestoreCoordinator.root }
        #endif
        choosingLocation = true
        panel.beginSheetModal(for: window) { response in
            choosingLocation = false
            guard response == .OK, let url = panel.url else { return }
            selected(url)
        }
    }
}

struct BackupMaintenanceEntryView: View {
    @EnvironmentObject private var appState: AppState
    @State private var confirmsEntry = false
    @State private var failed = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(L10n.tr("选择本地或 iCloud 目录，创建密码加密备份，并在另一台 Mac 恢复。"))
            Text(L10n.tr("为保证数据一致，先退出并重新打开 CellDock 进入维护模式；此时不会接听电话或收发短信。"))
            Button(L10n.tr("退出并准备进入维护模式…")) { confirmsEntry = true }
                .disabled(!appState.canEnterBackupMaintenance)
            if !appState.canEnterBackupMaintenance { Text(L10n.tr("请先结束所有模块的通话、录音和正在执行的操作。")) }
            if failed { Text(L10n.tr("无法进入维护模式，请稍后重试。")) }
        }
        .alert(L10n.tr("进入备份维护模式？"), isPresented: $confirmsEntry) {
            Button(L10n.tr("取消"), role: .cancel) { }
            Button(L10n.tr("退出 CellDock")) {
                guard appState.canEnterBackupMaintenance else { return }
                do { try BackupRestoreCoordinator.shared.enterMaintenance() } catch { failed = true }
            }
        } message: { Text(L10n.tr("退出后请重新打开应用，将显示备份与恢复窗口。")) }
    }
}
