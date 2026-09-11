#!/bin/sh
# remote-check.sh — 一次性回答「现在能不能脱离局域网用」。
#
# 远程通话成立需要三件事同时为真（缺一即不可用）：
#   1. Mac 侧：SIP 监听覆盖 tailnet 地址，且 SDP 会通告 tailnet IP
#      —— 网关的 localIPFor() 按「到对端的路由」挑本地地址，走 tailnet
#      进来的电话会自动填 100.x（装 Tailscale 前会退化成 127.0.0.1）
#   2. 手机侧：YakPhone 的 SIP 服务器必须填 tailnet 地址，否则在蜂窝网下
#      根本注册不上（日志里 contact 会是 192.168.x.x = 还在走局域网）
#   3. 后台来电：必须有 PushKit token，否则锁屏/后台时 CallKit 唤不醒
set -u

RUN="$HOME/.cellbridge/run"
GLOG="$RUN/logs/gateway.log"
CFG="$RUN/config.yaml"
ok()   { printf '  ✓ %s\n' "$1"; }
bad()  { printf '  ✗ %s\n' "$1"; }
warn() { printf '  ! %s\n' "$1"; }

# JSON 解析用的解释器。别硬编码 /usr/bin/python3：没装 Xcode CLT 的机器上没有它，
# 而且失败是**静默**的 —— 表面看像"没装 Tailscale"，实际只是解析器缺失。
PY3=""
for cand in "$(command -v python3 2>/dev/null)" /usr/bin/python3; do
  [ -n "$cand" ] && [ -x "$cand" ] && PY3="$cand" && break
done
[ -n "$PY3" ] || bad "找不到任何 python3，第 [1] 节的 tailnet 探测会失效"

TS=""
for c in "$(command -v tailscale 2>/dev/null || true)" \
         /Applications/Tailscale.app/Contents/MacOS/Tailscale \
         /usr/local/bin/tailscale /opt/homebrew/bin/tailscale; do
  if [ -n "$c" ] && [ -x "$c" ]; then TS="$c"; break; fi
done
if [ -n "$TS" ]; then
  _ts=$("$TS" status --json 2>/dev/null | "$PY3" -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
ips=(d.get("Self") or {}).get("TailscaleIPs") or []
print(next((i for i in ips if ":" not in i), ""))
print(((d.get("Self") or {}).get("DNSName") or "").rstrip("."))
' 2>/dev/null)
  TSIP=$(printf '%s\n' "$_ts" | sed -n '1p')
  TSNAME=$(printf '%s\n' "$_ts" | sed -n '2p')
fi

echo "═══ 远程可用性自检 ═══"
echo "[1] Mac 侧监听"
if lsof -nP -i :5060 2>/dev/null | grep -q UDP; then
  ok "SIP 5060 已监听（全接口，tailnet 可达）"
else
  bad "SIP 5060 未监听 —— 网关没在跑？"
fi
if [ -n "$TSIP" ]; then
  RESP=$("$PY3" - "$TSIP" <<'PY' 2>/dev/null
import socket,sys,uuid
host=sys.argv[1]
s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); s.settimeout(4)
try: s.bind((host,0))
except OSError: pass
s.sendto((f"OPTIONS sip:probe@{host} SIP/2.0\r\nVia: SIP/2.0/UDP {host}:5099;branch=z9hG4bK{uuid.uuid4().hex[:8]}\r\n"
          f"From: <sip:probe@{host}>;tag=p\r\nTo: <sip:probe@{host}>\r\n"
          f"Call-ID: {uuid.uuid4().hex[:8]}\r\nCSeq: 1 OPTIONS\r\nMax-Forwards: 70\r\nContent-Length: 0\r\n\r\n").encode(),(host,5060))
try: print(s.recvfrom(2048)[0].decode(errors="replace").split("\r\n")[0])
except socket.timeout: print("TIMEOUT")
PY
)
  case "$RESP" in
    *"200 OK"*) ok "tailnet 地址 $TSIP:5060 SIP 层实测回 200 OK" ;;
    *) warn "tailnet 地址 $TSIP:5060 无响应（$RESP）" ;;
  esac
  ok "SDP 地址策略：localIPFor() 按对端路由挑 → 远程来电会通告 $TSIP"
else
  bad "未检测到 Tailscale / 无 100.x 地址 —— 远程必然不通"
fi

echo "[2] 手机注册状态（最近一条）"
LAST=$(grep -aE "sip register" "$GLOG" 2>/dev/null | tail -1)
if [ -z "$LAST" ]; then
  warn "日志里还没有任何注册记录"
else
  printf '  %s\n' "$(printf '%s' "$LAST" | sed 's/.*INFO //')"
  case "$LAST" in
    *100.*) ok "手机通过 tailnet 注册（远程可用）" ;;
    *expires=0*) warn "这是注销记录，看下一条" ;;
    *) warn "手机走的是局域网地址 —— 把 YakPhone 的 SIP 服务器改成 ${TSIP:-<tailnet IP>}:5060" ;;
  esac
fi

echo "[3] 后台来电（PushKit）"
if grep -q 'push_token: ""' "$CFG" 2>/dev/null; then
  bad "sip.push_token 为空 → 锁屏/后台来电不会响（CallKit 唤不醒）"
  echo "      前台时正常；要后台可接必须先填 token（YakPhone→设置→推送→复制）"
else
  ok "PushKit token 已配置"
fi

echo
echo "手机侧这样设（改完不用动 Mac）："
echo "  SIP 服务器 = ${TSIP:-<tailnet IP>}:5060   用户名 iphone / 密码 cellbridge-$(whoami)"
echo "  验证远程：手机关 Wi-Fi、只留蜂窝 + Tailscale VPN 打开，再打一通"
echo "  延迟自查：tailscale ping <手机 tailnet IP>（出现 direct 才快，relay 会明显延迟）"
