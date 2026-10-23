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
- **Model memory (KV cache).** An MLX model keeps a working memory of
  the conversation so far — the *KV cache* — and at full size it can
  grow to several gigabytes on a long chat, next to the model's own
  ≈6.5 GB. The gear menu's **Local model memory** setting shrinks it:
  **8-bit** (the default) stores that memory in half the space with no
  noticeable change in answer quality, **4-bit** uses a quarter of the
  space with a little more quality risk, and **Off** keeps the
  full-size memory. It applies to downloaded MLX models only — the
  built-in model and local servers manage their own memory — and
  changing it simply restarts the chat's session (the conversation
  itself is kept).

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

## What's new in Phase 5

The local visibility layer: the model can now *look things up on your
Mac* to answer you — and only ever where you've said it may. This is
the app's main idea, so it's built like a bank vault door: everything
is off until you turn it on, everything in this phase is read-only,
and everything it looks at is written down where you can see it.
(Phase 6, below, adds carefully-confirmed *changes* under a separate
switch.)

**Turning it on.** Open the gear (Privacy) sheet and scroll to
**What this app can see**. Each source has its own switch, off by
default:

- **File search (Spotlight)** — find files by name or by words inside
  them.
- **Shared folders** — read text files and list folders, *only inside
  folders you pick* with the Add Folder button below the switch. A
  folder is granted by picking it (macOS keeps a security bookmark);
  there is no way to type in a path and widen it. Nothing outside
  those folders can be read — not by path tricks (`..`), not by a
  differently-spelled sibling folder, not through a symlink pointing
  out.
- **Calendar** and **Reminders** — upcoming events; unfinished
  reminders.
- **Contacts** — look up a name, get the phone/email as stored.
- **Photos** — list recent photos (date and size only — never the
  pictures) and read the text in one specific recent photo.
- **Music library** — search songs by title, artist, or album.
  One honest gap: *what's playing right now* can't be done — macOS
  gives apps no public way to see what another app is playing (the
  old private route was locked down in macOS 15.4), so the tool says
  exactly that instead of guessing.
- **About this Mac** — model, chip, memory, free storage, battery,
  macOS version, uptime, open apps.
- **Clipboard** — read what's copied, and copy text for you. Copying
  happens right away (it's the quick bridge from a chat to your other
  apps), but like every lookup it is always in the log.

Two small utilities ride along whenever any source is on: a
calculator (a small hand-written parser — it can't run anything but
arithmetic) and the current date & time.

**Permissions.** Calendar, Reminders, Contacts, Photos, and Music
also need macOS's permission. The app asks when you first flip the
switch; if you said no (or want to change your mind), the switch row
shows the state and the exact place to fix it (System Settings →
Privacy & Security). One wrinkle: macOS shows those prompts based on
the packaged app's permission notes, which arrive with the Phase 10
app bundle — when you run from Xcode in the meantime, macOS
attributes access to Xcode, and the panel will tell you if a grant
isn't landing.

**The access log.** Every lookup is recorded — when, which tool, what
it asked, a one-line summary of what it found — and shown two ways:
as a small card in the chat, right where it happened, and in the
gear sheet under **Recent activity**. The newest 300 are kept. If a
model ever looks at something, there is a card saying so; there is no
silent looking.

**Which models can look.** Lookups work with the Apple On-Device
model and downloaded MLX models — on an Auto chat, "do something on
my Mac" questions already route to the on-device model, which is the
tools engine. Server chats (Ollama / LM Studio) can't make lookups
yet; if you've turned sources on, a server chat shows a short note
saying so rather than pretending.

**Privacy rules for what a lookup finds.** Lookup results are your
local data, and in this version they never leave the Mac: the only
models that can use tools run locally. The rule is wired for the
future cloud tier anyway — tool results will pass the Phase 4 privacy
check before a cloud model can see them, and under **Local Only** a
network backend gets no tools at all. Results are also kept small on
purpose (a file search returns a handful of lines, trimmed with a
note if longer), because the on-device model's memory window is
small and a 200-line search result would crowd out your conversation.

## What's new in Phase 6

File actions — carefully, and only ever with your OK. Phase 5 let the
model *look*; this phase lets it *propose changes* to files inside
your shared folders. The model can never change anything by itself:
proposing is all a tool call can do, and every change waits for you.

**The switch.** In the gear sheet, below "What this app can see",
there's a separate **File changes** switch — off by default, and
separate from the read switches on purpose. While it's off, the
file-action tools don't exist for any model. While it's on, the
model gains seven propose-only tools: **rename**, **move**, **copy**,
**create folder**, **edit a text file** (replace its contents, or add
at the end), **move to Trash**, and **resize a photo**.

