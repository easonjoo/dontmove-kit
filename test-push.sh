#!/bin/bash
# test-push.sh — 直接向 push.yakteam.com 发一条 VoIP 推送，验证 PushKit token。
#
# 为什么需要它：判断「锁屏/后台来电不响」到底卡在哪一环，最怕的是只能靠
# 真打电话来试。本脚本把网关里那段推送逻辑（internal/sip/yakpush.go）单独
# 跑一遍，于是三件事一次分清：
#   * token 没配        → 本脚本直接报「未配置」
#   * token 格式/失效   → 端点回 4xx + 说明（CallKit 必然不会响）
#   * 推送被接受        → 端点回 2xx，此时若手机仍不响，问题在 App 侧
#                        （通知权限 / PushKit 回调 / 系统专注模式），不在网关
#
# 用法：
#   ./test-push.sh                  # 用 ~/.cellbridge/push_token，发一条 VoIP 来电推送
#   ./test-push.sh 'AAA...=='       # 临时用指定 token 测（不写入文件）
#   ./test-push.sh --message '你好'  # 发一条普通消息推送（type=message）
#
# 注意：必须绕过 HTTP(S)_PROXY。本机走透明 TUN 出网，代理反而会把它打断
# （网关里同样是 Transport{Proxy: nil}，见 yakpush.go 注释）。
set -uo pipefail

TOKEN_FILE="$HOME/.cellbridge/push_token"
ENDPOINT="https://push.yakteam.com/v1/notify"
PUSH_TYPE="voip"
CALLER="sip:13800138000@$(ipconfig getifaddr en0 2>/dev/null || echo 192.168.1.109)"
BODY_TEXT=""

while [ $# -gt 0 ]; do
  case "$1" in
    --message) PUSH_TYPE="message"; BODY_TEXT="${2:-测试消息}"; shift 2 ;;
    --type)    PUSH_TYPE="${2:-voip}"; shift 2 ;;
    --caller)  CALLER="${2:-$CALLER}"; shift 2 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *)         TOKEN="$1"; shift ;;
  esac
done

if [ -z "${TOKEN:-}" ]; then
  if [ ! -f "$TOKEN_FILE" ]; then
    echo "✗ 未配置 token（$TOKEN_FILE 不存在）"
    echo "  先执行：./set-push-token.sh 'AAA...=='"
    exit 2
  fi
  TOKEN="$(tr -d '[:space:]' < "$TOKEN_FILE")"
  SRC="$TOKEN_FILE"
else
  SRC="命令行参数"
fi

if [ -z "$TOKEN" ]; then
  echo "✗ token 为空"
  exit 2
fi

echo "端点   : $ENDPOINT"
echo "类型   : $PUSH_TYPE"
echo "caller : $CALLER"
echo "token  : ${TOKEN:0:8}…（共 ${#TOKEN} 字符，来源：$SRC）"
echo "---"

# 与网关完全一致的 JSON 形状（字段名大小写敏感）
PAYLOAD=$(printf '{"token":"%s","caller_uri":"%s","caller_name":"%s","type":"%s"%s}' \
  "$TOKEN" "$CALLER" "${CALLER#sip:}" "$PUSH_TYPE" \
  "$([ -n "$BODY_TEXT" ] && printf ',"message_body":"%s"' "$BODY_TEXT")")

RESP=$(curl -sS --noproxy '*' -m 15 -w '\n%{http_code}' \
  -X POST "$ENDPOINT" \
  -H 'Content-Type: application/json' \
  --data-binary "$PAYLOAD" 2>&1)

CODE=$(printf '%s' "$RESP" | tail -n1)
BODY=$(printf '%s' "$RESP" | sed '$d')

echo "HTTP $CODE"
[ -n "$BODY" ] && echo "响应 $BODY"
echo "---"

case "$CODE" in
  2*)
    echo "✓ 推送已被端点接受。"
    echo "  若手机此刻仍不响：问题在 App/系统侧，不在网关。依次检查"
    echo "  ① YakPhone 的通知权限 ② 系统「专注模式/静音未知来电」"
    echo "  ③ App 是否被后台清理（PushKit 需 App 至少安装过并授权）"
    exit 0 ;;
  401|403)
    echo "✗ token 被拒（HTTP $CODE）。token 已失效或不属于该推送环境。"
    echo "  重新在 YakPhone → 设置 → 推送 复制最新的 PushKit token。"
    exit 1 ;;
  400)
    echo "✗ 请求被拒（HTTP 400）：token 格式不对，多半是复制时截断/多带了字符。"
    echo "  当前长度 ${#TOKEN}；PushKit token 是 Base64，通常 64 字符以上。"
    exit 1 ;;
  000)
    echo "✗ 连不上端点（curl 退出前未拿到状态码）。检查网络/是否又被代理拦了。"
    exit 1 ;;
  *)
    echo "? 未预期的状态码 $CODE，按上面响应体判断。"
    exit 1 ;;
esac
