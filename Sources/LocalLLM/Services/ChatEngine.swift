import Foundation
import FoundationModels
import Observation
import SwiftData

/// Review finding 7: the execution-time grant gate for an approved
/// plan item, pure so it is unit-testable. The engine re-reads the
/// CURRENT tool availability before EVERY item (not once per
/// approval — a settings change mid-approval must not bless the
/// remaining items), and this gate turns that snapshot into a
/// refusal before anything runs: power items under the Local Only
/// lock or with the master switch off, and file-change items with
/// file writing off. Nil means the item may proceed to the usual
/// pre-check and executor. (Model tool calls revalidate the same
/// way inside `ToolRuntime.execute`, against the runtime's — now
/// post-discovery — snapshot; a later settings change retires the
/// session through its signature.)
enum PlanExecutionGate {
    static func refusal(for action: PlannedAction,
                        localOnly: Bool,
                        powerToolsEnabled: Bool,
                        fileWritingEnabled: Bool) -> String? {
        switch action.kind {
        case .runCommand, .mcpCall:
            if localOnly {
                return "Not run — Local Only is on, so commands "
                    + "and server calls are paused while the lock is on."
            }
            if !powerToolsEnabled {
                return "Not run — power tools are turned off, so "
                    + "commands and server calls are paused."
            }
            return nil
        default:
            if !fileWritingEnabled {
                return "Not run — file changes are turned off, so "
                    + "this change is paused."
            }
            return nil
        }
    }
}

/// Runs conversations against the model backend each chat has picked.
///
/// Phase 3 shape: the engine no longer talks to the on-device model
/// directly. Every chat has a `ModelSelection` (built-in model, a
/// downloaded MLX model, or a local server); a provider closure —
/// configured by the app from the live model/server stores — resolves
/// it to a `ModelBackend`, and the backend makes the live session. The
/// Phase 2 machinery is unchanged in spirit and mostly in code:
///
/// - One live session per conversation, kept while the app runs.
/// - Before each send, the conversation is planned against the
///   *selected backend's* context budget; if it no longer fits, the
///   oldest turns are folded into a running summary and the session is
///   rebuilt, seeded with [summary + recent turns verbatim].
/// - Switching the picker mid-conversation retires the session; the
///   next send rebuilds it against the new backend and re-seeds it the
///   same way, so the thread carries over and the new budget applies.
///   (Framework backends could swap via Dynamic Profiles, but local
///   servers aren't framework sessions — one rebuild path for every
///   backend keeps switching behavior identical. See the README.)
/// - Summaries are always written by the built-in on-device model,
///   whatever backend the chat uses: it's a background chore the small
///   model is good at, and it keeps compaction working even for a chat
///   pointed at a server that's down. A mechanical fallback covers the
///   on-device model being unavailable.
/// - Stored messages are never deleted. The summary lives on the
///   `Conversation` record; the transcript the user sees is whole.
///
/// Phase 4 adds the routing layer on top of that shape:
///
/// - A chat set to Auto has its outgoing prompt classified by a
///   throwaway on-device session (`IntentClassifier`) and routed by
///   the pure `RoutingPolicy` to a concrete backend before any of the
///   machinery above runs — from there on, an Auto send is an ordinary
///   send against the routed backend, telemetry included. A manual
///   picker choice remains a complete override: no classification.
/// - The privacy firewall: a chat pointed at a server that isn't on
///   this Mac is the one place a prompt can leave the machine, so the
///   outgoing text (instructions + prompt, history included) is
///   scrubbed by `Redactor` first, and the user is told it happened.
///   Stored messages are never touched — only the sent copy. The
///   brief's history-compression half of the firewall needs no new
///   machinery: a session is seeded with [running summary + recent
///   turns] (Phase 2), never the raw stored history, and an endpoint
///   session's memory is exactly the seeded prompt chain it was fed —
///   so a compacted chat's older turns reach a remote destination
///   only as their summary. Phase 8's cloud backends consume this
///   same hook: they are `ModelBackend`s like any other, seeded
///   the same way, with `Redactor` applied on the same
///   remote-destination check.
/// - The Local Only lock is enforced in `BackendFactory`: a server
///   selection resolves to the built-in model while it's on, and the
///   engine explains the switch.
/// - Every finished reply records telemetry (backend, seconds,
///   estimated tokens) on its `Message` for the pill in the
///   transcript.
///
/// Phase 5 adds the local visibility layer on that shape:
///
/// - When the user has enabled any visibility source ("What this app
///   can see" in Settings), sessions on tool-capable backends
///   (on-device, MLX) are created with a `ToolRuntime` tool set; the
///   tool set is part of the live-session signature, so toggling a
///   source or a shared folder retires sessions and the next send
///   rebuilds them, re-seeded as always. Endpoint chats get no tools
///   this phase, and Local Only changes nothing for them — they never
///   had any.
/// - Tool results never pass through this engine: the backends invoke
///   the runtime inside their own sessions. What the engine owns is
///   the *record*: runtime events arrive on a per-send sink (audit
///   B-43: it carries that send's own context) and are
///   persisted here as `ToolActivityRecord`s (the access log),
///   rotated to `AccessLogPolicy`'s cap.
/// - Tool results and the privacy firewall: every tool-capable
///   backend in this phase runs on this Mac, so results stay local
///   and no redaction applies. The runtime carries the redaction
///   flag Phase 8's cloud tier sets for its one remote tool host
///   (Private Cloud Compute); see the Phase 8 notes below.
///
/// Phase 8 adds the cloud tier on that shape:
///
/// - Two cloud backends join the factory: Private Cloud Compute (a
///   framework backend — tools and all) and OpenRouter (an HTTP
///   backend like Phase 3's servers, plus the user's Keychain key
///   and real per-reply costs). Auto's `frontier_cloud` route is
///   live: OpenRouter's best curated model when a key exists, else
///   PCC, else the local stand-in with an honest note.
/// - Both clouds count as REMOTE destinations here: the privacy
///   firewall scrubs instructions + prompt (seeded history, Phase 6
///   outcome notes, and Phase 7 prompt prefixes included) before
///   anything is sent, and the user is told when it hid something.
/// - Tool results follow the same rule through the runtime's one
///   choke point: a PCC session's tool set is built with
///   `redactResults` on and the user's custom terms attached, so a
///   lookup's findings are scrubbed before they can enter a cloud
///   prompt. Local tool hosts (on-device, MLX) keep raw results —
///   nothing leaves the Mac there. OpenRouter sessions, like server
///   sessions, get no tools at all this phase.
/// - Telemetry grows up: an OpenRouter reply's pill shows the real
///   cost from its usage report, or "cost unknown" when the service
///   sent none — never a fake $0.00 on a paid route. PCC reports
///   $0.00, labeled as Apple's cloud; Apple includes it.
///
/// Phase 9 adds the power tools on that shape:
///
/// - Behind the master Power tools switch, sessions gain the shell
///   tool and any MCP server tools (the manager's servers launch
///   lazily at session build — the only moment a process starts).
///   Both kinds are propose-only through the very same pending plan
///   as file changes: `executePlanItem` dispatches an approved item
///   to its executor, the audit log records proposals and results,
///   and the outcome note quotes a command's output or a server's
///   answer via the item's `modelDetail`.
/// - Flagged dangerous commands start UNCHECKED on the list
///   (`excludedPlanItems`): approving runs the checked remainder
///   and records the rest as declined. Commands and MCP calls are
///   never undoable, and their undo steps say so.
///
/// All state here is main-actor: the UI reads `streamingText`,
/// `respondingIDs`, and `errorMessages` directly.
@MainActor
@Observable
final class ChatEngine {

    init() {
        // Review finding 16: nothing static is bound here. Each
        // window owns its own engine (see LocalLLMApp), and each
        // engine hands its tool runtimes a sink bound to ITSELF
        // (`proposalSink()` below) — never a process-global
        // destination another window's init could overwrite.
    }

    // MARK: - Observable state for the UI