**How proposing works.** When the model wants to change something,
the change lands on a list pinned above the message box: *"Rename
“IMG_2049.jpg” → “beach-sunset.jpg” in ~/Downloads"*, one line per
change, in plain English. You can take individual changes off the
list (the ✕ on each row), **Discard** the whole list, or **Approve**
it. Only Approve touches the disk: the app then runs each change in
order, and each one reports its own result on a card in the chat —
done, or exactly why it couldn't. One failure doesn't stop the rest.
The model is told the outcome with your next message, so the
conversation carries on knowing what you decided — including when
you discard, so it doesn't quietly re-propose the same list.

**The safety rules** (all checked when a change is proposed, and
checked *again* against the disk as it is when you approve):

- Nothing outside your shared folders can ever be changed — both
  ends of a move or copy must be inside them, and a shared folder
  itself can never be moved to the Trash.
- **Nothing is ever overwritten.** If something already sits where a
  change would land, that change fails with a note instead. (The one
  deliberate exception is editing a text file — the file *is* the
  destination — and there the app keeps a backup of the old contents
  first, which is also what makes the edit undoable.)
- Deletes are really **Move to Trash** — nothing is permanently
  erased.
- A folder can't be moved or copied into itself.
- Every proposal, approval, discard, result, and undo is written to
  the same log as the lookups (the gear sheet's **Recent activity**)
  and shown as cards in the chat.

**Undo.** Every approved list's card keeps an **Undo these changes**
button until you've used it. Undo runs newest-change-first: renames
and moves go back where they came from, copies and created files go
to the Trash, a created folder is removed *only if it's still
empty*, an edited file gets its backed-up contents back (the edited
version goes to the Trash, so undo loses nothing itself), and a
trashed item is pulled back out of the Trash. The honest limits:
undo never overwrites either — if something new sits in the original
spot, that item stays put and the card says why; a folder that has
gained files is left alone; and if macOS didn't tell the app where a
trashed item landed, that one item can't be pulled back
automatically (it can always be dragged back from the Trash in
Finder).

**Resizing a photo** (for uploads with size limits, email, sharing).
Point it at a recent library photo or at an image file in a shared
folder, with a maximum width (default 1200 px) and a JPEG size limit
(default about 500 KB). The app scales the photo down, then saves it
as a JPEG, stepping the quality down until the file fits the limit;
if even the lowest quality is too big, it shrinks the photo a step
and tries again — and if it still can't fit, you get the smallest
version it could make, with the card saying so. The original is never
touched; the resized copy is a new file (named like the original,
with "-resized" added, unless you asked for a specific place), and
when the change is approved the copy is **also put on your
clipboard**, ready to paste.

**Artifact chips.** Any file an approved change creates — the
resized photo, a copy, a new text file — appears on the plan's card
as a small pill with its name and size. The pill is the file: drag it
straight into a browser upload, Finder, or another app. If the file
is later moved or deleted somewhere else, the pill stays on the card,
greyed out and marked "missing", rather than vanishing from the
record.

## What's new in Phase 7

**A quick panel: the same chat, one keystroke away.** While the
app is running, press **⌘⇧Space** anywhere — in Safari, in Finder,
in the middle of an email — and a small floating panel appears near
the top of the screen. Type a question, press Return, and the answer
streams right there in the panel. It's not a separate mini-app: a
panel chat runs through exactly the same machinery as the main
window (Auto routing, the lookups, the privacy check, the telemetry
pill), against a real conversation that's saved in the sidebar,
titled "Quick — …" after your first message. Follow-ups work in the
panel like anywhere else. Esc, or clicking away, dismisses it;
**Open in main window** (or **⌘Return**) brings the conversation up
in the main window instead.

**It quietly notes what you were in the middle of.** When the panel
opens it shows small chips for the context it captured: which app
was in front, whether the clipboard currently holds text, an image,
or something else, and — only when the **Shared folders** switch in
Settings is on — how many items Finder has selected. That context is
written into the first message of a panel chat (only the copy sent
to the model; your typed message is stored exactly as typed), so
"resize this" or "summarize this" can mean the file you just
selected. The capture follows the same switches as everything else:
the clipboard chip only ever shows the *kind* of thing copied, and
the clipboard's actual text is included only when the **Clipboard**
switch is on; the Finder selection is read only when the Shared
folders switch is on (and macOS will ask once for permission to let
the app talk to Finder — declining simply means no chip, never an
error). What's currently playing in other apps isn't captured —
only the frontmost app's name.

**Approvals still happen in the main window.** Read-only lookups
run in the panel as usual, but if a panel chat proposes a file
change (Phase 6), the panel shows the plan with a note — "This
needs your approval in the main window" — and an **Open** button
that takes you straight to it. Undoing a finished change is a
main-window action too; the panel's plan cards render without the
Undo button. Chips for files already created work in the panel like
anywhere else.

**Quick questions stay quick, but not throwaway.** Each time you
summon the panel you get a fresh chat — unless you dismissed it less
than two minutes ago, in which case it reopens the same chat so a
thought you had mid-dismissal isn't orphaned. Opening a panel chat
in the main window, or letting the two minutes lapse, ends the
chain; the chat itself of course stays in the sidebar forever.

**One switch controls it.** Settings has **Enable the quick panel
(⌘⇧Space)**, on by default. Turning it off unregisters the shortcut
immediately — while it's off, ⌘⇧Space does nothing — and turning it
back on re-registers it, no relaunch either way. The hotkey is
registered with macOS's Carbon hotkey service, so it needs no
Accessibility permission. If the app isn't running, there's no
panel — the main window is still home; the panel is an extra door,
not a replacement.

## What's new in Phase 8

**The cloud tier: two ways to reach a bigger brain, both behind
the privacy check.** The model picker gains two cloud destinations,
and a chat using one wears a **Cloud** badge in its header so it's
never a surprise. Local models remain the default for almost
everything — the cloud is there for the prompts that genuinely
outgrow this Mac.

**Apple Private Cloud** is Apple's own cloud model: it runs on
Apple's servers under Apple's privacy design (requests aren't
stored or used for training), has a much bigger memory than the
built-in model, and needs no key or account — macOS decides whether
it's available on your Mac, and the picker says so when it isn't.
It costs nothing beyond having the Mac. It can also make lookups
(calendar, files, photos…): because the answers would leave the
Mac, **every lookup result passes the privacy check before it's
sent** — the one door results can't slip around. Note that Private
Cloud is *not* "local": while **Local Only** is on, it's refused
like any other off-Mac destination, because Local Only means
nothing leaves the machine.

**OpenRouter** is one key that opens the frontier models from
every major lab, billed per reply to your own OpenRouter account.
The shortlist in the picker was checked against OpenRouter's live
model list when this version was built (October 2026): **Claude
Opus 5.5** and **Claude Sonnet 5.5** (Anthropic), **GPT-6 Astra**
and **GPT-6.1 Sol** (OpenAI), **Gemini 3.8 Flash** (Google's most
capable model there at the time), and **Kimi K3.1 Pro** (Moonshot's
open-weight flagship). Any other model on OpenRouter can be added
from Settings → **Cloud models** by typing its model id. OpenRouter
chats are text-only for now: no lookups, no file changes — the same
deal server chats have always had.

**Your key, your Keychain.** The app ships with **no key**, and
everything local works without one. When you're ready, paste your
OpenRouter key into Settings → Cloud models: it's stored in this
Mac's **Keychain** — nowhere else, never in a settings file — and
is only ever sent to OpenRouter itself, as the sign-in for your
requests. Add it whenever you like (today, next month, never);
until then the OpenRouter rows in the picker simply say they need
your key. Removing the key is one button in the same place.

**Auto's cloud route is live.** Before Phase 8, a prompt Auto
judged "needs a frontier cloud model" went to the best local
stand-in, with a note. Now it goes to the cloud for real: to
OpenRouter's strongest shortlisted model when your key is saved,
otherwise to Apple Private Cloud, and only if neither is available
does a local model stand in — with the note now telling you what
would unlock the real route. Under Local Only, Auto never routes
to the cloud at all. Either way, the header note says which model
got the message, and the **privacy check runs first, always**: the
instructions, the message, and any folded-in history are scrubbed
of secrets and personal details before anything leaves, and a
banner tells you when something was hidden.

**Honest costs.** A cloud reply's pill (under the answer) shows
the real cost OpenRouter reported for that reply — usually a
fraction of a cent, shown as $0.0042 rather than rounded away. If
OpenRouter doesn't report a cost, the pill says **cost unknown**
instead of pretending the reply was free. Private Cloud replies
show $0.00 (Apple includes it), labeled as Apple's cloud.

**Compare two models, side by side.** The new split-rectangle
button in the chat header opens compare mode: pick any two models
— local or cloud — type one question, and both answers stream in
together, each with its own pill. It's a single fresh question (no
chat history, no lookups), which makes it the cleanest way to feel
the difference between models. **Continue with this one** under an
answer turns that exchange into a normal chat on the winning model
and switches you to it, question and answer already in place.

