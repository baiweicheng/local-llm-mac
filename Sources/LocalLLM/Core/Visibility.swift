import Foundation

/// Phase 5: the local visibility layer.
///
/// Everything in this file is pure data and pure logic — what the
/// sources are, what the tools are, how arguments and results are
/// shaped, how big a result may get, and what the access log keeps.
/// The framework-facing halves (EventKit, PhotoKit, Spotlight, the
/// model runtimes) live in the services layer and are built on top of
/// these definitions, so this file is fully unit-testable with no live
/// system access at all.

// MARK: - Visibility sources

/// One thing the app can be allowed to look at. Each source sits
/// behind its own Settings toggle (default OFF) and, where macOS has a
/// permission for it, its own system permission.
enum VisibilitySource: String, CaseIterable, Sendable {
    case spotlight
    case files
    case calendar
    case reminders
    case contacts
    case photos
    case music
    case system
    case clipboard

    var displayName: String {
        switch self {
        case .spotlight: return "File search (Spotlight)"
        case .files: return "Shared folders"
        case .calendar: return "Calendar"
        case .reminders: return "Reminders"
        case .contacts: return "Contacts"
        case .photos: return "Photos"
        case .music: return "Music library"
        case .system: return "About this Mac"
        case .clipboard: return "Clipboard"
        }
    }

    /// One plain-English line for the Settings panel: what turning
    /// this on lets the model do.
    var settingsBlurb: String {
        switch self {
        case .spotlight:
            return "Find files by name or by words inside them."
        case .files:
            return "Read text files and list folders — only inside folders you pick below."
        case .calendar:
            return "See upcoming events when you ask what's on."
        case .reminders:
            return "See your unfinished reminders."
        case .contacts:
            return "Look up a contact's phone and email as stored."
        case .photos:
            return "List recent photos (dates and sizes only) and read text in a photo."
        case .music:
            return "Search your music library by song, artist, or album."
        case .system:
            return "Basic facts: model, chip, memory, storage, battery, open apps."
        case .clipboard:
            return "Read what's on the clipboard, and copy text to it for you."
        }
    }

    /// Whether macOS gates this source behind a Privacy & Security
    /// permission the user grants (vs. no permission at all: Spotlight
    /// searches the user's own index, shared folders are granted by
    /// picking them, and system/clipboard access needs no grant).
    var needsSystemPermission: Bool {
        switch self {
        case .calendar, .reminders, .contacts, .photos, .music:
            return true
        case .spotlight, .files, .system, .clipboard:
            return false
        }
    }

    /// Where a denied permission gets fixed, named the way the macOS
    /// Settings sidebar names it.
    var privacyPaneName: String {
        switch self {
        case .calendar: return "Calendars"
        case .reminders: return "Reminders"
        case .contacts: return "Contacts"
        case .photos: return "Photos"
        case .music: return "Media & Apple Music"
        case .spotlight, .files, .system, .clipboard: return ""
        }
    }

    var symbolName: String {
        switch self {
        case .spotlight: return "magnifyingglass"
        case .files: return "folder"
        case .calendar: return "calendar"
        case .reminders: return "checklist"
        case .contacts: return "person.crop.circle"
        case .photos: return "photo.on.rectangle"
        case .music: return "music.note"
        case .system: return "desktopcomputer"
        case .clipboard: return "doc.on.clipboard"
        }
    }
}

// MARK: - Permission state

/// The one permission vocabulary every source maps into, so the
/// Settings panel and the tool layer speak the same words.
enum PermissionState: String, Sendable {
    case notDetermined
    case authorized
    case denied
    case restricted
    case unavailable

    var settingsLabel: String {
        switch self {
        case .notDetermined: return "Not asked yet"
        case .authorized: return "Allowed"
        case .denied: return "Not allowed"
        case .restricted: return "Restricted"
        case .unavailable: return "Unavailable"
        }
    }
}

/// Plain-English guidance for a source in a given permission state —
/// what the Settings panel shows and what a tool can quote back when
/// a lookup can't run.
enum PermissionGuidance {

