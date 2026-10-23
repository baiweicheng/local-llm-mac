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
  **Llama 3.1 8B** (the balanced default, ≈4.9 GB), and **Qwen 2.5 14B**
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
  server-request building, and stream parsing) and never call the real
  model.

## Where this is going

This is phase 3 of a larger build (see the project plan): automatic
routing with a privacy firewall next, then read-only tools that can see
your files/calendar/photos locally, carefully-confirmed file actions,
a global hotkey HUD, and an optional cloud tier via OpenRouter — all
over this same chat window.
