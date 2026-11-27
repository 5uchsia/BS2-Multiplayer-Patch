import base64
import ctypes
import io
import socket
import subprocess
import sys
import threading
import time
from ctypes import wintypes

maxp = 4


class bmih(ctypes.Structure):
    _fields_ = [("biSize", wintypes.DWORD), ("biWidth", wintypes.LONG), ("biHeight", wintypes.LONG),
                ("biPlanes", wintypes.WORD), ("biBitCount", wintypes.WORD),
                ("biCompression", wintypes.DWORD), ("biSizeImage", wintypes.DWORD),
                ("biXPelsPerMeter", wintypes.LONG), ("biYPelsPerMeter", wintypes.LONG),
                ("biClrUsed", wintypes.DWORD), ("biClrImportant", wintypes.DWORD)]


maxq = 32 * 1024 * 1024
vidq = 512 * 1024


class Client:

    def __init__(self, sock, addr):
        self.sock = sock
        self.addr = addr
        self.id = None
        self.lock = threading.Lock()
        self.cond = threading.Condition(self.lock)
        self.queue = []
        self.backlog = 0
        self.alive = True
        self.closing = False
        self.writer = threading.Thread(target=self._write_loop, daemon=True)
        self.writer.start()

    def send(self, line):
        data = (line + "\n").encode("utf-8")
        with self.cond:
            if not self.alive:
                return
            if line.startswith("vid|") and self.backlog > vidq:
                return
            if self.backlog + len(data) > maxq:
                self.alive = False
                self.cond.notify_all()
                overflow = True
            else:
                overflow = False
                self.queue.append(data)
                self.backlog += len(data)
                self.cond.notify()
        if overflow:
            self.close()

    def _write_loop(self):
        while True:
            with self.cond:
                while self.alive and not self.queue and not self.closing:
                    self.cond.wait()
                if not self.alive:
                    return
                if not self.queue and self.closing:
                    finish = True
                else:
                    finish = False
                    chunk = b"".join(self.queue)
                    self.queue = []
                    self.backlog = 0
            if finish:
                self.close()
                return
            try:
                self.sock.sendall(chunk)
            except OSError:
                self.close()
                return

    def close_after_flush(self):
        with self.cond:
            self.closing = True
            self.cond.notify_all()

    def close(self):
        with self.cond:
            self.alive = False
            self.cond.notify_all()
        try:
            self.sock.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        try:
            self.sock.close()
        except OSError:
            pass


