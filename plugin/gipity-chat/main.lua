-- gipityChat
--
-- Ask an AI (Claude by default, or another provider) from the normal game chat:
--
--     !c how do I get to the Kalphite Queen?
--     !ai / !chat / !gc work the same way (trigger words are configurable).
--
-- The answer appears in your chatbox, visible only to you. Configuration is in a
-- small settings panel ("!c /settings", opened automatically on first use);
-- an API key must never be typed into game chat.
--
-- Only YOUR OWN messages are read; other players' chat is ignored and never sent
-- anywhere. Your "!c" message itself goes to the game server like any chat, so
-- others in that channel see it. A Friends Chat with only you in it keeps it private.
--
-- Files: json.lua (JSON), text.lua (text clean-up), providers.lua (provider list),
-- ai.lua (request/response formats), settings.lua (the settings panel).
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
local panel = require("settings")

local NAME = "gipity-chat" -- subscription name, unique to this plugin

---------------------------------------------------------------------------
-- Settings and their choices
---------------------------------------------------------------------------

local LENGTHS = { { id = "short", label = "Short" }, { id = "medium", label = "Medium" }, { id = "long", label = "Long" } }
local MEMORIES = {
    { id = 0, label = "Off (every question is new)" }, { id = 3, label = "Last 3 exchanges" },
    { id = 5, label = "Last 5 exchanges" }, { id = 10, label = "Last 10 exchanges" }, { id = 20, label = "Last 20 exchanges" },
}
local COLOURS = {
    { id = "d97757", label = "Orange" }, { id = "ffd166", label = "Gold" }, { id = "7fd1ff", label = "Sky blue" },
    { id = "60ff60", label = "Green" }, { id = "ff79c6", label = "Pink" }, { id = "c792ea", label = "Purple" },
    { id = "ffffff", label = "White" },
}
local LINE_LENGTHS = {
    { id = 100, label = "100 characters" }, { id = 140, label = "140 characters" },
    { id = 180, label = "180 characters" }, { id = 220, label = "220 characters" },
}

local DEFAULTS = {
    triggers = "!c !ai !chat !gc",
    length = "medium",
    memory = 10,
    instructions = "",
    replyName = "",
    colour = "d97757",
    lineLength = 180,
}

local INFO_COLOUR, ERROR_COLOUR = "a0a0a0", "ff7070"

local function loadSetting(key, default)
    local v = PersistentDB:Get(key)
    if type(v) == type(default) then return v end
    return default
end

local function oneOf(list, value, default)
    for _, item in ipairs(list) do
        if item.id == value then return value end
    end
    return default
end

local function loadConfig()
    return {
        triggers = loadSetting("triggers", DEFAULTS.triggers),
        length = oneOf(LENGTHS, loadSetting("length", DEFAULTS.length), DEFAULTS.length),
        memory = oneOf(MEMORIES, loadSetting("memory", DEFAULTS.memory), DEFAULTS.memory),
        instructions = loadSetting("instructions", DEFAULTS.instructions),
        replyName = loadSetting("replyName", DEFAULTS.replyName),
        colour = oneOf(COLOURS, loadSetting("colour", DEFAULTS.colour), DEFAULTS.colour),
        lineLength = oneOf(LINE_LENGTHS, loadSetting("lineLength", DEFAULTS.lineLength), DEFAULTS.lineLength),
    }
end

local state = {
    provider = providers.find(loadSetting("provider", "claude")) or providers[1],
    config = loadConfig(),
    triggers = {}, -- parsed from config.triggers
    convo = {}, -- conversation sent to the AI: { role, content }
    queue = {}, -- questions waiting to be sent
    pending = nil, -- { req, done, body, provider, question } for the request in flight
}

