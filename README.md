# LocalLLM (working name)

A chat app for your Mac that runs **entirely on the Mac itself** — no
account, no API key, no internet needed for chatting. It uses the on-device
AI model built into macOS (Apple Intelligence) through Apple's Foundation
Models framework, wrapped in a familiar chat interface: conversation list
on the left, chat on the right.

The real app name comes later; "LocalLLM" is just the placeholder.

## What you need

- A Mac with Apple Silicon running **macOS 27**
- **Xcode 27**
- **Apple Intelligence turned on** (System Settings → Apple Intelligence &
  Siri). The app checks for this and explains, in plain English, if
  something isn't ready — e.g. the model is still downloading.

## How to run it

1. Get this folder onto your Mac (clone the repo, or pull the latest
   version if you already have it).
2. Open the **folder** in Xcode 27 (File → Open, pick the folder that
   contains `Package.swift`). This is a Swift Package, not an Xcode
   project file — that's expected.
3. Wait a few seconds for Xcode to finish indexing, then press the **Run**
   button (▶) in the toolbar, or press **⌘R**.
4. The app window opens. Press **⌘N** (or the pencil button) to start a
   chat and type away.

First compile happens entirely on your Mac — expect the first build to
take a minute or two.

## What's in Phase 1

- **Real streaming chat** on Apple's built-in on-device model — replies
  appear as they're written, and you can stop a reply mid-stream (the
  partial answer is kept).
- **Conversation list**: new, rename, and delete chats (right-click a chat
  for the menu). The first message names the chat automatically.
- **History that stays put**: conversations are saved on this Mac with
  SwiftData and are still there when you reopen the app. Nothing is sent
  anywhere — there is no server.
