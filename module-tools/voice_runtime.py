#!/usr/bin/env python3
"""
DjiPhone 模块侧语音运行时管理。

将 MaVo/DJOneHub 的 ADB 语音路由流程移植为 Python：
1. 通过模块 ADB 接口（interface 6 / subclass 0x42）推送语音运行时组件；
2. insmod qdc507 内核声卡驱动，启动 alsaucm VoLTE 校准；
3. 运行 mavo-pcm-bridge 建立 D4/UAC 语音路由，使 USB 音频承载真实通话语音。

运行时文件不在本仓库分发：经用户确认后从上游固定 commit 下载并做 SHA-256 校验
（与 DJOneHub-mac-enhanced 的 OPEN_SOURCE_SCOPE 约定一致）。
"""
import hashlib
import os
import struct
import threading
import time
import urllib.request

import usb.core
import usb.util

VENDOR_ID = 0x2CA3
PRODUCT_ID = 0x4006
ALT_VENDOR_ID = 0x2C7C
ALT_PRODUCT_ID = 0x0125

ADB_MAX_PAYLOAD = 4096
ADB_VERSION = 0x01000001

CMD_CNXN = 0x4E584E43
CMD_AUTH = 0x48545541
CMD_OPEN = 0x4E45504F
CMD_OKAY = 0x59414B4F
CMD_WRTE = 0x45545257
CMD_CLSE = 0x45534C43

UPSTREAM_COMMIT = '0443dfdaf8aec086fd76ba2ee9152fd908114524'
UPSTREAM_BASE = f'https://raw.githubusercontent.com/moluncn/mavo/{UPSTREAM_COMMIT}/Resources/ModuleVoice/'
RUNTIME_FILES = [
    {'name': 'qdc507_aprv3.ko', 'mode': 0o644, 'sha256': '3d82d3dec4f1e323201bba87156df9d41438e08314097353f2607f9117211d4a'},
    {'name': 'qdc507_voice.ko', 'mode': 0o644, 'sha256': 'ed3821682d5309969a01c764192c83feff9669c61ef237c69475cd1619cf296c'},
    {'name': 'mavo-pcm-bridge.armv7', 'mode': 0o755, 'sha256': '88d47c15e61d1428a59c821fed804c2e6490e82859a085062f21966b58d167fc'},
]
KERNEL_RELEASE = '3.18.44'
CARD_NAME = 'mdm9607-tomtom-i2s-snd-card'
REQUIRED_DEVICES = ['/dev/snd/controlC0', '/dev/snd/pcmC0D4p', '/dev/snd/pcmC0D4c',
                    '/dev/snd/pcmC0D5p', '/dev/snd/pcmC0D6c']
MODULES = [{'file': 'qdc507_aprv3.ko', 'name': 'qdc507_aprv3'},
           {'file': 'qdc507_voice.ko', 'name': 'qdc507_voice'}]

VOICE_REMOTE_DIR = '/tmp/mavo-call'
ROUTE_PID_FILE = '/run/mavo-voice-route.pid'
ROUTE_LOG_FILE = '/run/mavo-voice-route.log'
CALIB_PID_FILE = '/run/mavo-alsaucm.pid'
CALIB_LOG_FILE = '/run/mavo-alsaucm.log'

RUNTIME_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'voice-runtime')

_state = {
    'lock': threading.Lock(),
    'ready': False,
    'last_error': '',
    'last_attempt': 0.0,
    'retry_after': 0.0,
    'detail': '',
}


class ADBError(Exception):
    pass


class ADBAuthRequired(ADBError):
    pass


