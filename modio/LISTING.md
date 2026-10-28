# mod.io listing: gipityChat

Paste the fields below into mod.io. The one thing left for you is the **EULA** sentence: copy it word for word from https://developer.runescape.com/rs/submission/example.html (EULA section), because it has to match exactly.

---

**Name:** gipityChat

**Summary:** Ask an AI (Claude, ChatGPT, Gemini and more) questions from your RuneScape chatbox with !c. Answers show only to you. Uses your own API key; nothing else to install.

**Tags:** HttpAccess, chatAccess (plus a category such as Utility)

**Listing image:** a screenshot of a `!c` question and its answer in the chatbox.

---

## Description (paste everything below this line)

### What it does
Type `!c` and a question in the normal game chat, for example:

`!c what do I need for the Kalphite Queen?`

The answer appears in your chatbox. Only you can see it. Follow-up questions remember the last few exchanges.

- **Claude** (by Anthropic) is the default. You can switch to OpenAI, Google Gemini, OpenRouter, Mistral, xAI or Groq, or use AI models running on your own PC with Ollama or LM Studio.
- There's nothing else to install. You ask in chat; a small settings panel (`!c /settings`) lets you choose the AI, model, trigger words, answer length, memory, custom instructions, and how answers look.
- It only reads **your own** messages that start with `!c` (or `!ai`, `!chat`, `!gc`). Other players' messages are ignored.

It doesn't play the game for you, and it can't see the game. It just answers questions.

### Getting started
1. Get an API key from your AI provider. For Claude: https://console.anthropic.com. AI providers charge per message. Local models (Ollama, LM Studio) are free and need no key.
2. Install this plugin and allow its permissions.
3. The settings panel opens: paste your key and click **Save**. Hide the game from your stream while you do this, because the key is visible while you paste it.
4. Ask: `!c hello`

### Commands
- `!c QUESTION`: ask
- `!c /settings`: provider, model, API key (never type keys in chat), trigger words, answer style, display
- `!c /provider NAME` and `!c /model NAME`: quick switches
- `!c /new`: new conversation
- `!c /forget`: delete the saved key
- `!c /help`: help

### Keep your questions private
Your `!c` message is normal game chat, so others in that chat channel can see your question. Only the answer is private. To keep questions private, make a Friends Chat channel with only you in it and ask there.

Full guide: https://github.com/adicarlisle/twitch-claude-chat#readme

### Email
adi.carlisle@ghostcompany.co.uk

### Feedback and collaboration
Feedback, bug reports and ideas are welcome in this plugin's channel in the RuneScape Plugin Portal Discord, by email at adi.carlisle@ghostcompany.co.uk, or as an issue at https://github.com/adicarlisle/twitch-claude-chat/issues. For collaboration, get in touch through any of these.

### EULA
[Paste the exact EULA statement from the example page here. It begins "This Plugin uses software licensed by Jagex to the developer under the terms of the Jagex End User Licence Agreement (EULA)" and links to https://legal.jagex.com/docs/terms/eula]

### Permissions

#### chatAccess
Used for two things:
- **Reading your own questions:** the plugin looks for chat messages from **your own character** that start with your trigger words (`!c`, `!ai`, `!chat` or `!gc` by default). Every other message, including all other players' chat, is ignored and never stored or sent anywhere.
- **Showing answers:** answers are added to your chatbox with `Chat.AddMessage`. Only you can see them, and they aren't sent to the game server.

#### HttpAccess
Used only to send your question to the AI provider you've chosen and receive the answer. The addresses are listed in the plugin's manifest:
- Anthropic: `api.anthropic.com`
- OpenAI: `api.openai.com`
- Google: `generativelanguage.googleapis.com`
- OpenRouter: `openrouter.ai`
- Mistral: `api.mistral.ai`
- xAI: `api.x.ai`
- Groq: `api.groq.com`
- Ollama and LM Studio: `127.0.0.1`, your own computer

Only one provider is used at a time, whichever you selected. No game information is sent.

#### Combine permissions
chatAccess finds your own `!c` questions and shows the answers. HttpAccess sends each question to your chosen AI provider. Other players' chat is never read for any purpose or sent anywhere.

### Data Protection (case 3)
When you ask a question, the plugin sends your question and the recent conversation to the AI provider you selected:
- Anthropic, OpenAI, Google, OpenRouter, xAI and Groq are in the United States.
- Mistral is in the EU.
- Ollama and LM Studio run on your own computer.

- **Privacy notice:** https://github.com/adicarlisle/twitch-claude-chat/blob/main/PRIVACY.md
- **Security:** requests use encrypted connections (HTTPS). API keys are stored only on your computer, in the client's per-plugin settings, and are never shown in chat (only a masked version). Keys typed into chat by mistake are refused and not saved.
- **Who can access the data:** the developer never receives any data. Each AI provider processes it under its own terms and privacy policy, using your account.
- **Data rights requests:** adi.carlisle@ghostcompany.co.uk

---

## Submission checklist
- [ ] Create the listing on mod.io (RuneScape page → **Add plugin**). Keep it **hidden** until ready.
- [ ] Paste in the name, summary, tags and description above, with the exact EULA sentence filled in.
- [ ] Upload `gipity-chat-0.4.0.zip` from the GitHub Release. Tick **Source** and all platforms (Windows, Linux, Android, iOS). Set version `0.4.0`.
- [ ] Submit, then fill in Jagex's adequacy exception form (data can go to the US). It asks for your name, address and data protection contact.