    /// Partial reply text, per conversation, while a reply is streaming.
    private(set) var streamingText: [UUID: String] = [:]
    /// Conversations with a reply currently in flight (including the
    /// brief compaction step that can precede one).
    private(set) var respondingIDs: Set<UUID> = []
    /// Last error per conversation, in plain English, shown as a banner.
    var errorMessages: [UUID: String] = [:]
    /// Phase 4: the latest Auto routing explanation per conversation
    /// ("Auto: a quick edit or question — Apple On-Device has it."),
    /// shown as a small caption while the chat is on Auto.
    private(set) var routingNotes: [UUID: String] = [:]
    /// UAT-06: the selection that actually answered the most recent
    /// send in each conversation — after Auto routing AND the
    /// factory's fallbacks. The chat's "lookups are off" note keys
    /// off this for Auto chats: an Auto Mac-action prompt stood in
    /// by a server has no tools even though the picker says Auto,
    /// and keying the note off the picker hid exactly that case.
    private(set) var lastEffectiveSelections: [UUID: ModelSelection] = [:]
    /// Phase 4: informational banners that aren't errors — currently
    /// the privacy-check notice when a prompt was scrubbed before
    /// being sent to a server that isn't on this Mac.
    var infoMessages: [UUID: String] = [:]
    /// Phase 6: pending approval lists, per conversation — file
    /// changes the model has proposed and the user hasn't decided
    /// yet. Memory only, on purpose: a relaunch starts empty.
    /// Proposals are cheap for the model to make again; silently
    /// keeping half-approved file changes around is not.
    private(set) var pendingPlans: [UUID: [PlannedAction]] = [:]
    /// Phase 9: pending items the user has NOT (yet) agreed to run —
    /// the approval list's unchecked set. A flagged dangerous
    /// command lands here the moment it's proposed (opt-in-only);
    /// the user can uncheck/re-check any item. Approve runs only
    /// the checked remainder; unchecked items are recorded as
    /// declined, like a discard, item by item.
    private(set) var excludedPlanItems: [UUID: Set<UUID>] = [:]
    /// Phase 6: conversations whose plan is being executed or undone
    /// right now (the card shows a spinner state and locks its
    /// buttons).
    private(set) var planBusyIDs: Set<UUID> = []
    /// Phase 6: outcome notes waiting to ride at the head of the next
    /// prompt in a conversation, so the model learns what the user
    /// decided (approved / discarded / undone, and per-item results)
    /// without a fake user message entering the transcript.
    private var pendingOutcomeNotes: [UUID: String] = [:]
    /// Phase 7: caller-supplied prompt prefixes waiting for the next
    /// send in a conversation — currently the quick panel's captured
    /// context ("you're in Safari; Finder has X selected"). Same
    /// deal as outcome notes: part of the sent copy only, never a
    /// stored message.
    private var pendingPromptPrefixes: [UUID: String] = [:]

    // MARK: - Backends

    /// Resolves a chat's stored selection to a live backend. Configured
    /// by the app shell from the MLX store and the server store; until
    /// then (and for anything unknown) everything resolves to the
    /// built-in model, which is exactly Phase 1–2 behavior.
    private var backendProvider: (ModelSelection) -> ResolvedBackend = { _ in
        ResolvedBackend(backend: OnDeviceBackend(),
                        effectiveSelection: .onDevice)
    }

    func configureBackendProvider(
        _ provider: @escaping (ModelSelection) -> ResolvedBackend
    ) {
        backendProvider = provider
    }

    /// Phase 4: everything routing and the privacy firewall need to
    /// know about the world — what's downloaded, what's configured,
    /// whether Local Only is on, what must never leave unhidden.
    /// Configured by the app shell alongside the backend provider;
    /// until then, empty inputs (Auto routes to the built-in model,
    /// nothing counts as remote).
    private var routingContextProvider: () -> RoutingInputs = {
        RoutingInputs()
    }

    func configureRoutingContextProvider(
        _ provider: @escaping () -> RoutingInputs
    ) {
        routingContextProvider = provider
    }

    /// Phase 5: what the tool layer may look at right now — enabled
    /// sources and shared-folder roots, snapshotted from Settings and
    /// the folder store by the app shell. Until configured, nothing
    /// (every toggle off, Phase 4 behavior).
    private var toolAvailabilityProvider: () -> ToolAvailability = {
        ToolAvailability.none
    }

    func configureToolAvailabilityProvider(
        _ provider: @escaping () -> ToolAvailability
    ) {
        toolAvailabilityProvider = provider
    }

    // MARK: - MCP providers (Phase 9)

    /// The MCP servers' currently offered tools, fetched when a
    /// tool-capable session is built with power tools on — the one
    /// moment server processes are launched. Configured by the app
    /// shell from the MCP manager; until then, no MCP tools.
    private var mcpToolsProvider: () async -> [MCPToolInfo] = { [] }

    func configureMCPToolsProvider(
        _ provider: @escaping () async -> [MCPToolInfo]
    ) {
        mcpToolsProvider = provider
    }

    /// Executes ONE approved MCP call. The shell hands the manager
    /// in through here, so plan approval can reach it without the
    /// engine knowing what an MCP server is. A nil return (no
    /// provider configured) becomes a plain failure item.
    private var mcpExecutorProvider: @MainActor (PlannedAction) async -> ExecutedActionItem? = { _ in nil }

    func configureMCPExecutorProvider(
        _ provider: @escaping @MainActor (PlannedAction) async -> ExecutedActionItem?
    ) {
        mcpExecutorProvider = provider
    }

    // MARK: - Tool activity log (Phase 5)

    /// Builds the runtime event sink for ONE operation (a send, in
    /// practice): the sink carries that operation's own container,
    /// and events are written through its main context — the same
    /// context the operation itself was handed.
    ///
    /// Audit B-43: this replaces a single static `activityLogContext`
    /// that every concurrent send/approve/discard/undo overwrote —
    /// last writer won, so an event from send A could be inserted
    /// through send B's context whenever their suspensions
    /// interleaved. The context now travels WITH the sink (and, for
    /// plan bookkeeping, as an explicit argument to
    /// `recordToolEvent`), never through shared mutable state.
    /// `ModelContainer` is the Sendable handle; its `mainContext`
    /// is the very context object the views pass to the engine.
    private static func toolEventSink(
        container: ModelContainer
    ) -> @Sendable (ToolEvent) async -> Void {
        { event in
            await MainActor.run {
                ChatEngine.recordToolEvent(event,
                                           context: container.mainContext)
            }
        }
    }

    /// Audit E-10: the access log's in-memory record count, per
    /// container — seeded lazily by ONE `fetchCount`, then kept by
    /// counting inserts, so rotation no longer pays a full-table
    /// count for every single tool event (a tool-heavy reply — or
    /// approving a 20-item plan, which loops this function per
    /// item — used to pay 20 counts + 20 saves back-to-back).
    /// Rotation semantics are unchanged: same `AccessLogPolicy`
    /// cap, oldest first, and still one `save()` per call, so a
    /// crash mid-reply loses no more than it did before.
    private static var activityCounts: [ObjectIdentifier: Int] = [:]

    /// Persists one tool event as an access-log record, rotating the
    /// oldest entries away past the policy cap.
    private static func recordToolEvent(_ event: ToolEvent,
                                        context: ModelContext) {
        context.insert(ToolActivityRecord(event: event))
        let key = ObjectIdentifier(context.container)
        let total: Int
        if let known = activityCounts[key] {
            total = known + 1
        } else {
            total = (try? context.fetchCount(
                FetchDescriptor<ToolActivityRecord>())) ?? 1
        }
        activityCounts[key] = total
        let excess = AccessLogPolicy.excessCount(totalRecords: total)
        if excess > 0 {
            var oldest = FetchDescriptor<ToolActivityRecord>(
                sortBy: [SortDescriptor(\.createdAt)])
            oldest.fetchLimit = excess
            var deleted = 0
            for record in (try? context.fetch(oldest)) ?? [] {
                context.delete(record)
                deleted += 1
            }
            activityCounts[key] = total - deleted
        }
        try? context.save()
    }

    /// Audit E-05: forget the in-memory access-log count for a
    /// container whose records were removed OUTSIDE
    /// `recordToolEvent` (Settings' Clear Log deletes them
    /// directly) — the next event re-seeds from a real count
    /// instead of rotating against a stale total.
    static func resetActivityCount(for container: ModelContainer) {
        activityCounts[ObjectIdentifier(container)] = nil
    }

    // MARK: - Action plans (Phase 6)

    /// The runtime's proposal sink, bound to THIS engine.
    /// Validated file-action proposals arrive here and land on the
    /// conversation's pending list. Returns false for an identical
    /// change already on the list.
    ///
    /// Review finding 16: this used to be a single static sink
    /// forwarding to a static `proposalTarget` that every engine
    /// init overwrote — with several windows open, a tool in an
    /// older window proposed into the NEWEST window's engine,
    /// leaving its own approval card empty. The sink is now an
    /// instance closure capturing this engine weakly, built fresh
    /// for each tool runtime; no process-global mutable destination
    /// for per-window work remains. (The activity-log sink below
    /// is still static by design: it carries its container with it
    /// and writes through that container, not through shared state.)
    func proposalSink() -> @Sendable (UUID, PlannedAction) async -> Bool {
        { [weak self] conversationID, action in
            await MainActor.run {
                self?.recordProposedAction(
                    action, conversationID: conversationID) ?? false
            }
        }
    }