class ADBClient:
    """面向 DJI/QDC507 模块 ADB 接口的最小 ADB 客户端（shell + push）。"""

    def __init__(self):
        self.dev = None
        self.iface = None
        self.ep_in = None
        self.ep_out = None
        self.remote_max_payload = ADB_MAX_PAYLOAD
        self.next_local_id = 1
        self.connected = False
        self._lock = threading.Lock()
        self._open_device()

    def _open_device(self):
        dev = usb.core.find(idVendor=VENDOR_ID, idProduct=PRODUCT_ID)
        if dev is None:
            dev = usb.core.find(idVendor=ALT_VENDOR_ID, idProduct=ALT_PRODUCT_ID)
        if dev is None:
            raise ADBError('未找到 DJI/Quectel USB 模块 (2ca3:4006)')
        cfg = dev.get_active_configuration()
        target = None
        for intf in cfg:  # 每个 intf 是一个 altsetting 描述符
            try:
                num = intf.bInterfaceNumber
                sub = intf.bInterfaceSubClass
            except AttributeError:
                continue
            if num != 6 and sub != 66:
                continue
            ep_in = ep_out = None
            for ep in intf:
                if (ep.bmAttributes & 0x03) != 2:  # bulk
                    continue
                if ep.bEndpointAddress & 0x80:
                    ep_in = ep.bEndpointAddress
                else:
                    ep_out = ep.bEndpointAddress
            if ep_in is not None and ep_out is not None:
                target = (num, ep_in, ep_out)
                break
        if not target:
            raise ADBError('模块上没有找到 ADB 接口（interface 6 / subclass 0x42）')
        iface, ep_in, ep_out = target
        try:
            if dev.is_kernel_driver_active(iface):
                dev.detach_kernel_driver(iface)
        except Exception:
            pass
        usb.util.claim_interface(dev, iface)
        self.dev = dev
        self.iface = iface
        self.ep_in = ep_in
        self.ep_out = ep_out

    def close(self):
        try:
            if self.dev is not None:
                try:
                    usb.util.release_interface(self.dev, self.iface)
                except Exception:
                    pass
                usb.util.dispose_resources(self.dev)
        finally:
            self.dev = None

    # ---- 底层收发 ----
    def _bulk_write(self, payload, timeout_ms):
        if not payload:
            return
        sent = self.dev.write(self.ep_out, payload, timeout=timeout_ms)
        if sent != len(payload):
            raise ADBError(f'ADB bulk write 短传输: {sent}/{len(payload)}')

    def _bulk_read(self, size, timeout_ms):
        try:
            return bytes(self.dev.read(self.ep_in, size, timeout=timeout_ms))
        except usb.core.USBError as e:
            if 'timeout' in str(e).lower() or getattr(e, 'errno', None) in (19, 60, 110):
                return b''  # 超时 → 空读，由调用方的 deadline 逻辑处理
            raise ADBError(f'ADB bulk read: {e}')

    @staticmethod
    def _header(cmd, arg0, arg1, payload):
        return struct.pack('<6I', cmd, arg0, arg1, len(payload),
                           sum(payload) & 0xFFFFFFFF, cmd ^ 0xFFFFFFFF)

    def _send(self, cmd, arg0, arg1, payload=b'', timeout_ms=2000):
        self._bulk_write(self._header(cmd, arg0, arg1, payload), timeout_ms)
        if payload:
            self._bulk_write(payload, timeout_ms)

    def _read_exact(self, n, deadline):
        out = b''
        while len(out) < n and time.time() < deadline:
            chunk = self._bulk_read(512, 100)
            if not chunk:
                continue
            out += chunk[:n - len(out)]
        if len(out) != n:
            raise ADBError(f'等待模块 ADB 数据超时（需要 {n} 字节，得到 {len(out)}）')
        return out

    def _receive(self, deadline):
        header = self._read_exact(24, deadline)
        cmd, arg0, arg1, length, checksum, _ = struct.unpack('<6I', header)
        if length > ADB_MAX_PAYLOAD:
            raise ADBError(f'ADB 消息长度无效: {length}')
        payload = self._read_exact(length, deadline)
        if (sum(payload) & 0xFFFFFFFF) != checksum:
            raise ADBError('ADB 消息校验和不匹配')
        return cmd, arg0, arg1, payload

    # ---- 连接与服务 ----
    def _connect(self):
        if self.connected:
            return
        banner = b'host::MaVo\x00'
        def send_cnxn():
            self._send(CMD_CNXN, ADB_VERSION, ADB_MAX_PAYLOAD, banner)
        send_cnxn()
        deadline = time.time() + 8
        stale = 0
        while time.time() < deadline:
            cmd, a0, a1, payload = self._receive(deadline)
            if cmd == CMD_AUTH:
                raise ADBAuthRequired('模块 ADB 要求认证，无法自动控制通话组件')
            if cmd == CMD_CNXN:
                if a1 > 0 and a1 < self.remote_max_payload:
                    self.remote_max_payload = a1
                self.connected = True
                return
            if cmd in (CMD_WRTE, CMD_OKAY, CMD_CLSE):
                stale += 1
                if stale > 64:
                    raise ADBError('ADB 旧流无法清理')
                if a0 and a1:
                    self._send(CMD_CLSE, a1, a0)
                send_cnxn()
                continue
            raise ADBError(f'模块未接受 ADB CNXN（command=0x{cmd:08X}）')
        raise ADBError('等待模块接受 ADB CNXN 超时')

    def _open_service(self, service):
        payload = service.encode() + b'\x00'
        if len(payload) > self.remote_max_payload:
            raise ADBError('ADB 服务命令过长')
        local_id = self.next_local_id
        self.next_local_id = self.next_local_id + 1 or 1
        self._send(CMD_OPEN, local_id, 0, payload)
        deadline = time.time() + 8
        while time.time() < deadline:
            cmd, a0, a1, p = self._receive(deadline)
            if cmd == CMD_OKAY and a0 and a1 == local_id and not p:
                return (local_id, a0)
            if cmd == CMD_CNXN and a1 > 0:
                self.remote_max_payload = min(self.remote_max_payload, a1)
                continue
            if cmd == CMD_CLSE:
                if a1 == local_id:
                    raise ADBError('模块拒绝 ADB 服务')
                if a0 and a1:
                    self._send(CMD_CLSE, a1, a0)
                continue
            if cmd == CMD_WRTE:
                if a0 and a1:
                    self._send(CMD_CLSE, a1, a0)
                continue
            raise ADBError('模块拒绝 ADB 服务')
        raise ADBError('等待模块打开 ADB 服务超时')

    def _write_stream(self, stream, data, timeout_ms=5000):
        local_id, remote_id = stream
        if len(data) > self.remote_max_payload:
            raise ADBError('ADB sync 数据块过大')
        self._send(CMD_WRTE, local_id, remote_id, data, timeout_ms)
        deadline = time.time() + 10
        cmd, a0, a1, p = self._receive(deadline)
        if cmd != CMD_OKAY or a0 != remote_id or a1 != local_id or p:
            raise ADBError('模块未确认 ADB 数据块')

    def _close_stream(self, stream):
        local_id, remote_id = stream
        try:
            self._send(CMD_CLSE, local_id, remote_id)
            deadline = time.time() + 5
            while time.time() < deadline:
                cmd, a0, a1, p = self._receive(deadline)
                if cmd == CMD_CLSE and a0 == remote_id and a1 == local_id and not p:
                    return
                if cmd == CMD_WRTE and a0 == remote_id and a1 == local_id:
                    self._send(CMD_OKAY, local_id, remote_id)
                    continue
                return
        except Exception:
            pass

    # ---- 对外能力：shell / push ----
    def shell_checked(self, command, timeout=8.0):
        """执行 shell 命令，返回 (输出, 退出码)。"""
        with self._lock:
            if self.dev is None:
                raise ADBError('ADB 通道未打开')
            self._connect()
            token = f'{os.getpid()}{int(time.time()*1000)%1000000}'
            wrapped = ('{ ' + command + '; }; __mavo_status=$?; '
                       f"printf '\\n__MAVO_STATUS_{token}_%u__\\n' \"$__mavo_status\"")
            stream = self._open_service('shell:' + wrapped)
            output = b''
            deadline = time.time() + timeout
            while time.time() < deadline:
                try:
                    cmd, a0, a1, p = self._receive(deadline)
                except ADBError:
                    self.connected = False
                    self._close_stream(stream)
                    raise
                if cmd == CMD_WRTE and a0 == stream[1] and a1 == stream[0]:
                    output += p
                    self._send(CMD_OKAY, stream[0], stream[1])
                elif cmd == CMD_CLSE and a1 == stream[0]:
                    if a0:
                        self._send(CMD_CLSE, stream[0], stream[1])
                    marker = f'__MAVO_STATUS_{token}_'.encode()
                    idx = output.rfind(marker)
                    if idx == -1:
                        self.connected = False
                        raise ADBError('模块 shell 没有返回退出状态')
                    rest = output[idx + len(marker):]
                    end = rest.find(b'__')
                    status = int(rest[:end])
                    text = output[:idx].decode('utf-8', errors='replace')
                    return text, status
            self.connected = False
            self._close_stream(stream)
            raise ADBError('等待模块 shell 超时')

    def push(self, data, remote_path, mode, timeout=30.0):
        with self._lock:
            if self.dev is None:
                raise ADBError('ADB 通道未打开')
            if ',' in remote_path or '\x00' in remote_path:
                raise ADBError('ADB push 目标路径无效')
            self._connect()
            stream = self._open_service('sync:')
            try:
                name = f'{remote_path},{mode}'.encode()
                self._write_stream(stream, b'SEND' + struct.pack('<I', len(name)) + name, int(timeout * 1000))
                chunk_cap = ADB_MAX_PAYLOAD - 8
                for off in range(0, len(data), chunk_cap):
                    chunk = data[off:off + chunk_cap]
                    self._write_stream(stream, b'DATA' + struct.pack('<I', len(chunk)) + chunk, int(timeout * 1000))
                self._write_stream(stream, b'DONE' + struct.pack('<I', int(time.time())), int(timeout * 1000))
                response = b''
                deadline = time.time() + 20
                while len(response) < 8 and time.time() < deadline:
                    cmd, a0, a1, p = self._receive(deadline)
                    if cmd == CMD_WRTE and a0 == stream[1] and a1 == stream[0]:
                        response += p
                        self._send(CMD_OKAY, stream[0], stream[1])
                    elif cmd == CMD_CLSE:
                        raise ADBError('ADB sync 提前关闭')
                if len(response) < 8:
                    raise ADBError('等待模块 ADB sync 响应超时')
                rid = response[:4]
                value = struct.unpack('<I', response[4:8])[0]
                if rid == b'FAIL':
                    detail = response[8:8 + value].decode('utf-8', errors='replace') if value else ''
                    raise ADBError(f'模块拒绝文件传输：{detail}')
                if rid != b'OKAY' or value != 0:
                    raise ADBError('ADB sync 返回无效状态')
            finally:
                self._close_stream(stream)


