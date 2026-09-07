# 企业微信群机器人转发

设置 → 蜂窝与通信 → 短信转发 → **企业微信（Webhook）** → 配置。

1. 在企业微信群机器人详情中复制完整的 HTTPS Webhook 地址（含 `key`）。
2. 粘贴到配置窗口。地址以密码形式显示并保存到 macOS 钥匙串，不写入仓库或普通偏好设置。
3. 点击“发送测试”：仅向当前填写的地址发送固定测试文字，不会保存草稿或开启自动转发。
4. 点击保存，再开启企业微信开关。只有后续新收到的短信会自动转发；历史同步不会转发。

开启后，发送方号码、短信时间和完整正文（包括验证码）会发送到该群。
请勿在聊天、截图或 GitHub 中公开真实 Webhook 地址。

此通道专用于企业微信群机器人：
`https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=...`。
它不是任意格式的通用 Webhook。使用 `POST` 和 `msgtype=text` / `text.content`，
仅在 HTTP 成功且 `errcode=0` 时报告成功。错误提示只包含错误码，不回显
可能包含密钥的服务端正文。请求不跟随重定向。

超过 2048 UTF-8 字节的转发文本会明确报错，不会截断内容；完整短信仍保存在 Mac。
网络错误或频率限制不会自动重试，以避免重复发群消息。

参考：[腾讯 CloudBase 企业微信 Webhook 示例](https://docs.cloudbase.net/recipes/connect-wecom-webhook-cloud-function)。
