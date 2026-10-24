# Blink

Blink is a native chat app for your Mac that is **local first**. It
chats with the AI model built into macOS (Apple Intelligence), with
bigger models you download onto the Mac, with local model servers you
already run, and — only when you choose — with Apple's Private Cloud
or frontier cloud models through OpenRouter. Its real difference from
the cloud chat apps is that it **lives on your Mac**: with your
permission it can look things up across your files, calendar, photos,
contacts, and music to answer you, and it can *propose* changes —
renaming files, resizing a photo, even running a command — that only
ever happen when you approve them.

Two front doors, one engine: the main chat window, and a quick panel
you summon from any app with **⌘⇧Space**.

## What Blink can do

### Chatting and models

- **Real streaming chat.** Replies appear as they're written, and you
  can stop a reply mid-stream — the partial answer is kept. Chats live
  in the sidebar (new, rename, delete; the first message names a chat
  automatically) and are saved on this Mac with SwiftData, so they're
  still there when you reopen the app. Nothing is stored anywhere
  else.
- **Markdown rendering**, including code blocks with a copy button.
  Keyboard: **⌘N** new chat, **Return** sends, **Shift+Return** starts
  a new line.
- **Per-chat instructions.** The quote-mark button in the chat header
  lets you tell the model how to behave in that one chat ("Be brief",
  "Explain like I'm a beginner"…). Empty means the built-in default.
- **A telemetry pill under every reply** — for example
  `Local MLX · Gemma 4 12B · 3.4s · ≈210 tokens · $0.00` — naming the
  model that actually answered, how long it took, roughly how big the
  reply is, and what it cost. Local models always cost $0.00.
- **Four kinds of model behind one picker** in the chat header; each
  chat remembers its own choice:
  - **Apple On-Device** — the model built into macOS. Free, offline,
    private. Its memory (its "context window") is 4,096 tokens, shared
    between instructions, tool definitions, and the conversation. A
    status pill says plainly if Apple Intelligence is off, not
    eligible, or still downloading the model.
  - **Downloaded MLX models** — bigger open models that run on your
    Mac's GPU. The catalog is sized for a Mac with 18 GB of memory:
    **Llama 3.2 3B** (small and fast, ≈1.9 GB), **Gemma 4 12B**
    (Google's model — the recommended default, ≈6.5 GB; it also
    natively understands images and audio), and **Qwen 2.5 14B** (the
    strongest local option that fits, ≈8.4 GB), each with a
    plain-English badge saying how it fits your Mac. Download from
    the Models panel with a progress bar; a cancelled download keeps
    its partial files (shown with their size, a **Resume** button,
    and a **Delete Partial** button, and counted in the on-disk
    total) instead of starting over. Downloaded models show their
    exact size on disk and can be deleted from the same panel. Only
    downloaded models appear in the picker, and the first reply after
    picking one takes a little while — the model has to load.
  - **Local servers** — if you run **Ollama** (`localhost:11434`) or
    **LM Studio** (`localhost:1234`), Blink can chat through the
    models they serve; the presets are listed in the Models panel —
    edit one to set the model name your server actually has. You can
    also add any other server that speaks the OpenAI chat API. The
    server app must be running when you send; if it isn't, the reply
    area tells you in plain English. Server chats are text-only (see
    Honest limits).
  - **Cloud models** — Apple Private Cloud and OpenRouter; see
    **Cloud** below.
- **Switching models mid-conversation is safe.** The new model is
  handed the chat's summary plus the recent messages, so the thread
  carries over. If a model you were using is deleted, the chat falls
  back to the built-in model with a visible note.
- **Long conversations manage themselves.** Before each message the
  app checks whether the conversation still fits the model's memory.
  When it gets close to full, the oldest messages are **summarized by
  the on-device model itself** into a running summary and the newest
  messages stay word-for-word; your instructions are never summarized
  away. A divider in the transcript — *"Earlier messages were
  summarized to fit the model's memory"* — marks where the summary
  takes over. **Nothing is deleted:** only the model's working memory
  is compacted; the full history stays in the app. If summarizing ever
  fails, the app falls back to a plain note of the topics covered, so
  a long chat never just breaks. Reopening a chat after a restart
  re-seeds the model the same way, so the thread isn't lost. Bigger
  models get bigger allowances: Private Cloud plans against a
  32,768-token window, MLX models against 8,192, OpenRouter against
  128,000.
- **Image attachments.** Attach pictures with the paperclip button,
  by dragging image files into the window, or by pasting (⌘V) with
  the composer focused — up to 4 per message. Images are shrunk to a
  sensible size and stored as JPEG with the message, shown as
  thumbnails in the transcript (click one to see it full-size in
  Preview), and sent to the model with your message so you can ask
  about them ("What's in this screenshot?", "Transcribe this
  receipt"). Each image is budgeted at roughly 400 tokens of model
  memory. If an attach fails (an unreadable file) or a drop brings
  more than 4, the app says so — "3 of 5 images attached" — instead of
  failing silently. Only the built-in and MLX models understand
  images, and images are **never sent to a remote destination** (see
  Privacy).
- **Model memory (KV cache).** An MLX model keeps a working memory
  of the conversation so far — the *KV cache* — which at full size
  can grow to several gigabytes on a long chat, next to the model's
  own ≈6.5 GB. Settings → **Local model memory** shrinks it: **8-bit**
  (the default) stores that memory in half the space with no
  noticeable change in answer quality, **4-bit** uses a quarter of
  the space with a little more quality risk, and **Off** keeps the
  full-size memory. It applies to downloaded MLX models only — the
  built-in model and local servers manage their own memory — and
  changing it simply restarts the chat's session (the conversation
  itself is kept).

