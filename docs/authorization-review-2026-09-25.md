# WgSense 首次授权与常驻服务审阅（2026-09-25）

> 这是首次审阅时的候选快照。之后用户明确接受个人使用下的本机安全取舍，服务可靠性问题已继续实现和隔离验证。当前进展以 [个人用候选实现](personal-service-implementation-2026-09-25.md) 为准；下文不应被当作后续代码全部未修复的结论。

结论：当前候选不可安全交付。把管理员弹窗次数限制为一次，没有实现可靠的一次安装；自动安装长期 root 服务还扩大了现有 API 和文件权限问题的暴露范围。以下结论基于当前未提交代码、隔离测试和构建，不代表已在真实安装或网络环境中验收。

审阅后已撤回本次候选的首次自动安装、`systemHelperInstallAttempted`、显式用户名传参及安装/卸载脚本改动，防止误构建交付。下文涉及这些候选改动的行号是审阅时的快照，当前工作树不再包含它们；P0 root API 和原安装脚本风险仍存在。隔离端口占用修复及本报告保留。

## 尚未解决的发现，按严重程度排序

### P0：长期 root 服务缺少调用者和文件访问边界

- `core/api/api.go:49` 直接注册整个 HTTP API；没有认证、调用者身份、Host/Origin 校验。`api.go:118` 等修改状态接口也没有限制 HTTP 方法。
- `core/internal/tunnel/tunnel_darwin.go:277` 用客户端提供的 profile 名拼接路径并 `os.WriteFile`，没有路径约束或禁止符号链接；`api.go:181` 调用的 ImportProfile 不验证内容。root 进程因此可能替无权限调用者写到配置目录之外。导出接口也没有权限检查。
- `core/api/api.go:379` 接受发送文件绝对路径，交给同一 root 进程的传输模块读取；`core/internal/transfer/outgoing_send.go:232` 直接打开文件。
- `packaging/wgsense-install-services.sh:39` 使用 `/usr/local/libexec`，未校验可执行文件及所有祖先目录的所有权/写权限；第 47–48 行把 root 使用的 runtime 递归交给登录用户。root 写入用户可替换路径的模式同样适用于 DNS 快照。

独立隔离探针已实证三个结果：无认证 profile import 通过 symlink 改写 profile 目录外的合成文件；无认证 export 返回该内容；无认证 GET 调用 shutdown 回调。测试只使用临时目录、临时 loopback HTTP 和空回调，没有读取任何真实私钥、用 root 执行、创建 TUN 或启动 LAN 服务。探针源码和输出留在 `/tmp/wgsense-authorization-review-probe-20260925.go` 与 `/tmp/wgsense-api-review-probe-20260925.log`，临时测试已从正常测试集移除，避免把漏洞行为定义为长期正确行为。

这些漏洞此前已存在，但自动首次安装、KeepAlive、开机启动会使其从按需临时服务变成长期权限入口。修复不能只给 HTTP 加一个随机字符串：必须同时处理 root 功能范围、调用者身份、路径和符号链接、用户数据的归属。

### P1：安装失败、取消和成功被同一个 attempted 标记混在一起

`platforms/macos/WgSense/DaemonClient.swift:177` 在查验 bundle 和实际安装之前持久写入 `systemHelperInstallAttempted=true`；取消、缺脚本、安装失败都会使第 166–168 行以后拒绝正常路径重试。第 133–135 行仅凭 plist 文件存在也会标记完成，即使 launchd 未加载、二进制缺失或版本不兼容。错误提示还会被两秒一次的 `fetchStatus()` 覆盖成通用“daemon 未连接”。

这保证的是“最多自动尝试一次”，不保证“首次成功安装后日常免密码”。应分别保存未安装、等待授权、安装中、可用、失败/可重试、权限已撤销；服务状态和经过身份验证的版本握手才是事实来源，UserDefaults 只能存 UI 偏好。

### P1：旧临时 daemon 没有迁移路径，装好的旧 helper 也不会升级

