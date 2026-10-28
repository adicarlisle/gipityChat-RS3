#!/usr/bin/env python3
"""
RS3 Twitch + Claude chat bridge.

The RuneScape 3 Client Plugin API only lets a plugin make plain HTTP GET/POST
requests to base URLs declared in its plugin.json - no WebSockets, no raw
sockets. Twitch chat is a persistent IRC connection and the Claude API needs a
secret API key, neither of which belong inside a plugin. So this small local
program does the long-lived / secret parts and exposes a tiny HTTP API on
127.0.0.1 that the plugin polls.

    Twitch IRC  ──►┐
                   ├──► bridge (127.0.0.1:8787) ◄──poll/POST── RS3 plugin
    Claude API ◄──►┘

Standard library only (Python 3.9+). Run:

    export ANTHROPIC_API_KEY=sk-ant-...
    python bridge.py --channel yourtwitchname

Optional, to send messages *to* Twitch chat from inside RS3 (/t hello):

    export TWITCH_OAUTH=xxxxxxxx      # token with chat:read + chat:edit ("oauth:" prefix optional)
    python bridge.py --channel yourtwitchname

Protocol (all text/plain, UTF-8, tab-separated so the Lua side needs no JSON):

  GET  /poll?since=<id>
       line 1:  OK <TAB> lastId <TAB> twitchState <TAB> claudeState
       then  :  id <TAB> kind <TAB> name <TAB> rrggbb <TAB> text
       kind is one of twitch | claude | you | system. One line per message
       (the plugin wraps to its window width). With --wrap N, messages are
       pre-wrapped and continuation lines have an empty name.
  POST /claude    body = prompt  ("/clear" resets the conversation)
  POST /twitch    body = message to send to Twitch chat (needs TWITCH_OAUTH)
  GET  /health

Every request must carry the header "X-RS3-Bridge: 1" and must NOT carry an
Origin header. Browsers can't add custom headers cross-site without a CORS
preflight (which we never answer), so a random web page can't drive the
bridge and spend your API credits.
"""

from __future__ import annotations

import argparse
import collections
import dataclasses
import json
import os
import queue
import random
import re
import socket
import ssl
import sys
import textwrap
import threading
import time
import unicodedata
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

# ---------------------------------------------------------------------------
# Shared message store
# ---------------------------------------------------------------------------

COLOURS = {
    "claude": "d97757",  # Claude orange
    "you": "7fd1ff",
    "system": "a0a0a0",
    "twitch_default": "b9a3e3",  # Twitch purple, for users with no colour set
}


def to_display_charset(text: str, charset: str) -> str:
    """Make text safe for the game's font renderer.

    'ascii' (default) folds accents (é -> e) and drops anything else, such as
    emoji, which RS fonts can't draw. 'utf8' passes text through untouched.
    """
    text = re.sub(r"[\x00-\x1f\x7f]", " ", text)  # tabs/newlines break the protocol
    if charset == "utf8":
        return text
    for fancy, plain in {"\u2014": " - ", "\u2013": "-", "\u2018": "'", "\u2019": "'",
                         "\u201c": '"', "\u201d": '"', "\u2026": "...", "\u00a0": " "}.items():
        text = text.replace(fancy, plain)
    folded = unicodedata.normalize("NFKD", text)
    return re.sub(r"  +", " ", folded.encode("ascii", "ignore").decode("ascii"))


def escape_rs_markup(text: str) -> str:
    """RS text supports tags like <col=ff0000> and <img=1>. Escape user text so
    chatters can't inject them."""
    return re.sub(r"[<>]", lambda m: "<lt>" if m.group() == "<" else "<gt>", text)


