-- The settings panel (opened with "!c /settings", and on first use).
--
-- Asking still happens in game chat; this panel is only for configuration:
-- provider, model and API key, trigger words, answer style and display.
--
-- Choices use "<  value  >" buttons rather than dropdowns, which keeps the panel
-- simple and reliable inside a plugin window.
--
-- The API key box shows the key while you paste it: the client blanks masked
-- (password-style) input fields for plugins, so a masked box can't be read.

local settings = {}

local W = 470
local PAD = 10
local LABEL_W = 120
local ROW_H = 28
local HEAD_H = 22
local CTRL_X = PAD + LABEL_W
local CTRL_W = W - CTRL_X - PAD

local root = nil
settings.controls = {} -- named controls, so tests can drive the panel

local function rgba(r, g, b, a) return Vector4.new(r, g, b, a) end

local function hex(h)
    local r, g, b = tonumber(string.sub(h, 1, 2), 16), tonumber(string.sub(h, 3, 4), 16), tonumber(string.sub(h, 5, 6), 16)
    return rgba(r / 255, g / 255, b / 255, 1)
end

function settings.close()
    if root then
        local r = root
        root = nil
        settings.controls = {}
        pcall(function() r:Destroy() end)
    end
end

function settings.isOpen()
    return root ~= nil
end

