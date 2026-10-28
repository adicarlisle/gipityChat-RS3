# mod.io listing: Twitch & Claude Chat

Paste the fields below into mod.io. The one thing left for you is the **EULA** sentence: copy it word for word from https://developer.runescape.com/rs/submission/example.html (EULA section), because it has to match exactly.

---

**Name:** Twitch & Claude Chat

**Summary:** A movable chat window that shows your Twitch stream chat inside RuneScape and lets you ask Claude, an AI assistant, questions without leaving the game. Works with Firebot, or the free RS3 Chat Bridge app.

**Tags:** HttpAccess, chatAccess (plus a category such as Utility)

**Listing image:** `listing-image.png` (in this folder). A real in-game screenshot is better if you have one.

---

## Description (paste everything below this line)

### What it does
Twitch & Claude Chat adds a small window to your screen. You can move it, resize it and collapse it. It shows:
- **Your Twitch chat**, live, with each chatter's name colour.
- **Claude**, an AI assistant made by Anthropic. Type a question in the window and press Enter. Claude can also see your recent Twitch chat, so you can ask things like "what is chat asking about?"

You can reply to your Twitch chat from inside the game too:
- In the plugin window: `/t your message`
- In the normal game chat: `!tw your message`, or `!c your question` to ask Claude

The plugin does **not** play the game for you or look at other players. It only reads game chat to spot **your own** messages that start with `!tw` or `!c`; everyone else's messages are ignored.

### What you need (read this first)
The plugin can't connect to Twitch by itself, so it uses a program on your own computer that already does. It finds one automatically.

**If you stream with Firebot:**
1. Add our free Firebot startup script: https://github.com/adicarlisle/twitch-claude-chat/blob/main/firebot/README.md
2. For Claude, enter a Claude API key from https://console.anthropic.com in the script's settings in Firebot. Claude is a paid service, charged by Anthropic per message.

**If you don't use Firebot:**
1. Download the free RS3 Chat Bridge app for Windows, macOS or Linux: https://github.com/adicarlisle/twitch-claude-chat/releases/latest
2. Open it, enter your Twitch channel and Claude API key, and click **Start bridge**.

Then install this plugin from the Plugin Hub and allow its permissions. If neither Firebot nor the bridge is running, the window says **no Firebot or bridge found**.

Full guide: https://github.com/adicarlisle/twitch-claude-chat#readme

### How to use it
- **Move:** click **Move**, move the mouse, click again. **Size** works the same way. You can also type `/move x y`, `/size w h` or `/reset`.
- **All / Twitch / Claude** button: choose which messages to show.
- **In-game** button: also copy messages into your normal chatbox. Only you can see them.
- Commands: `/help`, `/t <message>`, `/clear` (new Claude conversation), `/cls` (clear the window).
- Tip: game chat goes to the game server, so others in that channel see your `!tw` and `!c` messages. Use a Friends Chat channel with only you in it to keep them private.

### Email
adi.carlisle@ghostcompany.co.uk

### Feedback and collaboration
Feedback, bug reports and ideas are welcome in this plugin's channel in the RuneScape Plugin Portal Discord, by email at adi.carlisle@ghostcompany.co.uk, or as an issue at https://github.com/adicarlisle/twitch-claude-chat/issues. For collaboration, get in touch through any of these.

### EULA
[Paste the exact EULA statement from the example page here. It begins "This Plugin uses software licensed by Jagex to the developer under the terms of the Jagex End User Licence Agreement (EULA)" and links to https://legal.jagex.com/docs/terms/eula]

### Permissions

#### HttpAccess
Used only to talk to programs on your own computer: Firebot with our script at `http://127.0.0.1:7472`, or the RS3 Chat Bridge app at `http://127.0.0.1:8787`. The plugin sends them:
- the text you type into the plugin's window, to pass on to Claude or your Twitch chat
- your own `!tw` / `!c` game chat messages (see chatAccess)
- requests for new messages to show

No game information is sent.

#### chatAccess
Optional. Used for two things:
- **In-game button:** copies of the window's messages are added to your own chatbox with `Chat.AddMessage`. Only you see them, and they aren't sent to the game server.
- **Chat commands:** spotting **your own** chat messages that start with `!tw` (send to Twitch) or `!c` (ask Claude). The plugin checks that the sender is your own character. Other players' messages are ignored and never sent anywhere.

#### Combine permissions
With both permissions, your own `!tw` / `!c` messages are passed to Firebot or the bridge on your computer through HttpAccess, and Twitch and Claude messages can be shown in your chatbox. Other players' chat is never read for any purpose or sent anywhere.

### Data Protection (case 3)
The plugin itself only sends data to your own computer (127.0.0.1). The Firebot script or the bridge app then sends:
- what you ask Claude, plus up to the last 25 messages from your Twitch chat as context, to **Anthropic** (United States), using your own API key
- your `/t` and `!tw` messages, and your Twitch token, to **Twitch** (United States)

It also reads your channel's public Twitch chat.

- **Privacy notice:** https://github.com/adicarlisle/twitch-claude-chat/blob/main/PRIVACY.md
- **Security:** the Firebot script and the bridge only accept requests from the game on your own computer, and traffic to Anthropic and Twitch is encrypted (HTTPS/TLS). Keys are stored on your computer: in Firebot's settings, or in the bridge's settings file, readable only by your user account.
- **Who can access the data:** the developer never receives any data. Anthropic and Twitch process it under their own terms and privacy policies.
- **Data rights requests:** adi.carlisle@ghostcompany.co.uk

---

## Submission checklist
- [ ] Create the listing on mod.io (RuneScape page → **Add plugin**). Keep it **hidden** until ready.
- [ ] Paste in the name, summary, tags and description above, with the exact EULA sentence filled in.
- [ ] Upload `twitch-claude-chat-0.2.0.zip` from the GitHub Release. Tick **Source** and all platforms (Windows, Linux, Android, iOS). Set version `0.2.0`.
- [ ] Submit, then fill in Jagex's adequacy exception form (data goes to the US). It asks for your name, address and data protection contact.