class Store:
    def __init__(self, wrap: int, charset: str, backlog: int = 60, maxlen: int = 1000):
        self.lock = threading.Lock()
        self.lines: collections.deque = collections.deque(maxlen=maxlen)
        self.next_id = 1
        self.wrap = wrap
        self.charset = charset
        self.backlog = backlog
        self.twitch_state = "off"
        self.claude_state = "idle"
        # Recent raw Twitch chat, handed to Claude as context.
        self.twitch_recent: collections.deque = collections.deque(maxlen=40)
        self.last_poll = 0.0  # when the plugin last polled (for the GUI's status)

    def add(self, kind: str, name: str, colour: str, text: str) -> None:
        name = escape_rs_markup(to_display_charset(name, self.charset))
        clean = to_display_charset(text, self.charset).strip() or " "
        if self.wrap <= 0:
            out = [clean]  # default: whole message; the plugin wraps it to the window width
        else:
            # Optional fixed-width wrapping. First line is shorter to leave room for "name: ".
            first_width = max(12, self.wrap - len(name) - 2)
            wrapped = textwrap.wrap(clean, width=first_width, break_long_words=True) or [" "]
            head, rest = wrapped[0], " ".join(wrapped[1:])
            out = [head] + (textwrap.wrap(rest, width=self.wrap, break_long_words=True) if rest else [])
        colour = (colour or "ffffff").lstrip("#").lower()[:6]
        with self.lock:
            for i, line in enumerate(out):
                self.lines.append((self.next_id, kind, name if i == 0 else "", colour, escape_rs_markup(line)))
                self.next_id += 1

    def rows_since(self, since: int) -> list[tuple]:
        """Raw (id, kind, name, colour, text) rows newer than `since`, for the GUI."""
        with self.lock:
            return [r for r in self.lines if r[0] > since]

    def since(self, since: int) -> str:
        self.last_poll = time.time()
        with self.lock:
            if since <= 0:
                rows = list(self.lines)[-self.backlog :]
            else:
                rows = [r for r in self.lines if r[0] > since]
            last = self.next_id - 1
            header = f"OK\t{last}\t{self.twitch_state}\t{self.claude_state}"
        body = [header] + ["\t".join(str(c) for c in r) for r in rows]
        return "\n".join(body) + "\n"


# ---------------------------------------------------------------------------
# Twitch IRC (read anonymously; optionally authenticated to send)
# ---------------------------------------------------------------------------


def normalise_token(raw: str | None) -> str | None:
    """Accepts a token pasted in any of the usual shapes and returns "oauth:<token>".

    Handles: abc123, oauth:abc123, "oauth:abc123" (with quotes), Bearer abc123,
    or the whole redirect URL / fragment (...#access_token=abc123&scope=...).
    """
    if not raw:
        return None
    tok = raw.strip().strip("'\"").strip()
    m = re.search(r"access_token=([^&\s]+)", tok)
    if m:
        tok = m.group(1)
    tok = re.sub(r"^(oauth:|bearer\s+)", "", tok, flags=re.I).strip()
    return f"oauth:{tok}" if tok else None


def validate_token(token: str, url: str) -> dict | None:
    """Asks Twitch who this token belongs to. Returns the JSON ({"login", "scopes",
    "expires_in", ...}), {} if Twitch says it's invalid, or None if we couldn't check."""
    req = urllib.request.Request(url, headers={"Authorization": "OAuth " + token.split(":", 1)[1]})
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            return json.loads(resp.read())
    except urllib.error.HTTPError as err:
        return {} if err.code == 401 else None
    except Exception:  # noqa: BLE001 - offline etc.: don't block startup
        return None


