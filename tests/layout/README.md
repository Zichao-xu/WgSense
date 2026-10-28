# 实时排版独立原型

独立的 macOS SwiftUI/AppKit 测试窗口。稳定网格与正式界面共用 `Views/RetainedGrid.swift`，同时覆盖固定磁贴高度的快速路径。**不连接 WgSense 守护进程、网络或业务账号，不修改正式界面。**

比较三条路径：

1. 原有行容器：VStack/HStack，每行重新分组。
2. 保留视图身份：单一 Layout，缓存行分组，在测量与摆放之间复用同一次精确测量。
3. 可视区挂载：整页几何保持准确；固定高度磁贴直接计算尺寸，变高段落仍按当前宽度真实测量；只挂载视口附近的宿主。宿主保留，滚回时保持状态。换列平移采用独立 Core Animation 动画，文字本身不缩放。

```sh
bash tests/layout/check.sh /absolute/output/directory
```

构建后通过 Finder 打开 WgLayoutLab.app。点击“运行三种布局对照”会顺序运行常规页/长页 × 三种实现。模拟读数以 10Hz 更新。结果保存在 App 同目录的 benchmark.json。

`LAYOUT_LAB_AUTOSTART=1 bash tests/layout/build.sh ...` 可启用启动 10 秒后自动采样。默认关闭。

验证覆盖：176–620 点、0.5 点步进的几何扫描；真实系统文字的临界宽度、反向、重复宽度、字体与文案变化；所有磁贴滚入视口后的可达性和宿主身份；4 组原始/稳定布局原生 PNG 字节一致性。

边界：这是代表性夹具，不是原测速页。原生挂载路径的动画曲线与 SwiftUI smooth 不宣称完全一致。离屏 PNG 对照只覆盖前两种实现；原生路径另有尺寸/可达性验证和实窗检查。

宽度更新 CPU 计时不包括所有延迟任务和合成器显示；CADisplayLink 到达间隔也不是实际显示帧率。必须结合系统帧证据，才能声称达到 120fps。几何或 PNG 测试通过不等于性能通过。
