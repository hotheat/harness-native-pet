#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="${DSH_NATIVE_PET_DIST_DIR:-$ROOT/dist}"
bash "$ROOT/scripts/package-app.sh"
STAGING="$(mktemp -d /tmp/dnp-dmg.XXXXXX)"
trap 'rm -rf "$STAGING"' EXIT
/usr/bin/ditto "$DIST/DSH Native Pet.app" "$STAGING/DSH Native Pet.app"
ln -s /Applications "$STAGING/Applications"
cat > "$STAGING/安装说明.txt" <<'EOF'
DSH Native Pet

1. 将 DSH Native Pet.app 拖入 Applications 文件夹。
2. 从 Applications 打开应用，允许系统通知。
3. 点击菜单栏图标 →「设置与会话状态…」→「宿主连接」，勾选要接入的宿主，点击「保存」。
4. Codex 仍需在 /hooks 或 Hooks 设置中审核并启用 hooks；Claude Code 需要重新开始会话。
5. 完成后可推出本磁盘。

默认人物高度 100 pt，可在菜单栏切换小女孩或 DSH Pet。
应用内的 Contents/Resources/install-hooks.py 仍可用于脚本化安装与卸载宿主接入。
应用使用本机 ad-hoc 签名，未进行 Apple 公证。
EOF
IMAGE="$DIST/dsh-native-pet-macos-$(uname -m).dmg"
hdiutil create -volname 'DSH Native Pet' -srcfolder "$STAGING" -format UDZO -ov "$IMAGE"
hdiutil verify "$IMAGE"
echo "$IMAGE"
