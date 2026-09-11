#!/bin/sh
# tailnet-setup.sh — 让 CellBridge 脱离局域网使用（Tailscale / tailnet 模式）。
#
# 架构（对应上游 docs/deployment/nas.md，Mac 扮演 NAS 角色）：
#   - SIP/RTP：网关监听 0.0.0.0:5060，tailnet 内的手机直连 Mac 的 100.x 地址
#   - HTTP API：只绑 127.0.0.1:8787（安全），外部统一走 Tailscale Serve
#     的 https://<主机>.<tailnet>.ts.net → 反代到回环
#   - 短信/来电通知：走 push.yakteam.com 云端推送，与网络位置无关
#
# 用法：
#   ./tailnet-setup.sh          体检 + 打印需要的信息
#   ./tailnet-setup.sh serve    额外执行 tailscale serve（开放 API 入口）
set -u

ADB_UNUSED=1  # 占位，保持 set -u 下无副作用

TS=""
for c in \
  "$(command -v tailscale 2>/dev/null || true)" \
  /Applications/Tailscale.app/Contents/MacOS/Tailscale \
  /usr/local/bin/tailscale \
  /opt/homebrew/bin/tailscale
do
  [ -n "$c" ] && [ -x "$c" ] && TS="$c" && break
done

if [ -z "$TS" ]; then
  cat <<'EOF'
✗ 未检测到 Tailscale。

要脱离局域网使用，需要 Mac 和 iPhone 在同一个 tailnet 里：

  Mac 二选一：
    1) App Store 搜 "Tailscale" 安装（推荐，图形界面，自带 CLI）
    2) brew install tailscale && sudo brew services start tailscale

  iPhone：App Store 安装 Tailscale，用同一个账号登录并打开 VPN 开关。

  然后在 Tailscale 管理后台（login.tailscale.com）→ DNS → 开启 MagicDNS，
  这样才能拿到 <主机名>.<tailnet名>.ts.net 域名（配对接口要用它当 baseURL）。

装好后再跑一次本脚本。
EOF
  exit 1
fi

echo "✓ Tailscale CLI: $TS"
STATUS="$("$TS" status 2>&1)"
if ! printf '%s' "$STATUS" | grep -q "100\."; then
  echo "✗ Tailscale 似乎未登录/未连接，status 输出："
  printf '%s\n' "$STATUS" | head -5
  echo "  请先在 Mac 上登录 Tailscale。"
  exit 1
fi

# 解析 tailnet IPv4 与 MagicDNS 名（用 python3 解 JSON，避免依赖 jq）
INFO="$("$TS" status --json 2>/dev/null | /usr/bin/python3 -c '
import json,sys
try:
    d=json.load(sys.stdin)
except Exception:
    sys.exit(1)
ips=(d.get("Self") or {}).get("TailscaleIPs") or []
ip4=next((i for i in ips if ":" not in i), "")
name=((d.get("Self") or {}).get("DNSName") or "").rstrip(".")
print(ip4)
print(name)
')"
TSIP=$(printf '%s\n' "$INFO" | sed -n '1p')
TSNAME=$(printf '%s\n' "$INFO" | sed -n '2p')

echo ""
echo "  tailnet IPv4 : ${TSIP:-（未取到）}"
echo "  MagicDNS 名  : ${TSNAME:-（未取到，需在后台开启 MagicDNS）}"
echo ""

if [ "${1:-}" = "serve" ]; then
  if [ -z "$TSNAME" ]; then
    echo "✗ 没有 MagicDNS 名，无法配置 Serve。请先开启 MagicDNS。"
    exit 1
  fi
  echo "配置 Tailscale Serve（https 443 → 127.0.0.1:8787）..."
  # 不同 Tailscale 版本参数略有差异，先试新版写法，再退回旧版
  OUT="$("$TS" serve --bg --https=443 http://127.0.0.1:8787 2>&1)"
  case "$OUT" in
    *"not enabled on your tailnet"*|*"not enabled"*)
      echo "✗ 你的 tailnet 还没启用 Serve（这是一次性的账号级开关，只能用浏览器点）。"
      echo ""
      printf '%s\n' "$OUT" | grep -oE 'https://login\.tailscale\.com/[^ ]+' | head -1 | while read -r u; do
        echo "  请打开这个链接并确认开启："
        echo "    $u"
      done
      echo ""
      echo "  开启后再跑一次：./tailnet-setup.sh serve"
      exit 1
      ;;
  esac
  [ -n "$OUT" ] && printf '%s\n' "$OUT"
  echo ""
  "$TS" serve status 2>&1 | head -10
else
  echo "如需开放 App 的 API 入口（配对/同步必需），执行："
  echo "    ./tailnet-setup.sh serve"
fi

echo ""
echo "═══════════════════════════════════════════════"
echo " YakPhone（iPhone）里这样填："
echo "   SIP 服务器 : ${TSIP:-<tailnet IP>}:5060"
echo "   （也可填 MagicDNS 名）${TSNAME:-}"
echo ""
echo " API baseURL（配对时网关会返回）：https://${TSNAME:-<你的>.ts.net}"
echo "═══════════════════════════════════════════════"
echo "提示：SIP/RTP 会直接走 tailnet。若中间落到 DERP 中继，语音延迟会变高，"
echo "      可用 '$TS ping <iPhone 的 tailnet IP>' 确认是否为 direct 直连。"