    /// One validated proposal from the tool runtime. Identical
    /// changes already pending are refused, so a chatty model can't
    /// stack duplicates the user then has to wade through.
    /// Phase 9: a proposal carrying a danger warning (a flagged
    /// command) starts out in the unchecked set — the user must
    /// deliberately check it before Approve can run it.
    @discardableResult
    func recordProposedAction(_ action: PlannedAction,
                              conversationID: UUID) -> Bool {
        let existing = pendingPlans[conversationID] ?? []
        guard !ActionPlanRules.isDuplicate(action, in: existing) else {
            return false
        }
        pendingPlans[conversationID] = existing + [action]
        if action.requiresExplicitOptIn {
            excludedPlanItems[conversationID, default: []].insert(action.id)
        }
        return true
    }

    /// The pending approval list for a conversation (empty if none).
    func pendingPlan(for conversationID: UUID) -> [PlannedAction] {
        pendingPlans[conversationID] ?? []
    }

    /// Removes one item from a pending list — the card's per-item
    /// opt-out. What's left is what Approve will run.
    func removePendingAction(_ actionID: UUID, conversationID: UUID) {
        guard var plan = pendingPlans[conversationID] else { return }
        plan.removeAll { $0.id == actionID }
        pendingPlans[conversationID] = plan.isEmpty ? nil : plan
        excludedPlanItems[conversationID]?.remove(actionID)
    }

    /// The unchecked set for a conversation's pending list — the
    /// card renders these rows unchecked (see `recordProposedAction`
    /// for how an item lands there).
    func excludedPendingItems(for conversationID: UUID) -> Set<UUID> {
        excludedPlanItems[conversationID] ?? []
    }

    /// Checks or unchecks one pending item. An unchecked item is
    /// not removed — Approve records it as declined, so the model
    /// learns it was deliberately left out.
    func setPendingActionIncluded(_ actionID: UUID, included: Bool,
                                  conversationID: UUID) {
        if included {
            excludedPlanItems[conversationID]?.remove(actionID)
        } else {
            excludedPlanItems[conversationID, default: []].insert(actionID)
        }
    }

    /// The user pressed Approve: run every CHECKED item in order,
    /// persist the decided plan (the transcript card), audit-log
    /// each item, and queue the outcome note for the model's next
    /// turn. A per-item failure is recorded on that item; the rest
    /// still run. Items left unchecked (Phase 9's opt-in rule for
    /// flagged commands — or any item the user unchecked) don't
    /// run; they're recorded as declined, so the model learns they
    /// were deliberately left out rather than forgotten.
    func approvePlan(conversationID: UUID, context: ModelContext) {
        guard let plan = pendingPlans[conversationID], !plan.isEmpty,
              !planBusyIDs.contains(conversationID) else { return }
        pendingPlans[conversationID] = nil
        let excluded = excludedPlanItems[conversationID] ?? []
        excludedPlanItems[conversationID] = nil
        planBusyIDs.insert(conversationID)
        let mcpExecutor = mcpExecutorProvider
        let planKey = UUID()
        // Audit B-52: the execution task is STORED per conversation
        // (like a send task), so `forget` can cancel it — the old
        // fire-and-forget task kept running file changes, commands,
        // and MCP calls invisibly after its conversation was
        // deleted, then wrote records and outcome notes for it.
        planTasks[conversationID] = Task { [weak self] in
            let backupDirectory = Self.backupDirectory(for: planKey)
            var executed: [ExecutedActionItem] = []
            for action in plan {
                // Stop between items when cancelled (deletion is
                // the canceller — see `forget`).
                if Task.isCancelled { break }
                if excluded.contains(action.id) {
                    executed.append(ExecutedActionItem(
                        action: action, outcome: .declined,
                        resultNote: "Not run — it was left unchecked when the list was approved."))
                } else {
                    // Review finding 7: re-read the CURRENT
                    // availability before EVERY item, not once per
                    // approval — the loop awaits each item, so a
                    // folder unshared, the lock flipped, or a
                    // switch turned off mid-approval must reach the
                    // remaining items through the gate, not through
                    // a snapshot taken when Approve was pressed.
                    guard let currentAvailability = self?.toolAvailabilityProvider()
                    else { break }
                    // Audit E-90: `executePlanItem` is `nonisolated`
                    // (see its declaration), so this await runs the
                    // item's blocking disk/image work OFF the main
                    // actor — a big file copy or photo resize used
                    // to freeze the UI for its duration. Only the
                    // record-keeping below is on the main actor.
                    executed.append(await Self.executePlanItem(
                        action, roots: currentAvailability.folderRootPaths,
                        backupDirectory: backupDirectory,
                        localOnly: currentAvailability.localOnly,
                        powerToolsEnabled: currentAvailability.effectivePowerToolsEnabled,
                        fileWritingEnabled: currentAvailability.fileWritingEnabled,
                        mcpExecutor: mcpExecutor))
                }
            }
            let wasCancelled = Task.isCancelled
            await MainActor.run {
                guard let self else { return }
                self.planTasks[conversationID] = nil
                self.planBusyIDs.remove(conversationID)
                // Audit B-51/B-52: a deleted conversation gets no
                // record, no audit events, and no re-created
                // outcome note — `forget` already cleared them, and
                // this completion must not resurrect any of it.
                guard !self.forgottenIDs.contains(conversationID),
                      !wasCancelled else { return }
                // Audit E-05: the record carries the plan's key as
                // its id, so its backup folder is named by the
                // record (`ActionBackups/<record id>`) and rotation
                // can find — and delete — the folder when the
                // record goes.
                let record = ActionPlanRecord(conversationID: conversationID,
                                              status: .executed,
                                              items: executed,
                                              id: planKey)
                Self.insertPlanRecord(record, context: context)
                try? context.save()
                for item in executed {
                    Self.recordToolEvent(ToolEvent(
                        conversationID: conversationID,
                        toolName: Self.auditToolName(for: item.action),
                        source: Self.auditSource(for: item.action.kind),
                        querySummary: item.action.summary,
                        resultSummary: ToolResultText.summary(
                            of: item.resultNote),
                        date: Date()), context: context)
                }
                self.pendingOutcomeNotes[conversationID] =
                    Self.approvalOutcomeNote(items: executed)
            }
        }
    }

    /// Persists one decided plan record, rotating the oldest plan
    /// records away past `ActionPlanLogPolicy`'s cap (audit S-04 —
    /// plan records store full payloads and previously grew without
    /// bound, unlike the access log beside them).
    ///
    /// Audit E-05: rotation now also deletes each pruned record's
    /// pre-edit backup folder — a rotated record can never be
    /// undone (its card is gone), so its backups are unreachable;
    /// before this, the folders accumulated forever even though
    /// the records themselves were capped.
    private static func insertPlanRecord(_ record: ActionPlanRecord,
                                         context: ModelContext) {
        context.insert(record)
        let total = (try? context.fetchCount(
            FetchDescriptor<ActionPlanRecord>())) ?? 0
        let excess = ActionPlanLogPolicy.excessCount(totalRecords: total)
        if excess > 0 {
            var oldest = FetchDescriptor<ActionPlanRecord>(
                sortBy: [SortDescriptor(\.createdAt)])
            oldest.fetchLimit = excess
            for stale in (try? context.fetch(oldest)) ?? [] {
                context.delete(stale)
                Self.deleteBackupFolder(forRecordID: stale.id)
            }
        }
    }

    // MARK: - Backup-folder retention (audit E-05)

    /// The `ActionBackups` root: one folder per decided plan,
    /// named by the plan record's id.
    private static var actionBackupsRoot: URL {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent(
            "LocalLLM/ActionBackups", isDirectory: true)
    }

