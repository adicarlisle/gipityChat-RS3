"""End-to-end test: mock Twitch IRC + mock Claude API -> real bridge.py -> main.lua
running in Lua 5.4 (via lupa) against a stubbed RS3 Client API.

Not a substitute for the real client, but it catches Lua errors, protocol bugs,
escaping, wrapping, filtering and the request/Logic-tick flow."""

import http.server
import json
import os
import socket
import subprocess
import sys
import threading
import time
import urllib.request

import lupa.lua54 as lupa

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BRIDGE_PORT, IRC_PORT, API_PORT = 18787, 16667, 18999
API_CALLS = []

# --- mock Claude API --------------------------------------------------------
class Api(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):  # Twitch token validation
        ok = self.headers.get("Authorization") == "OAuth abc123"
        data = json.dumps({"login": "adi", "scopes": ["chat:read", "chat:edit"], "expires_in": 5184000}).encode() if ok else b'{"status":401}'
        self.send_response(200 if ok else 401); self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data)
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        API_CALLS.append((dict(self.headers), body))
        last = body["messages"][-1]["content"]
        reply = {"content": [{"type": "text", "text": f"**Sure!** You said `{last}`. Bring a `prayer potion` and some food, then head to the boss — it's a long fight so pace yourself and watch the mechanics carefully."}]}
        data = json.dumps(reply).encode()
        self.send_response(200); self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data)

threading.Thread(target=http.server.HTTPServer(("127.0.0.1", API_PORT), Api).serve_forever, daemon=True).start()

# --- mock Twitch IRC --------------------------------------------------------
IRC_RECEIVED = []
def irc():
    srv = socket.socket(); srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", IRC_PORT)); srv.listen(1)
    conn, _ = srv.accept()
    f = conn.makefile("rb")
    def send(s): conn.sendall((s + "\r\n").encode())
    for raw in f:
        line = raw.decode().strip(); IRC_RECEIVED.append(line)
        if line.startswith("JOIN"):
            send(":me!me@me.tmi.twitch.tv JOIN #adi")
            send("@color=#FF4500;display-name=Zezima :zezima!z@z PRIVMSG #adi :gz on 99 woodcutting!")
            send("@color=;display-name=Lurker :lurker!l@l PRIVMSG #adi :<col=ff0000>fake red</col> <img=1> café 🎉")
            send("@color=#00FF00;display-name=Talker :talker!t@t PRIVMSG #adi :" + "this is a really long message " * 4)
            send("PING :tmi.twitch.tv")
threading.Thread(target=irc, daemon=True).start()

# --- bridge -----------------------------------------------------------------
env = dict(os.environ, ANTHROPIC_API_KEY="test-key", TWITCH_OAUTH=' "http://localhost/#access_token=abc123&scope=chat%3Aread+chat%3Aedit&token_type=bearer" ')
bridge = subprocess.Popen([sys.executable, os.path.join(ROOT, "bridge", "bridge.py"), "--channel", "adi", "--twitch-validate-url", f"http://127.0.0.1:{API_PORT}/oauth2/validate",
                           "--port", str(BRIDGE_PORT), "--anthropic-url", f"http://127.0.0.1:{API_PORT}/v1/messages",
                           "--twitch-host", "127.0.0.1", "--twitch-port", str(IRC_PORT), "--no-tls"], env=env)
import atexit
atexit.register(lambda: bridge.poll() is None and bridge.kill())
time.sleep(1.0)

def http_req(method, path, body=None, headers=None):
    req = urllib.request.Request(f"http://127.0.0.1:{BRIDGE_PORT}{path}", data=body.encode() if body is not None else None, method=method, headers=headers or {})
    try:
        with urllib.request.urlopen(req, timeout=5) as r:
            return True, r.status, r.read().decode()
    except urllib.error.HTTPError as e:
        return True, e.code, e.read().decode()
    except Exception as e:  # noqa
        return False, 0, str(e)

# Security checks on the bridge itself.
assert http_req("GET", "/poll")[1] == 403, "missing header must be refused"
assert http_req("GET", "/poll", headers={"X-RS3-Bridge": "1", "Origin": "https://evil.example"})[1] == 403, "Origin must be refused"
assert http_req("POST", "/claude", "x", headers={"Content-Type": "text/plain"})[1] == 403

# --- Lua side ---------------------------------------------------------------
L = lupa.LuaRuntime(unpack_returned_tuples=True)
L.globals().py_http = lambda method, path, body, headers: http_req(method, path, body, dict(headers.items()) if headers else {})
L.execute(open(os.path.join(ROOT, "test", "stubs.lua")).read())
L.execute(open(os.path.join(ROOT, "plugin", "twitch-claude-chat", "main.lua")).read())
G = L.globals()

def ticks(n, sleep=0.01):
    for _ in range(n):
        G.__tick()
        time.sleep(sleep)

def screen():
    return [G.__line(i) for i in range(1, G.__nlines() + 1)]

ticks(120)
print("\n".join(screen())); print("status:", G.__status())
s = "\n".join(screen())
assert "Zezima" in s and "gz on 99" in s, "twitch line shown"
assert "<lt>col=ff0000<gt>fake red" in s, "markup escaped"
assert "🎉" not in s and "cafe" in s, "emoji dropped, accent folded"
assert "live" in G.__status()

