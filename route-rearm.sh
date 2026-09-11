#!/bin/sh
# route-rearm.sh — 按通话节奏刷新模块侧 VoLTE 路由会话（mavo-pcm-bridge）。
#
# 为什么需要：见 mavo-route.sh 顶部注释 —— mavo-pcm-bridge 的 route session
# 只对「第一通」电话生效，之后蜂窝侧永远送静音（cellular nonzero 恒定小值、
# mean=0）。所以每通电话都必须落在一个「新实例」上。
#
# 策略（2026-09-10 五次修订）：
#   核心：**以「通话结束」为触发点**，每批新日志按行序回放：
#     - 通话结束（voice bridge stopping / call ended / kind=ended）：
#         PENDING=1；是否需要重挂分两路：
#           · 本通见过「开始」事件（SEEN_START=1）→ 确定消耗了 session，
#             **无条件重挂**（NEED_AFTER）。
#           · 没见过「开始」→ 可能是同一通的重复结束上报，用 COALESCE 合并窗抑制；
#             也可能是「开始行被丢」，用「距上次重挂 ≥ COALESCE」时间兜底。
#     - 通话开始（sip session dialing / inbound ringing / inbound invite sent /
#       kind=started）：SEEN_START=1；若 PENDING=1 → NEED_NOW（来不及刷新，补刀）。
#   每批处理完只动作一次；任何重挂成功后 PENDING=0、刷新 LAST_REARM。
#
#   历史教训（四次翻车，一次比一次隐蔽）：
#   ① 「通话结束后若发现新通话在跑就跳过重挂」→ 用户 6s 内秒拨第二通时守卫把
#      重挂吃掉，第二通必哑。结论：**跳过 = 该通必哑**，永不因「忙」而跳过。
#   ② 用「通话开始」置脏标记、结束再结算。16:16 实测失效：脚本在 16:16:40
#      一次处理到第 124 行（第一通的开始在第 8 行、结束在第 123 行，同批到达），
#      按「先结束后开始」结算时脏标记仍是 0 → 又跳过 → 第二通全零。
#      修正：按行序回放。
#   ③ v3 改成「只要有结束事件就重挂」，但保留 COALESCE=8s 合并窗抑制重复上报。
#      2026-09-10 16:39 实测两通均正常（第二通 cellular nonzero 1975/2050、
#      win_ms≈1000），但留下一个**短通话漏洞**：若某通时长 < COALESCE（例如拨错
#      立刻挂断），结束时的重挂会被合并窗吃掉 —— 而这一通确确实实消耗了 session，
#      于是**再下一通必哑**。v4 修正：以「本通是否见过开始事件」为主判据，
#      通过行序配对，凡见过开始就无条件重挂；COALESCE 只用于抑制
#      「同一通的重复结束上报」和兜底「开始行被丢」两种情况。
#
# 环境变量：
#   CB_REARM_DELAY    通话结束后等待秒数（默认 2）
#   CB_REARM_COALESCE 两次重挂的最小间隔秒数（默认 8，用于抑制同一通的重复结束事件）
#   CB_REARM_POLL     轮询间隔秒数（默认 1）
#   CB_REARM_LOGDIR   日志/锁目录（默认 ~/.cellbridge/run/logs）
#   CELLBRIDGE_LOG    网关日志路径（默认 ~/.cellbridge/run/logs/gateway.log）
set -u

DIR=$(cd "$(dirname "$0")" && pwd)
GLOG="${CELLBRIDGE_LOG:-$HOME/.cellbridge/run/logs/gateway.log}"
DELAY="${CB_REARM_DELAY:-2}"
COALESCE="${CB_REARM_COALESCE:-8}"
POLL="${CB_REARM_POLL:-1}"
LOGDIR="${CB_REARM_LOGDIR:-$HOME/.cellbridge/run/logs}"
LOG="$LOGDIR/route-rearm.log"

mkdir -p "$LOGDIR"
_now() { date '+%F %T'; }
_say() { echo "[$(_now)] $*" >> "$LOG"; }

# 单例：避免同一通电话结束后被重挂两次
LOCK="$LOGDIR/route-rearm.lock"
HEARTBEAT="$LOGDIR/route-rearm.heartbeat"
if ! mkdir "$LOCK" 2>/dev/null; then
  OLD=$(cat "$LOCK/pid" 2>/dev/null | tr -dc '0-9')
  if [ -n "$OLD" ] && kill -0 "$OLD" 2>/dev/null; then
    _say "已有实例在运行（PID=${OLD}），本实例退出"
    exit 0
  fi
  rm -rf "$LOCK"
  mkdir "$LOCK" 2>/dev/null || exit 1
fi
echo $$ > "$LOCK/pid"
# 注意：trap 里必须 exit —— 否则收到 TERM 后 shell 会继续跑循环，
# kill/pkill 都杀不掉，重启时会留下僵尸实例（本项目已踩过多次）。
_tidy() { rm -rf "$LOCK"; rm -f "$LOGDIR/.route-rearm.ev.$$" 2>/dev/null; }
trap '_tidy; exit 0' INT TERM
trap '_tidy' EXIT

PENDING=0     # 1 = 桥被用过、尚未刷新
LAST_REARM=0  # 上次重挂成功的 epoch 秒（抑制同一通的重复结束事件）
SEEN_START=0  # 本通是否见过「开始」事件（v4 起为主判据，也是丢行诊断）

