"""Smoke test for bridge_gui.py: run under a display (xvfb-run). Uses mock Twitch/Claude
servers, drives the window, simulates the plugin polling, and saves screenshots."""

import functools
import http.server
import json
import os
import socket
import sys
import tempfile
import threading
import time
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "bridge"))
os.environ["XDG_CONFIG_HOME"] = tempfile.mkdtemp()
for k in ("TWITCH_OAUTH", "ANTHROPIC_API_KEY", "TWITCH_CHANNEL"):
    os.environ.pop(k, None)

import tkinter as tk  # noqa: E402
from tkinter import ttk  # noqa: E402

import bridge  # noqa: E402
import bridge_gui  # noqa: E402

API, IRC, PORT = 28999, 26667, 28787


class Api(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass

    def do_GET(self):
        data = json.dumps({"login": "adi", "scopes": ["chat:read", "chat:edit"], "expires_in": 5184000}).encode()
        self.send_response(200); self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data)

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        time.sleep(0.3)
        data = json.dumps({"content": [{"type": "text", "text": "Go for the **Telos** pet? Bring max prayer and practise the enrage mechanics first."}]}).encode()
        self.send_response(200); self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data)


threading.Thread(target=http.server.HTTPServer(("127.0.0.1", API), Api).serve_forever, daemon=True).start()

IRC_IN = []


def irc():
    srv = socket.socket(); srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", IRC)); srv.listen(1)
    conn, _ = srv.accept()
    for raw in conn.makefile("rb"):
        line = raw.decode().strip(); IRC_IN.append(line)
        if line.startswith("JOIN"):
            for msg in (":me JOIN #adi",
                        "@color=#FF4500;display-name=Woodchop :w!w@w PRIVMSG #adi :gz on 99 woodcutting!",
                        "@color=#1E90FF;display-name=BossHunter :b!b@b PRIVMSG #adi :what boss next? telos?",
                        "@color=;display-name=Lurker :l!l@l PRIVMSG #adi :hi from the lurk <3"):
                conn.sendall((msg + "\r\n").encode())


threading.Thread(target=irc, daemon=True).start()

# Point the GUI's Config at the mocks.
bridge_gui.Config = functools.partial(bridge.Config, anthropic_url=f"http://127.0.0.1:{API}/v1/messages",
                                      twitch_host="127.0.0.1", twitch_port=IRC, twitch_tls=False,
                                      twitch_validate_url=f"http://127.0.0.1:{API}/validate")

root = tk.Tk()
style = ttk.Style(root)
style.theme_use("clam")
app = bridge_gui.App(root)
root.geometry("820x640+0+0")
app.v_channel.set("adi"); app.v_token.set("http://localhost/#access_token=abc&scope=x"); app.v_key.set("sk-ant-test")
app.v_port.set(str(PORT)); app.v_remember.set(True)


def shot(name):
    root.update(); time.sleep(0.2); root.update()
    from PIL import ImageGrab
    ImageGrab.grab(bbox=(0, 0, 820, 640)).save(os.path.join(sys.argv[1], name))


def plugin_poll():
    req = urllib.request.Request(f"http://127.0.0.1:{PORT}/poll?since=0", headers={"X-RS3-Bridge": "1"})
    return urllib.request.urlopen(req, timeout=3).read().decode()


steps = []


def run_steps():
    shot("gui-1-stopped.png")
    app.start()
    root.after(1500, step2)


def step2():
    assert app.bridge.running, "bridge running"
    plugin_poll()
    app.v_message.set("what should I do next?"); app.send_claude()
    root.after(1500, step3)


def step3():
    app.v_message.set("thanks chat!"); app.send_twitch()
    root.after(800, step4)


def step4():
    content = app.log.get("1.0", "end")
    assert "Woodchop: gz on 99" in content and "Claude: Go for the Telos pet" in content, content
    assert "hi from the lurk <3" in content, "markup unescaped for display"
    assert "PRIVMSG #adi :thanks chat!" in IRC_IN, IRC_IN
    assert "Plugin: connected" in app.s_plugin.text.cget("text")
    saved = json.loads(bridge_gui.config_path().read_text())
    assert saved["anthropic_key"] == "sk-ant-test" and saved["twitch_token"] == "http://localhost/#access_token=abc&scope=x"
    assert oct(os.stat(bridge_gui.config_path()).st_mode)[-3:] == "600"
    shot("gui-2-running.png")
    app.token_dialog()
    root.after(400, step5)


def step5():
    root.update()
    dlg = [w for w in root.winfo_children() if isinstance(w, tk.Toplevel)][0]
    dlg.geometry("+150+60"); root.update(); time.sleep(0.2)
    from PIL import ImageGrab
    dlg.update()
    x, y, w, h = dlg.winfo_rootx(), dlg.winfo_rooty(), dlg.winfo_width(), dlg.winfo_height()
    ImageGrab.grab(bbox=(x, y, x + w, y + h)).save(os.path.join(sys.argv[1], "gui-3-token-dialog.png"))
    dlg.destroy()
    app.stop()
    assert not app.bridge.running
    # Remember off: secrets removed from the file.
    app.v_remember.set(False); app.save()
    saved = json.loads(bridge_gui.config_path().read_text())
    assert "anthropic_key" not in saved and "twitch_token" not in saved and saved["channel"] == "adi"
    print("GUI SMOKE TEST PASSED")
    root.destroy()


root.after(300, run_steps)
root.mainloop()
