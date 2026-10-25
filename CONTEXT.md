# 桌宠领域

宿主是产生任务状态的 DSH、Codex 或 Claude Code。
来源标识区分宿主实例，会话标识只在所属来源内唯一。
DSH 快照描述常驻插件当前观察到的全部会话，重连首帧建立静默基线。
宿主事实描述 hook 在某个时刻观察到的事件，一次性交付进程退出不代表会话结束。
PetCore 中的 PetStore 把快照与宿主事实整理为持续状态，管理去重、回合、状态过期、姿态和一次性提醒。
已有回合只由 turnStarted 切换；Stop 后更新的同回合活动可恢复执行，有中间活动的后续 Stop 可再次提醒。
失败和中断保持终态直到新回合；工具失败只结束工具。
非终态 900 秒无事件标记待确认，终态 900 秒后退出可见列表，去重状态按 24 小时清理。
DSH waiting 在 bridge 去抖一次，Swift 收到非基线 waiting 后立即提醒；hook waiting 在 Swift 去抖。
会话标题是 DSH 的 `session/title` 事件或 `title` 初始投影提供的可选名称。
hook 会话用 cwd 末级目录生成的 label 作为标题，完整目录不进入协议。
标题只作为数据在 PetCore 传递，由应用层用于等待确认、本轮完成气泡与设置会话行。
设置中的“在通知中显示会话标题”默认关闭；开启后只影响通知标题行，正文与点击定位不变。
协议 v1 接受缺省版本或 v:1，忽略未知可选字段，严格检查必需内容。
未知版本经 IPC 和 dispatcher 写入菜单与设置的独立警告，不覆盖桌宠文字。
PetPresentation 只提供姿态、计数、会话、hasReceivedHook 和结构化 feedback；PresentedSession 持有原始 SessionSnapshot 与来源/stale。
PresentedFeedback 提供 pose、kind、sourceLabel、title，PetNotice 提供身份、kind、feedback、可选会话标题与时长，不携带文案。
应用层 PetMessageProjector 将事实投影为气泡、菜单/设置摘要、会话行与通知内容；PetStatusModel 只维护状态，AppDelegate 应用投影结果。
PetPoseDecision 根据 presentation、时间与交互标志决定最终姿态，依次处理 60 秒睡眠、poke、drag、demo。
AppDelegate 保留 lastActivity 更新、动画与系统挂起策略，并将最终姿态传给 projector。
通知 dispatcher 保留时长过滤与声音决策，把投影后的 PetNotificationContent 交给系统或录制 adapter；点击仍使用 sourceId/sessionId。
capture extension 输出外部测试所需证据。
C4 暂缓：DSH 快照可重连并合并为最新状态，hook 是不可合并的逐条事实；统一输入形态会改变重连、去重与提醒语义。
本轮回应结束只表示模型停止本轮回应，不能推定用户的业务目标已实现。
提醒通过桌宠文字与 macOS 通知展示，不包含对话正文、工具参数或凭据。