# 事件模式：开始 / 结束
PAT_START='sip session dialing|sip inbound ringing|sip inbound invite sent|kind=started'
PAT_END='voice bridge stopping|call ended|kind=ended'
PAT_ANY="$PAT_START|$PAT_END"

rearm() {
  OUT=$("$DIR/mavo-route.sh" start 2>&1)
  case "$OUT" in
    *PID=*)
      PENDING=0
      LAST_REARM=$(date +%s)
      ;;
    *)
      PENDING=1   # 失败：桥仍是脏的，下一通开始前还会再试
      ;;
  esac
  _say "重挂（${1}）：${OUT}"
}

MYPID=$$
_say "route-rearm 启动（PID=${MYPID}，日志=${GLOG}，等待=${DELAY}s，合并窗=${COALESCE}s，轮询=${POLL}s）"

# 先记住「当前末尾」（真实冷启动要跑几秒 adb，重挂期间产生的事件不该被丢），
# 再冷启动挂一次，保证启动后的首通可用；历史事件不回放。
MARK=$(wc -l < "$GLOG" 2>/dev/null | tr -d ' ')
[ -n "$MARK" ] || MARK=0
rearm "冷启动"
_say "从第 ${MARK} 行开始跟踪"

while :; do
  touch "$HEARTBEAT" 2>/dev/null
  CUR=$(wc -l < "$GLOG" 2>/dev/null | tr -d ' ')
  [ -n "$CUR" ] || CUR=0
  if [ "$CUR" -lt "$MARK" ]; then
    _say "日志被截断（${MARK} → ${CUR}），重置跟踪位置"
    MARK="$CUR"
  elif [ "$CUR" -gt "$MARK" ]; then
    OLD=$MARK
    NEW=$(tail -n $((CUR - MARK)) "$GLOG" 2>/dev/null)
    MARK="$CUR"

    # 只关心的事件行：带行号取出，保证按原始先后顺序回放
    EV=$(printf '%s\n' "$NEW" | grep -nE "$PAT_ANY")
    if [ -n "$EV" ]; then
      # 诊断：本批行区间 / 行数 / 批内最新一行的日志时间距现在的滞后秒数
      # （滞后大 = 日志成批到达或本循环被拖住，是判断"丢事件"的关键指标）
      NLINES=$((CUR - OLD))
      LASTTS=$(printf '%s\n' "$NEW" | tail -1 | awk '{print $1" "$2}')
      LAG="?"
      if [ -n "$LASTTS" ]; then
        TSE=$(date -j -f "%Y/%m/%d %H:%M:%S" "$LASTTS" +%s 2>/dev/null)
        [ -n "${TSE:-}" ] && LAG="$(( $(date +%s) - TSE ))s"
      fi

      NEED_NOW=0
      NEED_AFTER=0
      WARNED=0
      printf '%s\n' "$EV" > "$LOGDIR/.route-rearm.ev.$$"
      while IFS= read -r ln <&3; do
        body=${ln#*:}
        case "$body" in
          *"voice bridge stopping"*|*"call ended"*|*"kind=ended"*)
            # 通话结束 = 桥已被用过，必须刷新。
            # 主判据：本通见过「开始」→ 确定消耗了 session，**无条件重挂**。
            #   这一条是 v4 的关键：不能让 COALESCE 吃掉它，否则「通话时长 < 合并窗」
            #   （如拨错秒挂）时重挂被抑制 → 下一通必哑。
            # 未见「开始」→ 要么是同一通的重复结束上报（合并窗抑制），
            #   要么是开始行被丢（用「距上次重挂 ≥ COALESCE」做时间兜底）。
            NOW=$(date +%s)
            if [ "$SEEN_START" -eq 1 ]; then
              NEED_AFTER=1
            elif [ "$LAST_REARM" -eq 0 ] || [ $((NOW - LAST_REARM)) -ge "$COALESCE" ]; then
              if [ "$WARNED" -eq 0 ]; then
                _say "提示：本通未见「开始」事件就结束（开始行可能被丢）→ 按时间兜底重挂"
                WARNED=1
              fi
              NEED_AFTER=1
            fi
            SEEN_START=0
            PENDING=1
            ;;
          *)
            SEEN_START=1
            if [ "$PENDING" -eq 1 ]; then
              # 结束后来不及刷新，这一通就会跑在脏实例上 —— 立刻补刀
              NEED_NOW=1
            fi
            ;;
        esac
      done 3< "$LOGDIR/.route-rearm.ev.$$"
      rm -f "$LOGDIR/.route-rearm.ev.$$"

      if [ "$NEED_NOW" -eq 1 ]; then
        _say "批次 行 ${OLD}→${CUR}（${NLINES} 行，批内最新事件滞后 ${LAG}）→ 通话开始前刷新"
        rearm "通话开始前刷新"
      elif [ "$NEED_AFTER" -eq 1 ]; then
        _say "批次 行 ${OLD}→${CUR}（${NLINES} 行，批内最新事件滞后 ${LAG}）"
        sleep "$DELAY"
        rearm "通话结束后"
      else
        _say "批次 行 ${OLD}→${CUR}（${NLINES} 行，批内最新事件滞后 ${LAG}）→ 无需重挂（距上次重挂 $(( $(date +%s) - LAST_REARM ))s）"
      fi
    fi
  fi
  sleep "$POLL"
done

