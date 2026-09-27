# WgSense 断联调查与本地修复（2026-09-25）

## 结论和边界

确认了一个能够将临时网络错误放大成持续失联的恢复缺陷：UDP bind 重建失败会先关闭旧 socket，随后出现 EAFNOSUPPORT；看门狗却只等待 EADDRNOTAVAIL，日志承诺的定时重试没有执行。另确认退出清理的双信号处理存在竞态。本轮已完成最小本地修复和失败注入测试。

这不证明所有断联都已解决。最初 EADDRNOTAVAIL、端口 EADDRINUSE 的外部触发原因没有足够现场证据；策略、DNS、状态显示和请求超时还有独立问题。未安装、启动或停止 WgSense，未更改 VPN、DNS、路由、服务器，也未发布版本。

## 版本与现场

- 当前代码：`/Users/adams/Projects/wgsense`，分支 `rebuild/clickable-baseline-20260717`，调查起点 clean，HEAD `65c8c57978cdf1eb2384d9659d85087728e51f0a`，2026-09-14 Release 0.3.10 beta 1。分支名称虽然旧，代码并非 7 月版本。
- `/Users/adams/Projects/wgsense-restored-20260717-0900` 为 clean 的 7 月恢复副本，HEAD `a514ca57372b3eced063ef7f4c70e8aa2bfe5725`。
- 安装 App 为 0.3.10 build 20。内嵌 helper 的 Go 元信息为同一 `65c8c579` revision，但 `vcs.modified=true`，因此不能保证构建目录当时没有额外改动。
- 当前只读快照：没有 WgSense 进程；官方 WireGuard NetworkExtension 使用 utun10，主 DNS 为绑定该隧道的 10.66.66.1；Wi-Fi 无手工 DNS，物理 scoped DNS 为本地路由器。当前能访问外网。这是官方 WireGuard 回退路径，不能算作 WgSense 修复验收，也不能把其隧道 DNS 认作 WgSense 残留。
- 故障依据来自现存 `/var/log/wgsense-daemon.log`；末条为 9 月 23 日 09:05:24。未把旧记忆作为当前运行证据。

## 按证据等级排序

### A：日志、源码和失败注入共同证实

9 月 22 日 04:30:02 第 72 次 UDP bind 重建后仍报 EADDRNOTAVAIL；04:30:04 第 73 次报 `listen udp4 ... bind: address already in use`，日志称“4s 后重试”；之后发包与握手变成 `address family not supported by protocol family`，直到 04:31:09 五次健康探测失败才整条重建。期间巡检持续报告 Connected。

依赖 `wireguard/device/device.go` 的 BindUpdate 先 close 再 open。Open 失败会将 port 置零；`conn/bind_std.go` 的 Send 在对应 socket 为 nil 时返回 EAFNOSUPPORT。故障的 family 错误不支持“选错 IPv6”结论：本轮用 IPv4 loopback endpoint 也复现了同样的二级错误。

旧 `rebind_darwin.go` 的失败分支只增加 backoff 并返回；loop 冷却、清空通知后重新等待。Logger 又仅匹配 EADDRNOTAVAIL 文本，因此不会主动重新打开失败的 bind。

新增测试先在旧代码失败（调用次数始终 1），修复后通过。真实 wireguard-go 内存 TUN 与本机 UDP 失败注入进一步验证：一次 Open=EADDRINUSE 后，Send=EAFNOSUPPORT，随后无需新的日志事件也会自动 Open，最终真实 loopback UDP 载荷到达接收端。

### B：确定的生命周期缺陷，事故归属尚不能逐次证明

- 看门狗 detach 原先只清空回调并关闭停止通道，没有等待已经开始的 BindUpdate。阻塞回调测试证明 detach 会提前返回，违反“先 detach 再销毁设备”的约束。已修为等待工作循环结束，并串行 attach/detach。
- daemon main 和 Darwin tunnel 各自注册 SIGTERM/SIGINT，各自 cleanup 后 os.Exit。tunnel 的处理绕开策略操作锁；cleanup 提前写 cleaned=true，另一个处理可能因此跳过清理并抢先退出。现存日志同一退出事件有两条不同处理器日志。已删除 tunnel 独立信号处理，由 daemon 主入口经 ShutdownCleanup 统一清理，保留 SIGHUP 语义。未在真实联网 daemon 上做信号测试。

### C：已定位、尚未纳入本轮最小修复的问题