    static func text(source: VisibilitySource, state: PermissionState) -> String? {
        switch state {
        case .authorized:
            return nil
        case .notDetermined:
            return source.needsSystemPermission
                ? "Turn this on and macOS will ask whether the app may look. Nothing is looked at before you allow it."
                : nil
        case .denied:
            return "macOS is currently set to not allow this. To change it: System Settings → Privacy & Security → \(source.privacyPaneName), then allow this app."
        case .restricted:
            return "This is restricted on this Mac (for example by a management profile), so the app can't look here."
        case .unavailable:
            return "This isn't available to the app as it's currently built. (Permission prompts use the packaged app's permission notes — see \u{201C}The double-clickable app\u{201D} in the README; when run from Xcode, macOS attributes access to Xcode.)"
        }
    }
}

// MARK: - Tool arguments

/// The argument fields a tool can take. Every backend path — the
/// framework's @Generable struct, the MLX JSON specs — fills the same
/// `ToolArguments` from these fields, so there is exactly one shape
/// for tool calls everywhere.
enum ToolArgumentField: String, CaseIterable, Sendable {
    case query
    case path
    case expression
    case text
    case days
    case limit
    case index
    // Phase 6: the file-action fields. Same deal as the rest — one
    // shared shape, the per-tool descriptions say which apply.
    case newName
    case destination
    case append
    case maxWidth
    case maxBytes
    // Phase 9: the power-tool fields — the shell command itself, and
    // the generic JSON carrier for MCP tools' own argument shapes.
    case command
    case argumentsJSON

    var jsonType: String {
        switch self {
        case .query, .path, .expression, .text, .newName, .destination,
             .command, .argumentsJSON:
            return "string"
        case .days, .limit, .index, .maxWidth, .maxBytes: return "integer"
        case .append: return "boolean"
        }
    }

    var fieldDescription: String {
        switch self {
        case .query: return "A search phrase or name, when the tool takes one."
        case .path: return "A full file or folder path, when the tool takes one."
        case .expression: return "A math expression, for the calculator tool."
        case .text: return "Text to write, for the clipboard tool."
        case .days: return "How many days ahead to look, when the tool takes one."
        case .limit: return "How many results to return at most, when the tool takes one."
        case .index: return "Which item, counting from the most recent (0 = most recent)."
        case .newName: return "The new name only (no folder, no slashes), for the rename tool."
        case .destination: return "The full destination path, for the move, copy, and photo-resize tools."
        case .append: return "True to add the text at the end of the file instead of replacing its contents, for the edit tool."
        case .maxWidth: return "The widest the resized photo may be, in pixels, for the photo-resize tool."
        case .maxBytes: return "The largest JPEG file size allowed, in bytes, for the photo-resize tool."
        case .command: return "The exact shell command to run, for the run_command tool."
        case .argumentsJSON: return "For an MCP server's tool: its arguments as one JSON object string, like {\"path\": \"/some/file\"} — {} when it takes none."
        }
    }
}

/// One argument value as it arrives from a backend's JSON-ish call.
enum ToolArgumentValue: Sendable, Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
}

/// A tool call's arguments, normalized. Numeric fields clamp to sane
/// ranges here, once, so no tool body re-checks them.
struct ToolArguments: Sendable, Equatable {
    var query: String?
    var path: String?
    var expression: String?
    var text: String?
    var days: Int?
    var limit: Int?
    var index: Int?
    // Phase 6: file-action fields.
    var newName: String?
    var destination: String?
    var append: Bool?
    var maxWidth: Int?
    var maxBytes: Int?
    // Phase 9: power-tool fields.
    var command: String?
    var argumentsJSON: String?

