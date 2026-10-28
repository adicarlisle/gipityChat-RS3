"""End-to-end test: main.lua (Lua 5.4 via lupa, stubbed RS3 API) talking to the Firebot
startup script running inside test/firebot-mock (Express configured like Firebot), with a
mock Claude API. Needs: pip install lupa; cd test/firebot-mock && npm install."""

import http.server
import json
import os
import subprocess
import threading
import time
import urllib.error
import urllib.request

import lupa.lua54 as lupa

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FIREBOT_PORT, API_PORT, BRIDGE_CLOSED_PORT = 17472, 18997, 17998
API_CALLS = []


class Api(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        API_CALLS.append((dict(self.headers), body))
        last = body["messages"][-1]["content"]
        data = json.dumps({"content": [{"type": "text", "text": f"**Firebot** relayed: `{last}` — good luck!"}]}).encode()
        self.send_response(200); self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data)


threading.Thread(target=http.server.HTTPServer(("127.0.0.1", API_PORT), Api).serve_forever, daemon=True).start()

env = dict(os.environ, PORT=str(FIREBOT_PORT), TEST_ANTHROPIC_KEY="sk-test",
           RS3CHAT_ANTHROPIC_URL=f"http://127.0.0.1:{API_PORT}/v1/messages")
fb = subprocess.Popen(["node", os.path.join(ROOT, "test", "firebot-mock", "mock_firebot.js")], env=env,
                      stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, bufsize=1)
FB_OUT = []
threading.Thread(target=lambda: [FB_OUT.append(json.loads(l)) for l in fb.stdout], daemon=True).start()
import atexit  # noqa: E402
atexit.register(lambda: fb.poll() is None and fb.kill())
for _ in range(100):
    if any("ready" in o for o in FB_OUT):
        break
    time.sleep(0.05)
assert any("ready" in o for o in FB_OUT), FB_OUT


def fb_cmd(obj):
    fb.stdin.write(json.dumps(obj) + "\n"); fb.stdin.flush()


def raw(method, path, headers=None, body=None):
    req = urllib.request.Request(f"http://127.0.0.1:{FIREBOT_PORT}{path}", method=method, headers=headers or {},
                                 data=body.encode() if body else None)
    try:
        with urllib.request.urlopen(req, timeout=5) as r:
            return r.status, r.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()


# Security: only the game plugin (header, no Origin) may use the routes.
P = "/integrations/rs3chat"
assert raw("GET", P + "/poll")[0] == 403
assert raw("GET", P + "/poll", {"X-RS3-Bridge": "1", "Origin": "https://evil.example"})[0] == 403
assert raw("POST", P + "/claude", {"X-RS3-Bridge": "1", "Origin": "https://evil.example",
                                   "Content-Type": "application/x-www-form-urlencoded"}, "text=spend")[0] == 403
assert raw("GET", P + "/health", {"X-RS3-Bridge": "1"}) == (200, "OK firebot\n")
assert len(API_CALLS) == 0


def plugin_http(method, base, path, body, headers):
    port = FIREBOT_PORT if base == "firebot" else BRIDGE_CLOSED_PORT
    req = urllib.request.Request(f"http://127.0.0.1:{port}{path}", data=body.encode() if body is not None else None,
                                 method=method, headers=dict(headers.items()) if headers else {})
    try:
        with urllib.request.urlopen(req, timeout=5) as r:
            return True, r.status, r.read().decode()
    except urllib.error.HTTPError as e:
        return True, e.code, e.read().decode()
    except Exception as e:  # noqa: BLE001
        return False, 0, str(e)


L = lupa.LuaRuntime(unpack_returned_tuples=True)
L.globals().py_http = plugin_http
L.execute(open(os.path.join(ROOT, "test", "stubs.lua")).read())
L.execute(open(os.path.join(ROOT, "plugin", "twitch-claude-chat", "main.lua")).read())
G = L.globals()


def ticks(n, sleep=0.01):
    for _ in range(n):
        G.__tick(); time.sleep(sleep)


def screen():
    return [G.__line(i) for i in range(1, G.__nlines() + 1)]


ticks(40)
s = "\n".join(screen())
assert "Connected via Firebot." in s and G.__status().startswith("Firebot:"), (s, G.__status())
assert "live" in G.__status() and "ready" in G.__status(), G.__status()

