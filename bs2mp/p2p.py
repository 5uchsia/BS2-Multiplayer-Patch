import base64
import os
import socket
import struct
import threading
import time

stuns = [("stun.l.google.com", 19302), ("stun.cloudflare.com", 3478), ("stun1.l.google.com", 19302)]
mtu = 1100
win = 512


def lan_ip():
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except OSError:
        return "127.0.0.1"


def stun_ask(sock, host, port):
    tid = os.urandom(12)
    req = struct.pack(">HHI", 1, 0, 0x2112A442) + tid
    try:
        addr = (socket.gethostbyname(host), port)
    except OSError:
        return None
    for _ in range(3):
        sock.sendto(req, addr)
        end = time.time() + 1.0
        while time.time() < end:
            try:
                data, src = sock.recvfrom(2048)
            except socket.timeout:
                break
            except OSError:
                continue
            if len(data) < 20 or data[8:20] != tid:
                continue
            i = 20
            while i + 4 <= len(data):
                t, ln = struct.unpack(">HH", data[i:i + 4])
                v = data[i + 4:i + 4 + ln]
                if t == 0x20 and len(v) >= 8:
                    p = struct.unpack(">H", v[2:4])[0] ^ 0x2112
                    ip = bytes(b ^ m for b, m in zip(v[4:8], b"\x21\x12\xa4\x42"))
                    return socket.inet_ntoa(ip), p
                if t == 0x01 and len(v) >= 8:
                    return socket.inet_ntoa(v[4:8]), struct.unpack(">H", v[2:4])[0]
                i += 4 + ln + ((4 - ln % 4) % 4)
    return None


def make_code(pub, lan, tok):
    raw = socket.inet_aton(pub[0]) + struct.pack(">H", pub[1]) + socket.inet_aton(lan[0]) + struct.pack(">H", lan[1]) + tok
    s = base64.b32encode(raw).decode().rstrip("=")
    return "-".join(s[i:i + 4] for i in range(0, len(s), 4))


def read_code(code):
    s = "".join(c for c in code.upper() if c.isalnum())
    if len(s) != 26:
        return None
    try:
        raw = base64.b32decode(s + "=" * 6)
    except Exception:
        return None
    if len(raw) != 16:
        return None
    pub = (socket.inet_ntoa(raw[0:4]), struct.unpack(">H", raw[4:6])[0])
    lan = (socket.inet_ntoa(raw[6:10]), struct.unpack(">H", raw[10:12])[0])
    return pub, lan, raw[12:16]


def looks_like_code(text):
    return read_code(text) is not None