### Auto routing

New chats start on **Auto**, and Auto is the recommended way to use
Blink. Before an Auto message is sent, the built-in on-device model
quickly sorts it into one of four kinds, and the app picks the
backend to match:

- **Something to do on this Mac** (files, calendar, photos…) → the
  built-in model, which is where the lookup tools live.
- **A quick edit or question** (summarize, rewrite, translate, a
  short simple question) → the built-in model: instant and private.
- **Hard work that should stay local** (code, long analysis, math) →
  your largest downloaded MLX model — or a local server if no model
  is downloaded, or the built-in model with a note if neither exists.
- **Something that really wants a frontier cloud model** → the cloud
  for real: OpenRouter's strongest shortlisted model when your key
  is saved, otherwise Apple Private Cloud, and only if neither is
  available does a local model stand in — with a note naming what
  would unlock the real route.

A quiet line under the chat header says what Auto decided and why
("Auto: a quick edit or question — Apple On-Device handles those
instantly and privately."). If the sorting step ever fails or takes
too long (it gets five seconds), the message just goes to the
built-in model — sorting never blocks a send. Picking a model
yourself in the picker overrides Auto completely, and chats you
already had keep the model you picked for them.

### Privacy

Local is the default and the design: the built-in and downloaded
models never send anything anywhere; lookups happen on the Mac;
sources are off until you turn them on, one by one. The protections
below guard the few paths that can leave the machine.

- **The privacy check (firewall).** Before anything is sent to a
  destination off this Mac — a cloud model, or a server you added
  whose address isn't this Mac — the text is scrubbed, automatically,
  every time: API-key-shaped tokens (`sk-…`, `ghp_…`, `AKIA…`, and
  friends), values after labels like `password:`, email addresses,
  phone numbers, card-number-shaped digit runs, long opaque tokens,
  and your own custom terms are replaced with `[redacted]`. The scrub
  covers your instructions and the fully assembled prompt, including
  seeded history and summaries, file-change outcome notes, and
  quick-panel context — a remote destination is always seeded with
  the running summary plus recent turns, never the raw full history.
  Your saved messages are never edited — only the copy that gets
  sent. A notice appears on **every** off-Mac send (and says how much
  was hidden when something was). Servers on `localhost` (Ollama, LM
  Studio) count as *on this Mac* and get your message exactly as
  written, as do the built-in and MLX models. Add your own words and
  phrases to hide (a project codename, an address) in Settings →
  **Privacy check**.
- **Lookup results are scrubbed too.** Private Cloud Compute can make
  lookups (calendar, files, photos…), but because the answers would
  leave the Mac, every lookup result passes the privacy check —
  custom terms included — inside the tool layer before it can enter
  a cloud prompt. Local models keep raw results.
- **Images never leave.** The firewall scrubs text; it can't scrub a
  screenshot, which is exactly where secrets hide. So an image
  attached to a message is simply not sent to a remote destination —
  the saved message keeps it, and the app tells you the image was
  left out.
- **Local Only lock.** Settings' top switch guarantees nothing is
  sent anywhere: server backends and **both** clouds are refused
  outright (not just hidden) — Private Cloud included, because Local
  Only means nothing leaves the machine. Auto never routes off the
  Mac, a chat that was using a server switches to the built-in model
  with a note explaining why, and a small **Local Only** badge shows
  in the chat header while the lock is on. Under the lock, MCP
  servers don't even launch, and any pending power-tool item refuses
  at approval time with a lock note.
- **Your OpenRouter key lives only in the macOS Keychain** — nowhere
  else, never in a settings file. Routing only ever learns *that* a
  key exists, never the key itself.
- Conversations are stored on this Mac with SwiftData and exported
  only when you ask.

### Eyes on your Mac — the lookup tools

The model can *look things up on your Mac* to answer you — read-only,
and only ever where you've said it may. Everything is off until you
turn it on, and everything it looks at is written down where you can
see it.

**Turning it on.** Settings → **What this app can see**. Each source
has its own switch, off by default. Fifteen small, single-purpose
tools ride on those sources:

- **File search** (Spotlight) — find files by name or by words
  inside them.
- **Shared folders** — list a folder's contents and read text files,
  *only inside folders you pick* with the Add Folder button. A folder
  is granted by picking it (macOS keeps a security bookmark); there
  is no way to type in a path and widen it. Nothing outside those
  folders can be read — not by path tricks (`..`), not by a
  differently-spelled sibling folder, not through a symlink pointing
  out: every candidate path is symlink-resolved and checked against
  the shared roots before anything is read.
- **Calendar** — events coming up (seven days ahead by default).
- **Reminders** — your unfinished reminders.
- **Contacts** — look up a name, get the phone/email as stored.
- **Photos** — list recent photos (date and size only — never the
  pictures themselves) and read the text visible in one specific
  recent photo (on-device OCR).
- **Music library** — search songs by title, artist, or album. (One
  honest gap: a **now playing** tool exists but can only explain
  itself — macOS gives apps no public way to see what another app is
  playing; see Honest limits.)
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
Privacy & Security). If a source is on but macOS hasn't decided yet,
the in-chat refusal points you at the **Allow…** button in Settings
rather than telling you to turn on what's already on. One wrinkle:
macOS phrases those prompts using the packaged app's permission
notes, which ship in the app bundle built by `Scripts/make-app.sh`
(see Getting started) — when you run from Xcode instead, macOS
attributes access to Xcode, and the panel will tell you if a grant
isn't landing.

