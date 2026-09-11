#!/bin/bash
# install.sh — Don'tMove Kit 一键安装
#
# 从零到可用：检查依赖 → 拉上游源码 → 应用 macOS 修复补丁 → 编译网关与音频桥
#            → 构建原生控制台 .app → 打印 YakPhone 配置指引。
#
# 幂等：重复执行安全。已编译好的组件默认跳过，加 --force 强制重编。
#
# 用法：
#   ./install.sh                # 全量安装（缺什么补什么）
#   ./install.sh --force        # 全部重新编译
#   ./install.sh --skip-gateway # 只装 Mac 侧 App（网关另行处理）
#
# 前置硬件：QDC507 / EG25-G 4G 模块经 USB 连接 Mac，插入可用 SIM 卡。
set -uo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
CM_DIR="$REPO_DIR"
FORCE=0
SKIP_GATEWAY=0

for arg in "$@"; do
  case "$arg" in
    --force)        FORCE=1 ;;
    --skip-gateway) SKIP_GATEWAY=1 ;;
    -h|--help)      sed -n '2,17p' "$0"; exit 0 ;;
    *) echo "未知参数：$arg（用 --help 看用法）"; exit 2 ;;
  esac
done

ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$1"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; }
step() { printf '\n\033[1m[%s]\033[0m %s\n' "$1" "$2"; }

echo "═══════════════════════════════════════════════"
echo " Don'tMove Kit 安装"
echo " 仓库：$REPO_DIR"
echo "═══════════════════════════════════════════════"

# ─────────────────────────────────────────────
step "1/6" "检查运行环境"

if [ "$(uname -s)" != "Darwin" ]; then
  bad "本套件依赖 macOS 的 CoreAudio / PTY / AppKit，无法在其他系统运行"; exit 1
fi
ok "macOS $(sw_vers -productVersion)"

if xcode-select -p >/dev/null 2>&1 && command -v swiftc >/dev/null 2>&1; then
  ok "Xcode Command Line Tools（swiftc 可用）"
else
  bad "缺少 Xcode Command Line Tools —— 编译控制台与音频桥都需要它"
  echo "      安装：xcode-select --install"
  exit 1
fi

# Python：AT 桥依赖 pyusb。优先挑**已经装了 pyusb** 的解释器，避免多装一份。
PY=""
PY_HAS_USB=0
for cand in \
  "$HOME/.workbuddy/binaries/python/envs/default/bin/python3" \
  /opt/homebrew/bin/python3 /usr/local/bin/python3 \
  "$(command -v python3 2>/dev/null)" /usr/bin/python3
do
  [ -n "$cand" ] && [ -x "$cand" ] || continue
  if "$cand" -c "import usb.core" >/dev/null 2>&1; then
    PY="$cand"; PY_HAS_USB=1; break
  fi
  [ -z "$PY" ] && PY="$cand"      # 记下第一个可用的作为兜底
done
if [ -z "$PY" ]; then
  bad "找不到 python3"; echo "      安装：brew install python3"; exit 1
fi

if [ "$PY_HAS_USB" = "1" ]; then
  ok "python3 = $PY（已含 pyusb）"
else
  ok "python3 = $PY"
  warn "缺少 pyusb（AT 串口桥需要）→ 现在安装"
  if "$PY" -m pip install --user pyusb >/dev/null 2>&1 \
     || "$PY" -m pip install --break-system-packages --user pyusb >/dev/null 2>&1; then
    ok "pyusb 安装完成"
  else
    bad "pyusb 安装失败。手动执行：$PY -m pip install --user pyusb"
    echo "      若提示 externally-managed-environment，建议用 Homebrew 的 python3"
    exit 1
  fi
fi

# adb：可选，用于写模块语音路由
if command -v adb >/dev/null 2>&1 || [ -x "$HOME/Applications/platform-tools/adb" ]; then
  ok "adb 可用（语音路由可写入）"
else
  warn "未找到 adb —— 语音路由无法写入，通话会没有声音"
  echo "      下载：https://developer.android.com/tools/releases/platform-tools"
  echo "      解压到 ~/Applications/platform-tools/"
fi

# ─────────────────────────────────────────────
step "2/6" "编译网关（Go）"

if [ "$SKIP_GATEWAY" = "1" ]; then
  warn "按要求跳过网关编译"
elif [ -x "$CM_DIR/cellbridge-gateway" ] && [ "$FORCE" = "0" ]; then
  ok "网关已存在，跳过（加 --force 重编）"
