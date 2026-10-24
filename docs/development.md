# 开发

在仓库根目录执行：

```sh
npm --prefix bridge ci
npm --prefix bridge run typecheck
npm --prefix bridge test
npm --prefix bridge run test:e2e
npm --prefix bridge run build
swift test --package-path native
swift build --package-path native --product PetIPCSmoke
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

自动检查定义见 [check.yml](../.github/workflows/check.yml)。
远端 CI 是否通过以实际运行结果为准。


同进程角色切换验收：

```sh
"dist/DSH Native Pet.app/Contents/MacOS/DSHNativePet" \
  --demo-pose working --capture-skin-switch /tmp/pet-skin-switch \
  -pet.animations YES -pet.visible YES -pet.size medium
```

该入口通过菜单选择方法依次切换小女孩、DSH Pet、小女孩，输出 PNG 及同名 JSON。
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
