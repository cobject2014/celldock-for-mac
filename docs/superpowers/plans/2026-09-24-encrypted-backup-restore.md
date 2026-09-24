# Encrypted Backup and Cross-Mac Restore Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 用户可以选择 iCloud 文件夹创建密码加密备份，并在另一台 Mac 上完整恢复 CellDock 数据与可迁移配置。

**Architecture:** 独立的备份核心负责格式、策略、加密和恢复事务；现有 Store 通过限定接口提供快照和凭据。协调器统一阻止业务写入并控制恢复向导，UI 不直接复制数据文件或访问钥匙串。

**Tech Stack:** Swift 5 language mode / Swift tools 6，macOS 14+，Foundation、CryptoKit、CommonCrypto、Security、SwiftUI/AppKit；沿用命令行 self-tests 和现有签名打包脚本。

**Spec:** `docs/superpowers/specs/2026-09-24-encrypted-backup-restore-design.md`

## Global Constraints

- 手动、时间点式迁移，不是实时同步；完整替换，不合并数据。
- 密码至少 12 个字符；PBKDF2-HMAC-SHA256，第一版 600,000 次迭代、随机 16 字节盐，AES-256-GCM。
- 分块处理大录音；不将全部录音装入内存；第一版不增加压缩。
- 白名单范围内导出文件、配置和凭据；目标 iCloud 文件夹绝不写入明文业务数据或凭据。
- 覆盖前验证、确认并保存加密回滚快照；恢复中断后先恢复一致性，不启动业务。
- 系统权限、模块固件、SIM/eSIM 实际内容不迁移；历史短信不重新转发。
- 原始左右分轨录音保持不变；真实数据覆盖恢复需要用户单独确认。
- 测试必须使用临时目录、隔离偏好域和测试凭据存储，不访问真实本机秘密。

## Review Focus

1. 源机的绝对路径、USB 位置和自选音效不能直接成为目标机的有效绑定；Task 1/3 覆盖路径重建和待确认路由。
2. 最后一块丢失、额外尾部或认证成功但清单不符不能作为完整备份；Task 2 覆盖终结帧和跨帧一致性。
3. 钥匙串拒绝访问不能被 `try?` 降级为空凭据；Task 3/4 覆盖显式失败以及原本不存在的凭据回滚。
4. 验证预览后云端文件被替换，不能恢复未验证的新内容；Task 4/5 使用同一私有 staging 快照，覆盖文件替换与占位下载。
5. 进程在文件、偏好和凭据三个存储更新之间退出，不能让业务读取半恢复状态；Task 4/5 覆盖启动门禁和每个提交边界中断。

## 文件与职责

新增核心 target `CellDockBackupCore`，不依赖 App 单例：

- `Sources/CellDockBackupCore/BackupModels.swift`：清单、凭据描述、快照引用、限制、错误类型。
- `Sources/CellDockBackupCore/BackupPolicy.swift`：相对路径、设置、凭据范围和模型校验。
- `Sources/CellDockBackupCore/BackupArchive.swift`：顺序分块格式、KDF、认证加解密、进度与取消。
- `Sources/CellDockBackupCore/BackupRestoreTransaction.swift`：事务日志、提交、回滚、启动恢复。
- `Tests/BackupSelfTests/main.swift`、`scripts/run_backup_tests.sh`：隔离测试驱动，接入 `scripts/run_tests.sh`。

新增 App 文件：

- `Sources/CellDock/BackupSnapshotProvider.swift`：业务 Store 快照与类型化配置导入导出。
- `Sources/CellDock/BackupCredentialAdapter.swift`：限于 CellDock 三类凭据的访问，错误向上传递。
- `Sources/CellDock/BackupRestoreCoordinator.swift`：操作状态、门禁、快照、iCloud 文件访问、事务调度。
- `Sources/CellDock/BackupSettingsView.swift`：选择目录、密码、预览、确认、进度、恢复后向导。
- `docs/backup-restore.md`：使用、密码遗失、迁移边界、回滚指南。

现有修改点：`Package.swift`、`AppState.swift`、`CellDockApp.swift`、`CellDockSettingsView.swift`、`MessageStore.swift`、`CallHistoryStore.swift`、`CallRecordingStore.swift`、`SMSForwardingStore.swift`、`SMSForwardingCredentialStore.swift`、`SOCKSProxyStore.swift`、`VoWiFiUpstreamProxyStore.swift`、`AlertSoundService.swift`、四种语言 `Resources/Localization/*/Localizable.strings`。若字段审计发现其他持久化所有者，将其加入分类表并通过适配器接入，不无差别复制其数据。

## Task 1: 类型、范围策略与隔离测试入口

