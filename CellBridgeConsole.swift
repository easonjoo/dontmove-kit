// CellBridge Console — macOS 原生前端（AppKit）
// 数据源：~/.cellbridge/data/cellbridge.sqlite、~/.cellbridge/run/{config.yaml,logs/*}、进程状态
// 编译：swiftc -O CellBridgeConsole.swift -o CellBridgeConsole

import AppKit
import SQLite3

// MARK: - 常量

/// 项目根目录解析。
///
/// 优先级：`CELLBRIDGE_HOME` 环境变量 → `~/.cellbridge/home`（install.sh 写入）
///        → `.app` 所在目录（仓库内直接构建运行时） → `~/CellBridge-mac`
///
/// 这样同一份二进制无论放在仓库里、还是被拷到 /Applications，都能找回脚本与网关二进制。
enum AppPaths {
    static let home: String = {
        let fm = FileManager.default
        if let env = ProcessInfo.processInfo.environment["CELLBRIDGE_HOME"],
           !env.isEmpty, fm.fileExists(atPath: env) {
            return env
        }
        let stamp = NSHomeDirectory() + "/.cellbridge/home"
        if let s = try? String(contentsOfFile: stamp, encoding: .utf8) {
            let p = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if !p.isEmpty, fm.fileExists(atPath: p) { return p }
        }
        // .app 位于 <repo>/CellBridge Console.app → 取其父目录
        let parent = (Bundle.main.bundlePath as NSString).deletingLastPathComponent
        if fm.fileExists(atPath: parent + "/start_cellbridge.sh") { return parent }
        return NSHomeDirectory() + "/CellBridge-mac"
    }()

    static var gatewayBin: String { home + "/cellbridge-gateway" }
    static var audioBin: String { home + "/voice-audio-bridge" }
    static var startScript: String { home + "/start_cellbridge.sh" }
    static var doctorScript: String { home + "/doctor.sh" }
    static var rebuildScript: String { home + "/rebuild-gateway.sh" }
    static var setPushTokenScript: String { home + "/set-push-token.sh" }
    static var testPushScript: String { home + "/test-push.sh" }
    static var sendSMSScript: String { home + "/send-sms.py" }
}

let kRunDir = NSHomeDirectory() + "/.cellbridge/run"
let kLogDir = kRunDir + "/logs"
let kConfigPath = kRunDir + "/config.yaml"
let kDBPath = NSHomeDirectory() + "/.cellbridge/data/cellbridge.sqlite"
let kPushTokenPath = NSHomeDirectory() + "/.cellbridge/push_token"
let kAdbPath = NSHomeDirectory() + "/Applications/platform-tools/adb"
let kRefreshInterval: TimeInterval = 2.0

// MARK: - 数据采集层

final class DataStore {
    static let shared = DataStore()

    // 进程检测
    func pgrep(_ pattern: String) -> [Int32] {
        let out = runShell("pgrep -f \(pattern) 2>/dev/null")
        return out.split(separator: "\n").compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
    }

    var gatewayRunning: Bool { !pgrep("cellbridge-gateway -config").isEmpty }
    var audioBridgeRunning: Bool { !pgrep("voice-audio-bridge --fifo-rx").isEmpty }
    var ptyBridgeRunning: Bool { !pgrep("at_pty_bridge.py").isEmpty }

    func sipListening() -> Bool {
        let out = runShell("lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null | grep -c ':5060'")
        return (Int(out.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0) > 0
    }

    // 配置解析
    func loadConfig() -> [(String, String)] {
        guard let s = try? String(contentsOfFile: kConfigPath, encoding: .utf8) else { return [] }
        var result: [(String, String)] = []
        for line in s.split(separator: "\n") {
            let l = line.trimmingCharacters(in: .whitespaces)
            if l.isEmpty || l.hasPrefix("#") { continue }
            let parts = l.split(separator: ":", maxSplits: 1)
            if parts.count == 2 {
                result.append((parts[0].trimmingCharacters(in: .whitespaces),
                               parts[1].trimmingCharacters(in: .whitespaces)))
            }
        }
        return result
    }

    // 音频统计（audio-bridge.log 最后一条 stats 行）
    struct AudioStats {
        var rxRate = 0        // cellular->fifo fr/s
        var txRate = 0        // fifo->cellular fr/s
        var dropped = 0
        var renderFailures = 0
        var raw = ""
        var timestamp = Date.distantPast
    }

    func audioStats() -> AudioStats {
        var st = AudioStats()
        guard let s = try? String(contentsOfFile: kLogDir + "/audio-bridge.log", encoding: .utf8) else { return st }
        let lines = s.split(separator: "\n")
        // 最近一条 [stats] 行
        for line in lines.reversed() {
            let l = String(line)
            if l.contains("[stats]"), l.contains("cellular->fifo=") {
                st.raw = l
                // cellular->fifo=39936 fr (7987 fr/s) fifo->cellular=39936 fr (7987 fr/s) dropped=80896 B
                let nums = l.components(separatedBy: CharacterSet.decimalDigits.inverted).filter { !$0.isEmpty }
                if nums.count >= 6 {
                    st.rxRate = Int(nums[2]) ?? 0
                    st.txRate = Int(nums[5]) ?? 0
                    if nums.count >= 7 { st.dropped = Int(nums[6]) ?? 0 }
                }
                break
            }
        }
        // 渲染失败只统计最近 80 行（旧的失败不代表当前）
        st.renderFailures = lines.suffix(80).filter { $0.contains("AudioUnitRender 失败") }.count
        return st
    }

    // mixer 路由状态
    func mixerRoutes() -> (csRx: String?, csTx: String?) {
        guard FileManager.default.fileExists(atPath: kAdbPath) else { return (nil, nil) }
        let out = runShell("\(kAdbPath) shell \"/data/mini_tinymix get 'AFE_PCM_RX_Voice Mixer CSVoice'; /data/mini_tinymix get 'Voice_Tx Mixer AFE_PCM_TX_Voice'\" 2>/dev/null", timeout: 6)
        let lines = out.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }
        func lastVal(_ lines: [String]) -> String? {
            guard let l = lines.last else { return nil }
            return l.components(separatedBy: .whitespaces).last
        }
        let half = lines.count / 2
        let csRx = half > 0 ? lastVal(Array(lines[0..<max(half,1)])) : nil
        let csTx = half > 0 ? lastVal(Array(lines[half...])) : nil
        return (csRx, csTx)
    }

    // 通话记录
    struct CallRow {
        var id: String
        var direction: String
        var peer: String
        var state: String
        var startedAt: Int
        var endedAt: Int?
        var endReason: String
    }

