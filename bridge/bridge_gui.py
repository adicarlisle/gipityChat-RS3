#!/usr/bin/env python3
"""
RS3 Chat Bridge - desktop app.

A window for running the Twitch + Claude bridge without the command line.
Works on Windows, macOS and Linux using Tkinter, which ships with Python
(on Ubuntu/Debian: sudo apt install python3-tk).

    python bridge_gui.py
"""

from __future__ import annotations

import json
import os
import shutil
import sys
import threading
import time
import tkinter as tk
import webbrowser
from pathlib import Path
from tkinter import filedialog, messagebox, scrolledtext, ttk

sys.path.insert(0, str(Path(__file__).resolve().parent))
from bridge import MODELS, Bridge, Config, normalise_token  # noqa: E402

APP_NAME = "RS3 Chat Bridge"
PLUGIN_NAME = "twitch-claude-chat"
TWITCH_CONSOLE = "https://dev.twitch.tv/console/apps"
ANTHROPIC_CONSOLE = "https://console.anthropic.com/settings/keys"

# ---------------------------------------------------------------------------
# Settings file
# ---------------------------------------------------------------------------


def config_path() -> Path:
    if sys.platform == "win32":
        base = Path(os.environ.get("APPDATA") or Path.home() / "AppData" / "Roaming")
        return base / "RS3ChatBridge" / "config.json"
    if sys.platform == "darwin":
        return Path.home() / "Library" / "Application Support" / "RS3ChatBridge" / "config.json"
    base = Path(os.environ.get("XDG_CONFIG_HOME") or Path.home() / ".config")
    return base / "rs3-chat-bridge" / "config.json"


SECRET_KEYS = ("twitch_token", "anthropic_key")


def load_settings() -> dict:
    try:
        return json.loads(config_path().read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}


def save_settings(data: dict, remember_secrets: bool) -> None:
    path = config_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    if not remember_secrets:
        data = {k: v for k, v in data.items() if k not in SECRET_KEYS}
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(data, indent=2), encoding="utf-8")
    if os.name == "posix":
        os.chmod(tmp, 0o600)  # only you can read it
    tmp.replace(path)


# ---------------------------------------------------------------------------
# Finding the RS3 beta plugin folder
# ---------------------------------------------------------------------------


def plugin_source_dir() -> Path:
    if getattr(sys, "frozen", False):  # packaged with PyInstaller
        return Path(getattr(sys, "_MEIPASS")) / "plugin" / PLUGIN_NAME
    return Path(__file__).resolve().parent.parent / "plugin" / PLUGIN_NAME


def candidate_beta_dirs() -> list[Path]:
    home = Path.home()
    c = []
    if sys.platform == "win32":
        c += [Path(os.environ.get("PROGRAMDATA", r"C:\ProgramData")) / "Jagex" / "RuneScape-BETA",
              Path(os.environ.get("LOCALAPPDATA", home / "AppData" / "Local")) / "Jagex" / "RuneScape-BETA"]
        for steam in (Path(r"C:\Program Files (x86)\Steam"), Path(r"C:\Program Files\Steam")):
            c.append(steam / "steamapps" / "common" / "RuneScape" / "RuneScape-BETA")
    elif sys.platform == "darwin":
        c += [home / "Jagex" / "RuneScape-BETA",
              home / "Library" / "Application Support" / "Steam" / "steamapps" / "common" / "RuneScape" / "RuneScape-BETA"]
    else:
        for steam in (home / ".local/share/Steam", home / ".steam/steam",
                      home / ".var/app/com.valvesoftware.Steam/.local/share/Steam"):
            c.append(steam / "steamapps/common/RuneScape/RuneScape-BETA")
        c += [home / ".local/share/bolt-launcher/Jagex/RuneScape-BETA",
              home / ".local/share/bolt-launcher/jagex/RuneScape-BETA",
              home / ".var/app/com.adamcake.Bolt/data/bolt-launcher/Jagex/RuneScape-BETA"]
    return [p for p in c if p.is_dir()]


# ---------------------------------------------------------------------------
# The window
# ---------------------------------------------------------------------------

STATUS_COLOURS = {"good": "#2fa84f", "busy": "#d9a400", "bad": "#d64545", "off": "#8a8a8a"}


