# BUU

A native macOS chat client for **any** server that speaks the OpenAI or the
Anthropic HTTP API — LM Studio, Ollama, llama.cpp, vLLM, OpenAI, Anthropic or a
self hosted proxy.

BUU has **no runtime of its own**. It is a thin desktop client: it renders the
UI, encodes your prompt into the wire format of the server you configured and
streams the answer back. Local servers are reached over plain `http://`,
remote servers over `https://`.

```
┌────────────┐   HTTP(S)    ┌──────────────────────────────┐
│  BUU.app   │ ───────────► │  LM Studio / Ollama / vLLM /  │
│  (SwiftUI) │   SSE stream │  OpenAI / Anthropic / proxy   │
└────────────┘ ◄─────────── └──────────────────────────────┘
```

## Features

- **Two wire protocols**
  - OpenAI compatible: `POST {base}/chat/completions`, SSE `data:` deltas
  - Anthropic compatible: `POST {base}/v1/messages`, SSE content-block deltas
- **Any endpoint** – `http://localhost:1234/v1`, `https://api.openai.com/v1`,
  `https://api.anthropic.com`, a reverse proxy, … Authentication is flexible:
  none, `Authorization: Bearer …`, a custom header (`x-api-key`) or a query
  parameter. Keys are stored in the **Keychain**.
- **Images** – attach pictures with the paperclip, the clipboard or by dropping
  them into the composer. They are downscaled and inlined as `data:` URLs
  (OpenAI) or base64 content blocks (Anthropic).
- **Streaming** – token by token, with a stop button, `reasoning_content` /
  thinking blocks and tool calls.
- **Markdown** – headings, lists, quotes, tables of contents and fenced code
  blocks with lightweight syntax highlighting and a copy button.
- **Conversations** – persisted on disk (`~/Library/Application Support/BUU`),
  renameable, duplicable, deletable.
- **Model picker** – the model list is fetched from the server (`/models`) and
  can be overridden manually.
- **Swift 6** – full strict concurrency, `@Observable` state, no third party
  dependencies.

## Dependencies

**None.** `swift package show-dependencies` reports *no external dependencies* and
there is no `Package.resolved`. Everything is either Apple system frameworks
(`Foundation`, `SwiftUI`, `AppKit`, `Observation`, `UniformTypeIdentifiers`,
`Security`, `ImageIO`) or code in this repository:

| Instead of | BUU uses |
| ---------- | -------- |
| Alamofire / SwiftHTTP | `URLSession` + a small `URLSessionDataDelegate` streaming shim |
| swift-markdown | own block parser (`Markdown/MarkdownDocument.swift`) + `AttributedString(markdown:)` for inline formatting |
| SwiftSyntax | own ~250 line tokenizer (`Markdown/CodeHighlighter.swift`) |
| KeychainAccess | `Security` framework wrapper (`KeychainStore`) |
| SwiftLint / SwiftFormat | not required, but the code follows the standard Swift API design guidelines |

That removes the whole supply-chain surface: no transitive dependencies, no
`Package.resolved` to audit, nothing that can be swapped underneath you, and
no version conflicts with anything else in your project.

## Security

- **API keys never touch the disk in plain text** – they live in the macOS
  **Keychain** (`kSecAttrAccessibleWhenUnlocked`), keyed by server id.
- **TLS uses the system trust store** – `https://` endpoints are validated by
  `URLSession` against the usual Apple roots. There is no custom trust
  handling and no certificate pinning that could silently weaken it.
- **App Transport Security** is relaxed only as far as needed for local
  servers: `NSAllowsLocalNetworking` (loopback/`.local`) plus
  `NSAllowsArbitraryLoads` for the case where your server runs on *another*
  machine over plain `http://`. Remove `NSAllowsArbitraryLoads` from
  `Resources/Info.plist` if all of your servers use `https://` and ATS will be
  enforced again.
- **Path traversal is contained** – attachment file names are always reduced
  to their last path component before they are joined to the attachments
  folder, so a tampered conversation file cannot make the app read arbitrary
  files.
- **No code execution from model output** – answers are rendered as text and
  attributed strings only. No HTML, no JavaScript, no shell. Links are opened
  by the system.
- **No logging of secrets** – the app does not write a log file at all. API keys
  are Keychain-only.
