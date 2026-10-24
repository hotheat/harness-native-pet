# 本地验收记录

验收日期：2026-10-23。
环境：Apple Silicon、macOS 15.6.1、Swift 6.1.2、Node.js 26.8.2，DSH 发布包 0.2.1-rc.2。
这份记录描述本次本地构建，不代表远端 CI 或公开发行验收。

## 自动与集成检查

| 项目 | 结果 |
| --- | --- |
| TypeScript 类型检查、构建 | 通过 |
| TS 单元、协议和客户端测试 | 35 项通过 |
| 真实 DSH Host E2E | 通过；覆盖工具、审批、并行会话、取消、错误、重载、销毁 |
| Swift Core、IPC、UI 测试 | 38 项通过 |
| 共享 schema fixtures、依赖边界 | 通过 |
| 九姿态透明度、尺寸、可见区域和锚点 | 通过 |
| Node ↔ Swift 真实 IPC smoke | 通过；含分片、粘包、多来源、断开、锁和退出清理 |
| 实际第二应用实例 | 第二进程退出，第一实例继续运行 |
| 实际连接替换 | 旧 seq 50 来源被新 seq 1 替换后窗口显示 thinking，退出删除 socket |
| 真实 DSH Host → bridge → PetStore → PetPanel | waiting、completed 及真实 working 会话中角色切换三个场景通过，保存窗口 PNG 与事件证据 |
| Web profile 本地 tarball | 隔离 DSH_HOME 中安装、配置组合、禁用、启用、移除通过 |
| 移动 `.app` 后资源读取 | 两套各九姿态全部加载成功，确认资源来自移动后 Contents/Resources |
| 本机 ad-hoc 签名完整性 | codesign verify 通过 |

Host E2E 使用真实 DSH 组件和确定性 provider，真实执行工具与审批流程。
原生联合测试等待应用确认首份 idle 快照进入 PetStore 后才发起 turn，避免首快照静默逻辑掩盖结果。
Web package smoke 验证 CLI 与公开 PluginManager 的配置操作，未操作实际 Web 页面。
测试只使用临时 DSH_HOME，不改变日常 DSH 配置。

## 主代理审查

主代理亲自检查 bridge reducer、非阻塞发送与重连、Swift 解码、连接所有权、主线程投递、聚合、窗口布局、动画、资源路径和打包脚本。
确认并要求修复了审批去抖绕过、中性终止状态反馈、IPC 投递顺序、第二实例重复窗口、图片尺寸归一化，以及等待计数和状态文字排版问题。
问题分别以对应输入、真实 IPC 或实际应用窗口复现，修复后回归。

默认人物可见高度按用户最终要求设为 100 pt。
九姿态在各档尺寸中按 alpha 可见范围等高，脚底锚点一致。
主代理核对了实际窗口截图，确认人物完整、透明背景和文字间距。

## 性能

使用 release 应用，预热 5 秒，小女孩静态休息与活动动画各采样 120 秒。
`scripts/measure-performance.py` 用进程累计 CPU 时间差计算单核占用，每 2 秒采样 RSS。
指标包含应用进程，未包含 WindowServer 合成开销；采样峰值不等于瞬时峰值。
结果保存在交付证据 `performance.json`，两项均达到 CPU/RSS 目标。
静态休息平均 CPU 0.025%、采样峰值 RSS 41.48 MiB；活动动画平均 CPU 0.017%、RSS 41.58 MiB。
该次测试的命令行隐藏参数未生效，休息场景实际仍显示窗口，因此仅作为小女孩静态休息数据。
这份旧记录不能证明隐藏状态的性能。
机器为 Apple M4 Pro；系统查询未返回显示器刷新率，故该项未确认。

## 尚未验收

- 官方 DSH Desktop profile 的安装、启用和事件联动。
- 实际 Web 页面与真实远程模型的完整操作录像。
- 多台物理显示器拔插、Spaces/全屏切换、真实锁屏与系统休眠唤醒。
- 用户长期使用中的拖动、穿透和菜单交互回归。
- Intel 或 macOS 15 之前的系统。
- GitHub 远端 CI、Developer ID 签名、Apple 公证和跨机器分发。

上述项目保留为后续人工验收，不以单元测试或程序声明代替实机结果。


## 双角色即时切换验收

2026-10-23 接入 PC2005-cloud/dsh-pet 的九段原始透明 MOV，保留当前小女孩主题。
38 项 Swift 测试覆盖两套资源、角色偏好、100 pt 人物基准、动画包络、同姿态切换和播放器释放。
35 项 TS 测试、真实 DSH Host 综合 E2E、两套素材校验和移动包 smoke 均通过。

