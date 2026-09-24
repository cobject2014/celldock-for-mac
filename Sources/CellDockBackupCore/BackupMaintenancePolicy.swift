import Foundation

/// Serial UI transition: durable preparation must succeed before business services resume.
public final class BackupMaintenanceExit {
    private var finishing = false
    private var finished = false
    public init() {}
    @discardableResult
    public func finish(busy: Bool, recoveryRequired: Bool, reviewRequired: Bool, reviewAccepted: Bool,
                       prepare: () throws -> Void, resume: () -> Void) throws -> Bool {
        guard !busy, !recoveryRequired, !reviewRequired || reviewAccepted, !finishing, !finished else { return false }
        finishing = true
        defer { finishing = false }
        try prepare()
        finished = true
        resume()
        return true
    }
}

public enum BackupMaintenancePolicy {
    public static func inactiveConfiguration(_ data: Data, nested: Bool) throws -> Data {
        guard var value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw BackupError.invalid("invalid automation configuration") }
        if nested {
            guard var configuration = value["configuration"] as? [String: Any] else { throw BackupError.invalid("invalid greeting configuration") }
            configuration["enabled"] = false
            value["configuration"] = configuration
        } else { value["enabled"] = false }
        return try JSONSerialization.data(withJSONObject: value)
    }
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