class StatusDot(ttk.Frame):
    def __init__(self, parent, label: str):
        super().__init__(parent)
        self.dot = tk.Label(self, text="\u25cf", font=("TkDefaultFont", 12))
        self.dot.pack(side="left")
        self.text = ttk.Label(self, text=label)
        self.text.pack(side="left", padx=(2, 0))
        self.label = label

    def set(self, level: str, detail: str) -> None:
        self.dot.configure(fg=STATUS_COLOURS[level])
        self.text.configure(text=f"{self.label}: {detail}")


class SecretEntry(ttk.Frame):
    """A password-style entry with a Show/Hide toggle."""

    def __init__(self, parent, var: tk.StringVar, width: int = 40):
        super().__init__(parent)
        self.entry = ttk.Entry(self, textvariable=var, show="\u2022", width=width)
        self.entry.pack(side="left", fill="x", expand=True)
        self.btn = ttk.Button(self, text="Show", width=6, command=self.toggle)
        self.btn.pack(side="left", padx=(4, 0))

    def toggle(self) -> None:
        hidden = self.entry.cget("show") != ""
        self.entry.configure(show="" if hidden else "\u2022")
        self.btn.configure(text="Hide" if hidden else "Show")

    def set_state(self, state: str) -> None:
        self.entry.configure(state=state)


