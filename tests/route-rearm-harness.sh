#!/bin/sh
# route-rearm-harness.sh — route-rearm.sh 行序状态机的离线回归测试。
#
# 为什么需要：route-rearm.sh 已经翻车四次，每次都是「某一类通话节奏下漏挂 →
# 下一通蜂窝侧全零（双向哑）」。漏挂是静默的，只能靠人工打电话才发现。
# 本测试用假日志按行序回放 5 类节奏，断言每种节奏下的重挂次数，
# 让「改脚本」这件事不再依赖「再打两通试试」。
#
# 时序注意：测试要在沙箱里跑，wc/tail/date 每次调用都有几百 ms 代理开销，
# rearm 一轮循环实测 1~4s。因此**不要用固定 sleep 猜时序**，一律用
# 「settle 让 rearm 读完本批 + 轮询等重挂发生」两段式，否则断言会错位。
#
# 用法：sh tests/route-rearm-harness.sh
# 退出码：0 = 全绿；1 = 有断言失败
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
SRC="$HERE/../route-rearm.sh"
[ -f "$SRC" ] || { echo "找不到 $SRC"; exit 1; }

TMP=$(mktemp -d)
RID=""
cleanup() { [ -n "$RID" ] && kill "$RID" 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT INT TERM

LOGDIR="$TMP/logs"; GLOG="$TMP/gateway.log"; CALLS="$TMP/calls.log"
mkdir -p "$LOGDIR"; : > "$GLOG"; : > "$CALLS"

cp "$SRC" "$TMP/route-rearm.sh"
cat > "$TMP/mavo-route.sh" <<'FAKE'
#!/bin/sh
# 假的重挂器：每次调用记一笔，永不失败
echo "mavo-route: 已重新挂载 PID=999"
echo "$(date '+%H:%M:%S')" >> "$REARM_CALLS"
FAKE
chmod +x "$TMP/mavo-route.sh"

# 测试参数。COALESCE 取 20s：既大到容得下沙箱的慢循环，
# 又小到让「时间兜底」场景不用等太久。
export REARM_CALLS="$CALLS"
export CB_REARM_LOGDIR="$LOGDIR"
export CB_REARM_DELAY=1
export CB_REARM_POLL=1
export CB_REARM_COALESCE=20
export CELLBRIDGE_LOG="$GLOG"

COALESCE=20
RLOG="$LOGDIR/route-rearm.log"
_ts() { date '+%Y/%m/%d %H:%M:%S'; }
_ev() { echo "$(_ts) INFO $1" >> "$GLOG"; }

FAIL=0
_ncalls() { wc -l < "$CALLS" | tr -d ' '; }
_new() { echo $(( $(_ncalls) - PREV )); }

# 轮询等候重挂发生（最多 $2 秒），返回时把 PREV 推进到当前计数
_expect() {  # $1=描述 $2=min $3=max $4=等待秒
  i=0
  while [ "$i" -lt "${4:-12}" ]; do
    [ "$(_new)" -ge "$2" ] && break
    sleep 1; i=$((i + 1))
  done
  N=$(_new); PREV=$(_ncalls)
  if [ "$N" -ge "$2" ] && [ "$N" -le "$3" ]; then
    echo "  ✓ $1（重挂 $N 次）"
  else
    echo "  ✗ $1（期望 $2..$3 次，实际 $N 次）"
    FAIL=$((FAIL + 1))
  fi
}

echo "route-rearm 离线回归（合并窗=${COALESCE}s，延后=${CB_REARM_DELAY}s）"
echo

# ── 启动：脚本自身会先做一次冷启动重挂 ────────────────────────────────
sh "$TMP/route-rearm.sh" &
RID=$!
PREV=0
_expect "冷启动挂一次" 1 1 8
echo

# ── A. 正常通话（有开始 → 结束）──────────────────────────────────────
echo "A. 正常通话：开始行与结束行（可能同批或分批）应重挂"
_ev "sip session dialing id=s1 peer=10010 dir=outbound"
sleep 5
_ev "voice bridge stopping call_id=s1"
_expect "通话结束后重挂" 1 1 12
echo

# ── B. 短通话（v4 修复点）─────────────────────────────────────────────
# 关键：此时距上次重挂只有 3~6s，远小于合并窗 20s。
# 旧版 v3 会被合并窗吃掉 → 0 次；新版 v4 因「见过开始」→ 必须重挂。
echo "B. 短通话（秒挂）：结束距上次重挂 < 合并窗，也必须重挂 ← v4 修复点"
_ev "sip session dialing id=s2 peer=10010 dir=outbound"
sleep 4
_ev "voice bridge stopping call_id=s2"
_expect "短通话结束后仍重挂（合并窗未吃掉）" 1 1 12
echo

# ── C. 同一通的重复结束上报（无新的开始）→ 应抑制 ─────────────────────
echo "C. 重复结束上报（无开始行、距上次重挂 < 合并窗）应被抑制，防止重挂风暴"
_ev "voice bridge stopping call_id=s2"
sleep 6
_expect "重复结束上报被抑制" 0 0 0
echo

# ── D. 结束与下一通开始同批到达 → 回归历史教训② ──────────────────────
echo "D. 结束行与下一通开始行同批到达，应在通话开始前补刀重挂"
_ev "voice bridge stopping call_id=sX"
_ev "sip session dialing id=s4 peer=10010 dir=outbound"
sleep 6
_expect "同批 结束+开始 → 补刀重挂" 1 1 12
echo

# ── E. 开始行被丢，但距上次重挂 > 合并窗 → 时间兜底 ───────────────────
echo "E. 开始行被丢（只有结束行），距上次重挂 > 合并窗 → 时间兜底重挂"
echo "   （等 $((COALESCE + 2))s 让合并窗过期…）"
sleep $((COALESCE + 2))
_ev "voice bridge stopping call_id=s5"
_expect "时间兜底重挂" 1 1 12
echo

# ── 结果 ─────────────────────────────────────────────────────────────
echo "─────"
echo "重挂调用明细："
sed 's/^/  /' "$CALLS"
echo
echo "脚本侧日志："
sed 's/^/  /' "$RLOG"
echo
if [ "$FAIL" -eq 0 ]; then
  echo "结果：全部通过"
  exit 0
fi
echo "结果：$FAIL 个断言失败"
exit 1