    func calls(limit: Int = 100) -> [CallRow] {
        var rows: [CallRow] = []
        guard let db = openDB() else { return rows }
        defer { sqlite3_close(db) }
        let sql = "SELECT id, direction, peer, state, started_at, ended_at, end_reason FROM calls ORDER BY started_at DESC LIMIT \(limit)"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                let ended = sqlite3_column_type(stmt, 5) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(stmt, 5))
                rows.append(CallRow(
                    id: String(cString: sqlite3_column_text(stmt, 0)),
                    direction: String(cString: sqlite3_column_text(stmt, 1)),
                    peer: sqlite3_column_type(stmt, 2) == SQLITE_NULL ? "—" : String(cString: sqlite3_column_text(stmt, 2)),
                    state: String(cString: sqlite3_column_text(stmt, 3)),
                    startedAt: Int(sqlite3_column_int64(stmt, 4)),
                    endedAt: ended,
                    endReason: sqlite3_column_type(stmt, 6) == SQLITE_NULL ? "" : String(cString: sqlite3_column_text(stmt, 6))))
            }
        }
        sqlite3_finalize(stmt)
        return rows
    }

    // 短信记录
    struct MsgRow {
        var direction: String
        var peer: String
        var body: String
        var status: String
        var createdAt: Int
    }

    func messages(limit: Int = 200) -> [MsgRow] {
        var rows: [MsgRow] = []
        guard let db = openDB() else { return rows }
        defer { sqlite3_close(db) }
        let sql = "SELECT direction, peer, body, status, created_at FROM messages ORDER BY created_at DESC LIMIT \(limit)"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                rows.append(MsgRow(
                    direction: String(cString: sqlite3_column_text(stmt, 0)),
                    peer: String(cString: sqlite3_column_text(stmt, 1)),
                    body: String(cString: sqlite3_column_text(stmt, 2)),
                    status: String(cString: sqlite3_column_text(stmt, 3)),
                    createdAt: Int(sqlite3_column_int64(stmt, 4))))
            }
        }
        sqlite3_finalize(stmt)
        return rows
    }

    func messageCount() -> Int {
        guard let db = openDB() else { return 0 }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        var n = 0
        if sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM messages", -1, &stmt, nil) == SQLITE_OK {
            if sqlite3_step(stmt) == SQLITE_ROW { n = Int(sqlite3_column_int64(stmt, 0)) }
        }
        sqlite3_finalize(stmt)
        return n
    }

    func callCount() -> Int {
        guard let db = openDB() else { return 0 }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        var n = 0
        if sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM calls", -1, &stmt, nil) == SQLITE_OK {
            if sqlite3_step(stmt) == SQLITE_ROW { n = Int(sqlite3_column_int64(stmt, 0)) }
        }
        sqlite3_finalize(stmt)
        return n
    }

    private func openDB() -> OpaquePointer? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(kDBPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return nil }
        return db
    }

    // 日志尾部
    func tailLog(_ name: String, maxBytes: Int = 64_000) -> String {
        let path = kLogDir + "/" + name
        guard let fh = FileHandle(forReadingAtPath: path) else { return "（日志不存在：\(path)）" }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        let start = max(0, Int(size) - maxBytes)
        try? fh.seek(toOffset: UInt64(start))
        let data = fh.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? "（无法解码）"
    }

    // SIP 注册状态（gateway.log 最近 register 事件）
    func sipRegisterInfo() -> (registered: Bool, detail: String) {
        let log = tailLog("gateway.log", maxBytes: 32_000)
        var registered = false
        var detail = "未见注册记录"
        for line in log.split(separator: "\n").reversed() {
            let l = String(line)
            if l.contains("sip register") {
                let expired = l.contains("expires=0")
                let ipPart = l.components(separatedBy: "contact=").last ?? ""
                if !expired {
                    registered = true
                    detail = ipPart
                } else if !registered {
                    detail = "最近一次为注销"
                }
                break
            }
        }
        return (registered, detail)
    }

    /// SIP 注册的「新鲜度」。YakPhone 会频繁重注册（expires=0 紧跟 expires=300），
    /// 所以最后一次成功注册距今多久，直接反映 App 是否还活着：
    ///   ≤60s  已注册 → 来电可经 SIP INVITE 直接振铃
    ///   >300s 或本次启动后无记录 → App 已挂起 → 只能靠 VoIP 推送唤醒
    func sipRegisterAge() -> (seconds: Int?, contact: String) {
        guard let data = try? String(contentsOfFile: kLogDir + "/gateway.log", encoding: .utf8) else {
            return (nil, "")
        }
        let lines = data.split(separator: "\n")
        guard let bootLine = lines.first else { return (nil, "") }
        let boot = parseLogTime(String(bootLine))
        for line in lines.reversed() {
            let l = String(line)
            guard l.contains("sip register"), l.contains("expires=300") else { continue }
            let ts = parseLogTime(l)
            let contact = l.components(separatedBy: "contact=").last ?? ""
            if let ts = ts {
                return (Int(Date().timeIntervalSince1970 - ts), contact)
            }
            return (nil, contact)
        }
        _ = boot
        return (nil, "")
    }

    /// 解析 "2026/09/10 11:30:47 INFO ..." 前缀为 Unix 时间戳
    private func parseLogTime(_ line: String) -> TimeInterval? {
        let parts = line.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        let df = DateFormatter()
        df.dateFormat = "yyyy/MM/dd HH:mm:ss"
        df.timeZone = TimeZone.current
        return df.date(from: "\(parts[0]) \(parts[1])")?.timeIntervalSince1970
    }

    // 推送（YakPush / PushKit）状态 —— 这是「后台/锁屏来电能否唤醒 CallKit」的唯一开关
    struct PushStatus {
        var tokenConfigured = false
        var tokenLength = 0
        var inRunningConfig = false
        var hasEvent = false
        var lastOK = false
        var lastEvent = ""
    }

    func pushStatus() -> PushStatus {
        var st = PushStatus()
        if let s = try? String(contentsOfFile: kPushTokenPath, encoding: .utf8) {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { st.tokenConfigured = true; st.tokenLength = t.count }
        }
        if let cfg = try? String(contentsOfFile: kConfigPath, encoding: .utf8) {
            for raw in cfg.split(separator: "\n") {
                let l = raw.trimmingCharacters(in: .whitespaces)
                guard l.hasPrefix("push_token:") else { continue }
                let v = l.replacingOccurrences(of: "push_token:", with: "")
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                st.inRunningConfig = !v.isEmpty
            }
        }
        let log = tailLog("gateway.log", maxBytes: 200_000)
        for raw in log.split(separator: "\n").reversed() {
            let l = String(raw)
            guard l.contains("yakpush ") else { continue }
            st.hasEvent = true
            st.lastEvent = l
            st.lastOK = l.contains("yakpush sent")
            break
        }
        return st
    }

    /// 最近一次来电的关键事件（用于判断「手机到底响没响」）
    func lastInboundTrace() -> [String] {
        let log = tailLog("gateway.log", maxBytes: 200_000)
        let keys = ["sip inbound invite sent", "sip inbound provisional", "sip inbound ringing",
                    "sip inbound call declined", "sip inbound connected", "sip inbound answer failed",
                    "sip inbound ring timeout", "sip bye received"]
        return log.split(separator: "\n").map(String.init).filter { l in
            keys.contains { l.contains($0) }
        }.suffix(6).map { $0 }
    }

    @discardableResult
    func runShell(_ cmd: String, timeout: Int = 8) -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", cmd]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do { try task.run() } catch { return "" }
        let deadline = Date().addingTimeInterval(TimeInterval(timeout))
        while task.isRunning && Date() < deadline { usleep(50_000) }
        if task.isRunning { task.terminate() }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
}

// MARK: - 动作层（一键部署）