    init(query: String? = nil, path: String? = nil,
         expression: String? = nil, text: String? = nil,
         days: Int? = nil, limit: Int? = nil, index: Int? = nil,
         newName: String? = nil, destination: String? = nil,
         append: Bool? = nil, maxWidth: Int? = nil, maxBytes: Int? = nil,
         command: String? = nil, argumentsJSON: String? = nil) {
        self.query = query
        self.path = path
        self.expression = expression
        self.text = text
        self.days = days
        self.limit = limit
        self.index = index
        self.newName = newName
        self.destination = destination
        self.append = append
        self.maxWidth = maxWidth
        self.maxBytes = maxBytes
        self.command = command
        self.argumentsJSON = argumentsJSON
    }

    /// From backend values (the MLX dispatch path). Strings that look
    /// like integers are accepted for the numeric fields — small
    /// models are loose with JSON types.
    init(values: [String: ToolArgumentValue]) {
        func string(_ field: ToolArgumentField) -> String? {
            switch values[field.rawValue] {
            case .string(let value): return value
            case .int(let value): return String(value)
            case .double(let value): return String(value)
            case .bool(let value): return value ? "true" : "false"
            case nil: return nil
            }
        }
        func int(_ field: ToolArgumentField) -> Int? {
            switch values[field.rawValue] {
            case .int(let value): return value
            case .double(let value):
                // Audit B-02: `Int(Double)` traps on out-of-range,
                // NaN, and infinite values — all things a model can
                // emit ("limit": 1e30). Out-of-range means "no usable
                // value": nil, so the clamped accessors apply their
                // defaults instead of the app crashing.
                guard value.isFinite, abs(value) < 9.0e18 else { return nil }
                return Int(value)
            case .string(let value): return Int(value.trimmingCharacters(in: .whitespaces))
            case .bool, nil: return nil
            }
        }
        func bool(_ field: ToolArgumentField) -> Bool? {
            switch values[field.rawValue] {
            case .bool(let value): return value
            case .string(let value):
                switch value.trimmingCharacters(in: .whitespaces).lowercased() {
                case "true", "yes", "1": return true
                case "false", "no", "0": return false
                default: return nil
                }
            case .int(let value): return value != 0
            case .double, nil: return nil
            }
        }
        self.init(query: string(.query), path: string(.path),
                  expression: string(.expression), text: string(.text),
                  days: int(.days), limit: int(.limit), index: int(.index),
                  newName: string(.newName), destination: string(.destination),
                  append: bool(.append), maxWidth: int(.maxWidth),
                  maxBytes: int(.maxBytes),
                  command: string(.command),
                  argumentsJSON: string(.argumentsJSON))
    }

    /// Days ahead for calendar lookups: default a week, at most 60.
    var daysClamped: Int { min(max(days ?? 7, 1), 60) }
    /// Result counts: default 8, at most 25.
    var limitClamped: Int { min(max(limit ?? 8, 1), 25) }
    /// "Which recent item": default the most recent, never negative.
    var indexClamped: Int { min(max(index ?? 0, 0), 24) }
    /// Photo resize width cap: default 1200 px, sane bounds.
    var maxWidthClamped: Int { min(max(maxWidth ?? 1200, 16), 8192) }
    /// Photo resize JPEG ceiling: default ~500 KB, sane bounds.
    var maxBytesClamped: Int { min(max(maxBytes ?? 512_000, 10_000), 20_000_000) }
    /// Edit mode: replace unless the model asked to append.
    var appendFlag: Bool { append ?? false }