    /// Deletes one plan record's backup folder, if it has one.
    /// Called when the record itself goes away (rotation), and by
    /// the views when records are deleted directly (a conversation
    /// delete, Clear Log).
    static func deleteBackupFolder(forRecordID recordID: UUID) {
        let folder = actionBackupsRoot.appendingPathComponent(
            ActionBackupRetention.folderName(recordID: recordID),
            isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
    }

    /// Audit E-05: the startup orphan sweep, run once per launch
    /// from the app shell. Backup folders whose plan record is
    /// gone — or retained but no longer undoable (already undone,
    /// or a discard, which never made backups) — are deleted; a
    /// retained, executed, not-yet-undone record's folder is NEVER
    /// touched, because its Undo still restores from it.
    /// `ActionBackupRetention` makes the call, purely.
    ///
    /// Review finding 10, FAIL CLOSED: the sweep runs ONLY when
    /// the persistent store actually opened AND the reference
    /// fetch succeeded. Two guards enforce that, in order, before
    /// anything is deleted:
    ///  - an in-memory store (the launch fallback when the
    ///    persistent store fails to open) holds no retained
    ///    records to protect, so sweeping against it would delete
    ///    every real backup folder — the sweep skips it entirely,
    ///    and the app shell additionally skips the call and shows
    ///    a banner (see ContentView);
    ///  - a failed reference fetch is unknown, never "no records":
    ///    `deletableFoldersIfReferencesKnown` returns nil for an
    ///    unavailable reference set, and the sweep deletes nothing.
    ///    A successful fetch that genuinely returns no records is
    ///    `[]`, and only that case deletes orphans.
    func pruneOrphanedActionBackups(context: ModelContext) {
        guard !didSweepActionBackups else { return }
        didSweepActionBackups = true
        guard !context.container.configurations.contains(
            where: { $0.isStoredInMemoryOnly }) else { return }
        let root = Self.actionBackupsRoot
        guard let folderNames = try? FileManager.default
            .contentsOfDirectory(atPath: root.path),
              !folderNames.isEmpty else { return }
        let retained: [(id: UUID, status: ActionPlanRecord.Status,
                        isUndone: Bool)]
        do {
            let records = try context.fetch(
                FetchDescriptor<ActionPlanRecord>())
            retained = records.map {
                (id: $0.id, status: $0.status, isUndone: $0.isUndone)
            }
        } catch {
            return
        }
        guard let deletable = ActionBackupRetention
            .deletableFoldersIfReferencesKnown(
                folderNames: folderNames, retained: retained) else { return }
        for name in deletable {
            try? FileManager.default.removeItem(
                at: root.appendingPathComponent(name, isDirectory: true))
        }
    }

    /// Audit E-05: the startup backup sweep runs once per launch.
    private var didSweepActionBackups = false

    /// Runs one approved item through the executor for its kind:
    /// file changes in `FileActionService`, commands in
    /// `ShellCommandService`, MCP calls through the shell-provided
    /// executor. Every path applies the same pure pre-check first —
    /// the world may have changed since the proposal.
    ///
    /// Audit E-90: `nonisolated` — this dispatcher (and the
    /// executors it awaits) does blocking disk/image work, and it
    /// used to inherit the engine's @MainActor isolation through
    /// the plan task, freezing the UI for a big copy or resize.
    /// It touches no engine state; the MCP executor it awaits hops
    /// to the main actor internally for the manager call, as
    /// before.
    nonisolated private static func executePlanItem(
        _ action: PlannedAction, roots: [String], backupDirectory: URL,
        localOnly: Bool = false,
        powerToolsEnabled: Bool = true,
        fileWritingEnabled: Bool = true,
        mcpExecutor: @MainActor (PlannedAction) async -> ExecutedActionItem?
    ) async -> ExecutedActionItem {
        // Review finding 7: the execution-time grant gate runs
        // FIRST — before the pre-check and before any executor.
        // Audit S-06's Local Only refusal for power items is one
        // of its cases; the gate adds the master-switch-off and
        // file-writing-off refusals alongside it.
        if let refusal = PlanExecutionGate.refusal(
            for: action, localOnly: localOnly,
            powerToolsEnabled: powerToolsEnabled,
            fileWritingEnabled: fileWritingEnabled) {
            return ExecutedActionItem(action: action,
                                      outcome: .failed(refusal),
                                      resultNote: refusal)
        }
        // Audit S-02: the pre-check re-resolves paths at execution
        // time, exactly as the proposal resolved them.
        if let refusal = ActionExecution.preCheck(
            action, roots: roots, probe: FileActionService.probe,
            resolve: { FileAccessService.resolvedPath($0) ?? $0 },
            resolveDestination: {
                FileAccessService.resolvedDestinationPath($0) ?? $0
            },
            resolveExistingDestination: {
                FileAccessService.resolvedPath($0) ?? $0
            }) {
            return ExecutedActionItem(action: action,
                                      outcome: .failed(refusal),
                                      resultNote: refusal)
        }
        switch action.kind {
        case .runCommand:
            return await ShellCommandService.execute(action)
        case .mcpCall:
            if let item = await mcpExecutor(action) { return item }
            let note = "That MCP server isn't available — it may have been removed from Settings."
            return ExecutedActionItem(action: action,
                                      outcome: .failed(note),
                                      resultNote: note)
        default:
            return await FileActionService.execute(
                action, roots: roots, backupDirectory: backupDirectory)
        }
    }

    /// The audit log's tool name for an item: an MCP call logs
    /// under its concrete namespaced name; everything else under
    /// its kind's tool.
    private static func auditToolName(for action: PlannedAction) -> String {
        if action.kind == .mcpCall, let namespaced = action.mcpNamespacedName {
            return namespaced
        }
        return action.kind.toolName
    }

    /// The audit log's source for an item: photo resizes belong to
    /// Photos, file changes to Files, and the power tools to no
    /// source at all (they're gated by their own switch, not a
    /// visibility source).
    private static func auditSource(for kind: PlannedActionKind)
        -> VisibilitySource? {
        switch kind {
        case .resizePhoto: return .photos
        case .runCommand, .mcpCall: return nil
        default: return .files
        }
    }

    /// The user pressed Discard: nothing runs, the decision is still
    /// recorded (card + audit), and the model is told plainly — so it
    /// doesn't quietly re-propose the same changes next turn.
    func discardPlan(conversationID: UUID, context: ModelContext) {
        guard let plan = pendingPlans[conversationID], !plan.isEmpty,
              !planBusyIDs.contains(conversationID) else { return }
        pendingPlans[conversationID] = nil
        excludedPlanItems[conversationID] = nil
        let record = ActionPlanRecord(
            conversationID: conversationID, status: .discarded,
            items: plan.map {
                ExecutedActionItem(
                    action: $0, outcome: .declined,
                    resultNote: "Not done — the list was discarded.")
            })
        Self.insertPlanRecord(record, context: context)
        try? context.save()
        for action in plan {
            Self.recordToolEvent(ToolEvent(
                conversationID: conversationID,
                toolName: Self.auditToolName(for: action),
                source: Self.auditSource(for: action.kind),
                querySummary: action.summary,
                resultSummary: "Discarded by the user — nothing was changed or run.",
                date: Date()), context: context)
        }
        pendingOutcomeNotes[conversationID] =
            "The user discarded the list of \(plan.count) "
            + "change(s) you proposed — NOTHING was changed or run. "
            + "Do not re-propose them unless the user asks again."
    }

    /// The user pressed Undo on an executed plan's card: reverse
    /// every reversible item, newest first, record each item's undo
    /// note on the plan, audit-log the undo, and queue the outcome
    /// note. Items that can't be reversed say so honestly on the
    /// card rather than pretending.
    ///
    /// Review finding 18: a plan is stamped fully undone ONLY
    /// when its reversible work actually succeeded. A failed
    /// attempt leaves `undoneAt` unset — so the Undo button stays
    /// (the plan is still retryable once the user fixes the
    /// condition, e.g. re-shares the folder or clears the
    /// destination) AND the startup backup sweep keeps the
    /// still-needed backups (it protects every retained, executed,
    /// not-yet-undone record). Steps that did succeed are flagged
    /// on their items, so a retry attempts only outstanding work.
    func undoPlan(record: ActionPlanRecord, context: ModelContext) {
        let conversationID = record.conversationID
        guard record.canUndo, !planBusyIDs.contains(conversationID)
        else { return }
        planBusyIDs.insert(conversationID)
        let undoRoots = toolAvailabilityProvider().folderRootPaths
        // Audit B-52: stored per conversation, like the approve
        // task, so `forget` can cancel an undo in flight too.
        planTasks[conversationID] = Task { [weak self] in
            var items = record.items
            let steps = ActionUndo.steps(for: items, home: NSHomeDirectory())
            // Steps are keyed by the action's id, not by position.
            var results: [(item: ExecutedActionItem, note: String,
                           outcome: UndoStepOutcome)] = []
            for step in steps {
                // Stop between steps when cancelled (audit B-52).
                if Task.isCancelled { break }
                // Audit E-90: undo's disk work also runs off the
                // main actor, like approval's (see `approvePlan`).
                let result = await Task.detached {
                    FileActionService.executeUndoStepResult(
                        step, roots: undoRoots)
                }.value
                if let index = items.firstIndex(
                    where: { $0.action.id == step.itemID }) {
                    items[index].undoNote = result.note
                    items[index].undoSucceeded =
                        result.outcome == .succeeded
                    results.append((items[index], result.note,
                                    result.outcome))
                }
            }
            let wasCancelled = Task.isCancelled
            await MainActor.run {
                guard let self else { return }
                self.planTasks[conversationID] = nil
                self.planBusyIDs.remove(conversationID)
                // Audit B-51/B-52: no writes for a deleted
                // conversation (see `approvePlan`).
                guard !self.forgottenIDs.contains(conversationID),
                      !wasCancelled else { return }
                record.items = items
                // Review finding 18: stamp ONLY on full success.
                // Non-reversible steps never block this; any
                // failed reversible step leaves the plan undoable
                // and its backups retained.
                let fullyUndone = UndoCompletion.isFullyUndone(
                    outcomes: results.map { $0.outcome })
                if fullyUndone {
                    record.undoneAt = Date()
                }
                try? context.save()
                for entry in results {
                    Self.recordToolEvent(ToolEvent(
                        conversationID: conversationID,
                        toolName: Self.auditToolName(for: entry.item.action),
                        source: Self.auditSource(for: entry.item.action.kind),
                        querySummary: "Undo: \(entry.item.action.summary)",
                        resultSummary: ToolResultText.summary(of: entry.note),
                        date: Date()), context: context)
                }
                let lines = results.map {
                    "• \($0.item.action.summary) — \($0.note)"
                }
                if fullyUndone {
                    self.pendingOutcomeNotes[conversationID] =
                        "The user undid what could be undone from the "
                        + "approved list. Results:\n" + lines.joined(separator: "\n")
                } else {
                    self.pendingOutcomeNotes[conversationID] =
                        "The user tried to undo the approved list, "
                        + "but some items could not be undone — "
                        + "Undo is still available, so the user can "
                        + "fix the problem and try again. Results:\n"
                        + lines.joined(separator: "\n")
                }
            }
        }
    }

    /// The note the model sees after an approval: per-item results,
    /// in the conversation's own terms. Phase 9: a command or MCP
    /// item's substance (what it printed / what the server
    /// answered) rides along as the item's detail — for those
    /// kinds the output is the whole reason the item ran.
    private static func approvalOutcomeNote(
        items: [ExecutedActionItem]) -> String {
        let lines = items.map { item -> String in
            let detail = item.modelDetail.map { "\n\($0)" } ?? ""
            switch item.outcome {
            case .done:
                return "• \(item.action.summary) — done. \(item.resultNote)\(detail)"
            case .failed(let reason):
                return "• \(item.action.summary) — FAILED. \(reason)\(detail)"
            case .declined:
                return "• \(item.action.summary) — not run. \(item.resultNote)"
            }
        }
        let allFileChanges = items.allSatisfy {
            $0.action.kind != .runCommand && $0.action.kind != .mcpCall
        }
        let heading = allFileChanges
            ? "The user approved the list of file changes you proposed."
            : "The user approved the list of changes and actions you proposed."
        return heading + " Results:\n" + lines.joined(separator: "\n")
    }

    /// Where pre-edit backups live: one folder per approved plan,
    /// inside the app's own Application Support — never inside the
    /// user's shared folders, so a backup can never be mistaken for
    /// the user's file (or proposed on by a later action).
    private static func backupDirectory(for planKey: UUID) -> URL {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent(
            "LocalLLM/ActionBackups/\(planKey.uuidString)", isDirectory: true)
    }

    // MARK: - Sessions

    /// A conversation's live session and everything needed to know
    /// whether it can be reused for the next send: which backend made
    /// it, the instructions it was created with, the summary its
    /// context reflects, whether it has been seeded, and — for MLX
    /// sessions — the KV-cache mode it was created under (a cache's
    /// layout is fixed at creation, so a Settings change there must
    /// retire the session; other backends ignore the field).
    private struct LiveSession {
        let session: ChatSession
        let selection: ModelSelection
        let instructions: String
        let summaryKey: String
        let seeded: Bool
        let kvCacheMode: KVCacheMode
        /// Phase 5: the tool-availability signature the session's
        /// tool set was built from ("none" for tool-less backends).
        /// Tools are bound at session creation on every backend, so
        /// a changed toggle or folder list must retire the session
        /// exactly like an instructions edit does.
        let toolsSignature: String
        /// Audit B-47: the resolved backend's configuration digest
        /// (`SessionConfigDigest`) — endpoint URL + model, or a
        /// one-way digest of the OpenRouter key. The selection alone
        /// doesn't capture either, so without this an edited server
        /// or rotated key never retired a live session. Compared
        /// in-memory only: `LiveSession` values are never persisted.
        let configDigest: String
    }

    private var liveSessions: [UUID: LiveSession] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]
    /// Audit B-52: plan approve/undo execution tasks, per
    /// conversation — stored (unlike the old fire-and-forget tasks)
    /// so `forget` can cancel them and their loops can stop between
    /// items.
    private var planTasks: [UUID: Task<Void, Never>] = [:]
    /// Audit B-51: conversations deleted while work was in flight.
    /// Cancellation is cooperative and the send/plan pipelines have
    /// wide suspension windows, so the pipelines consult this
    /// tombstone set after suspensions and before saving anything;
    /// a forgotten conversation's late reply or plan record is
    /// dropped silently instead of being inserted against a deleted
    /// `Conversation`. Entries are never removed (ids are unique
    /// and never reused).
    private var forgottenIDs: Set<UUID> = []

