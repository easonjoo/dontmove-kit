#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""CellBridgeWidget — 桌面右缘悬浮小组件

  1) 聚合探针线程：采集各组件状态，HTTP 服务 127.0.0.1:8791
     - /data : 状态 JSON
     - /ui   : widget.html（WebView 直接从这里加载，同源免 CORS、加载必成功）
  2) NSPanel：不透明深色 + 原生圆角（contentView layer.cornerRadius），
     置顶、全空间，悬停向左展开显示明细。
"""
import json
import os
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HOME = os.path.expanduser("~")
RUN = os.path.join(HOME, ".cellbridge", "run")
HEARTBEAT = os.path.join(RUN, "logs", "route-rearm.heartbeat")
TS_CLI = "/Applications/Tailscale.app/Contents/MacOS/Tailscale"
ADB = "/usr/local/bin/adb"
GATEWAY = "http://127.0.0.1:8787/api/v1/health"
WIDGET_DIR = os.path.dirname(os.path.abspath(__file__))

_lock = threading.Lock()
_cache = {"ts": 0, "data": {}}


def sh(cmd, timeout=4):
    try:
        p = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=timeout)
        return p.returncode, (p.stdout or "").strip()
    except Exception:
        return -1, ""


def http_ok(url, timeout=2.5):
    code, out = sh(
        "curl -s -m %.1f -o /dev/null -w '%%{http_code} %%{time_total}' %s" % (timeout, url),
        timeout=timeout + 1,
    )
    if code != 0:
        return False, None
    parts = out.split()
    return parts[0] == "200", (float(parts[1]) * 1000 if len(parts) > 1 else None)


def collect():
    d = {}
    ok, ms = http_ok(GATEWAY)
    d["gateway"] = {"ok": ok, "ms": round(ms) if ms else None}

    _, gw = sh("pgrep -x cellbridge-gateway | head -1")
    _, vb = sh("pgrep -f '[v]oice-audio-bridge' | head -1")
    _, ab = sh("pgrep -f '[a]t_pty_bridge.py' | head -1")
    _, rr = sh("pgrep -f '[r]oute-rearm.sh' | head -1")
    d["gateway"]["pid"] = int(gw) if gw.isdigit() else None
    d["voice_bridge"] = {"ok": bool(vb), "pid": int(vb) if vb.isdigit() else None}
    d["at_bridge"] = {"ok": bool(ab), "pid": int(ab) if ab.isdigit() else None}
    d["rearm"] = {"ok": bool(rr), "pid": int(rr) if rr.isdigit() else None}

    tty = os.path.join(RUN, "pty_path.txt")
    try:
        path = open(tty).readline().strip()
        d["at_bridge"]["tty"] = path
        d["at_bridge"]["tty_ok"] = os.path.exists(path) if path else False
    except Exception:
        d["at_bridge"]["tty"] = ""
        d["at_bridge"]["tty_ok"] = False

    try:
        age = round(time.time() - os.stat(HEARTBEAT).st_mtime)
    except Exception:
        age = None
    d["rearm"]["heartbeat_age"] = age

    _, sip = sh("lsof -nP -iUDP:5060 -sTCP:LISTEN 2>/dev/null | tail -1")
    d["sip"] = {"ok": "UDP" in sip}

    stale = time.time() - _cache["ts"] >= 15
    ts = _cache["data"].get("tailscale") if not stale else None
    if ts is None:
        code, ip = sh(TS_CLI + " ip -4 2>/dev/null | head -1", timeout=6)
        ts = {"ok": code == 0 and ip.startswith("100."), "ip": ip if ip else None}
    d["tailscale"] = ts

    mb = _cache["data"].get("module_bridge") if not stale else None
    if mb is None:
        code, pid = sh(ADB + " shell pidof mavo-pcm-bridge 2>/dev/null", timeout=8)
        mb = {"ok": code == 0 and bool(pid.strip()), "pid": pid.strip() or None}
    d["module_bridge"] = mb

    d["now"] = int(time.time())
    return d


def poller():
    while True:
        try:
            data = collect()
            with _lock:
                _cache["data"] = data
                _cache["ts"] = time.time()
        except Exception:
            pass
        time.sleep(3)


HTML_PATH = os.path.join(WIDGET_DIR, "widget.html")


class Handler(BaseHTTPRequestHandler):
    def _send(self, code, ctype, body):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/data":
            with _lock:
                body = json.dumps(_cache["data"]).encode()
            self._send(200, "application/json", body)
        elif self.path in ("/ui", "/", "/ui/"):
            try:
                with open(HTML_PATH, "rb") as f:
                    self._send(200, "text/html; charset=utf-8", f.read())
            except Exception as e:
                self._send(500, "text/plain", str(e).encode())
        else:
            self._send(404, "text/plain", b"404")

    def log_message(self, *a):
        pass


def main():
    threading.Thread(target=poller, daemon=True).start()
    srv = ThreadingHTTPServer(("127.0.0.1", 8791), Handler)
    threading.Thread(target=srv.serve_forever, daemon=True).start()

    import subprocess as sp

    import AppKit
    import Quartz
    from Foundation import NSObject
    from WebKit import WKWebView, WKWebViewConfiguration

    STRIP_W, EXPAND_W = 132.0, 444.0

    app = AppKit.NSApplication.sharedApplication()
    app.setActivationPolicy_(AppKit.NSApplicationActivationPolicyAccessory)

    screen = AppKit.NSScreen.mainScreen().frame()
    card_h = min(520.0, screen.size.height * 0.62)
    right = screen.origin.x + screen.size.width - 10.0
    y = screen.origin.y + (screen.size.height - card_h) / 2.0
    frame0 = Quartz.CGRectMake(right - STRIP_W, y, STRIP_W, card_h)

    panel = AppKit.NSPanel.alloc().initWithContentRect_styleMask_backing_defer_(
        frame0,
        AppKit.NSWindowStyleMaskBorderless,
        AppKit.NSBackingStoreBuffered,
        False,
    )
    panel.setLevel_(AppKit.NSFloatingWindowLevel + 3)
    panel.setOpaque_(True)
    panel.setBackgroundColor_(AppKit.NSColor.colorWithSRGBRed_green_blue_alpha_(0.043, 0.043, 0.051, 1.0))
    panel.setHasShadow_(True)
    panel.setCollectionBehavior_(
        AppKit.NSWindowCollectionBehaviorCanJoinAllSpaces
        | AppKit.NSWindowCollectionBehaviorFullScreenAuxiliary
    )
    # 原生圆角：不依赖 WebView 透明
    content = panel.contentView()
    content.setWantsLayer_(True)
    layer = content.layer()
    layer.setCornerRadius_(28.0)
    layer.setMasksToBounds_(True)

    class Ctl(NSObject):
        def userContentController_didReceiveScriptMessage_(self, uc, msg):
            body = msg.body()
            cmd = body.get("cmd") if isinstance(body, dict) else None
            if cmd == "expand":
                panel.setFrame_display_(
                    Quartz.CGRectMake(right - EXPAND_W, y, EXPAND_W, card_h), True)
            elif cmd == "shrink":
                panel.setFrame_display_(
                    Quartz.CGRectMake(right - STRIP_W, y, STRIP_W, card_h), True)
            elif cmd == "console":
                sp.Popen(["open", "http://127.0.0.1:8787"])
            elif cmd == "quit":
                app.terminate_(None)

    ctl = Ctl.alloc().init()
    conf = WKWebViewConfiguration.alloc().init()
    conf.userContentController().addScriptMessageHandler_name_(ctl, "ctl")

    web = WKWebView.alloc().initWithFrame_configuration_(
        AppKit.NSMakeRect(0, 0, STRIP_W, card_h), conf)
    url = AppKit.NSURL.URLWithString_("http://127.0.0.1:8791/ui")
    web.loadRequest_(AppKit.NSURLRequest.requestWithURL_(url))
    panel.contentView().addSubview_(web)

    panel.makeKeyAndOrderFront_(None)
    panel.orderFrontRegardless()
    AppKit.NSApp.activateIgnoringOtherApps_(True)
    app.run()


if __name__ == "__main__":
    main()
