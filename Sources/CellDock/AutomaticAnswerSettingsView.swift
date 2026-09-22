import SwiftUI

/// Keeps the fork's automatic answering features separate from upstream communication settings.
struct AutomaticAnswerSettingsView: View {
    @EnvironmentObject private var appState: AppState
    @AppStorage("CallRecordingConsentAcknowledged.v1") private var recordingConsent = false
    @State private var isConfirmingAutomaticAnswer = false

    var body: some View {
        VStack(spacing: 16) {
            section(title: L10n.tr("自动接听")) {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle(L10n.tr("自动接听并录音"), isOn: Binding(
                        get: { appState.automaticallyAnswerCalls },
                        set: { enabled in
                            if enabled { isConfirmingAutomaticAnswer = true }
                            else { appState.setAutomaticallyAnswerCalls(false) }
                        }
                    ))
                    .toggleStyle(.adaptiveGlass)

                    Text(L10n.tr("仅听对方，不采集本机麦克风；不受“通话时自动录音”开关影响。Mac 需保持唤醒且 CellDock 正在运行。"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Stepper(value: Binding(
                        get: { appState.automaticAnswerDelay },
                        set: { appState.setAutomaticAnswerDelay($0) }
                    ), in: 1...60) {
                        Text(L10n.tr("检测到来电 %lld 秒后接听（下次来电生效）", Int64(appState.automaticAnswerDelay)))
                    }

                    Label(L10n.tr("USB 音频输入也需要系统麦克风权限，请在“通知与权限”中确认已允许。仅听模式不会采集 Mac 麦克风。"),
                          systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(16)
            }

            section(title: L10n.tr("录音转录与推送")) {
                RecordingTranscriptionSettings()
                    .padding(16)
            }
        }
        .alert(L10n.tr("开启自动接听并录音？"), isPresented: $isConfirmingAutomaticAnswer) {
            Button(L10n.tr("取消"), role: .cancel) { }
            Button(L10n.tr("同意并开启")) {
                recordingConsent = true
                appState.setAutomaticallyAnswerCalls(true)
            }
        } message: {
            Text(L10n.tr("来电将自动接通并录音，不采集本机麦克风，对方声音通过当前输出设备播放。录音仅保存在这台 Mac，请确保通话参与者知情同意。"))
        }
    }

    private func section<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.headline)
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 12)
            Divider().padding(.horizontal, 16)
            content()
        }
        .adaptiveGlassSurface(cornerRadius: 18, treatment: .regular)
    }
}
