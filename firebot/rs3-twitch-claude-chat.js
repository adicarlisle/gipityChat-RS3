/**
 * RS3 Twitch & Claude Chat - Firebot startup script
 *
 * Lets the "Twitch & Claude Chat" RuneScape 3 plugin use Firebot instead of the
 * separate bridge app. Firebot already holds your Twitch connection; this script
 * adds a few HTTP endpoints to Firebot's local server that the plugin polls:
 *
 *   GET  http://localhost:7472/integrations/rs3chat/poll?since=<id>
 *   POST http://localhost:7472/integrations/rs3chat/claude   (form field "text")
 *   POST http://localhost:7472/integrations/rs3chat/twitch   (form field "text")
 *   GET  http://localhost:7472/integrations/rs3chat/health
 *
 * The response format is the same tab-separated text the bridge uses (see
 * bridge/bridge.py), so the plugin works with either.
 *
 * Install: Firebot > Settings > Scripts > Manage Startup Scripts > Add New Script,
 * pick this file, then enter your Anthropic API key in the script's settings.
 */

"use strict";

const PREFIX = "rs3chat";
const MAX_LINES = 1000;
const BACKLOG = 60;
const MODELS = ["claude-haiku-5-5", "claude-sonnet-5-5", "claude-opus-5-5"];
const COLOURS = { claude: "d97757", you: "7fd1ff", system: "a0a0a0", twitch: "b9a3e3", emote: "ffd166" };
// Tests point this at a mock server; normal installs use Anthropic's API.
const ANTHROPIC_URL = process.env.RS3CHAT_ANTHROPIC_URL || "https://api.anthropic.com/v1/messages";

const SYSTEM_PROMPT = `You are Claude, chatting with a RuneScape 3 player through a small chat window inside the game client while they play (and possibly stream on Twitch).

Keep replies short: usually 1-3 sentences, never more than about 80 words, because they are shown in a narrow in-game chat box. Plain text only - no markdown, no bullet points, no headings, no code blocks, no emoji.

Be helpful with RuneScape 3 questions (skilling, bossing, quests, money making, mechanics), but say so when you're unsure, since game details change with updates and you can't look things up. You can't see the game or take any action in it.`;

// ---------------------------------------------------------------------------
// Text helpers (same rules as bridge.py)
// ---------------------------------------------------------------------------

const FANCY = { "—": " - ", "–": "-", "‘": "'", "’": "'", "“": "\"", "”": "\"", "…": "...", " ": " " };

/** Folds text to plain ASCII the game's fonts can draw; drops emoji and control characters. */
function toAscii(text) {
    let s = String(text ?? "").replace(/[\x00-\x1f\x7f]/g, " ");
    s = s.replace(/[—–‘’“”… ]/g, c => FANCY[c]);
    s = s.normalize("NFKD").replace(/[^\x20-\x7e]/g, "");
    return s.replace(/ {2,}/g, " ");
}

/** Escapes RS text markup (<col=..>, <img=..>) so chatters can't inject it. */
function escapeMarkup(text) {
    return text.replace(/[<>]/g, c => (c === "<" ? "<lt>" : "<gt>"));
}

function clean(text) {
    return escapeMarkup(toAscii(text));
}

