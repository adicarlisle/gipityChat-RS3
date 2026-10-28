# mod.io listing draft: Twitch & Claude Chat

Fill in everything in [square brackets]. Copy the EULA sentence word for word from
https://developer.runescape.com/rs/submission/example.html, because it has to match exactly.

---

**Name** (max 50): Twitch & Claude Chat

**Summary** (10–250): A movable chat window that shows your Twitch stream chat inside RuneScape and lets you ask Claude, an AI assistant, questions without leaving the game. Needs a small companion program running on your PC.

**Tags:** HttpAccess, chatAccess (plus any category tags such as Utility/Streaming)

---

## Description

### What it does
Twitch & Claude Chat adds a small window to your screen that you can move around and collapse. It shows:
- **Your Twitch chat**, live, with each chatter's name colour.
- **Claude**, an AI assistant made by Anthropic. Type a question in the window's box and press Enter. Claude can also see your recent Twitch chat, so you can ask things like "what is chat asking about?"

You can also reply to your Twitch chat from inside the game with `/t your message` in the window, or `!tw your message` in the normal game chat. `!c your question` in game chat asks Claude.

The plugin does **not** play the game for you or look at other players. It only reads game chat to spot **your own** messages that start with `!tw` or `!c`; everyone else's messages are ignored.

### What you need (read this first)
The plugin can't connect to Twitch or Claude by itself, so it talks to a small free companion program, the **bridge**, that runs on your own computer.

1. Download the bridge from [GitHub link] and install Python 3 from python.org.
2. Get a Claude API key from console.anthropic.com. Claude is a paid service, charged by Anthropic for each message.
3. Start the bridge: `python3 bridge.py --channel yourtwitchname` (full steps at [GitHub link]).
4. Install this plugin from the Plugin Hub and allow its permissions.

If the bridge isn't running, the window says **bridge offline** and nothing else happens.

### How to use it
- Drag the title bar to move the window. Use the mouse wheel to scroll back.
- **All / Twitch / Claude** button: choose which messages to show.
- **In-game** button: also copy messages into your normal chatbox. Only you can see them; nothing is sent to other players.
- **Move** / **Size** buttons: click, move the mouse, click again.
- Commands: `/help`, `/t <message>` (send to Twitch), `/clear` (new Claude conversation), `/cls` (clear the window).
- In normal game chat: `!tw <message>` and `!c <question>`. Tip: use a Friends Chat with only you in it so other players don't see these.

### Feedback and collaboration
Feedback and bug reports are welcome in this plugin's channel in the RuneScape Plugin Portal Discord, or by email at [contact email]. For collaboration, get in touch through either.

### EULA
[Paste the exact statement from the example page. It begins: "This Plugin uses software licensed by Jagex to the developer under the terms of the Jagex End User Licence Agreement" and links to https://legal.jagex.com/docs/terms/eula]

### Permissions

#### HttpAccess
Used to talk to the bridge program on your own computer, at `http://127.0.0.1:8787` only. The plugin sends:
- the text you type into the plugin's window (to pass on to Claude or to your Twitch chat)
- requests asking for new messages to show

It does not send any game information.

#### chatAccess
Optional. Used for two things:
- When you turn on the **In-game** button, copies of the window's messages are added to your own chatbox with `Chat.AddMessage`. Only you can see them, and they aren't sent to the game server.
- Spotting **your own** chat messages that start with `!tw` (send to Twitch) or `!c` (ask Claude), so you can use the normal chatbox. The plugin checks that the sender is your own character. Other players' messages are ignored and never sent anywhere. Note that game chat goes to the game server before the plugin sees it, so others in that channel see your `!tw`/`!c` messages too.

#### How the permissions work together
HttpAccess fetches Twitch and Claude messages from the bridge and sends your questions to it. With chatAccess, your own `!tw`/`!c` chat messages are sent to the bridge the same way, and the window's messages can be copied into your chatbox. Other players' chat is never sent anywhere.

### Data protection
[Data protection case 3]
The plugin itself only sends data to your own computer (127.0.0.1). The companion bridge then sends:
- what you type to Claude (in the window or with `!c`) to **Anthropic** (United States), using your own API key
- your `/t` and `!tw` messages to **Twitch** (United States)

It reads your public Twitch chat from Twitch.

- **Privacy notice:** [link to your privacy notice; the ICO has a generator]
- **Security:** the bridge only accepts connections from your own computer, and all traffic to Anthropic and Twitch is encrypted (HTTPS/TLS).
- **Who can access data:** the developer never receives any data. Anthropic and Twitch process it under their own terms and privacy policies.
- **Data rights requests:** [contact email]

---

## Before you press submit
- [ ] Put your real contact email in `plugin.json` (`contactEmailAddress`) and above. Use one that's different from your mod.io login, then rebuild the zip.
- [ ] Test it in the beta client and replace the mockup image with a real screenshot.
- [ ] Publish the bridge publicly (for example on GitHub) so moderators and players can get it.
- [ ] Fill in the Jagex adequacy exception form after submitting (needed because data goes to the US).
- [ ] Upload: tick Source plus Windows, Linux, Android and iOS. Set version `0.1.0`, matching `plugin.json`.
- [ ] Keep the listing **hidden** until you're ready.
