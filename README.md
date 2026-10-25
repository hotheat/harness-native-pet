# DSH Native Pet

Native macOS desktop pet for DeepSeek Harness, built with Swift and AppKit.

原生菜单栏桌宠，通过 DSH 插件及 Codex、Claude Code hooks 显示思考、工具执行、等待处理和回应结束状态。
任务提醒同时支持桌宠文字与 macOS 系统通知。
内置双丸子头小女孩与 [DSH Pet](https://github.com/PC2005-cloud/dsh-pet) 两套角色，支持拖动、点击互动、大小、动画和点击穿透设置。
默认人物可见高度为 100 pt。

## 本地运行

本机验收平台为 Apple Silicon / macOS 15，构建需要 Xcode 命令行工具、Swift 6 和 Node.js 22 或更高版本。
DSH 插件源码位于 [hotheat/dsh-native-pet-plugin](https://github.com/hotheat/dsh-native-pet-plugin)，本仓库以 submodule 跟踪同一份实现，宿主依赖以其 [package.json](bridge/package.json) 为准。

```sh
git submodule update --init
npm --prefix bridge ci
bash scripts/package-app.sh
open "dist/DSH Native Pet.app"
```

应用可独立启动，未接入插件时显示连接状态。
点击菜单栏爪印图标，在「角色」中选择「小女孩」或「DSH Pet」即可立即切换。
「设置与会话状态」中也可选择角色，选择会保存并在下次启动恢复。
切换保留当前任务和脚底位置，窗口按角色动作范围调整，默认人物高度保持 100 pt。
DSH Pet 使用 AVFoundation 播放原始透明 MOV；关闭动画后显示静态首帧。
菜单还可显示或隐藏桌宠、切换大小、动画、点击穿透，以及查看会话状态。
设置窗口主动打开时会获得焦点；桌宠普通点击和拖动使用非激活面板。

## 接入 Codex / Claude Code

在设置窗口的「宿主连接」中勾选宿主要接入并保存，可逐项测试连线状态。
细节与脚本化安装方式见 [宿主接入](docs/host-hooks.md)。

## 接入 DSH

插件位于 submodule `bridge/`，先初始化再打包：

```sh
git submodule update --init
(cd bridge && npm pack)
```

给指定 Web profile 安装 tarball，然后重启该 profile 的 DSH Host：

```sh
dsh plugin --profile web add "$PWD/bridge/dsh-native-pet-0.1.0.tgz"
```

也可以直接以本地 link 方式安装同一份源码，细节见插件仓库的 README。

应用与 DSH 必须运行在同一个 macOS 用户下。
默认通过 `~/Library/Application Support/dsh-native-pet/pet.sock` 通信。
自定义测试目录时，两端都设置相同的 `DSH_NATIVE_PET_RUNTIME_DIR`。

官方 Desktop 使用自己的插件管理入口及配置。
其安装和真实模型联动尚未验收，Web profile 的结果不能替代 Desktop 验收。
插件只观察公开状态事件，审批操作仍在 DSH 中完成。

## 构建产物

每次推送到 `main` 都会新建 `build-<timestamp>` 发布并标记为 latest，推送 `v*` 标签会发布对应版本并标记为 latest。
构建发布只保留最近 10 个，版本发布不受此清理规则影响。
最新 macOS arm64 构建可通过固定链接下载：

- [DMG 安装包](https://github.com/hotheat/harness-native-pet/releases/latest/download/dsh-native-pet-macos-arm64.dmg)
- [应用 ZIP](https://github.com/hotheat/harness-native-pet/releases/latest/download/DSH-Native-Pet-macos-arm64.zip)

构建使用 ad-hoc 签名，未进行 Developer ID 签名或 Apple 公证。
本地打包脚本生成 `dist/DSH Native Pet.app`。
移动到其他目录后的资源检查：

```sh
bash scripts/smoke-package.sh
```

## 素材来源

| 素材 | 来源 | 本地位置 | 说明 |
| --- | --- | --- | --- |
| 双丸子头小女孩 | 用户提供的 `hanzi-evolution-atlas/designs/ip-assets/two-head-q-girl` 参考图 | `designs/two-head-q-girl/`、`native/Sources/DSHNativePet/Resources/Character/` | 保留参考副本与生成提示词；九张透明 PNG 由 Codex image_gen 生成或编辑 |
| DSH Pet（鲸鱼娘） | [PC2005-cloud/dsh-pet](https://github.com/PC2005-cloud/dsh-pet) 的 `assets-mov` release | `native/Sources/DSHNativePet/Resources/DSHPet/` | 九段 HEVC-alpha MOV 保留原始字节；PNG 为各段首帧；MIT 许可随资源保留 |
| 应用与菜单栏图标 | 用户提供的 `Pet Bed.svg`、`pet.svg` | `designs/icons/source/`、`native/Sources/DSHNativePet/Resources/Icons/` | 来源文件未附许可证，仓库只记录用户提供的来源 |

- DSH Pet 的配置与许可按 commit `48007b64ac0bebb2e97ac88344aed62de8399dd4` 核对；`assets-mov` 是移动 tag，具体字节由 [sources.json](designs/dsh-pet/sources.json) 记录的 release digest、ZIP CRC、文件大小和逐文件 SHA-256 固定。
- DSH Pet 的 MOV 只改为状态名，没有转码或修改字节；PNG 由 AVFoundation 解码对应 MOV 首帧得到，保留原始 640 × 360 画布和透明度。
- 小女孩的参考图、逐姿态提示词、输入与输出哈希见 [designs/two-head-q-girl/README.md](designs/two-head-q-girl/README.md)。
- 完整的素材映射、布局、尺寸和校验方法见 [素材说明](docs/assets.md)：
  `swift scripts/validate-assets.swift` 校验小女孩，`swift scripts/validate-dsh-pet.swift` 校验 DSH Pet。

## 相关文档

- [开发与检查](docs/development.md)
- [状态链路与模块边界](docs/architecture.md)
- [素材来源与布局](docs/assets.md)
- [验收记录及未测项目](docs/acceptance.md)
- [实施计划与执行证据](docs/plans/2026-10-23-native-desktop-pet.md)
- [多宿主实施计划](docs/plans/2026-10-23-multi-host-notifications.md)
