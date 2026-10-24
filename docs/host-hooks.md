# Codex 与 Claude Code 接入

应用保持原生 Swift/AppKit 实现，附带原生 `pet-hook` 可执行文件。
状态链路为宿主 hook → 短命 adapter → 本机 Unix socket → 会话接收 module → 桌宠与系统通知。
两套角色共用同一份任务状态，人物默认高度仍为 100 pt。

## 安装

打开应用，允许 macOS 系统通知。
菜单和设置中的「系统通知」可单独关闭提醒，桌宠继续显示状态。
如果已拒绝授权，可在 macOS 系统设置的通知中允许 DSH Native Pet。

在设置窗口的「宿主连接」中勾选要接入的宿主，点「保存」。
应用会把 `pet-hook` 安装到 `~/Library/Application Support/dsh-native-pet/bin/pet-hook`，并把本项目 hooks 合并到 Codex 的 `hooks.json` 或 Claude Code 的 `settings.json`。
取消勾选再保存即可移除本项目 handlers，其他 hooks 与配置保持原样。
每次写入前，原文件会备份为 `<文件名>.dsh-native-pet-<UTC 时间戳>.bak`；写入使用临时文件原子替换，失败时保留原文件并在界面显示原因。

每行都有「测试」，依次检查三层：本机 socket 是否可达、配置与 helper 是否一致、30 秒内是否收到该宿主的真实事件。
第三层需要你在宿主里发起一次会话操作。

「宿主连接」中的 DSH 一栏只做探测，不修改 profile。

没有图形界面或需要脚本化时，仍可使用安装器：

```sh
python3 "DSH Native Pet.app/Contents/Resources/install-hooks.py" \
  --app "DSH Native Pet.app" --target both
```

脚本与本应用共用同一套合并语义，由 `contracts/fixtures/host-hooks.json` 约束。
卸载：`install-hooks.py --uninstall --target both`。

Codex 的非托管 hooks 需要在 `/hooks` 或桌面 Hooks 设置中审核并启用，应用不会替用户写入信任记录。
Claude Code 安装后重新开始会话。
配置目录优先使用应用进程的环境变量 `CODEX_HOME` / `CLAUDE_CONFIG_DIR`，缺失时使用默认目录；图形界面不继承登录 shell 的环境，非默认目录请在启动应用的环境中设置。
CLI 与本机桌面运行环境使用同一 Codex 配置目录时可以共用配置。
远程执行环境不能直接访问本机 socket，不能以本机 runtime 验收代替云端支持。

## 提醒语义

- 提交输入、执行工具、等待处理时，桌宠显示对应状态。
- 回应结束、出错、中断及持续待处理请求产生一次性提醒。
- 系统通知只在等待和出错时发声。
- `.ended` / `.interrupted` 在回合时长已知且短于阈值时不发系统通知，桌宠反馈保留；默认阈值为 10 秒，偏好键为 `pet.noticeMinimumSeconds`。
- 时长未知时不受阈值影响，照常发送；例如桌宠在回合开始后才启动，首次观察到的事件就是 `Stop`。
- 点击系统通知或在等待状态点击桌宠会打开设置并定位到对应会话。
- `Stop` 显示“本轮回应已结束”，不推定业务目标成功。
- Claude Code 报告仍有后台任务或定时任务时保持执行状态。
- 子代理事件不覆盖主会话，当前接入显示主会话状态。
- 长时间没有新事实的会话显示“状态待确认”，不伪造结束。

提醒去重与桌宠姿态分别处理，因此其他会话仍在工作时也能收到结束通知。
应用未运行时 helper 会快速退出，不阻塞宿主；此时的事件不补发。
正常事件只传宿主、会话和回合标识、工具标识、时间与状态，不传提示词、回答正文、工作目录或工具参数。

## 验证

```sh
swift test --package-path native
python3 -m unittest discover -s scripts/tests -v
bash scripts/package-app.sh
```

`--notification-log /tmp/pet-notices.jsonl` 使用录制 adapter 替代真实系统通知，适用于联合测试。
录制结果证明应用发出提醒请求，不能证明系统已经展示横幅。
实际版本及验收范围见 [验收记录](acceptance.md)。

官方事件定义：[Codex hooks](https://learn.chatgpt.com/docs/hooks)、[Claude Code hooks](https://code.claude.com/docs/en/hooks)。
