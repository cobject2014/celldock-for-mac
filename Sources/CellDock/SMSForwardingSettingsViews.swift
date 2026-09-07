import SwiftUI

private struct ForwardingTestButton: View {
    let channel: SMSForwardChannel
    var action: (() async -> Result<Void, Error>)? = nil
    var isConfigured = true
    @State private var isSending = false
    @State private var resultMessage: String?
    @State private var resultIsSuccess = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                sendTest()
            } label: {
                if isSending {
                    ProgressView().controlSize(.small)
                } else {
                    Text(L10n.tr("发送测试"))
                }
            }
            .adaptiveGlassButton()
            .disabled(isSending || !isConfigured)

            if let resultMessage {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: resultIsSuccess ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .foregroundStyle(resultIsSuccess ? .green : .red)
                    Text(resultMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func sendTest() {
        isSending = true
        resultMessage = nil
        Task {
            let result: Result<Void, Error>
            if let action { result = await action() }
            else { result = await SMSForwardingService.shared.sendTest(channel) }
            await MainActor.run {
                isSending = false
                switch result {
                case .success:
                    resultIsSuccess = true
                    resultMessage = L10n.tr("测试消息已发送，请去对应渠道确认收到。")
                case let .failure(error):
                    resultIsSuccess = false
                    resultMessage = error.localizedDescription
                }
            }
        }
    }
}

private struct ForwardingSheetChrome<Content: View>: View {
    let title: String
    var canSave = true
    let onSave: () throws -> Void
    @ViewBuilder let content: () -> Content
    @Environment(\.dismiss) private var dismiss
    @State private var saveError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(title)
                .font(.title3.bold())

            content()

            if let saveError {
                Text(saveError).font(.caption).foregroundStyle(.red)
            }

            Spacer(minLength: 0)

            HStack {
                Spacer()
                Button(L10n.tr("取消")) { dismiss() }
                Button(L10n.tr("保存")) {
                    do {
                        try onSave()
                        dismiss()
                    } catch { saveError = error.localizedDescription }
                }
                .disabled(!canSave)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420, height: 320)
    }
}

struct WeComForwardingConfigSheet: View {
    @ObservedObject var store: SMSForwardingStore
    @State private var webhookURL: String

    init(store: SMSForwardingStore) {
        self.store = store
        _webhookURL = State(initialValue: store.wecom.webhookURL)
    }

    private var configuration: WeComForwardingConfiguration {
        WeComForwardingConfiguration(webhookURL: webhookURL)
    }

    var body: some View {
        ForwardingSheetChrome(title: L10n.tr("配置企业微信群机器人"), canSave: configuration.isConfigured) {
            try store.saveWeCom(configuration)
        } content: {
            VStack(alignment: .leading, spacing: 10) {
                Text(L10n.tr("Webhook 地址")).font(.caption).foregroundStyle(.secondary)
                SecureField("https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=...", text: $webhookURL)
                    .textFieldStyle(.roundedBorder)
                Text(L10n.tr("从企业微信群机器人复制完整地址，包含 key；地址安全保存在钥匙串中。"))
                    .font(.caption2).foregroundStyle(.secondary)
                Text(L10n.tr("启用后，新收到的短信号码、时间和正文（含验证码）将发送到该群。"))
                    .font(.caption2).foregroundStyle(.secondary)
                ForwardingTestButton(channel: .wecom, action: {
                    await SMSForwardingService.shared.sendWeComTest(configuration)
                }, isConfigured: configuration.isConfigured)
            }
        }
    }
}

struct BarkForwardingConfigSheet: View {
    @ObservedObject var store: SMSForwardingStore
    @State private var serverURL: String

    init(store: SMSForwardingStore) {
        self.store = store
        _serverURL = State(initialValue: store.bark.serverURL)
    }

    var body: some View {
        ForwardingSheetChrome(title: L10n.tr("配置 Bark")) {
            store.saveBark(BarkForwardingConfiguration(serverURL: serverURL))
        } content: {
            VStack(alignment: .leading, spacing: 10) {
                Text(L10n.tr("推送地址"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("https://api.day.app/你的Key/", text: $serverURL)
                    .textFieldStyle(.roundedBorder)
                Text(L10n.tr("从 Bark App 里复制包含设备 Key 的完整地址。"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                ForwardingTestButton(channel: .bark)
                    .padding(.top, 8)
            }
        }
    }
}

struct FeishuForwardingConfigSheet: View {
    @ObservedObject var store: SMSForwardingStore
    @State private var webhookURL: String
    @State private var secret: String

    init(store: SMSForwardingStore) {
        self.store = store
        _webhookURL = State(initialValue: store.feishu.webhookURL)
        _secret = State(initialValue: store.feishu.secret)
    }

    var body: some View {
        ForwardingSheetChrome(title: L10n.tr("配置飞书机器人")) {
            store.saveFeishu(FeishuForwardingConfiguration(webhookURL: webhookURL, secret: secret))
        } content: {
            VStack(alignment: .leading, spacing: 10) {
                Text(L10n.tr("Webhook 地址"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("https://open.feishu.cn/open-apis/bot/v2/hook/...", text: $webhookURL)
                    .textFieldStyle(.roundedBorder)

                Text(L10n.tr("签名密钥（可选）"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                SecureField(L10n.tr("开启了“签名校验”才需要填写"), text: $secret)
                    .textFieldStyle(.roundedBorder)

                ForwardingTestButton(channel: .feishu)
                    .padding(.top, 8)
            }
        }
    }
}

struct DingTalkForwardingConfigSheet: View {
    @ObservedObject var store: SMSForwardingStore
    @State private var accessToken: String
    @State private var secret: String

    init(store: SMSForwardingStore) {
        self.store = store
        _accessToken = State(initialValue: store.dingtalk.accessToken)
        _secret = State(initialValue: store.dingtalk.secret)
    }

    var body: some View {
        ForwardingSheetChrome(title: L10n.tr("配置钉钉机器人")) {
            store.saveDingTalk(DingTalkForwardingConfiguration(accessToken: accessToken, secret: secret))
        } content: {
            VStack(alignment: .leading, spacing: 10) {
                Text(L10n.tr("Webhook AccessToken"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField(L10n.tr("access_token 参数的值"), text: $accessToken)
                    .textFieldStyle(.roundedBorder)

                Text(L10n.tr("签名密钥（可选）"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                SecureField(L10n.tr("开启了“加签”才需要填写"), text: $secret)
                    .textFieldStyle(.roundedBorder)

                ForwardingTestButton(channel: .dingtalk)
                    .padding(.top, 8)
            }
        }
    }
}