class Twitch(threading.Thread):
    def __init__(self, store: Store, channel: str, host: str, port: int, use_tls: bool,
                 nick: str | None, oauth: str | None):
        super().__init__(daemon=True)
        self.store = store
        self.channel = channel.lower().lstrip("#")
        self.host, self.port, self.use_tls = host, port, use_tls
        self.nick = (nick or "").lower() or None
        self.oauth = oauth
        self.sock: socket.socket | None = None
        self.send_lock = threading.Lock()
        self._stop = threading.Event()

    def stop(self) -> None:
        self._stop.set()
        sock = self.sock
        if sock:
            try:
                sock.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            sock.close()
        self.store.twitch_state = "off"

    @property
    def can_send(self) -> bool:
        return bool(self.nick and self.oauth)

    def _send(self, line: str) -> None:
        with self.send_lock:
            if self.sock:
                self.sock.sendall((line + "\r\n").encode("utf-8"))

    def say(self, text: str) -> bool:
        if not self.can_send or self.store.twitch_state != "connected":
            return False
        text = re.sub(r"[\r\n]", " ", text).strip()[:450]
        if not text:
            return False
        self._send(f"PRIVMSG #{self.channel} :{text}")
        # Twitch doesn't echo your own messages back, so show it locally.
        self.store.add("twitch", self.nick, COLOURS["you"], text)
        self.store.twitch_recent.append(f"{self.nick}: {text}")
        return True

    def run(self) -> None:
        backoff = 2
        while not self._stop.is_set():
            try:
                self.store.twitch_state = "connecting"
                self._session()
                backoff = 2
            except Exception as exc:  # noqa: BLE001 - reconnect on anything
                if self._stop.is_set():
                    break
                self.store.add("system", "bridge", COLOURS["system"], f"Twitch disconnected ({exc}); retrying in {backoff}s")
            self.sock = None
            if self._stop.wait(backoff):
                break
            self.store.twitch_state = "connecting"
            backoff = min(backoff * 2, 60)
        self.store.twitch_state = "off"

    def _session(self) -> None:
        raw = socket.create_connection((self.host, self.port), timeout=360)
        if self.use_tls:
            raw = ssl.create_default_context().wrap_socket(raw, server_hostname=self.host)
        self.sock = raw
        self._send("CAP REQ :twitch.tv/tags twitch.tv/commands")
        if self.can_send:
            self._send(f"PASS {self.oauth}")
            self._send(f"NICK {self.nick}")
        else:  # anonymous read-only login, no account needed
            self._send("PASS SCHMOOPIIE")
            self._send(f"NICK justinfan{random.randint(10000, 99999)}")
        self._send(f"JOIN #{self.channel}")

        buf = b""
        while True:
            data = raw.recv(4096)
            if not data:
                raise ConnectionError("server closed connection")
            buf += data
            while b"\r\n" in buf:
                line, buf = buf.split(b"\r\n", 1)
                self._on_line(line.decode("utf-8", "replace"))

    def _on_line(self, line: str) -> None:
        tags: dict[str, str] = {}
        if line.startswith("@"):
            tag_str, line = line[1:].split(" ", 1)
            for kv in tag_str.split(";"):
                k, _, v = kv.partition("=")
                tags[k] = v.replace("\\s", " ")
        if line.startswith("PING"):
            self._send("PONG" + line[4:])
            return
        parts = line.split(" ", 3)
        if len(parts) < 2:
            return
        prefix, command = parts[0], parts[1]
        if command == "JOIN" and self.store.twitch_state != "connected":
            self.store.twitch_state = "connected"
            self.store.add("system", "bridge", COLOURS["system"], f"Connected to twitch.tv/{self.channel}")
        elif command == "NOTICE" and len(parts) == 4:
            notice = parts[3].lstrip(":")
            if self.oauth and ("authentication failed" in notice.lower() or "improperly formatted auth" in notice.lower()):
                self.oauth = None  # stop retrying a bad token; read-only from now on
                self.store.add("system", "bridge", COLOURS["system"],
                               f"Twitch rejected the token ({notice}). Reading chat anonymously; /t is off. Get a new token and restart the bridge.")
                raise ConnectionError("bad Twitch token")
            self.store.add("system", "twitch", COLOURS["system"], notice)
        elif command == "RECONNECT":
            raise ConnectionError("Twitch asked us to reconnect")
        elif command == "CLEARCHAT":
            pass  # bans/timeouts: could hide that user's lines; left simple
        elif command == "PRIVMSG" and len(parts) == 4:
            login = prefix.lstrip(":").split("!", 1)[0]
            name = tags.get("display-name") or login
            text = parts[3][1:] if parts[3].startswith(":") else parts[3]
            if text.startswith("\x01ACTION ") and text.endswith("\x01"):  # /me
                text = "* " + text[8:-1]
            colour = tags.get("color") or "#" + COLOURS["twitch_default"]
            self.store.add("twitch", name, colour, text)
            self.store.twitch_recent.append(f"{name}: {text}")


# ---------------------------------------------------------------------------
# Claude
# ---------------------------------------------------------------------------

SYSTEM_PROMPT = """You are Claude, chatting with a RuneScape 3 player through a small chat window inside the game client while they play (and possibly stream on Twitch).

Keep replies short: usually 1-3 sentences, never more than about 80 words, because they are shown in a narrow in-game chat box. Plain text only - no markdown, no bullet points, no headings, no code blocks, no emoji.

Be helpful with RuneScape 3 questions (skilling, bossing, quests, money making, mechanics), but say so when you're unsure, since game details change with updates and you can't look things up. You can't see the game or take any action in it."""


