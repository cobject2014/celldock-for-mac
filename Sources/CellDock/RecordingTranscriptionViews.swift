import SwiftUI

struct RecordingTranscriptionSettings: View {
    @ObservedObject private var store = CallTranscriptionStore.shared
    @State private var showingConfiguration = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(L10n.tr("录音自动转录并推送"), isOn: Binding(
                get: { store.configuration.enabled },
                set: { enabled in
                    var configuration = store.configuration
                    configuration.enabled = enabled
                    do { try store.configure(configuration); error = nil }
                    catch {
                        self.error = CallTranscriptionError.message(for: error)
                        showingConfiguration = true
                    }
                }
            ))
            .toggleStyle(.adaptiveGlass)
            Text(L10n.tr("录音保存后发送至配置的 ASR 服务，转录文本推送到企业微信。此开关独立于短信转发。"))
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Text(store.configuration.scope == .automaticAnswers
                    ? L10n.tr("仅自动接听的录音") : L10n.tr("所有通话录音"))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(L10n.tr("配置…")) { showingConfiguration = true }
                    .adaptiveGlassButton()
            }
            if let message = error ?? store.lastError {
                Text(message).font(.caption).foregroundStyle(.red)
            }
        }
        .sheet(isPresented: $showingConfiguration, onDismiss: { error = nil }) {
            RecordingTranscriptionConfigSheet(store: store)
        }
    }
}

private struct RecordingTranscriptionConfigSheet: View {
    @ObservedObject var store: CallTranscriptionStore
    @Environment(\.dismiss) private var dismiss
    @State private var configuration: CallTranscriptionConfiguration
    @State private var error: String?

    init(store: CallTranscriptionStore) {
        self.store = store
        _configuration = State(initialValue: store.configuration)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.tr("配置录音转录与推送")).font(.headline)
            Form {
                Toggle(L10n.tr("录音自动转录并推送"), isOn: $configuration.enabled)
                Picker(L10n.tr("自动处理范围"), selection: $configuration.scope) {
                    Text(L10n.tr("仅自动接听的录音")).tag(CallTranscriptionConfiguration.Scope.automaticAnswers)
                    Text(L10n.tr("所有通话录音")).tag(CallTranscriptionConfiguration.Scope.allRecordings)
                }
                TextField(L10n.tr("ASR 服务地址"), text: $configuration.baseURL)
                    .help("http://DELLXPS.local:9100")
                SecureField("ASR API Key", text: $configuration.apiKey)
                Picker(L10n.tr("识别语言"), selection: $configuration.language) {
                    Text(L10n.tr("自动识别")).tag("auto")
                    Text("中文").tag("zh")
                    Text("English").tag("en")
                }
                SecureField(L10n.tr("企业微信 Webhook"), text: $configuration.webhookURL)
                Button(L10n.tr("使用短信转发的企业微信地址")) {
                    configuration.webhookURL = SMSForwardingStore.shared.wecom.webhookURL
                }
                .disabled(!SMSForwardingStore.shared.wecom.isConfigured)
            }
            .textFieldStyle(.roundedBorder)
            Text(L10n.tr("密钥和 Webhook 保存在本机配置文件中，不使用钥匙串。开启后仅处理新保存的录音；关闭会暂停尚未完成的任务。"))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(L10n.tr("长录音会自动分段，长文本会分条推送。结果和失败重试入口在录音详情中。"))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button(L10n.tr("取消")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L10n.tr("保存")) {
                    do { try store.configure(configuration); dismiss() }
                    catch { self.error = CallTranscriptionError.message(for: error) }
                }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 560)
    }
}

struct RecordingTranscriptCard: View {
    let recordID: UUID
    let privacyEnabled: Bool
    @ObservedObject private var store = CallTranscriptionStore.shared

    var body: some View {
        if let job = store.jobs.first(where: { $0.id == recordID }) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(L10n.tr("录音转录")).font(.headline)
                    Spacer()
                    Text(job.phase.title).font(.caption).foregroundStyle(.secondary)
                }
                if privacyEnabled {
                    Text(L10n.tr("隐私模式下隐藏转录内容。"))
                        .font(.caption).foregroundStyle(.secondary)
                } else if let transcript = job.transcript {
                    Text(transcript.isEmpty ? L10n.tr("未识别到语音。") : transcript)
                        .font(.body).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let error = job.error {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                if job.phase == .failed {
                    Button(job.transcript == nil ? L10n.tr("重试转录与推送") : L10n.tr("重试推送")) {
                        store.retry(recordID)
                    }
                    .adaptiveGlassButton()
                    .disabled(!store.configuration.enabled || privacyEnabled)
                }
                if !store.configuration.enabled && job.phase == .queued {
                    Text(L10n.tr("自动转录已关闭，任务已暂停。"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .adaptiveGlassSurface(cornerRadius: 20, padding: 16, treatment: .regular)
        }
    }
}