**Files:** 新增 `BackupModels.swift`、`BackupPolicy.swift`、测试驱动及脚本；修改 `Package.swift`、`scripts/run_tests.sh`；新增 `docs/backup-data-inventory.md`。

**Interfaces:**

```swift
public struct BackupFileEntry: Codable, Equatable {
    public let path: String
    public let size: UInt64
    public let sha256: String
}
public struct BackupCredential: Codable, Equatable {
    public let namespace: String
    public let account: String
    public let value: Data? // nil means absent, not an empty secret
}
public struct BackupManifest: Codable {
    public let formatVersion: Int
    public let appVersion: String
    public let createdAt: Date
    public let files: [BackupFileEntry]
    public let messageCount: Int
    public let callCount: Int
    public let recordingCount: Int
}
public struct BackupSnapshot {
    public let root: URL
    public let manifest: BackupManifest
}
public enum BackupPolicy {
    public static func validateRelativePath(_ path: String) throws
    public static func validateManifest(_ manifest: BackupManifest) throws
}
```

- [ ] 审计 `UserDefaults`、`@AppStorage`、业务目录写入和 `SecItem`，在分类表列出每个键/文件/凭据的所有者、迁移分类、默认缺失行为；检查自选音效是否持久化外部资源引用。
- [ ] 写红测：纯路径校验、未知格式、重复路径、Unicode 文件名、限制边界；测试辅助 `expectThrows` 在闭包不抛错时抛出测试失败。

```swift
try expectThrows { try BackupPolicy.validateRelativePath("../calls.json") }
try expectThrows { try BackupPolicy.validateRelativePath("/tmp/calls.json") }
try expectThrows { try BackupPolicy.validateRelativePath("Recordings/../calls.json") }
try BackupPolicy.validateRelativePath("Recordings/通话.m4a")
```

- [ ] 用 `./scripts/run_backup_tests.sh` 看到缺失 API 导致的失败；脚本通过 SwiftPM 编译独立测试可执行 target，仅链接核心，不启动 App。
- [ ] 实现模型和策略；协议固定 v1，清单最大 16 MiB，文件最多 100,000 个、文件总量最多 1 TiB、路径 UTF-8 最多 1024 字节；对所有长度累加使用溢出检查。系统/机器相关键只列入排除表。
- [ ] 执行测试并提交：`git add Package.swift Sources/CellDockBackupCore Tests/BackupSelfTests scripts docs/backup-data-inventory.md && git commit -m "feat: define backup schema and migration policy"`。

## Task 2: 加密容器与可靠发布

**Files:** 新增 `BackupArchive.swift`；扩展 `Tests/BackupSelfTests/main.swift`。

**Interfaces:**

```swift
public enum BackupArchive {
    public static func seal(_ snapshot: BackupSnapshot, to output: URL,
        password: String, progress: (UInt64) -> Void, cancelled: () -> Bool) throws
    public static func open(_ archive: URL, into staging: URL,
        password: String, progress: (UInt64) -> Void, cancelled: () -> Bool) throws -> BackupSnapshot
}
```

- [ ] 写红测，fixture 使用 Task 1 模型和临时目录构造两份文件，秘密只使用 `test-secret`。

```swift
try BackupArchive.seal(fixture, to: encryptedURL, password: "test-password-123", progress: { _ in }, cancelled: { false })
let restored = try BackupArchive.open(encryptedURL, into: restoredRoot,
    password: "test-password-123", progress: { _ in }, cancelled: { false })
try expect(try Data(contentsOf: restored.root.appendingPathComponent("calls.json")) == expectedCalls, "round-trip mismatch")
try expectThrows {
    _ = try BackupArchive.open(encryptedURL, into: otherRoot,
        password: "wrong-password", progress: { _ in }, cancelled: { false })
}
```

- [ ] 测试先失败；然后实现系统 KDF 和 CryptoKit AES.GCM，使用 UTF-8 原始密码，不自动裁剪或 Unicode 归一化；密码比较仅用于输入确认。
- [ ] 实现固定二进制头及明确字节序：magic/version/迭代次数/16 字节盐/8 字节随机 nonce 前缀。nonce 后接 32 位块序号；块上限 1 MiB，使用完序号前拒绝；头部和帧类型、序号、长度作为 AAD。第一帧是加密清单；数据帧包含条目索引和偏移；最后认证帧绑定清单 SHA-256、总块数和累计字节数。必须读到正确终结帧且 EOF，无额外尾部。
- [ ] 分别测试单字节篡改、截断、重排、重复帧、追加数据、600,000 以外不受支持的 KDF 参数、大小溢出、跨块音频和取消。比较原始录音 SHA-256，确认只读取源文件。
- [ ] 在本机权限 0700 的 UUID 临时目录生成备份，文件 0600；清单与解密文件通过策略检查后才接受。发布到用户目录的唯一 `.partial` 文件，落盘校验后重命名；失败只清理本次已记录的临时路径。
- [ ] 执行 `./scripts/run_backup_tests.sh` 并提交 `feat: add authenticated encrypted backup archives`。