- **No network listeners** – the app only makes outbound requests (the test
  suite opens a loopback socket, but that code never ships in the app target).

## Markdown

The assistant transcript is rendered from a **block-aware** parser
(`Sources/BUUKit/Markdown/`), not from `Text(LocalizedStringKey)` — so GFM
features that AttributedString silently drops still work:

| Block | Rendering |
| ----- | --------- |
| Tables | `MarkdownTableView`: horizontal scroll, rounded 10pt container, semibold header with tinted background, zebra rows, 1px hairlines, per-column alignment from `:---` / `:---:` / `---:`, 80–320pt columns, inline markdown + selectable cells, hover toolbar **Copy as Markdown / Copy as CSV** |
| Headings, paragraphs, lists, quotes, rules | own SwiftUI views, 14.5pt body, 4pt leading, 10pt paragraph spacing |
| Fenced code | language label, copy button, 13pt monospaced, horizontal scroll, rounded container |
| Inline code | monospaced with a subtle rounded tint; very long unbroken spans are shortened with a middle ellipsis |

Streaming is incremental: re-parsing is debounced to 50 ms and the parser holds
back a half-written trailing table row so the table does not flicker. Quirky
model output is normalised — a table without the blank line before it, or
without outer pipes, still parses.

## Scrolling performance

The transcript is built so a row's height is **final on its first layout** —
the cause of the "jump when a table scrolls into view" bug.

- **Prepared once, cached forever.** `MessageCache` (not `@Observable`, so cache
  writes never invalidate rows) stores a `PreparedMessage`: paragraphs are
  `AttributedString`s, code is already syntax-highlighted, table cells already
  attributed and measured. `body` only lays out finished values, and the cache is
  warmed on a background task when a conversation loads. Background passes carry
  a generation token, so a slow pass can never overwrite fresher content.
- **Equatable rows.** `MessageRow`, `PreparedMarkdownView`, `CodeBlockView` and
  `MarkdownTableView` are `Equatable` and use `.equatable()`, so while tokens
  stream only the streaming row re-evaluates. Rows compare actual text, not
  character counts.
- **No nested vertical scrolling.** Code blocks wrap by default and collapse to
  18 lines behind "Show all N lines"; tables shrink their columns to fit the
  conversation column so cells wrap instead of being clipped. A horizontal
  scroll view only appears when the window is too narrow for the minimum widths.
- **One sentinel, throttled follow.** A single bottom sentinel feeds *user
  intent* (`isFollowing`), which is separate from its *layout* visibility: growing
  content pushes the sentinel off screen, and that must not stop following.
  Following is cleared only when you scroll up while the sentinel is off screen,
  restored when it comes back, and reinforced by an immediate jump whenever a
  message is appended. Scrolls are throttled to one per 100 ms, never animated
  while tokens arrive, and give a manual scroll 400 ms of grace. User scrolling
  is observed on the transcript's own `NSScrollView`, not with a global event
  monitor.
- **Fresh transcript per conversation.** The scroll view is keyed to the active
  conversation and jumps to the newest row only after the new lazy content has
  been installed, so an old offset cannot leave the pane blank.
- **No per-row geometry.** Near-bottom is one sentinel with `onAppear` /
  `onDisappear`; there are no `PreferenceKey` height reports.

### Diagnosing it yourself

```bash
BUU_RENDER_DEBUG=1 swift run BUU
```

Prints each row's first layout height, warns when a row's height changes **after**
first layout, and logs row `body` evaluations slower than 1 ms.

Then load a stress conversation with **⌥⌘T** (*Debug: Load Test Thread*, 200
messages mixing short replies, 9-row tables and 300-line code blocks) and check:

| Step | Expected |
| ---- | -------- |
| Scroll up fast with the trackpad | No vertical jump as tables/code come into view |
| Scroll to the top, then back down | Position tracks the finger, no snapping |
| Stream a reply while scrolled up | The view does **not** move; a "scroll to latest" pill fades in |
| Stream while at the bottom | The view follows without animating or overshooting |
| Resize the window narrower | Table columns shrink/wrap; only a very narrow window scrolls sideways |

## Interface

### Design system

All layout values live in `Sources/BUU/Views/Theme.swift`:

