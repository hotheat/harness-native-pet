# 本地验收

本轮日期：2026-10-24。
环境：Apple Silicon、macOS 15.6.1、Swift 6.1.2、Node.js 26.8.2，DSH 发布组件 0.2.1-rc.2。
结果限于本机工作树，远端 CI 与公开发行验收需独立确认。

## 本轮验证

| 命令或范围 | 结果 |
| --- | --- |
| `npm --prefix bridge ci` | 通过（worktree 新装依赖） |
| `npm --prefix bridge run typecheck`、`build` | 通过 |
| `npm --prefix bridge test` | 91/91 通过 |
| `npm --prefix bridge run test:e2e` | 1/1 通过（真实 DSH Host） |
| `swift test --disable-sandbox --package-path native` | 全部通过（含真实 socket、hook transport、视频与 UI 测试） |
| `swift build --disable-sandbox --package-path native --product PetIPCSmoke` | 通过 |
| `python3 -m unittest discover -s scripts/tests` | 5/5 通过，含原子升级及复制、chmod、replace 失败注入 |
| `node scripts/check-boundaries.mjs`、`check-contracts.mjs` | 通过 |
| `swift scripts/validate-assets.swift`、`validate-dsh-pet.swift` | 通过 |
| `node scripts/smoke-ipc.mjs` | 通过 |
| `bash scripts/package-app.sh`、`smoke-package.sh` | 通过；签名验证和移动包资源检查通过 |
| `DSH_NATIVE_PET_APP=... npm --prefix bridge run test:native` | 3/3 通过（waiting、completed、working 中换肤） |
| `python3 scripts/test-hook-app.py` | parallel-ended、waiting、closed-ended 三场景通过 |
| `python3 scripts/test-real-host-hooks.py` | 未运行 |

SwiftPM 在受沙箱限制的环境中需追加 `--disable-sandbox`；打包时用临时 wrapper 追加该参数，脚本本身未修改。
状态回归在修改前运行时 8 项失败，修复后覆盖 Stop 续跑与再次提醒、重复 Stop、Stop 后失败或中断、陌生回合隔离、终态时间倒挂、899/901 秒保留边界、DSH waiting episode 和 300 条提醒顺序。
协议 fixture 覆盖缺省版本、显式 v1、未知字段、非法版本、缺失必需键和错误类型。
完整命令及前置条件见 [开发指南](development.md)。

## 已有实机证据及适用范围

以下为 2026-10-23 的实机记录，未作为本轮改动后的通过证明。

- 真实 DSH Host 的工具、审批、并行、取消、错误、重载和销毁链路，以及 waiting、completed、working 中换肤三个原生场景通过。
- 角色切换保持同一进程、会话、working 状态和脚底坐标，播放器状态 false → true → false；视频截图来自实际解码帧并含播放时间和透明像素。
- 原始 hook → helper → app 的并行结束去重、持续等待、Stop 后 SessionEnd 三场景通过；短命 socket 共 1000 次送达，含无换行末帧。
- Codex CLI 0.163.0、桌面内置 runtime 0.163.0-alpha.11.2、Claude Code 2.1.296 在临时 HOME、配置与 localhost 确定性模型下触发 ended 提醒；桌面窗口中的实际用户会话未验证。
- 单实例、连接替换、退出清理、移动包双角色资源和 ad-hoc 签名通过。
- Web profile 本地 tarball 在隔离 DSH_HOME 中完成安装、配置、禁用、启用、移除；实际 Web 页面未操作。
- 正常通知模式进程持续运行超过 12 分钟，真实系统 adapter 接收 UserPromptSubmit 和 Stop 后仍存活；授权状态与横幅可视效果未验收。
- 默认人物可见高度 100 pt，九姿态各档尺寸的 alpha 可见区域、脚底锚点、完整人物和文字间距有窗口及资源检查证据。
- 原始九段 MOV 共 2046 帧通过解码审计，素材来源与完整许可见 [designs/dsh-pet](../designs/dsh-pet/)。

## 性能证据

既有 release 采样使用 Apple M4 Pro，每场景预热 5 秒、采样 120 秒，每 2 秒读取 RSS。
CPU 为应用进程占单核比例，不含 WindowServer，RSS 为采样峰值。

| 场景 | 平均 CPU | 峰值 RSS |
| --- | --- | --- |
| 小女孩静态休息，窗口显示 | 0.025% | 41.48 MiB |
| 小女孩活动动画 | 0.017% | 41.58 MiB |
| DSH Pet 隐藏 | 0.025% | 34.45 MiB |
| DSH Pet 活动动画 | 2.091% | 44.91 MiB |

小女孩静态休息记录不能证明隐藏状态性能，显示器刷新率未确认。
数据来自 `performance.json` 和 `performance-dsh-pet.json` 交付证据，本轮未重新测量。

## 未验收与限制

- 本轮代码的 IPC 启动失败退出与双实例实机场景、协议不兼容提示在菜单/设置中的可视效果、真实 Codex/Claude Code 宿主回归，以及系统通知可视回归。
- 官方 DSH Desktop profile 的安装、启用和事件联动，真实 Web 页面与远程模型完整操作。
- 多台物理显示器拔插、Spaces/全屏、锁屏、休眠唤醒，以及长期拖动、穿透和菜单交互。
- Intel、macOS 15 之前系统、远端 CI、Developer ID 签名、Apple 公证和跨机器分发。
- 系统通知频率、声音、点击响应、客户端自助接入和热插拔位置属于独立产品事项，本轮未调整。
- Hook 没有宿主全序；迟到旧活动可能被当作 Stop 续跑，丢失 turnStarted 会使已有会话的新回合事件和提醒被丢弃。
- capture 仍编译进 release；录制 adapter、进程存活与编译成功均不能证明系统横幅或视觉验收成功。