**The access log.** Every lookup is recorded — when, which tool,
what it asked, a one-line summary of what it found — and shown two
ways: as a small card in the chat, right where it happened, and in
Settings under **Recent activity**. The newest 300 are kept, and
there's a Clear button. If a model ever looks at something, there is
a card saying so; there is no silent looking. Lookup results are
also kept small on purpose — trimmed to about 1,200 characters, with
a note when they were trimmed — because the on-device model's memory
window is small and a huge search result would crowd out your
conversation.

**Which models can look.** Lookups work with the Apple On-Device
model, downloaded MLX models, and Private Cloud Compute (with its
results scrubbed, per Privacy above). On an Auto chat, "do something
on my Mac" questions route to the on-device model, which is the
primary tools engine. Server chats (Ollama / LM Studio) and
OpenRouter chats can't make lookups; if you've turned sources on, a
server chat shows a short note saying so rather than pretending.

### Hands, with permission — file changes

The model can also *propose changes* to files inside your shared
folders. Proposing is all a tool call can do: the model can never
change anything by itself, and every change waits for you.

**The switch.** Settings → **File changes** — off by default, and
separate from the read switches on purpose. While it's off, the
file-action tools don't exist for any model. While it's on, the
model gains seven propose-only tools: **rename** (including batches),
**move**, **copy**, **create folder**, **edit a text file** (replace
its contents, or add at the end; it can also create the file),
**move to Trash**, and **resize a photo**.

**How proposing works.** When the model wants to change something,
the change lands on a list pinned above the message box:
*"Rename “IMG_2049.jpg” → “beach-sunset.jpg” in ~/Downloads"*, one
line per change, in plain English, each with a checkbox. You can
uncheck or remove individual changes, **Discard** the whole list, or
**Approve** it. Only Approve touches the disk: the app then runs
each checked change in order, re-checking every safety rule against
the disk as it is at that moment, and each change reports its own
result on a card in the chat — done, or exactly why it couldn't. One
failure doesn't stop the rest. The model is told the outcome with
your next message, so the conversation carries on knowing what you
decided — including when you discard, so it doesn't quietly
re-propose the same list.

**The safety rules** (checked when a change is proposed, and checked
*again* when you approve):

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
  the same log as the lookups (Settings → **Recent activity**) and
  shown as cards in the chat.

**Undo.** Every approved list's card keeps an **Undo** button.
Undo runs newest-change-first: renames and moves go back where they
came from, copies and created files go to the Trash, a created
folder is removed *only if it's still empty*, an edited file gets
its backed-up contents back (the edited version goes to the Trash,
so undo loses nothing itself), and a trashed item is pulled back out
of the Trash. The honest limits: undo never overwrites either — if
something new sits in the original spot, that item stays put and the
card says why; a folder that has gained files is left alone; and if
macOS didn't tell the app where a trashed item landed, that one item
can't be pulled back automatically (it can always be dragged back
from the Trash in Finder).

**Resizing a photo** (for uploads with size limits, email, sharing).
Point it at a recent library photo or at an image file in a shared
folder, with a maximum width (default 1200 px) and a JPEG size limit
(default about 500 KB). The app scales the photo down, then saves it
as a JPEG, stepping the quality down until the file fits the limit;
if even the lowest quality is too big, it shrinks the photo a step
and tries again — and if it still can't fit, you get the smallest
version it could make, with the card saying so. The original is
never touched; the resized copy is a new file (named like the
original, with "-resized" added, unless you asked for a specific
place), and when the change is approved the copy is **also put on
your clipboard**, ready to paste.

**Artifact chips.** Any file an approved change creates — the
resized photo, a copy, a new text file — appears on the plan's card
as a small pill with its name and size. The pill is the file: drag
it straight into a browser upload, Finder, or another app. If the
file is later moved or deleted somewhere else, the pill stays on
the card, greyed out and marked "missing", rather than vanishing
from the record.

### The quick panel (HUD)

**The same chat, one keystroke away.** While Blink is running, press
**⌘⇧Space** anywhere — in Safari, in Finder, in the middle of an
email — and a small floating panel appears near the top of the
screen. Type a question, press Return, and the answer streams right
there in the panel. It's not a separate mini-app: a panel chat runs
through exactly the same machinery as the main window (Auto routing,
the lookups, the privacy check, the telemetry pill), against a real
conversation that's saved in the sidebar, titled "Quick — …" after
your first message. Follow-ups work in the panel like anywhere else.
Esc, pressing the shortcut again, or clicking away dismisses it;
**Open in main window** (or **⌘Return**) brings the conversation up
in the main window instead.

The panel doesn't steal your place: it floats without activating
Blink, so the app you were using stays in front — which is also what
keeps its context (below) truthful. The shortcut is registered with
macOS's Carbon hotkey service, so it needs no Accessibility
permission. If Blink isn't running, there's no panel — the main
window is still home; the panel is an extra door, not a replacement.
(Turning on **Open at login** in Settings keeps the panel always
ready.)