# ---- 运行时文件下载与校验 ----
def runtime_installed():
    for f in RUNTIME_FILES:
        path = os.path.join(RUNTIME_DIR, f['name'])
        if not os.path.exists(path):
            return False, '尚未从上游安装语音运行时'
        with open(path, 'rb') as fh:
            if hashlib.sha256(fh.read()).hexdigest() != f['sha256']:
                return False, '本地语音运行时校验失败，请重新安装'
    return True, '已从 moluncn/mavo@' + UPSTREAM_COMMIT[:7] + ' 校验安装'


def provision_runtime():
    """下载并校验语音运行时（需要用户在界面上明确确认后调用）。"""
    os.makedirs(RUNTIME_DIR, exist_ok=True)
    for f in RUNTIME_FILES:
        url = UPSTREAM_BASE + f['name']
        with urllib.request.urlopen(url, timeout=60) as r:
            data = r.read()
        digest = hashlib.sha256(data).hexdigest()
        if digest != f['sha256']:
            raise ADBError(f'{f["name"]} SHA-256 校验失败，已丢弃下载')
        path = os.path.join(RUNTIME_DIR, f['name'])
        with open(path, 'wb') as fh:
            fh.write(data)
        os.chmod(path, f['mode'])


def _voice_shell(adb, cmd, timeout=8.0):
    out, status = adb.shell_checked(cmd, timeout)
    if status != 0:
        msg = out.strip()[-500:] if out.strip() else f'返回状态 {status}'
        raise ADBError(f'模块命令执行失败：{msg}')


