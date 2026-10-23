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
            return "This isn't available to the app as it's currently built. (Permission prompts arrive with the packaged app in Phase 10; when run from Xcode, macOS attributes access to Xcode.)"
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

    var jsonType: String {
        switch self {
        case .query, .path, .expression, .text: return "string"
        case .days, .limit, .index: return "integer"
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

    init(query: String? = nil, path: String? = nil,
         expression: String? = nil, text: String? = nil,
         days: Int? = nil, limit: Int? = nil, index: Int? = nil) {
        self.query = query
        self.path = path
        self.expression = expression
        self.text = text
        self.days = days
        self.limit = limit
        self.index = index
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
            case .double(let value): return Int(value)
            case .string(let value): return Int(value.trimmingCharacters(in: .whitespaces))
            case .bool, nil: return nil
            }
        }
        self.init(query: string(.query), path: string(.path),
                  expression: string(.expression), text: string(.text),
                  days: int(.days), limit: int(.limit), index: int(.index))
    }

    /// Days ahead for calendar lookups: default a week, at most 60.
    var daysClamped: Int { min(max(days ?? 7, 1), 60) }
    /// Result counts: default 8, at most 25.
    var limitClamped: Int { min(max(limit ?? 8, 1), 25) }
    /// "Which recent item": default the most recent, never negative.
    var indexClamped: Int { min(max(index ?? 0, 0), 24) }

    /// The short human summary of what was asked, for the access log
    /// and the transcript card.
    func summary(for toolName: String) -> String {
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
            return String((text ?? "").prefix(40))
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
    ]

    static func descriptor(named name: String) -> ToolDescriptor? {
        all.first { $0.name == name }
    }

    /// The tool set for a session: the utilities plus every tool whose
    /// source the user has enabled. Nothing enabled = no tools at all,
    /// so a Phase 5 install with every toggle off behaves exactly
    /// like Phase 4.
    static func descriptors(enabledSources: Set<VisibilitySource>) -> [ToolDescriptor] {
        guard !enabledSources.isEmpty else { return [] }
        return all.filter { descriptor in
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

// MARK: - Tool availability snapshot

/// What the UI shell hands the engine per conversation: which sources
/// are on and which folders are shared. Equatable so the engine can
/// fold it into its live-session signature — changing a toggle or a
/// folder retires live sessions and the next send rebuilds them with
/// the new tool set.
struct ToolAvailability: Equatable, Sendable {
    var enabledSources: Set<VisibilitySource>
    var folderRootPaths: [String]

    static let none = ToolAvailability(enabledSources: [], folderRootPaths: [])

    var hasTools: Bool { !enabledSources.isEmpty }

    var signature: String {
        let sources = enabledSources.map(\.rawValue).sorted().joined(separator: ",")
        return sources + "|" + folderRootPaths.sorted().joined(separator: ",")
    }
}
