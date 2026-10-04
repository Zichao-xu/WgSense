# WgSense

跨平台网络工具套件，以 WireGuard 为首个模块——带智能管理能力：位置感知自动开关、假连接检测、睡眠唤醒恢复、Mihomo 代理面板。

## 为什么

官方 WireGuard 客户端缺少智能管理：
- 出门后隧道进入"假 Connected"状态，流量黑洞，必须手动停启
- 不会基于网络位置自动开关
- 睡眠唤醒后不主动重建数据通道
- 缺少统一的多协议代理管理界面

WgSense 解决这些，并演进为**网络工具套件平台**（WireGuard + 局域网传输 + 代理管理等）。

## 架构

```
UI 层(全原生)       macOS SwiftUI · Windows WinUI · Linux GTK · iOS/Android
核心层(Go,跨平台)   wireguard-go 隧道 + 智能管理引擎
平台绑定             gomobile → .framework / .dll / .so / .aar
```

**原则**：UI 全原生，核心逻辑 Go 跨平台复用。不重写 WG 协议(安全风险)，智能逻辑跨平台一致。这是 WireGuard 官方客户端、Tailscale 的架构。

## 状态

**v1.0.1** — 交互式链路 HUD、原生代理面板与界面性能更新：

- [x] 链路舞台 — 指针感应、收发聚焦、真实流量轨迹与自愈记录
- [x] 非线性事件动画 — 按显示器刷新率更新，空闲暂停，支持减少动态效果
- [x] HUD 回归 — 95 项模型/运动检查与极限遮挡像素检查

本次更新及验证边界见 [v1.0.1 发布说明](docs/releases/v1.0.1.md)。120Hz 是活动动画目标，尚不保证所有交互稳定 120fps。

已有能力：

- [x] Go 核心模块(config / location / tunnel / healthcheck / pause / policy)
- [x] wireguard-go 集成 — 真实隧道测试通过
- [x] macOS SwiftUI app — Surge 风格 sidebar + 菜单栏图标 + 磁贴仪表盘
- [x] daemon HTTP API — `127.0.0.1:8765`
- [x] Mihomo (Clash Meta) 代理面板 — 策略/域名/节点/订阅四页签
- [x] 局域网传输模块 (LocalSend 协议兼容, 端口 53318)
- [x] Profile CRUD — 导入/导出/编辑/切换，支持 daemon 离线操作
- [x] 流量监控 — netstat 自动选活跃接口
- [x] GitHub Actions CI
- [x] 路由修复 — 握手门控 + endpoint 排除 + 连接期接管 DNS、断开恢复
- [x] daemon 守护策略 — 回到受信任网络自动断开，网络切换后立即处理假连接
- [x] 多网卡判断 — 有线/Apple USB LAN 优先，任一有效物理网卡命中信任网段即断开 VPN
- [x] VPN 磁贴交互 — 执行动作后系统通知 + 全局 Liquid Glass 播报 + 紫色守护重启按钮
- [x] 连接自愈 — 发包地址失效(网络切换/睡眠唤醒)时重建 UDP bind，路由与 DNS 保持不动
- [x] 日志治理 — wireguard-go 调试日志默认关闭，重复错误折叠计数
- [x] 背景板三档 — Liquid Glass 标准/通透 + 传统毛玻璃，整窗一块，透出桌面
- [x] 实体层统一 — 磁贴/卡片/面板实色 + 描边，三级明度同源推导，不再各表面独立取值
- [x] 外观参数 44 → 5 — 背景模式/浓度 + 内容底色/描边/状态色，全部实时生效
- [x] 磁贴布局持久化 — 排序、增删、改大小重启后保留，解码逐条容错
- [ ] Windows / Linux / iOS / Android 平台

> 系统要求 macOS 26 或更新：背景板用的 `NSGlassEffectView` 自 macOS 26 起提供。
>
> 当前没有 Apple Developer 签名与公证。个人使用候选版会在 App 首次运行时请求一次
> 管理员授权安装常驻系统服务；之后启动 App、开关 VPN 与服务自动恢复使用已安装服务。
> 当前 macOS 发布版走 daemon 管理路径，不注册系统 VPN。

## 项目结构

```
wgsense/
├── core/                          # Go 核心层（跨平台 ~90% 复用）
│   ├── cmd/wgsense-daemon/        # daemon 主入口
│   ├── internal/
│   │   ├── tunnel/                # WireGuard 隧道 (wireguard-go)
│   │   ├── proxy/                 # Mihomo 代理 API 对接
│   │   ├── transfer/              # 局域网传输 (LocalSend 协议)
│   │   ├── logbuf/                # 日志环形缓冲区
│   │   ├── policy/                # 智能策略引擎
│   │   └── config/                # 配置管理
│   └── api/                       # daemon HTTP API (:8765)
├── platforms/macos/               # macOS 原生 UI (SwiftUI)
│   └── WgSense/
│       ├── DaemonClient.swift     # daemon API 客户端
│       ├── Views/
│       │   ├── MainView.swift     # 仪表盘 + 磁贴系统
│       │   ├── ProxyView.swift    # Mihomo 代理面板
│       │   ├── OverviewView.swift # WG 连接概览
│       │   ├── ProfileManagerView.swift  # Profile 管理
│       │   └── OtherViews.swift   # 设置/日志/关于
│       └── WgSenseApp.swift       # App 入口
└── .github/workflows/             # CI
```

## 开发

```bash
# Go 核心
cd core && go build ./...

# macOS app
cd platforms/macos
xcodegen generate
open WgSense.xcodeproj
```

## 安装

从 [Releases](../../releases) 下载 `WgSense-macOS.dmg`，打开后将
`WgSense.app` 拖入 `Applications`。DMG 已内置 daemon 和维护脚本，不需要
单独下载后台组件。未经公证的首次启动可能需要在“系统设置 → 隐私与安全性”中确认打开。

v1.0.0 实现首次授权安装常驻服务、后续免密码控制、版本核验、升级与失败回滚。
构建及隔离测试已通过；真实管理员弹窗次数、Mac 冷重启、VPN 握手与网络切换尚未验收。
已知验收边界见 [v1.0.0 验证记录](docs/release-validation-v1.0.0.md)。

自行编译：

```bash
cd platforms/macos
xcodegen generate
xcodebuild -project WgSense.xcodeproj -scheme WgSense -configuration Release build
```

## 隐私与默认配置

- 仓库和发布包不包含 WireGuard 私钥、Mihomo 密钥、个人路径或个人网络地址。
- Mihomo 控制器默认连接 `127.0.0.1:9090`，远程控制器由用户自行配置。
- 受信任网络列表默认留空，自动连接策略默认关闭。

## 商业模式

- **免费版(开源)**：WG 连接管理、多 profile、手动开关、基本状态
- **付费版**：智能守护(位置感知/自动开关/假连接检测/暂停恢复)、配置云同步、高级路由分流

## 许可证

Apache 2.0。核心开源。高级功能为付费模块。
