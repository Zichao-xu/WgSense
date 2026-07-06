# WgSense

跨平台 WireGuard 客户端，带智能管理能力——位置感知自动开关、假连接检测、睡眠唤醒恢复。

## 为什么

官方 WireGuard 客户端缺少智能管理：
- 出门后隧道进入“假 Connected”状态，流量黑洞，必须手动停启
- 不会基于网络位置自动开关
- 睡眠唤醒后不主动重建数据通道

WgSense 解决这些。

## 架构

```
UI 层(全原生)       macOS SwiftUI · Windows WinUI · Linux GTK · iOS/Android
核心层(Go,跨平台)   wireguard-go 隧道 + 智能管理引擎
平台绑定             gomobile → .framework / .dll / .so / .aar
```

**原则**：UI 全原生，核心逻辑 Go 跨平台复用。不重写 WG 协议(安全风险)，智能逻辑跨平台一致。这是 WireGuard 官方客户端、Tailscale 的架构。

## 状态

阶段 0(骨架)已完成：
- [x] Go 核心模块骨架(config/location/tunnel/healthcheck/pause/policy)
- [x] macOS SwiftUI app 骨架(XcodeGen + xcodebuild 通过)
- [x] GitHub Actions CI
- [ ] gomobile 绑定(阶段 1)
- [ ] wireguard-go 集成(阶段 1)
- [ ] NetworkExtension target(阶段 1)

全职下阶段 0-2 约 2 个月，完成后 bash 守护退役，macOS 智能管理上线。

## 开发

```bash
# Go 核心
cd core && go build ./...

# macOS app
cd platforms/macos
xcodegen generate
open WgSense.xcodeproj
```

## 商业模式

- **免费版(开源)**：WG 连接管理、多 profile、手动开关、基本状态
- **付费版**：智能守护(位置感知/自动开关/假连接检测/暂停恢复)、配置云同步、高级路由分流

## 许可证

Apache 2.0。核心开源。高级功能为付费模块。
