-- Builds chat requests for each provider format and reads the replies.
--
-- Two request formats cover every provider in providers.lua:
--   "anthropic": Claude's Messages API (x-api-key header, system as a field)
--   "openai":    Chat Completions, used by OpenAI and most others
--               (Authorization: Bearer header, system as the first message)
--
-- This module only builds and parses; main.lua sends the HTTP requests, because
-- requests must be started from the Logic event (see the notes in main.lua).

local json = require("json")

local ai = {}

ai.SYSTEM_PROMPT = [[You are a helpful assistant chatting with a RuneScape 3 player through a small chat window inside the game client while they play.

Keep replies short: usually 1-3 sentences, never more than about 80 words, because they are shown in a narrow in-game chat box. Plain text only - no markdown, no bullet points, no headings, no code blocks, no emoji.

Be helpful with RuneScape 3 questions (skilling, bossing, quests, money making, mechanics), but say so when you're unsure, since game details change with updates and you can't look things up. You can't see the game or take any action in it.]]

ai.MAX_TOKENS = 400

-- Reply-length settings: wording added to the instructions, and Claude's token cap.
ai.LENGTHS = {
    short = { label = "Short", tokens = 200, words = "usually 1-2 sentences, never more than about 50 words" },
    medium = { label = "Medium", tokens = 400, words = "usually 1-3 sentences, never more than about 80 words" },
    long = { label = "Long", tokens = 800, words = "a short paragraph when needed, never more than about 160 words" },
}

-- The system prompt for a reply length plus the player's own instructions.
function ai.systemPrompt(length, instructions)
    local l = ai.LENGTHS[length] or ai.LENGTHS.medium
    local s = string.gsub(ai.SYSTEM_PROMPT, "usually 1%-3 sentences, never more than about 80 words", l.words)
    if instructions and instructions ~= "" then
        s = s .. "\n\nThe player's own instructions for you: " .. instructions
    end
    return s
end

-- Returns { path, headers = {{name, value}...}, body } for one request.
-- `history` is a list of { role = "user"|"assistant", content = "..." }.
-- `opts` (optional): { system = prompt text, maxTokens = number }
function ai.buildRequest(provider, apiKey, model, history, opts)
    opts = opts or {}
    local system = opts.system or ai.SYSTEM_PROMPT
    local headers = { { "Content-Type", "application/json" } }
    local body
    if provider.format == "anthropic" then
        headers[#headers + 1] = { "x-api-key", apiKey or "" }
        headers[#headers + 1] = { "anthropic-version", "2023-06-01" }
        body = {
            model = model,
            max_tokens = opts.maxTokens or ai.MAX_TOKENS,
            system = system,
            messages = history,
        }
    else
        if apiKey and apiKey ~= "" then
            headers[#headers + 1] = { "Authorization", "Bearer " .. apiKey }
        end
        local messages = { { role = "system", content = system } }
        for _, m in ipairs(history) do messages[#messages + 1] = m end
        -- No token limit here: providers disagree on the parameter's name, and the
        -- system prompt already asks for short answers.
        body = { model = model, messages = messages }
    end
    return { path = provider.path, headers = headers, body = json.encode(body) }
end

-- Plain-English explanation for common HTTP failures.
local function explainStatus(code, provider)
    if code == 400 then return "the request was rejected (check the model name in !c /settings)" end
    if code == 401 or code == 403 then return "the API key was rejected - set it again in !c /settings" end
    if code == 402 then return "your account is out of credit" end
    if code == 404 then return "model not found - set a valid one in !c /settings (" .. provider.examples .. ")" end
    if code == 408 or code == 504 then return "the request timed out - try again" end
    if code == 429 then return "rate limited or out of quota - wait a moment, or check your plan" end
    if code == 500 or code == 502 or code == 503 or code == 529 then return provider.name .. " is busy or down - try again shortly" end
    return nil
end

-- Pulls an error message out of a JSON error body, if there is one.
local function errorMessage(data)
    if type(data) ~= "table" then return nil end
    local e = data.error
    if type(e) == "table" and type(e.message) == "string" then return e.message end
    if type(e) == "string" then return e end
    if type(data.message) == "string" then return data.message end
    return nil
end

-- Reads a finished HTTPRequest. Returns reply text, or nil and an error message.
function ai.parseResponse(provider, req)
    if req.timedOut then
        return nil, provider.name .. " didn't answer in time - try again"
    end
    if not req.successful and (req.responseCode or 0) == 0 then
        if not provider.needsKey then
            return nil, "couldn't reach " .. provider.name .. " - is it running on this PC?"
        end
        return nil, "couldn't reach " .. provider.name .. " (" .. tostring(req.errorInfo or "network error") .. ")"
    end
    local data = json.decode(req.data or "")
    local code = req.responseCode or 0
    if code < 200 or code >= 300 then
        local detail = errorMessage(data)
        local plain = explainStatus(code, provider)
        local msg = "HTTP " .. code .. (plain and (": " .. plain) or "")
        if detail and detail ~= "" then msg = msg .. " (" .. detail .. ")" end
        return nil, msg
    end
    if type(data) ~= "table" then
        return nil, "unexpected reply from " .. provider.name
    end
    local textOut
    if provider.format == "anthropic" then
        local parts = {}
        for _, block in ipairs(data.content or {}) do
            if type(block) == "table" and block.type == "text" and type(block.text) == "string" then
                parts[#parts + 1] = block.text
            end
        end
        textOut = table.concat(parts)
    else
        local choice = type(data.choices) == "table" and data.choices[1]
        local message = type(choice) == "table" and choice.message
        local content = type(message) == "table" and message.content
        if type(content) == "string" then
            textOut = content
        elseif type(content) == "table" then -- some providers return a list of parts
            local parts = {}
            for _, p in ipairs(content) do
                if type(p) == "table" and type(p.text) == "string" then parts[#parts + 1] = p.text end
            end
            textOut = table.concat(parts)
        end
    end
    if not textOut or textOut == "" then
        local detail = errorMessage(data)
        return nil, detail or (provider.name .. " sent an empty reply")
    end
    return textOut
end

return ai
