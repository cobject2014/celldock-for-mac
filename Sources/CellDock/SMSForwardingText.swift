import Foundation

struct SMSForwardingRecipient {
    let moduleID: CellularModuleID
    let name: String
    let phoneNumber: String?
}

enum SMSForwardingText {
    static func format(_ message: SMSMessage, recipients: [SMSForwardingRecipient]) -> String {
        // Resolve only the receiving module, never the currently selected SIM.
        // Capture this text before starting asynchronous delivery.
        let recipient = recipients.first { $0.moduleID == message.moduleID }
        let number = recipient?.phoneNumber?.trimmingCharacters(in: .whitespacesAndNewlines)
        let receiver = number.flatMap { $0.isEmpty ? nil : $0 } ?? L10n.tr("号码未知")
        let moduleName = recipient?.name ?? message.moduleID?.rawValue ?? L10n.tr("模组未知")
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return L10n.tr(
            "来自：%@\n接收：%@（%@）\n时间：%@\n内容：%@",
            message.sender,
            receiver,
            moduleName,
            formatter.string(from: message.timestamp),
            message.body
        )
    }
}
