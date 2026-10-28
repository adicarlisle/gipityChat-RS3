-- Minimal stand-in for the RS3 Client API, enough to run main.lua outside the game.
-- Unknown component methods/fields raise errors so typos are caught.

local function enum(t) return setmetatable(t, { __index = function(_, k) error("unknown enum value " .. tostring(k), 2) end }) end

local idCounter = 1000
id = setmetatable({}, { __index = function(_, ns)
    return setmetatable({}, { __index = function(_, name) idCounter = idCounter + 1; return idCounter end })
end })

Vector4 = { new = function(r, g, b, a) return { r = r, g = g, b = b, a = a } end }

function formatStr(fmt, ...)
    local args, i = { ... }, 0
    return (string.gsub(fmt, "{}", function() i = i + 1; return tostring(args[i]) end))
end

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
    local c = setmetatable({ _type = type_, _f = {}, _hooks = {} }, Comp)
    all[#all + 1] = c
    return c
end
for _, t in ipairs({ "Text", "Button", "InputField", "Rectangle", "GroupBox" }) do
    ui[t] = { new = function(parent) return mk(t, parent) end }
end
ui.Interfaces = { GetComponent = function(self, cid) assert(type(cid) == "number"); return mk("Root", true) end }

PluginPermissions = enum { httpAccess = 1, chatAccess = 2, trackingAccess = 3 }
local function urlValue(name)
    return setmetatable({ name = name }, { __concat = function() error("Plugin.urls values can't be concatenated") end })
end
local URLS = { firebot = urlValue("firebot"), bridge = urlValue("bridge") }
Plugin = { urls = URLS, HasPermission = function(p) assert(type(p) == "number"); return true end }

local db = {}
PersistentDB = { Get = function(self, k) return db[k] end, Set = function(self, k, v) db[k] = v end }
__mouse = { x = 100, y = 100 }
Mouse = { GetX = function() return __mouse.x end, GetY = function() return __mouse.y end }

local chatlog = {}
Chat = { AddMessage = function(m) assert(type(m) == "string"); chatlog[#chatlog + 1] = m end }

ChatType = enum { PUBLIC = 2, FRIEND_CHAT = 9, CLANCHANNEL_AFFINED_CHAT = 41, CLANCHANNEL_GUEST_CHAT = 44, GROUP_SAME_TEAM = 22, GROUP_ALL = 24, PLUGIN = 33 }
Player = { GetEntity = function() return { displayName = "Adi Rs" } end }

-- Events
local subs, chatSubs, tick = {}, {}, 0
Event = {
    Logic = {
        Subscribe = function(name, fn) subs[name] = fn end,
        Unsubscribe = function(name) subs[name] = nil end,
    },
    ChatMessage = {
        Subscribe = function(name, fn) chatSubs[name] = fn end,
        Unsubscribe = function(name) chatSubs[name] = nil end,
    },
}
function __chat(chatType, sender, msg)
    for _, fn in pairs(chatSubs) do
        fn({ chatType = chatType, senderNameSimple = sender, chatMessage = msg, senderNameFiltered = sender, senderNameUnfiltered = sender, timestamp = 0 })
    end
end

-- HTTP: performed by Python, callbacks fired on the next tick like the client does.
local pending = {}
local Req = {}
Req.__index = Req
HTTPRequest = { new = function(url, path)
    assert(url == URLS.firebot or url == URLS.bridge, "first arg must be a Plugin.urls value")
    return setmetatable({ base = rawget(url, "name"), path = path or "/", headers = {}, active = false }, Req)
end }
function Req:AddHeader(k, v) assert(not self.active, "AddHeader on active request"); self.headers[k] = v end
local function run(self, method, body, cb)
    assert(not self.active, "request already active")
    self.active = true
    local ok, code, data = py_http(method, self.base, self.path, body, self.headers)
    self.successful, self.failed, self.responseCode, self.data = ok and code == 200, not ok, code, data
    self.finished = true
    pending[#pending + 1] = function() if cb then cb(self) end end
end
function Req:Get(cb) run(self, "GET", nil, cb) end
function Req:Post(body, cb) assert(type(body) == "string"); run(self, "POST", body, cb) end
function Req:Cancel() end

-- Test hooks
function __tick()
    local p = pending; pending = {}
    for _, f in ipairs(p) do f() end
    tick = tick + 1
    for _, fn in pairs(subs) do fn({ logicTick = tick }) end
end
local function texts() local t = {} for _, c in ipairs(all) do if c._type == "Text" then t[#t + 1] = c end end return t end
local function lineTexts()
    local t = {}
    for idx, c in ipairs(texts()) do if idx > 2 and not c._f.hidden then t[#t + 1] = c end end
    return t
end
function __nlines() return #lineTexts() end
function __line(i) local c = lineTexts()[i]; return c and (c.content or "") or "" end
function __root() for _, c in ipairs(all) do if c._type == "GroupBox" then return c._f end end end
function __status() return texts()[2].content or "" end
local function find(type_, pred) for _, c in ipairs(all) do if c._type == type_ and pred(c) then return c end end end
function __submit(text)
    local f = find("InputField", function() return true end)
    f.content = text
    f._hooks[ui.Hook.ONCONTENTCHANGED](f, ui.InputFieldActionResult.SUBMIT, text)
    assert(f.content == "", "input cleared")
end
local order = { move = 1, mirror = 2, mode = 3, collapse = 4, size = 5 }
function __press(which)
    local n = 0
    local b = find("Button", function() n = n + 1; return n == order[which] end)
    b._hooks[ui.Hook.ONBUTTONPRESSED](b, 1, 0)
end
function __chatlog() return chatlog end
function __subs() local n = 0 for _ in pairs(subs) do n = n + 1 end for _ in pairs(chatSubs) do n = n + 1 end return n end
