import os
import sys
from pathlib import Path

from . import marshal

imgx = (".png",)


def cfgfile():
    if getattr(sys, "frozen", False):
        return Path(sys.executable).resolve().parent / "config.json"
    return Path(__file__).resolve().parent.parent / "config.json"


def game_dir_default():
    here = Path(sys.executable).resolve().parent
    candidates = []
    env = os.environ.get("BS2_DIR")
    if env:
        candidates.append(Path(env))
    try:
        import json

        cfg = cfgfile()
        if cfg.exists():
            data = json.loads(cfg.read_text(encoding="utf-8"))
            if data.get("game_dir"):
                candidates.append(Path(data["game_dir"]))
    except Exception:
        pass
    candidates.append(here)
    bases = ["C:/Program Files (x86)/Steam", "C:/Program Files/Steam", "D:/Steam", "E:/Steam"]
    try:
        import winreg

        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, r"Software\Valve\Steam") as k:
            bases.insert(0, winreg.QueryValueEx(k, "SteamPath")[0])
    except OSError:
        pass
    for base in bases:
        vdf = Path(base) / "steamapps" / "libraryfolders.vdf"
        if vdf.exists():
            try:
                text = vdf.read_text(encoding="utf-8", errors="replace")
                for line in text.splitlines():
                    line = line.strip()
                    if '"path"' in line:
                        part = line.split('"')
                        if len(part) >= 4:
                            candidates.append(Path(part[3]) / "steamapps" / "common" / "BLACK SOULS II")
            except Exception:
                pass
    candidates.append(Path("C:/Games/BLACK SOULS II"))
    for c in candidates:
        if (c / "Game.exe").exists() or (c / "Data" / "Scripts.rvdata2").exists():
            return c
    return candidates[0]


def remember_game_dir(game_dir):
    import json

    try:
        cfg = cfgfile()
        data = {}
        if cfg.exists():
            data = json.loads(cfg.read_text(encoding="utf-8"))
        data["game_dir"] = str(game_dir)
        cfg.write_text(json.dumps(data, indent=2), encoding="utf-8")
    except Exception:
        pass


def root(game_dir):
    g = Path(game_dir)
    if (g / "Graphics" / "Characters").exists() or not (g / "Game.rgss3a").exists():
        return g
    from .rgssad import Archive

    cache = g / "coop" / "cache"
    try:
        arc = Archive(g / "Game.rgss3a")
        want = [n for n in arc.names() if n.startswith(("Graphics/Characters/", "Graphics/Faces/"))
                or n in ("Data/Actors.rvdata2", "Data/Classes.rvdata2")]
        stamp = str(sum(arc.entries[n]["size"] for n in want)) + ":" + str(len(want))
        mark = cache / "stamp.txt"
        if mark.exists() and mark.read_text(encoding="ascii") == stamp:
            return cache
        for n in want:
            out = cache / n
            out.parent.mkdir(parents=True, exist_ok=True)
            out.write_bytes(arc.read(n))
        mark.write_text(stamp, encoding="ascii")
    except Exception:
        return g
    return cache


def steam_appid(game_dir):
    g = Path(game_dir)
    if not (g / "steam_api.dll").exists():
        return 0
    lib = g.parent.parent
    for m in lib.glob("appmanifest_*.acf"):
        try:
            text = m.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        vals = {}
        for line in text.splitlines():
            part = line.strip().split('"')
            if len(part) >= 4:
                vals[part[1].lower()] = part[3]
        if vals.get("installdir", "").lower() == g.name.lower() and vals.get("appid", "").isdigit():
            return int(vals["appid"])
    return 0


def character_sheets(game_dir):
    folder = root(game_dir) / "Graphics" / "Characters"
    if not folder.exists():
        return []
    out = []
    for p in folder.iterdir():
        if p.suffix.lower() in imgx:
            out.append(p.stem)
    out.sort(key=lambda s: s.lower())
    return out


def face_sheets(game_dir):
    folder = root(game_dir) / "Graphics" / "Faces"
    if not folder.exists():
        return []
    out = [p.stem for p in folder.iterdir() if p.suffix.lower() in imgx and not p.stem.endswith("_s")]
    out.sort(key=lambda s: s.lower())
    return out