/// 控制台只做「调用已有脚本」，不重新实现任何逻辑。
/// 这样命令行与 GUI 永远行为一致 —— 出问题时你可以在终端复现同一条命令。
final class Actions {
    static let shared = Actions()

    /// 长任务串行化，避免连点两次「启动」起两份网关
    private let queue = DispatchQueue(label: "local.cellbridge.actions")
    private(set) var busy = false
    /// 最近一次动作的结果（供界面提示）
    private(set) var lastMessage = ""
    /// 界面刷新回调（动作完成后触发）
    var onFinish: ((String) -> Void)?

    private func shell(_ cmd: String, timeout: Int) -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", cmd]
        task.currentDirectoryURL = URL(fileURLWithPath: AppPaths.home)
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        do { try task.run() } catch { return "启动子进程失败：\(error.localizedDescription)" }
        let deadline = Date().addingTimeInterval(TimeInterval(timeout))
        while task.isRunning && Date() < deadline { usleep(50_000) }
        if task.isRunning { task.terminate() }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// 启动脚本内部是 `wait $GWPID` 阻塞式前台运行，必须**脱离父进程**再执行，
    /// 否则控制台退出会把整栈带走。用 nohup + & 让 sh 立刻返回、脚本挂到 launchd 下。
    private func launchDetached(_ script: String, log: String) {
        let cmd = "cd '\(AppPaths.home)' && nohup ./\(script) > '\(log)' 2>&1 &"
        _ = shell(cmd, timeout: 5)
    }

    private func begin(_ what: String) {
        busy = true
        lastMessage = "\(what)…"
        DispatchQueue.main.async { self.onFinish?(self.lastMessage) }
    }

    private func finish(_ msg: String) {
        busy = false
        lastMessage = msg
        DispatchQueue.main.async { self.onFinish?(msg) }
    }

    // MARK: 一键部署

    func start() {
        guard !busy else { return }
        begin("正在启动")
        queue.async {
            self.launchDetached("start_cellbridge.sh", log: kRunDir + "/launcher.log")
            // 启动脚本要起三个进程，给它几秒
            Thread.sleep(forTimeInterval: 6)
            let ok = DataStore.shared.gatewayRunning && DataStore.shared.ptyBridgeRunning
            self.finish(ok ? "✓ 已启动（网关 + AT 桥 + 音频桥）"
                           : "⚠️ 启动未完成，请看日志：\(kRunDir)/launcher.log")
        }
    }

    func stop() {
        guard !busy else { return }
        begin("正在停止")
        queue.async {
            let out = self.shell("./start_cellbridge.sh stop", timeout: 30)
            let ok = !DataStore.shared.gatewayRunning
            self.finish(ok ? "✓ 已停止" : "⚠️ 仍有进程存活：\(out.suffix(200))")
        }
    }

    func restart() {
        guard !busy else { return }
        begin("正在重启")
        queue.async {
            _ = self.shell("./start_cellbridge.sh stop", timeout: 30)
            Thread.sleep(forTimeInterval: 2)
            self.launchDetached("start_cellbridge.sh", log: kRunDir + "/launcher.log")
            Thread.sleep(forTimeInterval: 6)
            let ok = DataStore.shared.gatewayRunning && DataStore.shared.ptyBridgeRunning
            self.finish(ok ? "✓ 已重启" : "⚠️ 重启未完成，请看 \(kRunDir)/launcher.log")
        }
    }

    /// 重新编译网关（覆盖上游源码 + go test + go build）。不自动部署，编译产物为 .new。
    func rebuild() {
        guard !busy else { return }
        begin("正在重新编译网关（约 20–60 秒）")
        queue.async {
            let out = self.shell("./rebuild-gateway.sh", timeout: 900)
            if out.contains("编译完成") {
                self.finish("✓ 编译完成：cellbridge-gateway.new\n（部署：先「停止」，再手动 mv，或跑 ./rebuild-gateway.sh 看提示）")
            } else {
                self.finish("✗ 编译失败：\n" + out.suffix(600))
            }
        }
    }

    /// 体检：跑 doctor.sh 并把完整输出回传（只读，不碰串口）
    func doctor(completion: @escaping (String) -> Void) {
        guard !busy else { return }
        begin("正在体检")
        queue.async {
            let out = self.shell("./doctor.sh", timeout: 120)
            self.finish("✓ 体检完成")
            DispatchQueue.main.async { completion(out) }
        }
    }

    /// 推送自检：把 test-push.sh 的输出回传，不用打电话就能验证 token
    func testPush(completion: @escaping (String) -> Void) {
        guard !busy else { return }
        begin("正在验证推送 token")
        queue.async {
            let out = self.shell("./test-push.sh", timeout: 60)
            self.finish("✓ 推送自检完成")
            DispatchQueue.main.async { completion(out) }
        }
    }

    /// 写入 PushKit token（token 只经 stdin 传给脚本，不落进命令行历史）
    func setPushToken(_ token: String, completion: @escaping (String) -> Void) {
        guard !busy else { return }
        begin("正在写入推送 token")
        queue.async {
            let safe = token.replacingOccurrences(of: "'", with: "")
            let out = self.shell("printf '%s' '\(safe)' | ./set-push-token.sh", timeout: 30)
            self.finish(out.contains("已写入") ? "✓ token 已写入，重启后生效" : "✗ 写入失败：\(out)")
            DispatchQueue.main.async { completion(out) }
        }
    }

    /// 发短信：走 SIP MESSAGE（与 YakPhone 完全相同的通道），不需要 API token
    func sendSMS(to: String, body: String, completion: @escaping (String) -> Void) {
        guard !busy else { return }
        begin("正在发送短信")
        queue.async {
            let py = "/usr/bin/python3"
            let script = AppPaths.sendSMSScript
            let args = [py, script, to, body]
                .map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }
                .joined(separator: " ")
            let out = self.shell(args, timeout: 60)
            self.finish(out.contains("OK") ? "✓ 已提交发送" : "✗ 发送失败")
            DispatchQueue.main.async { completion(out) }
        }
    }

    // MARK: 打开位置

    func openLogs()    { _ = shell("open '\(kLogDir)'", timeout: 5) }
    func openProject() { _ = shell("open '\(AppPaths.home)'", timeout: 5) }
    func openConfig()  { _ = shell("open -R '\(kConfigPath)'", timeout: 5) }
}

// MARK: - 工具

func fmtTime(_ ts: Int?) -> String {
    guard let ts = ts, ts > 0 else { return "—" }
    let df = DateFormatter()
    df.dateFormat = "MM-dd HH:mm:ss"
    return df.string(from: Date(timeIntervalSince1970: TimeInterval(ts)))
}

func fmtDuration(_ s: Int?) -> String {
    guard let s = s, s > 0 else { return "—" }
    if s < 60 { return "\(s) 秒" }
    return "\(s / 60) 分 \(s % 60) 秒"
}

// MARK: - 状态卡片视图

