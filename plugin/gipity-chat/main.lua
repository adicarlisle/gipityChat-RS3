-- gipityChat
--
-- Ask an AI (Claude by default, or another provider) from the normal game chat:
--
--     !c how do I get to the Kalphite Queen?
--     !ai / !chat / !gc work the same way.
--
-- The answer appears in your chatbox, visible only to you. There's no window:
-- the only UI is a small box for pasting your API key (shown on first use or with
-- "!c /setup"), because a key must never be typed into game chat.
--
-- Only YOUR OWN messages are read; other players' chat is ignored and never sent
-- anywhere. Your "!c" message itself goes to the game server like any chat, so
-- others in that channel see it. A Friends Chat with only you in it keeps it private.
--
-- Files: json.lua (JSON), text.lua (text clean-up), providers.lua (provider list),
-- ai.lua (request/response formats), setup.lua (the API key box).
--
-- Rules we follow from the community's runtime notes on the beta client:
--   * HTTP requests start only from the Logic event, never from inside another
--     request's completion callback (or from the chat event). Callbacks only
--     mark a request as done.
--   * Request body strings stay referenced until their request finishes.
--   * Every Event subscription is removed with a direct Unsubscribe call in
--     PluginShutdown (never passed straight to pcall).

local text = require("text")
local providers = require("providers")
local ai = require("ai")
local setup = require("setup")

local NAME = "gipity-chat" -- subscription name, unique to this plugin

local TRIGGERS = { "!c", "!ai", "!chat", "!gc" } -- lower-case; followed by a space
local MAX_TURNS = 10 -- conversation turns (question + answer) sent as context
local CHUNK = 180 -- longest piece of a reply per chatbox line

local COLOURS = { ai = "d97757", info = "a0a0a0", error = "ff7070" }

---------------------------------------------------------------------------
-- Settings (PersistentDB keeps them on this computer, per plugin)
---------------------------------------------------------------------------

local function loadString(key, default)
    local v = PersistentDB:Get(key)
    if type(v) == "string" then return v end
    return default
end

local state = {
    provider = providers.find(loadString("provider", "claude")) or providers[1],
    convo = {}, -- conversation sent to the AI: { role, content }
    queue = {}, -- questions waiting to be sent
    pending = nil, -- { req, done, body, provider, question } for the request in flight
}

-- Keys and models are saved per provider.
local function apiKey(p) return loadString("key." .. p.id, "") end
local function setApiKey(p, key) PersistentDB:Set("key." .. p.id, key) end
local function model(p) return loadString("model." .. p.id, p.model) end
local function setModel(p, m) PersistentDB:Set("model." .. p.id, m) end

-- Shows only the start and end of a key, e.g. "sk-ant-...wXyZ".
local function maskKey(key)
    if #key <= 12 then return string.rep("*", #key) end
    return string.sub(key, 1, 7) .. "..." .. string.sub(key, -4)
end

---------------------------------------------------------------------------
-- Writing to the chatbox (local only: Chat.AddMessage is never sent to the server)
---------------------------------------------------------------------------

-- `displayText` must already be cleaned (text.forDisplay or text.escapeMarkup).
-- Long text is split at word boundaries; the label only goes on the first line.
local function say(label, colour, displayText)
    local lines = text.wrap(displayText, CHUNK, CHUNK)
    for i, line in ipairs(lines) do
        if i == 1 and label then
            Chat.AddMessage(formatStr("<col={}>{}:</col> {}", colour, label, line) or line)
        else
            Chat.AddMessage(formatStr("<col={}>{}</col>", label and "ffffff" or colour, line) or line)
        end
    end
end

local function info(s) say(nil, COLOURS.info, text.escapeMarkup("[gipityChat] " .. s)) end
local function warn(s) say(nil, COLOURS.error, text.escapeMarkup("[gipityChat] " .. s)) end

---------------------------------------------------------------------------
-- API key box
---------------------------------------------------------------------------

local function openSetup()
    local p = state.provider
    if not p.needsKey then
        info(p.name .. " runs on your PC and needs no key. Set a model with: !c /model NAME")
        return
    end
    setup.open({
        title = "gipityChat - " .. p.name .. " API key",
        hint = "Get a key at " .. p.keyFrom .. ". Paste it below. It's saved on this computer only.",
        current = apiKey(p) ~= "" and maskKey(apiKey(p)) or nil,
        onSave = function(key)
            setApiKey(p, key)
            info(p.name .. " key saved (" .. maskKey(key) .. "). Ask with: !c your question")
        end,
    })