-- Builds the panel.
-- opts = {
--   values   = current values (see main.lua's currentSettings),
--   choices  = { providers = {...}, lengths = {...}, memories = {...}, colours = {...}, lineLengths = {...} },
--   keyLabel = function(providerId) -> "sk-ant-...wXyZ" or "not set" or "not needed",
--   modelFor = function(providerId) -> saved model for that provider,
--   defaults = values to load with the Defaults button,
--   onSave   = function(newValues, newKey or nil),
--   onForgetKey = function(providerId),
-- }
function settings.open(opts)
    settings.close()
    local parent = ui.Interfaces:GetComponent(id.Component.TOPLEVEL_V2__PLUGIN_BUILD_LAYER_TOP)
    local v = {}
    for k, val in pairs(opts.values) do v[k] = val end
    local c = {}
    settings.controls = c

    root = ui.GroupBox.new(parent)
    root.stylesheetID = id.StyleSheet.DEFAULT
    root:SetHeaderLayout(0, 0, 0, 0, 0)

    local bg = ui.Rectangle.new(root)
    bg.fill = true
    bg.colour = rgba(0.06, 0.05, 0.04, 0.96)
    bg.clickthrough = false

    local y = PAD

    local function newText(s, font, colour)
        local t = ui.Text.new(root)
        t.font = font or id.Font.VERDANA_11PT_REGULAR
        t.colour = colour or rgba(0.9, 0.9, 0.9, 1)
        t.isShadowed = true
        t.maxLines = 1
        t.alignVertical = ui.AlignMode.CENTRE
        t.content = s
        return t
    end

    local function newButton(label, x, w, h)
        local b = ui.Button.new(root)
        b.stylesheetID = id.StyleSheet.BUTTON_DEFAULT
        b.label = label
        b:SetPos(x, y + 1)
        b:SetSize(w, h or (ROW_H - 4))
        return b
    end

    local function heading(s)
        local t = newText(s, id.Font.MUSEO_SANS_13PT_BOLD, rgba(0.85, 0.47, 0.34, 1))
        t:SetPos(PAD, y)
        t:SetSize(W - 2 * PAD, HEAD_H)
        y = y + HEAD_H
    end

    local function label(s)
        local t = newText(s)
        t:SetPos(PAD, y)
        t:SetSize(LABEL_W - 6, ROW_H)
        return t
    end

    local function input(name, lbl, value, emptyText, width)
        label(lbl)
        local f = ui.InputField.new(root)
        f.stylesheetID = id.StyleSheet.INPUT_DEFAULT
        f.content = value or ""
        f.emptyText = emptyText or ""
        f:SetPos(CTRL_X, y + 1)
        f:SetSize(width or CTRL_W, ROW_H - 4)
        c[name] = f
        y = y + ROW_H
        return f
    end

    -- A "<  value  >" chooser over `list` (array of { id, label }), stored in v[key].
    local function chooser(name, lbl, list, key, onChange)
        label(lbl)
        local idx = 1
        for i, item in ipairs(list) do
            if item.id == v[key] then idx = i end
        end
        local prev = newButton("<", CTRL_X, 26)
        local nxt = newButton(">", CTRL_X + CTRL_W - 26, 26)
        local shown = newText("")
        shown:SetPos(CTRL_X + 30, y)
        shown:SetSize(CTRL_W - 60, ROW_H)
        shown.alignHorizontal = ui.AlignMode.CENTRE
        local function show()
            local item = list[idx]
            v[key] = item.id
            shown.content = item.label
            if onChange then onChange(item) end
        end
        prev:Subscribe(ui.Hook.ONBUTTONPRESSED, function() idx = (idx - 2) % #list + 1; show() end)
        nxt:Subscribe(ui.Hook.ONBUTTONPRESSED, function() idx = idx % #list + 1; show() end)
        c[name] = { prev = prev, next = nxt, text = shown }
        y = y + ROW_H
        return show
    end

    -- Title
    local title = newText("gipityChat settings", id.Font.MUSEO_SANS_15PT_BOLD, rgba(0.85, 0.47, 0.34, 1))
    title:SetPos(PAD, y)
    title:SetSize(W - 2 * PAD, 24)
    y = y + 28

    -- AI ------------------------------------------------------------------
    heading("AI")
    local model, key
    local showProvider = chooser("provider", "Provider", opts.choices.providers, "provider", function(item)
        -- Switching provider shows that provider's own model and key.
        if model then model.content = opts.modelFor(item.id) end
        if key then
            key.content = ""
            key.emptyText = "current: " .. opts.keyLabel(item.id) .. " - paste a new key to replace"
        end
        if c.examples then c.examples.content = item.examples or "" end
    end)
    model = input("model", "Model", "", "model name")
    local examples = newText("", id.Font.VERDANA_11PT_REGULAR, rgba(0.6, 0.6, 0.6, 1))
    examples:SetPos(CTRL_X, y - 6)
    examples:SetSize(CTRL_W, 16)
    c.examples = examples
    y = y + 12
    key = input("key", "API key", "", "", CTRL_W - 66)
    local forgetY = y
    y = y - ROW_H
    local forget = newButton("Forget", W - PAD - 62, 62)
    y = forgetY
    c.forget = forget
    showProvider() -- fill model, key hint and examples for the current provider

    -- Chat ------------------------------------------------------------------
    heading("Chat")
    input("triggers", "Trigger words", v.triggers, "e.g. !c !ai")

    -- Answers -----------------------------------------------------------------
    heading("Answers")
    local showLength = chooser("length", "Reply length", opts.choices.lengths, "length")
    local showMemory = chooser("memory", "Memory", opts.choices.memories, "memory")
    input("instructions", "Instructions", v.instructions, "optional, e.g. answer like a wise old wizard")

    -- Display -------------------------------------------------------------------
    heading("Display")
    input("replyName", "Reply name", v.replyName, "empty = provider name (e.g. Claude)")
    local showColour = chooser("colour", "Colour", opts.choices.colours, "colour", function(item)
        c.colour.text.colour = hex(item.id)
    end)
    local showLine = chooser("lineLength", "Line length", opts.choices.lineLengths, "lineLength")
    showLength(); showMemory(); showColour(); showLine()

    -- Buttons ---------------------------------------------------------------------
    y = y + 6
    local note = newText("Hide your stream while pasting a key.", id.Font.VERDANA_11PT_REGULAR, rgba(0.6, 0.6, 0.6, 1))
    note:SetPos(PAD, y)
    note:SetSize(200, ROW_H)
    local defaults = newButton("Defaults", W - PAD - 228, 72)
    local cancel = newButton("Cancel", W - PAD - 150, 70)
    local save = newButton("Save", W - PAD - 74, 74)
    c.defaults, c.cancel, c.save = defaults, cancel, save
    y = y + ROW_H + PAD

    -- Size the panel to fit, centred a little above the middle of the screen.
    root:SetSize(W, y)
    root:SetPos(-W / 2, -y / 2, 0.5, 0.45)
    bg:SetPos(0, 0)
    bg:SetSize(W, y)

    -- Actions ---------------------------------------------------------------------
    local function collect()
        local out = {}
        for k, val in pairs(v) do out[k] = val end
        out.model = model.content or ""
        out.triggers = c.triggers.content or ""
        out.instructions = c.instructions.content or ""
        out.replyName = c.replyName.content or ""
        return out
    end

    local function doSave()
        local newKey = string.gsub(key.content or "", "%s", "") -- pasted keys often carry spaces/newlines
        key.content = ""
        local values = collect()
        settings.close()
        opts.onSave(values, newKey ~= "" and newKey or nil)
    end
    save:Subscribe(ui.Hook.ONBUTTONPRESSED, doSave)
    cancel:Subscribe(ui.Hook.ONBUTTONPRESSED, function() settings.close() end)
    forget:Subscribe(ui.Hook.ONBUTTONPRESSED, function()
        opts.onForgetKey(v.provider)
        key.content = ""
        key.emptyText = "current: " .. opts.keyLabel(v.provider) .. " - paste a new key to replace"
    end)
    defaults:Subscribe(ui.Hook.ONBUTTONPRESSED, function()
        local d = opts.defaults
        c.triggers.content = d.triggers
        c.instructions.content = d.instructions
        c.replyName.content = d.replyName
        v.length, v.memory, v.colour, v.lineLength = d.length, d.memory, d.colour, d.lineLength
        -- Re-open with defaults for the choosers but keep the provider and model.
        local keep = collect()
        keep.length, keep.memory, keep.colour, keep.lineLength = d.length, d.memory, d.colour, d.lineLength
        keep.triggers, keep.instructions, keep.replyName = d.triggers, d.instructions, d.replyName
        local o = {}
        for k2, val in pairs(opts) do o[k2] = val end
        o.values = keep
        settings.open(o)
    end)
    -- Enter in the key box saves too.
    key:Subscribe(ui.Hook.ONCONTENTCHANGED, function(_, reason)
        if reason == ui.InputFieldActionResult.SUBMIT then doSave() end
    end)
end

return settings