def _device_checks_cmd():
    parts = [f"test -c '{d}'" for d in REQUIRED_DEVICES]
    parts.append(f"grep -Fq '{CARD_NAME}' /proc/asound/cards")
    return ' && '.join(parts)


def _ensure_calibration(adb):
    cmd = (
        "owned=0; "
        f"if test -s '{CALIB_PID_FILE}'; then "
        f"read pid expected_start < '{CALIB_PID_FILE}' || true; "
        'current_start=$(cut -d \' \' -f 22 "/proc/$pid/stat" 2>/dev/null); '
        'argv0=$(tr \'\\000\' \'\\n\' < "/proc/$pid/cmdline" 2>/dev/null | sed -n \'1p\'); '
        'test "$current_start" = "$expected_start" && test "$argv0" = /usr/bin/alsaucm_test && owned=1 || true; fi; '
        'if test "$owned" -eq 0; then '
        'for proc in /proc/[0-9]*; do '
        'test -r "$proc/cmdline" || continue; '
        'argv0=$(tr \'\\000\' \'\\n\' < "$proc/cmdline" 2>/dev/null | sed -n \'1p\'); '
        'test "$argv0" = /usr/bin/alsaucm_test || continue; '
        'oldpid=${proc##*/}; kill -TERM "$oldpid" 2>/dev/null || true; '
        'n=0; while kill -0 "$oldpid" 2>/dev/null && test "$n" -lt 30; do sleep 0.1; n=$((n+1)); done; '
        'kill -0 "$oldpid" 2>/dev/null && exit 71 || true; done; '
        f"rm -f /run/alsaucm_test '{CALIB_PID_FILE}' '{CALIB_LOG_FILE}'; "
        f"nohup /usr/bin/alsaucm_test </dev/null >> '{CALIB_LOG_FILE}' 2>&1 & pid=$!; "
        'starttime=$(cut -d \' \' -f 22 "/proc/$pid/stat" 2>/dev/null); '
        f"printf '%s %s\\n' \"$pid\" \"$starttime\" > '{CALIB_PID_FILE}'; "
        'n=0; while test "$n" -lt 50 && test ! -p /run/alsaucm_test; do '
        'kill -0 "$pid" 2>/dev/null || exit 72; sleep 0.1; n=$((n+1)); done; '
        'test -p /run/alsaucm_test || exit 73; fi; '
        f"if ! grep -q 'ACDB -> Sent VocProc Cal!' '{CALIB_LOG_FILE}' 2>/dev/null; then "
        "printf 'open snd_soc_msm_9x07_Tomtom_I2S\\n' > /run/alsaucm_test; "
        "printf 'set _verb VoLTE\\n' > /run/alsaucm_test; "
        "printf 'set _enadev Auxpcm Rx\\n' > /run/alsaucm_test; "
        "printf 'set _enadev Auxpcm Tx\\n' > /run/alsaucm_test; "
        'n=0; while test "$n" -lt 100; do '
        f"grep -q 'ACDB -> Sent VocProc Cal!' '{CALIB_LOG_FILE}' 2>/dev/null && break; "
        'sleep 0.1; n=$((n+1)); done; fi; '
        f"grep -q 'ACDB -> Sent VocProc Cal!' '{CALIB_LOG_FILE}'"
    )
    out, status = adb.shell_checked(cmd, 25)
    if status != 0:
        detail, _ = adb.shell_checked(f"test ! -f '{CALIB_LOG_FILE}' || tail -n 100 '{CALIB_LOG_FILE}'", 8)
        msg = detail.strip() or out.strip()
        raise ADBError(f'模块 VoLTE ACDB 校准服务没有就绪：{msg[-500:]}')


