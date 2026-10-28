"""End-to-end test for the gipityChat plugin.

Runs plugin/ai-chat/*.lua in Lua 5.4 (via lupa) against test/stubs.lua (a stand-in
for the RS3 Client API) and a mock AI provider that speaks both the Anthropic and
OpenAI formats. Needs: pip install lupa
"""

import http.server
import json
import os
import threading
import time
import urllib.error
import urllib.request

import lupa.lua54 as lupa

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PLUGIN = os.path.join(ROOT, "plugin", "gipity-chat")
MOCK_PORT, CLOSED_PORT = 18901, 18902
CALLS = []  # (base, path, headers, body)

LONG = ("**Sure!** For the Kalphite Queen — bring a `Dramen staff`, prayer potions and food. "
        "Café tip \U0001F389 <img=1> stay at range. " + "Keep your prayers flicked. " * 12)


class Provider(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass

    def reply(self, code, obj):
        data = json.dumps(obj).encode()
        self.send_response(code); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data)

    def do_POST(self):
        base, path = self.path.split("/", 2)[1], "/" + self.path.split("/", 2)[2]
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        headers = {k.lower(): v for k, v in self.headers.items()}
        CALLS.append((base, path, headers, body))
        last = body["messages"][-1]["content"]
        if base == "anthropic":
            if headers.get("x-api-key") != "sk-ant-good-0001":
                return self.reply(401, {"type": "error", "error": {"type": "authentication_error", "message": "invalid x-api-key"}})
            text = LONG if "kalphite" in last.lower() else f"You said: {last}"
            return self.reply(200, {"content": [{"type": "text", "text": text}], "stop_reason": "end_turn"})
        if headers.get("authorization") != "Bearer sk-openai-good":
            return self.reply(401, {"error": {"message": "Incorrect API key provided"}})
        if body["model"] == "missing-model":
            return self.reply(404, {"error": {"message": "The model `missing-model` does not exist"}})
        return self.reply(200, {"choices": [{"message": {"role": "assistant", "content": f"OpenAI-style: {last}"}}]})


threading.Thread(target=http.server.HTTPServer(("127.0.0.1", MOCK_PORT), Provider).serve_forever, daemon=True).start()


def py_http(method, base, path, body, headers):
    # Every provider goes to the mock (prefixed with its name), except Ollama: nothing is listening.
    port = CLOSED_PORT if base == "ollama" else MOCK_PORT
    req = urllib.request.Request(f"http://127.0.0.1:{port}/{base}{path}", data=body.encode("latin-1") if isinstance(body, str) else body,
                                 method=method, headers=dict(headers.items()))
    try:
        with urllib.request.urlopen(req, timeout=5) as r:
            return True, r.status, r.read().decode()
    except urllib.error.HTTPError as e:
        return True, e.code, e.read().decode()
    except Exception as e:  # noqa: BLE001
        return False, 0, str(e)


def new_runtime(perms=(True, True)):
    L = lupa.LuaRuntime(unpack_returned_tuples=True, encoding=None)  # keep Lua strings as bytes
    G = L.globals()
    G.PLUGIN_DIR = PLUGIN.encode()
    def lua_http(m, b, p, body, h):
        ok, code, data = py_http(m.decode(), b.decode(), p.decode(), body, {k.decode(): v.decode() for k, v in h.items()})
        return ok, code, data.encode("utf-8")  # hand Lua bytes, like the client does

    G.py_http = lua_http
    L.execute(open(os.path.join(ROOT, "test", "stubs.lua"), "rb").read())
    G.__perms[1], G.__perms[2] = perms[0], perms[1]
    L.execute(b"PLUGIN_MAIN = assert(load(assert(io.open(PLUGIN_DIR .. '/main.lua')):read('a'), '=main'))")
    L.execute(b"PLUGIN_MAIN()")
    return L, G


def chatlog(G):
    return [G.__chatlog[i].decode("latin-1") for i in range(1, len(G.__chatlog) + 1)]


def joined(G):
    """The chat log with colour tags removed and wrapped lines joined back up."""
    s = " ".join(chatlog(G))
    for tag in ("<col=d97757>", "<col=a0a0a0>", "<col=ff7070>", "<col=ffffff>", "</col>"):
        s = s.replace(tag, "")
    return s


def ticks(G, n=20):
    for _ in range(n):
        G.__tick(); time.sleep(0.005)


