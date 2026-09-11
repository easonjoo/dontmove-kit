#!/usr/bin/env python3
"""at_usb_status.py — USB 直连 AT 端口查询模块状态（只读查询，不拨号不挂断）。"""
import sys, time
import usb.core, usb.util

VID, PID = 0x2CA3, 0x4006
AT_IF, EP_IN, EP_OUT = 2, 0x84, 0x03

dev = usb.core.find(idVendor=VID, idProduct=PID)
if dev is None:
    print("未找到模块"); sys.exit(1)
try:
    if dev.is_kernel_driver_active(AT_IF):
        dev.detach_kernel_driver(AT_IF)
except Exception:
    pass
usb.util.claim_interface(dev, AT_IF)

# 排干残留
t0 = time.time()
while time.time() - t0 < 2:
    try:
        dev.read(EP_IN, 1024, timeout=200)
    except usb.core.USBError:
        break

def at(cmd, wait=2.5):
    dev.write(EP_OUT, (cmd + "\r").encode(), timeout=3000)
    out, t0 = b"", time.time()
    while time.time() - t0 < wait:
        try:
            out += bytes(dev.read(EP_IN, 1024, timeout=150))
        except usb.core.USBError:
            pass
        if b"OK" in out or b"ERROR" in out:
            t1 = time.time()
            while time.time() - t1 < 0.6:
                try:
                    out += bytes(dev.read(EP_IN, 1024, timeout=150))
                except usb.core.USBError:
                    break
            break
    return out.decode(errors="replace").strip()

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
    ("服务小区",   'AT+QENG="servingcell"'),
    ("网络制式",   'AT+QNWINFO'),
]

print("═" * 50)
for name, cmd in CMDS:
    r = at(cmd)
    print(f"── {name}  {cmd}")
    print(r if r else "(无响应)")
    print()