    func isResponding(_ conversationID: UUID) -> Bool {
        respondingIDs.contains(conversationID)
    }

    func stop(conversationID: UUID) {
        tasks[conversationID]?.cancel()
    }

    /// The conversation was deleted — forget its session and any stream.
    func forget(conversationID: UUID) {
        // Audit B-51/B-52: tombstone FIRST, then cancel everything
        // in flight for this conversation — the send task AND any
        // plan approve/undo task. The pipelines check the tombstone
        // after their suspensions and before saving, so a task
        // unwinding after the sidebar's delete can't insert a reply
        // or plan record into the deleted conversation.
        forgottenIDs.insert(conversationID)
        tasks[conversationID]?.cancel()
        tasks[conversationID] = nil
        planTasks[conversationID]?.cancel()
        planTasks[conversationID] = nil
        retireSession(conversationID)
        streamingText[conversationID] = nil
        respondingIDs.remove(conversationID)
        errorMessages[conversationID] = nil
        routingNotes[conversationID] = nil
        lastEffectiveSelections[conversationID] = nil
        infoMessages[conversationID] = nil
        pendingPlans[conversationID] = nil
        excludedPlanItems[conversationID] = nil
        pendingOutcomeNotes[conversationID] = nil
        pendingPromptPrefixes[conversationID] = nil
        planBusyIDs.remove(conversationID)
    }

    // MARK: - Sending

    /// Appends the user's message (with any prepared image attachments),
    /// then prepares the context — compacting first if needed — and
    /// streams the model's reply, saving it as an assistant message when
    /// the stream finishes (or partially, if stopped or interrupted).
    ///
    /// `promptPrefix` (Phase 7) is extra context folded into the sent
    /// copy of the prompt — the quick panel's captured context — and
    /// is never stored as part of the user's message.
    func send(text: String,
              attachments: [ImageAttachment] = [],
              in conversation: Conversation,
              context: ModelContext,
              promptPrefix: String? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty,
              !isResponding(conversation.id),
              // Audit B-51: a deleted conversation accepts no sends.
              !forgottenIDs.contains(conversation.id) else { return }
        if let promptPrefix, !promptPrefix.isEmpty {
            pendingPromptPrefixes[conversation.id] = promptPrefix
        }

        let userMessage = Message(role: .user, text: trimmed,
                                  conversation: conversation)
        if !attachments.isEmpty {
            userMessage.attachmentsData = ImageAttachmentCodec.encode(attachments)
            // Review finding 19: cache the count alongside the blob
            // at the one moment the attachments are known — the
            // context meter and planner then read this number
            // instead of scanning the blob on every render/send.
            userMessage.storedAttachmentCount =
                ImageAttachmentCodec.storedCount(for: attachments)
        }
        context.insert(userMessage)
        if conversation.title == "New Chat" {
            conversation.title = trimmed.isEmpty
                ? "Image chat"
                : String(trimmed.prefix(48))
        }
        conversation.updatedAt = Date()
        try? context.save()

        let conversationID = conversation.id
        errorMessages[conversationID] = nil
        infoMessages[conversationID] = nil
        respondingIDs.insert(conversationID)
        streamingText[conversationID] = ""
        tasks[conversationID] = Task { [weak self] in
            await self?.prepareAndStream(conversation: conversation,
                                         context: context)
        }
    }