## What's new in Phase 9

Phase 9 adds the **power tools** — the app's riskiest capabilities,
kept for last on purpose and **off by default**: running shell
commands, and calling tools on your own local MCP servers. They sit
behind one master switch (Settings → **Power tools**) and, exactly
like file changes, they are **propose-only**: a model's call just
adds an item to the chat's approval list, and nothing runs until you
press Approve there. Proposals, approvals, skips, and results are
all written to the activity log, like everything else.

**Running commands.** The model can propose a `zsh` command — the
approval card shows the **exact command text** (monospaced) and the
folder it would run in, which must be one of your shared folders
(there's no way to propose a command that runs somewhere else). On
approval it runs with a plain environment (a standard PATH and your
home folder; your shell profile is *not* loaded, so the command
behaves the same every time), it gets **at most 30 seconds** before
the app stops it, and the card records how it ended — exit code and
duration — plus what it printed (the model is told the same; very
long output is trimmed to its last part, with a note saying so).
Good uses: looking at a git diff, querying a local SQLite database,
running a script you've saved in a shared folder.

Extra care for dangerous commands: a built-in check scans each
proposed command for obviously destructive patterns — force-deleting
recursively (`rm -rf`), running as root (`sudo`), raw disk writes
(`dd`, writing to `/dev/disk…`), erasing or formatting a disk,
recursively changing permissions on system folders, unloading
system background services, force-quitting apps, shutting the Mac
down, and piping a download straight into a shell (`curl … | sh`).
A command that matches lands on the list **unchecked, with the
reason shown**; it only runs if you deliberately check its box
first. (Any item on the list can be unchecked the same way — an
unchecked item is recorded as skipped, and the model is told it was
deliberately left out.)

**MCP servers.** MCP (Model Context Protocol) servers are programs
that offer their own tools to a model — a filesystem server, a
database server, and so on. Add your own in Settings → Power tools:
a name, the launch command (like `npx` or `uvx`), and its arguments.
The app starts a server **lazily** — the first time a chat needs its
tools — talks to it over its standard input and output (stdio), and
stops it when you switch it off, remove it, or quit the app. Each
server's tools appear in chats under the server's name, and calling
one is **propose-only** too: the approval list shows the server, the
tool, and the exact arguments (as JSON), and the call runs only on
your Approve, with the server's answer shown on the card. If a
server won't start or stops answering, its tools quietly disappear
and Settings shows what happened, with a **Try Again** button — a
broken server never blocks a chat. Only local stdio servers are
supported in this phase; hosted or HTTP MCP servers are not.

**The honest limits.** There is **no sandbox** around an approved
command or server call beyond the shared-folder rule and your
approval: a command you approve runs with *your own full
permissions*, starting in the folder shown — where it goes from
there is up to the command. Commands and server calls **cannot be
undone** (the card says so before you approve; Undo still covers
any file changes in the same list). The dangerous-pattern check is
a seatbelt, not a vault: it catches the obvious disasters, it can't
understand everything a shell can do, and it never replaces reading
the command yourself — that's why the approval card shows the exact
text. Two smaller limits: a server's arguments are typed separated
by spaces (an argument containing a space can't be entered yet),
and MCP results are shown as text (a tool that returns an image
gets a placeholder line instead).

To try it: turn on **Power tools** in Settings, share a folder if
you haven't, and ask the model to run `git status` in it.

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
  privacy check, the telemetry pill, the calculator, the
  shared-folder scope check, tool arguments and result trimming, and
  the tool runtime's on/off and permission gates, plus the
  file-action layer: proposal validation, the
  never-overwrite rule, undo planning, and the photo-resize
  arithmetic, plus the quick panel's context rules (what the chips
  show, what gets folded into a prompt, how a panel chat is titled,
  and when a summon continues the last panel chat instead of
  starting fresh), plus the power tools: which commands get
  flagged as dangerous, how command output is trimmed, MCP server
  naming and settings, and the MCP wire format itself) and never
  call the real model.

## Where this is going

This is phase 9 of a larger build (see the project plan): the main
window and the quick panel are both in place — two front doors over
one engine — the cloud tier (Apple Private Cloud + OpenRouter) sits
behind Phase 4's privacy check, so local stays the default and the
cloud is a labeled, costed choice, and the power tools (shell + MCP)
now sit behind the same propose-and-approve gate as everything
that acts. What remains is the final polish pass.