class Peer:
    def __init__(self, node, tok, addrs):
        self.node = node
        self.tok = tok
        self.addrs = addrs
        self.addr = None
        self.up = False
        self.dead = False
        self.oseq = 0
        self.unacked = {}
        self.sendq = bytearray()
        self.inext = 0
        self.ooo = {}
        self.lastrx = time.time()
        self.lasttx = 0
        self.born = time.time()
        self.lastp = 0
        self.on_data = None
        self.on_up = None
        self.on_down = None
        self.held = bytearray()

    def write(self, data):
        with self.node.lock:
            if self.dead:
                return
            self.sendq += data
            self.pump()

    def pump(self):
        if not self.up:
            return
        now = time.time()
        while self.sendq and len(self.unacked) < win:
            chunk = bytes(self.sendq[:mtu])
            del self.sendq[:mtu]
            seq = self.oseq
            self.oseq += 1
            self.unacked[seq] = [chunk, now, 0]
            self.node.raw(self, b"D" + self.node.tok + struct.pack(">I", seq) + chunk)

    def tick(self, now):
        if self.dead:
            return
        if not self.up:
            if now - self.born > 900:
                self.close()
                return
            if now - self.lastp > 0.25:
                self.lastp = now
                for a in self.addrs:
                    self.node.send_to(a, b"P" + self.node.tok)
            return
        if now - self.lastrx > 25:
            self.close()
            return
        for seq, u in list(self.unacked.items()):
            rto = min(0.25 * (2 ** u[2]), 2.0)
            if now - u[1] > rto:
                u[1] = now
                u[2] += 1
                self.node.raw(self, b"D" + self.node.tok + struct.pack(">I", seq) + u[0])
        self.pump()
        if now - self.lasttx > 1.0:
            self.node.raw(self, b"Z" + self.node.tok)

    def got(self, kind, body, src):
        self.lastrx = time.time()
        if kind in (b"P", b"A"):
            if self.addr is None or kind == b"A":
                self.addr = src
            if kind == b"P":
                self.node.send_to(src, b"A" + self.node.tok)
            if not self.up:
                self.addr = src
                self.up = True
                self.pump()
                if self.on_up:
                    self.node.later(self.on_up)
            return
        if not self.up:
            return
        if kind == b"D" and len(body) >= 4:
            seq = struct.unpack(">I", body[:4])[0]
            data = body[4:]
            out = []
            if seq == self.inext:
                out.append(data)
                self.inext += 1
                while self.inext in self.ooo:
                    out.append(self.ooo.pop(self.inext))
                    self.inext += 1
            elif self.inext < seq < self.inext + 4096:
                self.ooo[seq] = data
            self.node.raw(self, b"K" + self.node.tok + struct.pack(">I", self.inext))
            if out:
                self.deliver(b"".join(out))
        elif kind == b"K" and len(body) >= 4:
            ack = struct.unpack(">I", body[:4])[0]
            for seq in [s for s in self.unacked if s < ack]:
                del self.unacked[seq]
            self.pump()
        elif kind == b"F":
            self.close(False)

    def deliver(self, data):
        if self.on_data:
            if self.held:
                data = bytes(self.held) + data
                self.held = bytearray()
            self.on_data(data)
        else:
            self.held += data

    def set_sink(self, fn):
        with self.node.lock:
            self.on_data = fn
            if self.held:
                data = bytes(self.held)
                self.held = bytearray()
                fn(data)

    def close(self, tell=True):
        if self.dead:
            return
        self.dead = True
        if tell and self.up:
            self.node.raw(self, b"F" + self.node.tok)
        if self.on_down:
            self.node.later(self.on_down)


class Node:
    def __init__(self, drop=0.0):
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.bind(("0.0.0.0", 0))
        self.sock.settimeout(0.5)
        self.tok = os.urandom(4)
        self.lock = threading.RLock()
        self.peers = {}
        self.pub = None
        self.strict = False
        self.lan = (lan_ip(), self.sock.getsockname()[1])
        self.drop = drop
        self.running = False
        self.calls = []

    def probe(self):
        seen = []
        for host, port in stuns:
            got = stun_ask(self.sock, host, port)
            if got:
                seen.append(got)
            if len(seen) >= 2:
                break
        if seen:
            self.pub = seen[0]
            self.strict = len(set(p for _, p in seen)) > 1
        else:
            self.pub = self.lan
        return self.pub

    def code(self):
        return make_code(self.pub or self.lan, self.lan, self.tok)

    def start(self):
        self.running = True
        threading.Thread(target=self.rx_loop, daemon=True).start()
        threading.Thread(target=self.tick_loop, daemon=True).start()

    def stop(self):
        self.running = False
        with self.lock:
            for p in list(self.peers.values()):
                p.close()
        try:
            self.sock.close()
        except OSError:
            pass

    def add(self, code):
        got = read_code(code)
        if not got:
            return None
        pub, lan, tok = got
        with self.lock:
            if tok in self.peers and not self.peers[tok].dead:
                return self.peers[tok]
            addrs = [pub] if pub == lan else [pub, lan]
            p = Peer(self, tok, addrs)
            self.peers[tok] = p
            return p

    def later(self, fn):
        self.calls.append(fn)

    def send_to(self, addr, data):
        if self.drop and os.urandom(1)[0] < 256 * self.drop:
            return
        try:
            self.sock.sendto(data, addr)
        except OSError:
            pass

    def raw(self, peer, data):
        peer.lasttx = time.time()
        if peer.addr:
            self.send_to(peer.addr, data)

    def rx_loop(self):
        while self.running:
            try:
                data, src = self.sock.recvfrom(4096)
            except socket.timeout:
                continue
            except OSError:
                if not self.running:
                    return
                continue
            if len(data) < 5:
                continue
            kind, tok, body = data[:1], data[1:5], data[5:]
            with self.lock:
                p = self.peers.get(tok)
                if p and not p.dead:
                    p.got(kind, body, src)
            self.flush_calls()

    def tick_loop(self):
        while self.running:
            now = time.time()
            with self.lock:
                for p in list(self.peers.values()):
                    p.tick(now)
            self.flush_calls()
            time.sleep(0.03)

    def flush_calls(self):
        while self.calls:
            fn = self.calls.pop(0)
            try:
                fn()
            except Exception:
                pass