**It quietly notes what you were in the middle of.** When the panel
opens it shows small chips for the context it captured: which app
was in front, and whether the clipboard currently holds text, an
image, or something else. Two captures follow the same switches as
everything else: the clipboard's actual *text* is included only
when the **Clipboard** source is on (and only the first 1,500
characters, with a note if it was longer), and the **Finder
selection** is read only when the **Shared folders** switch is on —
macOS will ask once for permission to let Blink talk to Finder, and
declining simply means no chip, never an error. That context is
written into the first message of a panel chat (only the copy sent
to the model — your typed message is stored exactly as typed, and
the context passes the privacy check like everything else), so
"resize this" or "summarize this" can mean the file you just
selected. One thing isn't captured: a selection in the **Photos**
app — only Finder selections are read.

**Approvals still happen in the main window.** Read-only lookups run
in the panel as usual, but if a panel chat proposes a file change,
the panel shows the plan with a note — "This needs your approval in
the main window" — and an **Open** button that takes you straight to
it. There is no Approve button in the panel, and decided-plan cards
render there without their Undo button. Chips for files already
created work in the panel like anywhere else.

**Quick questions stay quick, but not throwaway.** Each time you
summon the panel you get a fresh chat — unless you dismissed it less
than two minutes ago, in which case it reopens the same chat so a
thought you had mid-dismissal isn't orphaned. Opening a panel chat
in the main window, or letting the two minutes lapse, ends the
chain; the chat itself of course stays in the sidebar.

**One switch controls it.** Settings → **Enable the quick panel
(⌘⇧Space)**, on by default. Turning it off unregisters the shortcut
immediately — while it's off, ⌘⇧Space does nothing — and turning it
back on re-registers it, no relaunch either way. If another app
already owns ⌘⇧Space, registration fails quietly and the main window
is unaffected.

### Cloud

The model picker has two cloud destinations, and a chat using one
wears a **Cloud** badge in its header so it's never a surprise.
Local models remain the default for almost everything — the cloud is
there for the prompts that genuinely outgrow this Mac. Both clouds
sit behind the privacy check (see Privacy), and both are refused
under **Local Only**.

**Apple Private Cloud** is Apple's own cloud model: it runs on
Apple's servers under Apple's privacy design (requests aren't stored
or used for training), plans against a much bigger 32,768-token
memory than the built-in model, and needs no key or account — macOS
decides whether it's available on your Mac, and the picker says so
plainly when it isn't. It can make lookups (calendar, files,
photos…) — with every result scrubbed first, per Privacy. Its
replies show $0.00 on the pill, labeled "Cloud · Apple Private
Cloud" — Apple includes it.

**OpenRouter** is one key that opens the frontier models from every
major lab, billed per reply to your own OpenRouter account. The
shortlist in the picker was checked against OpenRouter's live model
list on **October 23, 2026**: **Claude Opus 5.5** and **Claude Sonnet
5.5** (Anthropic), **GPT-6 Astra** and **GPT-6.1 Sol** (OpenAI),
**Gemini 3.8 Flash** (Google's most capable model listed there at
the time — no Gemini Pro text model was on OpenRouter that day),
and **Kimi K3.1 Pro** (Moonshot's open-weight flagship). Any other
model on OpenRouter can be added from Settings → **Cloud models** by
typing its model id. OpenRouter chats are text-only: no lookups, no
file changes — the same deal server chats have.

**Your key, your Keychain.** The app ships with **no key**, and
everything local works without one. When you're ready, paste your
OpenRouter key into Settings → **Cloud models**: it's stored in this
Mac's **Keychain** — nowhere else, never in a settings file — and is
only ever sent to OpenRouter itself, as the sign-in for your
requests. The Settings field never reads the saved key back; removing
it is one button in the same place. Add it whenever you like (today,
next month, never); until then the OpenRouter rows in the picker
simply say they need your key and can't be sent to — and if one is
somehow requested anyway, the app falls back to the built-in model
and names the missing key as the reason.

**Honest costs.** A cloud reply's pill shows the real cost
OpenRouter reported for that reply — usually a fraction of a cent,
shown as $0.0042 rather than rounded away. If OpenRouter doesn't
report a cost, the pill says **cost unknown** instead of pretending
the reply was free. Cloud failures are worded plainly too: a
rejected key, out of credit, a rate limit, or an unreachable service
each gets its own message.

### Compare mode

The split-rectangle button in the chat header opens **Compare**: pick
any two models — local or cloud — type one question, and both
answers stream in together, side by side, each with its own
telemetry pill. It's a single fresh question (no chat history, no
lookups, no memory compaction), which makes it the cleanest way to
feel the difference between models. **Continue with this one** under
an answer turns that exchange into a normal chat on the winning
model and switches you to it, question and answer already in place.

Compare plays by the same rules as chat: a remote column's prompt is
scrubbed by the privacy check first, and the off-Mac notice shows on
every remote send, just like in a chat. And it's honest about what
answered: if a pick can't run — say, a cloud model while Local Only
is on, or with no key saved — the sheet says so and names the fix
instead of asking, and if a run still ends up answered by a
stand-in, a notice under the column names the model that actually
answered. A local answer never appears under a cloud model's name.

### Power tools

