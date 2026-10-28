# Firebot setup

Use this instead of the RS3 Chat Bridge app if you already stream with [Firebot](https://firebot.app). Firebot keeps your Twitch connection, and this script lets the RuneScape plugin read and send chat through it.

You need Firebot 5.6x or newer, logged in to your Twitch account.

1. Download `rs3-twitch-claude-chat.js` from the [latest release](https://github.com/adicarlisle/twitch-claude-chat/releases/latest).
2. In Firebot, go to **Settings → Scripts → Manage Startup Scripts → Add New Script**.
3. Firebot shows you where its scripts folder is. Put `rs3-twitch-claude-chat.js` in that folder, then pick it from the list.
4. In the script's settings:
   - **Anthropic API key**: from [console.anthropic.com](https://console.anthropic.com). Leave it empty if you only want Twitch chat.
   - **Claude model**: Haiku is quickest; Sonnet gives better answers.
   - **Send /t messages as the bot account**: off sends them as you.
5. Save. You don't need to restart Firebot.

In game, the plugin finds Firebot by itself. Its status line starts with **Firebot:** and the window says **Connected via Firebot.** If Firebot isn't running, the plugin looks for the bridge app instead.

## Notes
- The plugin expects Firebot's web server on its default port, **7472**.
- The script only answers requests from the RS3 client on this computer. Requests from your local network or from web pages are refused, because Firebot's server is reachable on your network and allows web pages to call it.
- The Anthropic key is stored in Firebot's own settings, on your computer.
- Twitch emotes are shown highlighted, and spam like `LUL LUL LUL LUL` is collapsed to `LUL x4`. Whispers and messages held by AutoMod are never shown.