- **Per-chat system instructions**: the quote-mark button in the chat
  header lets you tell the model how to behave in that one chat ("Be
  brief", "Explain like I'm a beginner"…). Empty means the built-in
  default.
- **Plain-English model status**: a status pill shows whether the
  on-device model is ready; if Apple Intelligence is off or the model is
  still downloading, the app says what's wrong and what to do.
- **Markdown rendering**, including code blocks with a copy button.
- **Keyboard**: ⌘N new chat, **Return** sends, **Shift+Return** starts a
  new line.
- A rough **token counter** in the header (the on-device model's memory —
  its "context window" — is 4,096 tokens, shared between instructions and
  the conversation). The count is an estimate, labeled with ≈.

## What's new in Phase 2

- **Long conversations that manage themselves.** The model's memory is
  only 4,096 tokens, so before each message the app checks whether the
  conversation still fits. When it gets close to full, the oldest
  messages are **summarized by the on-device model itself** into a
  running summary, and the newest messages stay word-for-word. Your
  system instructions are never summarized away. In the transcript, a
  divider — *"Earlier messages were summarized to fit the model's
  memory"* — marks where the summary takes over. **Nothing is deleted:**
  the full history stays in the app; only the model's working memory is
  compacted. If summarizing itself ever fails, the app falls back to a
  plain note of the topics covered, so a long chat never just breaks.
- **Image attachments.** Attach pictures to a message with the paperclip
  button, by dragging image files into the window, or by pasting (⌘V)
  with the composer focused — up to 4 per message. Images are shrunk to
  a sensible size before they're stored, shown as thumbnails in the
  transcript (click one to see it full-size in Preview), and sent to the
  model with your message so you can ask about them ("What's in this
  screenshot?", "Transcribe this receipt"). Everything still happens
  on-device. Note that images use up model memory faster than text —
  each one is budgeted at roughly 400 tokens.

## What's new in Phase 3

Phase 3 adds a **model picker**: each chat can now run on the built-in
model, on a bigger **local MLX model** you download, or on a **local
server** (Ollama or LM Studio) if you run one. The picker is in the chat
header, next to the status pill, and each chat remembers its own choice.
Switching models mid-conversation is safe: the new model is handed the
chat's summary plus the recent messages, so the thread carries over —
and long chats are compacted against the new model's (usually bigger)
memory.

- **Downloading an MLX model.** Click the chip/CPU button in the chat
  header → **Manage Models…**. Three models are listed, sized for a Mac
  with 18 GB of memory: **Llama 3.2 3B** (small and fast, ≈1.9 GB),
  **Gemma 4 12B** (Google's model — the recommended default, ≈6.5 GB;
  it also natively understands images and audio), and **Qwen 2.5 14B**
  (the strongest local option that fits, ≈8.4 GB), each with a
  plain-English badge saying how it fits your Mac. **Download** fetches
  it from Hugging Face with a progress bar (Cancel any time); downloaded
  models show their exact size on disk and can be **deleted** from the
  same panel. Only downloaded models appear in the picker. The first
  time you pick an MLX model in a chat, expect it to take a little
  while to load before the first reply.
- **Using Ollama or LM Studio.** If you already run one of these apps,
  this app can chat through the models they serve — no downloading
  inside this app needed. In **Manage Models…**, the two presets are
  already listed (Ollama at `localhost:11434`, LM Studio at
  `localhost:1234`); **Edit** the preset to set the model name to one
  your server actually has (for Ollama, `ollama list` in Terminal shows
  them; for LM Studio, load a model there first). The server app must be
  running when you send — if it isn't, the reply area tells you in plain
  English instead of failing mysteriously. You can also **Add Server**
  for any other app that serves the OpenAI chat API locally. Note:
  local servers receive the *text* of your messages; image attachments
  are understood only by the built-in and MLX models for now.
- **Everything is still local.** MLX models run on your Mac's GPU;
  servers are on `localhost`. The only network use in this phase is
  downloading models you asked for.

## What's new in Phase 4

Phase 4 makes the app **route each message to the right model by
itself**, and puts a **privacy firewall** in front of anything that
could ever leave this Mac.

- **Auto mode (the new default for new chats).** The model picker in
  the chat header now starts with **Auto**, and new chats use it.
  Before an Auto message is sent, the built-in on-device model quickly
  sorts it into one of four kinds — *something to do on this Mac*, a
  *quick edit or question*, *hard work that should stay local*, or
  *something that really wants a frontier cloud model* — and the app
  picks the backend to match: quick things go to the built-in model,
  hard local work goes to your largest downloaded MLX model (or a
  local server, if no model is downloaded), and a cloud-worthy
  question gets the best local stand-in available **plus a plain note
  that cloud models arrive in a later phase** — the app never pretends
  a cloud call happened. A quiet line under the chat header says what
  Auto decided and why ("Auto: a quick edit or question — Apple
  On-Device handles those instantly and privately."). If the sorting
  step ever fails or takes too long, the message just goes to the
  built-in model — sorting never blocks a send. Picking a model
  yourself in the picker still overrides Auto completely, and chats
  you already had keep the model you picked for them.
- **The privacy check (firewall).** You can add a server in Models
  whose address *isn't* on this Mac (say, a machine on your network).
  Anything sent to such a server is scrubbed first — automatically,
  every time: API keys and other secret-shaped tokens, values after
  labels like `password:`, email addresses, phone numbers, and
  card-number-shaped digit runs are replaced with `[redacted]`, and a
  notice under the chat tells you how much was hidden. Servers on
  `localhost` (Ollama, LM Studio) count as *on this Mac* and get your
  message exactly as written, as do the built-in and MLX models. Your
  saved messages are never edited — only the copy that gets sent. You
  can add your own words and phrases to hide (a codename, an address)
  in **Privacy settings** — the gear button in the chat header.
  History stays compressed, too: a long chat that has been summarized
  sends a remote server the summary plus the recent messages — never
  the full raw history.
- **Local Only lock.** In Privacy settings, the **Local Only** switch
  guarantees nothing is sent anywhere: server backends are refused
  outright (not just hidden), Auto never routes to a server, and a
  chat that was using a server switches to the built-in model with a
  note explaining why. A small **Local Only** badge in the chat header
  shows while the lock is on.
- **Telemetry pill.** Every reply now carries a small pill underneath
  — for example `Apple On-Device · 1.2s · $0.00` or `Local MLX ·
  Gemma 4 12B · 3.4s · $0.00` — naming the model that actually
  answered, how long it took, and what it cost. Under Auto this is
  where you can see which model handled each message.

## Good to know

- The built-in model is small (~3 billion parameters). It's good at chat,
  summarizing, rewriting, and quick questions; Apple itself warns it's
  not the right tool for heavy math, coding, or factual deep-dives.
  For harder work, switch the chat to a downloaded MLX model (Phase 3);
  an optional cloud tier arrives in a later phase.
- If you reopen an old chat after restarting the app, the model is
  re-seeded with the summary (if the chat was compacted) plus the recent
  messages, so the thread isn't lost.
- To run the unit tests: in Xcode, **Product → Test** (⌘U). They cover
  the behind-the-scenes logic (instructions, token estimates, markdown
  splitting, context budgets, compaction planning, summary merging,
  attachment storage, model-picker persistence, download planning,
  server-request building, stream parsing, routing decisions, the
  privacy check, and the telemetry pill) and never call the real
  model.

## Where this is going

This is phase 4 of a larger build (see the project plan): next come
read-only tools that can see your files/calendar/photos locally,
carefully-confirmed file actions, a global hotkey HUD, and an optional
cloud tier via OpenRouter — which will inherit Phase 4's privacy check
(and its habit of reusing the conversation summary instead of raw
history) before anything leaves the Mac.
