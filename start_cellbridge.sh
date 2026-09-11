#!/bin/bash
# start_cellbridge.sh — 在 Mac 上启动 CellBridge SIP 网关（DJiPhone Kit 的 iPhone 通话伴侣）
#
# 组件：
#   1. at_pty_bridge.py     USB AT ↔ PTY 串口桥（互斥：会先退出 DJiPhone Kit App）
#   2. voice-audio-bridge   蜂窝 UAC 音频 ↔ FIFO（CellBridge raw-pcm 后端）
#   3. cellbridge-gateway   SIP 服务器 + 短信引擎（iPhone 经 SIP/Tailscale 接入）
#
# 前提：模块侧语音运行时已部署（语音路由 ready）。
#   若刚重启过模块，请先打开 DJiPhone Kit.app 让它自动部署一次，再跑本脚本。
#
# 用法：./start_cellbridge.sh          启动（Ctrl+C 停止全部组件）
#       ./start_cellbridge.sh stop     停止全部组件

set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
RUN="$HOME/.cellbridge/run"
DATA="$HOME/.cellbridge/data"
LOG="$RUN/logs"
PY="${PYTHON:-}"
if [ -z "$PY" ] || [ ! -x "$PY" ] || ! "$PY" -c "import usb.core" >/dev/null 2>&1; then
  PY=""
  for cand in \
    "$HOME/.workbuddy/binaries/python/envs/default/bin/python3" \
    /opt/homebrew/bin/python3 \
    /usr/local/bin/python3 \
    "$(command -v python3 2>/dev/null)" \
    /usr/bin/python3
  do
    [ -n "$cand" ] && [ -x "$cand" ] || continue
    if "$cand" -c "import usb.core" >/dev/null 2>&1; then PY="$cand"; break; fi
    [ -z "$PY" ] && PY="$cand"
  done
fi
if [ -z "$PY" ] || [ ! -x "$PY" ]; then
  echo "找不到 python3，请安装（brew install python3）或设置 PYTHON=/path/to/python3"; exit 1
fi
"$PY" -c "import usb.core" >/dev/null 2>&1 \
  || echo "警告：$PY 缺少 pyusb，AT 桥会失败。安装：$PY -m pip install --user pyusb"

PY3=""
for cand in "$PY" "$(command -v python3 2>/dev/null)" /usr/bin/python3; do
  [ -n "$cand" ] && [ -x "$cand" ] && PY3="$cand" && break
done
APP_PY="$DIR/at_pty_bridge.py"
BRIDGE="$DIR/voice-audio-bridge"
GATEWAY="$DIR/cellbridge-gateway"
SIP_USER="${SIP_USER:-iphone}"
SIP_USER2="${SIP_USER2:-sheldon}"

mkdir -p "$RUN" "$DATA" "$LOG"

# SIP 口令：不再硬编码弱口令（仓库公开后 cellbridge-idoer 等于明文）。
# 优先级：环境变量 SIP_PASS/SIP_PASS2 > 持久化文件 ~/.cellbridge/run/sip-passwords > 首次随机生成。
PASS_FILE="$RUN/sip-passwords"
_read_pass() { # _read_pass <key>
  [ -f "$PASS_FILE" ] || return 1
  grep -E "^${1}=" "$PASS_FILE" 2>/dev/null | head -1 | cut -d= -f2-
}
_gen_pass() { LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c 16; }
if [ -z "${SIP_PASS:-}" ]; then SIP_PASS="$(_read_pass "$SIP_USER")"; fi
if [ -z "${SIP_PASS2:-}" ]; then SIP_PASS2="$(_read_pass "$SIP_USER2")"; fi
if [ -z "$SIP_PASS" ] || [ -z "$SIP_PASS2" ]; then
  [ -z "$SIP_PASS" ] && SIP_PASS="$(_gen_pass)"
  [ -z "$SIP_PASS2" ] && SIP_PASS2="$(_gen_pass)"
  {
    echo "# CellBridge SIP 口令（由 start_cellbridge.sh 生成，chmod 600）"
    echo "# 修改：编辑本文件或用环境变量 SIP_PASS/SIP_PASS2 覆盖后重启"
    echo "$SIP_USER=$SIP_PASS"
    echo "$SIP_USER2=$SIP_PASS2"
  } > "$PASS_FILE"
  chmod 600 "$PASS_FILE"
  echo "已生成新 SIP 口令并保存到 $PASS_FILE（Linphone 需用下方新口令重新登录一次）"
