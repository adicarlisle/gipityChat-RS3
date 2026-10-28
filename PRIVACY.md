# Privacy notice: gipityChat

_Last updated: 28 October 2026_

This notice explains what information the **gipityChat** RuneScape plugin handles, where it goes, and your rights.

## Who is responsible

gipityChat is made by **Adi Carlisle**. For questions about this notice or your data, email **adi.carlisle@ghostcompany.co.uk**.

The developer runs no servers for this plugin and **never receives your data**. The plugin sends data only to the AI provider you choose, using your own account and API key.

## What the plugin reads

- **Your own chat messages** that start with `!c`, `!ai`, `!chat` or `!gc`. The plugin checks that the sender is your own character. **Other players' messages are ignored and never sent anywhere.**
- Your character's display name, only to recognise your own messages. It is not sent anywhere.

## What it sends, and where

When you ask a question, the plugin sends these to the AI provider you've selected:
- your question
- up to the last 10 questions and answers from the current conversation
- a fixed instruction asking for short, plain-text answers

It's sent over an encrypted connection (HTTPS), using your API key.

| Provider | Where | Privacy policy |
|---|---|---|
| Claude (Anthropic) | United States | https://www.anthropic.com/legal/privacy |
| OpenAI | United States | https://openai.com/policies/privacy-policy |
| Gemini (Google) | United States | https://policies.google.com/privacy |
| OpenRouter | United States (forwards to the model's provider) | https://openrouter.ai/privacy |
| Mistral | France (EU) | https://mistral.ai/terms#privacy-policy |
| xAI | United States | https://x.ai/legal/privacy-policy |
| Groq | United States | https://groq.com/privacy-policy |
| Ollama / LM Studio | **Your own computer**: nothing leaves your PC | none |

The United States doesn't have full UK adequacy status for this purpose. Each provider processes your data under its own terms and privacy policy, through your own account. The developer has no access to it.

## What it stores

Stored on your computer, in the RuneScape client's plugin settings, which other plugins can't read:
- your API keys, one per provider you've set up
- your chosen provider and models

The conversation is kept in memory only and is gone when the plugin or game closes. Nothing about the game is stored.

API keys are stored as plain text in the client's settings on your computer. Use `!c /forget` to delete the current provider's key, and delete keys at the provider if you no longer use them.

## Your choices and rights

- **Don't use a provider you don't want.** Nothing is sent until you set one up and ask a question. Ollama and LM Studio keep everything on your PC.
- **Stop at any time** by disabling the plugin. Delete saved keys with `!c /forget`.
- **Data held by an AI provider:** use that provider's privacy tools or contact it directly.

Under UK data protection law you have rights over your personal data, including access, correction and deletion. Because the developer doesn't hold any of your data, most requests are best made to your AI provider. You're still welcome to contact the developer at **adi.carlisle@ghostcompany.co.uk**.

If you're unhappy with how your data is handled, you can complain to the UK Information Commissioner's Office: https://ico.org.uk/make-a-complaint/

## Changes

Any changes to this notice will be published in this file, with a new "last updated" date.
