# WgSense 品牌图标

2026-10-04 确认采用“双侧贯穿”：骨白斜面贯穿黑色圆角底板左右边缘，保留上下尖端、中央黑色切口和右上朱红短线。无渐变、光泽、阴影或额外装饰。展示图外围的浅色画布不属于图标；正式资源外围透明。

浅色界面使用浅底黑色交错斜面，深色界面使用黑底骨白斜面；朱红短线在两种外观中保持同色。形状、位置和裁切完全相同。

`GenerateAppIcon.swift` 是唯一几何母版，按确认图的轮廓坐标重建。两个 SVG、AppIcon 目录内的 10 个 PNG、BrandIcon.imageset 的浅/深两张图和外观配置都由它生成，不单独手改某个尺寸。

```sh
xcrun swift branding/GenerateAppIcon.swift
xcrun swift branding/GenerateAppIcon.swift --check
```

检查覆盖全部 10 个 macOS 槽位、16–1024 像素尺寸、透明通道、相对于母版的像素一致性、孤立 PNG 和 SVG 一致性。像素比较容许不同 macOS 版本的轻微边缘抗锯齿差异；CI 和发布流程均执行检查。

主窗底部与关于页均使用 `WgBrandIcon`，通过 BrandIcon.imageset 跟随所在 SwiftUI 视图的明暗外观。不要用固定的 `NSApp.applicationIconImage` 代替应用内的双主题品牌资源。关于页也不再额外添加阴影。

`tests/branding/check-appearance.sh` 从构建后的真实 bundle 加载资源，使用生产组件原生渲染两种外观 × 六个尺寸，并检查黑白互换、红线不变和透明圆角。CI 和发布流程在构建后执行该回归，防止浅色界面再次误用深色图标。

Dock、Finder 和通知仍使用原有深色平面 AppIcon。传统 mac AppIcon 的 luminosity 条目在本机 actool 实测被丢弃；原生 .icon 虽可编译两种外观，但在 macOS 26 渲染中附带明显边缘高光，与确认的平面设计不符，因此未采用。系统图标的实时明暗适配不作为本次已完成项。安装盘直接复制 bundle，无独立图标副本。

菜单栏、Widget 和 VPN 模块的盾牌表示连接/守护状态，属于功能符号，不是品牌图标。

发布前仍应查看构建后的 `AppIcon.icns` 在真实 macOS 表面的小尺寸效果。图标验证不需要启动 WgSense、访问守护服务或改变当前 VPN。