fi

_remote_watchdog_pids() {
  command -v adb >/dev/null 2>&1 || return 0
  adb shell 'for d in /proc/[0-9]*; do
    [ -r "$d/cmdline" ] || continue
    x=$(tr "\000" " " < "$d/cmdline" 2>/dev/null)
    x=${x% }
    case "$x" in
      "/bin/busybox /bin/sh /data/voice-route-watchdog.sh"|"/bin/sh /data/voice-route-watchdog.sh"|"/system/bin/sh /data/voice-route-watchdog.sh")
        echo "${d#/proc/}" ;;
    esac
  done' 2>/dev/null
}

kill_remote_watchdog() {
  local pids n=0
  pids="$(_remote_watchdog_pids)"
  if [ -z "$pids" ]; then echo 0; return 0; fi
  for p in $pids; do
    adb shell "kill -9 $p" >/dev/null 2>&1 && n=$((n + 1))
  done
  echo "$n"
}

if [ "${1:-}" = "stop" ]; then
  for pat in "cellbridge-gateway" "voice-audio-bridge" "at_pty_bridge.py" "[r]oute-rearm.sh"; do
    pkill -f "$pat" 2>/dev/null && echo "已停止 $pat"
  done
  # voice-audio-bridge 卡在 FIFO open() 时 SIGTERM 杀不死，等 1s 后补 SIGKILL
  sleep 1
  for pat in "voice-audio-bridge" "cellbridge-gateway" "at_pty_bridge.py"; do
    pkill -9 -f "$pat" 2>/dev/null && echo "强制清理残留 $pat（SIGKILL）"
  done
  KILLED="$(kill_remote_watchdog)"
  [ -n "${KILLED:-}" ] && [ "$KILLED" != "0" ] && echo "已清理模块侧 watchdog 实例 × $KILLED"
  exit 0
fi

for f in "$APP_PY" "$BRIDGE" "$GATEWAY"; do
  if [ ! -f "$f" ]; then
    echo "缺少组件: $f"; echo "请先运行构建（见 README-mac.md）"; exit 1
  fi
done

if pgrep -f "DJiPhone Kit.app" >/dev/null 2>&1; then
  echo "DJiPhone Kit App 正在运行（占用 USB AT 接口），先退出它..."
  pkill -f "DJiPhone Kit.app" 2>/dev/null
  sleep 2
fi

"$0" stop >/dev/null 2>&1
sleep 1

find_voiceruntime() {
  for d in "$DIR/voice-runtime" "$DIR/module-tools/voice-runtime"; do
    if [ -f "$d/qdc507_aprv3.ko" ] && [ -f "$d/qdc507_voice.ko" ]; then
      echo "$d"; return 0
    fi
  done
  return 1
}

if command -v adb >/dev/null 2>&1 || [ -x "$HOME/Applications/platform-tools/adb" ]; then
  export PATH="$HOME/Applications/platform-tools:$PATH"
  if adb shell 'ls /dev/snd/controlC0 >/dev/null 2>&1'; then
    echo "    模块声卡正常"
  elif KO_DIR="$(find_voiceruntime)"; then
    echo "    模块声卡缺失（模块重启过？）→ 自动加载驱动…"
    adb push "$KO_DIR/qdc507_aprv3.ko" /data/qdc507_aprv3.ko >/dev/null 2>&1
    adb push "$KO_DIR/qdc507_voice.ko" /data/qdc507_voice.ko >/dev/null 2>&1
    if adb shell 'insmod /data/qdc507_aprv3.ko && insmod /data/qdc507_voice.ko' 2>/dev/null \
       && adb shell 'ls /dev/snd/controlC0 >/dev/null 2>&1'; then
      echo "    声卡驱动已加载（qdc507_aprv3 + qdc507_voice）"
      sleep 1
    else
      echo "    警告：声卡驱动加载失败（通话可能无蜂窝音频，重启模块后重试）"
    fi
  else
    echo "    警告：声卡 .ko 缺失（可跑 module-tools/voice_runtime.py 部署），声卡缺失时无法自愈"
  fi
fi