def say(G, text, sender="Adi Rs", chat_type=2):
    G.__chat(chat_type, sender.encode(), text.encode("latin-1") if isinstance(text, str) else text)


# --- JSON module unit checks -------------------------------------------------
L, G = new_runtime()
L.execute(b"""
local json = require("json")
local v = assert(json.decode('{"a":[1,2.5,"x\\\\u00e9\\\\ud83c\\\\udf89\\\\n",true,null,{}],"b":"q\\\\"uote"}'))
assert(v.a[1] == 1 and v.a[2] == 2.5 and v.a[3] == "x\\195\\169\\240\\159\\142\\137\\n" and v.a[4] == true and v.a[5] == nil)
assert(v.b == 'q"uote')
assert(json.encode({b = "x\\"y\\n", a = {1, 2}}) == '{"a":[1,2],"b":"x\\\\"y\\\\n"}')
assert(json.encode("caf\\233") == '"caf\\\\u00e9"', json.encode("caf\\233"))   -- Latin-1 byte -> \\u00e9
assert(json.encode("caf\\195\\169") == '"caf\\195\\169"')                     -- valid UTF-8 passes through
assert(json.decode("{bad") == nil)
local text = require("text")
assert(text.toGameText("A \\226\\128\\148 caf\\195\\169 \\240\\159\\142\\137 \\226\\128\\156hi\\226\\128\\157") == 'A - cafe "hi"')
assert(text.forDisplay("**bold** `x` <img=1>") == "bold x <lt>img=1<gt>")
""")

# --- First run: no key ---------------------------------------------------------
log = chatlog(G)
assert any("Welcome! Paste your Claude API key" in l for l in log), log
assert G.__setupOpen(), "key box opens on first run"
assert "console.anthropic.com" in G.__setupText().decode()
G.__pressButton(b"Cancel")
assert not G.__setupOpen()

# Asking without a key reopens the box.
say(G, "!c hello"); ticks(G, 5)
assert G.__setupOpen() and any("No Claude API key yet" in l for l in chatlog(G))

# A wrong key is reported plainly.
G.__pasteKey(b"  sk-ant-bad \n")
assert not G.__setupOpen() and G.__db[b"key.claude"] == b"sk-ant-bad"
say(G, "!c hello again"); ticks(G, 10)
assert "HTTP 401: the API key was rejected - set it again with !c /setup (invalid x-api-key)" in joined(G), chatlog(G)[-3:]

# Typing a key in chat: warned, NOT saved, box opens instead.
say(G, "!c /key sk-ant-leaked"); ticks(G, 3)
assert G.__db[b"key.claude"] == b"sk-ant-bad", "keys typed in chat are never saved"
assert any("Don't type keys in chat" in l for l in chatlog(G)) and G.__setupOpen()
G.__pasteKey(b"sk-ant-good-0001")
assert any("Claude key saved (sk-ant-...0001)." in l for l in chatlog(G)), chatlog(G)[-2:]

# --- Asking -----------------------------------------------------------------------
n_calls = len(CALLS)
say(G, "!c how do I kill the Kalphite Queen?"); ticks(G, 10)
base, path, headers, body = CALLS[-1]
assert (base, path) == ("anthropic", "/v1/messages")
assert headers["anthropic-version"] == "2023-06-01" and body["model"] == "claude-haiku-5-5" and body["max_tokens"] == 400
assert "RuneScape 3" in body["system"] and body["messages"] == [{"role": "user", "content": "how do I kill the Kalphite Queen?"}]
replies = chatlog(G)[-6:]
first = [l for l in replies if "Claude:</col>" in l]
assert first and first[0].startswith("<col=d97757>Claude:</col> Sure! For the Kalphite Queen - bring a Dramen staff"), replies
whole = " ".join(chatlog(G)[-6:])
assert "Cafe tip <lt>img=1<gt> stay at range" in whole, whole  # accents folded, emoji dropped, markup escaped
assert "**" not in whole and "`" not in whole
assert len([l for l in chatlog(G) if "prayers flicked" in l]) >= 2, "long replies are split over several lines"

# Context: the second question carries the first exchange.
say(G, "!ai and after that?"); ticks(G, 10)
msgs = CALLS[-1][3]["messages"]
assert [m["role"] for m in msgs] == ["user", "assistant", "user"] and msgs[-1]["content"] == "and after that?"
assert any("You said: and after that?" in l for l in chatlog(G))