final class StatusCard: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let valueLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let dot = NSView(frame: NSRect(x: 0, y: 0, width: 9, height: 9))

    init(title: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        titleLabel.stringValue = title
        titleLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        titleLabel.textColor = .secondaryLabelColor
        valueLabel.font = NSFont.systemFont(ofSize: 17, weight: .semibold)
        valueLabel.textColor = .labelColor
        valueLabel.lineBreakMode = .byTruncatingMiddle
        detailLabel.font = NSFont.systemFont(ofSize: 11)
        detailLabel.textColor = .tertiaryLabelColor
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4.5
        for v in [titleLabel, valueLabel, detailLabel, dot] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            dot.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 9),
            dot.heightAnchor.constraint(equalToConstant: 9),
            titleLabel.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 7),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            valueLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            valueLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),
            valueLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            detailLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            detailLabel.topAnchor.constraint(equalTo: valueLabel.bottomAnchor, constant: 4),
            detailLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            detailLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() { applyTheme() }
    override func layout() { super.layout(); applyTheme() }

    func applyTheme() {
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
    }

    func set(value: String, detail: String, ok: Bool?) {
        valueLabel.stringValue = value
        detailLabel.stringValue = detail
        switch ok {
        case .some(true): dot.layer?.backgroundColor = NSColor.systemGreen.cgColor
        case .some(false): dot.layer?.backgroundColor = NSColor.systemRed.cgColor
        case .none: dot.layer?.backgroundColor = NSColor.systemOrange.cgColor
        }
    }
}

// MARK: - 表格封装

final class SimpleTable: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let tableView: NSTableView
    let scroll: NSScrollView
    private var rowsData: [[String]] = []
    private var headers: [String]

    init(headers: [String], widths: [CGFloat]) {
        self.headers = headers
        tableView = NSTableView()
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.headerView = NSTableHeaderView()
        for (i, h) in headers.enumerated() {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("c\(i)"))
            col.title = h
            col.width = widths[i]
            tableView.addTableColumn(col)
        }
        scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        super.init()
        tableView.dataSource = self
        tableView.delegate = self
    }

    func update(_ rows: [[String]]) {
        rowsData = rows
        tableView.reloadData()
    }

    func numberOfRows(in _: NSTableView) -> Int { rowsData.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let colIndex = tableColumn.flatMap { tableView.tableColumns.firstIndex(of: $0) } ?? 0
        let text = cellText(row: row, col: colIndex)
        let cell = tableView.makeView(withIdentifier: NSUserInterfaceItemIdentifier("cell"), owner: nil) as? NSTextField
            ?? {
                let t = NSTextField(labelWithString: "")
                t.identifier = NSUserInterfaceItemIdentifier("cell")
                t.lineBreakMode = .byTruncatingTail
                t.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
                return t
            }()
        cell.stringValue = text
        return cell
    }

    func cellText(row: Int, col: Int) -> String {
        guard row < rowsData.count, col < rowsData[row].count else { return "" }
        return rowsData[row][col]
    }
}

// MARK: - 各页面

protocol Page: AnyObject {
    var view: NSView { get }
    func refresh()
}

// 概览页
final class OverviewPage: NSObject, Page {
    let stack = NSStackView()
    private let cards: [String: StatusCard]
    private let eventView: NSTextView
    private let eventScroll: NSScrollView

    var view: NSView {
        let wrapper = NSView()
        wrapper.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        wrapper.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: wrapper.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor, constant: -24),
        ])
        return wrapper
    }

    override init() {
        stack.orientation = .vertical
        stack.spacing = 12
        stack.alignment = .leading

        func make(_ title: String) -> StatusCard { let c = StatusCard(title: title); c.translatesAutoresizingMaskIntoConstraints = false; c.heightAnchor.constraint(equalToConstant: 92).isActive = true; c.widthAnchor.constraint(equalToConstant: 320).isActive = true; return c }

        let gw = make("SIP 网关")
        let pty = make("AT PTY 桥")
        let audio = make("音频桥（蜂窝 ↔ Mac）")
        let route = make("模块语音路由（CS → AFE_PCM）")
        let db = make("数据存储")
        let push = make("推送（APNs）")
        cards = ["gw": gw, "pty": pty, "audio": audio, "route": route, "db": db, "push": push]

        let row1 = NSStackView(views: [gw, pty])
        let row2 = NSStackView(views: [audio, route])
        let row3 = NSStackView(views: [db, push])
        [row1, row2, row3].forEach { $0.spacing = 12; $0.alignment = .top }

        let eventTitle = NSTextField(labelWithString: "最近事件（gateway.log）")
        eventTitle.font = NSFont.systemFont(ofSize: 13, weight: .semibold)

        eventView = NSTextView()
        eventView.isEditable = false
        eventView.font = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular)
        eventView.autoresizingMask = [.width]
        eventView.isVerticallyResizable = true
        eventView.textContainer?.widthTracksTextView = true
        eventScroll = NSScrollView()
        eventScroll.documentView = eventView
        eventScroll.hasVerticalScroller = true
        eventScroll.borderType = .bezelBorder

        super.init()
        [row1, row2, row3, eventTitle, eventScroll].forEach { stack.addArrangedSubview($0) }
        eventScroll.translatesAutoresizingMaskIntoConstraints = false
        eventScroll.widthAnchor.constraint(equalToConstant: 652).isActive = true
        eventScroll.heightAnchor.constraint(equalToConstant: 240).isActive = true
    }

    func refresh() {
        let ds = DataStore.shared
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let gwOn = ds.gatewayRunning
            let ptyOn = ds.ptyBridgeRunning
            let audioOn = ds.audioBridgeRunning
            let aStats = ds.audioStats()
            let mixer = ds.mixerRoutes()
            let age = ds.sipRegisterAge()
            let push = ds.pushStatus()
            let callN = ds.callCount()
            let msgN = ds.messageCount()
            let log = ds.tailLog("gateway.log", maxBytes: 4000)
            DispatchQueue.main.async {
                guard let self = self else { return }
                // 注册新鲜度决定「来电走 INVITE 还是只能靠推送」
                let regText: String
                var regOK: Bool? = nil
                if let s = age.seconds {
                    if s <= 60 {
                        regText = "YakPhone 已注册（\(s)s 前）→ 来电可直接振铃"
                        regOK = true
                    } else if s <= 300 {
                        regText = "注册已 \(s)s 未刷新 → App 可能刚进后台"
                        regOK = nil
                    } else {
                        regText = "注册已 \(s)s → App 已挂起，来电只能靠推送"
                        regOK = false
                    }
                } else {
                    regText = "本次启动后未见注册 → YakPhone 未连上"
                    regOK = false
                }
                self.cards["gw"]?.set(
                    value: gwOn ? "运行中 · SIP :5060" : "未运行",
                    detail: gwOn ? regText : "网关进程不存在",
                    ok: gwOn ? (regOK ?? nil) : false)
                self.cards["pty"]?.set(
                    value: ptyOn ? "运行中" : "未运行",
                    detail: ptyOn ? "USB AT ↔ /dev/ttys* 已桥接" : "USB AT 口未被桥接（短信/通话全废）",
                    ok: ptyOn)
                self.cards["audio"]?.set(
                    value: audioOn ? "下行 \(aStats.rxRate) fr/s · 上行 \(aStats.txRate) fr/s" : "未运行",
                    detail: audioOn ? (aStats.renderFailures > 0 ? "⚠️ 最近有 \(aStats.renderFailures) 次渲染失败" : "s16le 8kHz mono · 丢弃 \(aStats.dropped) B") : "——",
                    ok: audioOn ? (aStats.rxRate > 0 && aStats.txRate > 0) : false)
                let rx = mixer.csRx ?? "未知"
                let tx = mixer.csTx ?? "未知"
                let routeOK = (rx == "1") && (tx == "1")
                self.cards["route"]?.set(
                    value: routeOK ? "已路由（CS ↔ AFE_PCM）" : (mixer.csRx == nil ? "状态未知" : "未路由"),
                    detail: "CSVoice→AFE_PCM_RX = \(rx) · AFE_PCM_TX→Voice = \(tx)",
                    ok: mixer.csRx == nil ? nil : routeOK)
                self.cards["db"]?.set(
                    value: "通话 \(callN) · 短信 \(msgN)",
                    detail: kDBPath,
                    ok: callN > 0 || msgN > 0 ? true : nil)
                // 推送卡片：这是「锁屏/后台来电能否唤醒 CallKit」的唯一开关，不能再写死
                if push.tokenConfigured && push.inRunningConfig {
                    let ev = push.hasEvent ? (push.lastOK ? "最近推送被接受" : "最近推送被拒") : "尚无推送记录"
                    self.cards["push"]?.set(
                        value: "已配置（\(push.tokenLength) 字符）",
                        detail: "\(ev) · 后台/锁屏来电可唤醒 CallKit",
                        ok: push.hasEvent ? push.lastOK : true)
                } else if push.tokenConfigured {
                    self.cards["push"]?.set(
                        value: "已写入但未生效",
                        detail: "改了 token 后没重启网关 → 点顶部「重启」",
                        ok: false)
                } else {
                    self.cards["push"]?.set(
                        value: "未配置",
                        detail: "App 在前台可振铃；挂起/锁屏来电不会有任何反应 → 见「参数」页",
                        ok: false)
                }
                self.eventView.string = log
                self.eventView.scrollToEndOfDocument(nil)
            }
        }
    }
}

