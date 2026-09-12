# DontMove Kit

**把一台 Mac 变成 4G 蜂窝语音网关。** 4G 模块插 SIM 卡接 USB，Mac 上跑一个网关，
iPhone 装 Linphone——这张 SIM 的电话和短信就跟着你走了：在家走局域网，出门走
Tailscale，锁屏也能弹原生来电。

> 名字的来历很简单：SIM 卡插进模块就**别再挪了**（Don't Move）。
> 挪一次，重新枚举、重挂路由、重新部署运行时，够你喝一壶的。

```
iPhone (Linphone)                    Mac (本仓库)                         4G 模块 (USB)
┌──────────────────────┐    ┌─────────────────────────────────┐    ┌───────────────┐
│  打电话 / 收短信 UI   │◄──►│ cellbridge-gateway (SIP :5060)  │◄──►│  VoLTE 语音    │
│  锁屏 CallKit 来电    │    │        + 短信引擎 + Web 控制面   │    │  AT 指令       │
│  短信聊天             │    │ voice-audio-bridge (PCM 桥)     │    │  UAC 8kHz     │
└──────────────────────┘    │ at_pty_bridge (AT→PTY 串口)     │    └───────────────┘
      局域网 / Tailscale     └─────────────────────────────────┘
```

**自检三连**：能打电话（双向都有声）✓ 能收短信（自动入库 + 转发到 Linphone 聊天）✓
能发短信（中文走 UCS2，不再变问号）✓

## ⚠️ 免责声明

**本项目与大疆创新（DJI）无任何隶属、合作或授权关系。** 项目中涉及的 QDC507 为
大疆硬件生态的 USB 4G 模块（USB VID `0x2CA3`），此处仅作技术兼容性说明。"DJI"
及相关商标归其权利人所有。请遵守当地电信法规，仅使用自己合法持有的 SIM 卡。

## 硬件清单

