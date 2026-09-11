#!/usr/bin/env python3
"""
at_pty_bridge.py — 把 QDC507 的 USB AT 通道桥接为 macOS PTY 串口。

CellBridge 网关需要一个串口设备（/dev/cu.*）收发 AT 指令与 URC（RING 等）。
macOS 不会为该模块的 CDC-AT 接口创建串口节点，本脚本用 pty.openpty()
创建一对主从终端：网关打开从端（/dev/ttysNNN），我们把字节双向搬运到
USB bulk 端点。URC（RING/+CRING/+CMT 等）自然透传。

用法：python3 at_pty_bridge.py
  stdout 第一行输出 PTY 从端路径（供启动脚本捕获），其余日志走 stderr。
  注意：与 DJiPhone Kit App 互斥——两者都会占用 USB AT 接口（interface 2）。

诊断：CB_INJECT_RING=<秒> 在启动若干秒后自动注入一条合成来电 URC；
  CB_INJECT_RING_CTL=<路径> 则开一个控制文件，写入一行号码即触发一次。
  用于在只有一部手机时验证入呼链路（见 main() 中的说明）。
  CB_AT_TRACE=1 打开 AT 字节级双向跟踪（输出到 stderr，即 at-pty.log）。
"""
import os
import pty
import sys
import time
import threading

import usb.core
import usb.util

VID, PID = 0x2CA3, 0x4006
AT_IF = 2
EP_IN = 0x84
EP_OUT = 0x03


def log(msg):
    sys.stderr.write(f'[at-pty] {msg}\n')
    sys.stderr.flush()


def open_usb():
    while True:
        dev = usb.core.find(idVendor=VID, idProduct=PID)
        if dev is not None:
            try:
                try:
                    if dev.is_kernel_driver_active(AT_IF):
                        dev.detach_kernel_driver(AT_IF)
                except Exception:
                    pass
                usb.util.claim_interface(dev, AT_IF)
                log('USB AT 接口已占用')
                return dev
            except Exception as e:
                log(f'占用 USB 接口失败（2s 后重试）: {e}')
        else:
            log('未找到模块（2s 后重试）')
        time.sleep(2)


def flush_usb(dev):
    """丢弃端点里残留的上一轮响应。

    模块的 AT 响应缓冲会在主机停止读取后继续累积。若不清空，网关启动后会把
    这些过期响应逐条当成自己命令的回复（读到的 OK 属于几条命令之前），
    于是所有状态判断都错位。
    """
    total = 0
    while True:
        try:
            chunk = bytes(dev.read(EP_IN, 512, timeout=200))
        except Exception:
            break
        if not chunk:
            break
        total += len(chunk)
    if total:
        log(f'已丢弃启动前的残留响应 {total} 字节')