    /// The short human summary of what was asked, for the access log
    /// and the transcript card.
    func summary(for toolName: String) -> String {
        // Phase 9: MCP tool names are per-server, so they're matched
        // by prefix rather than by case.
        if toolName.hasPrefix(MCPToolNaming.prefix) {
            return String((argumentsJSON ?? "{}").prefix(60))
        }
        switch toolName {
        case "search_files", "search_contacts", "search_music":
            return query.map { "“\($0)”" } ?? "search"
        case "read_file", "list_folder":
            return path ?? "a path"
        case "calendar_events":
            return "next \(daysClamped) days"
        case "list_reminders":
            return "unfinished reminders"
        case "recent_photos":
            return query.map { "album “\($0)”" } ?? "most recent"
        case "photo_text":
            return "photo #\(indexClamped + 1) from most recent"
        case "calculate":
            return expression ?? "an expression"
        case "write_clipboard":
            // Audit S-11: the log stores a type-and-size summary,
            // never the clipboard text itself — copying a password
            // and asking about it must not persist the password.
            return "Clipboard text (\((text ?? "").count) characters)"
        case "rename_file":
            return "\(path ?? "a file") → \(newName ?? "a new name")"
        case "move_file", "copy_file":
            return "\(path ?? "a file") → \(destination ?? "elsewhere")"
        case "create_folder", "edit_text_file", "trash_file":
            return path ?? "a path"
        case "resize_photo":
            return path ?? "photo #\(indexClamped + 1) from most recent"
        case "run_command":
            return command ?? "a command"
        default:
            return ""
        }
    }
}

// MARK: - Tool catalog

/// One tool's static definition: everything the backends need to
/// offer it to a model and everything the UI needs to show it.
struct ToolDescriptor: Sendable, Equatable, Identifiable {
    let name: String
    /// Label for cards and the log ("File search").
    let displayName: String
    /// The model-facing description — what it does and how to call it.
    let modelDescription: String
    /// The source that must be enabled for this tool to exist, or nil
    /// for utilities (calculator, clock) that read nothing personal
    /// and ride along with the tool set.
    let source: VisibilitySource?
    let argumentFields: [ToolArgumentField]
    let symbolName: String
    /// Phase 6: a file-action tool. These NEVER touch the disk when
    /// called — they propose an item onto the conversation's approval
    /// list (see `FileActions.swift`) — and they exist only while the
    /// separate file-writing Settings toggle is on. Declared last with
    /// a default so every read-tool literal above stays unchanged.
    let isWriteAction: Bool = false
    /// Phase 9: a power tool — the shell command, and every MCP
    /// server tool. Same propose-only contract as the file actions
    /// (a call proposes; nothing runs before the user's Approve),
    /// behind the master Power tools switch instead of the writing
    /// one. MCP descriptors are built per server in `PowerTools.swift`,
    /// not in the static catalog below; only `run_command` is static.
    let isPowerAction: Bool = false

    var id: String { name }
}

enum ToolCatalog {