echo "[0/3] 写入语音路由（AFE_PCM ↔ 全部语音会话类型）..."
if command -v adb >/dev/null 2>&1 || [ -x "$HOME/Applications/platform-tools/adb" ]; then
  export PATH="$HOME/Applications/platform-tools:$PATH"
  adb shell '
    [ -x /data/mini_tinymix ] || exit 0
    T=/data/mini_tinymix
    $T set "AFE_PCM_RX_Voice Mixer CSVoice" 1
    $T set "AFE_PCM_RX_Voice Mixer VoLTE" 1
    $T set "AFE_PCM_RX_Voice Mixer VoiceMMode1" 1
    $T set "AFE_PCM_RX_Voice Mixer VoiceMMode2" 1
    $T set "Voice_Tx Mixer AFE_PCM_TX_Voice" 1
    $T set "VoLTE_Tx Mixer AFE_PCM_TX_VoLTE" 1
    $T set "VoiceMMode1_Tx Mixer AFE_PCM_TX_MMode1" 1
    $T set "VoiceMMode2_Tx Mixer AFE_PCM_TX_MMode2" 1
  ' 2>/dev/null && echo "    语音路由已写入" || echo "    警告：语音路由写入失败（模块未连接？）"
  "$DIR/mavo-route.sh" start 2>/dev/null | sed 's/^/    /' || true
  adb shell 'pidof mavo-pcm-bridge >/dev/null && echo "    mavo-pcm-bridge 运行中" || echo "    警告：mavo-pcm-bridge 未运行"' 2>/dev/null
  adb shell 'cat > /data/voice-route-watchdog.sh <<EOF
#!/system/bin/sh
T=/data/mini_tinymix
PROBE="AFE_PCM_RX_Voice Mixer CSVoice"
apply_all() {
  \$T set "AFE_PCM_RX_Voice Mixer CSVoice" 1
  \$T set "AFE_PCM_RX_Voice Mixer VoLTE" 1
  \$T set "AFE_PCM_RX_Voice Mixer VoiceMMode1" 1
  \$T set "AFE_PCM_RX_Voice Mixer VoiceMMode2" 1
  \$T set "Voice_Tx Mixer AFE_PCM_TX_Voice" 1
  \$T set "VoLTE_Tx Mixer AFE_PCM_TX_VoLTE" 1
  \$T set "VoiceMMode1_Tx Mixer AFE_PCM_TX_MMode1" 1
  \$T set "VoiceMMode2_Tx Mixer AFE_PCM_TX_MMode2" 1
}
verify_all() {
  for r in "AFE_PCM_RX_Voice Mixer CSVoice" "AFE_PCM_RX_Voice Mixer VoLTE" "AFE_PCM_RX_Voice Mixer VoiceMMode1" "AFE_PCM_RX_Voice Mixer VoiceMMode2" "Voice_Tx Mixer AFE_PCM_TX_Voice" "VoLTE_Tx Mixer AFE_PCM_TX_VoLTE" "VoiceMMode1_Tx Mixer AFE_PCM_TX_MMode1" "VoiceMMode2_Tx Mixer AFE_PCM_TX_MMode2"; do
    v=\$(\$T get "\$r" 2>/dev/null)
    [ "\$v" = "1" ] || \$T set "\$r" 1
  done
}
i=0
while true; do
  v=\$(\$T get "\$PROBE" 2>/dev/null)
  if [ "\$v" != "1" ]; then apply_all
  elif [ \$((i % 6)) -eq 0 ]; then verify_all; fi
  i=\$((i + 1)); sleep 10