def main():
    master_fd, slave_fd = pty.openpty()
    slave_path = os.ttyname(slave_fd)
    # 故意不关闭 slave_fd。
    # 若从端无人持有，向主端写入会返回 EIO（macOS 上尤其明确）。桥启动时模块
    # 端点里往往残留着上一轮的响应，而网关要 4 秒后才打开从端——这段窗口内的
    # 每次写入都会 EIO。自己持有从端可让主端写入始终有效，从端缓冲区由网关读取，
    # 桥自身不读它，因此不存在数据竞争。
    log(f'PTY 从端: {slave_path}')

    # --- USB 断链自愈 ---------------------------------------------------
    # 模块重启（adb reboot / 掉电）后 USB 重新枚举，旧句柄永久失效，此前
    # 表现为桥对着死句柄无限重试（"No such device" 狂刷），AT 命令全部
    # 无响应，只能手动重启整套服务。现在检测到设备消失即重新枚举、重占
    # 接口，PTTY 从端路径不变，网关无需重启。
    dev_lock = threading.Lock()
    holder = {'dev': None}
    healing = threading.Event()

    def current_dev():
        with dev_lock:
            return holder['dev']

    def is_disconnect(e):
        text = str(e).lower()
        return ('no such device' in text or 'disconnected' in text
                or 'nodev' in text or 'shut down' in text)

    def try_reopen(reason):
        # 只允许一个线程做自愈；其余线程等到自愈完成直接用新句柄。
        if healing.is_set():
            healing.wait()
            return
        healing.set()
        try:
            with dev_lock:
                old = holder['dev']
                try:
                    usb.util.dispose_resources(old)
                except Exception:
                    pass
                log(f'USB 断链自愈（{reason}）：重新枚举模块…')
                holder['dev'] = open_usb()
                flush_usb(holder['dev'])
                log('USB 断链自愈完成')
        finally:
            healing.clear()

    holder['dev'] = open_usb()
    flush_usb(holder['dev'])

    print(slave_path, flush=True)  # 启动脚本读这一行（清空之后才公布，避免读到残留）

    trace = os.environ.get('CB_AT_TRACE', '').strip() == '1'

    def trace_line(tag, data):
        if not trace or not data:
            return
        text = data.decode(errors='replace').replace('\r', '\\r').replace('\n', '\\n')
        log(f'[{tag}] {text}')

    uplink_failures = 0

    def usb2pty():
        nonlocal uplink_failures
        while True:
            try:
                chunk = bytes(current_dev().read(EP_IN, 512, timeout=300))
            except usb.core.USBError as e:
                if is_disconnect(e):
                    try_reopen('上行读到设备消失')
                continue
            except Exception as e:
                if is_disconnect(e):
                    try_reopen('上行读到设备消失')
                else:
                    time.sleep(1)
                continue
            if not chunk:
                continue
            trace_line('模块→Mac', chunk)
            try:
                os.write(master_fd, chunk)
                uplink_failures = 0
            except OSError as e:
                # 绝不 return：曾经一次 EIO 就让上行线程永久退出，此后网关
                # 发出的所有 AT 命令都收不到响应（probe/status/CMGS 全部
                # context deadline exceeded），短信与通话一起失效。
                uplink_failures += 1
                if uplink_failures in (1, 10, 100) or uplink_failures % 500 == 0:
                    log(f'上行写入失败（第 {uplink_failures} 次，继续重试）: {e}')
                time.sleep(0.05)

    def pty2usb():
        while True:
            try:
                data = os.read(master_fd, 4096)
            except OSError as e:
                log(f'读取 PTY 失败（继续）: {e}')
                time.sleep(0.1)
                continue
            if not data:
                time.sleep(0.05)
                continue
            trace_line('Mac→模块', data)
            try:
                current_dev().write(EP_OUT, data, timeout=3000)
            except Exception as e:
                if is_disconnect(e):
                    try_reopen('下行写入设备消失')
                else:
                    log(f'USB 写失败: {e}')
                    time.sleep(0.5)

    threading.Thread(target=usb2pty, daemon=True).start()
    threading.Thread(target=pty2usb, daemon=True).start()

    # --- 诊断用：合成来电注入（默认关闭）---------------------------------
    # 往 PTY 主端写入的字节会出现在从端，也就是网关读到的那一侧，因此可以
    # 伪造一条来电 URC。用于在只有一部手机的情况下验证入呼链路：
    #   注册表 → INVITE → SIP 客户端振铃。
    #   CB_INJECT_RING=<秒>           启动后多少秒自动注入一次（不设则关闭）
    #   CB_INJECT_RING_CTL=<路径>     控制 FIFO：向它写一行号码即触发一次注入
    #   CB_INJECT_RING_NUMBER=<号码>  自动注入用的号码，默认 13800138000
    #   CB_INJECT_RING_HOLD=<秒>      保持时长，默认 20，之后补 NO CARRIER
    # 结束时补 NO CARRIER 是必要的：否则网关会一直以为有活动通话。
    def write_ring(number):
        try:
            os.write(master_fd, f'\r\nRING\r\n+CLIP: "{number}",129,,,,0\r\n'.encode())
        except OSError:
            return False
        return True

    def write_hangup():
        try:
            os.write(master_fd, b'\r\nNO CARRIER\r\n')
        except OSError:
            pass

    inject_after = os.environ.get('CB_INJECT_RING', '').strip()
    if inject_after:
        def inject_ring():
            try:
                delay = float(inject_after)
            except ValueError:
                delay = 8.0
            number = os.environ.get('CB_INJECT_RING_NUMBER', '13800138000')
            try:
                hold = float(os.environ.get('CB_INJECT_RING_HOLD', '20'))
            except ValueError:
                hold = 20.0
            time.sleep(delay)
            log(f'[注入] 合成来电 {number}（保持 {hold:.0f}s）')
            if not write_ring(number):
                return
            time.sleep(hold)
            log('[注入] 合成来电结束（NO CARRIER）')
            write_hangup()

        threading.Thread(target=inject_ring, daemon=True).start()

    ctl_path = os.environ.get('CB_INJECT_RING_CTL', '').strip()
    if ctl_path:
        def inject_control():
            # 轮询普通文件而不是 FIFO：FIFO 的读写端握手在异常退出/时序竞争时
            # 会让读端永久阻塞在 open() 上，触发就失效了。追加一行即触发。
            try:
                open(ctl_path, 'a').close()
            except OSError as e:
                log(f'[注入] 无法创建控制文件: {e}')
                return
            log(f'[注入] 控制通道就绪: {ctl_path}（追加一行号码触发来电，写 end 结束）')
            # 从文件末尾开始读。控制文件是追加式的，上一轮留下的行若被重放，
            # 网关刚启动就会凭空收到一通来电（已实际观察到）。
            try:
                offset = os.path.getsize(ctl_path)
            except OSError:
                offset = 0
            while True:
                try:
                    with open(ctl_path, 'r') as handle:
                        handle.seek(offset)
                        for line in handle:
                            token = line.strip()
                            if not token:
                                continue
                            if token.lower() in ('end', 'hangup', 'bye'):
                                log('[注入] 合成来电结束（NO CARRIER）')
                                write_hangup()
                                continue
                            log(f'[注入] 合成来电 {token}')
                            write_ring(token)
                        offset = handle.tell()
                except OSError as e:
                    log(f'[注入] 控制文件读取失败: {e}')
                time.sleep(0.5)

        threading.Thread(target=inject_control, daemon=True).start()

    log('桥接运行中，Ctrl+C 退出')
    try:
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        pass
    # 跳过 libusb 析构（macOS 上退出时会触发 refcnt 断言崩溃）
    os._exit(0)


if __name__ == '__main__':
    main()