# Chat from Firebot, with emotes and spam.
fb_cmd({"chat": {"id": "1", "username": "woodchop", "userDisplayName": "Woodchop", "color": "#FF4500",
                 "rawText": "gz on 99 PogChamp LUL LUL LUL LUL",
                 "parts": [{"type": "text", "text": "gz on 99 "}, {"type": "emote", "name": "PogChamp"}, {"type": "text", "text": " "},
                           {"type": "emote", "name": "LUL"}, {"type": "text", "text": " "}, {"type": "emote", "name": "LUL"},
                           {"type": "text", "text": " "}, {"type": "emote", "name": "LUL"}, {"type": "text", "text": " "},
                           {"type": "emote", "name": "LUL"}], "action": False, "whisper": False}})
fb_cmd({"chat": {"id": "2", "username": "lurker", "userDisplayName": "Lurker", "rawText": "<col=ff0000>red</col> café \U0001F389",
                 "parts": [{"type": "text", "text": "<col=ff0000>red</col> café \U0001F389"}], "action": False}})
fb_cmd({"chat": {"id": "3", "username": "sneaky", "userDisplayName": "Sneaky", "rawText": "secret", "whisper": True,
                 "parts": [{"type": "text", "text": "secret"}]}})
fb_cmd({"chat": {"id": "4", "username": "held", "userDisplayName": "Held", "rawText": "bad words", "isAutoModHeld": True,
                 "parts": [{"type": "text", "text": "bad words"}]}})
ticks(60)
s = "\n".join(screen())
print(s)
assert "<col=ff4500>Woodchop:</col> gz on 99 <col=ffd166>PogChamp</col> <col=ffd166>LUL</col> x4" in s, s
assert "<col=b9a3e3>Lurker:</col> <lt>col=ff0000<gt>red<lt>/col<gt> cafe" in s
assert "secret" not in s and "bad words" not in s, "whispers and AutoMod-held messages hidden"

# Ask Claude from the window (form-encoded POST through Firebot).
G.__submit("what & where? 100% sure")
ticks(120)
s = "\n".join(screen())
assert "<col=7fd1ff>You:</col> what & where? 100% sure" in s, s
assert "Firebot relayed: what & where? 100% sure - good luck!" in s, s
hdrs, body = API_CALLS[-1]
assert hdrs.get("x-api-key") == "sk-test" and body["model"] == "claude-haiku-5-5"
assert "Woodchop: gz on 99 PogChamp(emote) LUL(emote) x4" in body["system"], body["system"]

# /t from the window and !tw from game chat go out through Firebot's Twitch API.
G.__submit("/t hello chat")
G.__chat(9, "Adi Rs", "!tw from the game <lt>3")
ticks(80)
sent = [o["sent"] for o in FB_OUT if "sent" in o]
assert {"message": "hello chat", "asBot": False} in sent and {"message": "from the game <3", "asBot": False} in sent, sent
assert "<col=7fd1ff>Adi:</col> hello chat" in "\n".join(screen())

# Wrapping ignores colour tags: a long line of emotes wraps by visible width, tags intact.
fb_cmd({"chat": {"id": "5", "username": "spam", "userDisplayName": "Spam", "rawText": "x",
                 "parts": [{"type": "emote", "name": f"Emote{i}"} for i in range(14)]}})
ticks(60)
emote_lines = [l for l in screen() if "Emote" in l]
assert len(emote_lines) >= 2, emote_lines
for line in emote_lines:
    assert line.count("<col=") == line.count("</col>"), line
    visible = line.replace("<col=ffd166>", "").replace("</col>", "").replace("<col=b9a3e3>", "")
    assert len(visible) <= 62, (len(visible), line)

# Settings change + no key.
fb_cmd({"params": {"anthropicApiKey": "", "model": "claude-sonnet-5-5"}})
ticks(40)
assert "no key" in G.__status(), G.__status()

# Firebot going away: the plugin looks for the bridge (closed here) and says so.
fb_cmd({"stop": True})
time.sleep(0.3)
stopped = [o for o in FB_OUT if "stopped" in o][0]
assert stopped["listeners"] == 0 and stopped["routes"] == 0, stopped
ticks(80)
assert "no Firebot or bridge found" in G.__status(), G.__status()

G.PluginShutdown()
print("\nFIREBOT TESTS PASSED")