- **网络变化后过早重建**：`core/internal/policy/policy.go:140` 单次 5 秒 HTTP 探测失败即 Disconnect/Connect，绕过正常巡检的连接宽限与五次失败门槛；没有消抖。9 月 23 日 08:30 的连续事件仅证明反复检查，日志未显示这段发生重建，不能称为已证实的重建风暴。
- **连接显示混用用户意图**：`DaemonClient.swift:96` 的 isVPNOn 读取 desired intent；`Views/MainView.swift:500` 将其当作 isConnected，并在第 1472 行显示“已建立隧道”。状态获取失败清空 status，却保留 intent；菜单栏又读取真实 state。因此“daemon 未连接”和“已建立隧道”可以同时出现。
- **请求超时短于连接操作**：`DaemonControlAPIClient.swift:30` 默认 5 秒；resume 同步等待后台连接。9 月 23 日 07:19:05 至 07:19:51 的 46 秒间隔最后返回 endpoint DNS 错误，期间连接锁一直被占用。这段证明长操作，并不证明死锁。
- **endpoint DNS 缺少总预算**：`tunnel_darwin.go:618` 首次 net.LookupHost 没有调用方 deadline，之后串行尝试四个各 4 秒 bootstrap DNS；退出清理也可能等待持锁连接操作结束。
- **健康判断证据不足**：`healthcheck.go:34` 仅一个普通 HTTP HEAD，未绑定隧道，未结合握手/RX，也没有备用目标；目标站点或 DNS 故障可能误触发重建，其他出网路径可用也可能掩盖隧道故障。
- **状态读取竞争**：`policy.go:353` 的快照读取不参与操作锁；Darwin RuntimeStats 检查 m.dev 后再次读取，与 cleanup 置 nil 并发。现有测试没有并发查询状态的场景。本轮 race 通过不能排除这一未覆盖路径。
- **DNS 恢复错误处理**：restoreStaleDNS 失败仍继续连接，随后可覆盖旧快照；applyProfileDNS 失败只记日志仍返回连接成功。该机制需要专门失败注入测试，并保留用户要求的连接期间静态隧道 DNS 约束。

## 本轮改动和验证

- `core/internal/tunnel/rebind_darwin.go`：失败后按退避定时重试；detach 等待在途操作；纠正“Darwin peer 源地址缓存”注释。当前依赖 `sticky_default.go` 在 Darwin 明确无该缓存实现。日志只声明 socket 已重建，保留数据面验收边界。
- `core/internal/tunnel/tunnel_darwin.go` 与 `core/cmd/wgsense-daemon/main.go`：统一信号清理所有权。
- `core/internal/tunnel/rebind_darwin_test.go`：两项先红后绿的回归测试。
- `core/internal/tunnel/rebind_device_darwin_test.go`：真实 UDP bind 失败注入与恢复载荷测试。
- 通过：`go test -race ./internal/tunnel -count=1`、`go test ./... -count=1`、`go build ./...`、`git diff --check`。
- 所有测试只使用 mock、内存 TUN 或本机临时 UDP；没有创建系统 TUN 或改路由/DNS。未做 macOS App 构建、安装或发布。

## 后续修复与验收

先把网络恢复纳入同一策略状态机：明确 offline、connecting、recovering、connected；HTTP 失败结合物理路径、握手和 RX 判断；网络变化先等待稳定并保留连接宽限，避免单个站点失败直接拆隧道。界面分别显示开启意图和实际连接状态。DNS 保存/恢复应可重试且不覆盖尚未恢复的快照；连接、取消和退出使用统一总时间预算。

授权实际切换后，至少验证一个受信网段、一个非受信网段、以太网与 Wi-Fi 同时存在时的优先级，再覆盖断网恢复与睡眠唤醒。每次同时采集有效物理接口/IP、系统 DNS/路由、daemon 状态、隧道状态、最新握手与 peer RX/TX，以及浏览器请求结果。恢复时要求同一数据通路重新收到数据；结束时要求 DNS 恢复为进入前的设置，快照和自建路由正确清理。单纯 App 可打开、设备对象存在、IPC 返回、socket 重开或显示 Connected 均不算通过。

本轮修复仍不能让物理离线网络恢复。日志 9 月 22 日 04:31 后同时缺物理网关和 LocalSend 物理接口，不能把这几小时都归为 WgSense 的单一故障。初始 EADDRNOTAVAIL 和 EADDRINUSE 的触发原因仍需在下一次现场同时记录接口、路由和 socket 占用。