done
EOF
chmod +x /data/voice-route-watchdog.sh' 2>/dev/null
  OLD="$(kill_remote_watchdog)"
  [ -n "${OLD:-}" ] && [ "$OLD" != "0" ] && echo "    已回收遗留 watchdog × $OLD"
  adb shell sh /data/voice-route-watchdog.sh > /dev/null 2>&1 &
  sleep 2
  WN="$(_remote_watchdog_pids | wc -l | tr -d ' ')"
  if [ "${WN:-0}" -ge 1 ]; then
    echo "    语音路由 watchdog 运行中（Mac 托管，10s 探测 / 仅复位时补写）"
  else
    echo "    警告：watchdog 未启动（通话挂断后语音路由可能不被修复）"
  fi
  pkill -f "[r]oute-rearm.sh" 2>/dev/null
  i=0
  while [ "$i" -lt 24 ]; do
    pgrep -f "[r]oute-rearm.sh" > /dev/null 2>&1 || break
    sleep 0.25; i=$((i + 1))
  done
  HB="$RUN/logs/route-rearm.heartbeat"
  rm -f "$HB"
  nohup "$DIR/route-rearm.sh" > /dev/null 2>&1 &
  i=0
  while [ "$i" -lt 20 ]; do
    sleep 0.5; [ -f "$HB" ] && break; i=$((i + 1))
  done
  if [ -f "$HB" ]; then
    echo "    通话后自动重挂路由会话 已启用（心跳正常，日志 route-rearm.log）"
  else
    echo "    警告：route-rearm 心跳未出现（第二通起可能无蜂窝音频）"
    echo "          排查：tail -20 $RUN/logs/route-rearm.log"
  fi
else
  echo "    警告：找不到 adb，跳过 CS 路由写入"
fi

RX_FIFO="$RUN/cellular-rx.fifo"
TX_FIFO="$RUN/cellular-tx.fifo"
rm -f "$RX_FIFO" "$TX_FIFO"
mkfifo "$RX_FIFO" "$TX_FIFO"

echo "[1/3] 启动 AT PTY 桥..."
"$PY" "$APP_PY" > "$RUN/pty_path.txt" 2> "$LOG/at-pty.log" &
TTY_PATH=""
i=0
while [ "$i" -lt 30 ]; do
  sleep 0.5
  TTY_PATH=$(head -1 "$RUN/pty_path.txt" 2>/dev/null)
  [ -n "$TTY_PATH" ] && break
  i=$((i + 1))
done
if [ -z "$TTY_PATH" ]; then
  echo "AT PTY 桥未输出串口路径（等待 15s），查看 $LOG/at-pty.log"; exit 1
fi
echo "    模块串口: $TTY_PATH"

export CB_AUDIO_IDLE_SUSPEND="${CB_AUDIO_IDLE_SUSPEND:-1}"
export CB_AUDIO_IDLE_SECONDS="${CB_AUDIO_IDLE_SECONDS:-10}"
echo "[2/3] 启动音频桥（FIFO 模式，空闲挂起=${CB_AUDIO_IDLE_SUSPEND}，阈值=${CB_AUDIO_IDLE_SECONDS}s）..."
"$BRIDGE" --fifo-rx "$RX_FIFO" --fifo-tx "$TX_FIFO" --verbose \
  > /dev/null 2> "$LOG/audio-bridge.log" &

export CELLBRIDGE_SMS_DRY_RUN="${CELLBRIDGE_SMS_DRY_RUN:-false}"
export CELLBRIDGE_SMS_POLL_INTERVAL="${CELLBRIDGE_SMS_POLL_INTERVAL:-5s}"

PUSH_TOKEN="${YAK_PUSH_TOKEN:-}"
PUSH_TOKEN_FILE="$HOME/.cellbridge/push_token"
if [ -z "$PUSH_TOKEN" ] && [ -f "$PUSH_TOKEN_FILE" ]; then
  PUSH_TOKEN="$(tr -d '[:space:]' < "$PUSH_TOKEN_FILE")"
fi

TS_CLI=""
for c in \
  "$(command -v tailscale 2>/dev/null || true)" \
  /Applications/Tailscale.app/Contents/MacOS/Tailscale \
  /usr/local/bin/tailscale \
  /opt/homebrew/bin/tailscale
do
  [ -n "$c" ] && [ -x "$c" ] && TS_CLI="$c" && break
done
TAILNET_IP=""; TAILNET_NAME=""
if [ -n "$TS_CLI" ]; then
  _ts=$(printf '%s' "$("$TS_CLI" status --json 2>/dev/null)" | "$PY3" -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
ips=(d.get("Self") or {}).get("TailscaleIPs") or []
print(next((i for i in ips if ":" not in i), ""))
print(((d.get("Self") or {}).get("DNSName") or "").rstrip("."))
' 2>/dev/null)
  TAILNET_IP=$(printf '%s\n' "$_ts" | sed -n '1p')
  TAILNET_NAME=$(printf '%s\n' "$_ts" | sed -n '2p')
fi
case "$TAILNET_NAME" in
  *.ts.net) TAILNET_LINE="  tailnet_hostname: $TAILNET_NAME" ;;
  *) TAILNET_NAME=""; TAILNET_LINE="" ;;