    static let all: [ToolDescriptor] = [
        ToolDescriptor(
            name: "search_files",
            displayName: "File search",
            modelDescription: "Search the user's files by name or by words inside them (Spotlight). Set query to the keywords, and optionally limit for how many results (default 8).",
            source: .spotlight,
            argumentFields: [.query, .limit],
            symbolName: "magnifyingglass"),
        ToolDescriptor(
            name: "list_folder",
            displayName: "List folder",
            modelDescription: "List what's inside a folder. Only works inside folders the user has shared with the app (Settings → What this app can see). Set path to the folder's full path.",
            source: .files,
            argumentFields: [.path],
            symbolName: "folder"),
        ToolDescriptor(
            name: "read_file",
            displayName: "Read file",
            modelDescription: "Read the text of a file. Only works inside folders the user has shared with the app (Settings → What this app can see). Set path to the file's full path.",
            source: .files,
            argumentFields: [.path],
            symbolName: "doc.text"),
        ToolDescriptor(
            name: "calendar_events",
            displayName: "Calendar",
            modelDescription: "List the user's calendar events coming up. Set days to how many days ahead to look (default 7).",
            source: .calendar,
            argumentFields: [.days],
            symbolName: "calendar"),
        ToolDescriptor(
            name: "list_reminders",
            displayName: "Reminders",
            modelDescription: "List the user's unfinished reminders.",
            source: .reminders,
            argumentFields: [.limit],
            symbolName: "checklist"),
        ToolDescriptor(
            name: "search_contacts",
            displayName: "Contact search",
            modelDescription: "Find a contact by name and return the phone number and email exactly as stored. Set query to the name.",
            source: .contacts,
            argumentFields: [.query],
            symbolName: "person.crop.circle"),
        ToolDescriptor(
            name: "recent_photos",
            displayName: "Recent photos",
            modelDescription: "List the user's most recent photos — dates and sizes only, never the images themselves. Optionally set query to an album name to look in one album, and limit for how many (default 8).",
            source: .photos,
            argumentFields: [.query, .limit],
            symbolName: "photo.on.rectangle"),
        ToolDescriptor(
            name: "photo_text",
            displayName: "Text in a photo",
            modelDescription: "Read the text visible in one of the user's recent photos. Set index to which photo, counting from the most recent (0 = most recent, default 0).",
            source: .photos,
            argumentFields: [.index],
            symbolName: "text.viewfinder"),
        ToolDescriptor(
            name: "search_music",
            displayName: "Music search",
            modelDescription: "Search the user's music library by song, artist, or album. Set query to the search phrase, and optionally limit (default 8).",
            source: .music,
            argumentFields: [.query, .limit],
            symbolName: "music.note"),
        ToolDescriptor(
            name: "now_playing",
            displayName: "Now playing",
            modelDescription: "Say what music is playing right now on this Mac.",
            source: .music,
            argumentFields: [],
            symbolName: "play.circle"),
        ToolDescriptor(
            name: "system_info",
            displayName: "About this Mac",
            modelDescription: "Get facts about this Mac: model, chip, memory, free storage, battery, macOS version, how long it's been on, and which apps are open.",
            source: .system,
            argumentFields: [],
            symbolName: "desktopcomputer"),
        ToolDescriptor(
            name: "read_clipboard",
            displayName: "Read clipboard",
            modelDescription: "Read the text currently on the clipboard — whatever was copied most recently.",
            source: .clipboard,
            argumentFields: [],
            symbolName: "doc.on.clipboard"),
        ToolDescriptor(
            name: "write_clipboard",
            displayName: "Copy to clipboard",
            modelDescription: "Copy text to the clipboard so the user can paste it somewhere else. Set text to what should be copied.",
            source: .clipboard,
            argumentFields: [.text],
            symbolName: "doc.on.doc"),
        ToolDescriptor(
            name: "calculate",
            displayName: "Calculator",
            modelDescription: "Do arithmetic exactly. Set expression to a plain expression like 23.5 * 4 + sqrt(9). Supports + - * / % ^, parentheses, sqrt and abs.",
            source: nil,
            argumentFields: [.expression],
            symbolName: "calculator"),
        ToolDescriptor(
            name: "current_time",
            displayName: "Date & time",
            modelDescription: "Get the current date, time, and time zone on this Mac.",
            source: nil,
            argumentFields: [],
            symbolName: "clock"),

        // MARK: Phase 6 — file actions (propose-only)
        //
        // Every description below carries the same deal, stated to the
        // model in so many words: calling the tool changes NOTHING.
        // It adds one item to a list the user reviews (each item can
        // be removed) and approves or discards as a whole. The model
        // must never report an action as done before the user approves
        // — the outcome arrives as a note in a later message.

        ToolDescriptor(
            name: "rename_file",
            displayName: "Rename file",
            modelDescription: "Propose renaming a file or folder inside a shared folder. Set path to the item's full path and newName to the new name only (no folder, no slashes). This changes NOTHING yet: it adds the rename to a list the user must approve before anything happens. Never say a rename is done until the user has approved it.",
            source: .files,
            argumentFields: [.path, .newName],
            symbolName: "pencil",
            isWriteAction: true),
        ToolDescriptor(
            name: "move_file",
            displayName: "Move file",
            modelDescription: "Propose moving a file or folder to a new path inside the shared folders. Set path to where it is now and destination to the full new path (folder + name). This changes NOTHING yet: it adds the move to a list the user must approve before anything happens. A move never overwrites — if something already sits at the destination, pick a different name.",
            source: .files,
            argumentFields: [.path, .destination],
            symbolName: "arrow.right.square",
            isWriteAction: true),
        ToolDescriptor(
            name: "copy_file",
            displayName: "Copy file",
            modelDescription: "Propose copying a file to a new path inside the shared folders (the original stays where it is). Set path to the file and destination to the full path of the copy. This changes NOTHING yet: it adds the copy to a list the user must approve before anything happens. A copy never overwrites an existing file.",
            source: .files,
            argumentFields: [.path, .destination],
            symbolName: "doc.on.doc",
            isWriteAction: true),
        ToolDescriptor(
            name: "create_folder",
            displayName: "Create folder",
            modelDescription: "Propose creating a new folder inside a shared folder. Set path to the new folder's full path. This changes NOTHING yet: it adds the new folder to a list the user must approve before anything happens.",
            source: .files,
            argumentFields: [.path],
            symbolName: "folder.badge.plus",
            isWriteAction: true),
        ToolDescriptor(
            name: "edit_text_file",
            displayName: "Edit text file",
            modelDescription: "Propose writing text into a file inside a shared folder: the file's contents are replaced with text, or added at the end when append is true. If the file doesn't exist yet, this proposes creating it with that text. Set path and text. This changes NOTHING yet: it adds the edit to a list the user must approve before anything happens. Before an existing file is replaced, the app keeps a backup so the change can be undone.",
            source: .files,
            argumentFields: [.path, .text, .append],
            symbolName: "square.and.pencil",
            isWriteAction: true),
        ToolDescriptor(
            name: "trash_file",
            displayName: "Move to Trash",
            modelDescription: "Propose moving a file or folder inside a shared folder to the Trash. Set path to the item. This changes NOTHING yet: it adds the move to a list the user must approve before anything happens. Items go to the Trash — they are never permanently deleted — and the change can be undone.",
            source: .files,
            argumentFields: [.path],
            symbolName: "trash",
            isWriteAction: true),
        ToolDescriptor(
            name: "resize_photo",
            displayName: "Resize photo",
            modelDescription: "Propose making a smaller JPEG copy of a photo, sized for uploading or sharing: it is shrunk to at most maxWidth pixels wide (default 1200) and re-saved under a byte ceiling (maxBytes, default about 500 KB), lowering quality — and, if needed, size — until it fits. The original is never touched. Set index to pick one of the most recent library photos (0 = most recent), or path to an image file inside a shared folder; optionally set destination for the new file's full path (otherwise a name is derived next to the original, or in the first shared folder for library photos). This changes NOTHING yet: it adds the resize to a list the user must approve; when approved, the new file is also copied to the clipboard.",
            source: .photos,
            argumentFields: [.path, .index, .destination, .maxWidth, .maxBytes],
            symbolName: "arrow.down.right.and.arrow.up.left",
            isWriteAction: true),

        // MARK: Phase 9 — power tools (propose-only)
        //
        // The shell half of the power tools (the MCP half is
        // per-server and joins at runtime). Same propose-only deal,
        // stated to the model in so many words, under the Power
        // tools master switch. A command is never undoable, and the
        // description says that too.

        ToolDescriptor(
            name: "run_command",
            displayName: "Run command",
            modelDescription: "Propose running a shell command (zsh) on the user's Mac. Set command to the EXACT command text, and optionally path to the folder it should run in — the folder must be one of the user's shared folders (Settings → What this app can see → Shared folders); omit path to run in the first shared folder. This runs NOTHING yet: it adds the command to a list the user must approve before anything happens, and they see the exact text. Commands cannot be undone. The command gets at most 30 seconds, runs with a plain environment (no shell profile), and you will be told its exit code and what it printed. Never say a command has run until the user has approved it.",
            source: nil,
            argumentFields: [.command, .path],
            symbolName: "terminal",
            isPowerAction: true),
    ]

