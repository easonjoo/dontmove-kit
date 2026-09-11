#!/usr/bin/env python3
"""at_status_probe.py — 借 at_pty_bridge 的 PTY 查询模块注册/IMS 状态（查完即退）。

前提：at_pty_bridge.py 在跑（PTY 存在），cellbridge-gateway 已停（否则抢从端）。
"""
import os, sys, time, select

TTY = sys.argv[1] if len(sys.argv) > 1 else None
if not TTY:
    print("用法: at_status_probe.py /dev/ttysNNN"); sys.exit(1)

fd = os.open(TTY, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)

CMDS = [
    ("基带版本",   "AT+CGMR"),
    ("SIM 状态",   "AT+CPIN?"),
    ("网络注册",   "AT+CREG?"),
    ("EPS 注册",   "AT+CEREG?"),
    ("GPRS 注册",  "AT+CGREG?"),
    ("运营商",     "AT+COPS?"),
    ("CFUN",       "AT+CFUN?"),
    ("IMS 配置",   'AT+QCFG="ims"'),
    ("MBN 列表",   'AT+QMBNCFG="List"'),
    ("MBN 自动",   'AT+QMBNCFG="AutoSel"'),
    ("PDP 状态",   "AT+CGACT?"),
    ("呼叫列表",   "AT+CLCC"),
    ("最后错误",   "AT+CEER"),
    ("信号",       "AT+CSQ"),
    ("网络模式",   'AT+QCFG="nwscanseq"'),
    ("服务小区",   'AT+QENG="servingcell"'),
]

def flush():
    while True:
        r, _, _ = select.select([fd], [], [], 0.3)
        if not r: break
        try:
            if not os.read(fd, 4096): break
        except OSError: break

def at(cmd, wait=2.0):
    flush()
    os.write(fd, (cmd + "\r").encode())
    out, t0 = b"", time.time()
    while time.time() - t0 < wait:
        r, _, _ = select.select([fd], [], [], 0.3)
        if r:
            try: out += os.read(fd, 4096)
            except OSError: break
        if b"OK" in out or b"ERROR" in out or b"+CME ERROR" in out:
            # 再多收 0.5s 尾巴
            t1 = time.time()
            while time.time() - t1 < 0.5:
                r, _, _ = select.select([fd], [], [], 0.2)
                if r:
                    try: out += os.read(fd, 4096)
                    except OSError: break
            break
    return out.decode(errors="replace").strip()

print("═" * 50)
for name, cmd in CMDS:
    r = at(cmd)
    print(f"── {name}  {cmd}")
    print(r if r else "(无响应)")
    print()
os.close(fd)