    /// Backend resolution, compaction (if the plan calls for it),
    /// session selection, and the streaming call itself. Runs inside
    /// the send task, so Stop cancels it at any stage.
    private func prepareAndStream(conversation: Conversation,
                                  context: ModelContext) async {
        let conversationID = conversation.id
        // Audit B-43: tool executions during this send report to the
        // access log through a sink built with THIS send's container
        // (see the session-creation site below) — no shared static.
        // Audit B-51: whether this conversation was deleted while
        // this send was suspended. Checked after each suspension
        // window and before saving anything.
        func isForgotten() -> Bool {
            forgottenIDs.contains(conversationID)
        }
        let instructions = PromptHistory.mergedInstructions(
            userInstructions: conversation.systemInstructions)

        let stored = conversation.sortedMessages
        guard let lastMessage = stored.last,
              lastMessage.messageRole == .user else {
            finish(conversationID: conversationID)
            return
        }
        let newPromptTurn = lastMessage.chatTurn

        // Phase 4 routing: an Auto chat's prompt is classified and
        // routed to a concrete backend first; a manual selection is
        // already concrete and skips this entirely.
        let routingInputs = routingContextProvider()
        var targetSelection = conversation.modelSelection
        if conversation.modelSelection.isAuto {
            let intent = await IntentClassifier.classify(
                prompt: lastMessage.text) ?? .quickTransform
            if Task.isCancelled || isForgotten() {
                finish(conversationID: conversationID)
                return
            }
            let decision = RoutingPolicy.decide(intent: intent,
                                                inputs: routingInputs)
            targetSelection = decision.selection
            var noteText = decision.reason
            if let note = decision.note {
                noteText += " " + note
            }
            routingNotes[conversationID] = noteText
        }

        let resolved = backendProvider(targetSelection)
        let backend = resolved.backend
        let selection = resolved.effectiveSelection
        // UAT-06: remember who is really answering this send.
        lastEffectiveSelections[conversationID] = selection
        let budget = backend.budget
        if selection != targetSelection {
            // The picked (or routed) model can't run: it was deleted,
            // its server was removed, the Local Only lock refuses
            // servers and cloud models right now, or an OpenRouter
            // chat has no key yet. The chat falls back to the built-in
            // model — say which happened, once, rather than silently
            // switching.
            let targetLeavesMac: Bool = {
                switch targetSelection {
                case .endpoint, .privateCloudCompute, .openRouter:
                    return true
                case .auto, .onDevice, .mlx:
                    return false
                }
            }()
            if routingInputs.localOnly, targetLeavesMac {
                errorMessages[conversationID] =
                    "Local Only is on, so this chat can't use a "
                    + "server or cloud model right now — it switched "
                    + "to a model that runs entirely on this Mac."
            } else if case .openRouter = targetSelection {
                errorMessages[conversationID] =
                    "This chat's cloud model needs your OpenRouter "
                    + "API key first — add it in Settings → Cloud "
                    + "models (gear button). Until then, this chat "
                    + "uses the built-in on-device model."
            } else {
                errorMessages[conversationID] =
                    SharedWording.modelUnavailableFallback
            }
        }

        // Phase 4 privacy firewall, extended by Phase 8 to the
        // cloud. A prompt can now leave the machine three ways: a
        // server that isn't on this Mac, Private Cloud Compute, or
        // OpenRouter. Everything bound for one of those — the
        // instructions now, the prompt (seeded history included)
        // further below — is scrubbed by `Redactor` first. Local
        // destinations (built-in model, MLX, a localhost server) get
        // the text exactly as written. Stored messages are never
        // touched; only the sent copy is edited.
        // Audit S-08: the destination test lives in
        // `RemoteDestination` (shared with compare mode) and fails
        // CLOSED — a server selection whose config is missing
        // counts as remote, never as local.
        let isRemoteDestination = RemoteDestination.isRemote(
            selection: selection, endpoints: routingInputs.endpoints)
        var effectiveInstructions = instructions
        var redactions = 0
        if isRemoteDestination {
            let scrubbed = Redactor.redact(
                instructions,
                customTerms: routingInputs.customRedactionTerms)
            effectiveInstructions = scrubbed.text
            redactions += scrubbed.replacementCount
        }

        // Live turns: stored history minus the summarized prefix and
        // minus the message about to be sent. Audit E-07: the array
        // is built ONCE per send — the old code rebuilt it (a sort
        // plus a `chatTurn` per message) before the first plan and
        // after EVERY compaction pass. A pass only ever folds a
        // PREFIX of the live turns into the summary, so between
        // passes the array is updated by dropping that prefix —
        // the same turns, no rebuild.
        var liveTurns: [ChatTurn] = {
            let all = conversation.sortedMessages.dropLast()
            let prefix = min(conversation.summarizedMessageCount, all.count)
            return Array(all.dropFirst(prefix)).map { $0.chatTurn }
        }()

        // Review finding 12: budget the COMPLETE serialized prompt,
        // not just instructions + summary + turns + new message.
        // The tool count is the static catalog for this snapshot's
        // enabled sources plus the MCP tools from the last discovery
        // (their "slug:tool;…" signature lists one entry per tool);
        // the outcome note and HUD prefix are the exact strings
        // that will ride at the head of this prompt. This is an
        // ESTIMATE snapshot for planning only — session identity
        // still comes from the post-discovery snapshot below.
        // The MLX reply cap itself was already fixed in batch 1
        // (the MLX budget reserves the full 4,096-token reply cap),
        // so `promptAllowanceTokens` here already budgets the
        // actual generation limit.
        let planningAvailability = toolAvailabilityProvider()
        let planningToolCount: Int = {
            guard backend.supportsTools, planningAvailability.hasTools else { return 0 }
            let catalog = ToolCatalog.descriptors(
                enabledSources: planningAvailability.enabledSources,
                fileWritingEnabled: planningAvailability.fileWritingEnabled,
                powerToolsEnabled: planningAvailability.effectivePowerToolsEnabled,
                localOnly: planningAvailability.localOnly).count
            let mcp = planningAvailability.effectivePowerToolsEnabled
                ? planningAvailability.mcpToolsSignature
                    .split(separator: ";").filter { !$0.isEmpty }.count
                : 0
            return catalog + mcp
        }()
        let planningOverhead = ContextManager.planningOverheadTokens(
            toolCount: planningToolCount,
            outcomeNote: pendingOutcomeNotes[conversationID],
            promptPrefix: pendingPromptPrefixes[conversationID],
            hasTools: backend.supportsTools && planningAvailability.hasTools)

        // Compaction passes — always before streaming, never mid-stream.
        // One pass summarizes a bounded chunk; a very long history can
        // need several, so loop (with a sane cap) until the plan fits.
        var plan = ContextManager.plan(budget: budget,
                                       instructions: instructions,
                                       existingSummary: conversation.contextSummary,
                                       liveTurns: liveTurns,
                                       newPrompt: newPromptTurn,
                                       overheadTokens: planningOverhead)
        var passes = 0
        while plan.needsCompaction, passes < 4 {
            passes += 1
            // The summarizer is the on-device model (4K window) even
            // when the chat's backend is bigger, so cap each chunk to
            // what the summarizer can actually read; later passes fold
            // the rest.
            let chunk = summarizerChunk(plan.turnsToSummarize,
                                        existingSummary: conversation.contextSummary)
            let newSummary = await summarize(
                existingSummary: conversation.contextSummary,
                turns: chunk,
                targetTokens: budget.summaryTargetTokens)
            if Task.isCancelled || isForgotten() {
                finish(conversationID: conversationID)
                return
            }
            conversation.contextSummary = newSummary
            conversation.summarizedMessageCount += chunk.count
            conversation.updatedAt = Date()
            try? context.save()
            retireSession(conversationID) // its context is now stale
            // The folded chunk was a prefix of the live turns.
            liveTurns = Array(liveTurns.dropFirst(chunk.count))
            plan = ContextManager.plan(budget: budget,
                                       instructions: instructions,
                                       existingSummary: conversation.contextSummary,
                                       liveTurns: liveTurns,
                                       newPrompt: newPromptTurn,
                                       overheadTokens: planningOverhead)
        }

        // Review finding 13: the loop above stops after four passes
        // and the old code then proceeded WITHOUT acting on
        // `overflowWarning` — a long chat could keep failing rather
        // than self-managing, while nothing told the user. An
        // unresolved overflow is now explicit: a visible banner
        // says the conversation still doesn't fit even after
        // summarizing, and that the send goes ahead best-effort
        // (the model may not see the oldest context, or may report
        // its own overflow error). This is a notice, not a block:
        // refusing the send would strand a chat that can still
        // answer from its recent turns.
        if plan.needsCompaction || plan.overflowWarning {
            let overflowNote = "This conversation is still too long "
                + "for the model's memory even after summarizing, "
                + "so this reply goes ahead as a best effort — the "
                + "model may not see the oldest context."
            infoMessages[conversationID] =
                [infoMessages[conversationID], overflowNote]
                    .compactMap { $0 }
                    .joined(separator: " ")
        }

        // Session selection and seeding. A live session is reused only
        // when backend, instructions, and summary all still match —
        // anything else (first send, picker switch, instructions edit,
        // compaction, relaunch) rebuilds and re-seeds. An MLX session
        // additionally has to have been created under the current
        // KV-cache mode: the cache layout is fixed at creation, so a
        // Settings change retires MLX sessions here and the rebuild
        // re-seeds them from the stored conversation, exactly like a
        // picker switch. (The pure rule lives in
        // `KVCacheMode.sessionReusable`; other backends never retire
        // over this setting.)
        // Note the session identity uses the *effective* instructions
        // (the scrubbed copy for a remote destination), so a session
        // is never reused across a change in what would be sent.
        // Phase 5: the tool set for this send. Tool-capable backends
        // (on-device, MLX) get one when the user has enabled any
        // visibility source; endpoint chats never do. The signature
        // joins the reuse check below, so a toggled source or changed
        // folder list rebuilds the session with the new tool set.
        // Phase 8: Private Cloud Compute is tool-capable AND remote,
        // so its tool set is built with `redactResults` on (below, at
        // session creation) — lookup results pass the privacy check
        // inside the runtime before they can enter a cloud prompt.
        // Local tool hosts keep raw results.
        let toolAvailability = toolAvailabilityProvider()
        // Audit E-08: this value is only the PRE-discovery
        // signature, used for the reuse check. When a session is
        // actually BUILT below, the runtime AND the stored
        // signature both come from the SAME post-discovery
        // snapshot (review finding 7) — the old code built the
        // runtime from this pre-discovery snapshot and then
        // recorded a freshly recomputed signature, so a source or
        // folder disabled during discovery stayed granted in the
        // runtime while the stored signature described the new
        // restricted settings, and the next send re-blessed the
        // stale runtime. (The first discovery used to poison the
        // stored signature the other way, so the following send
        // always paid a spurious full rebuild + reseed even though
        // nothing had changed; the single-snapshot rule fixes both
        // directions.)
        // Review finding 6, defense in depth: a tool-less backend's
        // signature is no longer a constant "none" — for a remote
        // destination it carries the redaction-terms hash, so
        // adding a term retires the session like any other
        // settings change. (The transport scrub itself no longer
        // depends on retirement: sessions scrub each send's
        // payload with the current terms.)
        var toolsSignature = backend.supportsTools
            ? toolAvailability.signature
            : (isRemoteDestination
                ? "none|terms:" + RedactionTermsHash.value(
                    for: routingInputs.customRedactionTerms)
                : "none")

        let summaryKey = conversation.contextSummary ?? ""
        let existing = liveSessions[conversationID]
        let selectionIsMLX: Bool = {
            if case .mlx = selection { return true }
            return false
        }()
        let canReuse = existing != nil
            && existing!.selection == selection
            && existing!.instructions == effectiveInstructions
            && existing!.summaryKey == summaryKey
            && existing!.seeded
            && existing!.toolsSignature == toolsSignature
            // Audit B-47: the backend's configuration must also
            // match — an edited server (URL/model) or a rotated
            // OpenRouter key retires the session like any other
            // signature change.
            && existing!.configDigest == resolved.configDigest
            && KVCacheMode.sessionReusable(
                sessionMode: existing!.kvCacheMode,
                currentMode: routingInputs.kvCacheMode,
                selectionIsMLX: selectionIsMLX)

        let session: ChatSession
        var promptText = lastMessage.text
        if canReuse, let existing {
            session = existing.session
        } else {
            let sessionTools: SessionTools?
            if backend.supportsTools, toolAvailability.hasTools {
                // Phase 9: with power tools on, the MCP servers'
                // tools join this session's set — fetched here, at
                // session build, which is the one moment that may
                // launch a server process (lazily; a failed server
                // simply contributes nothing).
                // Audit S-06: under Local Only there are no power
                // tools and no discovery — servers don't even launch.
                let mcpTools = toolAvailability.effectivePowerToolsEnabled
                    ? await mcpToolsProvider()
                    : []
                // Review finding 7: MCP discovery is a suspension
                // window — settings may have changed while it ran.
                // The runtime is therefore built from the
                // POST-discovery snapshot captured HERE, once, and
                // the stored signature below is that same
                // snapshot's signature — never the pre-discovery
                // snapshot above, and never a second provider call
                // that could observe yet another settings state.
                // (If every grant vanished during discovery, the
                // runtime is built empty and the backend treats it
                // as no tools; the signature still matches it, so
                // the next send rebuilds cleanly instead of
                // reusing a stale grant.)
                let postDiscoveryAvailability = toolAvailabilityProvider()
                let runtime = ToolRuntime(
                    configuration: ToolRuntime.Configuration.fromPostDiscovery(
                        availability: postDiscoveryAvailability,
                        conversationID: conversationID,
                        mcpTools: mcpTools,
                        // Phase 8: a tool host in the cloud (today
                        // that means PCC) gets its results scrubbed
                        // by the runtime's choke point; a local host
                        // keeps them raw. Tool-capable + remote is
                        // exactly that one case.
                        redactResults: isRemoteDestination,
                        proposalSink: proposalSink()),
                    // Audit B-43: the sink carries THIS send's
                    // container, so its events are written through
                    // this send's context — never a shared static
                    // another send may have overwritten.
                    sink: Self.toolEventSink(container: context.container),
                    permissionProvider: { source in
                        PermissionStatusReader.currentState(for: source)
                    })
                sessionTools = SessionTools(
                    runtime: runtime, descriptors: await runtime.descriptors)
                // The signature of the tool set ACTUALLY built: the
                // post-discovery snapshot's, captured above — the
                // same snapshot the runtime was built from. (When
                // no tool set is built at all, the signature stays
                // the pre-discovery value, which is exact there
                // because no discovery suspension happened on that
                // path.)
                toolsSignature = postDiscoveryAvailability.signature
            } else {
                sessionTools = nil
            }
            session = backend.makeSession(instructions: effectiveInstructions,
                                          tools: sessionTools)
            // The fresh session knows nothing yet: prepend the stored
            // context (summary + live turns) to this prompt. For a
            // brand-new chat the seed is empty and the prompt stands
            // alone.
            let seed = ContextManager.seedText(
                existingSummary: conversation.contextSummary,
                recentTurns: liveTurns)
            if !seed.isEmpty {
                promptText = seed + "\n\n" + lastMessage.text
            }
            liveSessions[conversationID] = LiveSession(
                session: session, selection: selection,
                instructions: effectiveInstructions, summaryKey: summaryKey,
                seeded: true, kvCacheMode: routingInputs.kvCacheMode,
                toolsSignature: toolsSignature,
                configDigest: resolved.configDigest)
        }

        // Audit B-51: session building suspended (MCP discovery can
        // take seconds) — if the conversation was deleted meanwhile,
        // stop here, before anything is sent or saved.
        if isForgotten() {
            finish(conversationID: conversationID)
            return
        }

        // Review finding 7: recheck cancellation AND the Local Only
        // lock after that same suspension window, before anything
        // is dispatched. A send stopped mid-preparation must not
        // proceed, and a lock flipped on during discovery must not
        // let a resolved server/cloud send leave the Mac — the
        // backend was resolved before the flip, so only this fresh
        // check catches it. (A lock flipped OFF mid-preparation is
        // harmless here: the send proceeds against the already
        // resolved local fallback, never against a destination it
        // wasn't cleared for.)
        if Task.isCancelled {
            finish(conversationID: conversationID)
            return
        }
        if routingContextProvider().localOnly {
            let leavesMac: Bool = {
                switch selection {
                case .endpoint, .privateCloudCompute, .openRouter:
                    return true
                case .auto, .onDevice, .mlx:
                    return false
                }
            }()
            if leavesMac {
                errorMessages[conversationID] =
                    "Local Only is on, so this chat can't use a "
                    + "server or cloud model right now — it switched "
                    + "to a model that runs entirely on this Mac."
                finish(conversationID: conversationID)
                return
            }
        }

        // Phase 6: if the user decided a proposed file-change list
        // since the last message (approved, discarded, or undone),
        // the outcome rides at the head of this prompt. It is part of
        // the sent copy only — never a stored message — and it goes
        // through the same firewall scrub as everything else below.
        //
        // Audit B-44: the note (and the Phase 7 prefix below) is
        // PEEKED here, not consumed. It is the only channel telling
        // the model what was approved/discarded/undone; consuming it
        // before the stream meant a failed or stopped send lost it
        // forever, and the model then re-proposed executed changes
        // or reported approved work as pending. Both are removed
        // only after a reply completes successfully (see the stream
        // handling below); on error or stop they stay queued and
        // ride the next send instead.
        if let outcomeNote = pendingOutcomeNotes[conversationID] {
            promptText = outcomeNote + "\n\n" + promptText
        }

        // Phase 7: the quick panel's captured context, supplied with
        // the send, rides at the head of the prompt the same way —
        // sent copy only, and the firewall scrub below covers it too.
        if let promptPrefix = pendingPromptPrefixes[conversationID] {
            promptText = promptPrefix + "\n\n" + promptText
        }

        // The firewall's second half: with the outgoing prompt fully
        // assembled (seeded history included), scrub it too, and say
        // so — once per send, counting the instructions with it.
        // Audit S-09: the notice is set for EVERY remote send, not
        // only when something was hidden — a send that matched no
        // pattern still left this Mac, and the user is told it did.
        if isRemoteDestination {
            let scrubbed = Redactor.redact(
                promptText,
                customTerms: routingInputs.customRedactionTerms)
            promptText = scrubbed.text
            redactions += scrubbed.replacementCount
            // Review finding 13: APPEND, don't overwrite — the
            // post-compaction overflow note (set above) must survive
            // a remote send's privacy notice, exactly as the image
            // notice below appends to it.
            infoMessages[conversationID] =
                [infoMessages[conversationID],
                 RemoteDestination.noticeText(
                    redactions: redactions,
                    backendDisplayName: backend.displayName,
                    selection: selection)]
                    .compactMap { $0 }
                    .joined(separator: " ")
        }

        // Streaming. Images ride along as temporary files (framework
        // backends read them; local servers get the text only), and the
        // files must outlive the stream, so they are deleted only after
        // it finishes.
        let imageFiles = writeTemporaryImages(lastMessage.attachments)
        defer {
            if let dir = imageFiles.directory {
                try? FileManager.default.removeItem(at: dir)
            }
        }

        // Audit S-03: images never go to a remote destination. The
        // firewall scrubs text; it cannot scrub a screenshot, which
        // is exactly where secrets hide. The images are stripped
        // from this send (the saved message keeps them) and the
        // user is told, appended to the privacy notice above.
        let stripImages = RemoteDestination.shouldStripImages(
            isRemote: isRemoteDestination,
            imageCount: imageFiles.urls.count)
        if stripImages {
            let imageNotice = RemoteDestination.imageStripNoticeText(
                backendDisplayName: backend.displayName,
                selection: selection)
            infoMessages[conversationID] =
                [infoMessages[conversationID], imageNotice]
                    .compactMap { $0 }
                    .joined(separator: " ")
        }

        var received = ""
        // Audit B-44: did the reply complete? The peeked outcome
        // note / prompt prefix are consumed only when it did.
        var replyCompleted = false
        let generationStarted = Date()
        do {
            let request = ChatReplyRequest(
                promptText: promptText,
                imageURLs: stripImages ? [] : imageFiles.urls,
                // Review finding 6: the CURRENT terms and the
                // remote flag, per send — HTTP sessions scrub
                // their complete payload (including cached
                // history) with these at transport time. The terms
                // are re-read here, at dispatch, not taken from the
                // start-of-send snapshot: a term added during the
                // discovery window must still scrub this send.
                redactionTerms: routingContextProvider().customRedactionTerms,
                scrubOutgoingPayload: isRemoteDestination)
            for try await text in session.streamReply(to: request) {
                received = text
                streamingText[conversationID] = received
            }
            replyCompleted = true
        } catch is CancellationError {
            // Stopped by the user — whatever arrived is kept below.
        } catch {
            errorMessages[conversationID] =
                "The model couldn't finish that reply: \(error.localizedDescription)"
        }
        let generationSeconds = Date().timeIntervalSince(generationStarted)

        // Audit B-44: consume the peeked note/prefix now that the
        // reply completed — on error or stop they were never
        // removed, so they stay queued ("re-queued") for the next
        // send and the model still learns the decision.
        if replyCompleted {
            pendingOutcomeNotes[conversationID] = nil
            pendingPromptPrefixes[conversationID] = nil
        }

        // Audit B-51: the conversation was deleted while the reply
        // streamed — drop the save silently. Inserting here would
        // attach a message to a deleted `Conversation` and
        // resurrect an orphan.
        if isForgotten() {
            finish(conversationID: conversationID)
            return
        }

        let finalText = received.trimmingCharacters(in: .whitespacesAndNewlines)
        if !finalText.isEmpty {
            let reply = Message(role: .assistant, text: finalText,
                                conversation: conversation)
            // Phase 4 telemetry: which backend actually answered, how
            // long it took, roughly how big the reply is. Rendered as
            // the pill under the message. Phase 8: a session that can
            // report usage (OpenRouter's) contributes the reply's real
            // cost; a paid route with no report reads "cost unknown"
            // rather than $0.00. Local backends and PCC are free and
            // stay $0.00.
            var costUSD = 0.0
            var costKnown = true
            if case .openRouter = selection {
                if let report = (session as? UsageReportingChatSession)?
                    .lastUsageReport,
                   let reportedCost = report.costUSD {
                    costUSD = reportedCost
                } else {
                    costKnown = false
                }
            }
            reply.telemetry = MessageTelemetry(
                backendLabel: TelemetryFormat.label(
                    for: selection, displayName: backend.displayName),
                seconds: generationSeconds,
                estimatedTokens: PromptHistory.approximateTokenCount(
                    for: finalText),
                costUSD: costUSD,
                costKnown: costKnown)
            context.insert(reply)
            conversation.updatedAt = Date()
            try? context.save()
        }
        finish(conversationID: conversationID)
    }