class App:
    def __init__(self, root: tk.Tk):
        self.root = root
        self.bridge: Bridge | None = None
        self.seen = 0
        self.starting = False
        self.colour_tags: set[str] = set()

        saved = load_settings()
        self.v_channel = tk.StringVar(value=saved.get("channel", os.environ.get("TWITCH_CHANNEL", "")))
        self.v_token = tk.StringVar(value=saved.get("twitch_token", os.environ.get("TWITCH_OAUTH", "")))
        self.v_key = tk.StringVar(value=saved.get("anthropic_key", os.environ.get("ANTHROPIC_API_KEY", "")))
        self.v_model = tk.StringVar(value=saved.get("model", MODELS[0]))
        self.v_port = tk.StringVar(value=str(saved.get("port", 8787)))
        self.v_remember = tk.BooleanVar(value=bool(saved.get("remember_secrets", False)))
        self.v_autostart = tk.BooleanVar(value=bool(saved.get("autostart", False)))
        self.v_client_id = tk.StringVar(value=saved.get("twitch_client_id", ""))
        self.v_message = tk.StringVar()

        root.title(APP_NAME)
        root.minsize(620, 520)
        self._build()
        self._refresh_status()
        root.protocol("WM_DELETE_WINDOW", self.on_close)
        root.after(250, self._tick)
        if self.v_autostart.get():
            root.after(300, self.start)

    # ----- layout -----

    def _build(self) -> None:
        pad = {"padx": 8, "pady": 4}
        outer = ttk.Frame(self.root, padding=10)
        outer.pack(fill="both", expand=True)

        settings = ttk.LabelFrame(outer, text="Settings", padding=8)
        settings.pack(fill="x")
        settings.columnconfigure(1, weight=1)

        ttk.Label(settings, text="Twitch channel").grid(row=0, column=0, sticky="w", **pad)
        self.e_channel = ttk.Entry(settings, textvariable=self.v_channel)
        self.e_channel.grid(row=0, column=1, sticky="ew", **pad)
        ttk.Label(settings, text="your Twitch name; leave empty for Claude only", foreground="#777").grid(row=0, column=2, sticky="w", **pad)

        ttk.Label(settings, text="Twitch token").grid(row=1, column=0, sticky="w", **pad)
        self.e_token = SecretEntry(settings, self.v_token)
        self.e_token.grid(row=1, column=1, sticky="ew", **pad)
        self.b_get_token = ttk.Button(settings, text="Get token\u2026", command=self.token_dialog)
        self.b_get_token.grid(row=1, column=2, sticky="w", **pad)

        ttk.Label(settings, text="Anthropic API key").grid(row=2, column=0, sticky="w", **pad)
        self.e_key = SecretEntry(settings, self.v_key)
        self.e_key.grid(row=2, column=1, sticky="ew", **pad)
        ttk.Button(settings, text="Get key\u2026", command=lambda: webbrowser.open(ANTHROPIC_CONSOLE)).grid(row=2, column=2, sticky="w", **pad)

        ttk.Label(settings, text="Claude model").grid(row=3, column=0, sticky="w", **pad)
        self.e_model = ttk.Combobox(settings, textvariable=self.v_model, values=MODELS)
        self.e_model.grid(row=3, column=1, sticky="ew", **pad)
        ttk.Label(settings, text="Haiku is quickest; Sonnet answers better", foreground="#777").grid(row=3, column=2, sticky="w", **pad)

        ttk.Label(settings, text="Port").grid(row=4, column=0, sticky="w", **pad)
        self.e_port = ttk.Spinbox(settings, textvariable=self.v_port, from_=1024, to=65535, width=8)
        self.e_port.grid(row=4, column=1, sticky="w", **pad)
        ttk.Label(settings, text="must match plugin.json (8787)", foreground="#777").grid(row=4, column=2, sticky="w", **pad)

        opts = ttk.Frame(settings)
        opts.grid(row=5, column=0, columnspan=3, sticky="w", padx=4, pady=(6, 0))
        ttk.Checkbutton(opts, text="Remember token and key on this computer", variable=self.v_remember,
                        command=self.save).pack(anchor="w")
        ttk.Label(opts, text=f"Saved unencrypted, readable only by your user: {config_path()}",
                  foreground="#777", wraplength=560).pack(anchor="w", padx=(22, 0))
        ttk.Checkbutton(opts, text="Start the bridge when this app opens", variable=self.v_autostart,
                        command=self.save).pack(anchor="w", pady=(4, 0))

        # Controls + status
        bar = ttk.Frame(outer, padding=(0, 10, 0, 6))
        bar.pack(fill="x")
        self.b_start = ttk.Button(bar, text="Start bridge", command=self.toggle)
        self.b_start.pack(side="left")
        ttk.Button(bar, text="Install plugin into RS3\u2026", command=self.install_plugin).pack(side="left", padx=(6, 0))
        if sys.platform.startswith("linux"):
            ttk.Button(bar, text="Add to app menu", command=self.add_to_app_menu).pack(side="left", padx=(6, 0))
        status = ttk.Frame(outer, padding=(0, 0, 0, 8))
        status.pack(fill="x")
        self.s_bridge = StatusDot(status, "Bridge")
        self.s_twitch = StatusDot(status, "Twitch")
        self.s_claude = StatusDot(status, "Claude")
        self.s_plugin = StatusDot(status, "Plugin")
        for s in (self.s_bridge, self.s_twitch, self.s_claude, self.s_plugin):
            s.pack(side="left", padx=(0, 18))

        # Chat log
        log_frame = ttk.LabelFrame(outer, text="Chat", padding=4)
        log_frame.pack(fill="both", expand=True)
        self.log = scrolledtext.ScrolledText(log_frame, height=14, wrap="word", state="disabled",
                                             background="#151515", foreground="#e8e8e8",
                                             insertbackground="#e8e8e8", relief="flat", borderwidth=0)
        self.log.pack(fill="both", expand=True)

        # Test bar
        send = ttk.Frame(outer, padding=(0, 6, 0, 0))
        send.pack(fill="x")
        self.e_message = ttk.Entry(send, textvariable=self.v_message)
        self.e_message.pack(side="left", fill="x", expand=True)
        self.e_message.bind("<Return>", lambda _e: self.send_claude())
        ttk.Button(send, text="Ask Claude", command=self.send_claude).pack(side="left", padx=(6, 0))
        ttk.Button(send, text="Send to Twitch", command=self.send_twitch).pack(side="left", padx=(6, 0))

    # ----- settings -----

    def settings_dict(self) -> dict:
        try:
            port = int(self.v_port.get())
        except ValueError:
            port = 8787
        return {
            "channel": self.v_channel.get().strip(),
            "twitch_token": self.v_token.get().strip(),
            "anthropic_key": self.v_key.get().strip(),
            "model": self.v_model.get().strip() or MODELS[0],
            "port": port,
            "remember_secrets": self.v_remember.get(),
            "autostart": self.v_autostart.get(),
            "twitch_client_id": self.v_client_id.get().strip(),
        }

    def save(self) -> None:
        try:
            save_settings(self.settings_dict(), self.v_remember.get())
        except OSError as exc:
            messagebox.showwarning(APP_NAME, f"Couldn't save settings:\n{exc}")

    def _set_settings_state(self, enabled: bool) -> None:
        state = "normal" if enabled else "disabled"
        for w in (self.e_channel, self.e_model, self.e_port):
            w.configure(state=state)
        self.e_token.set_state(state)
        self.e_key.set_state(state)

    # ----- start / stop -----

    def toggle(self) -> None:
        if self.bridge and self.bridge.running:
            self.stop()
        else:
            self.start()

    def start(self) -> None:
        if self.starting or (self.bridge and self.bridge.running):
            return
        s = self.settings_dict()
        if not 1024 <= s["port"] <= 65535:
            messagebox.showerror(APP_NAME, "Port must be a number between 1024 and 65535.")
            return
        self.save()
        cfg = Config(channel=s["channel"], twitch_token=s["twitch_token"], anthropic_key=s["anthropic_key"],
                     model=s["model"], port=s["port"])
        # Keep one Bridge (and its message history) across restarts.
        if self.bridge is None:
            self.bridge = Bridge(cfg)
        else:
            self.bridge.cfg = cfg
        self.starting = True
        self.b_start.configure(text="Starting\u2026", state="disabled")
        self._set_settings_state(False)

        def work():  # token check can take a few seconds; keep the window responsive
            err = None
            try:
                self.bridge.start()
            except OSError as exc:
                err = exc
            self.root.after(0, lambda: self._started(err))

        threading.Thread(target=work, daemon=True).start()

    def _started(self, err: Exception | None) -> None:
        self.starting = False
        if err:
            self._set_settings_state(True)
            messagebox.showerror(APP_NAME, f"Couldn't start on port {self.v_port.get()}:\n{err}\n\n"
                                            "Another bridge (or app) may already be using it.")
        self._refresh_status()

    def stop(self) -> None:
        if self.bridge:
            self.bridge.stop()
        self._set_settings_state(True)
        self._refresh_status()

    def on_close(self) -> None:
        self.save()
        if self.bridge and self.bridge.running:
            self.bridge.stop()
        self.root.destroy()

    # ----- sending -----

    def send_claude(self) -> None:
        text = self.v_message.get().strip()
        if not text:
            return
        if not (self.bridge and self.bridge.running):
            messagebox.showinfo(APP_NAME, "Start the bridge first.")
            return
        self.bridge.ask_claude(text)
        self.v_message.set("")

    def send_twitch(self) -> None:
        text = self.v_message.get().strip()
        if not text:
            return
        if not (self.bridge and self.bridge.running):
            messagebox.showinfo(APP_NAME, "Start the bridge first.")
            return
        if self.bridge.say_twitch(text):
            self.v_message.set("")

    # ----- live updates -----

    def _tick(self) -> None:
        if self.bridge:
            rows = self.bridge.store.rows_since(self.seen)
            if rows:
                self._append(rows)
                self.seen = rows[-1][0]
        self._refresh_status()
        self.root.after(250, self._tick)

    def _append(self, rows) -> None:
        self.log.configure(state="normal")
        at_bottom = self.log.yview()[1] > 0.98
        for _id, kind, name, colour, text in rows:
            text = text.replace("<lt>", "<").replace("<gt>", ">")
            name = name.replace("<lt>", "<").replace("<gt>", ">")
            tag = "c" + colour
            if tag not in self.colour_tags:
                self.log.tag_configure(tag, foreground="#" + colour, font=("TkDefaultFont", 10, "bold"))
                self.colour_tags.add(tag)
            if kind == "system":
                self.log.tag_configure("system", foreground="#9a9a9a")
                self.log.insert("end", text + "\n", "system")
            elif name:
                self.log.insert("end", name + ": ", tag)
                self.log.insert("end", text + "\n")
            else:
                self.log.insert("end", "    " + text + "\n")
        # Keep the log from growing forever.
        lines = int(self.log.index("end-1c").split(".")[0])
        if lines > 2000:
            self.log.delete("1.0", f"{lines - 2000}.0")
        self.log.configure(state="disabled")
        if at_bottom:
            self.log.see("end")

    def _refresh_status(self) -> None:
        b = self.bridge
        running = bool(b and b.running)
        if self.starting:
            self.s_bridge.set("busy", "starting")
        else:
            self.s_bridge.set("good" if running else "off", f"on :{b.cfg.port}" if running else "stopped")
            self.b_start.configure(text="Stop bridge" if running else "Start bridge", state="normal")
        store = b.store if b else None
        tw = store.twitch_state if (store and running) else "off"
        self.s_twitch.set({"connected": "good", "connecting": "busy"}.get(tw, "off"),
                          {"connected": "live", "connecting": "connecting"}.get(tw, "off"))
        if not running:
            self.s_claude.set("off", "off")
        else:
            cs = store.claude_state
            self.s_claude.set({"idle": "good", "thinking": "busy"}.get(cs, "bad"),
                              {"idle": "ready", "thinking": "thinking", "nokey": "no key"}.get(cs, cs))
        if running and store.last_poll and (time.time() - store.last_poll) < 5:
            self.s_plugin.set("good", "connected")
        else:
            self.s_plugin.set("off" if not running else "busy", "waiting" if running else "\u2013")

    # ----- Twitch token helper -----

    def token_dialog(self) -> None:
        d = tk.Toplevel(self.root)
        d.title("Get a Twitch token")
        d.transient(self.root)
        d.resizable(False, False)
        f = ttk.Frame(d, padding=12)
        f.pack(fill="both", expand=True)
        wrap = 460

        ttk.Label(f, text="1. Register an app (once)", font=("TkDefaultFont", 10, "bold")).pack(anchor="w")
        ttk.Label(f, wraplength=wrap, justify="left", text=(
            "Open the Twitch developer console, click Register Your Application and use:\n"
            "  OAuth Redirect URL: http://localhost\n  Category: Chat Bot    Client Type: Public\n"
            "Then click Manage and copy the Client ID.")).pack(anchor="w", pady=(2, 4))
        ttk.Button(f, text="Open Twitch developer console", command=lambda: webbrowser.open(TWITCH_CONSOLE)).pack(anchor="w")

        ttk.Label(f, text="2. Authorise", font=("TkDefaultFont", 10, "bold")).pack(anchor="w", pady=(12, 0))
        row = ttk.Frame(f)
        row.pack(fill="x", pady=(2, 0))
        ttk.Label(row, text="Client ID").pack(side="left")
        ttk.Entry(row, textvariable=self.v_client_id, width=36).pack(side="left", padx=6, fill="x", expand=True)

        def open_auth():
            cid = self.v_client_id.get().strip()
            if not cid:
                messagebox.showinfo(APP_NAME, "Paste your Client ID first.", parent=d)
                return
            self.save()
            webbrowser.open("https://id.twitch.tv/oauth2/authorize?response_type=token"
                            f"&client_id={cid}&redirect_uri=http://localhost&scope=chat%3Aread+chat%3Aedit")

        ttk.Button(row, text="Open login page", command=open_auth).pack(side="left")
        ttk.Label(f, wraplength=wrap, justify="left", foreground="#777", text=(
            "After you click Authorize, the browser goes to a localhost page that won't load. "
            "That's expected.")).pack(anchor="w", pady=(4, 0))

        ttk.Label(f, text="3. Paste the address", font=("TkDefaultFont", 10, "bold")).pack(anchor="w", pady=(12, 0))
        ttk.Label(f, wraplength=wrap, justify="left", text=(
            "Copy the whole address from the browser's address bar (http://localhost/#access_token=...) "
            "and paste it here:")).pack(anchor="w")
        v_paste = tk.StringVar()
        ttk.Entry(f, textvariable=v_paste, width=60).pack(fill="x", pady=4)

        def use():
            tok = normalise_token(v_paste.get())
            if not tok:
                messagebox.showerror(APP_NAME, "That doesn't look like a token or a localhost address.", parent=d)
                return
            self.v_token.set(tok)
            self.save()
            d.destroy()
            if self.bridge and self.bridge.running:
                messagebox.showinfo(APP_NAME, "Token saved. Stop and start the bridge to use it.")

        btns = ttk.Frame(f)
        btns.pack(fill="x", pady=(6, 0))
        ttk.Button(btns, text="Use this token", command=use).pack(side="right")
        ttk.Button(btns, text="Cancel", command=d.destroy).pack(side="right", padx=6)
        d.grab_set()

    # ----- Linux app menu shortcut -----

    def add_to_app_menu(self) -> None:
        try:
            path = install_linux_shortcut()
        except OSError as exc:
            messagebox.showerror(APP_NAME, f"Couldn't add the shortcut:\n{exc}")
            return
        messagebox.showinfo(APP_NAME, f"Added '{APP_NAME}' to your app menu.\n\n({path})\n\n"
                                      "If you move this app's file, click this button again.")

    # ----- plugin install helper -----

    def install_plugin(self) -> None:
        src = plugin_source_dir()
        if not (src / "main.lua").is_file():
            messagebox.showerror(APP_NAME, f"Can't find the plugin files next to this app:\n{src}")
            return
        found = candidate_beta_dirs()
        if len(found) == 1:
            target = found[0]
            if not messagebox.askyesno(APP_NAME, f"Install the plugin into:\n{target}\n\nOK?"):
                return
        else:
            hint = ("Found several RS3 beta folders; pick the one you play with."
                    if found else "Couldn't find the RS3 beta folder automatically. "
                    "Launch the beta client once, then pick its RuneScape-BETA folder.")
            messagebox.showinfo(APP_NAME, hint)
            chosen = filedialog.askdirectory(title="Choose the RuneScape-BETA folder",
                                             initialdir=str(found[0] if found else Path.home()))
            if not chosen:
                return
            target = Path(chosen)
        dest = target / "dev_plugins" / PLUGIN_NAME
        try:
            dest.mkdir(parents=True, exist_ok=True)
            for f in ("main.lua", "plugin.json"):
                shutil.copy2(src / f, dest / f)
        except OSError as exc:
            messagebox.showerror(APP_NAME, f"Couldn't copy the plugin:\n{exc}")
            return
        messagebox.showinfo(APP_NAME, (
            f"Installed to:\n{dest}\n\nIn the beta client, open the console (Alt + `) and run:\n"
            f"prf\npon {PLUGIN_NAME}\nppr {PLUGIN_NAME}\nppe {PLUGIN_NAME} httpAccess\n"
            f"ppe {PLUGIN_NAME} chatAccess\n\nAfter updating, use: prl {PLUGIN_NAME}"))