def strip_markdown(text: str) -> str:
    text = re.sub(r"```.*?```", " ", text, flags=re.S)
    text = re.sub(r"`([^`]*)`", r"\1", text)
    text = re.sub(r"\*\*([^*]+)\*\*", r"\1", text)
    text = re.sub(r"(?m)^\s*#+\s*", "", text)
    text = re.sub(r"(?m)^\s*[-*]\s+", "- ", text)
    return re.sub(r"\s+", " ", text).strip()


class Claude(threading.Thread):
    def __init__(self, store: Store, api_key: str | None, model: str, url: str, max_turns: int = 20):
        super().__init__(daemon=True)
        self.store = store
        self.api_key = api_key
        self.model = model
        self.url = url
        self.max_turns = max_turns
        self.history: list[dict] = []
        self.jobs: queue.Queue = queue.Queue()  # prompts; None means stop
        store.claude_state = "idle" if api_key else "nokey"

    def stop(self) -> None:
        self.jobs.put(None)

    def ask(self, prompt: str) -> None:
        prompt = prompt.strip()
        if not prompt:
            return
        if prompt.lower() in ("/clear", "/reset", "/new"):
            self.history.clear()
            self.store.add("system", "claude", COLOURS["system"], "Conversation cleared.")
            return
        self.store.add("you", "You", COLOURS["you"], prompt)
        if not self.api_key:
            self.store.add("system", "bridge", COLOURS["system"], "No Anthropic API key set on the bridge, so Claude can't answer.")
            return
        self.jobs.put(prompt)

    def run(self) -> None:
        while True:
            prompt = self.jobs.get()
            if prompt is None:
                return
            self.store.claude_state = "thinking"
            try:
                reply = self._call(prompt)
                self.store.add("claude", "Claude", COLOURS["claude"], reply)
            except Exception as exc:  # noqa: BLE001
                self.store.add("system", "claude", COLOURS["system"], f"Claude error: {exc}")
            finally:
                self.store.claude_state = "idle" if self.jobs.empty() else "thinking"

    def _call(self, prompt: str) -> str:
        system = SYSTEM_PROMPT
        recent = list(self.store.twitch_recent)
        if recent:
            system += "\n\nRecent Twitch chat on the player's stream (oldest first), for context if they ask about it:\n" + "\n".join(recent[-25:])
        messages = self.history + [{"role": "user", "content": prompt}]
        body = json.dumps({"model": self.model, "max_tokens": 400, "system": system, "messages": messages}).encode()
        req = urllib.request.Request(self.url, data=body, method="POST", headers={
            "content-type": "application/json",
            "x-api-key": self.api_key or "",
            "anthropic-version": "2023-06-01",
        })
        try:
            with urllib.request.urlopen(req, timeout=90) as resp:
                data = json.loads(resp.read())
        except urllib.error.HTTPError as err:
            detail = err.read().decode("utf-8", "replace")
            try:
                detail = json.loads(detail)["error"]["message"]
            except Exception:  # noqa: BLE001
                pass
            raise RuntimeError(f"HTTP {err.code}: {detail}") from None
        text = "".join(b.get("text", "") for b in data.get("content", []) if b.get("type") == "text")
        text = strip_markdown(text) or "(no reply)"
        self.history = (messages + [{"role": "assistant", "content": text}])[-self.max_turns * 2 :]
        return text


# ---------------------------------------------------------------------------
# HTTP API for the plugin
# ---------------------------------------------------------------------------


