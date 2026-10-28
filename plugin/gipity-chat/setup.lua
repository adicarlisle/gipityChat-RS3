-- The API key box: the plugin's only UI.
--
-- Keys must never be typed into game chat (chat goes to the game server and other
-- players), so this small box appears on first use or with "!c /setup", takes the
-- pasted key, and closes.
--
-- The key is visible while it's in the box: the client blanks the contents of
-- masked (password-style) input fields for plugins, so a masked box can't be read.

local setup = {}

local W, H = 420, 112
local PAD = 8

local root = nil -- the open box, if any

local function rgba(r, g, b, a) return Vector4.new(r, g, b, a) end

function setup.close()
    if root then
        local r = root
        root = nil
        pcall(function() r:Destroy() end)
    end
end

-- opts: { title, hint, current (masked current key or nil), onSave(key) }
function setup.open(opts)
    setup.close()
    local parent = ui.Interfaces:GetComponent(id.Component.TOPLEVEL_V2__PLUGIN_BUILD_LAYER_TOP)

    root = ui.GroupBox.new(parent)
    root.stylesheetID = id.StyleSheet.DEFAULT
    root:SetHeaderLayout(0, 0, 0, 0, 0)
    root:SetSize(W, H)
    root:SetPos(-W / 2, -H / 2, 0.5, 0.35) -- centred horizontally, a bit above the middle

    local bg = ui.Rectangle.new(root)
    bg:SetPos(0, 0)
    bg:SetSize(W, H)
    bg.fill = true
    bg.colour = rgba(0.06, 0.05, 0.04, 0.95)
    bg.clickthrough = false

    local title = ui.Text.new(root)
    title.font = id.Font.MUSEO_SANS_13PT_BOLD
    title.colour = rgba(0.85, 0.47, 0.34, 1)
    title.isShadowed = true
    title.maxLines = 1
    title:SetPos(PAD, PAD)
    title:SetSize(W - 2 * PAD, 18)
    title.content = opts.title

    local hint = ui.Text.new(root)
    hint.font = id.Font.VERDANA_11PT_REGULAR
    hint.colour = rgba(0.85, 0.85, 0.85, 1)
    hint.isShadowed = true
    hint.maxLines = 2
    hint:SetPos(PAD, PAD + 20)
    hint:SetSize(W - 2 * PAD, 30)
    local current = opts.current and (" Current: " .. opts.current .. ".") or ""
    hint.content = opts.hint .. current .. "<br>Hide this from your stream: the key shows while you paste it."

    local input = ui.InputField.new(root)
    input.stylesheetID = id.StyleSheet.INPUT_DEFAULT
    input.emptyText = "Paste your API key here, then press Enter or Save"
    input:SetPos(PAD, PAD + 54)
    input:SetSize(W - 2 * PAD - 120, 26)

    local save = ui.Button.new(root)
    save.stylesheetID = id.StyleSheet.BUTTON_DEFAULT
    save.label = "Save"
    save:SetPos(W - PAD - 112, PAD + 54)
    save:SetSize(54, 26)

    local cancel = ui.Button.new(root)
    cancel.stylesheetID = id.StyleSheet.BUTTON_DEFAULT
    cancel.label = "Cancel"
    cancel:SetPos(W - PAD - 54, PAD + 54)
    cancel:SetSize(54, 26)

    local function submit(value)
        local key = string.gsub(value or "", "%s", "") -- pasted keys often carry spaces/newlines
        input.content = ""
        if key == "" then return end
        setup.close()
        opts.onSave(key)
    end

    input:Subscribe(ui.Hook.ONCONTENTCHANGED, function(field, reason, content)
        if reason == ui.InputFieldActionResult.SUBMIT then
            submit(content or field.content)
        elseif reason == ui.InputFieldActionResult.SUBMIT_ON_ESCAPE then
            setup.close()
        end
    end)
    save:Subscribe(ui.Hook.ONBUTTONPRESSED, function() submit(input.content) end)
    cancel:Subscribe(ui.Hook.ONBUTTONPRESSED, function() setup.close() end)
end

function setup.isOpen()
    return root ~= nil
end

return setup
