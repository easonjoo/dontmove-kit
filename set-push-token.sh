#!/bin/bash
# set-push-token.sh — 写入 YakPhone 的 PushKit token，让来电能够唤醒 CallKit。
#
# 为什么需要它：iOS 只允许通过 VoIP 推送（PushKit）在 App 挂起/后台时唤醒
# 并弹出 CallKit 来电界面。网关在收到模块 RING 时会 POST 到
# push.yakteam.com/v1/notify，其中 token 必须来自 YakPhone 本身。
# 不填的后果：App 在前台时 SIP INVITE 仍能振铃，但锁屏/后台来电毫无反应。
#
# 获取 token：YakPhone → 设置（Settings）→ 推送 / Push（PushKit、APNs Token）
#             → 复制，形如一串 Base64（常以 == 结尾）。
#
# 用法：
#   ./set-push-token.sh 'AAA...=='     # 直接给
#   ./set-push-token.sh                # 交互式粘贴（不回显）
#   ./set-push-token.sh --clear        # 清除
#
# 写入后需重启网关生效：./start_cellbridge.sh
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
FILE="$HOME/.cellbridge/push_token"

if [ "${1:-}" = "--clear" ]; then
  rm -f "$FILE"
  echo "已清除 $FILE（来电将不再推送，后台不会振铃）"
  exit 0
fi

if [ -n "${1:-}" ]; then
  TOKEN="$1"
elif [ -t 0 ]; then
  read -r -s -p "粘贴 YakPhone PushKit token 后回车: " TOKEN
  echo
else
  TOKEN="$(cat)"
fi

# 复制粘贴常带换行/空格；token 本身不含空白字符。
TOKEN="$(printf '%s' "$TOKEN" | tr -d '[:space:]')"

if [ -z "$TOKEN" ]; then
  echo "未提供 token，未做任何修改。"
  exit 1
fi
case "$TOKEN" in
  *"<"*|*">"*|*"你的"*)
    echo "看起来还是占位符，不是真实 token。已中止。"
    exit 1
    ;;
esac
if [ "${#TOKEN}" -lt 32 ]; then
  echo "警告：token 只有 ${#TOKEN} 个字符，通常明显更长，请确认复制完整。"
fi

mkdir -p "$(dirname "$FILE")"
umask 077
printf '%s' "$TOKEN" > "$FILE"
chmod 600 "$FILE"

echo "已写入 $FILE（${#TOKEN} 个字符，权限 600）"
echo
echo "下一步：重启网关使其生效"
echo "  cd \"$DIR\" && ./start_cellbridge.sh"