// 通话页
final class CallsPage: NSObject, Page {
    let table: SimpleTable
    let countLabel = NSTextField(labelWithString: "")
    var view: NSView {
        let v = NSView()
        countLabel.font = NSFont.systemFont(ofSize: 11)
        countLabel.textColor = .secondaryLabelColor
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        table.scroll.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(countLabel)
        v.addSubview(table.scroll)
        NSLayoutConstraint.activate([
            countLabel.topAnchor.constraint(equalTo: v.topAnchor, constant: 14),
            countLabel.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 24),
            table.scroll.topAnchor.constraint(equalTo: countLabel.bottomAnchor, constant: 8),
            table.scroll.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 24),
            table.scroll.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -24),
            table.scroll.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -16),
        ])
        return v
    }
    override init() {
        table = SimpleTable(headers: ["方向", "对方号码", "状态", "开始时间", "时长", "结束原因"], widths: [56, 130, 90, 150, 90, 160])
    }
    func refresh() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let rows = DataStore.shared.calls().map { c -> [String] in
                let dur = (c.endedAt ?? 0) - c.startedAt
                return [c.direction == "outbound" ? "↗ 拨出" : "↙ 来电",
                        c.peer, c.state, fmtTime(c.startedAt), fmtDuration(dur), c.endReason.isEmpty ? "—" : c.endReason]
            }
            DispatchQueue.main.async {
                self?.table.update(rows)
                self?.countLabel.stringValue = "共 \(rows.count) 条通话记录（最新在前）"
            }
        }
    }
}

// 短信页
final class MessagesPage: NSObject, Page {
    let table: SimpleTable
    let countLabel = NSTextField(labelWithString: "")
    private let toField = NSTextField(string: "")
    private let bodyField = NSTextField(string: "")
    private let sendButton = NSButton(title: "发送", target: nil, action: nil)
    private let hint = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()

    var view: NSView {
        let v = NSView()
        countLabel.font = NSFont.systemFont(ofSize: 11)
        countLabel.textColor = .secondaryLabelColor

        let bar = NSStackView()
        bar.orientation = .horizontal
        bar.spacing = 8
        toField.placeholderString = "对方号码"
        toField.font = NSFont.systemFont(ofSize: 12)
        toField.translatesAutoresizingMaskIntoConstraints = false
        toField.widthAnchor.constraint(equalToConstant: 130).isActive = true
        bodyField.placeholderString = "短信正文（支持中文）"
        bodyField.font = NSFont.systemFont(ofSize: 12)
        bodyField.translatesAutoresizingMaskIntoConstraints = false
        bodyField.widthAnchor.constraint(equalToConstant: 380).isActive = true
        sendButton.target = self
        sendButton.action = #selector(sendTapped)
        sendButton.bezelStyle = .rounded
        sendButton.keyEquivalent = "\r"
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        hint.font = NSFont.systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        [toField, bodyField, sendButton, spinner].forEach { bar.addArrangedSubview($0) }

        let note = NSTextField(labelWithString:
            "发送走 SIP MESSAGE —— 与 YakPhone 发短信完全同一条通道（不需要 API token）。中文自动走 PDU 编码。")
        note.font = NSFont.systemFont(ofSize: 10.5)
        note.textColor = .tertiaryLabelColor

        [countLabel, table.scroll, bar, hint, note].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            v.addSubview($0)
        }
        NSLayoutConstraint.activate([
            countLabel.topAnchor.constraint(equalTo: v.topAnchor, constant: 14),
            countLabel.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 24),

            table.scroll.topAnchor.constraint(equalTo: countLabel.bottomAnchor, constant: 8),
            table.scroll.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 24),
            table.scroll.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -24),

            bar.topAnchor.constraint(equalTo: table.scroll.bottomAnchor, constant: 12),
            bar.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 24),
            hint.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 6),
            hint.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 24),
            hint.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -24),
            note.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: 4),
            note.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 24),
            note.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -14),
        ])
        return v
    }

    override init() {
        table = SimpleTable(headers: ["方向", "号码", "状态", "时间", "内容"], widths: [56, 120, 90, 150, 420])
    }

    @objc private func sendTapped() {
        let to = toField.stringValue.trimmingCharacters(in: .whitespaces)
        let body = bodyField.stringValue
        guard !to.isEmpty, !body.isEmpty else {
            hint.stringValue = "号码与正文都不能为空"
            return
        }
        sendButton.isEnabled = false
        spinner.startAnimation(nil)
        hint.stringValue = "正在发送到 \(to) …"
        Actions.shared.sendSMS(to: to, body: body) { [weak self] out in
            guard let self = self else { return }
            self.spinner.stopAnimation(nil)
            self.sendButton.isEnabled = true
            let ok = out.contains("OK")
            self.hint.stringValue = ok ? "✓ 已提交，稍后在此列表看到「发出」记录"
                                       : "✗ 失败：\(out.suffix(200))"
            if ok { self.bodyField.stringValue = "" }
            self.refresh()
        }
    }

    func refresh() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let rows = DataStore.shared.messages().map { m -> [String] in
                [m.direction == "outbound" ? "↗ 发出" : "↙ 收到",
                 m.peer, m.status, fmtTime(m.createdAt),
                 m.body.replacingOccurrences(of: "\n", with: " ")]
            }
            DispatchQueue.main.async {
                self?.table.update(rows)
                self?.countLabel.stringValue = "共 \(rows.count) 条短信记录（最新在前）"
            }
        }
    }
}

