# 开发

在仓库根目录执行：

```sh
npm --prefix bridge ci
npm --prefix bridge run typecheck
npm --prefix bridge test
npm --prefix bridge run test:e2e
npm --prefix bridge run build
swift test --disable-sandbox --package-path native
swift build --disable-sandbox --package-path native --product PetIPCSmoke
python3 -m unittest discover -s scripts/tests -v
node scripts/check-boundaries.mjs
node scripts/check-contracts.mjs
swift scripts/validate-assets.swift
swift scripts/validate-dsh-pet.swift
node scripts/smoke-ipc.mjs
bash scripts/package-app.sh
bash scripts/smoke-package.sh
```

`test:e2e` 使用发布的真实 DSH Host 组件及确定性 provider、tool、approval，在临时 DSH_HOME 内测试完整回合。
它不使用真实模型凭据。
原生 IPC 测试绑定真实 Unix socket，需要允许本地 socket 和 GUI 会话的 macOS 环境。

原生联合 E2E 使用已构建应用：

```sh
DSH_NATIVE_PET_APP="$PWD/dist/DSH Native Pet.app/Contents/MacOS/DSHNativePet" \
DSH_NATIVE_PET_CAPTURE_DIR="$PWD/dist/acceptance" \
npm --prefix bridge run test:native
```

应用提供确定性截图入口：

```sh
"dist/DSH Native Pet.app/Contents/MacOS/DSHNativePet" \
  --demo-pose idle --capture-preview /tmp/pet-idle.png
```

截图来自实际 PetPanel，保持正常偏好尺寸。
小女孩截图暂停轻动画；DSH Pet 截图使用当前 AVPlayerItemVideoOutput 的实际解码帧，JSON 证据标记来源和播放时间。
`--capture-live /tmp/pet-live.png --capture-after 3` 保持真实 IPC 并在捕获后退出。
这些入口用于验收，不改变默认启动行为。
实现位于 [AppDelegate+Capture.swift](../native/Sources/DSHNativePet/AppDelegate+Capture.swift)，automation 判断与参数校验位于 AppDelegate。
缺值、冲突模式和非法延时在创建通知 adapter、窗口和 IPC 前失败。
`--capture-live` 与 demo 互斥，三种 capture 入口互斥；`--capture-after` 需要配合 capture。
自动化使用录制通知 adapter，不写入用户偏好；`--notification-log PATH` 可输出 JSONL。

受限环境需要将 `CLANG_MODULE_CACHE_PATH` 和 `SWIFTPM_MODULECACHE_OVERRIDE` 指向可写缓存目录。
`scripts/package-app.sh` 保持标准构建命令；需要 `--disable-sandbox` 时，可用临时 swift wrapper 为 build 子命令追加该参数，无需修改打包脚本。
Socket 绑定、GUI 会话或 AVFoundation 解码失败应分别记录为未验证，不能由编译成功替代。

自动检查定义见 [check.yml](../.github/workflows/check.yml)。
远端 CI 是否通过以实际运行结果为准。


同进程角色切换验收：

```sh
"dist/DSH Native Pet.app/Contents/MacOS/DSHNativePet" \
  --demo-pose working --capture-skin-switch /tmp/pet-skin-switch \
  -pet.animations YES -pet.visible YES -pet.size medium
```

该入口通过菜单选择方法依次切换小女孩、DSH Pet、小女孩，输出 PNG 及同名 JSON。
换肤断言由 `bridge/e2e/native-app.e2e.mjs` 执行，包括三帧脚底坐标、sizePreference 和首尾 frame 一致。
证据 JSON 字段以该测试与 `scripts/test-hook-app.py` 的消费为准。
去掉 `--demo-pose` 即保留真实 IPC；`test:native` 还会执行真实 DSH Host 的工作会话内切换场景。

## 多宿主接入验证

```sh
python3 -m unittest discover -s scripts/tests -v
python3 scripts/test-hook-app.py --app 'dist/DSH Native Pet.app' --output dist/multi-host-acceptance/hook-app
python3 scripts/test-real-host-hooks.py --app 'dist/DSH Native Pet.app' --output dist/multi-host-acceptance/real-hosts
```

`test-hook-app.py` 用原始 hook 输入检查并行完成、持续等待和会话关闭后的反馈。
`test-real-host-hooks.py` 使用本机已安装的 Codex CLI、桌面内置 runtime 与 Claude Code，通过 localhost 确定性模型执行真实回合。
脚本为每个宿主创建临时 HOME 和配置，Codex hooks 经官方配置接口信任，退出时清理临时目录。
桌面内置 runtime 的通过结果不代表桌面窗口内已完成实际会话验收。
两套测试使用录制通知 adapter；系统授权和实际展示需正常启动应用验证。

## DMG 安装包

```sh
bash scripts/package-dmg.sh
```

脚本编译应用，在 dist 生成当前 CPU 架构的 DMG，包含 Applications 拖放入口和宿主接入脚本。