def make_handler(bridge: "Bridge"):
    store = bridge.store

    class Handler(BaseHTTPRequestHandler):
        server_version = "rs3-bridge/1.0"

        def log_message(self, fmt, *args):  # quiet: the plugin polls twice a second
            pass

        def _reply(self, code: int, text: str) -> None:
            data = text.encode("utf-8")
            self.send_response(code)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(data)

        def _allowed(self) -> bool:
            if self.headers.get("Origin") is not None or self.headers.get("X-RS3-Bridge") != "1":
                self._reply(403, "forbidden\n")
                return False
            return True

        def _body(self) -> str:
            n = min(int(self.headers.get("Content-Length") or 0), 8000)
            return self.rfile.read(n).decode("utf-8", "replace") if n else ""

        def do_GET(self):  # noqa: N802
            if not self._allowed():
                return
            url = urlparse(self.path)
            if url.path == "/poll":
                try:
                    since = int(parse_qs(url.query).get("since", ["0"])[0])
                except ValueError:
                    since = 0
                self._reply(200, store.since(since))
            elif url.path == "/health":
                self._reply(200, "OK\n")
            else:
                self._reply(404, "not found\n")

        def do_POST(self):  # noqa: N802
            if not self._allowed():
                return
            path = urlparse(self.path).path
            text = self._body()
            if path == "/claude":
                bridge.ask_claude(text)
                self._reply(200, "OK\n")
            elif path == "/twitch":
                twitch = bridge.twitch
                if twitch is None or not twitch.can_send:
                    store.add("system", "bridge", COLOURS["system"], "Sending to Twitch needs a valid TWITCH_OAUTH token on the bridge.")
                    self._reply(200, "ERR\n")
                elif not twitch.say(text):
                    store.add("system", "bridge", COLOURS["system"], "Not connected to Twitch yet.")
                    self._reply(200, "ERR\n")
                else:
                    self._reply(200, "OK\n")
            else:
                self._reply(404, "not found\n")

        def do_OPTIONS(self):  # noqa: N802 - never grant CORS
            self._reply(403, "forbidden\n")

    return Handler


DEFAULT_MODEL = "claude-haiku-5-5"
MODELS = ["claude-haiku-5-5", "claude-sonnet-5-5", "claude-opus-5-5"]


@dataclasses.dataclass
class Config:
    channel: str = ""
    twitch_token: str = ""
    twitch_nick: str = ""
    anthropic_key: str = ""
    model: str = DEFAULT_MODEL
    port: int = 8787
    wrap: int = 0
    charset: str = "ascii"
    # Endpoints (overridable for testing)
    anthropic_url: str = "https://api.anthropic.com/v1/messages"
    twitch_host: str = "irc.chat.twitch.tv"
    twitch_port: int = 6697
    twitch_tls: bool = True
    twitch_validate_url: str = "https://id.twitch.tv/oauth2/validate"


class Bridge:
    """Owns the HTTP server, the Twitch connection and the Claude worker.
    Used by both the command line (main) and the desktop app (bridge_gui.py)."""

    def __init__(self, cfg: Config):
        self.cfg = cfg
        self.store = Store(wrap=cfg.wrap, charset=cfg.charset)
        self.server: ThreadingHTTPServer | None = None
        self.claude: Claude | None = None
        self.twitch: Twitch | None = None

    @property
    def running(self) -> bool:
        return self.server is not None

    def log(self, text: str) -> None:
        self.store.add("system", "bridge", COLOURS["system"], text)

    def start(self) -> None:
        """Starts everything. Raises OSError if the port is already in use."""
        if self.running:
            return
        cfg, store = self.cfg, self.store
        store.wrap, store.charset = cfg.wrap, cfg.charset
        # Bind first, so a busy port fails before anything else starts.
        server = ThreadingHTTPServer(("127.0.0.1", cfg.port), make_handler(self))
        server.daemon_threads = True

        self.claude = Claude(store, cfg.anthropic_key.strip() or None, cfg.model.strip() or DEFAULT_MODEL, cfg.anthropic_url)
        self.claude.start()
        if not cfg.anthropic_key.strip():
            self.log("No Anthropic API key set; Claude replies are off.")

        channel = cfg.channel.strip().lstrip("#")
        if channel:
            token, nick = normalise_token(cfg.twitch_token), cfg.twitch_nick.strip() or None
            if token:
                info = validate_token(token, cfg.twitch_validate_url)
                if info == {}:
                    self.log("Twitch rejected the token (wrong or expired). Reading chat anonymously; /t is off.")
                    token = None
                elif info:
                    nick = nick or info.get("login")
                    days = int(info.get("expires_in") or 0) // 86400
                    note = f"Twitch token OK for {info.get('login')}" + (f", expires in ~{days} days" if days else "")
                    if "chat:edit" not in (info.get("scopes") or []):
                        note += ". It lacks chat:edit, so /t won't work; make a new token with chat:read+chat:edit"
                    self.log(note + ".")
                nick = nick or channel  # couldn't check: assume you're sending as the channel owner
            self.twitch = Twitch(store, channel, cfg.twitch_host, cfg.twitch_port, cfg.twitch_tls, nick, token)
            self.twitch.start()
        else:
            self.log("No Twitch channel set; Claude only.")

        self.server = server
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.log(f"Bridge started on http://127.0.0.1:{cfg.port}")

    def stop(self) -> None:
        if self.server:
            self.server.shutdown()
            self.server.server_close()
            self.server = None
        if self.twitch:
            self.twitch.stop()
            self.twitch = None
        if self.claude:
            self.claude.stop()
            self.claude = None
        self.store.claude_state = "idle"
        self.log("Bridge stopped.")

    def ask_claude(self, text: str) -> None:
        if self.claude:
            self.claude.ask(text)

    def say_twitch(self, text: str) -> bool:
        if not self.twitch or not self.twitch.can_send:
            self.log("Sending to Twitch needs a valid Twitch token with chat:edit.")
            return False
        if not self.twitch.say(text):
            self.log("Not connected to Twitch yet.")
            return False
        return True