G.__submit("what should I bring to Zuk?")
ticks(150)
s = "\n".join(screen()); print("---\n" + s)
assert "You:" in s and "Claude:" in s
assert "**" not in s and "`" not in s, "markdown stripped"
hdrs, body = API_CALLS[-1]
assert body["model"] == "claude-haiku-5-5" and "Zezima: gz on 99 woodcutting!" in body["system"], "twitch context passed"

G.__submit("/t hello chat")
ticks(60)
assert any(l.startswith("PRIVMSG #adi :hello chat") for l in IRC_RECEIVED), IRC_RECEIVED
assert any(l == "PONG :tmi.twitch.tv" for l in IRC_RECEIVED)
assert "PASS oauth:abc123" in IRC_RECEIVED and "NICK adi" in IRC_RECEIVED, IRC_RECEIVED[:5]
assert "hello chat" in "\n".join(screen())

# Real game chat: own !tw / !c messages forwarded; others' ignored.
n_irc = len(IRC_RECEIVED); n_api = len(API_CALLS)
G.__chat(9, "Adi Rs", "!tw from friends chat <lt>3")
G.__chat(2, "Someone Else", "!tw spoof")
G.__chat(2, "Adi Rs", "just talking")
G.__chat(33, "Adi Rs", "!c plugin type ignored")
ticks(60)
sent = [l for l in IRC_RECEIVED[n_irc:] if l.startswith("PRIVMSG")]
assert sent == ["PRIVMSG #adi :from friends chat <3"], sent
G.__chat(9, "adi_rs", "!c how many prayer points?"); ticks(150)
assert len(API_CALLS) == n_api + 1 and API_CALLS[-1][1]["messages"][-1]["content"] == "how many prayer points?"
G.__submit("!tw via box"); ticks(60)
assert any(l == "PRIVMSG #adi :via box" for l in IRC_RECEIVED)

G.__submit("/clear"); ticks(60)
assert "Conversation cleared." in "\n".join(screen())
G.__submit("second question"); ticks(150)
assert len(API_CALLS[-1][1]["messages"]) == 1, "history cleared"

# Filter mode: Claude only hides twitch lines.
G.__press("mode"); G.__press("mode"); G.__tick()
s = "\n".join(screen()); print("--- Claude mode\n" + s)
assert "Zezima" not in s

# Mirror to game chat only for new lines, and only with chatAccess.
G.__press("mirror"); G.__submit("third"); ticks(150)
print("game chat:", list(G.__chatlog().values()))
log = list(G.__chatlog().values())
assert len(log) == 2 and log[1].startswith("<col=d97757>Claude:</col> Sure!") and "boss - it's" in log[1], log

# Wrapping: a fresh Claude reply wraps to the window width.
G.__press("mode"); G.__submit("/cls"); G.__submit("wrap test"); ticks(150)
before = [l for l in screen() if l]
conts_before = [l for l in before if l.startswith("   ")]
assert len(conts_before) >= 2 and all(len(l) <= 64 for l in conts_before), before

# Resize with the Size button: click, move mouse, click again.
n0 = G.__nlines(); r0 = dict(G.__root().items())
G.__press("size"); assert "again to finish" in G.__status()
G.__mouse.x = 100 + 300; G.__mouse.y = 100 + 160; ticks(3)
G.__press("size")
r1 = dict(G.__root().items())
assert r1["w"] == r0["w"] + 300 and r1["h"] == r0["h"] + 160, (r0, r1)
assert G.__nlines() == n0 + 10, (n0, G.__nlines())
after = [l for l in screen() if l]
assert len([l for l in after if l.startswith("   ")]) < len(conts_before), ("rewrapped wider", after)
print("--- after resize\n" + "\n".join(screen()))

# Move with the Move button.
G.__mouse.x, G.__mouse.y = 500, 500
G.__press("move"); G.__mouse.x, G.__mouse.y = 650, 420; ticks(2); G.__press("move")
r2 = dict(G.__root().items())
assert (r2["x"], r2["y"]) == (r1["x"] + 150, r1["y"] - 80), r2

# Minimum size is enforced, and typed commands work.
G.__submit("/size 10 10"); r3 = dict(G.__root().items()); assert (r3["w"], r3["h"]) == (380, 130), r3
G.__submit("/move 33 44"); r3 = dict(G.__root().items()); assert (r3["x"], r3["y"]) == (33, 44), r3
G.__submit("/reset"); r3 = dict(G.__root().items()); assert (r3["x"], r3["y"], r3["w"], r3["h"]) == (20, 120, 440, 270), r3

# Collapse and expand.
G.__press("collapse"); assert G.__root()["h"] < 40
G.__press("collapse"); assert G.__root()["h"] == 270

# Bridge goes away -> offline status, then back.
bridge.terminate(); bridge.wait()
ticks(60)
assert "offline" in G.__status(), G.__status()

G.PluginShutdown()
assert G.__subs() == 0, "Logic unsubscribed"
print("\nALL TESTS PASSED")
