# CellBridge-mac — 让 iPhone 用蜂窝号码打电话/收短信（SIP）

把 [mccding/CellBridge](https://github.com/mccding/CellBridge) 的 Go 网关移植到 macOS，
配合 DJiPhone Kit 的模块语音运行时：iPhone 装 SIP 客户端（如 YakPhone），经局域网或
Tailscale 连到 Mac，即可用 SIM 卡号码收发短信、拨打/接听 VoLTE 电话。

## 组成

| 组件 | 作用 |
|---|---|
| `CellBridgeConsole.swift` | **原生 AppKit 控制台**（一键部署 + 状态总览 + 发短信 + 推送设置） |
| `at_pty_bridge.py` | 把模块 USB AT 通道桥成 PTY 串口（CellBridge 只认 tty） |
| `voice-audio-bridge --fifo-*` | 蜂窝 UAC 音频 ↔ FIFO（s16le 8k mono，对应 raw-pcm 后端） |
| `cellbridge-gateway` | Go 编译的 SIP 服务器 + 短信引擎 + Web 控制面 |
| `doctor.sh` | 只读体检（进程 / AT / SIP 注册 / 推送 / 短信 / 通话） |
| `send-sms.py` | 经 SIP MESSAGE 发短信（与 YakPhone 同一条通道，不需要 API token） |
| `set-push-token.sh` / `test-push.sh` | 写入 / **免打电话验证** YakPhone PushKit token |
| `rebuild-gateway.sh` | 用 `gateway-patched/` 覆盖上游源码并重新编译网关 |

## 前提

**推荐直接用一键安装**（在仓库根目录执行，自动完成下面全部步骤）：

```bash
./install.sh          # 查依赖 → 拉上游 → 打补丁 → 编译网关/音频桥/控制台
./install.sh --force  # 全部重新编译
```

手动安装（等价于上面脚本做的事）：

1. DJiPhone Kit 已完成 QADBKEY 解锁 + 模块语音运行时部署（语音路由 ready）。
   **刚重启过模块的话，先打开 DJiPhone Kit.app 让自愈线程部署一次再启动本栈。**
2. `cellbridge-gateway`（darwin/amd64）与 `voice-audio-bridge` 已编译就位：

```bash
# Go 1.25+：https://go.dev/dl/（Apple Silicon 用 darwin-arm64 包）
./rebuild-gateway.sh          # 拉上游 + 打补丁 + go test + 编译（推荐，含 12 处修复）
# 或手工：git clone --depth 1 https://github.com/mccding/CellBridge.git /tmp/CellBridge
#         cd /tmp/CellBridge/gateway && go build -o cellbridge-gateway ./cmd/cellbridge-gateway

# 音频桥
cd /path/to/mac-4g-modem
swiftc -O voice_audio_bridge.swift -o voice-audio-bridge

# 控制台 App
cd 仓库根目录 && ./build_console.sh
```

## 启动 / 停止

**图形方式（推荐）**：双击 `CellBridge Console.app`，顶部控制条即：

| 按钮 | 作用 |
|---|---|
| 启动 / 停止 / 重启 | 调用 `start_cellbridge.sh`（脚本内部 `wait` 阻塞，App 会把它 detached 到后台） |
| 重编译 | 调用 `rebuild-gateway.sh`（含 `go test ./...`），产物为 `cellbridge-gateway.new` |
| 体检 | 跑 `doctor.sh`，结果在弹窗里显示全文 |
| 日志 / 目录 | 在 Finder 打开日志目录 / 项目目录 |

控制台只调脚本、不重新实现逻辑，所以**命令行能复现界面上做的每一件事**。

控制台如何找到项目目录（同一份二进制放哪都能用）：

1. `CELLBRIDGE_HOME` 环境变量
2. `~/.cellbridge/home`（`install.sh` 写入）
3. `.app` 所在目录（仓库内直接构建运行时）
4. `~/CellBridge-mac`（兜底）

**数据来源**：控制台直接只读打开 `~/.cellbridge/data/cellbridge.sqlite` 并 tail 日志，
不依赖网关的 HTTP API（那个需要配对 token），所以网关没跑时界面依然可用（会显示"未运行"）。

**命令行方式**：

```bash
./start_cellbridge.sh        # 启动（自动退出 DJiPhone Kit App，两者互斥）
./start_cellbridge.sh stop   # 停止全部组件
./doctor.sh                  # 一键体检（进程/AT/SIP注册/推送/短信/通话）
./send-sms.py 10010 "测试"    # 发短信（中文自动走 PDU）
```

启动后：

- **SIP**：`0.0.0.0:5060`，账号 `iphone` / `cellbridge-<用户名>`
  （可用环境变量 `SIP_USER` / `SIP_PASS` 覆盖）
- **Web 控制面**：http://127.0.0.1:8787（需要配对 token，日常用原生控制台即可）
- **日志**：`~/.cellbridge/run/logs/`

iPhone 端（YakPhone）配置：SIP 服务器填 Mac 的局域网 IP 或 Tailscale 地址 `:5060`，
用户名密码如上。默认 SMS dry-run=true（只入库不发送）；要真实发短信，在启动前
`export CELLBRIDGE_SMS_DRY_RUN=false`（`start_cellbridge.sh` 已默认设为 `false`）。

## 长期值守：散热优化（2026-09-10）

4G 模块长时间挂机发热明显。软件层找到并消除了三个**持续性**热源——它们都不是
功能必需的，只是原实现没有做空闲处理：

| 热源 | 原行为 | 现在 |
|---|---|---|
| 音频桥空转 | 无通话时两个 AudioUnit 仍以 ~8000 fr/s 双向全速搬运，模块 UAC 端点被 USB 主机持续轮询、无法进入低功耗 | 空闲 10s 后暂停 AudioUnit；网关通话时每 20ms 写 tx FIFO，桥据此**自动唤醒** |
| 模块侧语音路由 watchdog | 每 3 秒无条件 `set` 8 条 tinymix 路由；且每次启动都新起一个、`stop` 不回收，实测会累积成多个循环叠加 | 改为「先 `get` 探一条代表性路由 → 仅被 DSP 复位时才全量补写」，10s 一轮，并做**单例化**（启动前回收遗留、`stop` 时清理） |
| 短信收件箱轮询 | 固定每 5s 发 `AT+CPMS` + `AT+CMGL` 唤醒基带 | 默认仍 5s（不牺牲及时性）；可用 `CELLBRIDGE_SMS_POLL_INTERVAL=30s` 降频 |

实测（模块 `/proc/stat`，5 秒窗口）：模块 CPU 使用率 **5.7% → 0.6%**。

可调参数（启动前 `export` 即可）：

```bash
CB_AUDIO_IDLE_SUSPEND=1            # 1=启用空闲挂起（默认）；0=关闭，恢复旧的全速常开行为
CB_AUDIO_IDLE_SECONDS=10           # 空闲多久后挂起（默认 10 秒）
CELLBRIDGE_SMS_POLL_INTERVAL=5s    # 短信轮询间隔；想更省电可设 30s（代价：短信最多延迟该时长）
```

确认是否真的挂起了：

```bash
tail -f ~/.cellbridge/run/logs/audio-bridge.log
# 空闲时预期：
#   [idle] 第 1 次暂停 AudioUnit（已空闲 10s，等待通话音频唤醒）
#   [stats] [已挂起] cellular->fifo=0 fr fifo->cellular=0 fr dropped=0 B
# 来电/去电时自动出现：
#   [idle] 检测到通话音频，AudioUnit 已恢复
```

万一通话没声音，先 `CB_AUDIO_IDLE_SUSPEND=0` 重启以排除本特性；挂起若恢复失败会
自动退回常开模式并打印 `[idle] AudioUnit 恢复失败，退回常开模式`，不会牺牲通话能力。

模块温度可随时自查（需 adb）：

```bash
adb shell 'for z in /sys/class/thermal/thermal_zone*; do echo "$(cat $z/type) $(cat $z/temp)"; done'
```

## 与 DJiPhone Kit 的关系

- **互斥**：App 与本栈都独占 USB AT 接口（interface 2），启动脚本会先退出 App。
- **依赖**：模块侧语音运行时（qdc507_aprv3.ko / qdc507_voice.ko / mavo-pcm-bridge）
  仍由 App 的自愈线程部署；本栈只消费它建好的 UAC 音频流与语音路由。
- 电话音频路径：蜂窝 → AC Interface → FIFO → 网关 → SIP/RTP → iPhone。

## 已验证

**2026-09-09（首轮）**

- AT PTY 桥：AT/CPIN?/CEREG? 透传正常，URC 可达
- 音频桥 FIFO 模式：tx 8kHz 持续流、rx 待通话激活
- 网关：SIP 5060 监听、modem probe 无告警、控制面 HTTP 响应

**2026-09-10（三轮修复后）**

- 启动零 `context deadline exceeded`；`go test ./...` 全部 18 个包通过
- **出站短信**：经 SIP MESSAGE 发 10010 → `sip message sent to=10010 length=18`，
  数据库状态 `sent`（不再卡 `queued`）
- **入站短信**：10010 回信自动入库（`+CMTI` → 轮询 → 解码 → messages 表）
- **入呼**：`sip inbound invite sent ... contact=192.168.1.14:60187 peer=13800138000`、
  `push_host=192.168.1.109`（真实局域网地址，不再是 127.0.0.1）、
  `sip inbound ended by modem` 干净释放，无会话泄漏
- **VoIP 推送链路**：配置 token 后请求真实到达 `push.yakteam.com` 并返回校验结果
  （用假 token 实测 `status="400 Bad Request" body="{\"error\":\"invalid token format\"}"`，
  证明管道通畅、只差一个真 token）

**2026-09-10 11:30（第四轮：短信双向实测 + 控制台）**

- **出站短信（中文）**：`send-sms.py 10010 "控制台链路测试"` → DB `encoding=ucs2`、`status=sent`
  （走 PDU 分支，汉字不再变问号）
- **出站短信（ASCII）**：`LINK TEST OK` → DB `encoding=gsm7`、`status=sent`（走文本模式）
- **入站短信**：10010 回信自动入库，inbound 累计 24 条全部 `sent`，无一条卡 `queued`
- **控制台 App**：`swiftc` 编译通过，六页可用，顶部一键部署按钮就绪
- **`install.sh`**：从零安装跑通（依赖检查 → 上游拉取 → 补丁 → 编译 → 装到 /Applications）
- 诊断补丁：SIP 1xx 响应与 `state` 字段进入日志（见文末「来电诊断」）

**2026-09-10 11:25 真实来电的判读（重要）**

日志显示 INVITE 已送达手机（`contact=192.168.1.14:51060`、`push_host` 正确），
但 25 秒后手机回的是 **`method=CANCEL`** 而不是接听 → **App 没把来电呈现到屏幕上**。
所以「打过来没反应」的症结在 App/系统侧，不在网关：

- 前台（App 有 SIP 注册）：`sip register` 活跃 → 可直接振铃
- 后台/锁屏（App 挂起）：既没有 SIP 注册可下发 INVITE，也没有 token 可推送 → 完全没反应

`devices` 表为空说明 YakPhone 从未把 VoIP token 注册给网关，所以
`~/.cellbridge/push_token` 是唤醒 CallKit 的**唯一通道**。

**待你完成 / 验证**

- 填入 YakPhone 的真 PushKit token（见下节）→ 后台/锁屏来电应弹出 CallKit 原生来电界面
- 真机验证：真实来电振铃、接听后双向音频
- 遗留：MO 挂断后蜂窝不释放（ATH 返回 OK 但对方仍占线）尚未处理
- 遗留：出呼测试里蜂窝下行 `pcm_peak=0`（上行 `11900` 正常），需真机复测

## 上游网关修复（2026-09-10）：入呼不可达 + 上行静音

上游 `mccding/CellBridge` 的 macOS 移植版有三处缺陷，全部在 Go 网关里：

| # | 位置 | 症状 | 原因 |
|---|---|---|---|
| ① | `internal/sip/server.go` `contactAddr()` | 蜂窝来电时 SIP 客户端**完全无反应** | 把整串 `user@host:port` 交给 `ResolveUDPAddr`，未剥离 `iphone@`，解析必失败 → 返回 nil → `ringClients` 的 `if remote == nil { continue }` 跳过，**INVITE 从未发出**（日志里既无 sent 也无 failed） |
| ② | `internal/sip/server.go` `nasIP()` | 通话**上行静音**（对面听不到） | 只认 tailnet（100.x）地址，本机没装 Tailscale 时回落 `127.0.0.1`，发给客户端的 SDP 变成 `c=IN IP4 127.0.0.1`，客户端把上行 RTP 发给自己。下行不受影响，正好对应「咱这边能听到、对面听不到」 |
| ③ | `internal/sip/server.go` `handleMessage()` | 客户端振铃后接听也**接不通** | 只解析 SIP 请求，没有 `SIP/2.0` 响应分支，客户端回的 200 OK 被直接丢弃：不发 ACK、不接听蜂窝、不起音频桥 |

修复内容：

- `contactAddr` 用 `LastIndex("@")` 剥离 user 部分
- 新增 `localIPFor(remote)`：用 `net.DialUDP` 探测到该客户端的本机出口 IP，SDP `c=` 与 Contact 全部改用它（入呼 INVITE 与 MO 的 180/200 OK 都换）
- `handleMessage` 增加 `SIP/2.0` 分支 → 新增 `handleResponse`（按 Call-ID 匹配入呼会话）/ `acceptInbound`（ACK → 设 RTP 目标 → 接听）/ `sendACK`
- `session.go` 新增 `AnswerInbound`（ATA + 等 active + 起桥）与 `beginAnswer`（原子认领，防重传 200 OK 重复接听）
- `ringClients` 按**物理 callID 去重**（一次来电会多次 RING，原来每次都新建会话并再发一轮 INVITE）+ 45s 无人接听超时释放蜂窝
- `inboundLoop` 增加 `ended` 分支释放会话（原来只处理 incoming，会话与媒体端口会泄漏）
- `at/adapter.go` 解析 `+CLIP` 存 pendingPeer，首个 RING 延迟 350ms 发事件以带上来电号码；`Probe` 里发 `AT+CLIP=1`

修复后的源码在 `gateway-patched/`，重新编译用 `./rebuild-gateway.sh`。
回滚：`cellbridge-gateway.bak-20260910`。

## 第二轮修复（2026-09-10 10:20-10:55）：事件 channel 竞争 + CLIP + 状态残留

第一轮修完后真机复测仍然「打过来没反应」。日志显示**整份 gateway.log 没有任何 `sip inbound ringing`**，但 API 层有 `push skipped kind=voip` —— 说明模块上报了来电，只是 SIP 层收不到。

| # | 位置 | 症状 | 原因 |
|---|---|---|---|
| ④ | `cmd/cellbridge-gateway/main.go` | 入呼**时好时坏**，多数时候 SIP 层收不到 | modem 事件流被 **两个 goroutine 读同一个 channel**：API 状态机（`HandleModemEvent`）与 SIP 入呼振铃（`AttachEvents`）。Go channel 是单消费者语义，每条事件只被一个读者取走，两者互抢。API 抢到就不发 INVITE |
| ⑤ | `internal/modem/at/parser.go` `isUnsolicited()` | 来电号码恒为 `unknown` | 白名单里**没有 `+CLIP:`**。AT 口被状态轮询占用时，`+CLIP:` 被当作命令响应吞掉，不派发给 URC 处理器 |
| ⑥ | `internal/modem/at/adapter.go` `finishActive()` | 本地挂断过一次后，**后续所有来电静默失效** | 只清了 `active`，没清 `incomingSent`/`pendingPeer`；RING 分支的 `if already { return }`（防重复振铃）于是永久生效。只有收到 `NO CARRIER` 或重启网关才能恢复 |

修复内容：

- 新增 `internal/modem/fanout.go`：`FanOut(src, sinks...)` 把单条 modem 事件流扇出给多个消费者；`main.go` 改为扇出到 `apiEvents`/`sipEvents` 两条 64 缓冲 channel
- `isUnsolicited()` 认 `+CLIP:` 前缀
- `finishActive()` 一并重置 `incomingSent` / `pendingPeer`
- `emitIncomingDelayed` 由固定 350ms 改为**轮询等待来电号码，最多 800ms，拿到即走**（`incomingClipWait`）：AT 口被轮询占用时不再丢号码，常见情况反而更快
- `ringClients` 的 INVITE 投递加**短暂重试**（10 × 500ms，仅在一条都没发出去时重试，故不会重复发），并在全部失败时打 `sip inbound invite unsent`。原因：YakPhone 注册极频繁，`expires=0` 会让注册表瞬时为空

回归测试：`internal/modem/fanout_test.go`、`internal/modem/at/inbound_repeat_test.go`（本地挂断后可再来电 / 重复 RING 不重复开会话 / 迟到的 `+CLIP` 仍带上号码）。

### 诊断工具：合成来电注入

`at_pty_bridge.py` 持有 PTY master，往 master 写入的字节会出现在网关读取的那一侧，因此可以**伪造来电 URC**，在没有第二部手机时验证整条入呼链路。

```bash
# 启动后 20 秒自动注入一次合成来电（号码 13800138000，保持 30 秒）
CB_INJECT_RING=20 CB_INJECT_RING_HOLD=30 ./start_cellbridge.sh

# 或开一个控制文件，随时手动触发
CB_INJECT_RING_CTL=~/.cellbridge/run/inject-ring.ctl ./start_cellbridge.sh
echo 13800138000 >> ~/.cellbridge/run/inject-ring.ctl   # 触发一次来电
echo end          >> ~/.cellbridge/run/inject-ring.ctl   # 补 NO CARRIER，释放状态
```

用**普通文件轮询**而非 FIFO：FIFO 的读写端握手在时序竞争下会让读端永久阻塞在 `open()` 上，触发会失效。

验证通过的日志形态：

```
modem call event fanned out kind=incoming peer=13800138000 sinks=2
sip inbound invite sent user=iphone contact=192.168.1.14:56545 peer=13800138000 attempt=1
sip inbound ringing call_id=in-... peer=13800138000 invites_sent=1
```

## 第三轮修复（2026-09-10 11:00-11:20）：AT 上行断链（短信/通话一起失效的真凶）

现象：短信发不出去、网关启动时 `probe modem capabilities` 与 `read modem status` 双双
`context deadline exceeded`、接听超时。**但模块本身完全正常**——绕过 PTY 直接对 USB 端点
收发，`AT` → `OK`、`AT+CGMI` → `Baiwang` 秒回。

关键证据：USB 端点里堆积着**上百条从未被读取的响应**，全是网关发出的 `AT+CPMS="MT"`
轮询回复。即**下行（网关→模块）通，上行（模块→网关）断**。

| # | 位置 | 症状 | 原因 |
|---|---|---|---|
| ⑦ | `at_pty_bridge.py` `usb2pty()` | 短信收发、通话控制**全部超时** | 上行线程里 `os.write(master_fd, chunk)` 一旦抛 `OSError` 就 `return`，**线程永久退出**。桥启动时模块端点里残留着上一轮的响应，而网关要 4 秒后才打开 PTY 从端——此时向主端写入必然 EIO，于是第一次写入就把上行线程杀死 |
| ⑧ | `internal/sms/engine.go` `Send()` | 短信永久卡在 `queued` | 提交失败后回写状态时复用了**已过期的提交 context**，`UpdateMessageStatus` 自己也失败，状态永远停在 `queued`（昨天留下 7 条） |
| ⑨ | `internal/modem/at/parser.go` | 短信偶发发送失败 | `SendSMS` 先单独 `Exchange("AT+CMGF=1")` 再 `SendTextSMS`，两次持锁之间 5 秒轮询的 `AT+CMGF=0` 会插进来把模块切回 PDU 模式，`AT+CMGS="短号"` 随即失败 |
| ⑩ | `internal/modem/at/adapter.go` | 短号中文短信变问号 | 短号走文本模式并固定 `AT+CSCS="GSM"`，汉字不在 GSM 字符集里 |

修复内容：

- **`at_pty_bridge.py`**：
  - 不再 `os.close(slave_fd)`，桥自己持有从端——主端写入永远有效，杜绝启动窗口的 EIO
  - `usb2pty` 遇 `OSError` 只记日志并重试，**绝不退出**
  - 新增 `flush_usb()`：公布 PTY 路径**之前**先丢弃端点里残留的响应，否则网关会把过期响应
    当成自己命令的回复（读到的 OK 属于几条命令之前），状态判断全部错位
  - 新增 `CB_AT_TRACE=1`：AT 字节级双向跟踪，输出到 `at-pty.log`。这次就是靠它定位的
  - 注入控制文件改为**从末尾开始读**：否则旧行会在启动时被重放，凭空造出一通来电
- `sms/engine.go`：新增 `persistStatus()`，用**独立 5 秒 context** 回写终态，提交 context 过期
  也能落库
- `parser.go`：`SendTextSMS` / `SendPDU` 把 `AT+CMGF=` 模式切换与提交**合并到同一次持锁**内，
  消除与轮询的竞态；`isUnsolicited()` 补上 `+CMTI:` / `+CMT:`（新短信指示，原被当成命令响应）
- `adapter.go`：短号仅在正文可用 GSM7 编码时走文本模式，含中文一律落到 PDU（编码器已正确
  处理 GSM7/UCS2 与分片）；`ListSMS` 的存储名从写死的 `"SM"` 改为 `"MT"`

回归测试：`internal/sms/engine_deadline_test.go`（提交 deadline 过期也必须落库 `failed`，
不得停在 `queued`）。

## 来电唤醒 CallKit（VoIP 推送）

iOS 只允许通过 **VoIP 推送（PushKit）** 在 App 挂起/后台时唤醒并弹出 CallKit 来电界面。
网关在收到模块 RING 时 POST 到 `push.yakteam.com/v1/notify`（`type=voip`），token 必须来自
YakPhone 本身。

**这一步只能由你完成**（token 在 App 内，无法从外部获取）：

1. YakPhone → 设置 → 推送 / Push（PushKit、APNs Token）→ 复制
2. 写入：`./set-push-token.sh 'AAA...=='`（或交互式 `./set-push-token.sh`）
3. 重启：`./start_cellbridge.sh`

启动脚本会自动读 `~/.cellbridge/push_token` 写进 `config.yaml` 的 `sip.push_token`，
并在启动横幅里明确提示是否已配置。

**不填的后果**：App 在前台时 SIP INVITE 仍能振铃；App 挂起/锁屏时来电毫无反应。

| # | 位置 | 症状 | 原因 |
|---|---|---|---|
| ⑪ | `internal/sip/server.go` `ringClients()` | CallKit 唤醒了也接不通 | 推送里的 `caller_uri` 用 `nasIP()`，本机无 Tailscale 时是 `127.0.0.1`，YakPhone 拿到的呼叫地址指向它自己 |
| ⑬ | `internal/sip/server.go` `endInboundCall()` | **对方先挂断，手机界面还停在通话中** | 两个独立的洞：① 会话查找只按 `"in-"+模块call id`，呼出会话以客户端 Call-ID 为键 → 呼出时对方挂断等于空操作；② 全网关**从不发 BYE/CANCEL**，收线只做本地动作（停桥/关媒体/ATH），客户端对话永远不关 |

**⑬ 的修法**：建对话时把 Request-URI / From / To / Call-ID / CSeq / Via branch 原样记进
`byePlan`（呼出取客户端 INVITE，呼入取我们发出的 INVITE、接听后用 200 OK 覆盖）；
`sessionForModemEvent` 三级匹配（`"in-"+id` → 建腿时记下的模块 call id → 唯一在跑音频的
`active` 会话）；`sendDialogTeardown` 按状态发 **CANCEL**（还在振铃，复用 INVITE 的
branch 与 CSeq 号）/ **BYE**（已接通）/ **480**（呼出未接通，否则手机白响到事务超时）。
排查用：`grep -E "sip (call ended by modem|teardown sent|bye received)" ~/.cellbridge/run/logs/gateway.log`
—— 看到 `sip bye received` 是**手机自己**挂断，不算这条链路被验证。

修复内容：

- `ringClients` 用**已注册客户端的可达地址**（`localIPFor`）拼 `caller_uri`，无客户端时回落
  到新增的 `outboundIP()`（UDP 探测出口网卡，不发包），日志里新增 `push_host` 便于核对
- `yakpush.go` / `api/server.go` 的推送改为**读回响应体**：token 失效时端点回 4xx + 说明，
  不读就只能看到一个状态码。非 2xx 记 `yakpush rejected`，是区分「token 不对」与「网络不通」
  的唯一证据

排查用：`grep -E "yakpush (sent|rejected|failed|skipped)" ~/.cellbridge/run/logs/gateway.log`

### 免打电话验证 token：`./test-push.sh`

判断「锁屏/后台来电不响」卡在哪一环，最怕只能靠真打电话试。`test-push.sh` 把网关里那段
推送逻辑（`internal/sip/yakpush.go`）单独跑一遍，一次分清三件事：

```bash
./test-push.sh                       # 用 ~/.cellbridge/push_token 发一条 VoIP 来电推送
./test-push.sh 'AAA...=='            # 临时用指定 token 测（不写入文件）
./test-push.sh --message '你好'       # 发普通消息推送（type=message）
```

| 结果 | 含义 |
|---|---|
| `✗ 未配置 token` | token 文件不存在 → 先 `./set-push-token.sh` |
| `HTTP 400 invalid token format` | token 被截断/多带字符（PushKit token 是 Base64，通常 ≥64 字符） |
| `HTTP 401/403` | token 已失效或不属于该推送环境 → 重新复制 |
| `HTTP 2xx 推送已被端点接受` | 网关侧已到位；手机仍不响就查 App/系统侧（通知权限、专注模式、后台清理） |

**必须绕过 `HTTP(S)_PROXY`**：本机走透明 TUN 出网，代理反而会打断它（网关里同样是
`Transport{Proxy: nil}`）。脚本已内置 `--noproxy '*'`。

## 一键体检：`./doctor.sh`

排查前先跑它，比逐条猜快得多：

```bash
./doctor.sh
```

输出 8 节：进程 → 网关健康 → AT 链路 → YakPhone 注册状态 → 推送配置 → 短信统计 →
最近通话 → YakPhone 该填的服务器地址。每节都给出下一步动作。

**设计约束（重要）**：`doctor.sh` **绝不直接读写 AT 串口**。网关是 PTY 的唯一读者，
第三方去写 AT 会把网关的响应抢走，反而制造故障（这个坑踩过）。所以它只做只读检查：
看进程、看日志、看数据库、看健康接口。

其中第 4 节（YakPhone 注册状态）是判断「来电为什么不响」的关键：
YakPhone 注册很频繁（`expires=0` 注销紧跟一次 `expires=300` 注册），所以
**日志里最后一次注册的年龄**直接反映 App 是否还活着：

- ≤60s：已注册 → 来电会直接下发 SIP INVITE，前台必然振铃
- >300s 或本次启动后无记录：App 已挂起 → **只能靠 VoIP 推送唤醒**，token 未配则毫无反应

## 来电诊断：SIP 响应可见性（2026-09-10 11:30）

此前 `handleResponse` 把 100/180/183 静默丢弃，于是「手机没响」这一句话无法区分三种
完全不同的原因。现在补充两处日志：

- `sip inbound provisional code=180/183` —— **证明 YakPhone 收到 INVITE 并把来电放上了屏幕**。
  只有 `100` 或什么都没有，才说明 App 从未呈现来电，问题在 App/系统侧（后台挂起 → 需要
  PushKit 推送），不在网关
- `sip bye received method=CANCEL state=init reason=...` —— `CANCEL` + `state=init` 表示
  手机在接通前主动放弃（用户拒接，或它在等蜂窝侧时自己超时）；`BYE` + `state=active`
  才是接通后的正常挂断

判读口诀：

```
有 provisional(180) 但随后 CANCEL   → App 响了，用户/App 放弃了
无 provisional，直接 CANCEL          → App 没呈现来电 → 查推送与后台权限
无任何响应，45s 后 ring timeout      → INVITE 没送到 → 查第 8 节服务器地址
```