主代理运行的真实 Host 联合 E2E 在一个持续 working 的会话内，经菜单选择链路完成小女孩 → DSH Pet → 小女孩。
三张截图具有同一进程号、同一 sessionId，storePose 始终 working，脚底坐标保持一致。
播放器状态为 false → true → false，中间截图来自实际 AVPlayerItemVideoOutput，记录了播放时间与透明像素。
屏幕空间不足时，窗口仍优先约束到可见区域。

主审修正了 DSH Pet 按特效包络缩放造成主体约 82 pt 的问题，改用 idle 人物参考高度，默认主体准确为 100 pt。
窗口按特效范围扩展，切回小女孩恢复原框；人物尺度和任务状态保持不变。
联合测试曾在完成反馈的三秒到期边界截屏，已将测试截图时机调整至到期前两秒，并完整重跑三个场景通过。

原 MOV 未转码，九段共 2046 帧全部通过 AVFoundation 解码审计。
来源与许可见 designs/dsh-pet，完整上游许可包含在应用资源中。
前文单角色性能记录不作为新增视频主题的性能结论；视频主题结果单独保存为 performance-dsh-pet.json。

命令行布尔偏好读取已修复，缺省、Bool、字符串 NO/YES 均有测试。
普通启动的隐藏参数通过系统屏幕窗口枚举复测，关闭动画后验证播放器已释放。
最终 release 的三个原生联合场景和解压 ZIP 后的签名、双角色资源检查均通过。

最终双角色 release 的 DSH Pet 各采样 120 秒：隐藏状态平均 CPU 0.025%、RSS 34.45 MiB；活动动画平均 CPU 2.091%、RSS 44.91 MiB。
两场景均达到 CPU/RSS 目标，CPU 为应用进程占单核比例，不含 WindowServer，RSS 为每两秒采样峰值。

## 多宿主与系统通知验收

本轮统一链路为宿主 hook → 原生 pet-hook → Unix socket → PetStore → 桌宠和通知 adapter。
保留 DSH 长连接快照与心跳，短命 hook 连接关闭后仍保留回合状态。

| 项目 | 结果 |
| --- | --- |
| Swift Core、IPC、Hooks、App | 最终 80 项通过 |
| TypeScript | 类型检查及 36 项测试通过 |
| 安装器 | 3 项测试通过；覆盖合并、幂等、卸载与已有配置保留 |
| 短命 socket | 100 次立即关闭重复 10 轮，共 1000 次全部送达，包含无换行末帧 |
| 原始 hook → 最终 app | 并行完成去重、持续等待、Stop 后 SessionEnd 三场景通过 |
| Codex CLI 0.163.0 | 真实宿主回合触发 hooks，原生应用收到一次 ended 提醒 |
| 桌面内置 Codex runtime 0.163.0-alpha.11.2 | 同上；未操作桌面窗口 |
| Claude Code 2.1.296 | 同上；来源标签为 Claude Code |
| DSH 回归 | 真实 Host 综合 E2E、Node ↔ Swift IPC、原生三场景及工作中角色切换通过 |
| release 包 | helper 与应用 ad-hoc 签名、移动包两套九姿态资源检查通过 |

三宿主验收使用临时 HOME、宿主配置和 localhost 确定性模型。
Codex hooks 通过官方配置接口按 currentHash 审核信任，日常配置未修改。
宿主联合测试使用录制通知 adapter，证据保存在交付目录 multi-host-acceptance/real-hosts。
这些结果验证本机桌面内置运行时，尚未验证桌面窗口内的实际用户会话。

主代理检查了事件转换、会话隔离、乱序与终态、独立提醒队列、非阻塞传输、安装配置合并及打包链路。
正常模式实机复现了 UserNotifications 回调继承 MainActor 后在系统后台队列触发断言的启动崩溃。
实际截图同时暴露了并行完成反馈在两行气泡中被截断的问题，两处均纳入本轮修复与复测。

通知修复后的正常模式进程持续运行超过 12 分钟，socket 保持可用，未生成新的崩溃报告。
真实系统 adapter 下发送 UserPromptSubmit 和 Stop 后进程仍存活。
系统通知的授权状态与横幅未完成可视验收：电脑控制接口读取应用界面时超时。
交付保留这项人工验收，不将录制 adapter 或进程存活记为横幅成功。
并行提示改为来源独占一行、结束与剩余执行数独占一行，应用测试测量完整文本不超过气泡高度。