class Relay:
    def __init__(self, port=45555, on_change=None):
        self.port = port
        self.on_change = on_change
        self.lock = threading.Lock()
        self.clients = {}
        self.waiting = []
        self.leader = None
        self.names = {}
        self.hellos = {}
        self.server = None
        self.running = False
        self.thread = None
        self.log_lines = []
        self.game_pid = None
        self.video_running = False
        self.video_thread = None
        self.video_seq = 0

    def log(self, text):
        with self.lock:
            self.log_lines.append("%s %s" % (time.strftime("%H:%M:%S"), text))
            self.log_lines = self.log_lines[-200:]
        if self.on_change:
            try:
                self.on_change()
            except Exception:
                pass

    def start(self):
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        s.bind(("0.0.0.0", self.port))
        s.listen(8)
        self.server = s
        self.running = True
        self.thread = threading.Thread(target=self.accept_loop, daemon=True)
        self.thread.start()
        self.log("listening on port %d" % self.port)

    def stop(self):
        self.running = False
        if self.server:
            try:
                self.server.close()
            except OSError:
                pass
        with self.lock:
            clients = list(self.clients.values())
        for c in clients:
            c.close()
        with self.lock:
            self.clients.clear()
            self.waiting = []
            self.leader = None
            self.names = {}
            self.hellos = {}

    def attach_game(self, pid):
        self.game_pid = pid

    def _find_window(self, pid):
        u = ctypes.windll.user32
        found = []

        def cb(h, l):
            p = wintypes.DWORD()
            u.GetWindowThreadProcessId(h, ctypes.byref(p))
            if p.value == pid and u.IsWindowVisible(h):
                found.append(h)
            return True

        u.EnumWindows(ctypes.WINFUNCTYPE(ctypes.c_bool, wintypes.HWND, wintypes.LPARAM)(cb), 0)
        return found[0] if found else None

    def _capture(self, hwnd):
        from PIL import Image

        u = ctypes.windll.user32
        g = ctypes.windll.gdi32
        u.GetDC.restype = ctypes.c_void_p
        u.GetDC.argtypes = [wintypes.HWND]
        g.CreateCompatibleDC.restype = ctypes.c_void_p
        g.CreateCompatibleDC.argtypes = [ctypes.c_void_p]
        g.CreateCompatibleBitmap.restype = ctypes.c_void_p
        g.CreateCompatibleBitmap.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_int]
        g.SelectObject.restype = ctypes.c_void_p
        g.SelectObject.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
        g.BitBlt.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_int,
                             ctypes.c_void_p, ctypes.c_int, ctypes.c_int, ctypes.c_uint]
        g.GetDIBits.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_uint, ctypes.c_uint,
                                ctypes.c_void_p, ctypes.c_void_p, ctypes.c_uint]
        g.DeleteObject.argtypes = [ctypes.c_void_p]
        g.DeleteDC.argtypes = [ctypes.c_void_p]
        u.ReleaseDC.argtypes = [wintypes.HWND, ctypes.c_void_p]

        rect = wintypes.RECT()
        u.GetClientRect(hwnd, ctypes.byref(rect))
        w, h = rect.right, rect.bottom
        if w <= 0 or h <= 0:
            return None
        hdc = u.GetDC(hwnd)
        mdc = g.CreateCompatibleDC(hdc)
        bmp = g.CreateCompatibleBitmap(hdc, w, h)
        g.SelectObject(mdc, bmp)
        g.BitBlt(mdc, 0, 0, w, h, hdc, 0, 0, 0x00CC0020)
        bi = bmih()
        bi.biSize = ctypes.sizeof(bmih)
        bi.biWidth = w
        bi.biHeight = -h
        bi.biPlanes = 1
        bi.biBitCount = 32
        bi.biCompression = 0
        buf = ctypes.create_string_buffer(w * h * 4)
        g.GetDIBits(mdc, bmp, 0, h, buf, ctypes.byref(bi), 0)
        g.DeleteObject(bmp)
        g.DeleteDC(mdc)
        u.ReleaseDC(hwnd, hdc)
        return Image.frombuffer("RGBA", (w, h), buf, "raw", "BGRA", 0, 1).convert("RGB")

    def start_video(self):
        if self.video_running:
            return
        try:
            from PIL import Image  # noqa: F401
        except ImportError:
            self.log("installing pillow for battle video...")
            try:
                subprocess.run([sys.executable, "-m", "pip", "install", "pillow"], capture_output=True)
                from PIL import Image  # noqa: F401
            except Exception:
                self.log("battle video needs pillow, giving up")
                return
        if not self.game_pid:
            self.log("battle video: no game process attached")
            return
        hwnd = self._find_window(self.game_pid)
        if not hwnd:
            self.log("battle video: game window not found")
            return
        self.video_running = True
        self.video_thread = threading.Thread(target=self._capture_loop, args=(hwnd,), daemon=True)
        self.video_thread.start()
        self.log("battle video on")

    def stop_video(self):
        if self.video_running:
            self.video_running = False
            self.log("battle video off")

    def _capture_loop(self, hwnd):
        while self.video_running:
            with self.lock:
                guests = [c for c in self.clients.values() if c is not self.leader]
            if not guests:
                time.sleep(0.25)
                continue
            t0 = time.time()
            try:
                img = self._capture(hwnd)
            except Exception as exc:
                self.log("capture failed: %s" % exc)
                time.sleep(0.5)
                continue
            if img is not None:
                out = io.BytesIO()
                img.save(out, "JPEG", quality=55)
                payload = base64.b64encode(out.getvalue()).decode("ascii")
                self.video_seq += 1
                self.broadcast("vid|%d|%s" % (self.video_seq, payload), skip=self.leader)
            spent = time.time() - t0
            if spent < 0.1:
                time.sleep(0.1 - spent)

    def snapshot(self):
        with self.lock:
            return len(self.clients), dict(self.names)

    def accept_loop(self):
        while self.running:
            try:
                sock, addr = self.server.accept()
            except OSError:
                break
            sock.settimeout(None)
            try:
                sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
                sock.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
            except OSError:
                pass
            c = Client(sock, addr)
            threading.Thread(target=self.handle, args=(c,), daemon=True).start()

    def read_lines(self, client):
        buf = bytearray()
        while True:
            try:
                data = client.sock.recv(65536)
            except OSError:
                return
            if not data:
                return
            start = len(buf)
            buf += data
            pos = 0
            nl = buf.find(b"\n", start)
            while nl >= 0:
                yield bytes(buf[pos:nl]).decode("utf-8", "replace").rstrip("\r")
                pos = nl + 1
                nl = buf.find(b"\n", pos)
            if pos:
                del buf[:pos]

    def send_welcome(self, client):
        with self.lock:
            count = len(self.clients)
            hellos = [h for cid, h in self.hellos.items() if cid != client.id]
        client.send("welcome|%d|%d|%d" % (client.id, 0, count))
        for h in hellos:
            client.send(h)

    def flush_waiting(self):
        while True:
            with self.lock:
                if not self.waiting or self.leader is None:
                    return
                guest = self.waiting.pop(0)
                if len(self.clients) >= maxp:
                    full = True
                else:
                    full = False
                    used = set(self.clients.keys())
                    new_id = 1
                    while new_id in used:
                        new_id += 1
                    guest.id = new_id
                    self.clients[new_id] = guest
            if full:
                guest.send("full")
                guest.close_after_flush()
                continue
            self.send_welcome(guest)
            self.log("player %d joined (%s)" % (guest.id, guest.addr[0]))

    def broadcast(self, line, skip=None):
        with self.lock:
            targets = [c for c in self.clients.values() if c is not skip]
        for c in targets:
            c.send(line)

    def handle(self, client):
        try:
            for line in self.read_lines(client):
                if client.id is None:
                    self.identify(client, line)
                    if client.id is None and client not in self.waiting:
                        continue
                    continue
                self.route(client, line)
        finally:
            self.drop(client)

    def identify(self, client, line):
        parts = line.split("|")
        if parts[0] == "auth" and len(parts) > 1 and parts[1] == "host":
            with self.lock:
                if self.leader is not None:
                    busy = True
                else:
                    busy = False
                    self.leader = client
                    self.clients[0] = client
            if busy:
                client.send("full")
                client.close_after_flush()
                return
            client.id = 0
            self.send_welcome(client)
            self.log("host connected (%s)" % client.addr[0])
            self.flush_waiting()
            return
        if parts[0] == "auth":
            with self.lock:
                ready = self.leader is not None
                full = len(self.clients) >= maxp
                if not full:
                    self.waiting.append(client)
            if full:
                client.send("full")
                client.close_after_flush()
            elif not ready:
                client.send("wait")
            else:
                self.flush_waiting()
            return
        client.close()

    def route(self, client, line):
        parts = line.split("|")
        if parts[0] == "hello" and len(parts) > 2:
            try:
                name = base64.b64decode(parts[2]).decode("utf-8", "replace")
            except Exception:
                name = "?"
            with self.lock:
                self.names[client.id] = name
                self.hellos[client.id] = line
            self.broadcast(line, skip=client)
            self.log("hello from %d: %s" % (client.id, name))
            return
        if parts[0] == "req":
            with self.lock:
                leader = self.leader
            if leader is not None and leader is not client:
                leader.send(line)
            return
        self.broadcast(line, skip=client)

    def drop(self, client):
        with self.lock:
            if client in self.waiting:
                self.waiting.remove(client)
            was_leader = client is self.leader
            cid = client.id
            if cid is not None:
                self.clients.pop(cid, None)
                self.names.pop(cid, None)
                self.hellos.pop(cid, None)
            if was_leader:
                self.leader = None
        if cid is not None and not was_leader:
            self.broadcast("leave|%d" % cid)
            self.log("player %d left" % cid)
        if was_leader:
            self.stop_video()
            self.log("host left, closing room")
            with self.lock:
                targets = list(self.clients.values())
                self.clients.clear()
                self.names = {}
                guests = list(self.waiting)
                self.waiting = []
            for c in targets + guests:
                c.send("hostgone")
                c.close_after_flush()
        try:
            client.close()
        except Exception:
            pass
