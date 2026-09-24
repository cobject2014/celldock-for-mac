import Foundation

public enum BackupMaintenancePolicy {
    public static func canEnter(activeOperations: [Bool]) -> Bool { !activeOperations.contains(true) }
    /// Preserve portable settings, but require target-Mac consent before any automation runs.
    public static func inactivePreferences(_ data: Data) throws -> Data {
        var values = try BackupPreferences.decode(data)
        for key in ["AutomaticallyAnswerCalls.v1", "AutomaticallyRecordCalls.v1", "AutoDeleteReadVerificationMessages.v1"] { values[key] = false }
        if values["SMSForwardingSettings.v1"] != nil {
            values["SMSForwardingSettings.v1"] = try JSONSerialization.data(withJSONObject: ["enabledChannels": [String]()])
        }
        for key in ["SOCKSProxyConfigurations.v1", "VoWiFiUpstreamProxies.v1"] {
            guard let data = values[key] as? Data else { continue }
            guard var configs = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw BackupError.invalid("invalid proxies") }
            for index in configs.indices { configs[index]["isEnabled"] = false }
            values[key] = try JSONSerialization.data(withJSONObject: configs)
        }
        values.removeValue(forKey: "VoWiFiUpstreamRoutes.v1")
        return try PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0)
    }
}