function stripMarkdown(text) {
    return text
        .replace(/```[\s\S]*?```/g, " ")
        .replace(/`([^`]*)`/g, "$1")
        .replace(/\*\*([^*]+)\*\*/g, "$1")
        .replace(/^\s*#+\s*/gm, "")
        .replace(/^\s*[-*]\s+/gm, "- ")
        .replace(/\s+/g, " ")
        .trim();
}

function hexColour(c, fallback) {
    const m = /^#?([0-9a-fA-F]{6})$/.exec(String(c ?? ""));
    return m ? m[1].toLowerCase() : fallback;
}

/**
 * Turns a Firebot chat message into display text: emotes highlighted, runs of
 * the same word/emote (3 or more) collapsed to "LUL x5". Also returns a plain
 * version for Claude's context, with emotes marked.
 */
function renderMessage(msg) {
    const tokens = []; // { text (display), plain, key }
    const parts = Array.isArray(msg.parts) && msg.parts.length ? msg.parts : [{ type: "text", text: msg.rawText }];
    for (const p of parts) {
        if (p.type === "emote" || p.type === "third-party-emote") {
            const name = toAscii(p.name ?? p.text ?? "");
            if (name) tokens.push({ text: `<col=${COLOURS.emote}>${escapeMarkup(name)}</col>`, plain: `${name}(emote)`, key: "e:" + name });
        } else if (p.type === "cheermote") {
            const name = toAscii(`${p.name ?? ""}${p.amount ?? ""}`);
            if (name) tokens.push({ text: `<col=${COLOURS.emote}>${escapeMarkup(name)}</col>`, plain: name, key: "c:" + name });
        } else if (p.type === "mention") {
            const name = toAscii("@" + (p.userDisplayName ?? p.username ?? p.text ?? ""));
            tokens.push({ text: escapeMarkup(name), plain: name, key: "m:" + name });
        } else {
            for (const word of toAscii(p.text ?? p.url ?? "").split(/\s+/)) {
                if (word) tokens.push({ text: escapeMarkup(word), plain: word, key: "w:" + word });
            }
        }
    }
    const display = [];
    const plain = [];
    for (let i = 0; i < tokens.length;) {
        let j = i + 1;
        while (j < tokens.length && tokens[j].key === tokens[i].key) j++;
        const run = j - i;
        if (run >= 3) {
            display.push(`${tokens[i].text} x${run}`);
            plain.push(`${tokens[i].plain} x${run}`);
        } else {
            for (let k = i; k < j; k++) {
                display.push(tokens[k].text);
                plain.push(tokens[k].plain);
            }
        }
        i = j;
    }
    let text = display.join(" ");
    let plainText = plain.join(" ");
    if (msg.action) {
        text = "* " + text;
        plainText = "* " + plainText;
    }
    return { text: text || " ", plain: plainText };
}

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

let modules = null;
let firebot = null;
let params = { anthropicApiKey: "", model: MODELS[0], sendAsBot: false };
let lines = []; // [id, kind, name, colour, text]
let nextId = 1;
let twitchRecent = []; // plain "name: text" for Claude's context
let history = []; // Claude conversation
let claudeBusy = 0;
let lastPoll = 0;
let routesRegistered = false;
let eventListener = null;

function log(level, text) {
    if (modules && modules.logger) modules.logger[level](`[RS3 Chat] ${text}`);
}

function add(kind, name, colour, text) {
    lines.push([nextId++, kind, name, colour, text]);
    if (lines.length > MAX_LINES) lines.splice(0, lines.length - MAX_LINES);
}

function addSystem(text) {
    add("system", "firebot", COLOURS.system, clean(text));
}

function remember(nameAndText) {
    twitchRecent.push(nameAndText);
    if (twitchRecent.length > 40) twitchRecent.shift();
}

function twitchState() {
    try {
        return firebot && firebot.accounts && firebot.accounts.streamer && firebot.accounts.streamer.loggedIn
            ? "connected" : "off";
    } catch {
        return "off";
    }
}

function claudeState() {
    if (!params.anthropicApiKey) return "nokey";
    return claudeBusy > 0 ? "thinking" : "idle";
}

// ---------------------------------------------------------------------------
// Chat events from Firebot
// ---------------------------------------------------------------------------

function onEventTriggered({ event, source, meta }) {
    try {
        if (!source || source.id !== "twitch" || !event || event.id !== "chat-message" || !meta) return;
        const msg = meta.chatMessage || { rawText: meta.messageText, userDisplayName: meta.userDisplayName, username: meta.username };
        if (msg.whisper || msg.isAutoModHeld) return; // never show whispers or held messages
        const name = msg.userDisplayName || msg.username || "?";
        const { text, plain } = renderMessage(msg);
        add("twitch", clean(name), hexColour(msg.color, COLOURS.twitch), text);
        remember(`${toAscii(name)}: ${plain}`);
    } catch (err) {
        log("error", `Couldn't handle a chat message: ${err}`);
    }
}

