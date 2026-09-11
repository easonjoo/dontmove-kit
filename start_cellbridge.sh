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
  # 优先挑已经装了 pyusb 的解释器；都不行就取第一个可用的（AT 桥启动时会报错）
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

# 解析 JSON（tailscale status）用的解释器：只用标准库 json，随便哪个 python3 都行。
# 不要硬编码 /usr/bin/python3 —— 没装 Xcode CLT 的机器上它可能不存在，
# 而失败是**静默**的（探测不到 tailnet → 退化成纯局域网，用户以为"远程坏了"）。
PY3=""
for cand in "$PY" "$(command -v python3 2>/dev/null)" /usr/bin/python3; do
  [ -n "$cand" ] && [ -x "$cand" ] && PY3="$cand" && break
done
APP_PY="$DIR/at_pty_bridge.py"
BRIDGE="$DIR/voice-audio-bridge"
GATEWAY="$DIR/cellbridge-gateway"
SIP_USER="${SIP_USER:-iphone}"
SIP_PASS="${SIP_PASS:-cellbridge-$(id -un)}"
# 第二分机：出门经 Tailscale 注册用（tailnet 内 WireGuard 加密，弱口令可接受）
SIP_USER2="${SIP_USER2:-remote}"
SIP_PASS2="${SIP_PASS2:-cellbridge-remote-$(id -un)}"

mkdir -p "$RUN" "$DATA" "$LOG"

# 列出模块上真正在跑的语音路由 watchdog 进程 PID。
# 必须精确匹配 cmdline：宽松匹配（grep voice-route-watchdog）会把探测命令
# 自身以及 `sh -c '...'` 包装进程也算进去，导致"看着有、实际没有"的误判。
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

# 回收模块侧的 watchdog。它由 Mac 侧 adb 会话托管，stop 时必须显式清理，
# 否则每启动一次就泄漏一个循环，长期值守下持续唤醒模块 CPU → 发热。
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
  # 注意 "[r]oute-rearm.sh" 的方括号写法：pkill -f 匹配整条命令行，
  # 若写成 "route-rearm.sh"，执行本脚本的 shell 自身 cmdline 也会命中而被杀。
  for pat in "cellbridge-gateway" "voice-audio-bridge" "at_pty_bridge.py" "[r]oute-rearm.sh"; do
    pkill -f "$pat" 2>/dev/null && echo "已停止 $pat"
  done
  KILLED="$(kill_remote_watchdog)"
  [ -n "${KILLED:-}" ] && [ "$KILLED" != "0" ] && echo "已清理模块侧 watchdog 实例 × $KILLED"
  exit 0
fi

# --- 前置检查（放在最前：组件缺失时不该先白折腾一遍模块）---
for f in "$APP_PY" "$BRIDGE" "$GATEWAY"; do
  if [ ! -f "$f" ]; then
    echo "缺少组件: $f"; echo "请先运行构建（见 README-mac.md）"; exit 1
  fi
done

# App 占用 USB AT 接口，必须先退出
if pgrep -f "DJiPhone Kit.app" >/dev/null 2>&1; then
  echo "DJiPhone Kit App 正在运行（占用 USB AT 接口），先退出它..."
  pkill -f "DJiPhone Kit.app" 2>/dev/null
  sleep 2
fi

# --- 清理旧实例 ---
# ⚠️ 本段必须留在「启动任何组件」之前。stop 分支里含 `pkill -f "[r]oute-rearm.sh"`，
# 历史实现把它放在 watchdog / rearm 启动之后，于是**每次启动都会把刚拉起的 rearm
# 杀掉**；而那时的存活检查在 kill 之前跑，横幅照样打印「通话后自动重挂路由会话
# 已启用」——守护实际已死。后果是此后每通电话结束都不重挂，表现为
# 「重启后第一通正常、之后全哑」，且重启服务也修不好（因为又被杀一遍）。
"$0" stop >/dev/null 2>&1
sleep 1

