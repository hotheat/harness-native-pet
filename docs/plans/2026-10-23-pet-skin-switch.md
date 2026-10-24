# 两套角色即时切换

## 需求与范围

用户指定从 `PC2005-cloud/dsh-pet` 获取素材，应用运行中可在当前角色与 DSH Pet 间切换。
默认保留小女孩，人物尺寸偏好仍以中号 100 pt 为基准。
角色选择即时生效并持久化，切换不重建 DSH 连接、不清空任务状态、不重置窗口位置。

## 事实与实现选择

上游源码核对基线为 `48007b64ac0bebb2e97ac88344aed62de8399dd4`。
其 `assets-mov` 发布包提供 macOS HEVC-with-Alpha MOV，采用原始透明动画配合 AVFoundation 原生播放。
只接入当前九个状态对应的素材，保持已有 Swift/AppKit 架构。
资源保留上游 MIT 许可证、来源 URL、选取映射和 SHA-256。
固定 release tag 可更新，实际下载内容以保存的哈希为准。

运行链路：菜单或设置改变角色偏好 → AppDelegate 选择资源 → PetView 替换对应状态的图像或视频。
DSH → bridge → IPC → PetStore 状态链路继续独立运行。
播放器由窗口渲染层管理，角色切换、隐藏、暂停及应用退出时释放或停止对应资源。

## Ownership Map

| 路径 | Owner |
| --- | --- |
| `Resources/DSHPet/`、`designs/dsh-pet/` | `/root/dsh_pet_assets` |
| 应用 Swift、`PetAppTests/`、`native/Package.swift` | `/root/skin_switch_native` |
| 打包、验证脚本、`bridge/tests/native-app.e2e.ts`、文档、集成和最终审查 | `/root` |

## 验收

- 两套资源独立加载，角色选择可持久化。
- 同一进程内完成小女孩 → DSH Pet → 小女孩，当前姿态和窗口位置保持正确。
- DSH Pet 实际视频播放、透明通道、循环及停止有运行证据。
- 隐藏、动画开关和重复切换释放播放器资源。
- 原生测试及真实 DSH 联动回归通过，移动后的应用包可读取两套资源。
- 主代理核对真实窗口截图，再同步源仓库并交付编译产物。

## Execution Evidence

素材代理完成九段 MOV、首帧 PNG、MIT 许可和来源哈希，原始视频字节未改。
原生代理完成两套资源加载、菜单与设置切换、AVFoundation 播放、清理和 100 pt 人物基准。
主代理独立审查后执行 38 项 Swift、35 项 TS、真实 Host 综合 E2E、三个原生联合场景、两套素材和移动包验证，均通过。

真实 working 会话贯穿同进程三次换肤，sessionId、storePose 和屏幕脚底坐标不变，播放器仅在 DSH Pet 阶段存在。
初版按动画总包络缩放会使主体约 82 pt，已按用户原有 100 pt 要求校准 referenceHeight，并允许窗口按特效范围扩展。
初版测试在完成反馈到期边界截图，复现失败后改为两秒截图，三个联合场景重跑通过。

性能记录、最终截图及编译产物随交付说明提供。
未修改 DSH 宿主、原 bridge 状态协议或用户日常 profile，未提交、推送或发布。
官方 Desktop 安装、真实模型、多屏/系统唤醒及签名公证的未测边界延续原验收记录。

主审性能复核发现命令行 NO 被强转 Bool 丢弃，正常启动实际仍显示窗口。
原生代理修正偏好读取，并补充缺省、Bool 和字符串值测试。
修复后普通启动隐藏窗口数从 1 降为 0，关闭动画后播放器释放，38 项 Swift 测试通过。
最终 release 再次通过三个原生联合场景、移动包检查及 ZIP 解压后的签名和双角色资源检查。

最终双角色 release 的 DSH Pet 各采样 120 秒：隐藏状态平均 CPU 0.025%、RSS 34.45 MiB；活动动画平均 CPU 2.091%、RSS 44.91 MiB。
两场景均达到 CPU/RSS 目标，CPU 为应用进程占单核比例，不含 WindowServer，RSS 为每两秒采样峰值。