// 音频页
final class AudioPage: NSObject, Page {
    private let bigLabel = NSTextField(labelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let fifoLabel = NSTextField(wrappingLabelWithString: "")
    private var histView: NSTextView!
    private var histScroll: NSScrollView!

    var view: NSView {
        let v = NSView()
        bigLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 28, weight: .semibold)
        bigLabel.textColor = .labelColor
        detail.font = NSFont.systemFont(ofSize: 12)
        detail.textColor = .secondaryLabelColor
        fifoLabel.font = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular)
        fifoLabel.textColor = .tertiaryLabelColor
        histView = NSTextView()
        histView.isEditable = false
        histView.font = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular)
        histView.autoresizingMask = [.width]
        histView.isVerticallyResizable = true
        histView.textContainer?.widthTracksTextView = true
        histScroll = NSScrollView()
        histScroll.documentView = histView
        histScroll.hasVerticalScroller = true
        histScroll.borderType = .bezelBorder

        let t = NSTextField(labelWithString: "音频桥实时链路")
        t.font = NSFont.systemFont(ofSize: 13, weight: .semibold)

        let title = NSTextField(labelWithString: "audio-bridge.log（最近统计）")
        title.font = NSFont.systemFont(ofSize: 13, weight: .semibold)

        let subs: [NSView] = [t, bigLabel, detail, fifoLabel, title, histScroll]
        for sub in subs {
            sub.translatesAutoresizingMaskIntoConstraints = false
            v.addSubview(sub)
        }
        NSLayoutConstraint.activate([
            t.topAnchor.constraint(equalTo: v.topAnchor, constant: 18),
            t.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 24),
            bigLabel.topAnchor.constraint(equalTo: t.bottomAnchor, constant: 10),
            bigLabel.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 24),
            detail.topAnchor.constraint(equalTo: bigLabel.bottomAnchor, constant: 6),
            detail.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 24),
            detail.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -24),
            fifoLabel.topAnchor.constraint(equalTo: detail.bottomAnchor, constant: 8),
            fifoLabel.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 24),
            fifoLabel.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -24),
            title.topAnchor.constraint(equalTo: fifoLabel.bottomAnchor, constant: 18),
            title.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 24),
            histScroll.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),
            histScroll.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 24),
            histScroll.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -24),
            histScroll.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -16),
        ])
        return v
    }

    private var first = true
    func refresh() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let ds = DataStore.shared
            let on = ds.audioBridgeRunning
            let st = ds.audioStats()
            let log = ds.tailLog("audio-bridge.log", maxBytes: 5000)
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.bigLabel.stringValue = on
                    ? "↓ \(st.rxRate) fr/s   ↑ \(st.txRate) fr/s"
                    : "未运行"
                self.bigLabel.textColor = on ? .labelColor : .secondaryLabelColor
                let health = on ? (st.rxRate > 0 ? "正常（8kHz s16le 单声道，双向 8000 帧/秒为满速）" : "⚠️ 蜂窝采集方向无数据") : "——"
                self.detail.stringValue = "状态：\(health)" + (st.renderFailures > 0 ? " · 最近 \(st.renderFailures) 次渲染失败" : "")
                self.fifoLabel.stringValue = "rx FIFO（对方声音→Mac）：\(kRunDir)/cellular-rx.fifo\ntx FIFO（Mac→对方）：\(kRunDir)/cellular-tx.fifo\ndropped：\(st.dropped) B（网关空闲期正常增长，通话中应停止）"
                self.histView.string = log
                self.histView.scrollToEndOfDocument(nil)
                self.first = false
            }
        }
    }
}

// 日志页
final class LogsPage: NSObject, Page {
    private let popup = NSPopUpButton()
    private var textView: NSTextView!
    private var scroll: NSScrollView!
    private let autoCheck = NSButton(checkboxWithTitle: "自动刷新并跟随末尾", target: nil, action: nil)

    static let logFiles = ["gateway.log", "audio-bridge.log", "at-pty.log", "launcher.log"]

    var view: NSView {
        let v = NSView()
        popup.addItems(withTitles: Self.logFiles)
        popup.font = NSFont.systemFont(ofSize: 12)
        popup.target = self
        popup.action = #selector(logChanged)
        autoCheck.font = NSFont.systemFont(ofSize: 12)
        autoCheck.state = .on

        textView = NSTextView()
        textView.isEditable = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true
        scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        let subs: [NSView] = [popup, autoCheck, scroll]
        for sub in subs {
            sub.translatesAutoresizingMaskIntoConstraints = false
            v.addSubview(sub)
        }
        NSLayoutConstraint.activate([
            popup.topAnchor.constraint(equalTo: v.topAnchor, constant: 14),
            popup.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 24),
            popup.widthAnchor.constraint(equalToConstant: 200),
            autoCheck.centerYAnchor.constraint(equalTo: popup.centerYAnchor),
            autoCheck.leadingAnchor.constraint(equalTo: popup.trailingAnchor, constant: 14),
            scroll.topAnchor.constraint(equalTo: popup.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 24),
            scroll.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -24),
            scroll.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -16),
        ])
        return v
    }

    @objc private func logChanged() { refreshNow() }

    func refreshNow() {
        let name = Self.logFiles[popup.indexOfSelectedItem]
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let content = DataStore.shared.tailLog(name, maxBytes: 120_000)
            DispatchQueue.main.async {
                guard let self = self else { return }
                let wasAtBottom = self.textView.isScrolledToBottom
                self.textView.string = content
                if self.autoCheck.state == .on || wasAtBottom {
                    self.textView.scrollToEndOfDocument(nil)
                }
            }
        }
    }

    func refresh() {
        if autoCheck.state == .on { refreshNow() }
    }
}

extension NSTextView {
    var isScrolledToBottom: Bool {
        guard let sv = enclosingScrollView else { return true }
        return sv.contentView.bounds.maxY >= sv.documentView!.bounds.maxY - 40
    }
}

// MARK: - 输出窗口（体检 / 推送自检结果）

final class OutputWindow {
    static let shared = OutputWindow()
    private var window: NSWindow?
    private var textView: NSTextView?

    func show(title: String, text: String) {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 580),
                             styleMask: [.titled, .closable, .resizable, .miniaturizable],
                             backing: .buffered, defer: false)
            let tv = NSTextView()
            tv.isEditable = false
            tv.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
            tv.autoresizingMask = [.width]
            tv.isVerticallyResizable = true
            tv.textContainer?.widthTracksTextView = true
            let sv = NSScrollView()
            sv.documentView = tv
            sv.hasVerticalScroller = true
            sv.autoresizingMask = [.width, .height]
            sv.frame = w.contentView!.bounds
            w.contentView?.addSubview(sv)
            window = w
            textView = tv
        }
        window?.title = title
        textView?.string = text
        textView?.scrollToBeginningOfDocument(nil)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// 参数页