# find_voiceruntime — 在两处可能的位置找声卡 .ko：
#   ① 仓库根 voice-runtime/（手动放置或旧布局）
#   ② module-tools/voice-runtime/（voice_runtime.py provision_runtime() 的部署目标）
find_voiceruntime() {
  for d in "$DIR/voice-runtime" "$DIR/module-tools/voice-runtime"; do
    if [ -f "$d/qdc507_aprv3.ko" ] && [ -f "$d/qdc507_voice.ko" ]; then
      echo "$d"; return 0
    fi
  done
  return 1
}

# --- 模块声卡驱动自愈 ---
# 模块（QDC507）重启后内核模块全部清空，声卡 .ko 不会自动加载，表现为
# /proc/asound/cards 报 "no soundcards"、tinymix 全部写不进、通话蜂窝侧
# 全零静音。这里检测到声卡缺失时自动推驱动 + insmod（驱动在 voice-runtime/，
# insmod 顺序必须是先 aprv3 后 voice）。
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

# --- 语音路由（01.001.02.004 固件，会话类型含 CSVoice/VoLTE/VoiceMMode）---
# 模块重启后 mixer 复位，每次启动时重新写入；mini_tinymix 由 module-tools 交叉编译
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
  # mavo-pcm-bridge：DSP VoLTE ↔ UAC/USB 的用户态桥（缺它则通话全零静音）。
  # 注意：必须用 pidof 精确匹配（pgrep -f 会自匹配 adb shell 命令行造成假阳性）；
  # 二进制用 nohup 启动可在 adb shell 退出后存活。
  #
  # 实测（2026-09-10）：该桥的 --voice-route-session 只对「第一通」电话生效，
  # 之后 DSP 不再往 hw:0,4 送数据 → 蜂窝侧全零、双向哑。故启动时必须**强制
  # 重挂**（旧实现「已在跑就跳过」，导致重启整套服务也修不好第二通）。
  "$DIR/mavo-route.sh" start 2>/dev/null | sed 's/^/    /' || true
  adb shell 'pidof mavo-pcm-bridge >/dev/null && echo "    mavo-pcm-bridge 运行中" || echo "    警告：mavo-pcm-bridge 未运行"' 2>/dev/null
  # 部署路由自愈脚本到模块（每次覆盖写入，保证内容升级能生效）
  #
  # 散热优化：原实现每 3 秒无条件 set 8 条路由，模块 CPU/DSP 被持续唤醒。
  # 现改为「先 get 探一条代表性路由 → 只有被 DSP 复位时才全量补写」，
  # 并每 6 轮（≈60s）做一次全量校验兜底。稳态下每 10 秒仅 1 次 get。
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
  if [ "\$v" != "1" ]; then
    apply_all
  elif [ \$((i % 6)) -eq 0 ]; then
    verify_all
  fi
  i=\$((i + 1))
  sleep 10
