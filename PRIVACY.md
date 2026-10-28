# Privacy notice: Twitch & Claude Chat

_Last updated: 28 October 2026_

This notice explains what information the **Twitch & Claude Chat** RuneScape plugin and its companion **RS3 Chat Bridge** app handle, where that information goes, and your rights.

## Who is responsible

Twitch & Claude Chat is made by **Adi Carlisle**. For questions about this notice or your data, email **adi.carlisle@ghostcompany.co.uk**.

The developer runs no servers for this plugin and **never receives your data**. Everything below happens on your own computer, or between your computer and the services you choose to connect (Anthropic and Twitch), using your own accounts and keys.

## What the plugin does with data

The plugin runs inside the RuneScape client. It sends data **only to the bridge app on your own computer** (`http://127.0.0.1:8787`). It does not send anything over the internet itself.

It sends the bridge:
- **What you type into the plugin's window**, so it can be passed to Claude or to your Twitch chat.
- **Your own game chat messages that start with `!tw` or `!c`**. It checks that the sender is your own character; other players' messages are ignored and never sent anywhere.
- **Requests for new messages** to display. These contain no personal data.

The plugin stores **window position, size and display options** using the RuneScape client's plugin settings storage, on your computer. It doesn't store chat messages or any game information between sessions.

## What the bridge app does with data

The bridge runs on your computer and only accepts connections from your computer.

| Data | Sent to | Why |
|---|---|---|
| Questions you ask Claude, plus up to the last 25 messages from your Twitch chat as context | **Anthropic** (Claude API), United States | To get Claude's reply |
| Messages you send with `/t` or `!tw` | **Twitch**, United States | To post them in your Twitch chat |
| Your Twitch token | **Twitch**, United States | To check it and log in to your chat |
| Your Twitch channel name | **Twitch**, United States | To read your channel's public chat |

The bridge **reads your channel's public Twitch chat** so it can show it in the game. This includes chatters' display names and messages, which are already public on Twitch.

The bridge keeps messages **in memory only** while it's running (up to the most recent 1,000). They're gone when you close it.

If you tick **Remember token and key**, your Anthropic API key and Twitch token are saved in a settings file in your user folder. They aren't encrypted, but the file is readable only by your user account. Untick the box to stop saving them; the saved copies are then removed from the file.

## Anthropic and Twitch

Anthropic and Twitch process the data you send them under their own terms and privacy policies, using your own accounts:
- Anthropic: https://www.anthropic.com/legal/privacy
- Twitch: https://www.twitch.tv/p/legal/privacy-notice/

Both are in the **United States**, which doesn't have full UK adequacy status for this purpose. Data is sent to them over encrypted connections (HTTPS/TLS). The developer has no access to it.

## Why it's processed

Data is processed only to provide the features you turn on and use: showing your Twitch chat in game, asking Claude questions, and posting to your Twitch chat. The plugin and bridge contain no analytics, tracking or advertising.

## Your choices and rights

- **Don't connect a service you don't want to use.** Without an Anthropic key, nothing is sent to Anthropic. Without a Twitch channel and token, nothing is sent to Twitch.
- **Stop at any time.** Close the bridge app, or disable the plugin in the RuneScape client.
- **Delete local data.** Remove the bridge's settings file (its location is shown in the app) and the plugin's settings.
- **Data held by Anthropic or Twitch:** use their privacy tools or contact them directly.

Under UK data protection law you have rights over your personal data, including access, correction and deletion. Because the developer doesn't hold any of your data, most requests are best made to Anthropic or Twitch. You're still welcome to contact the developer with any question or request at **adi.carlisle@ghostcompany.co.uk**.

If you're unhappy with how your data is handled, you can complain to the UK Information Commissioner's Office: https://ico.org.uk/make-a-complaint/

## Changes

Any changes to this notice will be published in this file, with a new "last updated" date.