def _route_is_ready(adb):
    """严格判定：bridge 存活 + 日志激活 + audio_enable + PCM 双向 RUNNING。"""
    return _route_state(adb, strict=True)


def _route_is_active(adb):
    """宽松判定：bridge 进程存活且日志已报告 VoLTE route session active。
    （audio_enable 与 PCM RUNNING 需等 Mac 打开 UAC 流，可能滞后数秒）"""
    return _route_state(adb, strict=False)


def _route_state(adb, strict):
    helper = VOICE_REMOTE_DIR + '/mavo-pcm-bridge.armv7'
    cmd = (f"test -s '{ROUTE_PID_FILE}' && read pid expected_start < '{ROUTE_PID_FILE}' && "
           'test "$(cut -d \' \' -f 22 "/proc/$pid/stat" 2>/dev/null)" = "$expected_start" && '
           f'test "$(tr \'\\000\' \'\\n\' < "/proc/$pid/cmdline" 2>/dev/null | sed -n \'1p\')" = \'{helper}\' && '
           'tr \'\\000\' \'\\n\' < "/proc/$pid/cmdline" 2>/dev/null | grep -q \'^--voice-route-session$\' && '
           f"grep -q 'VoLTE route session active on hw:0,4' '{ROUTE_LOG_FILE}'")
    if strict:
        cmd += (' && test "$(cat /sys/class/android_usb/f_audio/audio_enable)" = 1 && '
                "grep -q '^state: RUNNING' /proc/asound/card0/pcm4p/sub0/status && "
                "grep -q '^state: RUNNING' /proc/asound/card0/pcm4c/sub0/status")
    try:
        _, status = adb.shell_checked(cmd, 8)
    except ADBAuthRequired:
        raise
    except ADBError:
        return False
    return status == 0