class Bridge:
    def __init__(self, peer, conn):
        self.peer = peer
        self.conn = conn
        self.alive = True
        down = peer.on_down
        peer.on_down = lambda: (self.end(), down and down())
        peer.set_sink(self.to_tcp)
        threading.Thread(target=self.from_tcp, daemon=True).start()

    def to_tcp(self, data):
        if not self.alive:
            return
        try:
            self.conn.sendall(data)
        except OSError:
            self.end()

    def from_tcp(self):
        while self.alive:
            try:
                data = self.conn.recv(65536)
            except OSError:
                data = b""
            if not data:
                self.end()
                return
            self.peer.write(data)

    def end(self):
        if not self.alive:
            return
        self.alive = False
        try:
            self.conn.close()
        except OSError:
            pass
        self.peer.close()


class Host:
    def __init__(self, relay_port, on_log=None):
        self.relay_port = relay_port
        self.on_log = on_log or (lambda t: None)
        self.node = Node()

    def open(self):
        self.node.probe()
        self.node.start()
        return self.node.code()

    def add(self, code):
        p = self.node.add(code)
        if not p:
            return False
        p.on_up = lambda: self.link(p)
        p.on_down = lambda: self.on_log("p2p: a guest disconnected")
        self.on_log("p2p: connecting to guest (keeps trying for 15 min)...")
        return True

    def link(self, p):
        try:
            c = socket.create_connection(("127.0.0.1", self.relay_port), 5)
        except OSError:
            self.on_log("p2p: relay not running")
            p.close()
            return
        c.settimeout(None)
        c.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        Bridge(p, c)
        self.on_log("p2p: guest connected")

    def stop(self):
        self.node.stop()


class Guest:
    def __init__(self, host_code, on_log=None):
        self.host_code = host_code
        self.on_log = on_log or (lambda t: None)
        self.node = Node()
        self.srv = None
        self.peer = None
        self.port = 0

    def open(self):
        self.node.probe()
        self.node.start()
        self.peer = self.node.add(self.host_code)
        self.peer.on_up = lambda: self.on_log("p2p: connected to host")
        self.peer.on_down = lambda: self.on_log("p2p: lost the host")
        self.srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.srv.bind(("127.0.0.1", 0))
        self.srv.listen(2)
        self.port = self.srv.getsockname()[1]
        threading.Thread(target=self.accept_loop, daemon=True).start()
        return self.node.code()

    def accept_loop(self):
        while True:
            try:
                c, _ = self.srv.accept()
            except OSError:
                return
            c.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            if self.peer.dead:
                c.close()
                continue
            Bridge(self.peer, c)

    def stop(self):
        try:
            self.srv.close()
        except OSError:
            pass
        self.node.stop()