The app's riskiest capabilities, **off by default**: running shell
commands, and calling tools on your own local MCP servers. They sit
behind one master switch (Settings → **Power tools**) and, exactly
like file changes, they are **propose-only**: a model's call just
adds an item to the chat's approval list — with a checkbox, like
every other item — and nothing runs until you press Approve there.
Proposals, approvals, skips, and results are all written to the
activity log, like everything else. While the master switch is off,
neither tool exists for any model.

**Running commands.** The model can propose a `zsh` command — the
approval card shows the **exact command text** (monospaced) and the
folder it would run in, which must be one of your shared folders,
checked when proposed and again when approved (there's no way to
propose a command that runs somewhere else; if no folder is shared,
the tool refuses and says why). On approval it runs with a plain
environment — a standard PATH, no login shell, so your shell profile
is *not* loaded and the command behaves the same every time. It gets
**at most 30 seconds** before the app stops it (recorded as timed
out), and the card records how it ended — exit code and duration —
plus what it printed. The model is told the outcome too; very long
output is trimmed to its last ≈4,000 characters, with a note saying
so. Good uses: looking at a git diff, querying a local SQLite
database, running a script you've saved in a shared folder.

Extra care for dangerous commands: a built-in check scans each
proposed command for obviously destructive patterns — running as
root (`sudo`), force-deleting recursively (`rm -rf` and its flag
variants), raw disk writes (`dd`, output to `/dev/…`), erasing or
formatting a disk (`mkfs`, `diskutil erase…`), recursively changing
permissions on system folders, unloading system background services,
force-quitting apps (`killall`), shutting the Mac down, and piping a
download straight into a shell (`curl … | sh`). A command that
matches lands on the list **unchecked, with an orange warning naming
the reason**; it only runs if you deliberately check its box first.
Approving the list with it still unchecked records it as skipped —
never runs it — and the model is told it was deliberately left out.

**MCP servers.** MCP (Model Context Protocol) servers are programs
that offer their own tools to a model — a filesystem server, a
database server, and so on. Add your own in Settings → Power tools:
a name, the launch command (like `npx` or `uvx`), and its arguments.
The app starts a server **lazily** — the first time a chat needs its
tools — talks to it over its standard input and output (stdio, the
MCP protocol over JSON-RPC), and stops it when you switch it off,
remove it, or quit the app. Each server's tools appear in chats
under names like `mcp.<server>.<tool>`, with the server's own
descriptions. Calling one is **propose-only** too: the approval list
shows the server, the tool, and the exact arguments (as JSON), and
the call runs only on your Approve (30-second limit), with the
server's answer shown on the card and capped for the model the same
way command output is. If a server won't start or stops answering,
its status shows in plain English in Settings, with a **Try Again**
button, and its tools quietly disappear — a broken server never
blocks a chat, and it isn't retried until you edit it, re-enable it,
or press Try Again. Only local stdio servers are supported; hosted
or HTTP MCP servers are not.

