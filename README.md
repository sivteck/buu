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
- **No logging of secrets** – the app does not write a log file at all.
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

## Project layout

```
Sources/
  BUUKit/            platform independent core (no SwiftUI)
    Models/          endpoint, conversation, request/response models
    Networking/      HTTP transport, SSE decoder, OpenAI & Anthropic transports
    Persistence/     file store, settings, conversation store, keychain
    Markdown/        markdown block parser, syntax highlighter
    Images/          image downscaling / re-encoding
  BUU/               the macOS app (SwiftUI)
    BUUApp.swift     @main entry point
    AppState.swift   observable application state
    Views/           sidebar, transcript, composer, settings, markdown renderer
Tests/BUUKitTests/   unit tests for the wire formats, SSE, markdown, storage
```

`BUUKit` deliberately contains no UI code, which makes the protocol handling
testable on any platform.

## How a request is made

1. The transcript is converted into a protocol neutral `ChatRequest`
   (role + text/image blocks).
2. `OpenAITransport` or `AnthropicTransport` encodes it:
   - OpenAI: `messages[].content` is a string or an array of
     `{"type":"text"}` / `{"type":"image_url"}` parts.
   - Anthropic: `system` is a separate field, `messages[].content` is an array
     of `{"type":"text"}` / `{"type":"image"}` blocks, consecutive same-role
     messages are merged and `max_tokens` is always sent.
3. The response is consumed as `text/event-stream`. If a server ignores
   `stream: true` and answers with plain JSON, the client detects the content
   type and parses the JSON instead.
4. Every delta is appended to the assistant message, so the UI updates live.

## License

MIT
