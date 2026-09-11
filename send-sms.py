#!/usr/bin/env python3
"""send-sms.py — 通过 SIP MESSAGE 让 CellBridge 网关用蜂窝模块发一条短信。

这是 YakPhone 发短信时走的**同一条通道**，所以用它做测试最贴近真实路径：
不需要网关的 HTTP API token，只需要 SIP 账号（从 config.yaml 读）。

用法：
    ./send-sms.py <号码> <正文>          # 发一条，成功打印 OK
    ./send-sms.py 10010 "测试" --timeout 15

退出码：0 成功 / 1 失败 / 2 用法或配置错误

注意：正文含中文时网关会自动改用 PDU(UCS2) 编码，无需在此处理。
"""

from __future__ import annotations

import hashlib
import os
import re
import socket
import sys
import time

CONFIG = os.path.expanduser("~/.cellbridge/run/config.yaml")
DEFAULT_PORT = 5060
LOCAL_BIND_PORT = 5099


def load_sip_config() -> tuple[str, str, str, int]:
    """从 config.yaml 里取 (username, password, realm, port)。

    只做极简的逐行扫描 —— 这个文件由 start_cellbridge.sh 生成，结构稳定。
    """
    user, password, realm, port = "iphone", "", "cellbridge", DEFAULT_PORT
    try:
        with open(CONFIG, encoding="utf-8") as fh:
            text = fh.read()
    except OSError as exc:
        print(f"读不到配置 {CONFIG}：{exc}", file=sys.stderr)
        raise SystemExit(2)

    for raw in text.splitlines():
        line = raw.strip()
        if line.startswith("realm:"):
            realm = line.split(":", 1)[1].strip().strip('"') or realm
        elif line.startswith("listen:"):
            m = re.search(r":(\d+)\s*$", line)
            if m:
                port = int(m.group(1))
        elif line.startswith("username:"):
            user = line.split(":", 1)[1].strip().strip('"') or user
        elif line.startswith("password:"):
            password = line.split(":", 1)[1].strip().strip('"')

    if not password:
        print("配置里没有 SIP 密码，无法认证", file=sys.stderr)
        raise SystemExit(2)
    return user, password, realm, port


def build_message(to: str, body: str, cseq: int, call_id: str, tag: str,
                  branch: str, user: str, auth: str | None = None) -> str:
    uri = f"sip:{to}@127.0.0.1"
    lines = [
        f"MESSAGE {uri} SIP/2.0",
        f"Via: SIP/2.0/UDP 127.0.0.1:{LOCAL_BIND_PORT};branch={branch};rport",
        "Max-Forwards: 70",
        f"From: <sip:{user}@127.0.0.1>;tag={tag}",
        f"To: <sip:{to}@127.0.0.1>",
        f"Call-ID: {call_id}",
        f"CSeq: {cseq} MESSAGE",
        f"Contact: <sip:{user}@127.0.0.1:{LOCAL_BIND_PORT}>",
    ]
    if auth:
        lines.append(auth)
    lines += [
        "Content-Type: text/plain; charset=UTF-8",
        f"Content-Length: {len(body.encode('utf-8'))}",
        "",
        body,
    ]
    return "\r\n".join(lines)


def digest_header(challenge: str, to: str, user: str, password: str,
                  realm_fallback: str) -> str:
    params: dict[str, str] = {}
    for part in challenge.split(","):
        part = part.strip()
        if "=" in part:
            k, v = part.split("=", 1)
            params[k.strip()] = v.strip().strip('"')
    nonce = params.get("nonce", "")
    realm = params.get("realm", realm_fallback)
    uri = f"sip:{to}@127.0.0.1"
    ha1 = hashlib.md5(f"{user}:{realm}:{password}".encode()).hexdigest()
    ha2 = hashlib.md5(f"MESSAGE:{uri}".encode()).hexdigest()
    cnonce = os.urandom(4).hex()
    resp = hashlib.md5(
        f"{ha1}:{nonce}:00000001:{cnonce}:auth:{ha2}".encode()
    ).hexdigest()
    return (
        f'Authorization: Digest username="{user}", realm="{realm}", '
        f'nonce="{nonce}", uri="{uri}", response="{resp}", '
        f'algorithm=MD5, qop=auth, nc=00000001, cnonce="{cnonce}"'
    )


def main() -> int:
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    timeout = 12.0
    if "--timeout" in sys.argv:
        try:
            timeout = float(sys.argv[sys.argv.index("--timeout") + 1])
        except (IndexError, ValueError):
            print("--timeout 需要一个秒数", file=sys.stderr)
            return 2

    if len(args) < 2:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    to, body = args[0], args[1]

    user, password, realm, port = load_sip_config()
    gateway = ("127.0.0.1", port)

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        sock.bind(("127.0.0.1", LOCAL_BIND_PORT))
    except OSError:
        sock.bind(("127.0.0.1", 0))          # 端口被占就随机取一个
    sock.settimeout(2.0)

    tag = os.urandom(4).hex()
    call_id = os.urandom(8).hex()
    branch = "z9hG4bK" + os.urandom(4).hex()

    sock.sendto(
        build_message(to, body, 1, call_id, tag, branch, user).encode("utf-8"),
        gateway,
    )

    deadline = time.time() + timeout
    authed = False
    last = ""
    while time.time() < deadline:
        try:
            data, _ = sock.recvfrom(8192)
        except socket.timeout:
            continue
        text = data.decode(errors="replace")
        first = text.split("\r\n", 1)[0]
        last = first
        code = 0
        parts = first.split(" ")
        if len(parts) > 1 and parts[1].isdigit():
            code = int(parts[1])

        if code == 401 and not authed:
            hdr = digest_header(text, to, user, password, realm)
            sock.sendto(
                build_message(to, body, 2, call_id, tag, branch, user, hdr)
                .encode("utf-8"),
                gateway,
            )
            authed = True
        elif 200 <= code < 300:
            print(f"OK 已提交发送 -> {to}（{len(body)} 字）")
            return 0
        elif code >= 400:
            print(f"FAIL 网关拒绝：{first}", file=sys.stderr)
            return 1

    print(f"FAIL 超时未收到确认（最后响应：{last or '无'}）", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
