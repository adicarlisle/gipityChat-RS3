# gipityChat for RuneScape 3

Ask an AI questions from the normal RS3 chatbox while you play.

```
You:     !c what do I need for the Kalphite Queen?
Claude:  Bring a Dramen staff, prayer potions and food, and stay at range...
```

- Type `!c your question` in chat (`!ai`, `!chat` and `!gc` work too). The answer appears in your chatbox, **visible only to you**.
- **Claude** is the default. You can switch to OpenAI, Gemini, OpenRouter (hundreds of models), Mistral, xAI or Groq, or run models **on your own PC** with Ollama or LM Studio.
- It's just the plugin: no extra app. Ask in chat, and change settings in a small panel (`!c /settings`).
- It only reads **your own** chat messages. Other players' messages are ignored and never sent anywhere.

Built on Jagex's official [RuneScape Client Plugin API](https://developer.runescape.com/rs/).

## Install (plugin beta)

Unmoderated plugins only run on the **plugin beta** client. With Steam, add this launch option:
`%command% --configURI rs-launch://world204.runescape.com/jav_config_beta.ws`

1. Download `gipity-chat-<version>.zip` from [Releases](https://github.com/adicarlisle/gipityChat-RS3/releases/latest) and unzip it into a folder called `gipity-chat` inside the beta client's `dev_plugins` folder. Create `dev_plugins` if needed. Typical locations:
   - Windows: `C:\ProgramData\Jagex\RuneScape-BETA\dev_plugins\gipity-chat`
   - Steam on Linux: `~/.local/share/Steam/steamapps/common/RuneScape/RuneScape-BETA/dev_plugins/gipity-chat`
2. In game, open the console with **Alt + `** and run:
   ```
   prf
   pon gipity-chat
   ppr gipity-chat
   ppe gipity-chat chatAccess
   ppe gipity-chat httpAccess
   ```
3. The settings panel opens. Get an API key from [console.anthropic.com](https://console.anthropic.com/settings/keys), paste it into **API key** and press **Save**.
4. In chat: `!c hello`

## Settings

Open the panel with `!c /settings`. It also opens by itself on first use, or whenever a key or model is missing.

| Section | Setting | What it does |
|---|---|---|
| AI | Provider | Claude, OpenAI, Gemini, OpenRouter, Mistral, xAI, Groq, Ollama, LM Studio (use the `<` `>` buttons) |
| | Model | Model name for that provider (examples are shown under the box) |
| | API key | Paste a new key to replace the saved one (shown masked). **Forget** deletes it. |
| Chat | Trigger words | The words that start a question, separated by spaces (default `!c !ai !chat !gc`). Each must start with a symbol like `!` or `?`. |
| Answers | Reply length | Short / Medium / Long |
| | Memory | How many previous exchanges the AI remembers: off, 3, 5, 10 or 20 |
| | Instructions | Your own extra instructions, e.g. "answer like a wise old wizard" or "assume I'm an ironman" |
| Display | Reply name | Name shown before answers (empty = the provider's name) |
| | Colour | Colour of that name |
| | Line length | How long each chatbox line can be before it wraps |

**Defaults** resets everything except provider, model and key. Keys and models are saved separately for each provider.

## Chat commands

| Command | What it does |
|---|---|
| `!c QUESTION` | Ask |
| `!c /settings` | Open the settings panel |
| `!c /provider NAME` | Quick switch, e.g. `!c /provider openai` (`!c /provider` lists them) |
| `!c /model NAME` | Quick model change |
| `!c /new` | Start a new conversation |
| `!c /forget` | Delete the saved key for the current provider |
| `!c /help` | Show help in chat |

If you change your trigger words, use them instead of `!c`.

### Privacy in chat
Your `!c` message is normal game chat: it goes to Jagex's servers and everyone in that channel sees it. Only the **answer** is private. To keep your questions private, make a **Friends Chat channel with only you in it** and ask there.

**Never type an API key in chat.** If you try (`!c /key ...`), the plugin refuses to save it, tells you to replace the key, and opens the settings panel instead.

## Your API key: is it safe?

- **Where it's stored:** in the RS client's plugin settings (`PersistentDB`) on your computer. Jagex isolates each plugin's settings, so other plugins can't read it. It's stored as plain text, though, so anything that can read your files could read it, just like keys kept by most desktop apps.
- **When it's visible:** while you paste it into the settings panel, because the client doesn't let plugins read masked password fields. Hide the game from your stream while you do this. After that, the plugin only ever shows a masked version (`sk-ant-...wXyZ`).
- **Where it goes:** only to the provider you chose, over HTTPS, in the request header that provider requires. Never to the developer or anywhere else.
- **Good habits:** use a key just for this plugin, set a monthly spend limit in your provider's console, and delete the key there if you ever think it's leaked. `!c /forget` removes it from your PC.

## Providers

| Provider | Default model | Key from |
|---|---|---|
| Claude (Anthropic) | `claude-haiku-5-5` | console.anthropic.com |
| OpenAI | `gpt-5.4-mini` | platform.openai.com |
| Gemini (Google) | `gemini-flash-latest` | aistudio.google.com |
| OpenRouter | `openrouter/auto` | openrouter.ai: one key for models from many companies |
| Mistral | `mistral-small-latest` | console.mistral.ai |
| xAI | (set in settings) | console.x.ai |
| Groq | `openai/gpt-oss-120b` | console.groq.com |
| Ollama | (set in settings) | none: runs on your PC (`http://127.0.0.1:11434`) |
| LM Studio | (set in settings) | none: runs on your PC (`http://127.0.0.1:1234`) |

Model names change often. If a default stops working, set a current one in `!c /settings`. Jagex requires every web address a plugin uses to be listed in `plugin.json`, so adding a provider means adding it to `plugin.json` and `providers.lua`.

## How it's built

| File | Purpose |
|---|---|
| `plugin/gipity-chat/main.lua` | Reads your `!c` messages, sends requests, writes answers to the chatbox |
| `plugin/gipity-chat/providers.lua` | The provider list (URLs, request format, default models) |
| `plugin/gipity-chat/ai.lua` | Builds requests (Anthropic or OpenAI format) and reads replies and errors |
| `plugin/gipity-chat/json.lua` | Small JSON encoder and decoder (the game's Lua has none) |
| `plugin/gipity-chat/text.lua` | Converts replies to text the game can draw (accents folded, emoji dropped, markdown removed), escapes RS markup, wraps long lines |
| `plugin/gipity-chat/settings.lua` | The settings panel |

## Tests and releases

`test/plugin_test.py` runs the real plugin files in Lua 5.4 against a stand-in for the RS3 API (`test/stubs.lua`) and a mock AI provider, checking requests, replies, errors, commands, the settings panel and key handling (`pip install lupa`, then `python test/plugin_test.py`). Nothing has been tested in the real game client yet.

GitHub Actions runs the tests on every push. When the `version` in `plugin.json` changes on `main`, it publishes a Release with the plugin zip, ready for mod.io (`main.lua` and `plugin.json` at the top level of the zip).

See also: [PRIVACY.md](PRIVACY.md) · [modio/LISTING.md](modio/LISTING.md)
