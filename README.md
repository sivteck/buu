# BUU

A native macOS chat client and isolated Mac VM task runner.

- **Chats** — OpenAI- or Anthropic-compatible HTTP servers: LM Studio, Ollama,
  llama.cpp, vLLM, OpenAI, Anthropic, or a self-hosted proxy.
- **Agentic → Mac Tasks** — run an LLM agent inside a separate macOS guest using
  Apple's Virtualization framework. No host screen or input APIs are used.

## Features

- OpenAI-compatible and Anthropic-compatible streaming chat.
- Images via paperclip, paste, or drag and drop.
- Markdown, tables, syntax-highlighted code, reasoning blocks, tool calls.
- Persistent conversations, search, native sidebar selection, pin/unread state.
- Model discovery plus manual model IDs; API keys in the Keychain.
- Embedded macOS VM profiles, VM instances, install/teardown, and guest helper.
- Mac Task agent loop with pause/resume round limits, steering, queue, run
  history, trace screenshots, artifacts, and outputs.
- Guest-only control: `vm_status`, `vm_screenshot`, `vm_click`, `vm_move`,
  `vm_drag`, `vm_scroll`, `vm_type`, `vm_key`, and guest artifact tools.
- Automatic trace archives: Markdown, JSON, and screenshot PNGs grouped by
  outcome — fully successful, partial success, failure, stopped midway, and
  user-cleared context.

## Requirements

- macOS 14 or newer
- Xcode 16 / Swift 6 toolchain
- No external Swift packages or runtime dependencies

## Build

```bash
make app      # builds build/BUU.app and the guest helper
open build/BUU.app
```

`swift run BUU` works for Chats, but the Mac VM needs the signed `.app` bundle
because Virtualization requires `com.apple.security.virtualization`.

Run tests:

```bash
swift test
```

The suite uses Swift Testing and covers providers, SSE, markdown, storage,
artifacts, tracing, and Mac task outcomes.

## Settings

Open **Settings** with `⌘,`.

| Section | Purpose |
| --- | --- |
| Providers | Chat servers, base URLs, API keys, models |
| VM Profiles | Reusable macOS VM image, hardware, display, network settings |
| VM Instances | Installed VM disks and deletion |
| Mac Traces | Destination folder for automatic Mac Task trace archives |

API keys are stored in the macOS Keychain. Provider base URLs and non-secret
settings live in `~/Library/Application Support/BUU`.

## Provider setup

| Preset | Base URL |
| --- | --- |
| LM Studio | `http://localhost:1234/v1` |
| Ollama | `http://localhost:11434/v1` |
| llama.cpp | `http://localhost:8080/v1` |
| vLLM | `http://localhost:8000/v1` |
| OpenAI | `https://api.openai.com/v1` |
| Anthropic | `https://api.anthropic.com` |

Bare OpenAI-compatible hosts get `/v1` added automatically. Anthropic-compatible
servers use `/v1/messages` and `/v1/models`.

## Mac Tasks

1. Open **Agentic** in the sidebar and choose **New Task**.
2. Pick or create a VM profile.
3. Install the macOS guest. The first install downloads a restore image from
   Apple and can take a long time.
4. Complete macOS Setup Assistant in the VM window.
5. Inside the guest, open
   `/Volumes/My Shared Files/tools/BUUVirtualMacGuest.app` and allow Screen
   Recording and Accessibility.
6. Configure a provider and model in the task composer, write a prompt, and Run.

The guest helper enforces `hw.model` starts with `VirtualMac`; it refuses to act
on a physical Mac.

### Workspace

The Mac Task workspace has:

- Live VM display with stacked or side-by-side agent panel.
- Run controls, round budget, run history, and trace.
- Artifacts and outputs, copied through the guest's virtiofs mailbox.
- Steering cards for instructions applied at safe boundaries.
- Per-workspace queue with pause/resume, reorder, and run-next-now.
- Console drawer for VM logs and errors.

### Trace autosave

Choose a folder in **Settings → Mac Traces**. Every finished Mac run and every
manual **Clear context** archives:

```text
<folder>/
  Fully Successful/<task>/...
  Partial Success/<task>/...
  Failure/<task>/...
  Stopped Midway/<task>/...
  User Cleared Context/<task>/...
```

Each archive contains `.md`, `.json`, and any trace screenshots.

## Shortcuts

| Shortcut | Action |
| --- | --- |
| `Return` | Send / queue steering |
| `Shift–Return` | New line |
| `⌘N` | New chat or Mac task, depending on sidebar mode |
| `⌘F` | Focus sidebar search |
| `⌘K` | Focus chat composer |
| `⌥Return` | Interrupt and steer the Mac agent |
| `⌘⌫` | Delete selected chat |
| `⌘,` | Settings |
| `Esc` | Stop, close popovers, or clear search |

## Security and privacy

- API keys are Keychain-only and never written to settings, conversations, or
  logs.
- Model output is rendered as text/attributed strings only. No HTML, JavaScript,
  or shell execution.
- Host screen capture and host input injection are not used.
- Guest actions and artifacts are confined to the guest helper and its allowed
  folders.
- The app makes outbound HTTP(S) requests only and opens no network listeners.

## Project layout

```text
Sources/BUU/            SwiftUI app, Mac task workspace, settings
Sources/BUUKit/         Provider wire formats, markdown, persistence, tests
Sources/VirtualMacCore/ Vendored VM mailbox and shared models
Sources/VirtualMacKit/  Virtualization runtime, guest helper, artifacts
Sources/VirtualMacGuest Guest helper executable
Resources/              App/guest plists and Virtualization entitlement
Scripts/                build-app.sh and signing helper
```

The vendored VM targets remain in Swift 5 language mode. The app and BUUKit use
Swift 6 strict concurrency.
