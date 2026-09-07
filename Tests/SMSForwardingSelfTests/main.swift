import Foundation

enum SelfTestFailure: Error {
    case failed(String)
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw SelfTestFailure.failed(message) }
}

// Reference values computed independently in Python (hmac + hashlib + base64)
// for the same secret/timestamp inputs, so this checks the Swift
// implementation against a second, independent implementation of the
// documented algorithms rather than against itself.
do {
    let endpoint = "https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=test-key"
    let request = try WeComWebhook.request(webhookURL: " \(endpoint)\n", text: "短信：你好\n\"106\"")
    try expect(request.url?.absoluteString == endpoint, "WeCom did not use the complete configured webhook")
    try expect(request.httpMethod == "POST", "WeCom used the wrong HTTP method")
    let payload = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
    try expect(payload["msgtype"] as? String == "text", "WeCom msgtype was not text")
    try expect((payload["text"] as? [String: String])?["content"] == "短信：你好\n\"106\"", "WeCom lost or incorrectly escaped SMS text")
    for invalid in ["", "http://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=x",
                    "https://example.com/cgi-bin/webhook/send?key=x",
                    "https://qyapi.weixin.qq.com/cgi-bin/webhook/send",
                    "https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=",
                    "https://user@qyapi.weixin.qq.com/cgi-bin/webhook/send?key=x",
                    "https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=x&key=y"] {
        do {
            _ = try WeComWebhook.request(webhookURL: invalid, text: "test")
            throw SelfTestFailure.failed("invalid WeCom endpoint accepted")
        } catch is WeComWebhook.Failure { }
    }
    try WeComWebhook.validateResponse(data: Data(#"{"errcode":0,"errmsg":"ok"}"#.utf8), statusCode: 200)
    for (status, body) in [(200, #"{"errcode":93000,"errmsg":"invalid webhook test-key"}"#),
                           (200, "{}"), (200, "not-json"), (500, #"{"errcode":0}"#)] {
        do {
            try WeComWebhook.validateResponse(data: Data(body.utf8), statusCode: status)
            throw SelfTestFailure.failed("WeCom failure was reported as successful delivery")
        } catch let error as WeComWebhook.Failure {
            try expect(!error.localizedDescription.contains("test-key"), "WeCom response leaked webhook secret")
        }
    }
    do {
        _ = try WeComWebhook.request(webhookURL: endpoint, text: String(repeating: "中", count: 683))
        throw SelfTestFailure.failed("WeCom byte limit treated Unicode characters as single bytes")
    } catch is WeComWebhook.Failure { }

    let feishuSign = SMSForwardingSigning.feishuSign(
        secret: "test_secret_123",
        timestampSeconds: 1_700_000_000
    )
    try expect(
        feishuSign == "ADXLocYmfIVvbO1q8epZkDElPLHsHxmj27uaQhfuRhE=",
        "Feishu sign did not match the independently-computed reference vector"
    )

    let dingTalkSign = SMSForwardingSigning.dingTalkSign(
        secret: "test_secret_123",
        timestampMilliseconds: 1_700_000_000_000
    )
    try expect(
        dingTalkSign == "4E76yXqQpW1fliVff/re+A7gBQu9SFSO72yXPSls3dA=",
        "DingTalk sign did not match the independently-computed reference vector"
    )

    // Feishu and DingTalk deliberately swap which side is the HMAC key vs.
    // message; guard against ever accidentally unifying the two call sites.
    try expect(
        feishuSign != dingTalkSign,
        "Feishu and DingTalk signs collided unexpectedly for matching inputs"
    )

    let encoded = SMSForwardingSigning.urlEncodedQueryValue("a+b/c=d e")
    try expect(
        encoded == "a%2Bb%2Fc%3Dd%20e",
        "urlEncodedQueryValue did not percent-encode reserved query characters"
    )

    print("All SMSForwardingSelfTests passed.")
} catch {
    print("SMSForwardingSelfTests FAILED: \(error)")
    exit(1)
}