def main(argv: list[str] | None = None) -> None:
    p = argparse.ArgumentParser(description="Local bridge between Twitch chat, Claude and the RS3 chat plugin. Run bridge_gui.py for the desktop app.")
    p.add_argument("--channel", default=os.environ.get("TWITCH_CHANNEL", ""), help="Twitch channel to read (e.g. yourname). Omit to run Claude only.")
    p.add_argument("--twitch-nick", default=os.environ.get("TWITCH_NICK", ""), help="Optional: your Twitch login. Normally worked out from TWITCH_OAUTH automatically")
    p.add_argument("--port", type=int, default=8787, help="Must match the URL in the plugin's plugin.json (default 8787)")
    p.add_argument("--model", default=os.environ.get("CLAUDE_MODEL", DEFAULT_MODEL), help=f"Claude model ID (default {DEFAULT_MODEL} for quick replies)")
    p.add_argument("--wrap", type=int, default=0, help="Pre-wrap messages to this many characters (default 0: the plugin wraps to the window width)")
    p.add_argument("--charset", choices=["ascii", "utf8"], default="ascii", help="ascii folds accents and drops emoji the game can't draw")
    p.add_argument("--anthropic-url", default=Config.anthropic_url, help=argparse.SUPPRESS)
    p.add_argument("--twitch-host", default=Config.twitch_host, help=argparse.SUPPRESS)
    p.add_argument("--twitch-port", type=int, default=Config.twitch_port, help=argparse.SUPPRESS)
    p.add_argument("--no-tls", action="store_true", help=argparse.SUPPRESS)
    p.add_argument("--twitch-validate-url", default=Config.twitch_validate_url, help=argparse.SUPPRESS)
    args = p.parse_args(argv)

    cfg = Config(
        channel=args.channel, twitch_token=os.environ.get("TWITCH_OAUTH", ""), twitch_nick=args.twitch_nick,
        anthropic_key=os.environ.get("ANTHROPIC_API_KEY", ""), model=args.model, port=args.port,
        wrap=args.wrap, charset=args.charset, anthropic_url=args.anthropic_url, twitch_host=args.twitch_host,
        twitch_port=args.twitch_port, twitch_tls=not args.no_tls, twitch_validate_url=args.twitch_validate_url,
    )
    bridge = Bridge(cfg)
    # Echo bridge/system messages to the terminal.
    seen = 0
    try:
        bridge.start()
    except OSError as exc:
        sys.exit(f"Couldn't listen on 127.0.0.1:{cfg.port} ({exc}). Is another bridge already running?")
    print(f"RS3 bridge on http://127.0.0.1:{cfg.port}  channel={cfg.channel or '-'}  model={cfg.model}", flush=True)
    try:
        while True:
            for row in bridge.store.rows_since(seen):
                seen = row[0]
                if row[1] == "system":
                    print(row[4].replace("<lt>", "<").replace("<gt>", ">"), flush=True)
            time.sleep(0.5)
    except KeyboardInterrupt:
        bridge.stop()
        print("bye", file=sys.stderr)


if __name__ == "__main__":
    main()