| 东西 | 说明 |
|---|---|
| Mac | Intel / Apple Silicon 都行（本项目在 Intel 上长期值守实测） |
| 4G 模块 | BAIWANG QDC507（DJI 卡槽配件）或 Quectel EG25-G 系列，USB 直连 |
| SIM 卡 | 开通 VoLTE，能正常打电话收短信。插进去，然后——别再挪了 |
| iPhone | 装 [Linphone](https://apps.apple.com/app/linphone/id360065639)（免费） |

## 逐步教程

### 第 0 步：模块侧配置（一次性，最容易被忽略的一步）

模块不是插上就能用的——VoLTE 通话音频要靠模块里的一套**语音运行时**：
声卡内核模块（`qdc507_aprv3.ko` / `qdc507_voice.ko`）+ `mavo-pcm-bridge` 语音路由。

1. **SIM 卡装进模块**，模块经 USB 线接 Mac，确认 `adb devices` 能看到模块
   （ADB 走模块的 interface 6）。
2. **部署语音运行时**，二选一：
   - 图形方式：用配套的模块管理 App（如 DJiPhone Kit 类工具），让它的自愈线程
     自动部署一次；
   - 命令行方式：用本仓库 `module-tools/voice_runtime.py` 的 `provision_runtime()`，
     它会从上游仓库的**固定 commit** 下载运行时文件、做 SHA-256 校验后经 ADB 推入
     模块并 `insmod`（运行时二进制不入本仓库分发，避免版权问题）。
3. **验证**：模块侧 `ls /dev/snd` 应出现声卡节点；`module-tools/enable_audio.py`
   可开关 UAC 音频；Mac 侧 `system_profiler SPUSBDataType` 里能看到 UAC 音频设备。
4. 记住一个事实：**模块重启后，声卡 `.ko` 会丢**。这不是 bug，是模块的宿命。
   本仓库的启动脚本会在启动时检测 `/dev/snd`，缺了就自动推驱动 + `insmod`。

### 第 1 步：安装

```bash
git clone https://github.com/easonjoo/dontmove-kit.git
cd dontmove-kit
./install.sh              # 缺什么补什么：依赖检查 → 拉上游源码 → 打补丁 → 编译 → 构建控制台
./install.sh --force      # 全部重新编译
```

脚本会：检查依赖（Go 1.25+、Python 3 + pyusb、swiftc、adb）→ 拉取
[mccding/CellBridge](https://github.com/mccding/CellBridge) 上游源码 → 用
`gateway-patched/` 覆盖并编译 `cellbridge-gateway`（含 15+ 处修复）→ 编译
`voice-audio-bridge`（Swift，蜂窝 UAC 音频 ↔ FIFO）→ 可选构建原生控制台 App。

### 第 2 步：启动

```bash
./start_cellbridge.sh
```

一条命令拉起全家桶：自动加载声卡驱动（如丢失）→ AT 串口桥 → 等就绪 →
强制重挂语音路由 → 启动网关（健康检查判活，不靠 sleep 硬等）→ 探测 Tailscale →
拉起通话后路由重挂守护。停止用 `./start_cellbridge.sh stop`。

**登录自启动**：往 `~/Library/LaunchAgents` 放一个 plist 指向本目录的
`start_cellbridge.sh`（`RunAtLoad=true`），开机即就绪。

### 第 3 步：iPhone 端 Linphone 配置

| 设置项 | 值 |
|---|---|
| SIP 服务器 | Mac 的局域网 IP（如 `192.168.x.x:5060`），出门用 Tailscale IP `100.x.y.z:5060` |
| 用户名 | `iphone`（默认；可用环境变量 `SIP_USER` / `SIP_PASS` 覆盖） |
| 密码 | 首次启动自动随机生成并持久化到 `~/.cellbridge/run/sip-passwords`，启动横幅会打印，也可用环境变量 `SIP_PASS` 指定 |
| 传输 | UDP |
| 媒体加密 | **无 / None（必须关）** |
| Push Notifications | **打开**（锁屏来电靠它） |

两个加密开关（「IM 加密」和「媒体加密」）**都要关**——这是本项目踩坑史里
最阴险的一个：媒体加密开着时，呼叫能接通，但 Linphone 会在 100 毫秒左右
默默自动挂断，日志里看到的就是「秒播秒挂」。网关回的是明文 RTP，
Linphone 的 SRTP 校验过不去就直接 BYE，连个招呼都不打。

### 第 4 步：锁屏来电推送（FlexiAPI Key）

Linphone 在后台/锁屏时 SIP 注册是挂起的，来电要靠 APNs VoIP 推送唤醒——
而推送证书只在 Belledonne 手里，所以要走它家的 FlexiAPI：

1. **在 Mac 的浏览器**打开 https://subscribe.linphone.org → 登录（免费
   `sip.linphone.org` 账号）→ My Account → API Key → Manage → 生成。
   ⚠️ 必须在 Mac 上生成：**Key 绑定生成时的出口 IP**，网关是从 Mac 发推送的，
   IP 对不上就是 401。
2. 写入并重启：

```bash
./set-linphone-push.sh <你的APIKey>
./start_cellbridge.sh
```

3. 验证：`./set-linphone-push.sh --status` 看配置与最近推送日志；
   Key 闲置久了会被服务端回收，重新生成一次即可。
4. 万一推送还是 401：先想想你的网络是不是换了出口（换网络/代理开关都会变 IP），
   再考虑 Key 是否过期。网关内置了 IPv6/IPv4 双栈重试，就是为这个坑准备的。

### 第 5 步：验收

```bash
./doctor.sh                        # 只读体检：进程/AT/SIP 注册/推送/短信/通话，8 节报告
./send-sms.py 10086 "测试"          # 发一条短信
```

- **打电话**：Linphone 直接拨号；别人打进 SIM 号码，iPhone 弹原生来电（锁屏也行）
- **收短信**：自动入库，并转发到 Linphone 聊天页；也可开 Web 控制面 `:8787` 看
- **免打电话测推送**：`./test-push.sh` 直接验证推送管道，不用反复真打电话骚扰朋友

## 出门也能用：Tailscale

最省心的玩法是把 Mac 配成**子网路由器**，iPhone 上服务器地址固定填 Mac 的局域网 IP：

```bash
tailscale set --advertise-routes=<你家局域网段，如 192.168.31.0/24>
# 然后到 https://login.tailscale.com/admin/machines 批准这条路由（一次性）
```

- **在家**：什么 VPN 都不用开，直连局域网
- **出门**：开 Tailscale，tailnet 自动把流量送进你家局域网

`./tailnet-setup.sh` 可辅助完成组网与 Serve 配置；`./remote-check.sh` 出门前四项速查。

## 我们踩过的坑（省流版）

这套东西是长期值守实测喂出来的，以下每一条都对应真实事故和真实修复
（完整根因分析见 [README-mac.md](README-mac.md)，15+ 处上游缺陷逐条带日志证据）：

| 坑 | 症状 | 一句话真相 |
|---|---|---|
| FlexiAPI Key 绑 IP | 推送 401 | Key 绑生成时出口 IP（IPv6 优先），在 Mac 上生成、换网就重新生成 |
| Linphone 媒体加密 | 接通即挂 | SRTP 校验失败自动 BYE，两个加密开关都得关 |
| CANCEL 对不上号 | 对方挂了你还在响 | RFC 3261 §9.1：CANCEL 必须逐字段复用 INVITE，差一个端口都不行 |
| 客户端重注册 | 挂断信号失踪 | 手机被推送唤醒后会换端口重注册，CANCEL 得追着新地址发 |
| 路由会话一次性 | 第二通电话全零静音 | VoLTE 路由会话用一次就没了，每通电话结束必须重挂 |
| 声卡 `.ko` 丢失 | 重启模块没声音 | 模块重启即丢驱动，启动脚本自动检测补挂 |
| AT 桥上行断链 | 短信通话全超时 | 上行线程遇 EIO 退出就永久装死， USB 端点里堆了上百条没人读的响应 |
| MESSAGE 重传 | 短信重复两条 | 回 200 超过 0.5s 客户端就 UDP 重发，网关必须去重 |
| isComposing XML | 对面收到乱码 | 打字状态包被当短信发了出去，希腊字母乱码既视感 |
| 幽灵呼叫 | 莫名占线 | 取消的呼叫蜂窝腿晚一秒才接通，成了没人认领的活尸，需 CLCC 对账收割 |
| SDP 地址写死 127.0.0.1 | 单向静音 | 对面听不到你？客户端把 RTP 发给自己了 |

## 内置自愈能力

- **声卡驱动自愈**：启动时检测 `/dev/snd`，缺了自动推驱动 + insmod
- **USB 断链自愈**：AT 桥自动重新占接口（此前表现为 AT 全超时只能重启全套）
- **路由会话自愈**：`route-rearm.sh` 每通电话结束后自动重挂 + 模块侧 watchdog
- **上线就绪探测**：全部用健康检查/心跳判活，不用固定 sleep
- **幽灵呼叫收割**：CANCEL/BYE 竞态残留的蜂窝上下文自动清理（ATH→CHUP 指令阶梯）

## 仓库结构

```
├── install.sh                  # 一键安装（依赖 → 拉上游 → 打补丁 → 编译 → 构建 App）
├── start_cellbridge.sh         # 一键启动全套服务（声卡自愈 + 就绪探测 + 守护拉起）
├── doctor.sh                   # 只读体检：进程/AT/SIP 注册/推送/短信/通话/重挂链路
├── remote-check.sh             # 远程使用四项速查
├── tailnet-setup.sh            # Tailscale 组网与 Serve 配置
├── gateway-patched/            # 上游 CellBridge 源码 + macOS/蜂窝补丁（含单测）
├── rebuild-gateway.sh          # 重新拉上游 + 打补丁 + go test + 编译网关
├── at_pty_bridge.py            # 模块 USB AT 通道 → PTY 串口桥（含断链自愈）
├── voice_audio_bridge.swift    # 蜂窝 UAC 音频 ↔ FIFO（编译为 voice-audio-bridge）
├── CellBridgeConsole.swift     # 原生 AppKit 控制台（build_console.sh 构建）
├── CellBridgeWidget.app/       # 桌面右缘状态小组件（环形仪表，悬停看明细）
├── mavo-route.sh               # 模块侧 VoLTE 路由会话重挂
├── route-rearm.sh              # 通话结束后自动重挂守护
├── send-sms.py / set-linphone-push.sh / test-push.sh
├── verify_cs_route.py          # 端到端 CS 语音路由验证（FIFO PCM 统计）
├── voice-runtime/              # 模块声卡内核模块（insmod 用；闭源二进制不入库）
├── module-tools/               # 模块侧工具：语音运行时部署 / UAC 音频开关 / tinyalsa 混音器
└── README-mac.md               # 详细文档：配置、排障、15+ 处上游修复清单（含根因分析）
```

## 排障

先跑 `./doctor.sh`，然后翻 [README-mac.md](README-mac.md) 的排障章节——症状速查表
（接不通/没声音/第二通哑/推送不响/短信失败）加 15+ 处已修复缺陷的根因分析，
多数问题都能对号入座。日志在 `~/.cellbridge/run/logs/`，信令轨迹用
`grep "sip trace" gateway.log`。

## 致谢

站在巨人的肩膀上，而且这几个肩膀都相当靠谱：

- **[mccding/CellBridge](https://github.com/mccding/CellBridge)** —— 本项目的根基。
  SIP 服务器、短信引擎、Web 控制面、语音桥接框架全部来自上游；
  本仓库的 `gateway-patched/` 是其上的 macOS + USB 4G 模块移植层与缺陷修复，
  以同一 MIT 协议回馈社区。上游作者的工程质量让人省了不少头发。
- **[moluncn/mavo](https://github.com/moluncn/mavo)（MaVo / DJOneHub）** ——
  模块侧语音运行时（`mavo-pcm-bridge`、语音路由流程、ADB 部署方案）的来源，
  `module-tools/voice_runtime.py` 是其流程的移植。没有它，模块里的 VoLTE 音频
  就只是一堆安静的字节。
- **[Belledonne Communications](https://www.belledonne-communications.com/)** ——
  Linphone 与 FlexiAPI / Flexisip Pusher。锁屏来电推送依赖其免费开放的
  `subscribe.linphone.org` 推送服务（只有它持有 Linphone 的 APNs 推送证书）。
- **[tinyalsa](https://github.com/tinyalsa/tinyalsa)** —— `module-tools/mini_tinymix` 的上游。
- **[bkerler/edl](https://github.com/bkerler/edl)** —— 模块刷机/救援工具链（未随仓库分发）。
- **[Tailscale](https://tailscale.com/)** —— 异地组网，让蜂窝网关跟着你走。
- **[Linphone](https://www.linphone.org/)** —— 免费、开源、能关掉所有加密开关的 SIP 客户端。

再次强调：本项目与 DJI（大疆创新）无任何隶属或合作关系，仅为硬件兼容性说明。

## License

[MIT](LICENSE) —— 与上游 CellBridge 一致。拿去折腾，翻车了别怪我们，怪 SIM 卡没插紧。
