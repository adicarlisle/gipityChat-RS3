-- Minimal stand-in for the RS3 Client API, enough to run the plugin outside the game.
-- Unknown component methods/fields raise errors so typos are caught.
-- The test sets PLUGIN_DIR and py_http before loading this file.

local function enum(t) return setmetatable(t, { __index = function(_, k) error("unknown enum value " .. tostring(k), 2) end }) end

local idCounter = 1000
id = setmetatable({}, { __index = function(_, ns)
    return setmetatable({}, { __index = function(_, name) idCounter = idCounter + 1; return idCounter end })
end })

Vector4 = { new = function(r, g, b, a) return { r = r, g = g, b = b, a = a } end }

-- fmtlib-style "{}" placeholders, like the client's formatStr.
function formatStr(fmt, ...)
    local args, i = { ... }, 0
    return (string.gsub(fmt, "{}", function() i = i + 1; return tostring(args[i]) end))
end

-- The client resolves require() relative to the plugin folder.
local loaded = {}
function require(name)
    if loaded[name] == nil then
        local f = assert(io.open(PLUGIN_DIR .. "/" .. name .. ".lua", "r"))
        local src = f:read("a"); f:close()
        loaded[name] = assert(load(src, "=" .. name))() or true
    end
    return loaded[name]
end

-- UI components (only what setup.lua uses)
ui = {}
ui.Hook = enum { ONBUTTONPRESSED = 49, ONCONTENTCHANGED = 50, ONCLICK = 0, ONRELEASE = 2, ONHOLD = 3, ONSCROLLWHEEL = 9 }
ui.InputFieldActionResult = enum { NONE = -1, ERROR = 1, CONTENT_CHANGE = 0, SUBMIT = 2, SUBMIT_ON_ESCAPE = 3, SUBMIT_ON_FOCUS_LOSS = 4 }
ui.InputFieldKeyHandlingMode = enum { DEFAULT = 0, CHAT = 1 }
ui.AlignMode = enum { CENTRE = 1, LEFT = 0 }

local FIELDS = {
    common = { hidden = 1, colour = 1, clickthrough = 1, stylesheetID = 1, alpha = 1, enabled = 1 },
    Text = { content = 1, font = 1, maxLines = 1, isShadowed = 1, alignVertical = 1, alignHorizontal = 1 },
    Button = { label = 1 },
    InputField = { content = 1, inputMode = 1, emptyText = 1 },
    Rectangle = { fill = 1, outlineThickness = 1 },
    GroupBox = {}, Root = {},
}
local all = {}
local Comp = {}
Comp.__index = function(self, k)
    local m = rawget(Comp, k)
    if m then return m end
    local f = rawget(self, "_f")
    if f[k] ~= nil then return f[k] end
    if FIELDS.common[k] or FIELDS[rawget(self, "_type")][k] then return nil end
    error("unknown member " .. rawget(self, "_type") .. "." .. tostring(k), 2)
end
Comp.__newindex = function(self, k, v)
    if not (FIELDS.common[k] or FIELDS[rawget(self, "_type")][k]) then
        error("unknown field " .. rawget(self, "_type") .. "." .. tostring(k), 2)
    end
    rawget(self, "_f")[k] = v
end
function Comp.SetPos(self, x, y) rawget(self, "_f").x = x; rawget(self, "_f").y = y end
function Comp.SetSize(self, w, h) rawget(self, "_f").w = w; rawget(self, "_f").h = h end
function Comp.SetHeaderLayout(self, ...) assert(select("#", ...) == 5) end
function Comp.Subscribe(self, hook, cb) assert(type(hook) == "number" and type(cb) == "function"); rawget(self, "_hooks")[hook] = cb end
function Comp.Destroy(self) rawset(self, "_destroyed", true) end

