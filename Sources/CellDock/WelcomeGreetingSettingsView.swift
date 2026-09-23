import AVFoundation
import SwiftUI

struct WelcomeGreetingSettings: View {
    @ObservedObject private var store = CallWelcomeStore.shared
    @State private var showingConfiguration = false
    @State private var enableOnSave = false
    @State private var error: String?
    @State private var preview: AVAudioPlayer?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(L10n.tr("接通后播放欢迎语"), isOn: Binding(
                get: { store.configuration.enabled },
                set: { enabled in
                    if enabled, store.cachedPCM == nil {
                        enableOnSave = true; showingConfiguration = true
                    } else {
                        do { try store.setEnabled(enabled); error = nil }
                        catch { self.error = CallWelcomeError.message(for: error) }
                    }
                }
            ))
            .toggleStyle(.adaptiveGlass)
            .disabled(store.isGenerating)
            Text(L10n.tr("仅自动接听时向来电方播放一次。不采集 Mac 麦克风；欢迎语不会加入仅识别来电方的转录音轨。"))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text(store.cachedPCM == nil ? L10n.tr("尚未生成欢迎语") : L10n.tr("欢迎语已缓存，接通后即可播放"))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(L10n.tr("试听")) {
                    guard let pcm = store.cachedPCM else { return }
                    do {
                        preview?.stop()
                        preview = try AVAudioPlayer(data: CallWelcomeAudio.wav(pcm: pcm))
                        preview?.play()
                    } catch { self.error = CallWelcomeError.invalidAudio.localizedDescription }
                }
                .disabled(store.cachedPCM == nil || store.isGenerating)
                .adaptiveGlassButton()
                Button(L10n.tr("配置…")) {
                    preview?.stop()
                    enableOnSave = store.configuration.enabled
                    showingConfiguration = true
                }
                .disabled(store.isGenerating)
                .adaptiveGlassButton()
            }
            if let message = error ?? store.lastError {
                Text(message).font(.caption).foregroundStyle(.red)
            }
        }
        .sheet(isPresented: $showingConfiguration) {
            WelcomeGreetingConfigurationSheet(store: store, enabled: enableOnSave)
        }
        .onDisappear { preview?.stop() }
    }
}

private struct WelcomeGreetingConfigurationSheet: View {
    @ObservedObject var store: CallWelcomeStore
    @Environment(\.dismiss) private var dismiss
    @State private var configuration: CallWelcomeConfiguration
    @State private var error: String?
    @State private var saving: Task<Void, Never>?

    init(store: CallWelcomeStore, enabled: Bool) {
        self.store = store
        var draft = store.configuration
        draft.enabled = enabled
        _configuration = State(initialValue: draft)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.tr("配置接通欢迎语")).font(.headline)
            Form {
                Toggle(L10n.tr("接通后播放欢迎语"), isOn: $configuration.enabled)
                TextField(L10n.tr("TTS 服务地址"), text: $configuration.baseURL)
                SecureField("TTS API Key", text: $configuration.apiKey)
                Picker(L10n.tr("音色"), selection: $configuration.voice) {
                    Text("cosyvoice-official").tag("cosyvoice-official")
                    Text("aishell3-ssb0316").tag("aishell3-ssb0316")
                }
                HStack {
                    Slider(value: $configuration.speed, in: 0.5...2.0, step: 0.1) { Text(L10n.tr("语速")) }
                    Text(String(format: "%.1f×", configuration.speed)).monospacedDigit().frame(width: 45)
                }
            }
            .textFieldStyle(.roundedBorder)
            .disabled(store.isGenerating)
            HStack {
                Text(L10n.tr("欢迎语文字"))
                Spacer()
                Text("\(configuration.text.unicodeScalars.count) / 5000").font(.caption).foregroundStyle(.secondary)
            }
            TextEditor(text: $configuration.text)
                .font(.body)
                .frame(height: 110)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.secondary.opacity(0.3)))
                .disabled(store.isGenerating)
            Text(L10n.tr("保存时调用 TTS 生成并缓存语音；修改失败会保留原欢迎语。密钥仅保存在本机配置文件，不使用钥匙串。"))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(L10n.tr("合成可能需要几分钟。保存后可在上一页试听；新配置从下次自动接听生效。"))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let error { Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                if store.isGenerating { ProgressView().controlSize(.small); Text(L10n.tr("正在生成欢迎语…")).font(.caption) }
                Spacer()
                Button(L10n.tr("取消")) { saving?.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
                Button(L10n.tr("生成并保存")) {
                    error = nil
                    saving = Task {
                        do { try await store.save(configuration); dismiss() }
                        catch is CancellationError { }
                        catch { self.error = CallWelcomeError.message(for: error) }
                    }
                }
                .disabled(store.isGenerating)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 580)
        .onDisappear { saving?.cancel() }
    }
}