end

---------------------------------------------------------------------------
-- Asking the AI
---------------------------------------------------------------------------

local function startRequest(question)
    local p = state.provider
    local key, m = apiKey(p), model(p)
    if p.needsKey and key == "" then
        warn("No " .. p.name .. " API key yet - opening the key box.")
        openSetup()
        return
    end
    if m == "" then
        warn("Choose a " .. p.name .. " model first: !c /model NAME  (" .. p.examples .. ")")
        return
    end
    -- Recent conversation plus the new question.
    local convo = {}
    local first = math.max(1, #state.convo - MAX_TURNS * 2 + 1)
    for i = first, #state.convo do convo[#convo + 1] = state.convo[i] end
    convo[#convo + 1] = { role = "user", content = question }

    local built = ai.buildRequest(p, key, m, convo)
    local entry = { done = false, body = built.body, provider = p, question = question } -- body kept alive
    entry.req = HTTPRequest.new(Plugin.urls[p.url], built.path)
    for _, h in ipairs(built.headers) do
        entry.req:AddHeader(h[1], h[2])
    end
    entry.req:Post(entry.body, function() entry.done = true end)
    state.pending = entry
end

local function finishRequest(entry)
    local p = entry.provider
    local reply, err = ai.parseResponse(p, entry.req)
    if not reply then
        warn(p.name .. ": " .. err)
        return
    end
    state.convo[#state.convo + 1] = { role = "user", content = entry.question }
    state.convo[#state.convo + 1] = { role = "assistant", content = reply }
    while #state.convo > MAX_TURNS * 2 do table.remove(state.convo, 1) end
    say(p.name, COLOURS.ai, text.forDisplay(reply))
end

---------------------------------------------------------------------------
-- Commands: "!c /something"
---------------------------------------------------------------------------

local function showHelp()
    info("Ask: !c QUESTION  (also !ai, !chat or !gc). Answers show only to you.")
    info("!c /setup - enter or change your API key (opens a small box; never type keys in chat)")
    info("!c /provider - list AIs;  !c /provider NAME - switch (e.g. openai, gemini, ollama)")
    info("!c /model - show model;  !c /model NAME - change it")
    info("!c /new - start a new conversation;  !c /forget - delete the saved key")
    info("Tip: others in the chat channel see your !c messages. Use a Friends Chat with only you in it to keep them private.")
end

local function listProviders()
    local parts = {}
    for _, p in ipairs(providers) do
        local note = p.needsKey and ((apiKey(p) ~= "") and "key saved" or "no key") or "on your PC"
        parts[#parts + 1] = p.id .. ((p == state.provider) and "*" or "") .. " (" .. note .. ")"
    end
    info("Providers: " .. table.concat(parts, ", ") .. ". * = current. Switch: !c /provider NAME")
end

local function runCommand(cmd, arg)
    local p = state.provider
    if cmd == "help" then
        showHelp()
    elseif cmd == "setup" or cmd == "key" then
        if arg ~= "" then
            -- Too late to keep it secret: it already went out as chat.
            warn("Don't type keys in chat - others can see them, and they're sent to the game server. "
                .. "If that was a real key, delete it at " .. p.keyFrom .. " and make a new one.")
        end
        openSetup()
    elseif cmd == "forget" then
        setApiKey(p, "")
        info(p.name .. " key removed from this computer.")
    elseif cmd == "provider" then
        if arg == "" then
            listProviders()
            return
        end
        local np = providers.find(arg)
        if not np then
            warn("Unknown provider '" .. arg .. "'. Choose one of: " .. providers.ids())
            return
        end
        state.provider = np
        PersistentDB:Set("provider", np.id)
        info("Now using " .. np.name .. " (" .. (model(np) ~= "" and model(np) or "no model set") .. ").")
        if np.needsKey and apiKey(np) == "" then
            openSetup()
        elseif model(np) == "" then
            info("Choose a model: !c /model NAME  (" .. np.examples .. ")")
        end
    elseif cmd == "model" then
        if arg == "" then
            info(p.name .. " model: " .. (model(p) ~= "" and model(p) or "not set") .. ". Examples: " .. p.examples)
        else
            setModel(p, arg)
            info(p.name .. " model set to " .. arg .. ".")
        end
    elseif cmd == "new" or cmd == "clear" then
        state.convo = {}
        info("New conversation.")
    else
        warn("Unknown command /" .. cmd .. ". Try: !c /help")
    end
end

---------------------------------------------------------------------------
-- Reading your own game chat
---------------------------------------------------------------------------

local GAME_CHAT_TYPES = {
    [ChatType.PUBLIC] = true,
    [ChatType.FRIEND_CHAT] = true,
    [ChatType.CLANCHANNEL_AFFINED_CHAT] = true,
    [ChatType.CLANCHANNEL_GUEST_CHAT] = true,
    [ChatType.GROUP_SAME_TEAM] = true,
    [ChatType.GROUP_ALL] = true,
}

-- Lower-case name with spaces and symbols removed, so "Adi Rs" matches "adi_rs".
local function simpleName(s)
    return (string.gsub(string.lower(s or ""), "[^%w]", ""))
end

local function myName()
    local ok, me = pcall(function() return Player.GetEntity() end)
    if ok and me then return simpleName(me.displayName) end
    return nil
end

-- Removes RS markup (<col=...> etc.) but keeps escaped < and > as real characters.
local function stripMarkup(s)
    s = string.gsub(s, "<lt>", "\1")
    s = string.gsub(s, "<gt>", "\2")
    s = string.gsub(s, "<[^>]*>", "")
    s = string.gsub(s, "\1", "<")
    return (string.gsub(s, "\2", ">"))
end

-- Returns the text after a trigger word ("!c hello" -> "hello"), or nil.
local function afterTrigger(msg)
    local first, rest = string.match(msg, "^(%S+)%s*(.-)%s*$")
    if not first then return nil end
    first = string.lower(first)
    for _, t in ipairs(TRIGGERS) do
        if first == t then return rest end
    end
    return nil
end

local function onGameChat(ev)
    if not GAME_CHAT_TYPES[ev.chatType] then return end -- ignores our own PLUGIN lines too
    local me = myName()
    if not me or me == "" or simpleName(ev.senderNameSimple) ~= me then return end
    local rest = afterTrigger(stripMarkup(ev.chatMessage or ""))
    if rest == nil then return end
    if rest == "" then
        showHelp()
        return
    end
    local cmd, arg = string.match(rest, "^/(%S+)%s*(.-)$")
    if cmd then
        runCommand(string.lower(cmd), text.trim(arg))
    else
        state.queue[#state.queue + 1] = rest -- sent from the Logic loop, not from here
    end
end

---------------------------------------------------------------------------
-- Main loop
---------------------------------------------------------------------------

local function onLogic(_ev)
    -- Finish the request whose callback has fired.
    if state.pending and state.pending.done then
        local entry = state.pending
        state.pending = nil
        finishRequest(entry)
    end
    -- Start the next question (only ever from here, never from a callback).
    if not state.pending and #state.queue > 0 then
        startRequest(table.remove(state.queue, 1))
    end
end

---------------------------------------------------------------------------
-- Start up / shut down
---------------------------------------------------------------------------

Event.Logic.Subscribe(NAME, onLogic)

local chatSubscribed = false
if not Plugin.HasPermission(PluginPermissions.chatAccess) then
    -- Without chatAccess we can neither read !c nor show replies; there's nothing to do.
    print("[gipityChat] needs the chatAccess permission to read !c and show replies.")
else
    Event.ChatMessage.Subscribe(NAME, onGameChat)
    chatSubscribed = true
    if not Plugin.HasPermission(PluginPermissions.httpAccess) then
        warn("Needs the httpAccess permission to reach the AI provider.")
    elseif state.provider.needsKey and apiKey(state.provider) == "" then
        info("Welcome! Paste your " .. state.provider.name .. " API key in the box, then ask with: !c your question")
        openSetup()
    else
        info("Ready (" .. state.provider.name .. "). Ask with: !c your question   Help: !c /help")
    end
end

function PluginShutdown()
    -- Direct calls, never pcall(Event.X.Unsubscribe, ...): that form aborts the client.
    Event.Logic.Unsubscribe(NAME)
    if chatSubscribed then
        Event.ChatMessage.Unsubscribe(NAME)
    end
    if state.pending and state.pending.req and not state.pending.done then
        local req = state.pending.req
        pcall(function() req:Cancel() end)
    end
    setup.close()
end
