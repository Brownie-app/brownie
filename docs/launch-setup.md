# Launch setup — founder-only accounts and keys

Everything here is something only you can create. Put the values in `.secrets/brownie.env` (git-ignored). Debug builds read it; release builds never do — users enter keys in Settings → Brain and they live in Keychain.

| Need | Where to get it | Env var(s) | Blocks |
|---|---|---|---|
| OpenAI API key | platform.openai.com → API keys | `OPENAI_API_KEY` | Brain = ChatGPT/OpenAI (default); KB build, cards, Hands |
| Anthropic API key | console.anthropic.com | `ANTHROPIC_API_KEY` | Brain = Claude |
| OpenRouter key | openrouter.ai/keys | `OPENROUTER_API_KEY` | Brain = OpenRouter |
| Google OAuth client (Desktop app) | console.cloud.google.com → APIs & Services → Credentials; enable Gmail API + Calendar API; OAuth consent screen (External, Testing is fine for you) | `GOOGLE_OAUTH_CLIENT_ID`, `GOOGLE_OAUTH_CLIENT_SECRET` | Gmail and Calendar sources |
| Telegram app | my.telegram.org → API development tools | `TELEGRAM_API_ID`, `TELEGRAM_API_HASH` | Telegram source |
| Slack app | api.slack.com/apps → OAuth & Permissions: user scopes `channels:history channels:read groups:history groups:read im:history im:read mpim:history mpim:read users:read users:read.email`; redirect URL `https://www.usebrownie.com/oauth/slack` (the page bounces to `brownie://oauth/slack`) | `SLACK_CLIENT_ID`, `SLACK_CLIENT_SECRET` | Slack source (users can also paste a user token) |
| Microsoft Entra app | entra.microsoft.com → App registrations → multi-tenant, platform "Mobile and desktop", redirect `http://localhost`; delegated permissions User.Read, Chat.Read, ChannelMessage.Read.All, Team.ReadBasic.All, Channel.ReadBasic.All, offline_access | `MICROSOFT_CLIENT_ID` (PKCE, no secret) | Teams source |
| Apple Developer Program ($99/yr) | developer.apple.com | `APPLE_TEAM_ID`, `APPLE_SIGNING_IDENTITY`, `APPLE_ID`, `APPLE_APP_SPECIFIC_PASSWORD` | Notarised DMG, wake helper as a proper daemon, distributing to anyone |
| Xcode (free, ~12 GB) | Mac App Store | — | Metal shader compiler, proper .app packaging, TCC-friendly signing. Command Line Tools work for `swift build`; Xcode is needed before shipping. |
| Domain | any registrar | — | appcast URL for updates, website |
| Sparkle keys | `Scripts/sparkle-keys.sh` (generated locally) | `SPARKLE_PRIVATE_KEY` | Signed auto-updates |

Not needed: a Hugging Face token (the Gemma 4 E4B `.litertlm` files are public), any Brownie server (v1 has none), any analytics account (off by default).
