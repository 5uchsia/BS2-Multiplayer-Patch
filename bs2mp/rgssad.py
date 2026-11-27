import struct
from pathlib import Path

magic = b"RGSSAD\0\3"
scrent = "Data/Scripts.rvdata2"


class ArchiveError(Exception):
    pass


class Archive:
    def __init__(self, path):
        self.path = Path(path)
        self.key = 0
        self.entries = {}
        self._read_index()

    def _read_index(self):
        with open(self.path, "rb") as f:
            if f.read(8) != magic:
                raise ArchiveError("not a VX Ace archive: %s" % self.path)
            self.key = struct.unpack("<I", f.read(4))[0]
            self.key = (self.key * 9 + 3) & 0xFFFFFFFF
            key = self.key
            kb = struct.pack("<I", key)
            while True:
                off_pos = f.tell()
                raw = f.read(4)
                if len(raw) < 4:
                    break
                offset = struct.unpack("<I", raw)[0] ^ key
                if offset == 0:
                    break
                size_pos = f.tell()
                size = struct.unpack("<I", f.read(4))[0] ^ key
                key_pos = f.tell()
                file_key = struct.unpack("<I", f.read(4))[0] ^ key
                nlen = struct.unpack("<I", f.read(4))[0] ^ key
                enc = f.read(nlen)
                name = bytes(enc[i] ^ kb[i % 4] for i in range(nlen)).decode("utf-8", "replace")
                self.entries[name.replace("\\", "/")] = {
                    "name": name, "offset": offset, "size": size, "key": file_key,
                    "off_pos": off_pos, "size_pos": size_pos, "key_pos": key_pos,
                }

    def names(self):
        return sorted(self.entries)

    def read(self, name):
        entry = self.entries[name.replace("\\", "/")]
        return self._read_range(entry["offset"], entry["size"], entry["key"])

    def _read_range(self, offset, size, key):
        with open(self.path, "rb") as f:
            f.seek(offset)
            data = f.read(size)
        return crypt(data, key)

    def replace(self, name, data, new_key=0x51A2F00D):
        entry = self.entries[name.replace("\\", "/")]
        with open(self.path, "r+b") as f:
            f.seek(0, 2)
            pos = f.tell()
            f.write(crypt(data, new_key))
            for field_pos, value in ((entry["off_pos"], pos), (entry["size_pos"], len(data)),
                                     (entry["key_pos"], new_key)):
                f.seek(field_pos)
                f.write(struct.pack("<I", value ^ self.key))
        entry["offset"] = pos
        entry["size"] = len(data)
        entry["key"] = new_key


def crypt(data, key):
    out = bytearray()
    for i in range(0, len(data), 4):
        unit = data[i:i + 4]
        if len(unit) < 4:
            unit = unit + b"\0" * (4 - len(unit))
        value = struct.unpack("<I", unit)[0] ^ key
        key = (key * 7 + 3) & 0xFFFFFFFF
        out += struct.pack("<I", value)
    return bytes(out[:len(data)])