`DaemonClient.swift:151–155` 对在线、非 passive 的 `app_owned` 直接返回成功，因此首次启动任务可以永远不安装服务；重启 Mac 后仍没有持久服务。passive 模式在第 157–159 行直接拒绝，也不迁移。手动安装脚本不接管旧临时进程，会留下“plist 已安装、新 daemon 持续撞端口、App 仍读取旧进程”的状态。第 184 行只验证任意可解码的 status，未核对 system/app_owned、服务 PID、版本或安装身份。

已有 plist 时 App 无版本检查或升级机制，更新 App 不等于更新正在使用的独立 `/usr/local/libexec/wgsense-daemon`；上一轮断联修复可能根本没有运行。需要一次可回滚的临时服务移交协议，并把目标版本加入健康确认。

### P1：安装/升级不是事务，并发维护和失败后无回滚

`packaging/wgsense-install-services.sh:39–48` 在验证完整配置前覆盖 helper、修改目录；第 67 行先 bootout，第 69–79 行才安装/启动。后续任何失败都没有恢复旧二进制、plist、运行服务或清理半成品；bootstrap 失败后盲目 kickstart 也不能证明新服务生效。接收 mover 失败会使脚本退出，而主服务可能已部分启用。

窗口共享的 `DaemonClient` 和 MainActor 能避免正常自动入口同时弹两次授权，但 `Views/OtherViews.swift:608–616` 的维护路径直接另调 installer，状态属于各窗口，既不共享锁也没有跨进程安装锁。它可以与首次启动任务或其他窗口安装/卸载并发。

NSUserName 作为显式参数传入，已修正 osascript 的 root/USER/SUDO_USER 歧义；但 `dscl | awk '{print $2}'` 仍不能处理带空格 home 路径，模板替换未转义 XML/sed。用户身份应解析为 UID 和完整 home，而不是从环境变量推断。

### P1：首次安装可能立即恢复旧 VPN 意图，与官方 WireGuard 并存

`WgSenseApp.swift:100` 在主窗口出现时触发安装；这不是跨进程启动协调器，仅菜单栏启动也没有独立保证。安装模板未把“安装服务”和“允许接管网络”拆开。`main.go:58` 读取旧 `settings.json`；`policy.go:304–305` 立即巡检；`policy.go:260–263` 根据旧 desired/auto 值自动连接。代码没有其他 VPN 的所有权/冲突仲裁。

因此旧配置仍要求连接时，用户只是打开 App 并同意安装后台服务，就可能创建第二条隧道、接管物理 DNS/路由。端口独占修复只能防止两个相同 HTTP 端口的 WgSense 实例，官方 WireGuard 不占用该端口，不能据此推断可共存。

### P1：统一 signal handler 后仍缺少“停止后不再接收连接”的关闭状态

`main.go:145–152`、170–177、180–185 各自取消 context、cleanup、退出。`policy.go:442–446` 的清理锁释放后，Connect 仍能再次进入；Start 的首次 RunOnce 不先检查取消，已经就绪的 ticker 也可能被继续处理。HTTP 请求入口没有关闸。尤其临时服务 `/api/shutdown` 留出的 200ms 窗口可在清理后重新建隧道，再被 os.Exit 截断。

上一轮看门狗 detach 等待 BindUpdate 的方向正确，现有 race 和真实 UDP 恢复测试也通过；但该等待、endpoint DNS、route/networksetup 命令没有共享退出总预算。被 launchd 强制结束时，DNS 清理仍可能未完成。必须由同一个关闭状态机先拒绝新网络操作、取消并等待策略、清理，再结束进程。

## 本轮独立修复与验证