**The honest limits.** There is **no sandbox** around an approved
command or server call beyond the shared-folder starting rule and
your approval: a command you approve runs with *your own full
permissions*, starting in the folder shown — where it goes from
there is up to the command. Commands and server calls **cannot be
undone** (the card says so before you approve; Undo still covers any
file changes in the same list). The dangerous-pattern check is a
seatbelt, not a vault: it catches the obvious disasters, it can't
understand everything a shell can do, and it never replaces reading
the command yourself — that's why the approval card shows the exact
text. Two smaller limits: a server's arguments are typed separated
by spaces (an argument containing a space can't be entered yet),
and MCP results come back as text (a tool that returns an image
gets a placeholder line).

To try it: turn on **Power tools** in Settings, share a folder if
you haven't, and ask the model to run `git status` in it.

### Chat search and export

- **Search.** The sidebar has a search field: type and the list
  narrows to chats whose **title or messages** contain the text
  (matching ignores case and accents — "cafe" finds "café", and
  irregular spacing in what you type is fine). A chat that matched
  inside its messages shows a one-line snippet of the first matching
  message under its title; clearing the field brings the full list
  back.
- **Export.** Right-click a chat in the sidebar (or use the share
  button in an open chat's header) for **Export as Markdown…** — the
  standard save panel, pre-named after the chat — or **Copy as
  Markdown**. The file is a clean Markdown document: the chat title,
  started/last-updated/exported stamps, then one section per message
  with its date and role, the telemetry pill as an italic line under
  each assistant reply, and an "_[N images attached]_" note where a
  picture was attached (images can't live in a text file — the
  pictures themselves stay in the app).

## Requirements

- A Mac with **Apple Silicon** running **macOS 27**
- **Xcode 27** (to build it — there's no prebuilt download)
- **Apple Intelligence turned on** (System Settings → Apple
  Intelligence & Siri) for the built-in model. The app checks for
  this and explains, in plain English, if something isn't ready —
  e.g. the model is still downloading.
- Optional, only if you want them: an **OpenRouter API key** for the
  frontier cloud models; disk space for downloaded models (the
  recommended one is ≈6.5 GB); **Ollama** or **LM Studio** if you'd
  rather serve local models that way.

## Getting started

Get this folder onto your Mac first (clone the repo, or pull the
latest version if you already have it). Then pick a path:

### Path A — run it from Xcode

1. Open the **folder** in Xcode 27 (File → Open, pick the folder that
   contains `Package.swift`). This is a Swift Package, not an Xcode
   project file — that's expected.
2. Wait a few seconds for Xcode to finish indexing, then press the
   **Run** button (▶) in the toolbar, or press **⌘R**.
3. The app window opens. Press **⌘N** (or the pencil button) to start
   a chat and type away.

First compile happens entirely on your Mac — expect the first build
to take a few minutes. One trade-off of this path: when you run from
Xcode, macOS attributes permission requests to **Xcode**, not to
Blink. Day-to-day chatting is fine that way; for the real permission
experience (prompts in Blink's own name, opening at login), use
Path B.

### Path B — build the double-clickable app

1. In Terminal, in this folder, run:  `bash Scripts/make-app.sh`
   (Running it through `bash` like that means no `chmod` is needed;
   the script is not marked executable in the repo, on purpose.)
2. The script builds the app in release mode, assembles
   **`.build-app/Blink.app`** — executable, permission notes
   (Info.plist), and icon — and signs it: with your Apple Development
   or Developer ID identity if you have one, otherwise ad-hoc.
3. Drag the `.app` into your **Applications** folder.
4. First launch of an ad-hoc signed app: **right-click → Open → Open**
   (Gatekeeper asks once because the app wasn't signed with an Apple
   identity; after that it opens with a normal double-click).

The app's name — **Blink** — and its bundle id
(`com.baiweicheng.localllm`) are single variables at the top of
`Scripts/make-app.sh`; the bundle always comes out as `Blink.app`.
(The code module keeps the internal name "LocalLLM" — plumbing
you'll see in a few folder names like `Sources/LocalLLM`. It doesn't
affect using the app. Note that changing the bundle id would make
macOS treat Blink as a different app, with fresh permissions and
settings.)

## First-run checklist

Work through this once, top to bottom, the first time you run Blink.
Each step says what you should see when it works — so the checklist
doubles as a smoke test. Steps marked *(optional)* are safe to skip
and come back to.

### Build and first launch

- [ ] **Clone or pull the latest code**, then open the folder in
  Xcode 27, wait for indexing, and press **Run** (⌘R). The first
  build takes a few minutes.
  *You'll see:* the main window opens — a sidebar on the left, an
  empty chat area on the right.
- [ ] **Run the tests** (Product → Test, or ⌘U). There are 351 of
  them, covering the behind-the-scenes logic; they never call a real
  model. If any fail on a fresh pull, that's worth reporting before
  going further.
- [ ] **Check the model status.** If Apple Intelligence is off, still
  downloading its model, or your Mac isn't eligible, the header pill
  and banner say which, in plain English, and what to do about it.

### Your first chats

- [ ] **Start a chat** (⌘N) and ask something quick — "Rewrite this
  more politely: …" works. New chats start on **Auto**.
  *You'll see:* the reply streams in; a line under the header says
  what Auto decided; the pill under the reply names the model
  (Apple On-Device), the seconds it took, and $0.00.
- [ ] **Stop a reply halfway.** Ask for something long and press
  **Stop** mid-stream.
  *You'll see:* the partial answer stays in the chat.
- [ ] **Quit and relaunch**, then reopen that chat and ask a
  follow-up.
  *You'll see:* the full history is intact, and the model still
  follows the thread.
- [ ] **Attach an image** (paperclip, drag-and-drop, or paste) and
  ask about it — "What's in this screenshot?"
  *You'll see:* a thumbnail in your message; the built-in model
  answers about the picture.

### A bigger local model

- [ ] **Download Gemma 4 12B.** Header → chip/CPU button → **Manage
  Models…** → **Download** (≈6.5 GB).
  *You'll see:* a progress bar with per-file progress. (Try
  **Cancel** partway if you like: the partial download stays listed
  with its size and a **Resume** button, and its bytes count in the
  panel's on-disk total.)
- [ ] **Chat on Gemma.** Open a chat, pick **Gemma 4 12B** in the
  header picker, and send a message.
  *You'll see:* the first reply takes a while (the model is
  loading), then streams; the pill reads `Local MLX · Gemma 4 12B ·
  … · $0.00`.
- [ ] *(Optional)* **Change the model memory.** Settings → **Local
  model memory** → switch 8-bit to 4-bit, then send another MLX
  message.
  *You'll see:* the reply works as before — the session quietly
  rebuilds under the new setting.

### The quick panel

- [ ] **Summon it from another app.** With Blink running, click into
  Safari or Finder, then press **⌘⇧Space**.
  *You'll see:* the panel floats near the top of the screen, and a
  chip names the app you were just in (it stays in front). **Esc**
  dismisses the panel.
- [ ] **Ask something in the panel**, then look at the main window's
  sidebar.
  *You'll see:* a new chat titled "Quick — …" holding the exchange.
  Summon the panel again within two minutes and it reopens that same
  chat; **⌘Return** moves it into the main window.

### Let it see something

Do these in the **packaged app** (Path B) for the real permission
prompts — under Xcode, macOS attributes the prompts to Xcode.

- [ ] **Turn on Calendar.** Settings → **What this app can see** →
  Calendar on; macOS asks — choose **Allow**. Then ask: "What's on
  my calendar this week?"
  *You'll see:* a small lookup card in the chat, the answer, and the
  same lookup listed in Settings → **Recent activity**.
- [ ] **Repeat for any other sources you want** — Reminders,
  Contacts, Photos, Music. Each asks its own permission the first
  time; ask the matching question ("Any reminders due?", "What's
  Alex's email?", "What are my recent photos?", "Find songs by…").
- [ ] **Share a folder.** In the same Settings section, under the
  Files switch, use **Add Folder…** and pick one (Downloads is a good
  test). Ask: "What's in my Downloads folder?" Then ask for a
  specific file *outside* the shared folder.
  *You'll see:* the listing works; the outside request is refused,
  naming your shared folders.
- [ ] **Try the Finder-selection chip.** Select a few files in
  Finder, summon the panel with ⌘⇧Space, and ask "Summarize this."
  The first time, macOS asks to let Blink control Finder
  (Automation) — **Allow**.
  *You'll see:* a chip showing how many items are selected, and the
  answer refers to those files.

### Let it act

- [ ] **Propose a file change.** Settings → **File changes** → on.
  In a chat, ask: "Rename `IMG_0001.jpg` in my Downloads to
  `beach.jpg`" (use a real file of yours).
  *You'll see:* a proposed-changes card above the message box — and
  nothing has changed on disk yet. Try **Discard** once to see the
  flow; then ask again and **Approve**, check the file in Finder,
  and press **Undo** on the finished card to watch it go back.
- [ ] **Resize a photo.** Ask: "Resize my most recent photo to
  1200 px wide, under 500 KB," and approve.
  *You'll see:* the new file next to the original (name ends in
  "-resized"), a draggable chip on the card — and the resized JPEG
  is on your clipboard: paste (⌘V) into any app to prove it.

### Cloud (optional)

- [ ] **Add your OpenRouter key.** Settings → **Cloud models** →
  paste your key (it goes into the macOS Keychain). Pick **Claude
  Opus 5.5** in a chat's picker and send a message.
  *You'll see:* a **Cloud** badge in the chat header; the pill shows
  the real cost (something like $0.0042), or "cost unknown" if
  OpenRouter didn't report one.
- [ ] **Watch Auto use the cloud.** In an **Auto** chat, ask a
  frontier-style question (hard reasoning, or very current world
  knowledge).
  *You'll see:* the header note says the message went to OpenRouter,
  and a privacy notice appears — one shows on every off-Mac send.
- [ ] **Try Private Cloud** (if the picker offers it — macOS
  decides). Chat with it, then ask it to look something up ("What's
  on my calendar?").
  *You'll see:* it answers using the lookup, with the result
  scrubbed by the privacy check on its way out.
- [ ] **Compare two models.** Header → compare button → pick two
  local models and ask one question.
  *You'll see:* both answers stream side by side, each with its own
  pill. **Continue with this one** turns the winner into a normal
  chat.

### Package it and make it yours

- [ ] **Build the app bundle** (if you haven't): `bash
  Scripts/make-app.sh`, drag `.build-app/Blink.app` to Applications,
  and open it (right-click → Open the first time, if it's ad-hoc
  signed). Redo the "Let it see something" steps here so the
  permission prompts carry Blink's name.
  *You'll see:* the icon — a blue-to-violet rounded square with a
  white spark — in Applications.
- [ ] **Open an MLX chat in the packaged app.**
  *You'll see:* Gemma answers as before — this proves the bundled
  model libraries work outside Xcode.
- [ ] **Turn on Open at login.** Settings → **General** → **Open at
  login** (packaged app only). Check System Settings → General →
  Login Items agrees — macOS may ask you to approve it there.
- [ ] **Set your defaults.** Settings → **General**: pick the model
  new chats start with (Auto is the recommended default). Settings →
  **Instructions library**: save a named set ("Be brief", "Beginner
  mode") and apply it to a chat from its quote-button editor.

### If something looks wrong

- **⌘⇧Space does nothing** — Blink isn't running, the quick-panel
  switch is off in Settings, or another app already owns the
  shortcut (registration fails quietly by design).
- **A permission grant "isn't landing"** — you're running from
  Xcode, so macOS attributes access to Xcode. Use the packaged app
  (Path B) for the real prompts.
- **A chat says "Couldn't reach…"** — the local server app (Ollama /
  LM Studio) isn't running, or isn't serving the model named in the
  preset.
- **An MLX model fails to load once** — just send again; a transient
  load failure doesn't poison the chat anymore.
- **Music search fails only in the packaged app** — that points at a
  missing MusicKit entitlement in the bundle (an open question
  carried from the project's audit); it working under Xcode confirms
  the diagnosis.
- **One test fails about "bookmark" data** — a known test-fixture
  suspect: the fixture assumes garbage data fails bookmark
  resolution, and if your macOS accepts it, the test (not the app)
  needs a tougher fixture.

## Settings map

Everything lives behind the **gear button** in the chat header,
which opens the **Settings** sheet:

- **Local Only** (top switch) — the privacy lock: refuses every
  off-Mac destination outright. See Privacy.
- **Privacy check** — your custom redaction terms: words or phrases
  (a codename, an address) hidden before anything leaves this Mac.
- **General** — the **default model for new chats** (Auto, or any
  specific backend from the same list the chat picker shows; new
  chats started from the sidebar begin with it, existing chats keep
  theirs, and the quick panel always starts on Auto), and **Open at
  login** (only usable from the packaged app in Applications; the
  switch reads the system's real state, including "macOS wants you
  to approve this in System Settings → General → Login Items").
- **What this app can see** — the nine per-source switches (file
  search, shared folders, calendar, reminders, contacts, photos,
  music, system info, clipboard), the shared-folder list, and each
  source's permission state with where to fix a "no".
- **Recent activity** — the access log: every lookup, proposal,
  approval, and result, newest first, capped at the newest 300, with
  a **Clear** button.
- **File changes** — the master switch for propose-only file actions
  (rename, move, copy, create, edit, trash, resize). Off by default.
- **Local model memory** — the KV-cache setting for downloaded MLX
  models: Off / 8-bit (default) / 4-bit.
- **Cloud models** — the OpenRouter key field (Keychain; save or
  remove), and the custom model-id field for any other OpenRouter
  model.
- **Enable the quick panel (⌘⇧Space)** — the HUD switch, on by
  default.
- **Instructions library** — named instruction sets: create and edit
  them here, or save a chat's current instructions as a set from
  that chat's quote-button editor; apply one to any chat from the
  same editor. Applying copies the text into the chat, so editing a
  set later never rewrites a chat already using it.
- **Power tools** — the master switch (off by default), the honest
  warnings, and your MCP server list: add/edit/remove servers, each
  with its own enable switch and a plain-English status (with **Try
  Again** when one fails).

## Honest limits

Stated plainly, in one place:

- **What's playing right now can't be seen.** macOS gives apps no
  public way to see what another app is playing (the old private
  route was locked down in macOS 15.4), so the now-playing tool says
  exactly that instead of guessing.
- **The quick panel reads Finder selections, not Photos selections.**
  The frontmost-app chip still shows when you're in Photos — it just
  can't see what you've selected there.
- **MCP is local-stdio only** (no hosted or HTTP servers), a server
  argument containing a space can't be typed yet, and MCP results
  come back as text only.
- **Server chats (Ollama / LM Studio) have no lookups and no file
  changes**, and they receive text only — image attachments are
  understood only by the built-in and MLX models.
- **OpenRouter chats have no local tools** either — no lookups, no
  file changes.
- **Images never go to a remote destination** — they're stripped from
  the sent copy (with a notice), so a cloud chat can't see your
  screenshots.
- **Undo has edges:** it never overwrites, a created folder is
  removed only if still empty, a trashed item whose landing spot
  macOS didn't report can't be pulled back automatically, and
  commands and MCP calls can't be undone at all.
- **The built-in model is small** (~3 billion parameters). It's good
  at chat, summarizing, rewriting, and quick questions; Apple itself
  warns it's not the right tool for heavy math, coding, or factual
  deep-dives. That's what the bigger local models, Auto routing, and
  the cloud tier are for.
- **Approved commands run unsandboxed**, with your full permissions —
  the approval card and the dangerous-command flagging are the
  protection, so read the exact command before approving.

## For developers

This is a Swift Package (Swift 6 language mode, macOS 27) with no
`.xcodeproj`: the app target is `Sources/LocalLLM` (pure logic in
`Core/`, platform wrappers in `Services/`, SwiftUI in `Views/`),
tests in `Tests/LocalLLMTests`. Run the tests in Xcode with **Product
→ Test** (⌘U): 351 tests covering the behind-the-scenes logic —
instructions and token estimates, markdown splitting, context budgets
and compaction planning, summary merging, attachment storage,
model-picker persistence, download planning, server-request building
and stream parsing, routing decisions, the privacy check, telemetry
formatting, the calculator, the shared-folder scope check, tool
arguments and result trimming, the tool runtime's gates, file-action
validation and undo planning, photo-resize arithmetic, the quick
panel's context rules, dangerous-command flagging, command-output
trimming, MCP naming/settings/wire format, the instructions library,
the default-model setting, chat search, and the exporter's exact
Markdown — and they never call the real model. (During development
the pure logic was also validated with Python transliteration
harnesses.)

The product is named **Blink**; the code module keeps the internal
name **LocalLLM** (`Sources/LocalLLM`, UserDefaults keys, Application
Support folders, and the bundle id `com.baiweicheng.localllm`). The
split is deliberate — renaming the module would be a large refactor
for zero user benefit.

Nothing in this repo has been compiled off a Mac, so expect a
first-compile fix list when Xcode 27 first builds it — the risky
surfaces were kept small and contained on purpose, one file each:
the multimodal `Prompt`/`Attachment` path (`ChatEngine` and
`ChatBackend`), the @Generable symbols (`IntentClassifier`, the
shared tool-arguments struct in `FrameworkTool`), the MLX session
(`MLXBackend.swift` — the only file importing the MLX packages), the
PCC backend (`PCCBackend.swift`), the Carbon hotkey trampoline and
`NSAppleScript` walk (`HUDCoordinator`, `HUDContextCapture`), the
Keychain calls (`KeychainStore`), the shell/MCP process plumbing
(`ShellCommandService`, `MCPClient`), and `SMAppService`
(`LoginItemService`). Package pins and fallbacks are noted where
they live (start with `Package.swift`, including its
`.macOS(.v27)` spelling).

One packaging caveat: `swift build` places dependency resource
bundles next to the executable; `make-app.sh` copies any it finds
into the app bundle — if a packaged MLX chat ever reports a missing
Metal library, that's the step to check.

The phase-by-phase build history — ten phases, an audit, and a UAT
pass — lives in this repo's git history (`git log`), not in this
document.
