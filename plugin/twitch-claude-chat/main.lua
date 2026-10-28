-- Twitch & Claude Chat
--
-- A movable, resizable chat window that shows your Twitch chat inside
-- RuneScape 3 and lets you talk to Claude from the same window.
--
-- The plugin API can only make HTTP GET/POST requests, so the real work (the
-- Twitch connection and the Claude API key) lives in another program on this PC:
--   * Firebot, with the rs3-twitch-claude-chat.js startup script (port 7472), or
--   * the RS3 Chat Bridge app (port 8787).
-- The plugin tries Firebot first, then the bridge, and uses whichever answers.
-- This plugin:
--   * polls the bridge for new messages twice a second and draws them,
--   * sends what you type in the window's input box to Claude (or to Twitch with /t),
--   * lets you do the same from the real game chat with !c and !tw,
--   * optionally mirrors messages into the normal game chatbox (needs chatAccess).
--
-- It only looks at game chat to spot YOUR OWN messages starting with !tw or !c;
-- other players' messages are ignored and nothing about them leaves the game.
--
-- Rules we follow from the community's runtime notes on the beta client:
--   * HTTP requests start only from the Logic event, never from inside another
--     request's completion callback. Callbacks only mark a request as done.
--   * Request body strings stay referenced until their request finishes.
--   * Every Event subscription is removed with a direct Unsubscribe call in
--     PluginShutdown (never passed straight to pcall).

local NAME = "twitch-claude-chat" -- subscription name, unique to this plugin

---------------------------------------------------------------------------
-- Settings
---------------------------------------------------------------------------

local DEFAULT_X, DEFAULT_Y = 20, 120
local DEFAULT_W, DEFAULT_H = 440, 270
local MIN_W, MIN_H = 380, 130
local MAX_W, MAX_H = 1600, 1200

local LINE_HEIGHT = 16
local CHAR_WIDTH = 7 -- rough average character width of FONT, used for word wrapping
local TITLE_HEIGHT = 22
local INPUT_HEIGHT = 28
local PAD = 6
local GRIP_W = 44 -- the "Size" button next to the input box

local FONT = id.Font.VERDANA_11PT_REGULAR
local TITLE_FONT = id.Font.MUSEO_SANS_13PT_BOLD

local POLL_TICKS = 25 -- Logic runs at 50 Hz, so 25 ticks = 0.5 s
local POLL_TICKS_OFFLINE = 150 -- back off to 3 s while the bridge is unreachable
local MAX_HISTORY = 300 -- messages kept for scrolling back

local MODES = { "All", "Twitch", "Claude" }

