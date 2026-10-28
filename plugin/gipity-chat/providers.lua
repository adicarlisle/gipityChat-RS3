-- The AI providers this plugin can talk to.
--
-- Jagex requires every web address a plugin uses to be listed in plugin.json
-- ("urls"), so providers are a fixed list here rather than free-form URLs.
-- Each entry:
--   id          what you type with /provider
--   name        shown in the window
--   url         key in plugin.json "urls"
--   path        API path for chat requests
--   format      "anthropic" (Messages API) or "openai" (Chat Completions)
--   needsKey    false for apps running on your own PC
--   model       default model ("" means you must choose one with /model)
--   keyFrom     where to get a key, or how to get started

local providers = {
    {
        id = "claude", name = "Claude", url = "anthropic", path = "/v1/messages", format = "anthropic",
        needsKey = true, model = "claude-haiku-5-5",
        keyFrom = "console.anthropic.com (Settings > API keys)",
        examples = "claude-haiku-5-5, claude-sonnet-5-5, claude-opus-5-5",
    },
    {
        id = "openai", name = "OpenAI", url = "openai", path = "/v1/chat/completions", format = "openai",
        needsKey = true, model = "gpt-5.4-mini",
        keyFrom = "platform.openai.com (API keys)",
        examples = "gpt-5.4-mini, gpt-5.5, chat-latest",
    },
    {
        id = "gemini", name = "Gemini", url = "gemini", path = "/v1beta/openai/chat/completions", format = "openai",
        needsKey = true, model = "gemini-flash-latest",
        keyFrom = "aistudio.google.com (Get API key)",
        examples = "gemini-flash-latest, gemini-pro-latest",
    },
    {
        id = "openrouter", name = "OpenRouter", url = "openrouter", path = "/api/v1/chat/completions", format = "openai",
        needsKey = true, model = "openrouter/auto",
        keyFrom = "openrouter.ai (Keys) - one key for models from many companies",
        examples = "openrouter/auto, or any model id from openrouter.ai/models",
    },
    {
        id = "mistral", name = "Mistral", url = "mistral", path = "/v1/chat/completions", format = "openai",
        needsKey = true, model = "mistral-small-latest",
        keyFrom = "console.mistral.ai (API keys)",
        examples = "mistral-small-latest, mistral-medium-latest, mistral-large-latest",
    },
    {
        id = "xai", name = "xAI", url = "xai", path = "/v1/chat/completions", format = "openai",
        needsKey = true, model = "",
        keyFrom = "console.x.ai (API keys)",
        examples = "see docs.x.ai for current Grok model names",
    },
    {
        id = "groq", name = "Groq", url = "groq", path = "/openai/v1/chat/completions", format = "openai",
        needsKey = true, model = "openai/gpt-oss-120b",
        keyFrom = "console.groq.com (API keys)",
        examples = "openai/gpt-oss-120b, or see console.groq.com/docs/models",
    },
    {
        id = "ollama", name = "Ollama", url = "ollama", path = "/v1/chat/completions", format = "openai",
        needsKey = false, model = "",
        keyFrom = "ollama.com - runs models on your own PC, no key needed",
        examples = "any model you've pulled, e.g. llama3.2 (run: ollama list)",
    },
    {
        id = "lmstudio", name = "LM Studio", url = "lmstudio", path = "/v1/chat/completions", format = "openai",
        needsKey = false, model = "",
        keyFrom = "lmstudio.ai - runs models on your own PC; start its local server",
        examples = "the model id shown in LM Studio's Developer tab",
    },
}

-- Aliases accepted by /provider.
local ALIASES = { anthropic = "claude", chatgpt = "openai", gpt = "openai", google = "gemini",
    grok = "xai", ["lm-studio"] = "lmstudio", lms = "lmstudio", ["local"] = "ollama" }

local byId = {}
for _, p in ipairs(providers) do byId[p.id] = p end

function providers.find(id)
    id = string.lower(id or "")
    return byId[ALIASES[id] or id]
end

function providers.ids()
    local ids = {}
    for _, p in ipairs(providers) do ids[#ids + 1] = p.id end
    return table.concat(ids, ", ")
end

return providers
