# 产品图片来源

这里的 HUD 图片和动图直接使用应用内的 `WgLinkStage`，通过 SwiftUI 的离线渲染器生成，数据来自 `tests/hud/render.swift` 的固定合成样本。它们不是在线网络测速或帧率实测，也不是另画的产品界面。

| 文件 | 内容 |
| --- | --- |
| `hud-dark.png` | 正常连接态，深色，1552 × 680 |
| `hud-light.png` | 相同合成数据，浅色，1552 × 680 |
| `hud-motion.gif` | 10 秒交互与事件演示，960 × 470，20 fps，供 README 浏览 |
| `hud-motion.mp4` | 同一演示的清晰版本，1552 × 760，120 fps 编码 |
| `brand-appearance.png` | 编译后资产目录中的品牌图标，经实际 `WgBrandIcon` 分别按浅色、深色渲染，1440 × 640 |

动图顶部持续标明“离线演示 · 合成数据”，依次演示入场、接收聚焦、发送聚焦、轨迹采样、频繁自愈和恢复。静图在引用时同样需要标明合成数据。MP4 的 120 fps 是离线输出规格，不能据此承诺应用在所有设备上都达到 120 fps。

这些脚本不启动 WgSense，不构建 `DaemonClient`，不读取个人配置，也不连接后台服务。仅品牌图读取指定应用包内的编译后图片资源；图片内容不包含网络地址、私钥、设备名称或个人文件路径。

## 重新生成

在装有 Xcode、Python 3 和 FFmpeg 的 Mac 上，用已构建的应用包运行：

```sh
bash docs/images/build-media.sh "/absolute/path/WgSense.app" "/absolute/scratch-directory"
```

所有原生 HUD 帧生成到指定临时目录，仅这五个发布素材写回本目录。`build-media.sh` 最后会执行全量检查；也可以单独运行：

```sh
python3 docs/images/check-media.py
```

完整检查覆盖全部五份素材的结构、尺寸、动图时长、编码帧率和 GIF 体积，并对照 `source-hashes.json` 检查视图、图标资产和生成脚本是否已改变；有改变时需重新生成。`media-hashes.json` 记录五份素材各自的 SHA-256，检查能发现媒体内容的意外更改。

CI 和发布检查不需要安装 FFmpeg，使用：

```sh
python3 docs/images/check-media.py --static
```

此模式检查全部素材的结构和尺寸、GIF 体积、来源新鲜度及五份素材的完整 SHA-256，确认它们与上次完整验证的文件逐字节一致；不重复解析动画时长或帧率。`build-media.sh` 使用的 `--record-sources` 只有在包括 FFprobe 在内的完整检查通过后，才更新两份清单，不能与 `--static` 混用。

仍需人工查看所有演示阶段，确认文字、布局与合成数据标识正常。