## Task 3: 快照、配置与凭据适配

**Files:** 新增 `BackupSnapshotProvider.swift`、`BackupCredentialAdapter.swift`；修改上述 Store 导出接口和字段分类文档。

**Interfaces:**

```swift
public protocol BackupCredentialAccess {
    func read(namespace: String, account: String) throws -> Data?
    func write(_ value: Data?, namespace: String, account: String) throws
}
// App layer, invoked only after the maintenance barrier is held.
@MainActor protocol BackupSnapshotProviding {
    func capture(into root: URL) throws -> BackupSnapshot
    func validate(_ snapshot: BackupSnapshot) throws
}
```

- [ ] 先写失败用例：短信已读状态/删除标记、通话录音关联、自动接听标签、配置、外部音效资源在备份后可重建；机器路径和网络服务 ID 不出现在可应用配置中。
- [ ] 凭据测试使用字典实现 `BackupCredentialAccess`，区分 nil 与空 Data；读取异常直接抛出，不能降级为空。限定三个命名空间：短信转发、SOCKS 代理、VoWiFi 上游代理，账户来自 Field 枚举或配置中明确引用的 ID。

```swift
struct DeniedCredentials: BackupCredentialAccess {
    func read(namespace: String, account: String) throws -> Data? { throw CocoaError(.fileReadNoPermission) }
    func write(_ value: Data?, namespace: String, account: String) throws { throw CocoaError(.fileWriteNoPermission) }
}
```

- [ ] 使用类型化的备份配置结构导出白名单，清单中的数据包括 `preferences.plist` 和 `credentials.json`，但这些明文只在本机私有 staging 出现，归档内均加密。现有 `try?` UI 保存方法不能用作事务写入接口。
- [ ] 为文件缺失定义语义：空集合可导出为空数组；有索引却缺音频要明确报错，不静默跳过。捕获源文件前后元数据并拒绝未经门禁的变化，资源不得为符号链接。
- [ ] 完成 `validate`：解码业务模型、校验 UUID/重复条目/索引和录音关联；恢复资源路径映射到目标根。执行完整测试，提交 `feat: capture portable CellDock data and credentials`。

## Task 4: 跨存储恢复事务与中断恢复

**Files:** 新增 `BackupRestoreTransaction.swift`；扩展核心测试；App 适配器提供偏好和凭据实现。

**Interfaces:**

```swift
public protocol BackupSettingsAccess {
    func read() throws -> Data
    func replace(with encodedSettings: Data) throws
}
public struct BackupRestoreTransaction {
    public init(root: URL, journal: URL, settings: BackupSettingsAccess, credentials: BackupCredentialAccess)
    public func apply(_ verified: BackupSnapshot, rollback: URL, password: String) throws
    public func recover(rollback: URL, password: String) throws
    public static func hasPendingRecovery(at journal: URL) throws -> Bool
}
```

- [ ] 写红测：建立目标旧数据 A、备份数据 B；在每个文件/配置/凭据提交位置注入失败；期望恢复 A，原来不存在的凭据仍不存在。

```swift
try expectThrows { try transaction.apply(verifiedB, rollback: rollbackURL, password: "test-password-123") }
try expect(try Data(contentsOf: targetCalls) == originalA, "rollback did not restore target")
try expect(try credentials.read(namespace: "sms", account: "wecom") == nil, "rollback invented a credential")
```

- [ ] 定义事务阶段：`prepared`, `filesApplying`, `settingsApplying`, `credentialsApplying`, `committed`, `rollingBack`。原子更新日志并落盘；记录的是事务 ID、阶段、文件清单和已处理索引，不记录秘密。每次真实写操作前都已有可持久恢复的旧状态。
- [ ] 使用 Task 2 保存目标机加密回滚快照；验证回滚包后才修改数据。文件只替换白名单位置，未受管日志/备份/其他目录不受影响。替换偏好和限定凭据时删除备份中不存在、但属于本次受管集合的目标项，记录原值。
- [ ] `apply` 不接受原始外部 URL，只接受已验证的私有快照，防止预览后 iCloud 文件替换。逐步失败后幂等恢复旧状态；回滚自身失败时保留日志和快照并报告恢复路径，不启动业务。
- [ ] 在独立子进程模拟每个阶段退出，再用 `recover` 验证恢复；错误恢复密码不得改任何文件。测试清单损坏、磁盘不足、权限错误以及回滚包丢失，均保留业务门禁。
- [ ] 运行完整测试并提交 `feat: add recoverable backup restore transactions`。

