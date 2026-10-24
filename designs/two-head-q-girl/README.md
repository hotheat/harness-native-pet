# 角色素材

本目录保存桌宠角色的参考图、生成提示词和来源哈希。
原角色来自用户提供的 `hanzi-evolution-atlas/designs/ip-assets/two-head-q-girl`。
原始文件未修改。

## Runtime Assets

运行时资源位于 `native/Sources/DSHNativePet/Resources/Character/`。
九个姿态分别是 `idle`、`thinking`、`working`、`waiting`、`completed`、`error`、`sleeping`、`poke`、`drag`。
每个姿态都是单独生成或编辑的透明 PNG，没有复用其他状态的图片。
这些图片用于姿态切换，持续动作由原生渲染器完成。

| 姿态 | 输入与处理 |
| --- | --- |
| idle | 全身正面图，编辑为透明背景 |
| thinking | 思考表情，透明背景并去掉悬浮灯泡 |
| working | 全身与三视图作为身份参考，生成专注双手姿态 |
| waiting | 惊讶表情，保留双手贴脸 |
| completed | 点赞表情，保留单手点赞 |
| error | 委屈表情，保留轻微受挫反馈 |
| sleeping | 困倦表情作为身份参考，生成闭眼平稳站立姿态 |
| poke | 开心挥手表情，保留挥手 |
| drag | 全身与三视图作为身份参考，生成轻微失衡的拖动反应 |

## Manifest

`manifest.json` 中的 `canvas` 是 1024×1024 的逻辑制作画布。
实际 PNG 均为 1254×1254，渲染时必须使用每个姿态的实际 `width`、`height`。
`visibleBounds` 是 alpha 大于 200 的可见区域像素矩形，格式为 `{x,y,width,height}`。
像素坐标原点位于左上角。
`anchor` 使用归一化的左上坐标，纵坐标取脚底最后一个实心像素的下一行，横坐标取下部脚区域的中心。
渲染器按可见区域高度统一角色大小，并用脚底锚点对齐普通状态。
拖动姿态包含主动倾斜。

## Provenance

`prompts.json` 记录每次内置 Codex image_gen 调用的完整提示词、输入和输出位置。
`sources.json` 记录保存在 `references/` 的原始输入与运行时 PNG 的 SHA-256。
生成时启用 `transparent_background: true`，每次调用只生成一个独立姿态。
生成结果均复制出工具缓存，项目构建只读取仓库中的运行时图片。
所有九张图片都已经用 `view_image` 独立检查完整全身、发型与服装锚点。
所有九张图片都经过 ImageIO 解码和透明像素检查。
最终桌面浅色、深色壁纸与小尺寸显示质量由应用验收截图确认。

`audit-assets.swift` 读取现有图片并更新尺寸、可见区域、脚底锚点与哈希，不修改图片。
在仓库根目录运行：

```sh
swift designs/two-head-q-girl/audit-assets.swift
```
