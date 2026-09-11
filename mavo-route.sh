#!/bin/sh
# mavo-route.sh — 模块侧 VoLTE 路由会话（mavo-pcm-bridge）的生命周期管理。
#
# 背景（2026-09-10 实测定位）：
#   mavo-pcm-bridge --voice-route-session 打开 hw:0,4 后常驻，但**只对第一通
#   电话生效**：之后所有通话 DSP 都不再往该设备送数据，网关侧表现为
#   `voice cellular stats ... nonzero=0 mean=0`（不管呼入呼出，双向全哑）。
#   判别实验：Mac 侧完全不动、只重启这个桥，下一通立刻恢复
#   （cellular nonzero 2060/2150，mean≈837）。
#   因此必须「空闲时重新挂载」：每通电话结束后重新起一个实例。
#
# 用法：
#   mavo-route.sh start    重新挂载（已在跑则先 SIGTERM 等清理，再启动新实例）
#   mavo-route.sh stop     停止
#   mavo-route.sh status   打印 PID 与远端最近日志
set -u

ADB="$(command -v adb 2>/dev/null || true)"
if [ -z "$ADB" ] && [ -x "$HOME/Applications/platform-tools/adb" ]; then
  ADB="$HOME/Applications/platform-tools/adb"
fi
if [ -z "$ADB" ] || [ ! -x "$ADB" ]; then
  echo "mavo-route: 找不到 adb（PATH 与 ~/Applications/platform-tools 都没有）" >&2
  exit 1
fi

BRIDGE=/data/mavo-pcm-bridge
RLOG=/data/mavo-bridge.log

pids() { "$ADB" shell pidof mavo-pcm-bridge 2>/dev/null | tr -d '\r'; }

case "${1:-start}" in
  stop)
    P="$(pids)"
    if [ -z "$P" ]; then echo "mavo-route: 未在运行"; exit 0; fi
    "$ADB" shell "kill $P" >/dev/null 2>&1
    echo "mavo-route: 已 SIGTERM PID=$P"
    ;;
  status)
    P="$(pids)"
    if [ -n "$P" ]; then echo "状态: 运行中 PID=$P"; else echo "状态: 未运行"; fi
    "$ADB" shell "tail -2 $RLOG 2>/dev/null" 2>/dev/null | tr -d '\r'
    ;;
  start)
    P="$(pids)"
    if [ -n "$P" ]; then
      "$ADB" shell "kill $P" >/dev/null 2>&1
      i=0
      while [ "$i" -lt 8 ]; do
        sleep 0.5
        [ -z "$(pids)" ] && break
        i=$((i + 1))
      done
      P2="$(pids)"
      if [ -n "$P2" ]; then
        "$ADB" shell "kill -9 $P2" >/dev/null 2>&1
        sleep 0.5
      fi
    fi
    # 启动后轮询就绪（最多 ~2s），比固定 sleep 2 平均快一半，
    # 缩短「通话建立期桥不可用」的空窗。
    NEW="$("$ADB" shell "nohup $BRIDGE --verbose --voice-route-session > $RLOG 2>&1 & i=0; while [ \$i -lt 10 ]; do sleep 0.2; P=\$(pidof mavo-pcm-bridge); if [ -n \"\$P\" ]; then echo \$P; break; fi; i=\$((i+1)); done" 2>/dev/null | tr -d '\r')"
    if [ -n "$NEW" ]; then
      echo "mavo-route: 已重新挂载 PID=$NEW"
    else
      echo "mavo-route: 警告：重新挂载失败（模块未连接？）" >&2
      exit 1
    fi
    ;;
  *)
    echo "用法: $0 start|stop|status" >&2
    exit 2
    ;;
esac
