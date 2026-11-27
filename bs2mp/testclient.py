import os
import shutil
import subprocess
from pathlib import Path

lnkd = ("Data", "Graphics", "Audio", "Movies", "Fonts", "Bonus")
cpyf = ("Game.exe", "Game.ini", "steam_api.dll")
cname = "_coop_test_client"


def client_dir(game_dir):
    return Path(game_dir) / cname


def build(game_dir):
    src = Path(game_dir)
    dst = client_dir(src)
    if (dst / "Game.exe").exists() and (dst / "Data").exists():
        _link_archive(src, dst)
        return dst, "tester window already set up"
    dst.mkdir(parents=True, exist_ok=True)
    for name in cpyf:
        s = src / name
        if s.exists():
            shutil.copy2(str(s), str(dst / name))
    if (src / "System").exists():
        shutil.copytree(str(src / "System"), str(dst / "System"), dirs_exist_ok=True)
    for name in lnkd:
        s = src / name
        link = dst / name
        if not s.exists() or link.exists():
            continue
        subprocess.run(["cmd", "/c", "mklink", "/J", str(link), str(s)],
                       capture_output=True, text=True)
    _link_archive(src, dst)
    (dst / "coop").mkdir(exist_ok=True)
    return dst, "tester window created"


def _link_archive(src, dst):
    s = Path(src) / "Game.rgss3a"
    link = Path(dst) / "Game.rgss3a"
    if not s.exists() or link.exists():
        return
    try:
        os.link(str(s), str(link))
    except OSError:
        shutil.copy2(str(s), str(link))


def remove(game_dir):
    dst = client_dir(game_dir)
    if not dst.exists():
        return "no tester window to remove"
    archive = dst / "Game.rgss3a"
    if archive.exists():
        try:
            os.remove(str(archive))
        except OSError:
            pass
    for name in lnkd:
        link = dst / name
        if link.exists():
            try:
                os.rmdir(link)
            except OSError:
                pass
    shutil.rmtree(str(dst), ignore_errors=True)
    return "tester window removed"


def launch(game_dir, port, name, gfx, idx=0, addr="127.0.0.1"):
    dst, note = build(game_dir)
    coop = dst / "coop"
    coop.mkdir(exist_ok=True)
    lines = ["role=guest", "addr=%s" % addr, "port=%d" % port, "name=%s" % name,
             "gfx=%s" % gfx, "idx=%d" % idx, "save=0", "class=0", "battle=1"]
    (coop / "session.cfg").write_text("\n".join(lines) + "\n", encoding="utf-8")
    saves = coop / "saves"
    if saves.exists():
        shutil.rmtree(str(saves), ignore_errors=True)
    proc = subprocess.Popen([str(dst / "Game.exe")], cwd=str(dst))
    return proc, note
