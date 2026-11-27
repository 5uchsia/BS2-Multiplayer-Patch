import os
import shutil
import time
import zlib
from hashlib import sha256
from pathlib import Path

from . import marshal

sect = "Coop"
here = Path(__file__).resolve().parent
rbsrc = here / "ruby" / "coop.rb"


class PatchError(Exception):
    pass


def scripts_path(game_dir):
    return Path(game_dir) / "Data" / "Scripts.rvdata2"


def archive_path(game_dir):
    return Path(game_dir) / "Game.rgss3a"


def coop_dir(game_dir):
    return Path(game_dir) / "coop"


def backup_dir(game_dir):
    return coop_dir(game_dir) / "backup"


def ensure_archive_live(game_dir):
    live = archive_path(game_dir)
    off = live.with_suffix(".rgss3a.off")
    if not live.exists() and off.exists():
        os.replace(off, live)
        return True
    return False


def source_bytes():
    return rbsrc.read_text(encoding="utf-8").replace("\r\n", "\n").encode("utf-8")


def read_sections(game_dir):
    path = scripts_path(game_dir)
    if not path.exists():
        raise PatchError("Scripts.rvdata2 not found in %s" % path.parent)
    raw = path.read_bytes()
    obj = marshal.loads(raw)
    n, _, slices = marshal.split_array(raw)
    if len(obj) != n:
        raise PatchError("script table mismatch")
    return raw, obj, slices


def find_insert_index(obj):
    idx = None
    for i, entry in enumerate(obj):
        try:
            code = zlib.decompress(entry[2]).decode("utf-8", "replace")
        except Exception:
            continue
        if "rgss_main" in code:
            idx = i
    return idx if idx is not None else len(obj)


def build_with(raw, obj, slices, code, replace):
    magic = obj[0][0] if obj else 1
    entry = marshal.encode_entry(magic, sect, zlib.compress(code, 9))
    names = [e[1] for e in obj]
    out_slices = list(slices)
    added = True
    if replace and sect in names:
        i = names.index(sect)
        out_slices[i] = entry
        count = len(out_slices)
        added = False
    else:
        i = find_insert_index(obj)
        out_slices.insert(i, entry)
        count = len(out_slices)
    return b"\x04\x08[" + marshal.wrap_long(count) + b"".join(out_slices), count, added


def check_install(raw, code):
    try:
        obj = marshal.loads(raw)
        n, _, slices = marshal.split_array(raw)
    except Exception as exc:
        return False, "unreadable: %s" % exc
    hits = [i for i, e in enumerate(obj) if e[1] == sect]
    if not hits:
        return False, "vanilla"
    try:
        got = zlib.decompress(obj[hits[0]][2])
    except Exception:
        return False, "coop section corrupt"
    if got != code:
        return False, "coop section is an older build"
    return True, "patched (%d sections)" % n


def move_archive(game_dir):
    return ensure_archive_live(game_dir) and "Game.rgss3a is live again"


def restore_archive(game_dir):
    a = archive_path(game_dir)
    off = a.with_suffix(".rgss3a.off")
    if not a.exists() and off.exists():
        os.replace(off, a)
        return "Game.rgss3a put back"
    return None


def archive_patch(game_dir, code, force=False):
    import json

    from .rgssad import Archive, scrent

    path = archive_path(game_dir)
    arc = Archive(path)
    raw = arc.read(scrent)
    ok, why = check_install(raw, code)
    if ok and not force:
        return "already patched inside Game.rgss3a, %s" % why
    obj = marshal.loads(raw)
    n, _, slices = marshal.split_array(raw)
    out, count, added = build_with(raw, obj, slices, code, replace=True)
    verify_build(raw, out, code, added)
    cb = backup_dir(game_dir)
    cb.mkdir(parents=True, exist_ok=True)
    rec = cb / "archive.index.json"
    if not rec.exists():
        entry = arc.entries[scrent]
        rec.write_text(json.dumps({
            "name": entry["name"],
            "key": arc.key,
            "fields": [[entry["off_pos"], entry["offset"]],
                       [entry["size_pos"], entry["size"]],
                       [entry["key_pos"], entry["key"]]],
        }), encoding="utf-8")
    arc.replace(scrent, out)
    return "patched %d sections inside Game.rgss3a" % count


def archive_revert(game_dir):
    import json

    from .rgssad import Archive

    rec = backup_dir(game_dir) / "archive.index.json"
    if not rec.exists():
        return "no archive patch recorded"
    info = json.loads(rec.read_text(encoding="utf-8"))
    path = archive_path(game_dir)
    arc = Archive(path)
    key = arc.key
    with open(path, "r+b") as f:
        for pos, value in info["fields"]:
            f.seek(int(pos))
            f.write((int(value) ^ key).to_bytes(4, "little"))
    return "archive script entry restored"