else
  GO_ROOT="${GO_ROOT:-$HOME/.workbuddy/binaries/go/go}"
  if [ ! -x "$GO_ROOT/bin/go" ] && command -v go >/dev/null 2>&1; then
    GO_ROOT="$(dirname "$(dirname "$(command -v go)")")"
  fi
  if [ ! -x "$GO_ROOT/bin/go" ]; then
    warn "未找到 Go 工具链，尝试从阿里云镜像安装 Go 1.25（约 70MB）"
    GO_ROOT="$HOME/.workbuddy/binaries/go/go"
    ARCH="$(uname -m)"; [ "$ARCH" = "arm64" ] && GOARCH=arm64 || GOARCH=amd64
    mkdir -p "$GO_ROOT"
    if curl -fL --noproxy '*' -o /tmp/go-install.tar.gz \
         "https://mirrors.aliyun.com/golang/go1.25.0.darwin-${GOARCH}.tar.gz"; then
      tar -C "$GO_ROOT" -xzf /tmp/go-install.tar.gz && ok "Go 已安装到 $GO_ROOT"
    else
      bad "Go 下载失败。请手动安装：https://go.dev/dl/ 然后重跑本脚本"
      echo "      或设置 GO_ROOT=/path/to/go"
      exit 1
    fi
  fi
  ok "Go = $GO_ROOT"

  if [ ! -d /tmp/CellBridge-main/gateway ]; then
    echo "      拉取上游源码（git clone 在国内常失败，改用 codeload tarball）…"
    rm -rf /tmp/CellBridge-main /tmp/cb-src /tmp/cb.tar.gz
    mkdir -p /tmp/cb-src
    if ! curl -fL --noproxy '*' -o /tmp/cb.tar.gz \
           "https://codeload.github.com/mccding/CellBridge/tar.gz/refs/heads/main"; then
      bad "上游源码下载失败，检查网络后重试"; exit 1
    fi
    tar -xzf /tmp/cb.tar.gz -C /tmp/cb-src
    mv /tmp/cb-src/CellBridge-main /tmp/CellBridge-main
    ok "上游源码已就位"
  else
    ok "复用已有上游源码 /tmp/CellBridge-main"
  fi

  if ( cd "$CM_DIR" && GO_ROOT="$GO_ROOT" ./rebuild-gateway.sh ); then
    mv -f "$CM_DIR/cellbridge-gateway.new" "$CM_DIR/cellbridge-gateway"
    ok "网关编译完成并部署"
  else
    bad "网关编译失败"; exit 1
  fi
fi

# ─────────────────────────────────────────────
step "3/6" "编译通话音频桥（Swift CoreAudio）"

if [ -x "$CM_DIR/voice-audio-bridge" ] && [ "$FORCE" = "0" ]; then
  ok "音频桥已存在，跳过（加 --force 重编）"
elif [ -f "$REPO_DIR/voice_audio_bridge.swift" ]; then
  if swiftc -O "$REPO_DIR/voice_audio_bridge.swift" -o "$CM_DIR/voice-audio-bridge" 2>/dev/null; then
    ok "音频桥编译完成"
  else
    bad "音频桥编译失败"; exit 1
  fi
else
  bad "找不到 voice_audio_bridge.swift"; exit 1
fi

# ─────────────────────────────────────────────
step "4/6" "构建原生控制台 App"

if ( cd "$CM_DIR" && ./build_console.sh ) >/dev/null 2>&1; then
  ok "CellBridge Console.app 构建完成"
else
  bad "控制台构建失败，手动排查：cd $REPO_DIR && ./build_console.sh"
  exit 1
fi

# 记下项目根目录：控制台从 /Applications 启动时靠它找回脚本
mkdir -p "$HOME/.cellbridge"
printf '%s' "$CM_DIR" > "$HOME/.cellbridge/home"
chmod 644 "$HOME/.cellbridge/home"
ok "已记录项目路径 → ~/.cellbridge/home"

# 安装到 /Applications（可选但推荐：Spotlight 能搜到）
if [ -w /Applications ]; then
  rm -rf "/Applications/CellBridge Console.app"
  cp -R "$CM_DIR/CellBridge Console.app" "/Applications/" 2>/dev/null \
    && ok "已安装到 /Applications/CellBridge Console.app" \
    || warn "拷贝到 /Applications 失败（不影响使用，可用仓库内的 .app）"
else
  warn "无权限写入 /Applications，直接用仓库内的 .app 即可"
fi

# ─────────────────────────────────────────────
step "5/6" "检查硬件"

if "$PY" - <<'PYEOF' >/dev/null 2>&1
import usb.core, sys
# 0x2CA3/0x4006 = BAIWANG QDC507（DJI 定制）；0x2C7C = Quectel（EG25-G 等）
found = usb.core.find(idVendor=0x2CA3, idProduct=0x4006) or usb.core.find(idVendor=0x2C7C)
sys.exit(0 if found else 1)
PYEOF
then
  ok "检测到 4G 模块（QDC507 / Quectel）"
else
  warn "未检测到 4G 模块 —— 插好 USB 线再启动"
  echo "      期望：BAIWANG QDC507（VID 0x2CA3, PID 0x4006）或 Quectel（VID 0x2C7C）"
  echo "      若你的模块 VID/PID 不同，改 at_pty_bridge.py 顶部的 VID, PID"
fi

if pgrep -f "DJiPhone Kit.app" >/dev/null 2>&1; then
  warn "DJiPhone Kit App 正在运行，它会独占 USB AT 接口"
  echo "      启动 CellBridge 前请先退出它（start_cellbridge.sh 会自动处理）"
fi

# ─────────────────────────────────────────────
step "6/6" "完成"

cat <<EOF

  下一步（按顺序）：

  1) 启动全栈
       cd "$CM_DIR"
       ./start_cellbridge.sh

  2) 打开控制台（可视化管理 + 一键部署）
       open "$CM_DIR/CellBridge Console.app"
       （控制台顶部有 启动/停止/重启/重编译/体检/日志 按钮）

  3) iPhone 端装 YakPhone，SIP 账号填：
       服务器 = 本机局域网 IP 或 Tailscale 地址，端口 5060
       用户名 = iphone
       密码   = cellbridge-\$(whoami)      # 可用 SIP_PASS 环境变量覆盖

  4) 让后台/锁屏来电也能响（CallKit 唤醒，必须做）
       YakPhone → 设置 → 推送/Push → 复制 PushKit token
       然后在控制台「参数」页粘贴，或执行：
         ./set-push-token.sh 'AAA...=='
         ./test-push.sh          # 不用打电话即可验证 token

  体检：./doctor.sh    （只读检查，不碰串口）
  文档：README-mac.md 与仓库根 README.md

EOF
