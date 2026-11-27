import ctypes
import json
import msvcrt
import os
import struct
import threading
import time
import uuid


def register(cid, cmd):
    try:
        import winreg

        root = r"Software\Classes\discord-%s" % cid
        with winreg.CreateKey(winreg.HKEY_CURRENT_USER, root) as k:
            winreg.SetValueEx(k, None, 0, winreg.REG_SZ, "URL:Run game %s protocol" % cid)
            winreg.SetValueEx(k, "URL Protocol", 0, winreg.REG_SZ, "")
        with winreg.CreateKey(winreg.HKEY_CURRENT_USER, root + r"\shell\open\command") as k:
            winreg.SetValueEx(k, None, 0, winreg.REG_SZ, cmd)
        return True
    except OSError:
        return False


class Rpc:
    def __init__(self, cid, on_join=None, on_log=None):
        self.cid = cid
        self.on_join = on_join or (lambda s: None)
        self.on_log = on_log or (lambda t: None)
        self.want = None
        self.sent = False
        self.pipe = None
        self.alive = True
        self.last = 0
        self.tried = 0
        self.ev = threading.Event()
        threading.Thread(target=self.loop, daemon=True).start()

    def set(self, act):
        if act != self.want:
            self.want = act
            self.sent = False
            self.ev.set()

    def stop(self):
        self.alive = False
        self.ev.set()
        self.drop()

    def wr(self, op, body):
        b = json.dumps(body).encode("utf-8")
        self.pipe.write(struct.pack("<II", op, len(b)) + b)
        self.pipe.flush()

    def rd(self):
        op, n = struct.unpack("<II", self.pipe.read(8))
        return op, json.loads(self.pipe.read(n).decode("utf-8") or "{}")

    def ready(self):
        n = ctypes.c_ulong(0)
        h = msvcrt.get_osfhandle(self.pipe.fileno())
        if not ctypes.windll.kernel32.PeekNamedPipe(h, None, 0, None, ctypes.byref(n), None):
            raise OSError("pipe closed")
        return n.value >= 8

    def link(self):
        for i in range(10):
            try:
                self.pipe = open(r"\\.\pipe\discord-ipc-%d" % i, "r+b", buffering=0)
            except OSError:
                continue
            try:
                self.wr(0, {"v": 1, "client_id": self.cid})
                op, r = self.rd()
                if r.get("evt") == "READY":
                    self.wr(1, {"cmd": "SUBSCRIBE", "evt": "ACTIVITY_JOIN", "nonce": str(uuid.uuid4())})
                    return True
            except (OSError, ValueError, struct.error):
                pass
            self.drop()
        return False

    def drop(self):
        p, self.pipe = self.pipe, None
        self.sent = False
        if p:
            try:
                p.close()
            except OSError:
                pass

    def got(self, op, m):
        if op == 3:
            self.wr(4, m)
        elif op == 2:
            raise OSError("closed by discord")
        elif m.get("evt") == "ACTIVITY_JOIN":
            self.on_join((m.get("data") or {}).get("secret", ""))
        elif m.get("evt") == "ERROR":
            self.on_log("discord: %s" % (m.get("data") or {}).get("message", "error"))

    def loop(self):
        while self.alive:
            try:
                if not self.pipe and time.time() - self.tried > 15:
                    self.tried = time.time()
                    self.link()
                if self.pipe:
                    if not self.sent and self.want is not None:
                        self.wr(1, {"cmd": "SET_ACTIVITY", "nonce": str(uuid.uuid4()),
                                    "args": {"pid": os.getpid(), "activity": self.want or None}})
                        self.sent = True
                        self.last = time.time()
                    while self.pipe and self.ready():
                        self.got(*self.rd())
                    if time.time() - self.last > 60:
                        self.sent = False
            except (OSError, ValueError, struct.error):
                self.drop()
            self.ev.wait(0.5)
            self.ev.clear()