-- Trigger words: space-separated, lower-cased. Each must start with a symbol
-- (like ! or ?) so normal chat can't set it off by accident.
local function parseTriggers(s)
    local out, bad = {}, {}
    for word in string.gmatch(string.lower(s or ""), "%S+") do
        if string.match(word, "^[%p]") and #word >= 2 then
            out[#out + 1] = word
        else
            bad[#bad + 1] = word
        end
    end
    return out, bad
end
state.triggers = parseTriggers(state.config.triggers)
if #state.triggers == 0 then state.triggers = parseTriggers(DEFAULTS.triggers) end

-- Keys and models are saved per provider.
local function apiKey(p) return loadSetting("key." .. p.id, "") end
local function setApiKey(p, key) PersistentDB:Set("key." .. p.id, key) end
local function model(p) return loadSetting("model." .. p.id, p.model) end
local function setModel(p, m) PersistentDB:Set("model." .. p.id, m) end

-- Shows only the start and end of a key, e.g. "sk-ant-...wXyZ".
local function maskKey(key)
    if #key <= 12 then return string.rep("*", #key) end
    return string.sub(key, 1, 7) .. "..." .. string.sub(key, -4)
end

local function firstTrigger() return state.triggers[1] end

---------------------------------------------------------------------------
-- Writing to the chatbox (local only: Chat.AddMessage is never sent to the server)
---------------------------------------------------------------------------

-- `displayText` must already be cleaned (text.forDisplay or text.escapeMarkup).
-- Long text is split at word boundaries; the label only goes on the first line.
local function say(label, colour, displayText)
    local width = state.config.lineLength
    for i, line in ipairs(text.wrap(displayText, width, width)) do
        if i == 1 and label then
            Chat.AddMessage(formatStr("<col={}>{}:</col> {}", colour, label, line) or line)
        elseif label then
            Chat.AddMessage(line)
        else
            Chat.AddMessage(formatStr("<col={}>{}</col>", colour, line) or line)
        end
    end
end

local function info(s) say(nil, INFO_COLOUR, text.escapeMarkup("[gipityChat] " .. s)) end
local function warn(s) say(nil, ERROR_COLOUR, text.escapeMarkup("[gipityChat] " .. s)) end

---------------------------------------------------------------------------
-- Settings panel
---------------------------------------------------------------------------

local function keyLabel(providerId)
    local p = providers.find(providerId)
    if not p.needsKey then return "not needed (runs on your PC)" end
    local k = apiKey(p)
    return (k ~= "") and maskKey(k) or "not set"
end

local function providerChoices()
    local list = {}
    for _, p in ipairs(providers) do
        list[#list + 1] = { id = p.id, label = p.name, examples = "e.g. " .. p.examples }
    end
    return list
end

local function applySettings(values, newKey)
    local p = providers.find(values.provider) or state.provider
    state.provider = p
    PersistentDB:Set("provider", p.id)
    setModel(p, text.trim(values.model or ""))
    if newKey then
        if p.needsKey then
            setApiKey(p, newKey)
        else
            info(p.name .. " runs on your PC and doesn't use a key, so the key wasn't saved.")
        end
    end

    -- Triggers: keep the old ones if none of the new ones are usable.
    local trig, bad = parseTriggers(values.triggers)
    if #bad > 0 then
        warn("Ignored trigger words (they must start with a symbol like ! or ?): " .. table.concat(bad, " "))
    end
    if #trig == 0 then
        warn("No usable trigger words - keeping " .. table.concat(state.triggers, " "))
    else
        state.triggers = trig
    end

    local cfg = state.config
    cfg.triggers = table.concat(state.triggers, " ")
    cfg.length = oneOf(LENGTHS, values.length, cfg.length)
    cfg.memory = oneOf(MEMORIES, values.memory, cfg.memory)
    cfg.instructions = text.trim(values.instructions or "")
    cfg.replyName = text.trim(values.replyName or "")
    cfg.colour = oneOf(COLOURS, values.colour, cfg.colour)
    cfg.lineLength = oneOf(LINE_LENGTHS, values.lineLength, cfg.lineLength)
    for k, v in pairs(cfg) do PersistentDB:Set(k, v) end

    local status
    if p.needsKey and apiKey(p) == "" then
        status = "no API key yet - add one in " .. firstTrigger() .. " /settings"
    elseif model(p) == "" then
        status = "no model set - add one in " .. firstTrigger() .. " /settings"
    else
        status = "ready. Ask with: " .. firstTrigger() .. " your question"
    end
    info("Settings saved. " .. p.name .. " (" .. (model(p) ~= "" and model(p) or "no model") .. "), " .. status)
end

local function openSettings()
    local values = {}
    for k, v in pairs(state.config) do values[k] = v end
    values.provider = state.provider.id
    values.model = model(state.provider)
    local defaults = {}
    for k, v in pairs(DEFAULTS) do defaults[k] = v end
    panel.open({
        values = values,
        defaults = defaults,
        choices = { providers = providerChoices(), lengths = LENGTHS, memories = MEMORIES,
                    colours = COLOURS, lineLengths = LINE_LENGTHS },
        keyLabel = keyLabel,
        modelFor = function(providerId) return model(providers.find(providerId)) end,
        onSave = applySettings,
        onForgetKey = function(providerId)
            local p = providers.find(providerId)
            setApiKey(p, "")
            info(p.name .. " key removed from this computer.")
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
        warn("No " .. p.name .. " API key yet - opening settings.")
        openSettings()
        return
    end
    if m == "" then
        warn("Choose a " .. p.name .. " model first - opening settings.")
        openSettings()
        return
    end
    -- Recent conversation (as much as the Memory setting allows) plus the new question.
    local convo = {}
    local keep = state.config.memory * 2
    for i = math.max(1, #state.convo - keep + 1), #state.convo do
        if keep > 0 then convo[#convo + 1] = state.convo[i] end
    end
    convo[#convo + 1] = { role = "user", content = question }

    local length = ai.LENGTHS[state.config.length] or ai.LENGTHS.medium
    local built = ai.buildRequest(p, key, m, convo, {
        system = ai.systemPrompt(state.config.length, state.config.instructions),
        maxTokens = length.tokens,
    })
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
    while #state.convo > 40 do table.remove(state.convo, 1) end
    local name = state.config.replyName ~= "" and text.escapeMarkup(text.toGameText(state.config.replyName)) or p.name
    say(name, state.config.colour, text.forDisplay(reply))
end

---------------------------------------------------------------------------
-- Commands: "!c /something"
---------------------------------------------------------------------------

local function showHelp()
    local t = firstTrigger()
    info("Ask: " .. t .. " QUESTION  (triggers: " .. table.concat(state.triggers, " ") .. "). Answers show only to you.")
    info(t .. " /settings - provider, model, API key, trigger words, answer style, display")
    info(t .. " /provider NAME - quick switch;  " .. t .. " /model NAME - quick change;  " .. t .. " /new - new conversation")
    info("Never type API keys in chat. Others in the chat channel see your questions - use a Friends Chat with only you in it to keep them private.")
end

local function runCommand(cmd, arg)
    local p = state.provider
    if cmd == "help" then
        showHelp()
    elseif cmd == "settings" or cmd == "setup" or cmd == "config" or cmd == "key" then
        if cmd == "key" and arg ~= "" then
            -- Too late to keep it secret: it already went out as chat.
            warn("Don't type keys in chat - others can see them, and they're sent to the game server. "
                .. "If that was a real key, delete it at " .. p.keyFrom .. " and make a new one.")
        end
        openSettings()
    elseif cmd == "forget" then
        setApiKey(p, "")
        info(p.name .. " key removed from this computer.")
    elseif cmd == "provider" then
        if arg == "" then
            local parts = {}
            for _, q in ipairs(providers) do parts[#parts + 1] = q.id .. ((q == p) and "*" or "") end
            info("Providers: " .. table.concat(parts, ", ") .. " (* = current). Switch: " .. firstTrigger() .. " /provider NAME")
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
        if (np.needsKey and apiKey(np) == "") or model(np) == "" then openSettings() end
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
        warn("Unknown command /" .. cmd .. ". Try: " .. firstTrigger() .. " /help")
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
    for _, t in ipairs(state.triggers) do
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
    print("[gipityChat] needs the chatAccess permission to read " .. firstTrigger() .. " and show replies.")
else
    Event.ChatMessage.Subscribe(NAME, onGameChat)
    chatSubscribed = true
    if not Plugin.HasPermission(PluginPermissions.httpAccess) then
        warn("Needs the httpAccess permission to reach the AI provider.")
    elseif state.provider.needsKey and apiKey(state.provider) == "" then
        info("Welcome! Add your " .. state.provider.name .. " API key in the settings panel, then ask with: "
            .. firstTrigger() .. " your question")
        openSettings()
    else
        info("Ready (" .. state.provider.name .. "). Ask with: " .. firstTrigger() .. " your question   Settings: "
            .. firstTrigger() .. " /settings")
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
    panel.close()
end
