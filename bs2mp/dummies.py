import base64
import socket
import threading
import time


def b64(text):
    return base64.b64encode(text.encode("utf-8")).decode("ascii")


class Dummy:
    def __init__(self, addr, port, name, gfx, idx=0, on_log=None):
        self.addr = addr
        self.port = port
        self.name = name
        self.gfx = gfx
        self.idx = idx
        self.on_log = on_log
        self.sock = None
        self.id = None
        self.alive = False
        self.thread = None

    def log(self, text):
        if self.on_log:
            try:
                self.on_log(text)
            except Exception:
                pass

    def start(self):
        self.thread = threading.Thread(target=self.run, daemon=True)
        self.thread.start()
        return self

    def run(self):
        try:
            self.sock = socket.create_connection((self.addr, self.port), 3)
            self.sock.settimeout(1.0)
            self.alive = True
            self.sock.sendall(b"auth|guest\n")
            buf = b""
            while self.alive and self.id is None:
                try:
                    buf += self.sock.recv(4096)
                except socket.timeout:
                    continue
                while b"\n" in buf:
                    line, buf = buf.split(b"\n", 1)
                    text = line.decode("utf-8", "replace")
                    if text.startswith("welcome|"):
                        self.id = int(text.split("|")[1])
                        self.log("%s joined as #%d" % (self.name, self.id))
                        self.sock.sendall(("hello|%d|%s|%s|%d\n" % (self.id, b64(self.name), b64(self.gfx), self.idx)).encode())
                    elif text == "wait":
                        pass
                    elif text == "full":
                        self.log("room is full")
                        self.alive = False
            while self.alive:
                try:
                    data = self.sock.recv(4096)
                except socket.timeout:
                    continue
                except OSError:
                    break
                if not data:
                    break
                if b"hostgone" in data:
                    self.log("%s: host left" % self.name)
                    break
        except OSError as exc:
            self.log("%s: %s" % (self.name, exc))
        finally:
            self.alive = False
            if self.sock:
                try:
                    self.sock.close()
                except OSError:
                    pass
            self.sock = None

    def stop(self):
        self.alive = False
        if self.sock:
            try:
                self.sock.close()
            except OSError:
                pass
        self.sock = None


class DummyPool:
    def __init__(self, on_log=None):
        self.items = []
        self.on_log = on_log

    def add(self, addr, port, name, gfx, idx=0):
        d = Dummy(addr, port, name, gfx, idx, self.on_log)
        self.items.append(d)
        d.start()
        return d

    def stop_all(self):
        for d in self.items:
            d.stop()
        self.items = []

    def count(self):
        return len([d for d in self.items if d.alive])