- `core/cmd/wgsense-daemon/main.go:43–50`：在创建运行目录、传输服务及网络策略之前先占用 API listener。端口冲突立即退出，避免 KeepAlive 反复启动网络策略后才发现自己没有控制端口。
- `core/api/api.go:47–102`：允许使用预先绑定的 listener；启动路径不会再次竞争同一个端口。
- signal 清理注册移到策略启动之前；Serve 异常返回先尝试取消和清理。这不代表上一节关闭竞态已经解决。
- 新增 `main_test.go:16`：真实测试子进程进入 daemon main，面对已占用的临时 loopback 端口必须立即失败，运行目录仍不存在，日志中没有传输服务/巡检启动。子进程在最初 bind 失败后退出，没有启动真实网络服务。
- 通过：`go test ./...`；`go test -race ./internal/tunnel ./internal/policy ./cmd/wgsense-daemon ./api`；`git diff --check`；两个安装脚本语法检查；两个 plist 模板检查。
- macOS Debug 完整构建通过；产物位于 `/tmp/wgsense-review-build-20260925/Build/Products/Debug/WgSense.app`，日志 `/tmp/wgsense-review-build-20260925.log`。没有安装、打开该 App、注册 launchd、操作当前 VPN/DNS/路由或发布。

## 可审查的目标架构

1. **最小 root helper**：只管理受控 WireGuard 设备和它自己创建的网络状态。LocalSend、代理控制、普通文件访问运行在登录用户权限。root 配置/回滚日志放在 root 独占目录，禁止跨边界 symlink 和任意路径写入。
2. **系统服务身份与单一安装协调器**：评估以 macOS 的 SMAppService 注册/管理 bundle 内 LaunchDaemon；使用具备稳定 Team/签名身份的安装产物。全 App 一个状态机，跨进程一个事务锁。安装成功需身份、版本、协议和只读健康握手共同确认。
3. **受限 IPC**：root 控制使用经 peer 代码签名和用户身份验证的 XPC；不让任意 loopback HTTP 请求拥有 root 行为。公开状态和 Widget 另设最小只读接口；协议严格限制操作、参数和版本。Apple 提供 SMAppService 与 NSXPCConnection 代码签名约束 API，但具体部署版本和分发签名仍需实现与验证，不能从 API 存在推导“永不再授权”。
4. **可回滚的移交/升级**：先完整 staging、校验签名/配置/磁盘条件和服务所有权，保留旧版本；新 helper 默认没有网络接管意图；明确移交用户意图并保证旧服务清理完成，才能启用新服务。失败恢复旧服务和配置，报告可重试状态；安装成功不以 shell exit=0 或 HTTP 200 代替。
5. **网络生命周期**：一个策略状态机管理 connect/recovery/shutdown、持久用户意图、操作期限和 DNS 快照。服务活着与 VPN 活着分开显示。其他 VPN 活跃时拒绝自动接管并明确原因；不杀掉、不清理别人的隧道/DNS。

Apple 一手资料：[SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice)、[XPC peer code-signing requirement](https://developer.apple.com/documentation/foundation/nsxpcconnection/setcodesigningrequirement(_:))。

## 阶段验收与交付门槛

| 阶段 | 必须证明的结果 |
| --- | --- |
| 权限边界 | 未授权同用户/其他用户/浏览器请求不能控制 root helper 或读私钥；任意路径、symlink、替换 helper 和越权文件传输被阻止。 |
| 安装/恢复 | 首次批准后可用；取消后能明确重试；每个 staging/bootstrap/健康检查失败点可回滚；并发窗口和第二进程不会重复安装。 |
| 迁移/升级 | app_owned、passive、已有系统服务和版本不匹配均有明确结果；失败保留可用旧服务；App 与 helper 的实际版本一致。 |
| 日常免密码 | 成功安装后重开 App、正常退出 App、Mac 冷重启、daemon 意外退出恢复、VPN/守护反复开关均零次管理员提示，同时验证真实隧道流量。 |
| 共存和关闭 | 官方 WireGuard 运行时打开/安装 WgSense 不改变现有网络；信号/停机/升级和连接并发时最后一步总是清理，DNS/路由恢复到原值。 |
| 网络恢复 | 原断联故障注入、真实睡眠唤醒、断网恢复、受信/非受信和多网卡切换均验证握手、RX/TX、DNS、路由和浏览器请求，不只检查开关或 Connected。 |

这至少涉及服务拆分、IPC、安装状态机、事务迁移和真实设备验收五部分，无法用改几个提权判断并通过编译取代。本轮完成的是审阅、隔离风险实证和端口冲突防护；首次授权功能和完整断联修复均未达到交付条件。
