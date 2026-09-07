import Combine
import Foundation

struct BarkForwardingConfiguration: Equatable {
    var serverURL: String = ""

    var isConfigured: Bool { !serverURL.trimmingCharacters(in: .whitespaces).isEmpty }
}

struct FeishuForwardingConfiguration: Equatable {
    var webhookURL: String = ""
    var secret: String = ""

    var isConfigured: Bool { !webhookURL.trimmingCharacters(in: .whitespaces).isEmpty }
}

struct DingTalkForwardingConfiguration: Equatable {
    var accessToken: String = ""
    var secret: String = ""

    var isConfigured: Bool { !accessToken.trimmingCharacters(in: .whitespaces).isEmpty }
}

@MainActor
final class SMSForwardingStore: ObservableObject {
    static let shared = SMSForwardingStore()

    @Published private(set) var enabledChannels: Set<SMSForwardChannel>
    @Published var lastResults: [SMSForwardChannel: SMSForwardResult] = [:]

    @Published private(set) var bark = BarkForwardingConfiguration()
    @Published private(set) var feishu = FeishuForwardingConfiguration()
    @Published private(set) var dingtalk = DingTalkForwardingConfiguration()
    @Published private(set) var wecom = WeComForwardingConfiguration()

    private let defaults: UserDefaults
    private let credentialStore: SMSForwardingCredentialStore
    private let key = "SMSForwardingSettings.v1"

    init(
        defaults: UserDefaults = .standard,
        credentialStore: SMSForwardingCredentialStore = SMSForwardingCredentialStore()
    ) {
        self.defaults = defaults
        self.credentialStore = credentialStore
        let settings = defaults.data(forKey: key).flatMap {
            try? JSONDecoder().decode(SMSForwardingSettings.self, from: $0)
        } ?? .empty
        enabledChannels = settings.enabledChannels

        bark.serverURL = ((try? credentialStore.value(for: .barkServerURL)) ?? nil) ?? ""
        feishu.webhookURL = ((try? credentialStore.value(for: .feishuWebhookURL)) ?? nil) ?? ""
        feishu.secret = ((try? credentialStore.value(for: .feishuSecret)) ?? nil) ?? ""
        dingtalk.accessToken = ((try? credentialStore.value(for: .dingtalkAccessToken)) ?? nil) ?? ""
        dingtalk.secret = ((try? credentialStore.value(for: .dingtalkSecret)) ?? nil) ?? ""
        wecom.webhookURL = ((try? credentialStore.value(for: .wecomWebhookURL)) ?? nil) ?? ""
    }

    func isEnabled(_ channel: SMSForwardChannel) -> Bool {
        enabledChannels.contains(channel)
    }

    func setEnabled(_ enabled: Bool, for channel: SMSForwardChannel) {
        if enabled {
            enabledChannels.insert(channel)
        } else {
            enabledChannels.remove(channel)
        }
        persistSettings()
    }

    func saveBark(_ configuration: BarkForwardingConfiguration) {
        bark = configuration
        try? credentialStore.setValue(configuration.serverURL, for: .barkServerURL)
    }

    func saveFeishu(_ configuration: FeishuForwardingConfiguration) {
        feishu = configuration
        try? credentialStore.setValue(configuration.webhookURL, for: .feishuWebhookURL)
        try? credentialStore.setValue(configuration.secret, for: .feishuSecret)
    }

    func saveDingTalk(_ configuration: DingTalkForwardingConfiguration) {
        dingtalk = configuration
        try? credentialStore.setValue(configuration.accessToken, for: .dingtalkAccessToken)
        try? credentialStore.setValue(configuration.secret, for: .dingtalkSecret)
    }

    func recordResult(_ result: SMSForwardResult, for channel: SMSForwardChannel) {
        lastResults[channel] = result
    }

    func saveWeCom(_ configuration: WeComForwardingConfiguration) throws {
        let url = try WeComWebhook.endpoint(configuration.webhookURL)
        try credentialStore.setValue(url.absoluteString, for: .wecomWebhookURL)
        wecom = WeComForwardingConfiguration(webhookURL: url.absoluteString)
    }

    private func persistSettings() {
        let settings = SMSForwardingSettings(enabledChannels: enabledChannels)
        defaults.set(try? JSONEncoder().encode(settings), forKey: key)
    }
}
