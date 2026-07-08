# WireGuard 跨平台客户端 · 项目规划

> 状态：方向已定，技术栈已确认（UI 全原生 + Go 核心跨平台），待确认项目名
> 更新：2026-07-06

## 一、愿景

自研一个跨平台 WireGuard 客户端，解决官方客户端缺失的**智能管理能力**——位置感知自动开关、假连接检测、睡眠唤醒恢复、暂停恢复绑定开机周期。

开源核心 + 高级功能收费，上架 App Store。参考 defguard 架构思路，但代码全自研。

## 二、商业模式

| 层级 | 功能 | 定价 |
|---|---|---|
| 免费版（开源） | WG 连接管理、多 profile、配置导入、手动开关、基本状态、连接统计 | 免费 |
| 付费版（闭源模块） | 智能守护（位置感知/自动开关/假连接检测/暂停恢复）、配置云同步、高级路由分流、按应用代理 | 订阅或买断（待定） |

**许可证**：核心 Apache 2.0（GitHub 开源，商业友好，允许闭源衍生）+ 高级功能作为独立闭源模块或 license 解锁。

**上架**：macOS App Store + iOS App Store（需 Apple Developer 账号 $99/年 + NetworkExtension entitlement）。

## 三、技术架构

### 核心原则：UI 全原生，核心逻辑跨平台复用

这是 WireGuard 官方客户端、Tailscale 等成熟产品的架构——**不要每平台重写 WG 协议和智能逻辑**。wireguard-go 是官方 Go 实现，直接复用；智能管理层用 Go 写一次，编译成各平台库嵌入原生 app。

### 分层

```
┌──────────────────────────────────────────────┐
│  UI 层（全原生，各平台最佳体验）              │
│  macOS/iOS: SwiftUI + NetworkExtension       │
│  Windows:   WinUI 3 + WinTun                 │
│  Linux:     GTK/Qt + TUN                     │
│  Android:   Jetpack Compose + VpnService     │
├──────────────────────────────────────────────┤
│  智能核心层（Go，跨平台复用 ~90%）            │
│  位置感知 · 自动开关 · 假连接检测             │
│  暂停恢复 · 路由分流 · 配置同步客户端         │
├──────────────────────────────────────────────┤
│  隧道层（wireguard-go，MIT，官方实现）        │
├──────────────────────────────────────────────┤
│  平台绑定（gomobile 编译 Go 核心为平台库）    │
│  macOS/iOS: .framework   Windows: .dll       │
│  Linux: .so              Android: .aar       │
└──────────────────────────────────────────────┘
```

### 进程模型

- **桌面**（macOS/Windows/Linux）：Go 核心 wireguard-go 作为后台 tunnel service/daemon + 原生 UI，本地 IPC 通信
- **移动**（iOS/Android）：Go 核心 gomobile 编译进 app，原生 UI 通过 FFI 调用，单进程

### 关键技术选型理由

| 选型 | 理由 |
|---|---|
| wireguard-go | 官方 Go 实现，MIT 许可，跨平台，不必重写 WG 协议（重写有安全风险） |
| Go 核心层 | 跟 wireguard-go 同生态；智能层逻辑跨平台复用，避免 5 次重写导致行为不一致 |
| 全原生 UI | 各平台最佳体验；SwiftUI/WinUI/Compose 是各自平台首选，App Store 友好 |
| gomobile 绑定 | Go → 平台库的成熟方案，WireGuard 官方客户端就是这么做的 |
| Apache 2.0 | 商业友好，允许闭源衍生，App Store 友好（非 GPL） |

### 为什么不全平台纯原生重写

1. **WG 协议重写有安全风险**：WireGuard 的安全性强依赖实现严谨性，每平台用 Swift/C#/Kotlin 重写 WG 协议会引入漏洞。连 WireGuard 官方客户端都用 wireguard-go + 原生 UI，没有纯全原生。
2. **智能逻辑一致性**：位置感知/假连接检测等逻辑若每平台重写，行为可能不一致，bug 难修。
3. **工程量**：纯全原生 = 5 倍核心逻辑工作，无收益。

### 风险与缓解

| 风险 | 缓解 |
|---|---|
| Go 核心 + 原生 UI FFI 复杂 | 参考 WireGuard 官方客户端 gomobile 绑定实践 |
| 每平台 UI 独立开发工作量大 | UI 层各平台独立，但核心逻辑共享；优先 macOS 验证架构再扩展 |
| Mac App Store 沙盒 + NetworkExtension | 需申请 entitlement，SwiftUI 配合沙盒 |
| gomobile 移动端限制 | 核心层设计为纯 Go 无平台依赖 |

## 四、MVP 路线图（全职投入，每周 40h+）

| 阶段 | 周期 | 目标 | 里程碑 |
|---|---|---|---|
| **0 · 选型与骨架** | 1 周 | 项目骨架、Go 核心模块、macOS Xcode 项目、GitHub 仓库 + CI | 仓库跑起来 |
| **1 · macOS 基础版** | 3-4 周 | wireguard-go 集成 + SwiftUI UI + 手动连接/断开/多 profile（免费功能） | macOS 能连 WG |
| **2 · 智能管理层** | 3-4 周 | 位置感知/自动开关/假连接检测/暂停恢复（付费功能），移植并超越 bash 守护 | **bash 守护退役** |
| **3 · 桌面扩展** | 5-6 周 | Windows（WinUI 3 + WinTun）+ Linux（GTK + TUN）适配 + 配置同步后端 | 三平台统一 |
| **4 · 移动端** | 5-6 周 | iOS（SwiftUI + NE）+ Android（Compose + VpnService），gomobile 绑定 | 全平台覆盖 |
| **5 · 产品化** | 持续 | 高级路由分流、App Store 上架、商业化落地、安全审计 | 正式发布 |

**全职下阶段 0-2 约 2 个月**，完成后 bash 守护退役，macOS 智能管理上线。

### 阶段 1 验收标准（macOS 基础版）

- [ ] 能导入标准 WireGuard .conf 配置
- [ ] 能建立/断开 WG 隧道（通过 wireguard-go + NetworkExtension）
- [ ] 多 profile 管理
- [ ] 基本连接状态显示
- [ ] SwiftUI UI 可用
- [ ] Go 核心 daemon 后台常驻 + launchd 注册

### 阶段 2 验收标准（智能管理层）

- [ ] 位置感知：检测家网段，在家自动断开
- [ ] 自动开关：不在家网段自动连上
- [ ] 假连接检测：Connected 状态下探测连通性，失效则强制 stop/start
- [ ] 暂停恢复：绑定设备启动周期，重启后自动恢复
- [ ] 现有 bash 守护可退役

## 五、待确认决策

1. **项目名**：影响仓库名、App Store 应用名、品牌
2. **商业模式**：订阅 vs 买断？定价区间？
3. **Apple Developer 账号**：是否已有？上架必需
4. **仓库位置**：GitHub 个人账号还是新建组织？

## 六、参考资源（仅学习，不套用代码）

- **WireGuard 官方客户端**：gomobile + 原生 UI 架构的最佳参考（macOS/iOS/Windows/Android 各平台实现）
- **defguard client**：跨平台架构思路、UI 设计参考（AGPLv3，不套用代码）
- **wireguard-go**：隧道层直接使用（MIT，可用）
- **Tailscale 客户端**：daemon + UI 架构参考
- **现有 bash 守护**（`~/.local/share/wireguard-lan-switch/`）：智能层逻辑原型，阶段 2 移植基础

---

*本文档随项目推进持续更新。确认项目名后进入阶段 0。*
