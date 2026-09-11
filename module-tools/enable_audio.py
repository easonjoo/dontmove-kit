#!/usr/bin/env python3
"""
开启 EG25-G/QDC507 的 USB 音频接口（语音通话用）。
配置写入模块并重启模组，一次配置永久生效。
运行前请先退出 4G 短信助手 App（独占 USB）。
"""
import sys
import time
from sms_server import ModemManager

CMD_CFG = 'AT+QCFG="usbcfg",0x2CA3,0x4006,1,1,1,1,1,0,1'  # audio=1
CMD_SAVE = "AT&W"
CMD_REBOOT = "AT+CFUN=1,1"


def main():
    mm = ModemManager()
    mm._connect()
    if not mm.is_connected():
        print("ERROR: 模块未连接")
        sys.exit(1)

    print("当前 usbcfg:", mm.send_at('AT+QCFG="usbcfg"', timeout=8000))
    print("设置 audio=1:", mm.send_at(CMD_CFG, timeout=8000))
    print("保存配置:", mm.send_at(CMD_SAVE, timeout=8000))
    print("重启模组（约 30-60 秒后重新枚举）...")
    try:
        mm.send_at(CMD_REBOOT, timeout=8000)
    except Exception as e:
        # 重启后 USB 重新枚举，句柄失效属正常
        print(f"模组重启中（{e.__class__.__name__}，属预期）")
    try:
        mm._disconnect()
    except Exception:
        pass
    print("DONE")
    time.sleep(1)


if __name__ == "__main__":
    main()