// ---------------------------------------------------------------------------
// Claude
// ---------------------------------------------------------------------------

async function askClaude(prompt) {
    prompt = String(prompt || "").trim();
    if (!prompt) return;
    if (["/clear", "/reset", "/new"].includes(prompt.toLowerCase())) {
        history = [];
        add("system", "claude", COLOURS.system, "Conversation cleared.");
        return;
    }
    add("you", "You", COLOURS.you, clean(prompt));
    if (!params.anthropicApiKey) {
        addSystem("No Anthropic API key set. Add it in Firebot > Settings > Scripts > RS3 Twitch & Claude Chat.");
        return;
    }
    claudeBusy++;
    try {
        let system = SYSTEM_PROMPT;
        if (twitchRecent.length) {
            system += "\n\nRecent Twitch chat on the player's stream (oldest first), for context if they ask about it:\n"
                + twitchRecent.slice(-25).join("\n");
        }
        const messages = history.concat([{ role: "user", content: prompt }]);
        const resp = await fetch(ANTHROPIC_URL, {
            method: "POST",
            headers: {
                "content-type": "application/json",
                "x-api-key": params.anthropicApiKey,
                "anthropic-version": "2023-06-01"
            },
            body: JSON.stringify({ model: params.model || MODELS[0], max_tokens: 400, system, messages }),
            signal: AbortSignal.timeout(90000)
        });
        const data = await resp.json().catch(() => ({}));
        if (!resp.ok) {
            throw new Error(`HTTP ${resp.status}: ${(data.error && data.error.message) || resp.statusText}`);
        }
        const text = stripMarkdown((data.content || []).filter(b => b.type === "text").map(b => b.text).join("")) || "(no reply)";
        history = messages.concat([{ role: "assistant", content: text }]).slice(-40);
        add("claude", "Claude", COLOURS.claude, clean(text));
    } catch (err) {
        add("system", "claude", COLOURS.system, clean(`Claude error: ${err.message || err}`));
    } finally {
        claudeBusy--;
    }
}

// ---------------------------------------------------------------------------
// Sending to Twitch
// ---------------------------------------------------------------------------

async function sendToTwitch(text) {
    text = String(text || "").replace(/[\r\n]+/g, " ").trim().slice(0, 450);
    if (!text) return;
    let ok = false;
    try {
        ok = await modules.twitchApi.chat.sendChatMessage(text, undefined, !!params.sendAsBot);
    } catch (err) {
        log("error", `sendChatMessage failed: ${err}`);
    }
    if (!ok) {
        addSystem("Firebot couldn't send that to Twitch. Is your account connected in Firebot?");
        return;
    }
    // Twitch doesn't echo your own messages back through chat events, so show it here.
    const me = (params.sendAsBot ? firebot.accounts.bot : firebot.accounts.streamer) || {};
    const name = me.displayName || me.username || "You";
    add("twitch", clean(name), COLOURS.you, clean(text));
    remember(`${toAscii(name)}: ${toAscii(text)}`);
}

// ---------------------------------------------------------------------------
// HTTP routes (on Firebot's server: /integrations/rs3chat/...)
// ---------------------------------------------------------------------------

function isLoopback(req) {
    const addr = String((req.socket && req.socket.remoteAddress) || req.ip || "");
    return addr === "127.0.0.1" || addr === "::1" || addr === "::ffff:127.0.0.1";
}

/**
 * Firebot's server listens on your whole network and allows web pages to call it.
 * Only accept the game plugin: from this computer, with our header, and with no
 * Origin header (browsers always send one; the RS3 client doesn't).
 */
function allowed(req, res) {
    if (!isLoopback(req) || req.headers.origin !== undefined || req.headers["x-rs3-bridge"] !== "1") {
        res.status(403).type("text/plain").send("forbidden\n");
        return false;
    }
    return true;
}

function bodyText(req) {
    const b = req.body;
    if (b && typeof b === "object" && typeof b.text === "string") return b.text;
    if (typeof b === "string") return b;
    return "";
}