def launch_command() -> str:
    """How to start this app again, for a desktop shortcut."""
    if getattr(sys, "frozen", False):
        return f'"{Path(sys.executable).resolve()}"'
    return f'"{Path(sys.executable).resolve()}" "{Path(__file__).resolve()}"'


def install_linux_shortcut() -> Path:
    """Adds 'RS3 Chat Bridge' to the Linux app menu (freedesktop .desktop file)."""
    apps = Path(os.environ.get("XDG_DATA_HOME") or Path.home() / ".local" / "share") / "applications"
    apps.mkdir(parents=True, exist_ok=True)
    path = apps / "rs3-chat-bridge.desktop"
    path.write_text(
        "[Desktop Entry]\n"
        "Type=Application\n"
        f"Name={APP_NAME}\n"
        "Comment=Twitch chat and Claude for the RuneScape 3 plugin\n"
        f"Exec={launch_command()}\n"
        "Icon=utilities-terminal\n"
        "Terminal=false\n"
        "Categories=Game;Utility;\n",
        encoding="utf-8",
    )
    path.chmod(0o755)
    return path


def main() -> None:
    if sys.platform == "win32":
        try:  # crisp text on high-DPI Windows screens
            import ctypes
            ctypes.windll.shcore.SetProcessDpiAwareness(1)
        except Exception:  # noqa: BLE001
            pass
    root = tk.Tk()
    style = ttk.Style(root)
    if sys.platform.startswith("linux") and "clam" in style.theme_names():
        style.theme_use("clam")  # nicer than Tk's default on Linux; Windows/macOS keep native looks
    App(root)
    root.mainloop()


if __name__ == "__main__":
    main()