esac
LAN_IP="$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || true)"

echo "[3/3] 启动 CellBridge 网关... (SMS_DRY_RUN=$CELLBRIDGE_SMS_DRY_RUN)"
if [ -n "$PUSH_TOKEN" ]; then
  echo "    PushKit token: 已配置（${#PUSH_TOKEN} 字符）→ 来电可唤醒 CallKit"
else
  echo "    PushKit token: 未配置 —— 后台来电不会振铃（CallKit 需要 VoIP 推送）"
  echo "                   把 YakPhone 的 Push Token 写入 $PUSH_TOKEN_FILE 后重启本脚本"
fi
cat > "$RUN/config.yaml" << EOF
# 由 start_cellbridge.sh 生成
network:
  mode: tailnet
  transport: tailnet
$TAILNET_LINE
server:
  listen: 127.0.0.1:8787
data:
  dir: $DATA
modem:
  adapter: at
  tty: $TTY_PATH
  baud: 9600
voice:
  enabled: true
  backend: raw-pcm
  rx_path: $RX_FIFO
  tx_path: $TX_FIFO
  sample_rate: 8000
sip:
  enabled: true
  listen: 0.0.0.0:5060
  realm: cellbridge
  push_token: "$PUSH_TOKEN"
  users:
    - username: $SIP_USER
      password: $SIP_PASS
    - username: $SIP_USER2
      password: $SIP_PASS2
recording:
  enabled: false
EOF

# Linphone 锁屏来电推送（FlexiAPI x-api-key）
if [ -f "$HOME/.cellbridge/linphone_push_key" ]; then
  export CB_LINPHONE_PUSH_KEY="$(head -1 "$HOME/.cellbridge/linphone_push_key" | tr -d '[:space:]')"
  [ -f "$HOME/.cellbridge/linphone_push_from" ] && export CB_LINPHONE_FROM="$(head -1 "$HOME/.cellbridge/linphone_push_from" | tr -d '[:space:]')"
  [ -f "$HOME/.cellbridge/linphone_push_url" ] && export CB_LINPHONE_PUSH_URL="$(head -1 "$HOME/.cellbridge/linphone_push_url" | tr -d '[:space:]')"
fi

"$GATEWAY" -config "$RUN/config.yaml" > "$LOG/gateway.log" 2>&1 &
GWPID=$!

i=0
READY=0
while [ "$i" -lt 40 ]; do
  sleep 0.5
  kill -0 $GWPID 2>/dev/null || break
  if curl -s -m 1 --noproxy '*' http://127.0.0.1:8787/api/v1/health 2>/dev/null | grep -q '"status":"ok"'; then
    READY=1; break
  fi
  i=$((i + 1))
done
if ! kill -0 $GWPID 2>/dev/null; then
  echo "网关启动失败，日志："; tail -20 "$LOG/gateway.log"; exit 1
fi
[ "$READY" = "1" ] || echo "    警告：网关进程在，但 health 接口 20s 内未就绪（可能仍在初始化，或 8787 被占用）"

echo ""
echo "═══════════════════════════════════════════════"
echo " CellBridge 网关已启动"
echo "   SIP:     0.0.0.0:5060（局域网/Tailscale 可达）"
echo "   账号:    $SIP_USER / $SIP_PASS"
echo "   控制台:  http://127.0.0.1:8787"
echo "   日志:    $LOG/"
echo "═══════════════════════════════════════════════"
echo "iPhone 端（Linphone 等 SIP 客户端）："
if [ -n "$TAILNET_IP" ]; then
  echo "   服务器 = $TAILNET_IP:5060（Tailscale，外网/蜂窝网可用）"
  [ -n "$LAN_IP" ] && echo "           或 $LAN_IP:5060（同一局域网）"
else
  echo "   服务器 = ${LAN_IP:-<Mac 的 IP>}:5060（仅同一局域网）"
  echo "   想在外网使用：安装 Tailscale 后跑 ./tailnet-setup.sh serve"
fi
echo "   用户名/密码如上。停止：./start_cellbridge.sh stop"
echo ""
trap 'echo "停止全部组件..."; "$0" stop' INT TERM
wait $GWPID 2>/dev/null
"$0" stop
