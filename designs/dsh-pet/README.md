# DSH Pet 原始动画素材

来源为 [PC2005-cloud/dsh-pet](https://github.com/PC2005-cloud/dsh-pet)，配置与许可按 commit `48007b64ac0bebb2e97ac88344aed62de8399dd4` 核对。
2026-10-23 从 `assets-mov` release 选择九段 macOS HEVC-alpha MOV，原始字节保存在 `native/Sources/DSHNativePet/Resources/DSHPet/`。
完整 MIT 许可随资源目录保留。

| 原生状态 | 上游动作 |
| --- | --- |
| idle | 待机呼吸休闲 |
| thinking | 工作状态-思考冒泡 |
| working | 工作状态-忙碌点按 |
| waiting | 工作状态-原地踱步张望 |
| completed | 工作状态-雀跃庆祝 |
| error | 工作状态-垂头叹气冒汗 |
| poke | 点击回应-元气挥手 |
| drag | 被鼠标拖拽悬空反馈 |
| sleeping | 原地小憩沉眠 |

MOV 只改为状态名文件名，没有转码或改动字节。
PNG 由 AVFoundation 解码各段第一帧，保留原始 640 × 360 画布和透明度。
每个状态的 PNG 是播放前的首帧，动画内容由对应 MOV 提供。

`audit-assets.swift` 扫描所有解码帧，以 alpha > 200 计算每段动画包络，再合并为九状态共用的 `visibleBounds`。
共用包络是 `(161, 7, 301, 324)`，共用锚点是待机首帧底部 10% 脚区的中心 `(0.4921875, 0.9138888889)`。
待机首帧人物可见高度是 265px，占共用包络高度的 81.79%。
manifest 的 `referenceHeight: 265` 使用这一人物高度作为尺寸基准，因此人物 100pt 时缩放比例为 `100 / 265`，完整动作包络高度约为 122.26pt。
原生渲染根据共用包络扩展窗口边界，以容纳动作与特效。
共用尺度和脚底基准在动画期间保持固定，特效和动作伸展不触发逐帧缩放。
各状态独立的首帧和动画包络保存在 `animation-audit.json`。

`poster-contact-sheet.png` 将九张首帧合成到棋盘背景，用于检查真实透明合成效果。
九段共解码 2046 帧，每段均有全透明与全不透明像素，抽样像素哈希随时间变化。
全部首帧已逐张目视核对。

`assets-mov` 是可更新的固定 tag，因此 `sources.json` 同时记录下载日期、官方 API 声明的完整 ZIP digest、选中条目的 CRC32、文件字节数和本地 SHA-256。
这次通过 HTTP Range 读取九个条目并核对 ZIP CRC32，没有完成整个 ZIP 的本地哈希核验。
`sourceCommit` 标识配置与许可的核对版本，release 素材由独立的 asset ID 和 digest 标识。

在仓库根目录重新提帧与审计：

```sh
swift designs/dsh-pet/audit-assets.swift
```