    // MARK: - Compaction helpers

    /// The prefix of `turns` that fits the summarizer's own window.
    /// The summarizer runs on the on-device model (4,096 tokens) even
    /// for chats on bigger backends, so a pass planned against a large
    /// budget is folded in a few chunks. Always at least one turn, so
    /// compaction always makes progress.
    private func summarizerChunk(_ turns: [ChatTurn],
                                 existingSummary: String?) -> [ChatTurn] {
        let summarizerBudget = ContextBudget.onDevice
        let summaryTokens = existingSummary.map {
            PromptHistory.approximateTokenCount(for: $0)
        } ?? 0
        let allowance = summarizerBudget.promptAllowanceTokens
            - summaryTokens - ContextManager.summarizerOverheadTokens
        var used = 0
        var kept = 0
        for turn in turns {
            let cost = ContextManager.tokens(for: turn)
            if kept > 0, used + cost > allowance { break }
            used += cost
            kept += 1
        }
        return Array(turns.prefix(max(1, kept)))
    }

    /// One summarization pass with a throwaway on-device session. On
    /// any failure, falls back to the mechanical summary so compaction
    /// — and the send that triggered it — still succeeds.
    private func summarize(existingSummary: String?,
                           turns: [ChatTurn],
                           targetTokens: Int) async -> String {
        let input = ContextManager.summarizerInput(
            existingSummary: existingSummary,
            turns: turns,
            targetTokens: targetTokens)
        let session = LanguageModelSession(
            instructions: ContextManager.summarizerInstructions)
        do {
            let response = try await session.respond(to: input)
            let text = response.content
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // Review finding 13: enforce an ACHIEVABLE summary
            // output limit — the "at most about N words" instruction
            // alone is a request, not a guarantee, and an over-long
            // summary eats the next pass's allowance.
            if !text.isEmpty {
                return ContextManager.cappedSummary(text, maxTokens: targetTokens)
            }
        } catch {
            // Fall through to the mechanical summary.
        }
        return ContextManager.mechanicalFallbackSummary(
            existing: existingSummary, droppedTurns: turns,
            maxTokens: targetTokens)
    }

    private func retireSession(_ conversationID: UUID) {
        liveSessions[conversationID] = nil
    }

    private func finish(conversationID: UUID) {
        streamingText[conversationID] = nil
        respondingIDs.remove(conversationID)
        tasks[conversationID] = nil
    }

    // MARK: - Image attachments

    /// Writes a message's stored images to a private temporary folder
    /// so they can be handed to the model as file URLs. Images that
    /// fail to write are skipped; if none can be written, the send
    /// falls back to a text-only prompt.
    private func writeTemporaryImages(
        _ attachments: [ImageAttachment]
    ) -> (urls: [URL], directory: URL?) {
        guard !attachments.isEmpty else { return ([], nil) }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalLLM-\(UUID().uuidString)",
                                    isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
        } catch {
            return ([], nil)
        }
        var urls: [URL] = []
        for (index, attachment) in attachments.enumerated() {
            let url = directory.appendingPathComponent("image-\(index).jpg")
            if (try? attachment.data.write(to: url, options: .atomic)) != nil {
                urls.append(url)
            }
        }
        return (urls, directory)
    }
}
