# Don'tMove Kit

**让一台 Mac 变成 4G 蜂窝语音网关**：插上 QDC507 / EG25-G 4G 模块和 SIM 卡，
iPhone 上装一个 SIP 客户端（[YakPhone](https://apps.apple.com/app/yakphone/id1529270977)
或 [Linphone](https://www.linphone.org/)），即可用这张 SIM 卡的号码拨打 / 接听
VoLTE 电话、收发短信——走局域网或 Tailscale，人在哪里都能用。

> 名字里的 "Don't Move"：SIM 卡插进模块就别再挪了，电话短信跟着你走。

```
iPhone (SIP 客户端)                 Mac (本仓库)                        4G 模块 (USB)
┌─────────────────────┐    ┌────────────────────────────────┐    ┌──────────────┐
│  打电话 / 收短信 UI  │◄──►│ cellbridge-gateway (SIP 5060)  │◄──►│  VoLTE 语音   │
│  CallKit 来电推送    │    │        + 短信引擎 + Web 控制面  │    │  AT 指令      │
└─────────────────────┘    │ voice-audio-bridge (PCM 桥)    │    │  UAC 8kHz    │
      局域网 / Tailscale    │ at_pty_bridge (AT→PTY 串口)    │    └──────────────┘
                           └────────────────────────────────┘
```

## 硬件前提

- **Mac**（Intel 或 Apple Silicon 均可）
- **4G 模块**：BAIWANG QDC507（DJI 定制，VID `0x2CA3` / PID `0x4006`）或 Quectel EG25-G 系列，经 USB 连接
- **SIM 卡**：插在模块里，开通 VoLTE，能正常打电话收短信
- **iPhone**：装 [YakPhone](https://apps.apple.com/app/yakphone/id1529270977) 或 [Linphone](https://apps.apple.com/app/linphone/id360065639)
- **模块侧语音运行时**：模块内需已部署 VoLTE PCM 桥（`mavo-pcm-bridge`）与语音内核模块。
  可用 `module-tools/voice_runtime.py provision_runtime()` 在线拉取并校验后经 ADB 部署。

## 一键安装

```bash
git clone https://github.com/easonjoo/dontmove-kit.git
cd dontmove-kit
./install.sh              # 缺什么补什么：依赖检查 → 拉上游源码 → 打补丁 → 编译 → 构建控制台
./install.sh --force      # 全部重新编译
```

安装脚本会做这些事（也可手动逐步执行，见 [README-mac.md](README-mac.md)）：

1. 检查依赖：Go 1.25+、Python 3 + pyusb、swiftc（Xcode CLT）、adb
2. 拉取 [mccding/CellBridge](https://github.com/mccding/CellBridge) 上游源码到 `/tmp/CellBridge-main`
3. 用 `gateway-patched/` 覆盖上游并编译出 `cellbridge-gateway`（含 13+ 处 macOS/蜂窝修复）
4. 编译 `voice-audio-bridge`（Swift，蜂窝 UAC 音频 ↔ FIFO）
5. 构建 `CellBridge Console.app`（原生 AppKit 控制台，可选装到 /Applications）
6. 打印 SIP 客户端需要填写的服务器地址

## 启动

```bash
./start_cellbridge.sh
```

脚本会自动完成：退出占用 USB 的 App → **检测并自动加载模块声卡驱动**（模块重启后
`.ko` 会丢失，脚本发现 `/dev/snd` 缺失时自动推驱动 + insmod）→ 拉起 AT 串口桥 →
等待串口就绪 → 强制重挂语音路由 → 启动网关（等健康检查 OK）→ 探测 Tailscale →
拉起通话后路由自动重挂守护（rearm）→ 打印当前状态横幅。

**登录自启动（推荐）**：给 `~/Library/LaunchAgents` 加一个 plist 指向本目录的
`start_cellbridge.sh`（`RunAtLoad=true`、`KeepAlive={SuccessfulExit:false}`），重启后自动就绪。

## iPhone 端配置

### 方案 A：YakPhone（简单，PushKit 锁屏来电）

| 设置项 | 值 |
|---|---|
| SIP 服务器 | Mac 的局域网 IP（或 Tailscale IP `100.x.y.z`）+ 端口 `5060` |
| 用户名 | `iphone` |
| 密码 | `cellbridge-<你的Mac用户名>`（如 `cellbridge-idoer`） |
| 传输 | UDP |

锁屏来电：在 YakPhone 里复制 PushKit token，跑 `./set-push-token.sh` 写入网关。

### 方案 B：Linphone（免费，无需 App 内购）

第三方 SIP 账号：服务器 / 用户名 / 密码同上，传输 UDP，加密 None，
并在该账号设置里**打开 Push Notifications 开关**。然后：

```bash
# 1. 在 Mac 浏览器登录 subscribe.linphone.org → API Key Manage 生成 Key
./set-linphone-push.sh <你的APIKey>
# 2. 重启网关（脚本会自动注入 Key 与账号）
./start_cellbridge.sh
```

之后锁屏 / 划掉后台状态下来电：网关先向 Belledonne FlexiAPI 发推送唤醒
Linphone（APNs VoIP push），再送 SIP INVITE，弹原生 CallKit 来电。

### 通用能力

- **打电话**：SIP 客户端里直接拨号（网关经 VoLTE 呼出）；别人打进 SIM 号码，iPhone 弹原生来电
- **收短信**：进网关 Web 控制面 `http://<Mac IP>:8787` 查看
- **发短信**：Web 控制台 / 控制台 App / `./send-sms.py <号码> <内容>`
- **异地可用**：`./tailnet-setup.sh` 配 Tailscale，出门照样接电话

随时体检：`./doctor.sh`（只读，8 节报告，末尾直接给出 SIP 客户端该填的地址）。

## 内置自愈能力（长期值守实测踩坑换来的）

- **声卡驱动自愈**：模块重启后声卡 `.ko` 丢失是常态，启动脚本检测到即自动加载
- **USB 断链自愈**：模块重启后 USB 重新枚举，AT 桥自动重新占接口（此前表现为
  AT 命令全部超时，只能重启整套服务）
- **路由会话自愈**：VoLTE 路由会话是一次性的，`route-rearm.sh` 在每通电话结束后
  自动重挂（否则第二通起蜂窝侧全零静音）；另有模块侧 watchdog 每 10 秒校验路由
- **上线就绪探测**：启动脚本全部用健康检查/心跳判活，不用固定 sleep

## 仓库结构

```
├── install.sh                  # 一键安装（依赖 → 拉上游 → 打补丁 → 编译 → 构建 App）
├── start_cellbridge.sh         # 一键启动全套服务（声卡自愈 + 就绪探测 + 守护拉起）
├── doctor.sh                   # 只读体检：进程/AT/SIP 注册/推送/短信/通话/重挂链路
├── remote-check.sh             # 远程使用四项速查（Tailscale/SIP/push token）
├── tailnet-setup.sh            # Tailscale 组网与 Serve 配置
├── gateway-patched/            # 上游 CellBridge 源码 + macOS/蜂窝补丁（含单测）
├── rebuild-gateway.sh          # 重新拉上游 + 打补丁 + go test + 编译网关
├── at_pty_bridge.py            # 模块 USB AT 通道 → PTY 串口桥（含断链自愈）
├── voice_audio_bridge.swift    # 蜂窝 UAC 音频 ↔ FIFO（编译为 voice-audio-bridge）
├── CellBridgeConsole.swift     # 原生 AppKit 控制台（build_console.sh 构建）
├── CellBridgeWidget.app/       # 桌面右缘状态小组件（环形仪表，悬停看明细）
├── widget/                     # 小组件源码（探针聚合器 + 界面）
├── mavo-route.sh               # 模块侧 VoLTE 路由会话重挂
├── route-rearm.sh              # 通话结束后自动重挂守护（每通电话都跑在新会话上）
├── tests/route-rearm-harness.sh# rearm 状态机离线回归（5 场景，无需真机）
├── send-sms.py / set-push-token.sh / set-linphone-push.sh / test-push.sh
├── verify_cs_route.py          # 端到端 CS 语音路由验证（FIFO PCM 统计）
├── voice-runtime/              # 模块声卡内核模块（insmod 用；闭源二进制不入库，
│                               #   由 install.sh / voice_runtime.py 部署到本目录）
├── module-tools/               # 模块侧工具：语音运行时部署 / UAC 音频开关 / tinyalsa 混音器
└── README-mac.md               # 详细文档：配置、排障、13+ 处上游修复清单
```

## 排障

先跑 `./doctor.sh`，然后看 [README-mac.md](README-mac.md) 的「排障」章节——里面有一张
症状速查表（接不通/没声音/第二通哑/推送不响/短信失败）和 13+ 处已修复的上游缺陷清单
（含每处的根因分析），多数问题都能对号入座。

## 致谢

- **[mccding/CellBridge](https://github.com/mccding/CellBridge)** —— 本项目的根基。
  网关（SIP 服务器、短信引擎、Web 控制面、语音桥接框架）全部来自上游；
  本仓库的 `gateway-patched/` 只是在其上的 macOS + USB 4G 模块移植层与缺陷修复。
  衍生修复以同一 MIT 协议回馈社区。由衷感谢上游作者的出色工作。
- **[Belledonne Communications](https://www.belledonne-communications.com/)** ——
  Linphone 与 FlexiAPI / Flexisip Pusher。锁屏来电推送依赖其免费开放的
  `subscribe.linphone.org` 推送服务（只有它持有 Linphone 的 APNs 推送证书）。
- [YakPhone](https://apps.apple.com/app/yakphone/id1529270977) —— iPhone 端 SIP 客户端（PushKit 锁屏来电）。
- [Linphone](https://www.linphone.org/) —— 开源 SIP 客户端（FlexiAPI 锁屏来电）。
- [Tailscale](https://tailscale.com/) —— 异地组网，让蜂窝网关跟着你走。
- [bkerler/edl](https://github.com/bkerler/edl) —— 模块刷机/救援工具链（未随仓库分发）。
- [tinyalsa](https://github.com/tinyalsa/tinyalsa) —— `module-tools/mini_tinymix` 的上游。

本项目以 [MIT](LICENSE) 协议开源，与上游 CellBridge 一致。