def _route_is_stopped(adb):
    helper = VOICE_REMOTE_DIR + '/mavo-pcm-bridge.armv7'
    cmd = ('owned=0; '
           f"if test -s '{ROUTE_PID_FILE}'; then "
           f"read pid expected_start < '{ROUTE_PID_FILE}' || true; "
           'current_start=$(cut -d \' \' -f 22 "/proc/$pid/stat" 2>/dev/null); '
           'argv0=$(tr \'\\000\' \'\\n\' < "/proc/$pid/cmdline" 2>/dev/null | sed -n \'1p\'); '
           'args=$(tr \'\\000\' \'\\n\' < "/proc/$pid/cmdline" 2>/dev/null); '
           'if test "$current_start" = "$expected_start" && '
           f'test "$argv0" = \'{helper}\' && '
           'printf \'%s\\n\' "$args" | grep -q \'^--voice-route-session$\'; '
           f'then owned=1; else rm -f \'{ROUTE_PID_FILE}\'; fi; fi; '
           'test "$owned" -eq 0')
    _, status = adb.shell_checked(cmd, 8)
    return status == 0


def ensure_voice_route(force=False):
    """确保模块侧 D4/UAC 语音路由就绪。成功返回 True；失败抛 ADBError。"""
    with _state['lock']:
        if _state['ready'] and not force:
            return True
        if not force and time.time() < _state['retry_after'] and _state['last_error']:
            raise ADBError(f'语音路由暂不可用：{_state["last_error"]}')
        try:
            _start_voice_route()
            _state['ready'] = True
            _state['last_error'] = ''
            _state['detail'] = '语音路由就绪（UAC 语音已启用）'
            return True
        except Exception as e:
            _state['ready'] = False
            _state['last_error'] = str(e)
            _state['retry_after'] = time.time() + 30
            raise
        finally:
            _state['last_attempt'] = time.time()


