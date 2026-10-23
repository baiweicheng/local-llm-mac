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

## Good to know

- The built-in model is small (~3 billion parameters). It's good at chat,
  summarizing, rewriting, and quick questions; Apple itself warns it's
  not the right tool for heavy math, coding, or factual deep-dives.
  Bigger local models (MLX) and an optional cloud tier arrive in later
  phases.
- If you reopen an old chat after restarting the app, the model is
  re-seeded with the summary (if the chat was compacted) plus the recent
  messages, so the thread isn't lost.
- To run the unit tests: in Xcode, **Product → Test** (⌘U). They cover
  the behind-the-scenes logic (instructions, token estimates, markdown
  splitting, context budgets, compaction planning, summary merging,
  attachment storage) and never call the real model.

## Where this is going

This is phase 1 of a larger build (see the project plan): local MLX
models and a model picker next, then automatic routing with a privacy
firewall, read-only tools that can see your files/calendar/photos locally,
carefully-confirmed file actions, a global hotkey HUD, and an optional
cloud tier via OpenRouter — all over this same chat window.
