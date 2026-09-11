#!/bin/bash
# set-linphone-push.sh — 配置 Linphone 锁屏来电推送的 FlexiAPI Key
#
# 用法：
#   ./set-linphone-push.sh <API_KEY>          # 写入 Key（推荐：Key 在 Mac 浏览器上生成）
#   ./set-linphone-push.sh --status           # 查看当前配置与最近一次推送日志
#   ./set-linphone-push.sh --test <pn_prid>   # 用当前 Key 发一条测试推送（type=background）
#
# Key 的获取：在 **Mac 上**打开 https://subscribe.linphone.org 并登录
# （免费 sip.linphone.org 账号）→ My Account → API Key → Manage
# → 生成/复制。务必在 Mac 上操作：生成的 Key 绑定当前出口 IP，
# 网关是从这台 Mac 调推送 API 的，IP 不一致会被 403。
# Key 闲置一段时间会被服务端回收，过期重生成一次即可。
set -uo pipefail

KEY_FILE="$HOME/.cellbridge/linphone_push_key"
URL_FILE="$HOME/.cellbridge/linphone_push_url"
LOG="$HOME/.cellbridge/run/logs/gateway.log"

case "${1:-}" in
  --status)
    if [ -f "$KEY_FILE" ]; then
      K=$(head -1 "$KEY_FILE" | tr -d '[:space:]')
      echo "Key 文件: $KEY_FILE（已配置，${#K} 字符）"
    else
      echo "Key 文件: $KEY_FILE（未配置）"
    fi
    [ -f "$URL_FILE" ] && echo "自定义端点: $(cat "$URL_FILE")"
    echo "--- 网关日志中的 linphonepush 记录 ---"
    grep -a "linphonepush" "$LOG" 2>/dev/null | tail -5 || echo "（无）"
    ;;
  --test)
    [ -f "$KEY_FILE" ] || { echo "先配置 Key：./set-linphone-push.sh <API_KEY>"; exit 1; }
    KEY=$(head -1 "$KEY_FILE" | tr -d '[:space:]')
    URL="https://subscribe.linphone.org/api/push_notification"
    [ -f "$URL_FILE" ] && URL=$(cat "$URL_FILE")
    PRID="${2:?用法: ./set-linphone-push.sh --test <pn_prid>}"
    FROM="sip:$(cat "$HOME/.cellbridge/linphone_push_from" 2>/dev/null || echo yourname@sip.linphone.org)"
    echo "POST $URL (From: $FROM) ..."
    curl -sS -X POST "$URL" \
      -H "Content-Type: application/json" -H "Accept: application/json" \
      -H "From: $FROM" \
      -H "x-api-key: $KEY" \
      -d "{\"pn_provider\":\"apns\",\"pn_param\":\"org.linphone.phone.voip\",\"pn_prid\":\"$PRID\",\"type\":\"background\"}"; echo
    ;;
  "")
    sed -n '2,10p' "$0"; exit 2 ;;
  *)
    mkdir -p "$HOME/.cellbridge"
    printf '%s' "$1" > "$KEY_FILE" && chmod 600 "$KEY_FILE"
    FROM="${2:-yourname@sip.linphone.org}"
    printf '%s' "$FROM" > "$HOME/.cellbridge/linphone_push_from" && chmod 600 "$HOME/.cellbridge/linphone_push_from"
    [ -n "${2:-}" ] && printf '%s' "$2" > "$URL_FILE"
    echo "已写入 $KEY_FILE（重启 ./start_cellbridge.sh 后生效）"
    ;;
esac
