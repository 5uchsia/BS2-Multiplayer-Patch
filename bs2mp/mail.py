import base64
import hashlib
import hmac
import json
import os
import threading
import time
import urllib.request

base = "https://ntfy.sh/"
hdr = {"User-Agent": "bs2mp", "Cache": "no", "Firebase": "no"}


def norm(code):
    return code.strip().upper().replace("-", "").encode("ascii", "ignore")


def box(code):
    return "bs2mp-" + hashlib.sha256(b"box|" + norm(code)).hexdigest()[:40]


def key(code):
    return hashlib.sha256(b"key|" + norm(code)).digest()


def flow(k, n, size):
    out = b""
    i = 0
    while len(out) < size:
        out += hashlib.sha256(k + n + i.to_bytes(4, "big")).digest()
        i += 1
    return out[:size]


def seal(code, text):
    k = key(code)
    n = os.urandom(16)
    pt = text.encode("utf-8")
    ct = bytes(a ^ b for a, b in zip(pt, flow(k, n, len(pt))))
    tag = hmac.new(k, n + ct, hashlib.sha256).digest()[:16]
    return base64.urlsafe_b64encode(n + ct + tag).decode("ascii")


def unseal(code, s):
    try:
        raw = base64.urlsafe_b64decode(s.strip().encode("ascii"))
    except (ValueError, UnicodeError):
        return None
    if len(raw) < 33:
        return None
    k = key(code)
    n, ct, tag = raw[:16], raw[16:-16], raw[-16:]
    if not hmac.compare_digest(tag, hmac.new(k, n + ct, hashlib.sha256).digest()[:16]):
        return None
    return bytes(a ^ b for a, b in zip(ct, flow(k, n, len(ct)))).decode("utf-8", "replace")


def send(code, text):
    req = urllib.request.Request(base + box(code), data=seal(code, text).encode("ascii"), headers=hdr, method="POST")
    with urllib.request.urlopen(req, timeout=15) as r:
        return r.status == 200


class Listen:
    def __init__(self, code, on_text):
        self.code = code
        self.on_text = on_text
        self.alive = True
        threading.Thread(target=self.loop, daemon=True).start()

    def stop(self):
        self.alive = False

    def loop(self):
        url = base + box(self.code) + "/json"
        while self.alive:
            try:
                req = urllib.request.Request(url, headers={"User-Agent": "bs2mp"})
                with urllib.request.urlopen(req, timeout=90) as r:
                    for line in r:
                        if not self.alive:
                            return
                        try:
                            m = json.loads(line.decode("utf-8"))
                        except ValueError:
                            continue
                        if m.get("event") == "message":
                            t = unseal(self.code, m.get("message", ""))
                            if t:
                                self.on_text(t)
            except Exception:
                time.sleep(5)