def _start_voice_route():
    installed, detail = runtime_installed()
    if not installed:
        raise ADBError(f'缺少模块侧语音运行时：{detail}（请在设置中先安装）')
    adb = ADBClient()
    try:
        out, status = adb.shell_checked('id -u', 8)
        if status != 0 or '0' not in out.split():
            raise ADBError(f'模块 ADB 没有 root 控制权限（id -u 返回 {out.strip()!r}）')
        release, status = adb.shell_checked('uname -r', 8)
        if status != 0 or KERNEL_RELEASE not in release:
            raise ADBError(f'模块内核版本与通话驱动不匹配：需要 {KERNEL_RELEASE}，实际 {release.strip()}')
        _voice_shell(adb, f"mkdir -p '{VOICE_REMOTE_DIR}' && chmod 700 '{VOICE_REMOTE_DIR}'", 8)
        for f in RUNTIME_FILES:
            with open(os.path.join(RUNTIME_DIR, f['name']), 'rb') as fh:
                data = fh.read()
            adb.push(data, f'{VOICE_REMOTE_DIR}/{f["name"]}', 0o100000 | f['mode'], 30)
        # 声卡设备检查/驱动加载
        _, status = adb.shell_checked(_device_checks_cmd(), 8)
        sound_ready = status == 0
        if not sound_ready:
            _, status, = adb.shell_checked("grep -q '^qdc507_voice ' /proc/modules", 8)
            if status == 0:
                raise ADBError('检测到旧版 qdc507_voice 声卡仍在内核中；为避免热切换语音驱动，请重启模块后再试')
            for mod in MODULES:
                _, present, = adb.shell_checked(f"grep -q '^{mod['name']} ' /proc/modules", 8)
                if present != 0:
                    continue
                try:
                    _voice_shell(adb, f"insmod '{VOICE_REMOTE_DIR}/{mod['file']}'", 20)
                except ADBError:
                    dmesg, _ = adb.shell_checked('dmesg | tail -n 80', 8)
                    raise ADBError(f'模块音频驱动加载失败：{dmesg.strip()[-500:]}')
        # 等待 ALSA 设备出现
        wait_cmd = ('ready=0; n=0; while test "$n" -lt 100; do '
                    f'if {_device_checks_cmd()}; then ready=1; break; fi; '
                    'sleep 0.2; n=$((n+1)); done; test "$ready" -eq 1')
        _, status = adb.shell_checked(wait_cmd, 25)
        if status != 0:
            dmesg, _ = adb.shell_checked('dmesg | tail -n 80', 8)
            raise ADBError(f'音频驱动已加载，但 ALSA 设备没有出现：{dmesg.strip()[-500:]}')
        _ensure_calibration(adb)
        _, status = adb.shell_checked('test -c /dev/ttyGS0 && test -p /run/voc_svr', 8)
        if status != 0:
            raise ADBError('模块缺少 ttyGS0 或 voc_svr，无法建立 USB 通话桥')
        _voice_shell(adb, f"'{VOICE_REMOTE_DIR}/mavo-pcm-bridge.armv7' --check", 15)
        # 路由已就绪？
        if _route_is_ready(adb):
            return
        if _route_is_active(adb):
            return  # 旧实例仍在服务，直接视为就绪
        # 清理残留 bridge（避免 PCM EBUSY）再启动（[.] 防止 pkill 匹配到自身 shell）
        _voice_shell(adb, "pkill -f 'mavo-pcm-bridge[.]armv7' 2>/dev/null; "
                          "n=0; while pgrep -f 'mavo-pcm-bridge[.]armv7' >/dev/null && test \"$n\" -lt 30; do "
                          'sleep 0.1; n=$((n+1)); done; pgrep -f "mavo-pcm-bridge[.]armv7" >/dev/null && exit 74; '
                          f"rm -f '{ROUTE_PID_FILE}' '{ROUTE_LOG_FILE}'", 15)
        helper = f'{VOICE_REMOTE_DIR}/mavo-pcm-bridge.armv7'
        launch = (f"rm -f '{ROUTE_PID_FILE}' '{ROUTE_LOG_FILE}'; "
                  f"nohup '{helper}' --voice-route-session --verbose "
                  f"</dev/null >> '{ROUTE_LOG_FILE}' 2>&1 & pid=$!; "
                  'starttime=$(cut -d \' \' -f 22 "/proc/$pid/stat" 2>/dev/null); '
                  'case "$pid:$starttime" in :*|*:|*[!0-9:]*) false;; *) '
                  f"printf '%s %s\\n' \"$pid\" \"$starttime\" > '{ROUTE_PID_FILE}';; esac")
        launch_err = None
        try:
            _voice_shell(adb, launch, 8)
        except ADBError as e:
            launch_err = e
        if launch_err:
            # audio_enable=1 可能让 USB gadget 短暂重新枚举 —— 重连 ADB 再验证
            try:
                adb.close()
                time.sleep(2)
                adb = ADBClient()
            except ADBError as e:
                raise ADBError(f'路由启动后 ADB 重连失败: {e}（启动错误: {launch_err}）')
        for _ in range(30):
            if _route_is_ready(adb):
                return
            if _route_is_active(adb):
                # bridge 已激活，等 Mac 打开 UAC 流后 RUNNING 会跟上
                for _ in range(100):
                    if _route_is_ready(adb):
                        return
                    time.sleep(0.2)
                return  # 宽松成功：bridge 存活即认为路由就绪
            time.sleep(0.1)
        route_log, _ = adb.shell_checked(f"test ! -f '{ROUTE_LOG_FILE}' || tail -n 160 '{ROUTE_LOG_FILE}'", 8)
        detail = route_log.strip()[-1000:]
        if launch_err:
            detail = f'{launch_err}\n{detail}'
        raise ADBError(f'模块 D4/UAC 语音路由没有进入 RUNNING：{detail}')
    finally:
        adb.close()