| Token | Values |
| ----- | ------ |
| `Theme.Spacing` | 4, 8, 12, 16, 24 |
| `Theme.Radius` | 6, 8, 12, 16 |
| `Theme.Metrics.readableWidth` | 720pt centred column for header, messages and composer |
| `Theme.Metrics.bubbleMaxWidth` | 540pt (≈75% of the column) |
| `Theme.Metrics.controlSize` | 28pt minimum hit target |
| `Theme.Typography` | body 14.5pt / 1.35 line height, code 13pt monospaced |
| `Theme.Colors` | `windowBackgroundColor`, `controlBackgroundColor`, `separatorColor`, `accentColor` |

No colour is hard-coded except the syntax-highlight palette, which has explicit
light and dark variants (`SyntaxPalette`) so code stays legible in both modes
without requiring an asset catalog.

### Shortcuts

| Shortcut | Action |
| -------- | ------ |
| `Return` | Send |
| `Shift–Return` | New line |
| `⌘N` | New chat |
| `⌘K` | Focus the composer |
| `Esc` | Stop generating |
| `⇧⌘R` | Regenerate the last answer |
| `⌘,` | Settings |
| Double-click the title | Rename the chat |

### Behaviour

- **Images** can be attached four ways: the paperclip menu, drag & drop onto the
  composer (accent border while hovering), ⌘V / right-click **Paste**, or
  copying a file in Finder. Drops accept files, raw bitmap data and remote
  image URLs; pasted rich text still pastes as text.
- **Click a thumbnail** in the transcript to open the image full size (click the
  backdrop or press `Esc` to close; **Open in Preview** hands it to Preview.app
  because attachments are real files on disk).
- The transcript only auto-scrolls while you are near the bottom; otherwise a
  *scroll to latest* pill appears above the composer.
- Streaming shows a typing indicator (or a pulsing caret once text arrives) and
  the send button turns into **Stop**.
- Token usage, stop reason, copy and regenerate live in a hover toolbar under
  each assistant message.
- **Performance numbers** ride along with each answer (hover the message, or it
  is always visible on the newest one): time to first token, generation speed,
  prefill speed and the context size after the turn. While a reply streams, the
  row shows a live generation rate. The chat header always shows the current
  context size.

  Client-side timings are always measured; when the server reports its own
  numbers they win — llama.cpp's `timings` (`prompt_per_second`,
  `predicted_per_second`) and LM Studio's `stats` (`tokens_per_second`,
  `time_to_first_token`) are decoded from the final stream chunk. Prefill speed
  falls back to `prompt_tokens ÷ time-to-first-token`, which includes network
  and queueing, so it is a lower bound.
- Reasoning is collapsed by default in a compact disclosure; expansion respects
  *Reduce Motion*.
- Empty chats show four suggestion chips that pre-fill the composer.

### Virtual Mac (embedded terminal-mac engine)