    static func descriptor(named name: String) -> ToolDescriptor? {
        all.first { $0.name == name }
    }

    /// The tool set for a session: the utilities plus every tool whose
    /// source the user has enabled. Nothing enabled = no tools at all,
    /// so a Phase 5 install with every toggle off behaves exactly
    /// like Phase 4.
    ///
    /// Phase 6: file-action tools carry a second gate — they are in
    /// the set only while the file-writing toggle is also on. The
    /// default (toggle off) keeps every Phase 5 call site behaving
    /// exactly as before.
    ///
    /// Phase 9: power tools carry their own master gate
    /// (`powerToolsEnabled`). The static catalog holds only
    /// `run_command`; the MCP servers' tools are dynamic and are
    /// merged in by the runtime, not here. The early return widens
    /// by exactly one case: power tools on is enough for a tool set
    /// to exist even with every visibility source off (the source-
    /// less utilities ride along, as they do with any source).
    static func descriptors(enabledSources: Set<VisibilitySource>,
                            fileWritingEnabled: Bool = false,
                            powerToolsEnabled: Bool = false,
                            localOnly: Bool = false) -> [ToolDescriptor] {
        // Audit S-06: under the Local Only lock the power tools
        // don't exist at all — an approved command or server call
        // can itself reach the network, so "nothing leaves this
        // Mac" must cover them too.
        let effectivePowerToolsEnabled = powerToolsEnabled && !localOnly
        guard !enabledSources.isEmpty || effectivePowerToolsEnabled else { return [] }
        return all.filter { descriptor in
            if descriptor.isWriteAction, !fileWritingEnabled { return false }
            if descriptor.isPowerAction, !effectivePowerToolsEnabled { return false }
            guard let source = descriptor.source else { return true }
            return enabledSources.contains(source)
        }
    }

}