-- Where the chat comes from, in the order we try them. Both serve the same API
-- under API_PREFIX. Plugin.urls values are opaque: only pass them to HTTPRequest.
local BACKENDS = {}
if Plugin.urls.firebot then BACKENDS[#BACKENDS + 1] = { name = "Firebot", url = Plugin.urls.firebot } end
if Plugin.urls.bridge then BACKENDS[#BACKENDS + 1] = { name = "bridge", url = Plugin.urls.bridge } end
local API_PREFIX = "/integrations/rs3chat"

---------------------------------------------------------------------------
-- Saved settings (PersistentDB keeps them between sessions)
---------------------------------------------------------------------------

local function loadNumber(key, default)
    local v = PersistentDB:Get(key)
    if type(v) == "number" then return v end
    return default
end

local function loadBool(key, default)
    local v = PersistentDB:Get(key)
    if type(v) == "boolean" then return v end
    return default
end

local function clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

local state = {
    x = loadNumber("winX", DEFAULT_X),
    y = loadNumber("winY", DEFAULT_Y),
    w = clamp(loadNumber("winW", DEFAULT_W), MIN_W, MAX_W),
    h = clamp(loadNumber("winH", DEFAULT_H), MIN_H, MAX_H),
    collapsed = false, -- always start open, so a reload (prl) brings the window back
    mode = loadNumber("mode", 1), -- index into MODES
    mirror = loadBool("mirror", false), -- copy messages into the game chatbox

    history = {}, -- messages: { id, kind, name, colour, text }
    lastId = 0, -- newest line id received from the bridge
    firstPollDone = false,
    scroll = 0, -- display lines scrolled up from the bottom
    bridgeOnline = false, -- connected to a backend (Firebot or the bridge)
    backend = 1, -- index into BACKENDS currently being used / tried
    connectedBackend = nil, -- name of the backend we last connected to
    failures = 0, -- consecutive failed polls
    twitchState = "off",
    claudeState = "idle",

    tick = 0,
    nextPollTick = 0,
    poll = nil, -- { req, done } for the in-flight GET /poll
    send = nil, -- { req, done, body } for the in-flight POST
    outbox = {}, -- queued { path, body } POSTs

    -- Moving/resizing: click Move (or Size) once, move the mouse, click it again.
    adjust = nil, -- { kind = "move"|"size", mx0, my0, x0, y0, w0, h0 }
}

local function saveSettings()
    PersistentDB:Set("winX", state.x)
    PersistentDB:Set("winY", state.y)
    PersistentDB:Set("winW", state.w)
    PersistentDB:Set("winH", state.h)
    PersistentDB:Set("mode", state.mode)
    PersistentDB:Set("mirror", state.mirror)
end

---------------------------------------------------------------------------
-- Text helpers
---------------------------------------------------------------------------

-- Splits on tabs, keeping empty fields (string.gmatch would drop them).
local function splitTabs(s)
    local out, start = {}, 1
    while true do
        local i = string.find(s, "\t", start, true)
        if not i then
            out[#out + 1] = string.sub(s, start)
            return out
        end
        out[#out + 1] = string.sub(s, start, i - 1)
        start = i + 1
    end
end

local function trim(s)
    return (string.gsub(s, "^%s*(.-)%s*$", "%1"))
end

-- Escapes RS text markup in text that we produce locally (the bridge escapes its own).
local MARKUP_ESCAPES = { ["<"] = "<lt>", [">"] = "<gt>" }
local function escapeMarkup(s)
    return (string.gsub(s, "[<>]", MARKUP_ESCAPES)) -- one pass, so "<lt>" isn't re-escaped
end

-- Number of characters a string shows on screen: "<lt>" and "<gt>" draw as one,
-- and markup tags such as <col=ffd166> and </col> take no space.
local function visibleLen(s)
    s = string.gsub(s, "<[lg]t>", "x")
    s = string.gsub(s, "<[^>]*>", "")
    return #s
end

-- Splits a word into on-screen pieces: { text, width }. "<lt>"/"<gt>" are one
-- character wide; other tags are kept whole with width 0 so they're never split.
local function displayChars(word)
    local out, i = {}, 1
    while i <= #word do
        local esc = string.match(word, "^<[lg]t>", i)
        local tag = not esc and string.match(word, "^<[^<>]*>", i)
        if esc then
            out[#out + 1] = { esc, 1 }
            i = i + #esc
        elseif tag then
            out[#out + 1] = { tag, 0 }
            i = i + #tag
        else
            out[#out + 1] = { string.sub(word, i, i), 1 }
            i = i + 1
        end
    end
    return out
end

-- Word-wraps text into lines of at most `width` visible characters.
-- The first line can be shorter (`firstWidth`) to leave room for the sender's name.
local function wrapText(text, firstWidth, width)
    local lines, cur, curLen, limit = {}, {}, 0, firstWidth
    local function newLine()
        lines[#lines + 1] = table.concat(cur, " ")
        cur, curLen, limit = {}, 0, width
    end
    for word in string.gmatch(text, "%S+") do
        local wl = visibleLen(word)
        if wl > width then
            -- A very long word (like a URL): break it wherever it hits the edge.
            if curLen > 0 then newLine() end
            local piece, pl = {}, 0
            for _, ch in ipairs(displayChars(word)) do
                if pl >= limit and ch[2] > 0 then
                    cur = { table.concat(piece) }
                    newLine()
                    piece, pl = {}, 0
                end
                piece[#piece + 1] = ch[1]
                pl = pl + ch[2]
            end
            cur, curLen = { table.concat(piece) }, pl
        else
            local need = (curLen == 0) and wl or (curLen + 1 + wl)
            if need > limit and curLen > 0 then
                newLine()
                need = wl
            end
            cur[#cur + 1] = word
            curLen = need
        end
    end
    if curLen > 0 or #lines == 0 then
        lines[#lines + 1] = table.concat(cur, " ")
    end
    return lines
end

local function hasChatAccess()
    return Plugin.HasPermission(PluginPermissions.chatAccess)
end

---------------------------------------------------------------------------
-- UI construction
---------------------------------------------------------------------------

local ui_ = { lines = {} } -- the components we create, so we can update and destroy them

local parentLayer = ui.Interfaces:GetComponent(id.Component.TOPLEVEL_V2__PLUGIN_BUILD_LAYER_TOP)

local function rgba(r, g, b, a) return Vector4.new(r, g, b, a) end

local function newText(parent, font)
    local t = ui.Text.new(parent)
    t.font = font or FONT
    t.maxLines = 1
    t.isShadowed = true
    t.colour = rgba(1, 1, 1, 1)
    t.clickthrough = true
    return t
end

local function newButton(parent, label)
    local b = ui.Button.new(parent)
    b.stylesheetID = id.StyleSheet.BUTTON_DEFAULT
    b.label = label
    return b
end

local function buildUI()
    -- Root container. Moving it moves everything inside.
    local root = ui.GroupBox.new(parentLayer)
    root.stylesheetID = id.StyleSheet.DEFAULT
    root:SetHeaderLayout(0, 0, 0, 0, 0)
    ui_.root = root

    -- Title bar
    local titleBg = ui.Rectangle.new(root)
    titleBg.fill = true
    titleBg.colour = rgba(0.10, 0.08, 0.06, 0.95)
    ui_.titleBg = titleBg

    local title = newText(root, TITLE_FONT)
    title.alignVertical = ui.AlignMode.CENTRE
    title.content = "<col=b9a3e3>Twitch</col> & <col=d97757>Claude</col>"
    ui_.title = title

    local status = newText(root)
    status.alignVertical = ui.AlignMode.CENTRE
    ui_.status = status

    ui_.move = newButton(root, "Move")
    ui_.mirror = newButton(root, "In-game")
    ui_.mode = newButton(root, "All")
    ui_.collapse = newButton(root, "-")

    -- Body: hidden when collapsed.
    local body = ui.GroupBox.new(root)
    body.stylesheetID = id.StyleSheet.DEFAULT
    body:SetHeaderLayout(0, 0, 0, 0, 0)
    ui_.body = body

    local bg = ui.Rectangle.new(body)
    bg.fill = true
    bg.colour = rgba(0, 0, 0, 0.65)
    bg.clickthrough = false
    ui_.bg = bg

    local input = ui.InputField.new(body)
    input.stylesheetID = id.StyleSheet.INPUT_DEFAULT
    input.inputMode = ui.InputFieldKeyHandlingMode.CHAT
    input.emptyText = "Ask Claude... (Enter to send, /help)"
    ui_.input = input

    ui_.size = newButton(body, "Size")
end

-- Number of chat lines that fit in the current window height.
local function visibleLineCount()
    local avail = state.h - TITLE_HEIGHT - INPUT_HEIGHT - 3 * PAD
    return math.max(1, math.floor(avail / LINE_HEIGHT))
end

-- Makes sure there are at least n line components, and hides any extras.
local function ensureLineComponents(n)
    for i = #ui_.lines + 1, n do
        ui_.lines[i] = newText(ui_.body)
    end
    for i, t in ipairs(ui_.lines) do
        t.hidden = i > n
    end
end

-- Positions everything for the current size/position. Call after any change to them.
local function layout()
    local w, h = state.w, state.h
    local root = ui_.root
    root:SetPos(state.x, state.y)
    root:SetSize(w, state.collapsed and (TITLE_HEIGHT + 6) or h)

    -- Title bar: title on the left, buttons packed on the right, status in between.
    ui_.titleBg:SetPos(0, 0)
    ui_.titleBg:SetSize(w, TITLE_HEIGHT)
    ui_.title:SetPos(PAD, 0)
    ui_.title:SetSize(120, TITLE_HEIGHT)

    local buttons = { { ui_.collapse, 26 }, { ui_.mode, 62 }, { ui_.mirror, 92 }, { ui_.move, 54 } }
    local right = w - 2
    for _, b in ipairs(buttons) do
        right = right - b[2]
        b[1]:SetPos(right, 2)
        b[1]:SetSize(b[2], TITLE_HEIGHT - 4)
        right = right - 3
    end
    local statusW = right - 130
    ui_.status.hidden = statusW < 90
    ui_.status:SetPos(130, 0)
    ui_.status:SetSize(math.max(statusW, 0), TITLE_HEIGHT)

    -- Body
    ui_.body.hidden = state.collapsed
    ui_.body:SetPos(0, TITLE_HEIGHT)
    ui_.body:SetSize(w, h - TITLE_HEIGHT)
    ui_.bg:SetPos(0, 0)
    ui_.bg:SetSize(w, h - TITLE_HEIGHT)

    local n = visibleLineCount()
    ensureLineComponents(n)
    for i = 1, n do
        ui_.lines[i]:SetPos(PAD, PAD + (i - 1) * LINE_HEIGHT)
        ui_.lines[i]:SetSize(w - 2 * PAD, LINE_HEIGHT)
    end

    local inputY = h - TITLE_HEIGHT - PAD - INPUT_HEIGHT
    ui_.input:SetPos(PAD, inputY)
    ui_.input:SetSize(w - 3 * PAD - GRIP_W, INPUT_HEIGHT)
    ui_.size:SetPos(w - PAD - GRIP_W, inputY)
    ui_.size:SetSize(GRIP_W, INPUT_HEIGHT)

    ui_.collapse.label = state.collapsed and "+" or "-"
end

---------------------------------------------------------------------------
-- Rendering
---------------------------------------------------------------------------

local function messageVisible(msg)
    local mode = MODES[state.mode]
    local k = msg.kind
    return mode == "All" or k == "system"
        or (mode == "Twitch" and k == "twitch")
        or (mode == "Claude" and (k == "claude" or k == "you"))
end

-- The wrapped, coloured display lines for one message, cached per wrap width.
local function messageLines(msg, chars)
    if msg.wrapChars == chars then return msg.lines end
    local out = {}
    if msg.kind == "system" then
        for _, l in ipairs(wrapText(msg.text, chars, chars - 3)) do
            out[#out + 1] = formatStr("<col={}>{}</col>", msg.colour, (#out > 0 and "   " or "") .. l)
        end
    else
        local nameLen = visibleLen(msg.name) + 2
        local wrapped = wrapText(msg.text, math.max(8, chars - nameLen), chars - 3)
        for i, l in ipairs(wrapped) do
            if i == 1 then
                out[i] = formatStr("<col={}>{}:</col> {}", msg.colour, msg.name, l)
            else
                out[i] = "   " .. l -- continuation lines are indented
            end
        end
    end
    msg.wrapChars, msg.lines = chars, out
    return out
end

local function statusText()
    if state.adjust then
        return "<col=ffd060>click " .. (state.adjust.kind == "move" and "Move" or "Size") .. " again to finish</col>"
    end
    if #BACKENDS == 0 then
        return "<col=ff6060>no chat source in plugin.json</col>"
    end
    if not state.bridgeOnline then
        return "<col=ff6060>no Firebot or bridge found</col>"
    end
    local tw = state.twitchState == "connected" and "<col=60ff60>live</col>"
        or (state.twitchState == "off" and "<col=a0a0a0>off</col>" or "<col=ffd060>...</col>")
    local cl = state.claudeState == "thinking" and "<col=d97757>thinking...</col>"
        or (state.claudeState == "nokey" and "<col=ff6060>no key</col>" or "<col=60ff60>ready</col>")
    return BACKENDS[state.backend].name .. ": twitch " .. tw .. "  claude " .. cl
end

local function render()
    if not ui_.root then return end
    local n = visibleLineCount()
    local chars = math.max(20, math.floor((state.w - 2 * PAD) / CHAR_WIDTH))

    -- Build display lines from the newest message backwards, only as many as needed.
    local needed = n + state.scroll
    local display = {}
    for i = #state.history, 1, -1 do
        local msg = state.history[i]
        if messageVisible(msg) then
            local ls = messageLines(msg, chars)
            for j = #ls, 1, -1 do
                display[#display + 1] = ls[j]
            end
            if #display >= needed + 200 then break end -- plenty for scrolling
        end
    end
    -- display is newest-first; clamp scrolling to what exists.
    state.scroll = clamp(state.scroll, 0, math.max(0, #display - n))
    for i = 1, n do
        local idx = state.scroll + (n - i) + 1
        ui_.lines[i].content = display[idx] or ""
    end

    ui_.status.content = statusText()
    ui_.mode.label = MODES[state.mode]
    ui_.mirror.label = state.mirror and "In-game: on" or "In-game"
    ui_.move.label = (state.adjust and state.adjust.kind == "move") and "Done" or "Move"
    ui_.size.label = (state.adjust and state.adjust.kind == "size") and "Done" or "Size"
end

---------------------------------------------------------------------------
-- History
---------------------------------------------------------------------------

local function addMessage(msg)
    state.history[#state.history + 1] = msg
    if #state.history > MAX_HISTORY then
        table.remove(state.history, 1)
    end
end

local function addSystem(text)
    addMessage({ id = 0, kind = "system", name = "", colour = "a0a0a0", text = escapeMarkup(text) })
end

-- Copies one message into the game chatbox, which does its own wrapping.
-- Only visible to you; never sent to the server.
local function mirrorToGameChat(msg)
    if not state.mirror or msg.kind == "system" or not hasChatAccess() then return end
    Chat.AddMessage(formatStr("<col={}>{}:</col> {}", msg.colour, msg.name, msg.text) or msg.text)
end

---------------------------------------------------------------------------
-- Talking to the bridge
---------------------------------------------------------------------------

local function newRequest(path)
    local req = HTTPRequest.new(BACKENDS[state.backend].url, API_PREFIX .. path)
    -- The bridge refuses requests without this header (see bridge.py).
    req:AddHeader("X-RS3-Bridge", "1")
    return req
end

local function startPoll()
    local entry = { done = false }
    entry.req = newRequest("/poll?since=" .. string.format("%d", state.lastId))
    entry.req:Get(function() entry.done = true end)
    state.poll = entry
end

local function handlePoll(req)
    if not req.successful or req.responseCode ~= 200 then
        if state.bridgeOnline then
            addSystem("Lost " .. BACKENDS[state.backend].name .. ". Looking for Firebot or the bridge...")
        end
        state.bridgeOnline = false
        -- Try the next backend. Retry quickly until every one has failed once, then back off.
        state.failures = state.failures + 1
        state.backend = state.backend % #BACKENDS + 1
        state.lastId = 0 -- ids are per backend
        state.firstPollDone = false
        state.nextPollTick = state.tick + ((state.failures >= #BACKENDS) and POLL_TICKS_OFFLINE or 5)
        return
    end
    state.failures = 0
    state.bridgeOnline = true
    state.nextPollTick = state.tick + POLL_TICKS
    local name = BACKENDS[state.backend].name
    if state.connectedBackend ~= name then
        state.connectedBackend = name
        addSystem("Connected via " .. name .. ".")
    end

    -- The first poll returns recent backlog, which we show but never mirror.
    local mirror = state.firstPollDone
    local header = true
    local current = nil -- message being assembled from (possibly several) lines
    local function finish()
        if current then
            addMessage(current)
            if mirror then mirrorToGameChat(current) end
            current = nil
        end
    end
    for raw in string.gmatch(req.data, "[^\n]+") do
        local f = splitTabs(raw)
        if header then
            header = false
            if f[1] ~= "OK" then return end
            local last = tonumber(f[2]) or 0
            if last < state.lastId then
                -- The bridge restarted and its ids began again from 1.
                state.lastId = 0
                addSystem(BACKENDS[state.backend].name .. " restarted.")
            end
            state.twitchState = f[3] or "off"
            state.claudeState = f[4] or "idle"
        elseif #f >= 5 then
            local lineId = tonumber(f[1]) or 0
            if lineId > state.lastId then
                state.lastId = lineId
                if f[3] ~= "" or not current then
                    -- A named line starts a new message.
                    finish()
                    current = { id = lineId, kind = f[2], name = f[3], colour = f[4], text = f[5] }
                else
                    -- Unnamed line: continuation (only if the bridge was started with --wrap).
                    current.text = current.text .. " " .. f[5]
                end
            end
        end
    end
    finish()
    state.firstPollDone = true
end

-- Percent-encodes text for an application/x-www-form-urlencoded body.
local function urlEncode(s)
    return (string.gsub(s, "[^%w%-_%.~]", function(c) return string.format("%%%02X", string.byte(c)) end))
end

local function queuePost(path, body)
    state.outbox[#state.outbox + 1] = { path = path, body = body }
end

local function startSend(item)
    -- Sent as a form field: Firebot's server parses forms (but not plain text).
    local entry = { done = false, body = "text=" .. urlEncode(item.body) } -- body kept alive until done
    entry.req = newRequest(item.path)
    entry.req:AddHeader("Content-Type", "application/x-www-form-urlencoded")
    entry.req:Post(entry.body, function() entry.done = true end)
    state.send = entry
end

local function handleSend(entry)
    if not entry.req.successful then
        addSystem("Couldn't reach " .. BACKENDS[state.backend].name .. ", message not sent.")
    end
    state.nextPollTick = state.tick -- poll right away to pick up the echo
end

---------------------------------------------------------------------------
-- Moving and resizing
---------------------------------------------------------------------------

local function finishAdjust()
    state.adjust = nil
    saveSettings()
end

-- Starts (or finishes) moving or resizing. While active, the window follows the
-- mouse every tick, which keeps the button under the cursor so a second click
-- on it ends the action.
local function toggleAdjust(kind)
    if state.adjust then
        local same = state.adjust.kind == kind
        finishAdjust()
        if same then return end
    end
    local mx, my = Mouse.GetX(), Mouse.GetY()
    if not mx then
        addSystem("No mouse available. Use /move x y and /size w h instead.")
        return
    end
    state.adjust = { kind = kind, mx0 = mx, my0 = my, x0 = state.x, y0 = state.y, w0 = state.w, h0 = state.h }
end

local function updateAdjust()
    local a = state.adjust
    if not a then return false end
    local mx, my = Mouse.GetX(), Mouse.GetY()
    if not mx then return false end
    local dx, dy = mx - a.mx0, my - a.my0
    if a.kind == "move" then
        state.x = math.max(0, a.x0 + dx)
        state.y = math.max(0, a.y0 + dy)
        ui_.root:SetPos(state.x, state.y)
        return false
    end
    local w, h = clamp(a.w0 + dx, MIN_W, MAX_W), clamp(a.h0 + dy, MIN_H, MAX_H)
    if w == state.w and h == state.h then return false end
    state.w, state.h = w, h
    layout()
    return true -- needs a re-render (line count or wrap width may have changed)
end

---------------------------------------------------------------------------
-- Input box commands
---------------------------------------------------------------------------

local function showHelp()
    addSystem("Type a message and press Enter to ask Claude.")
    addSystem("/t <message> or !tw <message>  send to your Twitch chat")
    addSystem("In the real game chat: !tw <message> (Twitch), !c <question> (Claude).")
    addSystem("Game chat is seen by others in that channel - use a Friends Chat with only you in it.")
    addSystem("/clear  new Claude conversation   /cls  clear this window")
    addSystem("/mode  cycle All/Twitch/Claude")
    addSystem("Move: click Move, move the mouse, click it again. Size: same with Size.")
    addSystem("/move x y   /size w h   /reset  (put the window back to default)")
end

local function onSubmit(text)
    text = trim(text)
    if text == "" then return end
    local lower = string.lower(text)
    local a, b = string.match(lower, "^/move%s+(%-?%d+)%s+(%-?%d+)$")
    local sw, sh = string.match(lower, "^/size%s+(%d+)%s+(%d+)$")
    if lower == "/help" then
        showHelp()
    elseif lower == "/cls" then
        state.history = {}
        state.scroll = 0
    elseif lower == "/mode" then
        state.mode = state.mode % #MODES + 1
        saveSettings()
    elseif a then
        state.x, state.y = math.max(0, tonumber(a)), math.max(0, tonumber(b))
        layout()
        saveSettings()
    elseif sw then
        state.w, state.h = clamp(tonumber(sw), MIN_W, MAX_W), clamp(tonumber(sh), MIN_H, MAX_H)
        layout()
        saveSettings()
    elseif lower == "/reset" then
        state.x, state.y, state.w, state.h = DEFAULT_X, DEFAULT_Y, DEFAULT_W, DEFAULT_H
        layout()
        saveSettings()
    elseif string.sub(lower, 1, 3) == "/t " or string.sub(lower, 1, 4) == "!tw " then
        queuePost("/twitch", trim(string.sub(text, (string.sub(lower, 1, 1) == "/") and 4 or 5)))
    elseif string.sub(lower, 1, 8) == "/twitch " then
        queuePost("/twitch", string.sub(text, 9))
    else
        queuePost("/claude", text) -- includes /clear, which the bridge handles
    end
    state.scroll = 0
    render()
end

---------------------------------------------------------------------------
-- Commands typed in the real game chat
--
-- Your own messages starting with !tw or !c are passed to Twitch or Claude.
-- The game has already sent them to its server by then, so others in that
-- channel see them too: a Friends Chat with only you in it keeps them private.
-- Other players' messages are ignored and never leave the game.
---------------------------------------------------------------------------

local GAME_CHAT_TYPES = {
    [ChatType.PUBLIC] = true,
    [ChatType.FRIEND_CHAT] = true,
    [ChatType.CLANCHANNEL_AFFINED_CHAT] = true,
    [ChatType.CLANCHANNEL_GUEST_CHAT] = true,
    [ChatType.GROUP_SAME_TEAM] = true,
    [ChatType.GROUP_ALL] = true,
}

local CHAT_PREFIXES = { { "!tw ", "/twitch" }, { "!claude ", "/claude" }, { "!c ", "/claude" } }

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
local function stripMarkup(text)
    text = string.gsub(text, "<lt>", "\1")
    text = string.gsub(text, "<gt>", "\2")
    text = string.gsub(text, "<[^>]*>", "")
    text = string.gsub(text, "\1", "<")
    return (string.gsub(text, "\2", ">"))
end

local function onGameChat(ev)
    if not GAME_CHAT_TYPES[ev.chatType] then return end
    local me = myName()
    if not me or me == "" or simpleName(ev.senderNameSimple) ~= me then return end
    local text = trim(stripMarkup(ev.chatMessage or ""))
    local lower = string.lower(text)
    for _, p in ipairs(CHAT_PREFIXES) do
        if string.sub(lower, 1, #p[1]) == p[1] then
            local msg = trim(string.sub(text, #p[1] + 1))
            if msg ~= "" then queuePost(p[2], msg) end -- sent from Logic, not from here
            return
        end
    end
end

---------------------------------------------------------------------------
-- UI hooks
---------------------------------------------------------------------------

local function hookUI()
    ui_.input:Subscribe(ui.Hook.ONCONTENTCHANGED, function(field, reason, content)
        if reason == ui.InputFieldActionResult.SUBMIT then
            local text = content or field.content
            field.content = ""
            onSubmit(text)
        end
    end)

    ui_.mode:Subscribe(ui.Hook.ONBUTTONPRESSED, function()
        state.mode = state.mode % #MODES + 1
        state.scroll = 0
        saveSettings()
        render()
    end)

    ui_.mirror:Subscribe(ui.Hook.ONBUTTONPRESSED, function()
        if not hasChatAccess() then
            addSystem("Allow the chatAccess permission for this plugin to copy messages into game chat.")
            state.mirror = false
        else
            state.mirror = not state.mirror
        end
        saveSettings()
        render()
    end)

    ui_.collapse:Subscribe(ui.Hook.ONBUTTONPRESSED, function()
        state.collapsed = not state.collapsed
        if state.adjust and state.adjust.kind == "size" then finishAdjust() end
        layout()
        render()
    end)

    ui_.move:Subscribe(ui.Hook.ONBUTTONPRESSED, function()
        toggleAdjust("move")
        render()
    end)

    ui_.size:Subscribe(ui.Hook.ONBUTTONPRESSED, function()
        toggleAdjust("size")
        render()
    end)

    -- Mouse wheel scrolls through history.
    ui_.bg:Subscribe(ui.Hook.ONSCROLLWHEEL, function(_, delta)
        if delta < 0 then
            state.scroll = state.scroll + 3
        elseif delta > 0 then
            state.scroll = math.max(0, state.scroll - 3)
        end
        render()
    end)
end

---------------------------------------------------------------------------
-- Main loop
---------------------------------------------------------------------------

local function onLogic(ev)
    state.tick = ev.logicTick
    local changed = false

    -- Finish requests whose callbacks have fired.
    if state.poll and state.poll.done then
        handlePoll(state.poll.req)
        state.poll = nil
        changed = true -- status may have changed even with no new messages
    end
    if state.send and state.send.done then
        handleSend(state.send)
        state.send = nil
    end

    -- Start new requests (only ever from here, never from a callback).
    if #BACKENDS > 0 and not state.poll and state.tick >= state.nextPollTick then
        startPoll()
    end
    if #BACKENDS > 0 and not state.send and #state.outbox > 0 then
        startSend(table.remove(state.outbox, 1))
    end

    if updateAdjust() then changed = true end
    if changed then render() end
end

---------------------------------------------------------------------------
-- Start up / shut down
---------------------------------------------------------------------------

buildUI()
layout()
hookUI()
addSystem("Twitch & Claude Chat loaded. Type /help for commands.")
if not Plugin.HasPermission(PluginPermissions.httpAccess) then
    addSystem("This plugin needs the httpAccess permission to reach the bridge.")
end
render()

Event.Logic.Subscribe(NAME, onLogic)

-- Watching game chat needs chatAccess. If you grant it later, reload the plugin (prl).
local chatSubscribed = false
if hasChatAccess() then
    Event.ChatMessage.Subscribe(NAME, onGameChat)
    chatSubscribed = true
end

function PluginShutdown()
    -- Direct call, never pcall(Event.Logic.Unsubscribe, ...): that form aborts the client.
    Event.Logic.Unsubscribe(NAME)
    if chatSubscribed then
        Event.ChatMessage.Unsubscribe(NAME)
    end
    for _, entry in ipairs({ state.poll, state.send }) do
        if entry and entry.req and not entry.done then
            pcall(function() entry.req:Cancel() end)
        end
    end
    saveSettings()
    if ui_.root then
        pcall(function() ui_.root:Destroy() end)
        ui_.root = nil
    end
end
