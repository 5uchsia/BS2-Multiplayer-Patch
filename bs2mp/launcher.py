import base64
import json
import os
import socket
import subprocess
import sys
import threading
import time
import tkinter as tk
from pathlib import Path
from tkinter import colorchooser, filedialog, messagebox, ttk

from . import data, mail, names, p2p, patch, rpc, testclient
from .dummies import DummyPool
from .relay import Relay

bgc = "#101010"
pnc = "#000000"
fgc = "#d6d6d6"
dmc = "#5c5c5c"
acc = "#2a2a2a"
acc2 = "#3a3a3a"
dcid = "1575736026088079442"


class App:
    def __init__(self, root):
        self.root = root
        self.root.title("BS Multiplayer Patcher")
        try:
            self.root.iconbitmap(str(Path(__file__).resolve().parent / "icon.ico"))
        except tk.TclError:
            pass
        self.root.configure(bg=pnc)
        self.root.geometry("760x780")
        self.relay = None
        self.p2p = None
        self.pmsg = []
        self.proc = None
        self.t0 = int(time.time())
        self.hcode = None
        self.mbox = None
        self.seen = set()
        self.rpc = rpc.Rpc(dcid, on_join=lambda c: self.pmsg.append(("join", c)), on_log=self.pmsg.append)
        if getattr(sys, "frozen", False):
            rpc.register(dcid, '"%s"' % sys.executable)
        else:
            rpc.register(dcid, '"%s" "%s"' % (sys.executable, Path(__file__).resolve().parent.parent / "run.py"))
        self.tester_proc = None
        self.looks = []
        self.dummies = DummyPool(on_log=self.dummy_log)
        self.sheets = []
        self.sheet_map = {}
        self.faces = []
        self.face_img = None
        self.look_sel = ""
        self.face_sel = ""
        self.shown = []
        self.off = {}
        self.class_map = {}
        self.saves = []
        self.preview_img = None
        self.log_pos = 0
        self.game = Path(data.game_dir_default())
        self.build()
        self.reload_game()
        self.root.protocol("WM_DELETE_WINDOW", self.on_close)
        self.root.after(800, self.poll)

    def label(self, parent, text, size=10, color=fgc, bold=False):
        f = ("Segoe UI", size, "bold" if bold else "normal")
        return tk.Label(parent, text=text, bg=parent["bg"], fg=color, font=f, anchor="w")

    def build(self):
        row = tk.Frame(self.root, bg=pnc)
        row.pack(fill="x", padx=18, pady=(14, 2))
        self.label(row, "game folder", 9, dmc).pack(side="left")
        self.game_var = tk.StringVar(value=str(self.game))
        tk.Entry(row, textvariable=self.game_var, bg=bgc, fg=dmc, insertbackground=fgc,
                 relief="flat", font=("Consolas", 9)).pack(side="left", fill="x", expand=True, padx=8, ipady=4)
        tk.Button(row, text="...", command=self.browse_game, bg=bgc, fg=fgc, relief="flat",
                  activebackground=acc, width=3).pack(side="left")
        self.patch_label = self.label(self.root, "", 8, dmc)

        role = tk.Frame(self.root, bg=pnc)
        role.pack(fill="x", padx=18, pady=(10, 0))
        self.mode = tk.StringVar(value="host")
        for text, val in (("host the party", "host"), ("join a party", "guest")):
            tk.Radiobutton(role, text=text, value=val, variable=self.mode, command=self.mode_changed,
                           bg=pnc, fg=fgc, selectcolor=pnc, activebackground=pnc, activeforeground=fgc,
                           font=("Segoe UI", 10), anchor="w").pack(side="left", padx=(0, 20))

        net = tk.Frame(self.root, bg=pnc, highlightthickness=0)
        net.pack(fill="x", padx=18, pady=10)
        inner = tk.Frame(net, bg=pnc)
        inner.pack(fill="x", padx=12, pady=10)
        self.label(inner, "host address", 9, dmc).grid(row=0, column=0, sticky="w")
        self.label(inner, "port", 9, dmc).grid(row=0, column=2, sticky="w", padx=(14, 0))
        self.addr_var = tk.StringVar(value="127.0.0.1")
        self.port_var = tk.StringVar(value="45555")
        self.addr_entry = tk.Entry(inner, textvariable=self.addr_var, bg=bgc, fg=fgc, insertbackground=fgc,
                                   disabledbackground=bgc, disabledforeground=dmc,
                                   relief="flat", font=("Consolas", 11), width=22)
        self.addr_entry.grid(row=1, column=0, sticky="w", ipady=4)
        tk.Entry(inner, textvariable=self.port_var, bg=bgc, fg=fgc, insertbackground=fgc,
                 relief="flat", font=("Consolas", 11), width=8).grid(row=1, column=2, sticky="w", padx=(14, 0), ipady=4)
        self.hint = self.label(inner, "", 9, dmc)
        self.hint.grid(row=2, column=0, columnspan=3, sticky="w", pady=(6, 0))
        self.code_row = tk.Frame(inner, bg=pnc)
        self.code_row.grid(row=3, column=0, columnspan=3, sticky="w", pady=(6, 0))
        self.label(self.code_row, "your code", 9, dmc).pack(side="left")
        self.code_var = tk.StringVar(value="")
        tk.Entry(self.code_row, textvariable=self.code_var, state="readonly", readonlybackground=bgc, fg=fgc,
                 relief="flat", font=("Consolas", 10), width=34).pack(side="left", padx=8, ipady=3)
        tk.Button(self.code_row, text="copy", command=self.copy_code, bg=bgc, fg=fgc, relief="flat",
                  activebackground=acc).pack(side="left")
        self.code_row.grid_remove()
        self.add_row = tk.Frame(inner, bg=pnc)
        self.add_row.grid(row=4, column=0, columnspan=3, sticky="w", pady=(6, 0))
        self.label(self.add_row, "guest code", 9, dmc).pack(side="left")
        self.gcode_var = tk.StringVar(value="")
        tk.Entry(self.add_row, textvariable=self.gcode_var, bg=bgc, fg=fgc, insertbackground=fgc,
                 relief="flat", font=("Consolas", 10), width=34).pack(side="left", padx=8, ipady=3)
        tk.Button(self.add_row, text="add", command=self.add_guest, bg=bgc, fg=fgc, relief="flat",
                  activebackground=acc).pack(side="left")
        self.add_row.grid_remove()

        who = tk.Frame(self.root, bg=pnc, highlightthickness=0)
        who.pack(fill="x", padx=18)
        w = tk.Frame(who, bg=pnc)
        w.pack(fill="x", padx=12, pady=10)
        self.label(w, "name tag", 9, dmc).grid(row=0, column=0, sticky="w")
        self.label(w, "class", 9, dmc).grid(row=0, column=1, sticky="w", padx=(14, 0))
        self.name_var = tk.StringVar(value=data.recall("name", "") or "")
        self.name_entry = tk.Entry(w, textvariable=self.name_var, bg=bgc, fg=fgc, insertbackground=fgc,
                                   relief="flat", font=("Segoe UI", 11), width=18)
        self.name_entry.grid(row=1, column=0, sticky="w", ipady=4)
        self.class_box = ttk.Combobox(w, state="readonly", width=22, font=("Segoe UI", 10))
        self.class_box.grid(row=1, column=1, sticky="w", padx=(14, 0))
        self.label(w, "name colour", 9, dmc).grid(row=0, column=2, sticky="w", padx=(14, 0))
        self.ncol = data.saved_ncol()
        self.ncol_btn = tk.Button(w, text="pick", command=self.pick_ncol, bg="#" + self.ncol, fg="#000000",
                                  relief="flat", font=("Segoe UI", 9), width=8)
        self.ncol_btn.grid(row=1, column=2, sticky="w", padx=(14, 0), ipady=2)
        self.label(w, "portrait", 9, dmc).grid(row=0, column=3, sticky="w", padx=(14, 0))
        self.fidx_var = tk.StringVar(value="0")
        self.face_prev = tk.Label(w, bg=bgc, width=6, height=3, text="auto", fg=dmc, font=("Segoe UI", 8),
                                  cursor="hand2")
        self.face_prev.grid(row=1, column=3, sticky="w", padx=(14, 0))
        self.face_prev.bind("<Button-1>", lambda e: self.set_kind("portrait"))

        char = tk.Frame(self.root, bg=pnc, highlightthickness=0)
        char.pack(fill="both", expand=True, padx=18, pady=10)
        c = tk.Frame(char, bg=pnc)
        c.pack(fill="both", expand=True, padx=12, pady=10)
        head = tk.Frame(c, bg=pnc)
        head.pack(fill="x")
        self.label(head, "pick a", 9, dmc).pack(side="left")
        self.kind = tk.StringVar(value="sprite")
        for k in ("sprite", "portrait"):
            tk.Radiobutton(head, text=k, variable=self.kind, value=k, command=self.kind_changed, bg=pnc, fg=fgc,
                           selectcolor=bgc, activebackground=pnc, activeforeground=fgc,
                           font=("Segoe UI", 9)).pack(side="left", padx=(6, 0))
        self.search_var = tk.StringVar()
        self.search_var.trace("w", lambda *a: self.fill_sheets())
        tk.Entry(head, textvariable=self.search_var, bg=bgc, fg=fgc, insertbackground=fgc, relief="flat",
                 font=("Segoe UI", 9), width=18).pack(side="right", ipady=3)
        self.label(head, "search", 9, dmc).pack(side="right", padx=(0, 6))

        self.look_row = tk.Frame(c, bg=pnc)
        self.custom_look = tk.BooleanVar(value=False)
        tk.Checkbutton(self.look_row, text="custom look for the host", variable=self.custom_look,
                       command=self.mode_changed, bg=pnc, fg=fgc, selectcolor=bgc,
                       activebackground=pnc, activeforeground=fgc,
                       font=("Segoe UI", 9)).pack(side="left")

        body = tk.Frame(c, bg=pnc)
        body.pack(fill="both", expand=True, pady=(8, 0))
        self.look_anchor = body
        left = tk.Frame(body, bg=pnc)
        left.pack(side="left", fill="both", expand=True)
        self.sheet_list = tk.Listbox(left, bg=bgc, fg=fgc, selectbackground=acc, selectforeground=fgc,
                                     relief="flat", font=("Segoe UI", 9), height=9, activestyle="none",
                                     highlightthickness=0, bd=0, disabledforeground=dmc)
        self.sheet_list.pack(side="left", fill="both", expand=True)
        self.sheet_list.bind("<<ListboxSelect>>", lambda e: self.list_pick())

        side = tk.Frame(body, bg=pnc, width=150)
        side.pack(side="right", fill="y", padx=(12, 0))
        side.pack_propagate(False)
        self.preview = tk.Label(side, bg=bgc, width=96, height=120, text="no preview", fg=dmc, font=("Segoe UI", 8))
        self.preview.pack(pady=(0, 6))
        idxrow = tk.Frame(side, bg=pnc)
        idxrow.pack(fill="x")
        self.label(idxrow, "frame", 9, dmc).pack(side="left")
        self.idx_var = tk.StringVar(value="0")
        self.spin = tk.Spinbox(idxrow, from_=0, to=7, textvariable=self.idx_var, width=3, bg=bgc, fg=fgc,
                               relief="flat", command=self.list_pick, buttonbackground=bgc,
                               highlightthickness=0, bd=0)
        self.spin.pack(side="right")

        self.steam_row = tk.Frame(self.root, bg=pnc)
        self.use_steam = tk.BooleanVar(value=False)
        tk.Checkbutton(self.steam_row, text="Launch with steam (if you want achievements 😭📝)",
                       variable=self.use_steam, bg=pnc, fg=fgc, selectcolor=bgc, activebackground=pnc,
                       activeforeground=fgc, font=("Segoe UI", 10)).pack(side="left")
        self.steam_row.pack(fill="x", padx=18, pady=(0, 6))
        self.appid = 0
        save = tk.Frame(self.root, bg=pnc, highlightthickness=0)
        self.steam_after = save
        save.pack(fill="x", padx=18)
        s = tk.Frame(save, bg=pnc)
        s.pack(fill="x", padx=12, pady=10)
        self.use_save = tk.BooleanVar(value=False)
        self.save_radio = tk.Checkbutton(s, text="bring my save", variable=self.use_save,
                                         command=self.mode_changed, bg=pnc, fg=fgc, selectcolor=bgc,
                                         activebackground=pnc, activeforeground=fgc, font=("Segoe UI", 10))
        self.save_radio.pack(side="left")
        self.save_box = ttk.Combobox(s, state="readonly", width=26, font=("Segoe UI", 9))
        self.save_box.pack(side="left", padx=10)
        self.save_box.bind("<<ComboboxSelected>>", lambda e: self.pick_save())
        tk.Button(s, text="file...", command=self.browse_save, bg=bgc, fg=fgc, relief="flat",
                  activebackground=acc).pack(side="left")

        bottom = tk.Frame(self.root, bg=pnc)
        bottom.pack(fill="x", padx=18, pady=12)
        self.go = tk.Button(bottom, text="start", command=self.start, bg=fgc, fg=pnc, relief="flat",
                            font=("Segoe UI", 11), activebackground="#ffffff", width=14)
        self.go.pack(side="left", ipady=6)
        self.stop_btn = tk.Button(bottom, text="stop", command=self.stop_all, bg=bgc, fg=fgc, relief="flat",
                                  font=("Segoe UI", 10), activebackground=acc, width=8, state="disabled",
                                  disabledforeground=dmc)
        self.stop_btn.pack(side="left", padx=8, ipady=6)
        self.status = self.label(bottom, "", 9, dmc)
        self.status.pack(side="left", padx=12)

        testrow = tk.Frame(self.root, bg=pnc)
        testrow.pack(fill="x", padx=18, pady=(0, 8))
        tk.Button(testrow, text="dummy", command=self.add_dummy, bg=pnc, fg=dmc,
                  relief="flat", activebackground=acc, font=("Segoe UI", 9)).pack(side="left", ipady=3)
        tk.Button(testrow, text="test window", command=self.spawn_tester, bg=pnc, fg=dmc,
                  relief="flat", activebackground=acc, font=("Segoe UI", 9)).pack(side="left", padx=6, ipady=3)
        tk.Button(testrow, text="clear", command=self.clear_testers, bg=pnc, fg=dmc,
                  relief="flat", activebackground=acc, font=("Segoe UI", 9)).pack(side="left", ipady=3)
        self.test_label = self.label(testrow, "", 9, dmc)
        self.test_label.pack(side="left", padx=10)

        self.logbox = tk.Text(self.root, height=3, bg=pnc, fg=dmc, relief="flat", highlightthickness=0,
                              font=("Consolas", 8))
        self.logbox.pack(fill="x", padx=18, pady=(0, 14))
        self.logbox.configure(state="disabled")

    def pick_ncol(self):
        got = colorchooser.askcolor(color="#" + self.ncol, title="name colour")
        if got and got[1]:
            self.ncol = got[1].lstrip("#").lower()
            self.ncol_btn.configure(bg="#" + self.ncol)
            data.remember_ncol(self.ncol)

    def write(self, text):
        self.logbox.configure(state="normal")
        self.logbox.insert("end", text.rstrip() + "\n")
        self.logbox.see("end")
        self.logbox.configure(state="disabled")

    def browse_game(self):
        p = filedialog.askdirectory(initialdir=str(self.game))
        if p:
            self.game = Path(p)
            self.game_var.set(p)
            self.reload_game()

    def reload_game(self):
        self.game = Path(self.game_var.get())
        data.remember_game_dir(self.game)
        st = patch.status(self.game)
        self.patch_label.configure(text="scripts: " + st)
        try:
            self.sheets = data.character_sheets(self.game)
            self.faces = data.face_sheets(self.game)
        except Exception:
            self.sheets = []
        self.sheet_map = {s.lower(): s for s in self.sheets}
        self.off = names.official(self.game)
        self.appid = data.steam_appid(self.game)
        if self.appid:
            self.steam_row.pack(fill="x", padx=18, pady=(0, 6), before=self.steam_after)
        else:
            self.steam_row.pack_forget()
        self.face_sel = ""
        self.update_face()
        self.fill_sheets()
        if self.sheets and self.sheet_list.size():
            want = "$主人公" if "$主人公" in self.sheets else None
            if want is None:
                for s in self.sheets:
                    if not s.startswith("!"):
                        want = s
                        break
            items = list(self.shown)
            if want in items:
                pos = items.index(want)
                self.sheet_list.selection_clear(0, "end")
                self.sheet_list.selection_set(pos)
                self.sheet_list.see(pos)
                self.update_preview()
        mem = data.recall("look", {}) or {}
        if mem.get("gfx") in self.sheets:
            self.custom_look.set(bool(mem.get("custom")))
            self.preview_sheet(mem["gfx"], int(mem.get("idx", 0)))
            self.mode_changed()
        if mem.get("face") in self.faces:
            self.face_sel = mem["face"]
            self.fidx_var.set(str(mem.get("fidx", 0)))
            self.update_face()
        classes = data.class_list(self.game)
        self.class_map = {}
        values = []
        for cid, cname in classes:
            label = "%02d  %s" % (cid, cname)
            self.class_map[label] = cid
            values.append(label)
        self.class_box.configure(values=values)
        if values:
            self.class_box.current(0)
        self.looks = data.actor_looks(self.game)
        self.saves = data.save_files(self.game)
        sv = []
        for p in self.saves:
            prof = data.save_profile(p)
            if prof:
                sv.append("%s - %s (%s)" % (p.stem, names.en(prof["name"]), prof["playtime"]))
            else:
                sv.append(p.stem)
        self.save_box.configure(values=sv)
        if sv:
            self.save_box.current(0)
        self.mode_changed()

    def fill_sheets(self):
        text = self.search_var.get().lower()
        st = self.sheet_list.cget("state")
        self.sheet_list.configure(state="normal")
        self.sheet_list.delete(0, "end")
        self.shown = []
        seen = {}
        face = self.kind.get() == "portrait"
        for name in ([""] + self.faces if face else self.sheets):
            if name.startswith("!") or name.startswith("$!"):
                continue
            lab = names.en(name, self.off) if name else "auto (match look)"
            if text and text not in name.lower() and text not in lab.lower():
                continue
            seen[lab] = seen.get(lab, 0) + 1
            if seen[lab] > 1:
                lab = "%s #%d" % (lab, seen[lab])
            self.sheet_list.insert("end", lab)
            self.shown.append(name)
            if len(self.shown) > 1500:
                break
        if self.sheet_list.size():
            cur = self.face_sel if face else self.look_sel
            pos = self.shown.index(cur) if cur in self.shown else 0
            self.sheet_list.selection_set(pos)
            self.sheet_list.see(pos)
        self.sheet_list.configure(state=st)
        if self.sheet_list.size():
            self.list_pick()

    def current_sheet(self):
        sel = self.sheet_list.curselection()
        if self.kind.get() == "sprite" and sel and sel[0] < len(self.shown):
            self.look_sel = self.shown[sel[0]]
        return self.look_sel

    def list_pick(self):
        if self.kind.get() == "sprite":
            self.update_preview()
            return
        sel = self.sheet_list.curselection()
        if sel and sel[0] < len(self.shown):
            self.face_sel = self.shown[sel[0]]
        self.update_face()

    def set_kind(self, k):
        self.kind.set(k)
        self.kind_changed()

    def kind_changed(self):
        face = self.kind.get() == "portrait"
        self.spin.configure(textvariable=self.fidx_var if face else self.idx_var)
        self.mode_changed()
        self.search_var.set("")

    def face_index(self):
        try:
            return int(self.fidx_var.get()) % 8
        except ValueError:
            return 0

    def current_face(self):
        return self.face_sel

    def update_face(self):
        name = self.current_face()
        big = self.kind.get() == "portrait"
        if not name:
            self.face_img = None
            self.face_prev.configure(image="", text="auto", width=6, height=3)
            if big:
                self.preview_img = None
                self.preview.configure(image="", text="auto\n(matches look)")
            return
        try:
            idx = int(self.fidx_var.get()) % 8
        except ValueError:
            idx = 0
        try:
            img = tk.PhotoImage(file=str(data.root(self.game) / "Graphics" / "Faces" / (name + ".png")))
            fw, fh = img.width() // 4, img.height() // 2
            x, y = idx % 4 * fw, idx // 4 * fh
            cut = tk.PhotoImage()
            cut.tk.call(cut, "copy", img, "-from", x, y, x + fw, y + fh)
            if big:
                self.preview_img = cut
                self.preview.configure(image=cut, text="", width=cut.width(), height=cut.height())
            small = cut.subsample(2)
            self.face_img = small
            self.face_prev.configure(image=small, text="", width=small.width(), height=small.height())
        except Exception:
            self.face_img = None
            self.face_prev.configure(image="", text="none", width=6, height=3)

    def update_preview(self):
        if self.kind.get() == "portrait":
            return
        name = self.current_sheet()
        try:
            idx = int(self.idx_var.get())
        except ValueError:
            idx = 0
        if not name:
            self.preview.configure(image="", text="no preview")
            self.preview_img = None
            return
        folder = data.root(self.game) / "Graphics" / "Characters" / (name + ".png")
        try:
            img = tk.PhotoImage(file=str(folder))
            box = data.crop_box(folder, idx % 8)
            if not box:
                raise ValueError("bad png")
            x, y, w, h = box
            cropped = tk.PhotoImage()
            cropped.tk.call(cropped, "copy", img, "-from", x, y, x + w, y + h)
            big = cropped.zoom(3)
            self.preview_img = big
            self.preview.configure(image=big, text="", width=big.width(), height=big.height())
        except Exception:
            self.preview_img = None
            self.preview.configure(image="", text="no preview")

    def mode_changed(self):
        host = self.mode.get() == "host"
        if host:
            self.look_row.pack(fill="x", pady=(6, 0), before=self.look_anchor)
            free = self.custom_look.get() or self.kind.get() == "portrait"
            self.sheet_list.configure(state="normal" if free else "disabled")
            self.save_radio.configure(state="disabled")
        else:
            self.look_row.pack_forget()
            self.sheet_list.configure(state="normal")
            self.save_radio.configure(state="normal")
        self.class_box.configure(state="disabled" if host else "readonly")
        self.save_box.configure(state="disabled" if host else "readonly")
        self.addr_entry.configure(state="disabled" if host else "normal")
        if host:
            local = local_ip()
            self.hint.configure(text="friends join at %s : %s" % (local, self.port_var.get()))
        else:
            self.hint.configure(text="")
        self.status.configure(text="")

    def pick_save(self):
        i = self.save_box.current()
        if i < 0 or i >= len(self.saves):
            return
        prof = data.save_profile(self.saves[i])
        if not prof:
            return
        self.preview_sheet(prof["gfx"], prof["idx"])
        if self.name_var.get().strip() in ("", "Traveller"):
            self.name_var.set(prof["name"] or "Helper")
        self.use_save.set(True)
        self.write("save: %s  look: %s #%d" % (prof["path"], prof["gfx"], prof["idx"]))

    def preview_sheet(self, gfx, idx):
        if not gfx:
            return
        low = gfx.lower()
        if low not in self.sheet_map:
            self.write("look %s is not in Graphics/Characters, keeping the current one" % gfx)
            return
        name = self.sheet_map[low]
        self.look_sel = name
        self.idx_var.set(str(idx))
        if self.kind.get() != "sprite":
            return
        self.search_var.set("")
        items = list(self.shown)
        if name not in items:
            return
        pos = items.index(name)
        state = self.sheet_list.cget("state")
        self.sheet_list.configure(state="normal")
        self.sheet_list.selection_clear(0, "end")
        self.sheet_list.selection_set(pos)
        self.sheet_list.see(pos)
        self.sheet_list.configure(state=state)
        self.idx_var.set(str(idx))
        self.update_preview()

    def browse_save(self):
        p = filedialog.askopenfilename(initialdir=str(self.game), filetypes=[("VX Ace save", "*.rvdata2"), ("all", "*.*")])
        if not p:
            return
        prof = data.save_profile(p)
        if prof:
            self.saves.append(Path(p))
            label = "%s - %s (%s)" % (Path(p).stem, names.en(prof["name"]), prof["playtime"])
            vals = self.save_box.cget("values")
            if isinstance(vals, str):
                vals = self.save_box.tk.splitlist(vals)
            vals = list(vals)
            vals.append(label)
            self.save_box.configure(values=vals)
            self.save_box.current(len(vals) - 1)
            self.preview_sheet(prof["gfx"], prof["idx"])
            if self.name_var.get().strip() in ("", "Traveller"):
                self.name_var.set(prof["name"] or "Helper")
            self.use_save.set(True)
            self.write("save: %s  look: %s #%d" % (p, prof["gfx"], prof["idx"]))
        else:
            self.write("could not read the save header: %s" % p)

    def current_save_path(self):
        i = self.save_box.current()
        if self.use_save.get() and 0 <= i < len(self.saves):
            return Path(self.saves[i])
        return None

    def start(self):
        game = Path(self.game_var.get())
        if not (game / "Game.exe").exists():
            messagebox.showerror("co-op", "Game.exe not found in:\n%s" % game)
            return
        try:
            port = int(self.port_var.get())
            if not 1024 <= port <= 65535:
                raise ValueError
        except ValueError:
            messagebox.showerror("co-op", "port must be 1024-65535")
            return
        mode = self.mode.get()
        name = self.name_var.get().strip()
        if mode == "guest" and not name:
            name = "Helper"
        name = name.replace("\n", " ").replace("\r", " ")[:40]
        try:
            self.write("--- %s ---" % time.strftime("%H:%M:%S"))
            self.write(patch.install(game))
            self.patch_label.configure(text="scripts: " + patch.status(game))
        except Exception as exc:
            messagebox.showerror("co-op", "could not patch the game:\n%s" % exc)
            return
        if mode == "host":
            if self.relay is not None and self.relay.port != port:
                self.relay.stop()
                self.relay = None
            if self.relay is None:
                r = Relay(port, on_change=self.relay_changed)
                try:
                    r.start()
                except OSError as exc:
                    messagebox.showerror("co-op", "could not open port %d:\n%s" % (port, exc))
                    return
                self.relay = r
                self.write("relay listening on %d" % port)
            if self.p2p is None:
                self.p2p = p2p.Host(port, on_log=self.pmsg.append)
                self.code_var.set("finding your address...")
                self.code_row.grid()
                self.add_row.grid()
                threading.Thread(target=self.open_host, daemon=True).start()
            addr = "127.0.0.1"
            gfx = ""
            idx = 0
            if self.custom_look.get():
                gfx = self.current_sheet()
                if not gfx:
                    messagebox.showerror("co-op", "pick the look you want first")
                    return
                try:
                    idx = int(self.idx_var.get())
                except ValueError:
                    idx = 0
            cfg = {"role": "host", "addr": addr, "port": port, "name": name, "gfx": gfx, "idx": idx, "save": 0, "class": 0}
            self.hint.configure(text="friends join at %s : %d" % (local_ip(), port))
        else:
            addr = self.addr_var.get().strip() or "127.0.0.1"
            if p2p.looks_like_code(addr):
                if self.p2p:
                    self.p2p.stop()
                self.p2p = p2p.Guest(addr, on_log=self.pmsg.append)
                mine = self.p2p.open()
                if self.p2p.node.strict:
                    self.write("p2p: your network is strict, connecting may fail")
                self.show_code(mine)
                self.write("p2p: sending your code to the host...")
                threading.Thread(target=self.post_code, args=(self.p2p, addr, mine), daemon=True).start()
                self.status.configure(text="waiting for the host to add your code...")
                addr = "127.0.0.1"
                port = self.p2p.port
            else:
                try:
                    addr = socket.gethostbyname(addr)
                except OSError as exc:
                    messagebox.showerror("co-op", "cannot resolve %s:\n%s" % (addr, exc))
                    return
                try:
                    socket.create_connection((addr, port), 2).close()
                except OSError as exc:
                    messagebox.showerror("co-op", "host not reachable at %s:%d\n%s" % (addr, port, exc))
                    return
            gfx = self.current_sheet()
            if not gfx:
                messagebox.showerror("co-op", "pick a character look first")
                return
            try:
                idx = int(self.idx_var.get())
            except ValueError:
                idx = 0
            cls = 0
            sel = self.class_box.get()
            if sel in self.class_map:
                cls = self.class_map[sel]
            save = 0
            src = self.current_save_path()
            saves_dir = game / "coop" / "saves"
            saves_dir.mkdir(parents=True, exist_ok=True)
            target = saves_dir / "Save01.rvdata2"
            if src:
                self.backup_guest_saves(game, src)
                try:
                    target.write_bytes(src.read_bytes())
                except OSError as exc:
                    messagebox.showerror("co-op", "could not copy the save:\n%s" % exc)
                    return
                save = 1
                self.write("save sandbox: %s" % target)
            else:
                if target.exists():
                    target.unlink()
                self.write("save sandbox: fresh character")
            cfg = {"role": "guest", "addr": addr, "port": port, "name": name, "gfx": gfx, "idx": idx, "save": save, "class": cls,
                   "src": src.stem if src else "new%d" % cls}
        coop = game / "coop"
        coop.mkdir(parents=True, exist_ok=True)
        lines = ["role=%s" % cfg["role"], "addr=%s" % cfg["addr"], "port=%d" % cfg["port"],
                 "name=%s" % cfg["name"], "gfx=%s" % cfg["gfx"], "idx=%d" % cfg["idx"],
                 "save=%d" % cfg["save"], "class=%d" % cfg["class"], "src=%s" % cfg.get("src", ""),
                 "face=%s" % self.current_face(), "fidx=%d" % self.face_index(),
                 "battle=1", "ncol=%s" % self.ncol]
        try:
            lidx = int(self.idx_var.get())
        except ValueError:
            lidx = 0
        data.remember("name", name)
        data.remember("look", {"gfx": self.current_sheet(), "idx": lidx, "custom": bool(self.custom_look.get()),
                               "face": self.current_face(), "fidx": self.face_index()})
        (coop / "session.cfg").write_text("\n".join(lines) + "\n", encoding="utf-8")
        try:
            (coop / "party.txt").unlink()
        except OSError:
            pass
        if self.proc and self.proc.poll() is None:
            self.write("game already running")
            return
        try:
            env = dict(os.environ, bs2mp="1")
            if self.appid and self.use_steam.get():
                env.update(SteamAppId=str(self.appid), SteamGameId=str(self.appid))
                self.ensure_steam()
            self.proc = subprocess.Popen([str(game / "Game.exe")], cwd=str(game), env=env)
            self.t0 = int(time.time())
        except OSError as exc:
            messagebox.showerror("co-op", "could not start Game.exe:\n%s" % exc)
            return
        if mode == "host" and self.relay:
            self.relay.attach_game(self.proc.pid)
        keep_awake(self.proc)
        self.go.configure(state="disabled")
        self.stop_btn.configure(state="normal")
        self.status.configure(text="game running - %s" % cfg["role"])
        self.log_pos = 0
        self.write("started Game.exe as %s" % cfg["role"])

    def backup_guest_saves(self, game, chosen):
        stamp = time.strftime("%Y%m%d-%H%M%S")
        dest = game / "coop" / "backup" / ("guest-" + stamp)
        dest.mkdir(parents=True, exist_ok=True)
        for p in game.glob("Save*.rvdata2"):
            try:
                (dest / p.name).write_bytes(p.read_bytes())
            except OSError:
                pass
        try:
            (dest / ("chosen-" + Path(chosen).name)).write_bytes(Path(chosen).read_bytes())
        except OSError:
            pass
        self.write("backed up saves to coop/backup/guest-%s" % stamp)

    def relay_changed(self):
        self.root.after(80, self.refresh_relay)

    def refresh_relay(self):
        if not self.relay:
            return
        count, names = self.relay.snapshot()
        if count:
            who = ", ".join(str(names[k]) for k in sorted(names))
            self.status.configure(text="party %d/4  %s" % (count, who))

    def ensure_steam(self):
        out = subprocess.run(["tasklist", "/FI", "IMAGENAME eq steam.exe", "/NH"], capture_output=True, text=True,
                             creationflags=0x08000000).stdout
        if "steam.exe" in out.lower():
            return
        self.write("starting steam...")
        try:
            os.startfile("steam://open/main")
        except OSError:
            self.write("could not start steam, achievements may not count")
            return
        end = time.time() + 30
        while time.time() < end:
            time.sleep(1)
            out = subprocess.run(["tasklist", "/FI", "IMAGENAME eq steam.exe", "/NH"], capture_output=True,
                                 text=True, creationflags=0x08000000).stdout
            if "steam.exe" in out.lower():
                time.sleep(5)
                return

    def open_host(self):
        try:
            code = self.p2p.open()
        except Exception as exc:
            self.pmsg.append("p2p failed: %s" % exc)
            return
        if self.p2p.node.strict:
            self.pmsg.append("p2p: your network is strict, friends may not get through")
        self.pmsg.append(("code", code))

    def show_code(self, code):
        self.code_var.set(code)
        self.code_row.grid()
        self.copy_code()

    def copy_code(self):
        code = self.code_var.get()
        if not p2p.looks_like_code(code):
            return
        self.root.clipboard_clear()
        self.root.clipboard_append(code)
        self.write("code copied - send it to your friend")

    def add_guest(self):
        code = self.gcode_var.get().strip()
        if not isinstance(self.p2p, p2p.Host):
            messagebox.showerror("co-op", "press start as host first")
            return
        if not self.p2p.add(code):
            messagebox.showerror("co-op", "that code doesn't look right")
            return
        self.gcode_var.set("")

    def post_code(self, g, hc, mine):
        end = time.time() + 300
        warned = False
        while time.time() < end and self.p2p is g and not g.peer.dead and not g.peer.up:
            try:
                mail.send(hc, mine)
            except Exception:
                if not warned:
                    warned = True
                    self.pmsg.append("p2p: couldn't auto-send your code, send it to the host yourself")
            time.sleep(15)

    def auto_add(self, code):
        if not isinstance(self.p2p, p2p.Host) or code in self.seen or not p2p.looks_like_code(code):
            return
        self.seen.add(code)
        if self.p2p.add(code):
            self.write("p2p: a friend's code arrived, connecting...")

    def join_from(self, code):
        if not p2p.looks_like_code(code):
            return
        if self.proc and self.proc.poll() is None:
            self.write("discord join ignored, the game is already running")
            return
        self.mode.set("guest")
        self.mode_changed()
        self.addr_var.set(code)
        self.status.configure(text="joining a party - pick your look, then press start")
        self.write("discord: got the host's code, pick your look and press start")
        self.root.deiconify()
        self.root.lift()
        self.root.attributes("-topmost", True)
        self.root.after(300, lambda: self.root.attributes("-topmost", False))
        self.root.focus_force()

    def presence(self):
        act = {"timestamps": {"start": self.t0}}
        if not (self.proc and self.proc.poll() is None):
            act["details"] = "Preparing..."
        else:
            try:
                n, lead = (Path(self.game_var.get()) / "coop" / "party.txt").read_text(encoding="utf-8").split("|", 1)
                n = int(n)
            except (OSError, ValueError):
                n, lead = 1, ""
            if self.mode.get() == "host" and self.relay:
                n = self.relay.snapshot()[0] or n
            n = min(max(n, 1), 4)
            act["details"] = "Finding Alice"
            act["state"] = "Soul" if n == 1 else "Souls"
            act["party"] = {"id": "bs2mp-" + (lead or str(self.t0)), "size": [n, 4]}
            if self.mode.get() == "host" and self.hcode and n < 4:
                act["secrets"] = {"join": self.hcode}
        self.rpc.set(act)

    def poll(self):
        self.root.after(800, self.poll)
        self.presence()
        while self.pmsg:
            m = self.pmsg.pop(0)
            if isinstance(m, tuple) and m[0] == "join":
                self.join_from(m[1])
            elif isinstance(m, tuple) and m[0] == "guest":
                self.auto_add(m[1])
            elif isinstance(m, tuple):
                self.show_code(m[1])
                self.hcode = m[1]
                if self.mbox:
                    self.mbox.stop()
                self.mbox = mail.Listen(m[1], lambda t: self.pmsg.append(("guest", t)))
            else:
                self.write(m)
                if m.startswith("p2p: "):
                    self.status.configure(text=m[5:])
        game = Path(self.game_var.get())
        log = game / "coop" / "log.txt"
        if log.exists():
            try:
                text = log.read_text(encoding="utf-8", errors="replace")
            except OSError:
                text = ""
            if len(text) > self.log_pos:
                self.write(text[self.log_pos:].rstrip("\n"))
                self.log_pos = len(text)
        if self.proc and self.proc.poll() is not None:
            self.write("game exited")
            self.proc = None
            self.go.configure(state="normal")
            self.stop_btn.configure(state="disabled")
            if self.status.cget("text").startswith("game running"):
                self.status.configure(text="game closed")

    def dummy_log(self, text):
        try:
            self.root.after(0, lambda t=text: self.write("tester: " + t))
        except Exception:
            pass

    def test_target(self):
        try:
            port = int(self.port_var.get())
        except ValueError:
            messagebox.showerror("co-op", "port must be a number")
            return None
        if self.mode.get() == "host":
            if self.relay is None:
                messagebox.showinfo("co-op", "press START first, the relay only runs while hosting")
                return None
            return "127.0.0.1", port
        addr = self.addr_var.get().strip() or "127.0.0.1"
        try:
            return socket.gethostbyname(addr), port
        except OSError:
            messagebox.showerror("co-op", "cannot resolve %s" % addr)
            return None

    def dummy_look(self):
        if self.looks:
            name, gfx, idx = self.looks[len(self.dummies.items) % len(self.looks)]
            return gfx, idx
        sheet = self.current_sheet()
        if not sheet:
            for s in self.sheets:
                if not s.startswith("!") and not s.startswith("$!"):
                    sheet = s
                    break
        return sheet, 0

    def add_dummy(self):
        target = self.test_target()
        if not target:
            return
        gfx, idx = self.dummy_look()
        if not gfx:
            messagebox.showerror("co-op", "no character sheets found in the game folder")
            return
        name = "Tester %d" % (len(self.dummies.items) + 1)
        self.dummies.add(target[0], target[1], name, gfx, idx)
        self.write("dummy %s -> %s:%d using %s" % (name, target[0], target[1], gfx))
        self.test_label.configure(text="dummies: %d" % len(self.dummies.items))

    def spawn_tester(self):
        target = self.test_target()
        if not target:
            return
        gfx, idx = self.dummy_look()
        if not gfx:
            messagebox.showerror("co-op", "pick a character look first")
            return
        if self.tester_proc is not None and self.tester_proc.poll() is None:
            self.write("test window is already running")
            return
        try:
            self.tester_proc, note = testclient.launch(self.game, target[1], "Test Window", gfx, idx, addr=target[0])
        except Exception as exc:
            messagebox.showerror("co-op", "could not start the test window:\n%s" % exc)
            return
        keep_awake(self.tester_proc)
        self.write("%s at %s" % (note, testclient.client_dir(self.game)))

    def clear_testers(self):
        self.dummies.stop_all()
        if self.tester_proc is not None and self.tester_proc.poll() is None:
            try:
                self.tester_proc.terminate()
            except OSError:
                pass
        self.tester_proc = None
        self.test_label.configure(text="")

    def stop_all(self):
        if self.proc and self.proc.poll() is None:
            try:
                self.proc.terminate()
            except OSError:
                pass
        self.proc = None
        if self.relay:
            self.relay.stop()
            self.relay = None
            self.write("relay stopped")
        if self.p2p:
            self.p2p.stop()
            self.p2p = None
            self.code_var.set("")
            self.code_row.grid_remove()
            self.add_row.grid_remove()
        if self.mbox:
            self.mbox.stop()
            self.mbox = None
        self.hcode = None
        self.seen = set()
        self.go.configure(state="normal")
        self.stop_btn.configure(state="disabled")
        self.status.configure(text="stopped")

    def on_close(self):
        self.rpc.stop()
        self.clear_testers()
        if self.relay:
            self.relay.stop()
        if self.p2p:
            self.p2p.stop()
        self.root.destroy()


