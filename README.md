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

**v0.3.0-beta** — macOS 一体化测试版：

- [x] Go 核心模块(config / location / tunnel / healthcheck / pause / policy)
- [x] wireguard-go 集成 — 真实隧道测试通过
- [x] macOS SwiftUI app — Surge 风格 sidebar + 菜单栏图标 + 磁贴仪表盘
- [x] daemon HTTP API — `127.0.0.1:8765`
- [x] Mihomo (Clash Meta) 代理面板 — 策略/域名/节点/订阅四页签
- [x] 局域网传输模块 (LocalSend 协议兼容, 端口 53318)
- [x] Profile CRUD — 导入/导出/编辑/切换，支持 daemon 离线操作
- [x] 流量监控 — netstat 自动选活跃接口
- [x] GitHub Actions CI
- [x] 路由修复 — 握手门控 + endpoint 排除 + DNS 不动系统配置
- [ ] NetworkExtension target(等 Apple Developer 账号)
- [ ] Windows / Linux / iOS / Android 平台

> 当前没有 Apple Developer 签名与公证。系统 helper 只会在用户从 App
> 维护面板明确安装时请求管理员授权；NetworkExtension 尚未实现。

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