local function mk(type_, parent)
    assert(parent, type_ .. " needs a parent")
    assert(not rawget(parent, "_destroyed"), "parent destroyed")
    local c = setmetatable({ _type = type_, _f = {}, _hooks = {}, _parent = parent }, Comp)
    all[#all + 1] = c
    return c
end
for _, t in ipairs({ "Text", "Button", "InputField", "Rectangle", "GroupBox" }) do
    ui[t] = { new = function(parent) return mk(t, parent) end }
end
local rootLayer = setmetatable({ _type = "Root", _f = {}, _hooks = {} }, Comp)
ui.Interfaces = { GetComponent = function(self, cid) assert(type(cid) == "number"); return rootLayer end }

ChatType = enum { PUBLIC = 2, FRIEND_CHAT = 9, CLANCHANNEL_AFFINED_CHAT = 41, CLANCHANNEL_GUEST_CHAT = 44,
    GROUP_SAME_TEAM = 22, GROUP_ALL = 24, PLUGIN = 33 }
Player = { GetEntity = function() return { displayName = "Adi Rs" } end }

-- Permissions; tests can flip these.
PluginPermissions = enum { httpAccess = 1, chatAccess = 2, trackingAccess = 3 }
__perms = { [1] = true, [2] = true }

-- Plugin.urls values are opaque userdata in the client: only HTTPRequest.new accepts them.
local function urlValue(name)
    return setmetatable({ name = name }, { __concat = function() error("Plugin.urls values can't be concatenated") end })
end
local URLS = {}
for _, n in ipairs({ "anthropic", "openai", "gemini", "openrouter", "mistral", "xai", "groq", "ollama", "lmstudio" }) do
    URLS[n] = urlValue(n)
end
Plugin = { urls = URLS, HasPermission = function(p) assert(type(p) == "number"); return __perms[p] == true end }

__db = {}
PersistentDB = { Get = function(self, k) return __db[k] end, Set = function(self, k, v) __db[k] = v end }
Mouse = { GetX = function() return 100 end, GetY = function() return 100 end }

-- Chat: AddMessage lines are recorded, and (like the client) fire ChatMessage as PLUGIN type.
__chatlog = {}
local chatSubs, logicSubs, tick = {}, {}, 0
local queuedPluginLines = {}
Chat = { AddMessage = function(m)
    assert(type(m) == "string")
    __chatlog[#__chatlog + 1] = m
    queuedPluginLines[#queuedPluginLines + 1] = m
end }

Event = {
    Logic = {
        Subscribe = function(name, fn) logicSubs[name] = fn end,
        Unsubscribe = function(name) logicSubs[name] = nil end,
    },
    ChatMessage = {
        Subscribe = function(name, fn) chatSubs[name] = fn end,
        Unsubscribe = function(name) chatSubs[name] = nil end,
    },
}

local function fireChat(chatType, sender, msg)
    for _, fn in pairs(chatSubs) do
        fn({ chatType = chatType, senderNameSimple = sender, chatMessage = msg, senderNameFiltered = sender,
             senderNameUnfiltered = sender, timestamp = 0 })
    end
end

function __chat(chatType, sender, msg) fireChat(chatType, sender, msg) end

-- HTTP: performed by Python, callbacks fired on the next tick like the client does.
local pending = {}
local Req = {}
Req.__index = Req
HTTPRequest = { new = function(url, path)
    assert(type(url) == "table" and rawget(url, "name"), "first arg must be a Plugin.urls value")
    return setmetatable({ base = rawget(url, "name"), path = path or "/", headers = {}, active = false }, Req)
end }
function Req:AddHeader(k, v) assert(not self.active, "AddHeader on active request"); self.headers[k] = v end
function Req:Post(body, cb)
    assert(type(body) == "string")
    assert(not self.active, "request already active")
    self.active = true
    local ok, code, data, timedOut = py_http("POST", self.base, self.path, body, self.headers)
    self.responseCode, self.data = code, data
    self.successful = ok and code >= 200 and code < 300
    self.failed = not ok
    self.timedOut = timedOut == true
    self.errorInfo = ok and "" or data
    self.finished = true
    pending[#pending + 1] = function() if cb then cb(self) end end
end
function Req:Get() error("not used") end
function Req:Cancel() end

-- Test hooks
function __tick()
    local p = pending; pending = {}
    for _, f in ipairs(p) do f() end
    local lines = queuedPluginLines; queuedPluginLines = {}
    for _, m in ipairs(lines) do fireChat(ChatType.PLUGIN, "", m) end
    tick = tick + 1
    for _, fn in pairs(logicSubs) do fn({ logicTick = tick }) end
end
function __subs() local n = 0 for _ in pairs(logicSubs) do n = n + 1 end for _ in pairs(chatSubs) do n = n + 1 end return n end
local function live(type_)
    local out = {}
    for _, c in ipairs(all) do
        local alive, p = not rawget(c, "_destroyed"), rawget(c, "_parent")
        while alive and p and p ~= rootLayer do alive = not rawget(p, "_destroyed"); p = rawget(p, "_parent") end
        if alive and c._type == type_ then out[#out + 1] = c end
    end
    return out
end
function __setupOpen() return #live("InputField") > 0 end
function __setupText() local t = {} for _, c in ipairs(live("Text")) do t[#t + 1] = c.content or "" end return table.concat(t, " | ") end
function __pasteKey(key)
    local f = live("InputField")[1]
    f.content = key
    f._hooks[ui.Hook.ONCONTENTCHANGED](f, ui.InputFieldActionResult.SUBMIT, key)
end
function __pressButton(label)
    for _, b in ipairs(live("Button")) do
        if b.label == label then return b._hooks[ui.Hook.ONBUTTONPRESSED](b, 1, 0) end
    end
    error("no button " .. label)
end