// MARK: - Result sizing

/// Tool results go straight into a model's context, and the on-device
/// window is 4K tokens — a careless result (a search with 200 hits)
/// would crowd out the conversation. Every result is clamped here,
/// with an honest note when something was trimmed.
enum ToolResultText {

    static let maxCharacters = 1200

    static func clamp(_ text: String, maxCharacters: Int = maxCharacters) -> String {
        guard text.count > maxCharacters else { return text }
        let kept = String(text.prefix(maxCharacters))
        return kept + "\n… (trimmed — the full result was longer; ask for something narrower)"
    }

    /// One short line summarizing a result for the access log and the
    /// transcript card: the first line, itself capped.
    static func summary(of result: String) -> String {
        let firstLine = result.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? result
        let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
        guard trimmed.count > 100 else { return trimmed }
        return String(trimmed.prefix(100)) + "…"
    }

    /// The access-log summary for one tool's result (audit S-11).
    ///
    /// Most tools keep the first-line summary above — their results
    /// lead with a header or a count, not raw user content. The
    /// exceptions are the tools whose result IS raw user content:
    /// the clipboard's current text and a file's contents. Persisting
    /// even a first line of those writes the content itself into the
    /// log (a copied password, a private file's opening line), so
    /// these store a type-and-size summary instead — mirroring how
    /// `write_clipboard`'s own result already reports only a count.
    static func summary(of result: String, toolName: String) -> String {
        switch toolName {
        case "read_clipboard":
            return "Clipboard text (\(result.count) characters)"
        case "write_clipboard":
            return "Text copied to the clipboard"
        case "read_file":
            return "File text (\(result.count) characters)"
        default:
            return summary(of: result)
        }
    }
}

// MARK: - Access log

/// One tool execution, as the runtime reports it. The engine turns
/// these into persisted `ToolActivityRecord`s (the access log) and
/// ChatView renders them as transcript cards — same event, two views,
/// so nothing the model looks at is invisible to the user.
struct ToolEvent: Sendable, Equatable {
    let conversationID: UUID
    let toolName: String
    let source: VisibilitySource?
    let querySummary: String
    let resultSummary: String
    let date: Date
}

/// How much log the app keeps: the newest few hundred lookups. Older
/// entries fall off — the log is for "what did it just look at", not
/// an archive.
enum AccessLogPolicy {
    static let maxRecords = 300