# Triggers: !chat, upper case, friends chat; not other players, not plugin lines, not plain chat.
n = len(CALLS)
say(G, "!CHAT friends chat question", chat_type=9)
say(G, "!c spoofed", sender="Someone Else")
say(G, "just chatting")
say(G, "!clan stuff")  # not a trigger word
G.__chat(33, b"", b"!c from a plugin line")
ticks(G, 15)
asked = [c[3]["messages"][-1]["content"] for c in CALLS[n:]]
assert asked == ["friends chat question"], asked

# Latin-1 bytes from the client become valid JSON.
say(G, b"!c caf\xe9?"); ticks(G, 10)
assert CALLS[-1][3]["messages"][-1]["content"] == "café?"

# --- Other providers ------------------------------------------------------------
say(G, "!c /provider gpt"); ticks(G, 3)
assert any("Now using OpenAI (gpt-5.4-mini)" in l for l in chatlog(G)) and G.__setupOpen()
G.__pasteKey(b"sk-openai-good")
say(G, "!c hi openai"); ticks(G, 10)
base, path, headers, body = CALLS[-1]
assert (base, path) == ("openai", "/v1/chat/completions") and headers["authorization"] == "Bearer sk-openai-good"
assert body["messages"][0]["role"] == "system" and body["model"] == "gpt-5.4-mini" and "max_tokens" not in body
assert any("<col=d97757>OpenAI:</col> OpenAI-style: hi openai" in l for l in chatlog(G))

say(G, "!c /model missing-model"); say(G, "!c test"); ticks(G, 10)
assert "HTTP 404: model not found - set a valid one with !c /model" in joined(G), chatlog(G)[-2:]

say(G, "!c /provider gemini"); ticks(G, 3)
G.__pasteKey(b"sk-openai-good")  # the mock accepts this key for every OpenAI-style provider
say(G, "!c gemini test"); ticks(G, 10)
assert CALLS[-1][:2] == ("gemini", "/v1beta/openai/chat/completions") and CALLS[-1][3]["model"] == "gemini-flash-latest"

say(G, "!c /provider ollama"); ticks(G, 3)
assert not G.__setupOpen(), "local providers need no key"
say(G, "!c local question"); ticks(G, 5)
assert any("Choose a Ollama model first" in l for l in chatlog(G)), chatlog(G)[-2:]
say(G, "!c /model llama3.2"); say(G, "!c local question"); ticks(G, 10)
assert any("couldn't reach Ollama - is it running on this PC?" in l for l in chatlog(G)), chatlog(G)[-2:]

say(G, "!c /provider nope"); ticks(G, 3)
assert any("Unknown provider 'nope'" in l for l in chatlog(G))
say(G, "!c /provider"); ticks(G, 3)
assert "Providers: claude (key saved), openai (key saved), gemini (key saved)" in joined(G), chatlog(G)[-2:]

# --- Housekeeping commands --------------------------------------------------------
say(G, "!c /provider claude"); say(G, "!c /new"); say(G, "!c fresh start"); ticks(G, 10)
assert CALLS[-1][3]["messages"] == [{"role": "user", "content": "fresh start"}]
say(G, "!c"); ticks(G, 3)
assert any("Ask: !c QUESTION" in l for l in chatlog(G)), "bare trigger shows help"
say(G, "!c /forget"); ticks(G, 3)
assert G.__db[b"key.claude"] == b"" and any("Claude key removed" in l for l in chatlog(G))
say(G, "!c /wat"); ticks(G, 3)
assert any("Unknown command /wat" in l for l in chatlog(G))

# Every line the plugin writes is a single chat line of sensible length.
for line in chatlog(G):
    visible = line.replace("<lt>", "<").replace("<gt>", ">")
    for tag in ("<col=d97757>", "<col=a0a0a0>", "<col=ff7070>", "<col=ffffff>", "</col>"):
        visible = visible.replace(tag, "")
    assert len(visible) <= 200, (len(visible), line)

# Shutdown removes every subscription and closes the box.
say(G, "!c /setup"); ticks(G, 2)
assert G.__setupOpen()
G.PluginShutdown()
assert G.__subs() == 0 and not G.__setupOpen()

# --- Without chatAccess the plugin stays quiet and subscribes to nothing but Logic ---
L2, G2 = new_runtime(perms=(True, False))
assert len(G2.__chatlog) == 0 and G2.__subs() == 1
G2.PluginShutdown()
assert G2.__subs() == 0

print("ALL PLUGIN TESTS PASSED")