## Task 5: 运行门禁、iCloud 访问与设置页面

**Files:** 新增 `BackupRestoreCoordinator.swift`、`BackupSettingsView.swift`；修改 `AppState.swift`、`CellDockApp.swift`、`CellDockSettingsView.swift`、`ModemService.swift` 及四种语言资源。

**Interfaces:**

```swift
@MainActor final class BackupRestoreCoordinator: ObservableObject {
    enum Phase { case idle, snapshotting, encrypting, validating, awaitingConfirmation, restoring, recoveryRequired, completed }
    @Published private(set) var phase: Phase = .idle
    func backup(to directory: URL, password: String) async
    func preview(archive: URL, password: String) async
    func confirmRestore() async
    func cancel()
}
```

- [ ] 先写门禁测试：任意模块通话/录音/eSIM/短信发送或其他状态写入未完成时拒绝；持锁后新的变更动作不允许进入。锁覆盖所有模块而非仅当前 UI 选中模块。
- [ ] 实现 App 维护状态：停止产生新任务，等待已在执行的持久化/转发任务完成；模块短信事件只记待重新扫描标志，不触发导入或转发。退出备份维护状态后执行原有短信扫描；恢复后先载入历史和删除标记，再经用户确认才连接业务。
- [ ] 在 `AppState.start()` 启动硬件、代理、自动接听和消息转发之前检查事务日志；有日志只展示恢复向导。有正常迁移完成状态则进入模块/权限/自动化确认向导，而非直接启用源机网络代理或自动删除。
- [ ] 实现 `NSOpenPanel` 文件夹和备份选择；目录书签只保存本机。外部备份先通过文件协调复制到私有 staging，检查 iCloud 下载状态并支持显式下载；取消、下载失败和空间不足均保留原数据。后台工作不阻塞 MainActor，进度回主线程更新。
- [ ] 设置类别加入“备份与恢复”；密码 `SecureField` 输入及确认、最少 12 字符；预览展示数量与覆盖范围；确认恢复与密码输入分离。界面只显示安全错误文本，不输出 URL 中的秘密、明文凭据或密码。
- [ ] 测试预览后外部文件变化、密码取消、选择不可写目录、没有 iCloud、未下载占位文件、关闭窗口及重复点击。核对“已保存到本地，等待 iCloud 同步”文案不会误报上传完成。
- [ ] 测试恢复后开关待确认、系统授权未伪造、USB 路由未直接启用、历史短信不重复转发且没有 SIM 写操作。执行 `./scripts/run_tests.sh` 和 `swift build --disable-sandbox -Xswiftc -disable-sandbox`；提交 `feat: add backup and restore settings workflow`。

## Task 6: 端到端验证、文档与交付

**Files:** 扩展 `Tests/BackupSelfTests/main.swift`；新增 `docs/backup-restore.md`；检查 `scripts/build_app.sh` 的新 target 链接。

- [ ] 将 Task 1—5 的独立测试组成源环境 A→加密包→目标环境 B 的全流程；fixture 包含中文短信、多个模块、自动接听记录、双声道录音、所有凭据类别和自选资源。恢复后逐字段及逐文件哈希验证。
- [ ] 专门构造多块大录音，验证内存不随总音频大小线性增长；取消后目标目录没有正式备份文件，测试目录外没有任何写入。
- [ ] 运行完整 self-tests、定位新增失败、修复后重跑；执行签名 universal build。审核秘密不进入日志/备份文件名/公开清单，密码不进入命令行，明文临时数据只在受限目录且正常结束清理。
- [ ] 记录恢复状态机和故障注入结果、兼容版本限制、密码遗失后果、如何找到加密回滚快照。说明第二台 Mac 系统权限和自动化确认步骤。
- [ ] 本机 UI 验证使用独立测试环境；若用户选择真实 iCloud 目录并设置密码，才生成真实备份。不能在本机真实数据上模拟破坏性恢复；第二台 Mac 恢复待用户明确选择目标并确认。
- [ ] 运行 `git diff --check`，逐项核对设计验收条目，独立审查整个分支，报告未实测的跨机/iCloud 条件。提交 `test: verify encrypted cross-Mac backup and restore`，不自动 push 或覆盖安装。

## 执行选择与当前状态

计划已完成，尚未编写产品代码或创建真实备份。建议本会话顺序实施，完成后独立审查整个分支；这些任务共享格式和事务接口，顺序实现便于保持一致。也可选择分任务子代理实施和逐项审查。须由用户审阅计划并选择执行方式后开始。