    /// How many oldest records to delete when the total reaches this.
    static func excessCount(totalRecords: Int) -> Int {
        max(0, totalRecords - maxRecords)
    }
}

/// How many decided plan records the app keeps (audit S-04): the
/// same discipline as the access log, for the same reason. A plan
/// record stores full payloads — a file's replacement text, an exact
/// command, a server's whole answer — so it must not accumulate
/// forever either. The engine rotates to this cap on every insert;
/// the newest `maxRecords` decided plans are kept.
enum ActionPlanLogPolicy {
    static let maxRecords = 300

    /// How many oldest records to delete when the total reaches this.
    static func excessCount(totalRecords: Int) -> Int {
        max(0, totalRecords - maxRecords)
    }
}

// MARK: - Tool availability snapshot

/// What the UI shell hands the engine per conversation: which sources
/// are on and which folders are shared. Equatable so the engine can
/// fold it into its live-session signature — changing a toggle or a
/// folder retires live sessions and the next send rebuilds them with
/// the new tool set.
/// A deterministic hash of the user's custom redaction terms, for
/// the tool-availability signature (audit S-13). FNV-1a over the
/// normalized (trimmed, order-insensitive) term list — deliberately
/// NOT Swift's `Hasher`, which is seeded per process: a signature
/// only ever needs to be compared within one run, but a stable
/// value keeps the tests able to pin exact outputs.
enum RedactionTermsHash {

    static func value(for terms: [String]) -> String {
        let normalized = terms
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .sorted()
        let joined = normalized.joined(separator: "\u{1F}")
        // FNV-1a, 64-bit.
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in joined.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return String(hash, radix: 16)
    }
}

struct ToolAvailability: Equatable, Sendable {
    var enabledSources: Set<VisibilitySource>
    var folderRootPaths: [String]
    /// Phase 6: the file-writing toggle. Part of the signature, so
    /// flipping it retires live sessions and the next send rebuilds
    /// them with (or without) the file-action tools — the same deal
    /// as toggling a source.
    var fileWritingEnabled: Bool = false
    /// Phase 9: the power-tools master switch, same deal. The MCP
    /// half also carries a signature of the tool set the manager
    /// last discovered ("serverSlug:tool,tool;…") — when a server's
    /// tools change (first launch, a restart, an edit), sessions
    /// retire and rebuild with the fresh list, exactly as when any
    /// other part of the tool set changes.
    var powerToolsEnabled: Bool = false
    var mcpToolsSignature: String = ""
    /// Audit S-06: the Local Only lock. While it's on, the power
    /// tools (shell + MCP) are unavailable — they can reach the
    /// network themselves, so the lock pauses them — and plan
    /// execution refuses power items outright. Part of the
    /// signature, so flipping the lock retires live sessions.
    var localOnly: Bool = false
    /// Audit S-13: the user's custom redaction terms. Only their
    /// HASH joins the signature (the terms themselves travel in
    /// `RoutingInputs`), so adding a term mid-conversation retires
    /// a live session and its tool runtime is rebuilt with the new
    /// list — tool results get the same fresh terms prompts get.
    var customRedactionTerms: [String] = []

    static let none = ToolAvailability(enabledSources: [], folderRootPaths: [])

    /// Whether the power tools may exist under the current
    /// settings: the master switch on AND the lock off.
    var effectivePowerToolsEnabled: Bool {
        powerToolsEnabled && !localOnly
    }

    var hasTools: Bool { !enabledSources.isEmpty || effectivePowerToolsEnabled }

    var signature: String {
        let sources = enabledSources.map(\.rawValue).sorted().joined(separator: ",")
        return sources + "|" + folderRootPaths.sorted().joined(separator: ",")
            + "|" + (fileWritingEnabled ? "write" : "read")
            + "|" + (effectivePowerToolsEnabled ? "power" : "nopower")
            + "|" + (localOnly ? "localonly" : "nolock")
            + "|terms:" + RedactionTermsHash.value(for: customRedactionTerms)
            + "|" + mcpToolsSignature
    }
}
