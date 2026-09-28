# 滚动帧率测试

- `swipe.swift`：模拟触控板手势（began/changed/ended，每 1.4s 反向）。**不要用无阶段的旧式滚轮事件测**：换向时会产生真实触控板不存在的 100ms+ 假尖峰。
- 启动参数 `-WgSenseFrameProbe <秒>`：第 3 秒起用 CADisplayLink 记录主线程帧间隔，结果写入 `/tmp/wgsense-frames.txt`（p50/p95/p99/掉帧率/>40ms 尖峰时刻）。
- `frames_swipe.sh`：一键启动 → 滚动 → 输出结果（脚本里的路径按本机调整）。

2026-09-27 基线（120Hz 屏，代理页全部展开）：原版掉帧 65%、中位 21ms；NSTableView 方案掉帧约 12%、中位 8.3ms；设置页（普通 SwiftUI ScrollView）31%。
