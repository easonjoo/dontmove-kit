#!/bin/bash
# rebuild-gateway.sh — 重新编译带修复的 CellBridge 网关
#
# 背景：上游 mccding/CellBridge 的 macOS 移植版有多处缺陷，导致
#   ① 蜂窝来电时 SIP 客户端完全无反应（INVITE 从未发出）
#   ② 通话上行静音（SDP 把客户端指向 127.0.0.1，对面听不到）
#   ③ 即便客户端振铃，接听后也无法接通（网关不解析 SIP 响应）
#   ④ 入呼时好时坏（modem 事件流被 API 与 SIP 两个 goroutine 抢同一个 channel）
#   ⑤ 来电号码恒为 unknown（isUnsolicited 白名单漏了 +CLIP:）
#   ⑥ 本地挂断过一次后，后续来电静默失效（finishActive 没清 incomingSent）
#   ⑧ 短信永久卡在 queued（状态回写复用了已过期的提交 context）
#   ⑨ 短信偶发发送失败（AT+CMGF 模式切换与提交之间被轮询插入）
#   ⑩ 短号中文短信变问号（文本模式固定 AT+CSCS="GSM"）
#   ⑪ CallKit 唤醒了也接不通（推送 caller_uri 用了 nasIP → 127.0.0.1）
#   ⑫ 推送报 EOF（继承了 shell 的 HTTP(S)_PROXY）
#   ⑬ 对面先挂断时本机还在通话中：网关只做本地收线（停桥/ATH），从不给 SIP
#      客户端发 BYE/CANCEL；且挂断事件只按 "in-"+模块 call id 查会话，呼出
#      会话（按客户端 Call-ID 存）永远匹配不到，呼出时对方挂断等于什么都没做。
#      → sessionForModemEvent 双方向匹配 + sendDialogTeardown 按状态发
#        CANCEL（还在振铃）/BYE（已接通）/480（呼出未接通）。
#   ⑭ 对面挂断后本机继续响：手机被 VoIP 推送唤醒后会重启 SIP 栈、从新的源
#      端口重新注册，INVITE 发出时的地址随即失效，只发旧地址的 CANCEL 被
#      静默丢弃（实测 62862→58591→52543，几秒内连换两次）。
#      → sendDialogTeardown 把 teardown 同时发往 INVITE 地址与该账号当前
#        注册地址，每个目标重发一次；Request-URI 仍按 RFC 3261 §9.1 复用
#        INVITE 的原值，只有发送地址更新，客户端才能匹配到该事务。
#   ⑮ 来电不显示号码：INVITE 的 From 只有裸 URI（<sip:号码@网关>），锁屏
#      来电人一栏是空的。→ 补上带引号的号码显示名、P-Asserted-Identity 和
#      Remote-Party-ID；无来电号码时退回 unknown URI，避免空的 From 头。
# 注：⑦（AT 桥上行线程被一次 EIO 杀死）在 at_pty_bridge.py 里，与网关无关。
#
# 修复后的源码保存在 gateway-patched/，编译前覆盖到上游源码上。
#
# 用法：./rebuild-gateway.sh
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
GO_ROOT="${GO_ROOT:-$HOME/.workbuddy/binaries/go/go}"
SRC="${SRC:-/tmp/CellBridge-main}"
TARBALL_URL="https://codeload.github.com/mccding/CellBridge/tar.gz/refs/heads/main"

if [ ! -x "$GO_ROOT/bin/go" ]; then
  cat <<EOF
缺少 Go 工具链（$GO_ROOT）。安装（go.dev 直连在国内会失败，用阿里云镜像）：
  curl -L -o /tmp/go.tar.gz https://mirrors.aliyun.com/golang/go1.25.0.darwin-amd64.tar.gz
  mkdir -p "$GO_ROOT" && tar -C "$GO_ROOT" -xzf /tmp/go.tar.gz
EOF
  exit 1
fi

if [ ! -d "$SRC/gateway" ]; then
  echo "[1/3] 拉取上游源码（git clone 常被墙，改用 codeload tarball）..."
  rm -rf "$SRC" /tmp/cb-src /tmp/cb.tar.gz
  mkdir -p /tmp/cb-src
  curl -fL -o /tmp/cb.tar.gz "$TARBALL_URL"
  tar -xzf /tmp/cb.tar.gz -C /tmp/cb-src
  mv /tmp/cb-src/CellBridge-main "$SRC"
else
  echo "[1/3] 复用已有源码 $SRC"
fi

echo "[2/3] 覆盖修复后的源码..."
# 注意 cmd/ 也必须覆盖：事件扇出（fanout）的接线就在 main.go 里
cp -R "$DIR/gateway-patched/internal/." "$SRC/gateway/internal/"
cp -R "$DIR/gateway-patched/cmd/." "$SRC/gateway/cmd/"

echo "[3/3] 测试并编译..."
export GOROOT="$GO_ROOT"
export PATH="$GOROOT/bin:$PATH"
export GOPROXY="${GOPROXY:-https://goproxy.cn,direct}"
export GOPATH="${GOPATH:-$HOME/.workbuddy/binaries/go/gopath}"
export GOFLAGS=-mod=mod
cd "$SRC/gateway"
go test ./...
go build -o "$DIR/cellbridge-gateway.new" ./cmd/cellbridge-gateway

echo ""
echo "编译完成：$DIR/cellbridge-gateway.new"
echo "部署："
echo "  ./start_cellbridge.sh stop"
echo "  mv $DIR/cellbridge-gateway.new $DIR/cellbridge-gateway"
echo "  ./start_cellbridge.sh"
