#!/usr/bin/env python3
"""verify_cs_route.py — 端到端验证 CS 语音路由：
停网关后借 at_pty_bridge 的 PTY 拨 10010，同时从 rx FIFO 读 PCM 统计非零样本。
"""
import os, sys, time, struct, fcntl, subprocess

RUN = os.path.expanduser("~/.cellbridge/run")
RX = os.path.join(RUN, "cellular-rx.fifo")
TX = os.path.join(RUN, "cellular-tx.fifo")
PTY = open(os.path.join(RUN, "pty_path.txt")).read().strip()
DUR = 12  # 通话采样时长（秒）

def at(cmd, wait=0.8):
    fd = os.open(PTY, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    try:
        os.write(fd, (cmd + "\r").encode())
        time.sleep(wait)
        out = b""
        try:
            while True:
                chunk = os.read(fd, 4096)
                if not chunk:
                    break
                out += chunk
        except BlockingIOError:
            pass
        return out.decode(errors="replace").strip()
    finally:
        os.close(fd)

print("== 清理残留 ==")
subprocess.run(["pkill", "-f", "cellbridge-gateway"], capture_output=True)
subprocess.run(["pkill", "-f", "voice-audio-bridge"], capture_output=True)
subprocess.run(["pkill", "-f", "at_pty_bridge.py"], capture_output=True)
time.sleep(2)

print("== 启动 PTY 桥 ==")
pty_log = open(os.path.join(RUN, "logs", "at-pty.log"), "ab")
subprocess.Popen([sys.executable,
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "at_pty_bridge.py")],
    stdout=pty_log, stderr=pty_log)
time.sleep(5)
PTY = open(os.path.join(RUN, "pty_path.txt")).read().strip()
print("   PTY:", PTY)

print("== 启动音频桥 ==")
ab_log = open(os.path.join(RUN, "logs", "audio-bridge.log"), "ab")
subprocess.Popen([os.path.join(os.path.dirname(os.path.abspath(__file__)), "voice-audio-bridge"),
    "--fifo-rx", RX, "--fifo-tx", TX, "--verbose"], stdout=subprocess.DEVNULL, stderr=ab_log)
time.sleep(3)

# rx FIFO 读者：非阻塞读，统计字节与非零 s16 样本
rx_fd = os.open(RX, os.O_RDONLY | os.O_NONBLOCK)
fcntl.fcntl(rx_fd, fcntl.F_SETFL, os.O_NONBLOCK)
stats = {"bytes": 0, "nonzero": 0, "chunks": 0}
import threading

def drain():
    while not stop.is_set():
        try:
            data = os.read(rx_fd, 16384)
        except BlockingIOError:
            time.sleep(0.02); continue
        except OSError:
            time.sleep(0.05); continue
        if not data:
            continue
        stats["bytes"] += len(data); stats["chunks"] += 1
        n = len(data) // 2
        vals = struct.unpack(f"<{n}h", data[:n*2])
        stats["nonzero"] += sum(1 for v in vals if v != 0)

stop = threading.Event()
t = threading.Thread(target=drain, daemon=True); t.start()

print("== AT 握手 ==")
print("   ATE0:", at("ATE0"))
print("   AT+CLCC:", (at("AT+CLCC") or "(空)")[:80])

print(f"== 拨打 10010，采 {DUR}s ==")
print("   ATD:", (at("ATD10010;", 1.5) or "(无响应)")[:60])
time.sleep(DUR)
print("   CLCC:", (at("AT+CLCC") or "(空)")[:120])
print("== 挂断 ==")
print("   ATH:", (at("ATH") or "(无响应)")[:40])
time.sleep(1)
stop.set(); t.join(timeout=1)

total = stats["bytes"] // 2
print("\n===== 结果 =====")
print(f"收到字节: {stats['bytes']}  (s16 样本: {total})  数据块: {stats['chunks']}")
if total:
    pct = 100.0 * stats["nonzero"] / total
    print(f"非零样本: {stats['nonzero']} ({pct:.1f}%)")
    if pct > 5:
        print("✅ CS 语音路由已打通：蜂窝→Mac 有真实音频")
    else:
        print("❌ 仍是全零静音：需要换 VoiceMMode1 路由")
else:
    print("❌ 一个字节都没收到：UAC 采集未启动")