def stop_voice_route():
    """通话结束后拆除语音路由（保留 mixer 状态回滚逻辑）。"""
    with _state['lock']:
        if not _state['ready']:
            _state['detail'] = ''
            return
        try:
            adb = ADBClient()
        except ADBError as e:
            _state['ready'] = False
            _state['last_error'] = str(e)
            return
        try:
            helper = f'{VOICE_REMOTE_DIR}/mavo-pcm-bridge.armv7'
            stop_cmd = ('helper_stopped=1; '
                        'is_owned() { '
                        'current_start=$(cut -d \' \' -f 22 "/proc/$pid/stat" 2>/dev/null); '
                        'argv0=$(tr \'\\000\' \'\\n\' < "/proc/$pid/cmdline" 2>/dev/null | sed -n \'1p\'); '
                        'args=$(tr \'\\000\' \'\\n\' < "/proc/$pid/cmdline" 2>/dev/null); '
                        f'test "$current_start" = "$expected_start" && test "$argv0" = \'{helper}\' && '
                        'printf \'%s\\n\' "$args" | grep -q \'^--voice-route-session$\'; }; '
                        f"if test -s '{ROUTE_PID_FILE}'; then "
                        f"read pid expected_start < '{ROUTE_PID_FILE}' || true; "
                        'case "$pid:$expected_start" in :*|*:|*[!0-9:]*) true;; *) '
                        'if is_owned; then kill -TERM "$pid" 2>/dev/null || true; '
                        'n=0; while is_owned && test "$n" -lt 50; do sleep 0.1; n=$((n+1)); done; '
                        'is_owned && helper_stopped=0 || true; fi;; esac; fi; '
                        f'test "$helper_stopped" -eq 1 && rm -f \'{ROUTE_PID_FILE}\'')
            try:
                adb.shell_checked(stop_cmd, 8)
            except Exception:
                pass
            stopped = False
            for _ in range(20):
                try:
                    if _route_is_stopped(adb):
                        stopped = True
                        break
                except Exception:
                    break
                time.sleep(0.1)
            if not stopped:
                raise ADBError('D4 语音 helper 未确认正常退出；为保留 mixer 回滚，没有发送 SIGKILL')
            last_err = None
            for _ in range(5):
                try:
                    _voice_shell(adb,
                                 'echo 0 > /sys/class/android_usb/f_audio/audio_enable; '
                                 'if test -p /run/voc_svr; then '
                                 'printf \'T\\n\' > /run/voc_svr; '
                                 'printf \'T\\n\' > /run/voc_svr; '
                                 'printf \'B\\n\' > /run/voc_svr; fi; '
                                 'test "$(cat /sys/class/android_usb/f_audio/audio_enable)" = 0', 8)
                    _state['ready'] = False
                    _state['last_error'] = ''
                    _state['detail'] = '语音路由已停止'
                    return
                except ADBError as e:
                    last_err = e
                    time.sleep(0.2)
            raise ADBError(f'T/T/B 路由回滚未确认: {last_err}')
        finally:
            adb.close()
            _state['ready'] = False


def invalidate():
    """模块重启/USB 重新枚举后使路由状态失效，下次部署会完整重跑。"""
    with _state['lock']:
        _state['ready'] = False
        _state['last_error'] = ''
        _state['detail'] = ''


def voice_status():
    installed, detail = runtime_installed()
    return {
        'ready': _state['ready'],
        'last_error': _state['last_error'],
        'detail': _state['detail'],
        'runtime_installed': installed,
        'runtime_detail': detail,
        'runtime_source': f'moluncn/mavo@{UPSTREAM_COMMIT[:7]}',
    }