def char_frame_size(path):
    from struct import unpack

    try:
        with open(path, "rb") as f:
            head = f.read(33)
        if head[:8] != b"\x89PNG\r\n\x1a\n":
            return None
        w, h = unpack(">II", head[16:24])
        if w <= 0 or h <= 0:
            return None
        single = os.path.basename(path).startswith("$")
        if single:
            return w // 3, h // 4, True
        return w // 12, h // 8, False
    except Exception:
        return None


def sheet_cells(path):
    size = char_frame_size(path)
    if not size:
        return 0, None
    fw, fh, single = size
    if single:
        return 1, (fw, fh)
    return 8, (fw, fh)


def crop_box(path, index):
    size = char_frame_size(path)
    if not size:
        return None
    fw, fh, single = size
    if single:
        x, y = fw, 0
    else:
        col = index % 4
        row = (index // 4) % 2
        x = col * 3 * fw + fw
        y = row * 4 * fh
    return x, y, fw, fh


def class_list(game_dir):
    path = root(game_dir) / "Data" / "Classes.rvdata2"
    if not path.exists():
        return []
    try:
        data = marshal.loads(path.read_bytes())
    except Exception:
        return []
    out = []
    for i, c in enumerate(data):
        if not c:
            continue
        name = c.attrs.get("@name") or ""
        name = str(name).strip()
        out.append((i, name if name else "class %d" % i))
    return out


def actor_looks(game_dir):
    path = root(game_dir) / "Data" / "Actors.rvdata2"
    if not path.exists():
        return []
    try:
        data = marshal.loads(path.read_bytes())
    except Exception:
        return []
    sheets = set(character_sheets(game_dir))
    out = []
    for a in data:
        if not a:
            continue
        g = str(a.attrs.get("@character_name") or "")
        if g and g in sheets and not g.startswith("!"):
            idx = a.attrs.get("@character_index")
            out.append((str(a.attrs.get("@name") or ""), g, int(idx) if isinstance(idx, int) else 0))
    return out


def save_files(game_dir):
    root = Path(game_dir)
    out = []
    for p in sorted(root.glob("Save*.rvdata2")):
        out.append(p)
    return out


def save_profile(path):
    try:
        raw = Path(path).read_bytes()
        hdr, _ = marshal.loads_partial(raw)
    except Exception:
        return None
    if not isinstance(hdr, dict):
        return None
    chars = hdr.get("characters") or []
    playtime = hdr.get("playtime_s") or ""
    gfx = ""
    idx = 0
    name = ""
    if chars and isinstance(chars[0], list) and len(chars[0]) >= 2:
        gfx = str(chars[0][0])
        idx = int(chars[0][1]) if str(chars[0][1]).lstrip("-").isdigit() else 0
        name = gfx.lstrip("$!")
    return {"name": name, "gfx": gfx, "idx": idx, "playtime": str(playtime), "path": str(path)}


def saved_ncol():
    import json

    try:
        cfg = cfgfile()
        v = json.loads(cfg.read_text(encoding="utf-8")).get("ncol", "")
        if len(v) == 6 and all(c in "0123456789abcdef" for c in v):
            return v
    except Exception:
        pass
    return "ebebf5"


def remember_ncol(v):
    import json

    try:
        cfg = cfgfile()
        d = {}
        if cfg.exists():
            d = json.loads(cfg.read_text(encoding="utf-8"))
        d["ncol"] = v
        cfg.write_text(json.dumps(d, indent=2), encoding="utf-8")
    except Exception:
        pass


def recall(key, default=None):
    import json

    try:
        cfg = cfgfile()
        return json.loads(cfg.read_text(encoding="utf-8")).get(key, default)
    except Exception:
        return default


def remember(key, v):
    import json

    try:
        cfg = cfgfile()
        d = {}
        if cfg.exists():
            d = json.loads(cfg.read_text(encoding="utf-8"))
        d[key] = v
        cfg.write_text(json.dumps(d, indent=2, ensure_ascii=False), encoding="utf-8")
    except Exception:
        pass
