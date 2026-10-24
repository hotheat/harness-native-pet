# 多宿主状态与通知

## 已确定方向

用户选择两个候选一起推进，提醒采用桌宠动作与文字加 macOS 系统通知，Codex 覆盖 CLI 和本机桌面应用。
Delivery：现有 feat/native-desktop-pet 分支；不提交或推送。
工作副本在本次会话 work/implementation，最终同步用户仓库。

宿主 hook → Swift 短命 adapter → 本地 IPC → 会话接收 module → 来源感知的任务呈现 → 桌宠和通知 adapter。
保留 DSH 快照的重连静默行为，新增一次性 activity 事实，不将 hook 的 EOF 解释为来源失联。
宿主 adapter 仅发送状态及标识，不发送正文、工作目录或工具输入。
Codex 使用 turn_id，Claude Code 使用 prompt_id 关联回合；依据本机当前版本实现，不引入旧版本兼容层。

## 冻结约定

PetActivityEvent 定义在 native/Sources/PetCore/PetActivityEvent.swift。
wire type 为 activity，provider 为 codex 或 claudeCode。
sessionId、eventId 为非空字符串，turnId、toolId 为可空字符串，occurredAt 为 Unix 秒。
kind 为 sessionStarted、turnStarted、toolStarted、toolFinished、waiting、running、turnEnded、failed、interrupted、sessionEnded。
JSON 只包含这八个字段；adapter 必须输出显式 null，避免与传输校验出现歧义。
应用收包只记录当前本机事实，不恢复离线历史；丢失的事件不伪造为成功。
同一回合终态不被迟到工具事件重新激活，重复事件不产生第二次提醒。
长期无新事实的 hook 状态标记为状态待确认，不误报完成。

PetStore 新增 apply(PetActivityEvent, at: Date)、drainNotices(at: Date) -> [PetNotice]。
PetNotice 含 id、sourceId、sourceLabel、sessionId、kind、title、body；kind 使用 waiting、ended、error、interrupted。
PetPresentation.sessions 改为带 sourceId、sourceLabel 及原 session 状态字段的 PresentedSession，窗口和设置使用来源标签。
桌宠聚合优先级不决定是否发出一次性通知。

## Ownership Map

| 路径 | Owner |
| --- | --- |
| PetActivityEvent.swift、contracts、Package.swift、脚本、文档、最终集成 | 主代理 |
| PetCore 其余文件、PetIPC、Core/IPC 测试 | core_agent |
| PetHooks、PetHookCLI、PetHooksTests | hooks_agent |
| DSHNativePet Swift、PetAppTests | ui_agent |

## 验收

先真实 socket 复现短命快照首帧静默和 EOF 清理，再实现独立事实生命周期。
Core 验证跨宿主同名会话、并行工具、去重、回合乱序、等待解除、状态过期、DSH 基线及提醒不被活动任务遮蔽。
adapter 验证原始 hook 输入映射、数据最小化、无应用时限时退出和不干预宿主决策。
联合验收使用短命 CLI 进程通过真实 IPC 驱动最终应用，并记录通知 adapter 的请求；系统通知权限与横幅展示另行实机验证。
尽可能通过已安装宿主验证 hooks 发现与触发；桌面应用与 CLI 分别记录实际证据。
最终主代理审查、回归现有双角色切换、打包、签名、解压与资源检查。

## Execution Evidence

短命快照旧行为已通过真实 socket 复现：首帧 completed 只建立 idle 基线，EOF 后会话数归零。
Network 封装在连续短命连接中出现 accept/receive 与关闭竞争，最后一帧可能未被消费。
基于反复复现，将 PetIPC 的读取实现替换为 POSIX 非阻塞 socket 与 DispatchSourceRead，保留同一公开 interface 及身份、心跳、锁和清理规则。
该调整集中在既有 PetIPC module，不引入第二套兼容传输。

三种已安装宿主均通过隔离真实回合验收，包含 SessionStart、UserPromptSubmit、Stop、SessionEnd 和应用内一次 ended 通知记录。
桌面验收使用其内置 runtime，未操作桌面窗口。
主代理实机复现并修复通知线程隔离崩溃，复核并修复并行文字截断，完成双角色与 DSH 回归。
系统授权与横幅可视验收因电脑控制接口超时未完成，具体范围见 docs/acceptance.md。