BUU now embeds the `Virtualization`-based VM engine and guest helper from
[terminal-mac](https://github.com/govijr/terminal-mac) (MIT). The VM, guest
helper, shared mailbox and screenshot/input path live in this repository; there
is no external Swift package dependency.

Virtualization needs a signed app bundle with the
`com.apple.security.virtualization` entitlement. Build with:

```bash
make app              # builds BUU.app and the nested guest helper
open build/BUU.app
```

`swift run BUU` still works for chat, but the Virtual Mac cannot boot without the
entitlement.

Open **Sidebar → Agentic → Mac Tasks**. Named Mac Task configurations (VM name,
resources, display and optional restore image) are managed in **Settings → Mac
Tasks**; the task pane loads the active configuration. On first use BUU downloads a
compatible macOS restore image from Apple (several GB) and installs a separate
virtual Mac. Complete macOS Setup Assistant in the VM window, then open
`/Volumes/My Shared Files/tools/BUUVirtualMacGuest.app` inside the guest and
allow Screen Recording and Accessibility. The host needs neither permission.

The Mac Tasks workspace uses the window toolbar for Display/Activity/
Configuration, keeps the live VM display aspect-fit, and places the agent in a
collapsible trailing inspector or a resizable bottom split. The agent panel has a
fixed run bar, a single scrolling middle tab (Trace/Artifacts/Outputs/Queue) and
a pinned composer. No separate VM window is required by default. Display also contains the
agent prompt, execution controls and response/tool log, with stacked or
side-by-side layout. Both layouts use native draggable split views, so the VM
display and agent control area can be resized. **Activity** holds VM lifecycle controls and install/
runtime/error logs; **Configuration** shows the active VM profile. The agent
loop can be paused at a configurable round limit and resumed from its saved
context, or cleared with **Clear context**. Files attached to the prompt are
copied into a per-task host workspace and then into the guest at
`~/Desktop/BUU Artifacts` (with `~/Desktop/BUU Outputs` for results). Transfers
are chunked over the existing virtiofs mailbox with SHA-256 verification and
resume. The model uses guest-centric tools: `list_artifacts`, `open_artifact`,
`reveal_artifact`, `read_artifact`, `extract_artifact_text`, `write_artifact`,
`guest_frontmost_app` and `guest_list_windows`. While a loop is running,
steering is a separate pinned composer below the trace: Return queues a steer for
the next safe boundary, Option-Return interrupts and applies it now, and the
pending cards remain editable/reorderable until the loop marks them applying.
The workspace task queue is a separate collapsible tray under the run controls;
use **Queue task** or the header queue button. Queued tasks keep their own prompt,
files, provider/model, budget, VM-state policy and fresh/continue-context choice,
run sequentially in the workspace, and support pause/resume, run-next-now and
stop-on-failure. Both steers and queue transitions are included in readable and
JSON trace exports. **Export logs…** covers VM/install, error, agent-loop and full
reasoning-trace exports. Exports write to a location chosen in the standard save
panel. Choose any configured provider endpoint and model;
the loop exposes exactly the `vm_status`, `vm_screenshot`, `vm_click`, `vm_move`,
`vm_drag`, `vm_scroll`, `vm_type` and `vm_key` tools. There is no shell tool and
no host screen/input API: every action goes through the guest helper.

The vendored VM targets are kept in Swift 5 language mode because they depend on
the upstream Virtualization/AppKit/ScreenCaptureKit stack. The BUU app and
BUUKit remain Swift 6.

## Requirements

- macOS 14 or newer
- Xcode 16 / Swift 6 toolchain (`swift --version`) – verified with **Swift 6.2**
- Swift 6 language mode (`swiftLanguageMode(.v6)`, i.e. full strict
  concurrency checking)

## Build & run

```bash
make app      # produces build/BUU.app
open build/BUU.app
```

or during development:

```bash
swift run BUU
```

Run the (platform independent) core tests with:

```bash
swift test
```

The suite uses **Swift Testing** (the framework shipped with Swift 6) and
covers the wire formats, the SSE parser, markdown parsing, storage and five
end-to-end tests that run against a real socket server.

## Configuration

Open **Settings** (⌘,) and add a server:

| Preset | Base URL | Notes |
| ------ | -------- | ----- |
| LM Studio | `http://localhost:1234/v1` | local server, no key |
| Ollama | `http://localhost:11434/v1` | local server, no key |
| llama.cpp | `http://localhost:8080/v1` | local server, no key |
| vLLM | `http://localhost:8000/v1` | local server, no key |
| OpenAI | `https://api.openai.com/v1` | bearer token |
| Anthropic | `https://api.anthropic.com` | `x-api-key` header |

If you type a bare host for an OpenAI compatible server (`http://localhost:1234`)
the `/v1` prefix is added automatically. Anthropic compatible servers get
`/v1/messages` and `/v1/models` appended (unless the base URL already ends in
`/v1`).

### Mac Tasks

The sidebar has two top-level sections: **Chats** and **Agentic**. Agentic lists
Mac Task instances; **New Task** opens a wizard for a macOS VM task, names it,
selects a configuration profile, and optionally saves a prompt without running
it.

Each task keeps its own configuration choice, prompt, logs and surface state,
while configuration profiles remain reusable. Inside a task you can switch to
any existing configuration or create a new one (including a fresh VM) without
affecting other tasks.

**Settings → VM Profiles** manages reusable macOS VM recipes: image source,
macOS version, architecture, storage, CPU/RAM/disk, networking, shared folder,
display and graphics. Profiles support create, edit, duplicate, delete, default
selection and surface host-capacity warnings. **Settings → VM Instances** lists
installed VMs and allows deleting their disk/hardware files.

Model lists are fetched lazily when the model picker opens because
`/api/v1/agents?models=1` shells out to `pi --list-models` (about 3.6 s).
Uploads and task routes are operator-only. The agent runs on the Pi with its own
short-lived task token; the window never executes browser actions or CDP itself.


