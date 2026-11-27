import argparse
import sys
from pathlib import Path

from bs2mp import data, patch


def main():
    ap = argparse.ArgumentParser(description="BLACK SOULS II co-op party tool")
    ap.add_argument("--game", help="path to the BLACK SOULS II folder")
    ap.add_argument("--install", action="store_true", help="inject the co-op scripts")
    ap.add_argument("--uninstall", action="store_true", help="remove the co-op scripts")
    ap.add_argument("--restore", action="store_true", help="put the original Scripts.rvdata2 back")
    ap.add_argument("--status", action="store_true", help="show patch state")
    args = ap.parse_args()
    game = Path(args.game) if args.game else data.game_dir_default()
    if args.install:
        print(patch.install(game))
        return
    if args.uninstall:
        print(patch.uninstall(game))
        return
    if args.restore:
        print(patch.restore(game))
        return
    if args.status:
        print(game)
        print(patch.status(game))
        return
    from bs2mp.launcher import main as gui

    gui()


if __name__ == "__main__":
    sys.exit(main())