final class ConfigPage: NSObject, Page {
    private let configTable: SimpleTable
    private let note = NSTextField(wrappingLabelWithString: "")
    private let tokenField = NSSecureTextField(string: "")
    private let pushState = NSTextField(wrappingLabelWithString: "")
    private let saveButton = NSButton(title: "写入并重启", target: nil, action: nil)
    private let verifyButton = NSButton(title: "验证推送", target: nil, action: nil)
    private let doctorButton = NSButton(title: "一键体检", target: nil, action: nil)
    private let spinner = NSProgressIndicator()

    var view: NSView {
        let v = NSView()

        let pushTitle = NSTextField(labelWithString: "CallKit 唤醒（YakPhone PushKit token）")
        pushTitle.font = NSFont.systemFont(ofSize: 13, weight: .semibold)

        let pushNote = NSTextField(wrappingLabelWithString:
            "iOS 只允许 VoIP 推送（PushKit）在 App 挂起/锁屏时唤醒 CallKit。"
            + "token 在 YakPhone → 设置 → 推送 / Push（PushKit、APNs Token）里复制。"
            + "不填的后果：App 在前台可振铃，挂起/锁屏来电毫无反应。")
        pushNote.font = NSFont.systemFont(ofSize: 11)
        pushNote.textColor = .secondaryLabelColor

        tokenField.placeholderString = "粘贴 PushKit token（形如 AAA…== 的 Base64 串）"
        tokenField.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        tokenField.translatesAutoresizingMaskIntoConstraints = false
        tokenField.widthAnchor.constraint(equalToConstant: 380).isActive = true

        saveButton.target = self; saveButton.action = #selector(saveToken)
        saveButton.bezelStyle = .rounded
        verifyButton.target = self; verifyButton.action = #selector(verifyPush)
        verifyButton.bezelStyle = .rounded
        doctorButton.target = self; doctorButton.action = #selector(runDoctor)
        doctorButton.bezelStyle = .rounded
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        let row = NSStackView(views: [tokenField, saveButton, verifyButton, doctorButton, spinner])
        row.orientation = .horizontal
        row.spacing = 8

        pushState.font = NSFont.systemFont(ofSize: 11)
        pushState.textColor = .secondaryLabelColor

        note.font = NSFont.systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.stringValue = "以下来自 ~/.cellbridge/run/config.yaml 与运行环境（只读展示）"

        [pushTitle, pushNote, row, pushState, note, configTable.scroll].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            v.addSubview($0)
        }
        NSLayoutConstraint.activate([
            pushTitle.topAnchor.constraint(equalTo: v.topAnchor, constant: 16),
            pushTitle.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 24),

            pushNote.topAnchor.constraint(equalTo: pushTitle.bottomAnchor, constant: 6),
            pushNote.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 24),
            pushNote.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -24),

            row.topAnchor.constraint(equalTo: pushNote.bottomAnchor, constant: 10),
            row.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 24),

            pushState.topAnchor.constraint(equalTo: row.bottomAnchor, constant: 8),
            pushState.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 24),
            pushState.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -24),

            note.topAnchor.constraint(equalTo: pushState.bottomAnchor, constant: 16),
            note.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 24),
            note.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -24),

            configTable.scroll.topAnchor.constraint(equalTo: note.bottomAnchor, constant: 8),
            configTable.scroll.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 24),
            configTable.scroll.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -24),
            configTable.scroll.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -16),
        ])
        return v
    }

    override init() {
        configTable = SimpleTable(headers: ["配置项", "值"], widths: [240, 500])
    }

    @objc private func saveToken() {
        let t = tokenField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { pushState.stringValue = "请先粘贴 token"; return }
        saveButton.isEnabled = false; spinner.startAnimation(nil)
        pushState.stringValue = "正在写入并重启网关…"
        Actions.shared.setPushToken(t) { [weak self] out in
            guard let self = self else { return }
            self.tokenField.stringValue = ""
            Actions.shared.restart()
            DispatchQueue.main.asyncAfter(deadline: .now() + 9) {
                self.saveButton.isEnabled = true
                self.spinner.stopAnimation(nil)
                self.pushState.stringValue = out.contains("已写入")
                    ? "✓ token 已写入并已重启。建议接着点「验证推送」。"
                    : "✗ \(out.suffix(200))"
                self.refresh()
            }
        }
    }

    @objc private func verifyPush() {
        verifyButton.isEnabled = false; spinner.startAnimation(nil)
        pushState.stringValue = "正在向 push.yakteam.com 发一条测试推送…"
        Actions.shared.testPush { [weak self] out in
            guard let self = self else { return }
            self.verifyButton.isEnabled = true
            self.spinner.stopAnimation(nil)
            self.pushState.stringValue = out.contains("已被端点接受")
                ? "✓ 推送被接受 —— 若手机仍不响，问题在 App/系统侧（通知权限、专注模式、后台清理）"
                : "见弹窗里的详细判读"
            OutputWindow.shared.show(title: "推送 token 验证结果", text: out)
        }
    }

    @objc private func runDoctor() {
        doctorButton.isEnabled = false; spinner.startAnimation(nil)
        pushState.stringValue = "正在体检（只读检查，不碰串口）…"
        Actions.shared.doctor { [weak self] out in
            guard let self = self else { return }
            self.doctorButton.isEnabled = true
            self.spinner.stopAnimation(nil)
            self.pushState.stringValue = "体检完成，见弹窗"
            OutputWindow.shared.show(title: "CellBridge 体检报告", text: out)
        }
    }

    func refresh() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let ds = DataStore.shared
            let push = ds.pushStatus()
            var rows: [[String]] = ds.loadConfig().map { ($0.0, $0.1) }.map { [$0.0, $0.1] }
            rows.append(["项目根目录", AppPaths.home])
            rows.append(["二进制 · 网关", AppPaths.gatewayBin + (FileManager.default.fileExists(atPath: AppPaths.gatewayBin) ? "（存在）" : "（缺失，需先编译）")])
            rows.append(["二进制 · 音频桥", AppPaths.audioBin + (FileManager.default.fileExists(atPath: AppPaths.audioBin) ? "（存在）" : "（缺失）")])
            rows.append(["数据库", kDBPath])
            rows.append(["日志目录", kLogDir])
            rows.append(["PushKit token 文件", push.tokenConfigured ? "已写入（\(push.tokenLength) 字符）" : "未写入"])
            rows.append(["token 是否已进运行配置", push.inRunningConfig ? "是" : "否（需重启网关）"])
            if push.hasEvent { rows.append(["最近一次推送日志", push.lastEvent]) }
            rows.append(["adb 工具", kAdbPath + (FileManager.default.fileExists(atPath: kAdbPath) ? "（存在）" : "（不存在，mixer 状态将不可查）")])
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.configTable.update(rows)
                if !self.saveButton.isEnabled { return }   // 动作进行中不覆盖提示
                if push.tokenConfigured && push.inRunningConfig {
                    self.pushState.stringValue = "当前状态：已配置且已生效 ✓"
                } else if push.tokenConfigured {
                    self.pushState.stringValue = "当前状态：token 已写入但未生效 → 点「写入并重启」"
                } else {
                    self.pushState.stringValue = "当前状态：未配置 → 挂起/锁屏来电不会振铃"
                }
            }
        }
    }
}

