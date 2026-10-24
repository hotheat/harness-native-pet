#!/bin/bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
APP="$HERE/DSH Native Pet.app"
python3 "$APP/Contents/Resources/install-hooks.py" --app "$APP" --target both
printf '\n已添加 Codex / Claude Code 接入。\n请打开桌宠并允许系统通知；在 Codex 的 /hooks 或 Hooks 设置中审核启用，然后重新开始会话。\n按回车关闭。\n'
read -r
