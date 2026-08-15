# KOreader FNS Sync Plugin

English | [中文](./README.md)

Sync highlights and notes from KOreader to Obsidian via the [Fast Note Sync](https://github.com/haierkeys/fast-note-sync-service) service.

## Features

- ✨ **Auto-sync** (triggered on highlight/note edits and book close, debounced to merge consecutive operations)
- 📦 **Offline queue** (queued while offline, auto-pushed once reconnected; retry + freeze-on-failure)
- 🔄 **Bidirectional cross-device sync** (three-way merge: deleting an HL@ block in Obsidian deletes the highlight across devices; highlights created on other devices are pulled back automatically)
- 🤖 **AI reading assistant** (long-press "Ask AI" on selected text; chat via DeepSeek or any OpenAI-compatible API; add AI answers to your note right under the excerpt — cascade-deleted along with it)
- 📝 **Item-level HL@ marker** (your interleaved edits in Obsidian are preserved)
- 🎨 **Customizable templates** (excerpt / note / filename templates, color emoji, AI quick-prompt templates)
- 📚 **Cross-device sync per book** (each book can override title / author — useful for anthologies)
- 🔌 **Built on the FNS REST API** (talks to [fast-note-sync-service](https://github.com/haierkeys/fast-note-sync-service))

## Installation

1. Download the [latest release](https://github.com/xzymoon/KOreader-FNS-plugin/releases) or clone this repo
2. Copy the entire `plugin/fns_sync.koplugin/` directory into KOreader's `plugins/` folder:
   - **Kindle**: USB-connect, then copy to `<KINDLE>:/koreader/plugins/fns_sync.koplugin/`
   - **Other devices** (Android / Desktop / etc.): see the KOreader docs for the plugin path
3. Restart KOreader

## Menu Structure

Open **KOreader top menu → Tools → FNS Sync**. The menu hierarchy (`[✓]` = on, `[ ]` = off):

```
FNS Sync
├─ [✓] Enable FNS Sync
├────────────────────────
├─ [✓] Auto Sync
│   ├─ [✓] Enable Auto Sync
│   ├─ [✓] Sync on Highlight Edit
│   ├─ [✓] Sync on Book Close
│   ├─ Sync Delay (seconds)
│   └─ Bidirectional Sync (experimental)
│       ├─ [ ] Enable Bidirectional Sync
│       ├─ [ ] Auto-pull on Book Open
│       └─ Notes
├────────────────────────
├─ [✓] Offline Queue
│   ├─ [✓] Enable Offline Queue
│   ├─ Pending Queue (N books)
│   ├─ Retry Frozen Entries
│   └─ Clear Queue
├────────────────────────
├─ Sync Current Book Now
├─ Pull Remote Highlights Now
├─ Sync All History
├─ AI Assistant
│   ├─ [✓] Enable AI Chat
│   ├─ API Settings
│   │   ├─ API Service URL
│   │   ├─ API Key
│   │   ├─ Model Name
│   │   └─ System Prompt
│   ├─ Quick Templates
│   │   ├─ Translate Template
│   │   ├─ Explain Template
│   │   ├─ Comment Template
│   │   └─ Summarize Template
│   └─ Advanced Parameters
│       ├─ max_tokens
│       ├─ temperature
│       ├─ Timeout (seconds)
│       └─ Notes
├─ Test Connection
├─ Current Book Info
│   ├─ 📁 File name
│   ├─ 📖 Title: ...
│   ├─ ✍️ Author: ...
│   └─ 🔄 Reset to File Metadata
└─ Settings
    ├─ Service Connection
    │   ├─ FNS Service URL
    │   ├─ API Token
    │   └─ Vault Name
    ├─ Note Organization
    │   ├─ Note Path Prefix
    │   ├─ Note Filename Template
    │   └─ Note Template
    ├─ Excerpt Rendering
    │   ├─ [✓] Show Page Number
    │   ├─ [✓] Show Note Marker
    │   ├─ [✓] Chapter Subtitle
    │   ├─ [✓] Color to Emoji
    │   └─ Custom Excerpt Template
    ├─ Trigger Mode
    │   ├─ [✓] Sync on Highlight
    │   ├─ [✓] Sync on Book Close
    │   └─ Debounce Delay (seconds)
    └─ Advanced
        ├─ Reset Config
        └─ About
```

## Configuration

Open **KOreader top menu → Tools → FNS Sync**:

1. **Enable FNS Sync** (master switch)
2. Go to **Settings → Service Connection** and fill in:
   - **FNS service URL** (e.g. `https://fns.example.com:9000`)
   - **API token** (create it in the FNS WebGUI)
   - **Vault name**
3. Click **Test connection** to verify
4. Click **Sync current book now** for the first sync

Once enabled, highlight/note edits and book close will trigger auto-sync (5-second debounce by default).

### AI Reading Assistant (optional)

1. Prepare an **OpenAI-compatible API** ([DeepSeek](https://platform.deepseek.com) by default; other compatible services work too)
2. Go to **Tools → FNS Sync → AI Assistant → API Settings** and fill in:
   - **API service URL** (e.g. `https://api.deepseek.com`)
   - **API key**
   - **Model name** (e.g. `deepseek-chat`; note that reasoning models spend max_tokens on hidden thinking first — pair them with a larger max_tokens)
3. Check **Enable AI Chat**

Usage: select text while reading → long-press **Ask AI** → type a question (or tap a quick button: translate/explain/comment) → in the answer window you can keep asking, ask for a summary, or **Add to Note** (the AI answer is written into your note right under that excerpt; deleting the excerpt cascade-deletes the answer).

### Bidirectional Sync (optional, experimental)

Enable at **Auto Sync → Bidirectional Sync (experimental)**. Once on:

- Deleting an HL@ block in Obsidian deletes the local highlight across devices
- Highlights created on other devices are pulled back to this device automatically
- Each highlight additionally records its XPointer coordinates in the Obsidian note (privacy confirmation on first enable)

Only crengine formats are supported for pulling (EPUB/MOBI/AZW3/FB2/TXT/HTML); PDF is not.

## End-to-End Example

Highlights in KOreader are wrapped as HL@ blocks in Obsidian.

**Rendered view (reading mode)** — what the user actually sees:

![Obsidian rendered view](./docs/obsidian-hl-rendered.png)

**Source view (editing mode)** — HL@ markers and block structure are visible:

![Obsidian source view](./docs/obsidian-hl-source.png)

The areas between blocks are **safe-edit zones** — you can interleave your own thoughts (the non-highlighted text in the screenshots above), and they will be preserved on sync. The interior of HL@ blocks is overwritten on sync, so don't edit inside a block. See [plugin/fns_sync.koplugin/README.md](./plugin/fns_sync.koplugin/README.md) for details.

## Documentation

For detailed usage (HL@ block structure, Obsidian safe-edit zones, template customization, troubleshooting):
👉 [plugin/fns_sync.koplugin/README.md](./plugin/fns_sync.koplugin/README.md)

## System Requirements

- KOreader (developed against the master branch; requires the `onNetworkConnected` event)
- A deployed [fast-note-sync-service](https://github.com/haierkeys/fast-note-sync-service) server (provides the REST API + WebGUI)
- AI reading assistant (optional): any OpenAI-compatible API (DeepSeek by default)

## Privacy

Queue data (book path + title) is stored in KOreader's global config file `settings.reader.lua` under the `fns_sync_queue` field; **AI answers not yet synced** are stored under `fns_sync_pending_ai` (answer text + model name). **These do not contain FNS tokens or other sensitive credentials.** If you don't want the offline queue feature, disable it at **Tools → FNS Sync → Offline queue → Enable offline queue**.

⚠️ **The AI API key is stored in plaintext** in `settings.reader.lua` (`fns_sync.ai_api_key`), at the same trust level as the FNS api_token. KOreader's config file is plaintext on the device — encryption would only defend against USB snooping, not a stolen device; if the device is lost, revoke the key at your AI provider. With bidirectional sync enabled, each highlight's XPointer coordinates are additionally recorded in the note (reading progress can be inferred) — be aware if your vault is shared.

## Feedback & Contributing

- Server-side issues: [haierkeys/fast-note-sync-service](https://github.com/haierkeys/fast-note-sync-service)
- This plugin: open an issue / PR

## Sponsor

If this plugin helps you, buy the author a coffee:
[![Donate](https://img.shields.io/badge/PayPal-Donate-blue.svg?logo=paypal)](https://www.paypal.com/cgi-bin/webscr?cmd=_s-xclick&hosted_button_id=WTV8HNRMMMGEC)

<p align="center">
  <img src="./docs/sponsor-wechat.jpg" width="220" alt="WeChat sponsor QR" />
</p>

## Commercial Licensing

This project is licensed under the PolyForm Noncommercial License 1.0.0, permitting personal study, research, teaching, charitable, religious, and other noncommercial uses.

**Commercial use requires a separate license.** To inquire, please open a [GitHub Issue](https://github.com/xzymoon/KOreader-FNS-plugin/issues/new).

## License

[PolyForm Noncommercial 1.0.0](./LICENSE)
