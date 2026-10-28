// Test double for Firebot: an Express server configured like Firebot's
// (src/server/http-server-manager.ts: cors(), bodyParser.json(), urlencoded,
// custom routes at /integrations/<prefix>/<route>) plus fake script modules.
// Loads firebot/rs3-twitch-claude-chat.js and runs it like a startup script.
//
// Control over stdin (one JSON object per line):
//   {"chat": {<FirebotChatMessage fields>}}   -> emits a twitch chat-message event
//   {"params": {...}}                         -> parametersUpdated
//   {"stop": true}                            -> calls the script's stop()
// Prints JSON lines to stdout: {"ready": port}, {"sent": {...}}
"use strict";
const path = require("path");
const readline = require("readline");
const EventEmitter = require("events");
const express = require("express");
const cors = require("cors");
const bodyParser = require("body-parser");

const port = parseInt(process.env.PORT || "7472", 10);
const app = express();
app.use(cors());
app.use(bodyParser.json());
app.use(bodyParser.urlencoded({ extended: true }));
const router = express.Router();
app.use(router);
const routes = new Map();
const out = o => process.stdout.write(JSON.stringify(o) + "\n");

const eventManager = new EventEmitter();
const modules = {
    logger: { info: m => out({ log: m }), warn: m => out({ log: m }), error: m => out({ log: m }), debug: () => {} },
    eventManager,
    httpServer: {
        registerCustomRoute(prefix, route, method, cb) {
            const key = `${method} /integrations/${prefix}/${route}`;
            if (routes.has(key)) return false;
            routes.set(key, cb);
            return true;
        },
        unregisterCustomRoute(prefix, route, method) {
            return routes.delete(`${method} /integrations/${prefix}/${route}`);
        }
    },
    twitchApi: { chat: { async sendChatMessage(message, reply, asBot) { out({ sent: { message, asBot } }); return true; } } }
};
// Dispatch registered custom routes (Firebot uses an Express router the same way).
router.use((req, res, next) => {
    const cb = routes.get(`${req.method} ${req.path}`);
    if (!cb) return next();
    Promise.resolve(cb(req, res)).catch(err => { out({ log: String(err) }); res.status(500).end(); });
});

const script = require(path.resolve(__dirname, "../../firebot/rs3-twitch-claude-chat.js"));
const firebot = {
    accounts: {
        streamer: { username: "adi", displayName: "Adi", loggedIn: true },
        bot: { username: "adibot", displayName: "AdiBot", loggedIn: true }
    },
    version: "5.65.0"
};
const defaults = script.getDefaultParameters();
const parameters = Object.fromEntries(Object.entries(defaults).map(([k, v]) => [k, v.default]));
parameters.anthropicApiKey = process.env.TEST_ANTHROPIC_KEY || "";

app.listen(port, "127.0.0.1", () => {
    script.run({ modules, firebot, parameters, trigger: { type: "startup" } });
    out({ ready: port, manifest: script.getScriptManifest().name });
});

readline.createInterface({ input: process.stdin }).on("line", line => {
    const cmd = JSON.parse(line);
    if (cmd.chat) {
        eventManager.emit("event-triggered", {
            event: { id: "chat-message" }, source: { id: "twitch" },
            meta: { username: cmd.chat.username, userDisplayName: cmd.chat.userDisplayName, messageText: cmd.chat.rawText, chatMessage: cmd.chat }
        });
        // Other events must be ignored.
        eventManager.emit("event-triggered", { event: { id: "follow" }, source: { id: "twitch" }, meta: { username: "x" } });
    }
    if (cmd.params) script.parametersUpdated(cmd.params);
    if (cmd.stop) { script.stop(); out({ stopped: true, listeners: eventManager.listenerCount("event-triggered"), routes: routes.size }); }
});
