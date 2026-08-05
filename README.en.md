# KOreader FNS Sync Plugin

English | [中文](./README.md)

Sync highlights and notes from KOreader to Obsidian via the [Fast Note Sync](https://github.com/haierkeys/fast-note-sync-service) service.

## Features

- ✨ **Auto-sync** (triggered on highlight/note edits and book close, debounced to merge consecutive operations)
- 📦 **Offline queue** (queued while offline, auto-pushed once reconnected; retry + freeze-on-failure)
- 📝 **Item-level HL@ marker** (your interleaved edits in Obsidian are preserved)
- 🎨 **Customizable templates** (excerpt / note / filename templates, color emoji)
- 📚 **Cross-device sync per book** (each book can override title / author — useful for anthologies)
- 🔄 **Built on the FNS REST API** (talks to [fast-note-sync-service](https://github.com/haierkeys/fast-note-sync-service))

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
│   └─ Sync Delay (seconds)
├────────────────────────
├─ [✓] Offline Queue
│   ├─ [✓] Enable Offline Queue
│   ├─ Pending Queue (N books)
│   ├─ Retry Frozen Entries
│   └─ Clear Queue
├────────────────────────
├─ Sync Current Book Now
├─ Sync All History  (disabled)
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
    │   ├─ [ ] Sync on Book Open
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

## Privacy

Queue data (book path + title) is stored in KOreader's global config file `settings.reader.lua` under the `fns_sync_queue` field. **It does not contain tokens or other sensitive credentials.** If you don't want the offline queue feature, disable it at **Tools → FNS Sync → Offline queue → Enable offline queue**.

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