done
EOF
chmod +x /data/voice-route-watchdog.sh' 2>/dev/null
  # 语音路由 watchdog：通话挂断时 DSP 会把 VoLTE 路由复位，需补写。
  # 必须从 Mac 侧用持久 adb 会话托管（模块侧 nohup/setsid 启动的 shell 脚本
  # 会随 adb shell 退出被杀，二进制则可存活）。
  #
  # 单例化：先回收模块上遗留的旧 watchdog 实例。历史实现每次启动都新起一个
  # 且 stop 不回收，长期值守会累积成多个循环叠加（实测发现同时跑 2 个）。
  OLD="$(kill_remote_watchdog)"
  [ -n "${OLD:-}" ] && [ "$OLD" != "0" ] && echo "    已回收遗留 watchdog × $OLD"
  adb shell sh /data/voice-route-watchdog.sh > /dev/null 2>&1 &
  sleep 2
  # 用实际进程数确认（`kill -0 $!` 只说明 adb 客户端还在，不能证明模块侧循环活着）
  WN="$(_remote_watchdog_pids | wc -l | tr -d ' ')"
  if [ "${WN:-0}" -ge 1 ]; then
    echo "    语音路由 watchdog 运行中（Mac 托管，10s 探测 / 仅复位时补写）"
  else
    echo "    警告：watchdog 未启动（通话挂断后语音路由可能不被修复）"
  fi
  # 通话结束后重挂模块侧 VoLTE 路由会话（mavo-pcm-bridge 的 route session
  # 是一次性的：不重挂则第二通起蜂窝侧全零静音）。详见 route-rearm.sh。
  # 方括号写法与 stop 分支同理：pkill -f 匹配整条命令行，裸写
  # "route-rearm.sh" 会把「命令行里恰好含这个字符串」的调用者（例如
  # 在终端里执行 ./start_cellbridge.sh 的那个 shell）一起杀掉。
  # ⚠️ 两个必做的等待，都是踩过的坑：
  #   ① pkill 之后必须**等旧实例真正退出**再启动新的。新实例一启动就去抢
  #      单例锁（route-rearm.lock），此时旧实例若还没被回收，它会判定
  #      「已有实例在运行」直接 exit —— 新旧都没了，表现是「重启完 rearm
  #      反而不在跑」。窗口虽小，但在慢机器/沙箱里实测会命中。
  #   ② 存活判据必须是**心跳文件**而不是 pgrep：进程在 ≠ 循环在转，
  #      本项目已被「进程看着在、实际没干活」误导过多次。
  pkill -f "[r]oute-rearm.sh" 2>/dev/null
  i=0
  while [ "$i" -lt 24 ]; do
    pgrep -f "[r]oute-rearm.sh" > /dev/null 2>&1 || break
    sleep 0.25
    i=$((i + 1))
  done
  HB="$RUN/logs/route-rearm.heartbeat"
  rm -f "$HB"
  nohup "$DIR/route-rearm.sh" > /dev/null 2>&1 &
  i=0
  while [ "$i" -lt 20 ]; do
    sleep 0.5
    [ -f "$HB" ] && break
    i=$((i + 1))
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

# --- FIFO ---
RX_FIFO="$RUN/cellular-rx.fifo"
TX_FIFO="$RUN/cellular-tx.fifo"
rm -f "$RX_FIFO" "$TX_FIFO"
mkfifo "$RX_FIFO" "$TX_FIFO"

# --- 组件 1：AT PTY 桥 ---
echo "[1/3] 启动 AT PTY 桥..."
"$PY" "$APP_PY" > "$RUN/pty_path.txt" 2> "$LOG/at-pty.log" &
# 轮询等串口路径出现，而不是固定 sleep：正常 1~2s 就有，慢机器最多等 15s。
# 固定等待两头不讨好 —— 快机器上白等，慢机器（或沙箱里）又不够。
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

# --- 组件 2：音频桥（FIFO 模式）---
# 散热开关（均可用环境变量覆盖）：
#   CB_AUDIO_IDLE_SUSPEND  1=无通话时暂停 AudioUnit（默认，省电降热）
#   CB_AUDIO_IDLE_SECONDS  空闲超过多久后暂停（默认 10 秒）
# 原理：空闲时音频桥仍以 ~8000 fr/s 双向全速搬运，模块 UAC 端点被 USB
# 主机持续轮询、无法进入低功耗，是长期值守的主要热源之一。暂停后由
# tx FIFO 出现数据（网关通话时每 20ms 写一帧）自动唤醒。
export CB_AUDIO_IDLE_SUSPEND="${CB_AUDIO_IDLE_SUSPEND:-1}"
export CB_AUDIO_IDLE_SECONDS="${CB_AUDIO_IDLE_SECONDS:-10}"
echo "[2/3] 启动音频桥（FIFO 模式，空闲挂起=${CB_AUDIO_IDLE_SUSPEND}，阈值=${CB_AUDIO_IDLE_SECONDS}s）..."
"$BRIDGE" --fifo-rx "$RX_FIFO" --fifo-tx "$TX_FIFO" --verbose \
  > /dev/null 2> "$LOG/audio-bridge.log" &