def install(game_dir, force=False):
    if ensure_archive_live(game_dir):
        pass
    if archive_path(game_dir).exists():
        return archive_patch(game_dir, source_bytes(), force)
    raw, obj, slices = read_sections(game_dir)
    code = source_bytes()
    ok, why = check_install(raw, code)
    if ok and not force:
        msg = "already installed, %s" % why
        return msg
    out, count, added = build_with(raw, obj, slices, code, replace=True)
    verify_build(raw, out, code, added)
    cb = backup_dir(game_dir)
    cb.mkdir(parents=True, exist_ok=True)
    orig = cb / "Scripts.rvdata2.orig"
    if not orig.exists():
        orig.write_bytes(raw)
    tmp = scripts_path(game_dir).with_suffix(".rvdata2.new")
    tmp.write_bytes(out)
    os.replace(tmp, scripts_path(game_dir))
    (cb / "coop.version").write_text(sha256(code).hexdigest(), encoding="ascii")
    return "installed %d sections" % count


def verify_build(old_raw, new_raw, code, added=True):
    obj_old = marshal.loads(old_raw)
    obj_new = marshal.loads(new_raw)
    n_new, _, slices_new = marshal.split_array(new_raw)
    if len(obj_new) != n_new:
        raise PatchError("rebuild damaged the script table")
    if len(obj_new) != len(obj_old) + (1 if added else 0):
        raise PatchError("unexpected section count after install")
    i = [k for k, e in enumerate(obj_new) if e[1] == sect]
    if len(i) != 1:
        raise PatchError("coop section missing after rebuild")
    i = i[0]
    if zlib.decompress(obj_new[i][2]) != code:
        raise PatchError("coop section did not round-trip")
    old_others = [e for e in obj_old if e[1] != sect]
    new_others = [e for e in obj_new if e[1] != sect]
    if len(old_others) != len(new_others):
        raise PatchError("section list changed unexpectedly")
    for a, b in zip(old_others, new_others):
        if a[0] != b[0] or a[1] != b[1] or a[2] != b[2]:
            raise PatchError("original section %r was altered" % (a[1],))


def uninstall(game_dir):
    if archive_path(game_dir).exists() and (backup_dir(game_dir) / "archive.index.json").exists():
        return archive_revert(game_dir)
    raw, obj, slices = read_sections(game_dir)
    names = [e[1] for e in obj]
    if sect not in names:
        return "not installed"
    i = names.index(sect)
    out_slices = slices[:i] + slices[i + 1:]
    out = b"\x04\x08[" + marshal.wrap_long(len(out_slices)) + b"".join(out_slices)
    got = marshal.loads(out)
    n, _, sl = marshal.split_array(out)
    if len(got) != n or len(sl) != len(slices) - 1:
        raise PatchError("uninstall produced a bad table")
    if any(e[1] == sect for e in got):
        raise PatchError("coop section survived uninstall")
    tmp = scripts_path(game_dir).with_suffix(".rvdata2.new")
    tmp.write_bytes(out)
    os.replace(tmp, scripts_path(game_dir))
    return "removed"


def restore(game_dir):
    from .rgssad import Archive, scrent

    notes = []
    if archive_path(game_dir).exists() and (backup_dir(game_dir) / "archive.index.json").exists():
        notes.append(archive_revert(game_dir))
    orig = backup_dir(game_dir) / "Scripts.rvdata2.orig"
    if orig.exists():
        shutil.copy2(str(orig), str(scripts_path(game_dir)))
        notes.append("loose Scripts.rvdata2 restored")
    back = restore_archive(game_dir)
    if back:
        notes.append(back)
    if not notes:
        return "nothing to restore"
    return "; ".join(notes)


def status(game_dir):
    code = source_bytes()
    if archive_path(game_dir).exists():
        try:
            from .rgssad import Archive, scrent

            raw = Archive(archive_path(game_dir)).read(scrent)
        except Exception as exc:
            return "Game.rgss3a unreadable: %s" % exc
        ok, why = check_install(raw, code)
        return "inside Game.rgss3a: " + why
    if archive_path(game_dir).with_suffix(".rgss3a.off").exists():
        return "Game.rgss3a is sitting as .off, start the tool to restore it"
    path = scripts_path(game_dir)
    if not path.exists():
        return "game folder looks wrong (no Data/Scripts.rvdata2)"
    raw = path.read_bytes()
    ok, why = check_install(raw, code)
    return "loose: " + why


def stamp():
    return time.strftime("%Y%m%d-%H%M%S")
