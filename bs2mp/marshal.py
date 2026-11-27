class MarshalError(Exception):
    pass


def _key(k):
    if isinstance(k, list):
        return tuple(_key(x) for x in k)
    if isinstance(k, dict):
        return ("__hash__", tuple((_key(a), _key(b)) for a, b in k.items()))
    return k


class Sym(str):
    __slots__ = ()

    def __repr__(self):
        return "Sym(%s)" % str.__repr__(self)


class Obj:
    __slots__ = ("cls", "attrs")

    def __init__(self, cls=None, attrs=None):
        self.cls = cls
        self.attrs = attrs if attrs is not None else {}

    def __repr__(self):
        return "Obj(%r, %r)" % (self.cls, self.attrs)


class UserDef:
    __slots__ = ("cls", "data")

    def __init__(self, cls, data):
        self.cls = cls
        self.data = data

    def __repr__(self):
        return "UserDef(%r, %d bytes)" % (self.cls, len(self.data))


class Reader:
    def __init__(self, data, pos=0):
        self.data = data
        self.pos = pos
        self.symbols = []
        self.objects = []

    def byte(self):
        if self.pos >= len(self.data):
            raise MarshalError("unexpected end at %d" % self.pos)
        b = self.data[self.pos]
        self.pos += 1
        return b

    def take(self, n):
        if n < 0 or self.pos + n > len(self.data):
            raise MarshalError("truncated at %d (want %d)" % (self.pos, n))
        s = self.data[self.pos:self.pos + n]
        self.pos += n
        return s

    def long(self):
        b = self.byte()
        if b == 0:
            return 0
        if b < 5:
            raw = self.take(b)
            v = 0
            for i in range(len(raw)):
                v |= raw[i] << (8 * i)
            return v
        if b < 128:
            return b - 5
        if b < 251:
            return b - 251
        raw = self.take(256 - b)
        v = 0
        for i in range(len(raw)):
            v |= raw[i] << (8 * i)
        v -= 1 << (8 * len(raw))
        return v

    def read_bytes(self):
        return self.take(self.long())

    def obj(self):
        t = self.byte()
        if t == 48:
            return None
        if t == 84:
            return True
        if t == 70:
            return False
        if t == 105:
            return self.long()
        if t == 58:
            s = Sym(self.read_bytes().decode("utf-8", "replace"))
            self.symbols.append(s)
            return s
        if t == 59:
            return self.symbols[self.long()]
        if t == 64:
            return self.objects[self.long()]
        if t == 34:
            b = self.read_bytes()
            self.objects.append(b)
            return b
        if t == 73:
            s = self.obj()
            n = self.long()
            enc = None
            for _ in range(n):
                k = self.obj()
                v = self.obj()
                if k == "E":
                    enc = v
            if isinstance(s, (bytes, bytearray)) and enc is True:
                try:
                    return s.decode("utf-8")
                except UnicodeDecodeError:
                    return bytes(s)
            return s
        if t == 91:
            n = self.long()
            a = []
            self.objects.append(a)
            for _ in range(n):
                a.append(self.obj())
            return a
        if t == 123:
            n = self.long()
            d = {}
            self.objects.append(d)
            for _ in range(n):
                k = _key(self.obj())
                d[k] = self.obj()
            return d
        if t == 111:
            cls = self.obj()
            o = Obj(cls)
            self.objects.append(o)
            n = self.long()
            for _ in range(n):
                k = self.obj()
                o.attrs[k] = self.obj()
            return o
        if t == 117:
            cls = self.obj()
            u = UserDef(cls, self.read_bytes())
            self.objects.append(u)
            return u
        if t == 108:
            sign = self.byte()
            n = self.long()
            raw = self.take(n * 2)
            v = 0
            for i in range(len(raw)):
                v |= raw[i] << (8 * i)
            return -v if sign == 45 else v
        if t == 102:
            txt = self.read_bytes().split(b"\0")[0].decode("ascii", "replace")
            f = {"inf": float("inf"), "-inf": float("-inf"), "nan": float("nan")}.get(txt)
            if f is None:
                f = float(txt)
            self.objects.append(f)
            return f
        if t == 99 or t == 109:
            return Obj(self.read_bytes().decode("utf-8", "replace"))
        if t == 83:
            cls = self.obj()
            o = Obj(cls)
            self.objects.append(o)
            n = self.long()
            for _ in range(n):
                k = self.obj()
                o.attrs[k] = self.obj()
            return o
        raise MarshalError("unsupported marshal type %r at %d" % (chr(t), self.pos - 1))


def loads(data):
    r = Reader(data)
    if r.take(2) != b"\x04\x08":
        raise MarshalError("bad marshal header %r" % (r.data[:2],))
    return r.obj()


def loads_partial(data, pos=0):
    r = Reader(data, pos)
    if r.take(2) != b"\x04\x08":
        raise MarshalError("bad marshal header")
    o = r.obj()
    return o, r.pos


def split_array(data):
    r = Reader(data)
    if r.take(2) != b"\x04\x08":
        raise MarshalError("bad marshal header %r" % (r.data[:2],))
    if r.byte() != 91:
        raise MarshalError("top level object is not an Array")
    n = r.long()
    body_start = r.pos
    slices = []
    for _ in range(n):
        start = r.pos
        r.obj()
        slices.append(bytes(r.data[start:r.pos]))
    if r.pos != len(data):
        raise MarshalError("trailing bytes after %d entries: %d" % (n, len(data) - r.pos))
    return n, body_start, slices


def wrap_long(x):
    out = bytearray()
    if x == 0:
        return b"\x00"
    if 0 < x < 123:
        return bytes([x + 5])
    if -124 < x < 0:
        return bytes([x - 5])
    if x > 0:
        raw = bytearray()
        v = x
        while v:
            raw.append(v & 0xFF)
            v >>= 8
        return bytes([len(raw)]) + bytes(raw)
    n = 1
    while x < -(1 << (8 * n - 1)):
        n += 1
    raw = bytearray()
    v = x + (1 << (8 * n))
    for _ in range(n):
        raw.append(v & 0xFF)
        v >>= 8
    return bytes([256 - n]) + bytes(raw)


def _raw_string(b):
    if isinstance(b, str):
        b = b.encode("utf-8")
    return b'"' + wrap_long(len(b)) + b


def _text_string(s):
    b = s.encode("utf-8")
    return b"I" + b'"' + wrap_long(len(b)) + b + wrap_long(1) + b":" + wrap_long(1) + b"E" + b"T"


def encode_entry(magic, name, code_bytes):
    body = b"[" + wrap_long(3)
    if isinstance(magic, int):
        body += b"i" + wrap_long(magic)
    else:
        body += _text_string(str(magic))
    body += _text_string(name)
    body += _raw_string(code_bytes)
    return body