// MARK: - 主窗口

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: NSWindow!
    var sidebarStack: NSStackView!
    var sidebarButtons: [NSButton] = []
    var contentContainer: NSView!
    var pageHost: NSView!
    var statusLabel: NSTextField!
    var pages: [Page] = []
    var titles: [String] = []
    var currentIndex = 0
    var timer: Timer?

    func applicationDidFinishLaunching(_: Notification) {
        let overview = OverviewPage()
        let calls = CallsPage()
        let messages = MessagesPage()
        let audio = AudioPage()
        let logs = LogsPage()
        let config = ConfigPage()
        pages = [overview, calls, messages, audio, logs, config]
        titles = ["概览", "通话", "短信", "音频", "日志", "参数"]

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "CellBridge Console"
        window.delegate = self
        window.titlebarAppearsTransparent = false
        window.minSize = NSSize(width: 900, height: 620)

        // 布局：侧栏 + 内容
        let sidebar = NSVisualEffectView()
        sidebar.material = .sidebar
        sidebar.blendingMode = .behindWindow
        sidebar.state = .active

        sidebarStack = NSStackView()
        sidebarStack.orientation = .vertical
        sidebarStack.spacing = 4
        sidebarStack.alignment = .leading
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        sidebarStack.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(sidebarStack)

        contentContainer = NSView()
        contentContainer.translatesAutoresizingMaskIntoConstraints = false

        // ── 顶部控制条：一键部署 ──────────────────────────────
        // 只调已有脚本，不重新实现逻辑：命令行能复现同一条命令。
        let controlBar = NSVisualEffectView()
        controlBar.material = .headerView
        controlBar.blendingMode = .withinWindow
        controlBar.state = .active
        controlBar.translatesAutoresizingMaskIntoConstraints = false

        let barStack = NSStackView()
        barStack.orientation = .horizontal
        barStack.spacing = 6
        barStack.translatesAutoresizingMaskIntoConstraints = false

        let controls: [(String, String, Selector)] = [
            ("启动",   "play.fill",         #selector(actStart)),
            ("停止",   "stop.fill",         #selector(actStop)),
            ("重启",   "arrow.clockwise",   #selector(actRestart)),
            ("重编译", "hammer",            #selector(actRebuild)),
            ("体检",   "stethoscope",       #selector(actDoctor)),
            ("日志",   "doc.text",          #selector(actLogs)),
            ("目录",   "folder",            #selector(actProject)),
        ]
        for (title, symbol, sel) in controls {
            let b = NSButton(title: title, target: self, action: sel)
            b.bezelStyle = .rounded
            b.font = NSFont.systemFont(ofSize: 12)
            b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            b.imagePosition = .imageLeading
            b.translatesAutoresizingMaskIntoConstraints = false
            barStack.addArrangedSubview(b)
        }
        statusLabel = NSTextField(labelWithString: "就绪")
        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        barStack.addArrangedSubview(statusLabel)
        controlBar.addSubview(barStack)

        pageHost = NSView()
        pageHost.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(controlBar)
        contentContainer.addSubview(pageHost)

        let title = NSTextField(labelWithString: "CellBridge")
        title.font = NSFont.systemFont(ofSize: 15, weight: .bold)
        title.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(title)

        window.contentView?.addSubview(sidebar)
        window.contentView?.addSubview(contentContainer)

        NSLayoutConstraint.activate([
            sidebar.topAnchor.constraint(equalTo: window.contentView!.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor),
            sidebar.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 176),

            title.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 44),
            title.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 18),

            sidebarStack.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 18),
            sidebarStack.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 12),
            sidebarStack.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -12),

            contentContainer.topAnchor.constraint(equalTo: window.contentView!.topAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor),
            contentContainer.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor),

            controlBar.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            controlBar.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            controlBar.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            controlBar.heightAnchor.constraint(equalToConstant: 44),

            barStack.centerYAnchor.constraint(equalTo: controlBar.centerYAnchor),
            barStack.leadingAnchor.constraint(equalTo: controlBar.leadingAnchor, constant: 16),
            barStack.trailingAnchor.constraint(lessThanOrEqualTo: controlBar.trailingAnchor, constant: -16),

            pageHost.topAnchor.constraint(equalTo: controlBar.bottomAnchor),
            pageHost.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            pageHost.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            pageHost.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
        ])

        for (i, t) in titles.enumerated() {
            let b = NSButton(title: "  \(t)", target: self, action: #selector(sidebarTap(_:)))
            b.bezelStyle = .regularSquare
            b.isBordered = false
            b.tag = i
            b.font = NSFont.systemFont(ofSize: 13)
            b.contentTintColor = .labelColor
            b.translatesAutoresizingMaskIntoConstraints = false
            sidebarStack.addArrangedSubview(b)
            b.widthAnchor.constraint(equalTo: sidebarStack.widthAnchor, constant: -8).isActive = true
            b.heightAnchor.constraint(equalToConstant: 30).isActive = true
            sidebarButtons.append(b)
        }

        selectPage(0)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        timer = Timer.scheduledTimer(withTimeInterval: kRefreshInterval, repeats: true) { [weak self] _ in
            self?.refreshCurrent()
        }
        Actions.shared.onFinish = { [weak self] msg in
            self?.statusLabel.stringValue = msg.replacingOccurrences(of: "\n", with: " · ")
        }
        refreshCurrent()
    }

    // MARK: 控制条动作

    @objc private func actStart()   { Actions.shared.start() }
    @objc private func actStop()    { Actions.shared.stop() }
    @objc private func actRestart() { Actions.shared.restart() }
    @objc private func actRebuild() { Actions.shared.rebuild() }
    @objc private func actLogs()    { Actions.shared.openLogs() }
    @objc private func actProject() { Actions.shared.openProject() }

    @objc private func actDoctor() {
        statusLabel.stringValue = "正在体检…"
        Actions.shared.doctor { out in
            OutputWindow.shared.show(title: "CellBridge 体检报告", text: out)
        }
    }

    @objc private func sidebarTap(_ sender: NSButton) { selectPage(sender.tag) }

    private func selectPage(_ idx: Int) {
        currentIndex = idx
        pageHost.subviews.forEach { $0.removeFromSuperview() }
        let pv = pages[idx].view
        pv.translatesAutoresizingMaskIntoConstraints = false
        pageHost.addSubview(pv)
        NSLayoutConstraint.activate([
            pv.topAnchor.constraint(equalTo: pageHost.topAnchor),
            pv.bottomAnchor.constraint(equalTo: pageHost.bottomAnchor),
            pv.leadingAnchor.constraint(equalTo: pageHost.leadingAnchor),
            pv.trailingAnchor.constraint(equalTo: pageHost.trailingAnchor),
        ])
        for (i, b) in sidebarButtons.enumerated() {
            b.layer?.cornerRadius = 6
            b.wantsLayer = true
            b.layer?.backgroundColor = i == idx
                ? NSColor.quaternaryLabelColor.cgColor
                : NSColor.clear.cgColor
            b.contentTintColor = i == idx ? .labelColor : .secondaryLabelColor
        }
        refreshCurrent()
    }

    private func refreshCurrent() {
        guard currentIndex < pages.count else { return }
        pages[currentIndex].refresh()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool { true }
}

// MARK: - 入口

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