# --- 组件 3：网关 ---
# 真实短信（不设则默认 dry-run）
export CELLBRIDGE_SMS_DRY_RUN="${CELLBRIDGE_SMS_DRY_RUN:-false}"
# 短信收件箱轮询间隔。默认 5s 保持原有及时性；长期值守想进一步降热可设
# CELLBRIDGE_SMS_POLL_INTERVAL=30s（代价：收到短信最多延迟该时长）。
export CELLBRIDGE_SMS_POLL_INTERVAL="${CELLBRIDGE_SMS_POLL_INTERVAL:-5s}"

# --- PushKit token（来电 CallKit 振铃 / 短信通知唤醒的必要条件）---
# 获取方式：YakPhone → 设置 → 推送/Push 页 → 复制 Push Token（形如 AAA...==）。
# 把 token 粘进 $HOME/.cellbridge/push_token 即可，无需手改 config.yaml。
# 不填的后果：App 在前台时 SIP INVITE 仍能振铃，但 App 挂起/后台时
# 来电不会有任何反应（CallKit 靠 VoIP 推送唤醒）。
PUSH_TOKEN="${YAK_PUSH_TOKEN:-}"
PUSH_TOKEN_FILE="$HOME/.cellbridge/push_token"
if [ -z "$PUSH_TOKEN" ] && [ -f "$PUSH_TOKEN_FILE" ]; then
  PUSH_TOKEN="$(tr -d '[:space:]' < "$PUSH_TOKEN_FILE")"
fi

# --- 组网信息（Tailscale 可选，装了就自动启用外网访问）---
# 有 Tailscale 时把 MagicDNS 名写进 network.tailnet_hostname：配对接口据此
# 返回 baseURL=https://<名字>.ts.net，手机 App 才能从局域网外接入（详见
# ./tailnet-setup.sh）。没装则留空 —— 配置校验只要求它为空或 *.ts.net。
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
try:
    d=json.load(sys.stdin)
except Exception:
    sys.exit(0)
ips=(d.get("Self") or {}).get("TailscaleIPs") or []
print(next((i for i in ips if ":" not in i), ""))
print(((d.get("Self") or {}).get("DNSName") or "").rstrip("."))
' 2>/dev/null)
  TAILNET_IP=$(printf '%s\n' "$_ts" | sed -n '1p')
  TAILNET_NAME=$(printf '%s\n' "$_ts" | sed -n '2p')
fi
# 校验要求 *.ts.net，否则网关会拒绝启动，这里直接拦掉
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

# Linphone 锁屏来电推送（FlexiAPI x-api-key，见 set-linphone-push.sh）
if [ -f "$HOME/.cellbridge/linphone_push_key" ]; then
  export CB_LINPHONE_PUSH_KEY="$(head -1 "$HOME/.cellbridge/linphone_push_key" | tr -d '[:space:]')"
  [ -f "$HOME/.cellbridge/linphone_push_from" ] && export CB_LINPHONE_FROM="$(head -1 "$HOME/.cellbridge/linphone_push_from" | tr -d '[:space:]')"
  [ -f "$HOME/.cellbridge/linphone_push_url" ] && export CB_LINPHONE_PUSH_URL="$(head -1 "$HOME/.cellbridge/linphone_push_url" | tr -d '[:space:]')"
fi

"$GATEWAY" -config "$RUN/config.yaml" > "$LOG/gateway.log" 2>&1 &
GWPID=$!

# 就绪判据 = 进程活着 **且** health 接口应答。固定 sleep 6 有两个盲区：
# 快机器上白等，慢机器上「进程在、接口还没起来」就被当成成功了。
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
echo "iPhone 端（YakPhone 等 SIP 客户端）："
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