def find_hwnd(pid):
    import ctypes
    from ctypes import wintypes

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


def keep_awake(proc):
    import ctypes
    import threading
    import time
    from ctypes import wintypes

    u = ctypes.windll.user32
    u.PostMessageW.argtypes = [wintypes.HWND, ctypes.c_uint, wintypes.WPARAM, wintypes.LPARAM]
    u.PostMessageW.restype = ctypes.c_bool

    def run():
        while proc is not None and proc.poll() is None:
            try:
                h = find_hwnd(proc.pid)
                if h and u.GetForegroundWindow() != h:
                    u.PostMessageW(h, 0x0006, 1, 0)
                    u.PostMessageW(h, 0x001C, 1, 0)
            except Exception:
                pass
            time.sleep(0.05)

    t = threading.Thread(target=run, daemon=True)
    t.start()
    return t


def local_ip():
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except OSError:
        return "127.0.0.1"


def main():
    root = tk.Tk()
    style = ttk.Style()
    try:
        style.theme_use("clam")
    except tk.TclError:
        pass
    style.configure("TCombobox", fieldbackground=bgc, background=bgc,
                    foreground=fgc, arrowcolor=dmc, bordercolor=pnc, lightcolor=pnc, darkcolor=pnc)
    style.map("TCombobox", fieldbackground=[("readonly", bgc), ("disabled", bgc)],
              foreground=[("readonly", fgc), ("disabled", dmc)], selectbackground=[("readonly", bgc)],
              selectforeground=[("readonly", fgc)], background=[("disabled", bgc)])
    App(root)
    root.mainloop()