function pollHandler(req, res) {
    if (!allowed(req, res)) return;
    lastPoll = Date.now();
    const since = parseInt(req.query.since, 10) || 0;
    const rows = since <= 0 ? lines.slice(-BACKLOG) : lines.filter(r => r[0] > since);
    const out = [`OK\t${nextId - 1}\t${twitchState()}\t${claudeState()}`].concat(rows.map(r => r.join("\t")));
    res.status(200).type("text/plain").send(out.join("\n") + "\n");
}

function healthHandler(req, res) {
    if (!allowed(req, res)) return;
    res.status(200).type("text/plain").send("OK firebot\n");
}

function claudeHandler(req, res) {
    if (!allowed(req, res)) return;
    askClaude(bodyText(req)); // runs in the background; the reply arrives via /poll
    res.status(200).type("text/plain").send("OK\n");
}

async function twitchHandler(req, res) {
    if (!allowed(req, res)) return;
    await sendToTwitch(bodyText(req));
    res.status(200).type("text/plain").send("OK\n");
}

const ROUTES = [
    ["poll", "GET", pollHandler],
    ["health", "GET", healthHandler],
    ["claude", "POST", claudeHandler],
    ["twitch", "POST", twitchHandler]
];

function registerRoutes() {
    if (routesRegistered) return;
    for (const [route, method, handler] of ROUTES) {
        if (!modules.httpServer.registerCustomRoute(PREFIX, route, method, handler)) {
            log("warn", `Couldn't register /integrations/${PREFIX}/${route} (already registered?)`);
        }
    }
    routesRegistered = true;
}

function unregisterRoutes() {
    if (!routesRegistered) return;
    for (const [route, method] of ROUTES) {
        modules.httpServer.unregisterCustomRoute(PREFIX, route, method);
    }
    routesRegistered = false;
}

// ---------------------------------------------------------------------------
// Firebot script interface
// ---------------------------------------------------------------------------

exports.getScriptManifest = () => ({
    name: "RS3 Twitch & Claude Chat",
    description: "Shows your Twitch chat in the RuneScape 3 'Twitch & Claude Chat' plugin, and lets you ask Claude and reply to Twitch from the game.",
    author: "Adi Carlisle",
    version: "0.2.0",
    website: "https://github.com/adicarlisle/twitch-claude-chat",
    startupOnly: true,
    firebotVersion: "5"
});

exports.getDefaultParameters = () => ({
    anthropicApiKey: {
        type: "password",
        default: "",
        title: "Anthropic API key",
        description: "From console.anthropic.com. Needed for Claude replies. Leave empty to use Twitch chat only."
    },
    model: {
        type: "enum",
        options: MODELS,
        default: MODELS[0],
        title: "Claude model",
        description: "Haiku is quickest; Sonnet gives better answers."
    },
    sendAsBot: {
        type: "boolean",
        default: false,
        title: "Send /t messages as the bot account",
        description: "Off: messages you send from the game come from your streamer account."
    }
});

function applyParameters(p) {
    params = {
        anthropicApiKey: String((p && p.anthropicApiKey) || "").trim(),
        model: MODELS.includes(p && p.model) ? p.model : (String((p && p.model) || "").trim() || MODELS[0]),
        sendAsBot: !!(p && p.sendAsBot)
    };
}

exports.run = (runRequest) => {
    modules = runRequest.modules;
    firebot = runRequest.firebot;
    applyParameters(runRequest.parameters);
    registerRoutes();
    if (!eventListener) {
        eventListener = onEventTriggered;
        modules.eventManager.on("event-triggered", eventListener);
    }
    addSystem("Firebot connected.");
    log("info", `Ready at http://localhost:7472/integrations/${PREFIX}/`);
};

exports.parametersUpdated = (p) => {
    applyParameters(p);
    addSystem("Settings updated.");
};

exports.stop = () => {
    if (modules && eventListener) {
        modules.eventManager.removeListener("event-triggered", eventListener);
        eventListener = null;
    }
    if (modules) unregisterRoutes();
};

// Exposed for tests only.
exports._test = { renderMessage, toAscii, escapeMarkup, stripMarkdown };
