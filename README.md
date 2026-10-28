# Twitch & Claude Chat for RuneScape 3

A movable chat window inside the RS3 client that shows your Twitch chat live and lets you talk to Claude from the same box. You can also reply to Twitch with `/t`, and copy lines into the normal game chatbox, where only you can see them.

```
 Twitch IRC ──►┐
               ├──► bridge.py (127.0.0.1:8787) ◄── polls / POSTs ── RS3 plugin (Lua)
 Claude API ◄─►┘
```

**Why two parts?** The official Client Plugin API only gives plugins plain HTTP `GET`/`POST` to URLs declared in `plugin.json`. Plugins get no WebSockets or sockets, and there's no safe place in a plugin for an API key. So a small local program, `bridge.py`, holds the Twitch connection and your Anthropic key, and the plugin polls it twice a second. The bridge is Python 3.9+ and uses only the standard library.

## Setup

### 1. Run the bridge

**Easiest: the desktop app.** Download `RS3ChatBridge` for your system from this repo's **Releases** page, then open it:
- **Windows:** unzip and run `RS3ChatBridge.exe`. SmartScreen may warn because the app isn't code-signed; click **More info → Run anyway**.
- **macOS:** unzip and open `RS3ChatBridge.app`. Because it isn't signed, the first time you need to right-click it and choose **Open**.
- **Linux:** extract `RS3ChatBridge-Linux.tar.gz`, then run `RS3ChatBridge` (in the Files app: right-click → **Run as a Program**). Click **Add to app menu** once, and from then on you can open it from your app grid like any other app.

In the window:
1. Fill in your Twitch channel and your Anthropic API key. **Get key…** opens the Anthropic console.
2. Optionally add a Twitch token so `/t` and `!tw` can post to chat. **Get token…** walks you through it.
3. Click **Start bridge**. The dots show the Bridge, Twitch, Claude and the in-game Plugin as each connects.
4. **Install plugin into RS3…** copies the plugin into your beta client's `dev_plugins` folder.

Tick **Remember token and key** to save them in your user settings folder; they're stored unencrypted, readable only by your user. The box at the bottom lets you test Claude or Twitch without opening the game.

**From source:** with Python 3.9+, run `python bridge/bridge_gui.py`, or use one of the launchers: `Start Bridge (Windows).bat`, `Start Bridge (Mac).command`, or `start-bridge.sh` on Linux. On Ubuntu you need `sudo apt install python3-tk` first. On macOS use Python from python.org, because Apple's built-in Python has a broken Tk.

**Command line, no window:**
```bash
export ANTHROPIC_API_KEY=sk-ant-...
export TWITCH_OAUTH=xxxxxxxx          # optional, for sending to Twitch
python3 bridge/bridge.py --channel yourtwitchname
```

| Option | Default | |
|---|---|---|
| `--channel` | – | Twitch channel to read. Leave it out to use Claude only. |
| `--model` | `claude-haiku-5-5` | `claude-sonnet-5-5` gives better answers but is a bit slower. |
| `--port` | `8787` | Must match `urls.bridge` in `plugin.json`. |
| `--charset` | `ascii` | Folds accents and drops emoji the game fonts can't draw. Use `utf8` to pass text through unchanged. |

### 2. Install the plugin (plugin beta)

Unmoderated plugins only run on the **plugin beta** client.

1. Copy the `plugin/twitch-claude-chat` folder into `dev_plugins` under the beta data folder. Create `dev_plugins` if it doesn't exist. It has to be a real folder copy; symlinks aren't loaded.
   - Windows: `C:\ProgramData\Jagex\RuneScape-BETA\dev_plugins\twitch-claude-chat`
   - macOS: `~/Jagex/RuneScape-BETA/dev_plugins/twitch-claude-chat`
2. In game, open the console with **Alt + `** and run:
   ```
   prf
   pon twitch-claude-chat
   ppr twitch-claude-chat
   ppe twitch-claude-chat httpAccess
   ppe twitch-claude-chat chatAccess
   ```
   `chatAccess` is optional. It's only needed for the **Game chat** button.
3. After editing `main.lua`, run `prl twitch-claude-chat` to reload.

## Using it

- Type in the box and press **Enter** to ask Claude. Claude also sees the last ~25 Twitch messages, so "what's chat asking about?" works.
- `/t <message>` (or `!tw <message>`) in the window's box sends a message to your Twitch chat.
- **From the real game chat:** type `!tw <message>` to send to Twitch or `!c <question>` to ask Claude. This needs `chatAccess`. Others in that chat channel will see the message, so use a Friends Chat channel with only you in it to keep it private. Only your own messages are acted on.
- `/clear` starts a new Claude conversation. `/cls` clears the window. `/mode` (or the **All** button) cycles through All, Twitch and Claude. `/help` lists the commands.
- **Move:** click **Move** in the title bar, move the mouse, then click it again (it says **Done**) to drop the window.
- **Resize:** same with the **Size** button next to the input box. Lines re-wrap to the new width.
- If either button misbehaves, type `/move x y`, `/size w h` or `/reset`. Position and size are saved.
- Use the mouse wheel to scroll back. **-** collapses the window to its title bar and **+** opens it again; reloading the plugin always opens it.
- **In-game** copies new Twitch and Claude lines into the real chatbox using `Chat.AddMessage`. Only you can see them; they aren't sent to the server.

## CI/CD

`.github/workflows/ci.yml` runs on every push and pull request:
1. **test**: lints, runs the plugin and bridge end-to-end test against mock Twitch and Claude servers, and smoke-tests the desktop app on a virtual screen (screenshots are uploaded as an artifact).
2. **build**: builds the desktop app for Windows, macOS and Linux with PyInstaller (`build.py`).
3. **release** (pushes to `main`): if the `version` in `plugin/twitch-claude-chat/plugin.json` has no GitHub Release yet, it tags `v<version>` and publishes a Release with the three apps plus the mod.io plugin zip.

To release, bump `version` in `plugin.json` and push to `main`. Pushes that don't change the version just build and test.

`modio/` has the mod.io listing text and image, and `PRIVACY.md` is the privacy notice the listing links to.

## Notes and limits

- **Tested against a stubbed API, not in a live client.** `test/harness.py` runs the real bridge against a mock Twitch IRC server and a mock Claude API, then runs `main.lua` in Lua 5.4 with stand-ins for the RS3 API (`pip install lupa`, then `python test/harness.py`). The things most likely to need tweaking in the real client are Move/Size (they use the mouse position, which may not match interface units if UI scaling is on), the wrap width estimate (`CHAR_WIDTH` in `main.lua`), and the font, stylesheet and colour choices.
- Lines use RS `<col=rrggbb>` tags for name colours. Any `<`/`>` in chat text is escaped as `<lt>`/`<gt>`, so chatters can't inject tags like `<img=…>`.
- **Security.** The bridge only listens on 127.0.0.1. It refuses any request that doesn't send `X-RS3-Bridge: 1` or that does send an `Origin` header, which stops a web page in your browser from using your Claude credits.
- **Submitting to mod.io.** A plugin that needs a separately run local program pointed at `127.0.0.1` isn't something Jagex moderation has clear rules on yet. Treat this as a personal/beta plugin for now. If you do submit it, the guidelines expect you to have reviewed and understood all code, AI-assisted included.
- The plugin only looks at game chat to spot your own `!tw`/`!c` messages. Other players' messages are ignored and nothing about them leaves the game, which keeps it clear of the "no exporting other players' info" rule.
