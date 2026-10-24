# 角色素材

## 小女孩

用户提供的 `hanzi-evolution-atlas/designs/ip-assets/two-head-q-girl` 是身份与服装参考。
项目保存参考副本、Codex imagegen 提示词与来源哈希，见 [素材说明](../designs/two-head-q-girl/README.md)。
运行时从 [Character](../native/Sources/DSHNativePet/Resources/Character/) 读取九个透明 PNG，配合 CALayer 变换实现轻动画。

## DSH Pet

原始透明 MOV 来自 [PC2005-cloud/dsh-pet](https://github.com/PC2005-cloud/dsh-pet) 的 macOS 素材发布附件。
应用选取九个对应状态的动作，使用 AVFoundation 原生解码和播放。
PNG 是从对应视频解码的首帧，用于即时显示和关闭动画状态。
上游 MOV 字节保持不变，完整 MIT 许可证随 [DSHPet](../native/Sources/DSHNativePet/Resources/DSHPet/) 资源打包。
素材映射、下载来源、CRC、逐文件 SHA-256 和审计方法见 [来源说明](../designs/dsh-pet/README.md)。

## 布局和校验

`visibleBounds` 描述真实 alpha 可见区域，归一化 anchor 表示脚底位置。
DSH Pet 使用所有动画的共同包络，`referenceHeight` 使用 idle 人物高度，确保人物默认 100 pt 且动作不因特效范围变化而缩放。
窗口按包络预留空间，切换保持屏幕脚底位置。

```sh
swift scripts/validate-assets.swift
swift scripts/validate-dsh-pet.swift
```

第一项校验小女孩的尺寸、透明度与像素包络。
第二项校验九段 MOV 可播放、透明像素、真实运动，以及首帧 PNG 与视频尺寸一致。
原始编码的透明区域可能保留颜色，目视应使用实际 alpha 合成结果。
