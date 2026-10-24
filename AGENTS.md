# AGENTS.md

原生 macOS 桌宠：Swift/AppKit 应用（`native/`），DSH 插件在 submodule `bridge/`。

## 界面用 SwiftUI

新增或修改的用户界面用 SwiftUI 写，尺寸、内边距、背景交给 SwiftUI 的固有布局，布局代码里不写死宽高。
参考 [PetView.swift](native/Sources/DSHNativePet/PetView.swift) 里的 `PetBubbleView` 与 `PetBubbleHostingView`。

AppKit 负责 SwiftUI 表达不了的部分：`NSPanel` 与窗口行为、屏幕坐标、`CALayer` 与 Core Animation、菜单栏、IPC。
SwiftUI 嵌进 AppKit 用 `NSHostingView`；需要点击穿透到下层 AppKit 视图时，让宿主视图的 `hitTest` 返回 `nil`。

## 分层

`PetCore` 只依赖 Foundation，不放排版与文案拼接；状态到界面文字的排版留在应用层。

## 验证

SwiftPM 在本机需要 `--disable-sandbox`：

```sh
swift test --package-path native --disable-sandbox
```

其余检查入口见 [开发指南](docs/development.md)。

## 变更纪律

- 行为变化同步更新 `docs/`：架构在 [architecture](docs/architecture.md)，宿主接入在 [host-hooks](docs/host-hooks.md)。
- `bridge/` 是 [hotheat/dsh-native-pet-plugin](https://github.com/hotheat/dsh-native-pet-plugin) 的 submodule，插件改动在插件仓库提交，本仓库只更新 submodule 指针。
- 经 PR 合入 `main`，分支用 `feat/`、`fix/`、`refactor/` 前缀。
