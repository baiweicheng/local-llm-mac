import Foundation
import AppKit

/// Phase 9: the MCP client — the app's half of the Model Context
/// Protocol for the user's own local servers.
///
/// Two layers, deliberately split the way the rest of the app
/// splits pure from plumbing:
///
///  - `Core/MCPProtocol.swift` is the wire format: JSON-RPC 2.0,
///    one object per line over the server's stdin/stdout
///    (stdio transport — the only transport this phase supports).
///  - This file is the plumbing: `MCPServerConnection` owns one
///    server process and correlates responses to requests;
///    `MCPServerManager` owns the set — launching servers lazily
///    when a chat first needs their tools, caching what they offer,
///    and shutting them down when they're disabled, removed, or
///    the app quits.
///
/// Servers never launch just because they exist in Settings: only
/// when a tool-capable session is being built (power tools on), and
/// a server that fails to start is remembered as failed — its tools
/// simply don't appear — until the user edits it, re-enables it, or
/// taps "Try again" in Settings. No failure here ever crashes or
/// blocks a chat: worst case, the tools are absent and Settings
/// shows why.

// MARK: - Errors (written for the user, not a log)

enum MCPClientError: LocalizedError {
    case executableNotFound(command: String)
    case launchFailed(String)
    case timeout(what: String)
    case serverError(message: String)
    case serverStopped
    case notConfigured
    case disabled

    var errorDescription: String? {
        switch self {
        case .executableNotFound(let command):
            return "Couldn't find the program “\(command)” — check the launch command in Settings → Power tools."
        case .launchFailed(let detail):
            return "The server didn't start: \(detail)"
        case .timeout(let what):
            return "The server took too long to answer (\(what)), so the call was given up on."
        case .serverError(let message):
            return "The server answered with an error: \(message)"
        case .serverStopped:
            return "The server stopped running."
        case .notConfigured:
            return "That MCP server isn't in Settings anymore."
        case .disabled:
            return "That MCP server is turned off in Settings → Power tools."
        }
    }
}

// MARK: - One server process

/// A launched MCP server: its process, the request/response
/// correlation over its pipes, and its discovered tools.
///
/// Threading: pipe callbacks arrive off the main actor, responses
/// are matched under a lock, and continuations resume wherever they
/// land (their awaiters hop as needed). All mutable state sits
/// behind `lock`; the class is `@unchecked Sendable` on that basis.
final class MCPServerConnection: @unchecked Sendable {

    let config: MCPServerConfig
    let slug: String

    private let process: Process
    private let stdinHandle: FileHandle
    private let lock = NSLock()
    private var parser = MCPStreamParser()
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    /// Audit E-91: each pending request's timeout task, so it can
    /// be CANCELLED when the response lands — previously every
    /// request left a task sleeping for its full 15–30 s timeout
    /// and then expiring an already-answered id (harmless, but
    /// pure waste, and the tasks piled up under load).
    private var timeoutTasks: [Int: Task<Void, Never>] = [:]
    private var stderrTail = ""
    private var isDead = false
    private(set) var remoteTools: [MCPRemoteTool] = []

    /// Set by the manager: the process exited on its own.
    var onUnexpectedExit: (@Sendable () -> Void)?

    private init(config: MCPServerConfig, slug: String,
                 process: Process, stdinHandle: FileHandle) {
        self.config = config
        self.slug = slug
        self.process = process
        self.stdinHandle = stdinHandle
    }

    var isRunning: Bool { process.isRunning && !isDead }

    // MARK: Launch

    /// Resolves the launch command and starts the process. Throws
    /// `MCPClientError` with a user-facing message on any failure.
    static func launch(config: MCPServerConfig,
                       slug: String) throws -> MCPServerConnection {
        let home = NSHomeDirectory()
        guard let executable = MCPExecutableResolver.resolve(
            command: config.command, home: home,
            exists: { FileManager.default.isExecutableFile(atPath: $0) })
        else {
            throw MCPClientError.executableNotFound(command: config.command)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = config.arguments
        process.currentDirectoryURL = URL(fileURLWithPath: home)
        process.environment = ShellCommandPolicy.plainEnvironment(home: home)

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let connection = MCPServerConnection(
            config: config, slug: slug, process: process,
            stdinHandle: stdinPipe.fileHandleForWriting)

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak connection] handle in
            let data = handle.availableData
            guard let connection else {
                handle.readabilityHandler = nil
                return
            }
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            connection.receive(data)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak connection] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            connection?.appendStderr(String(decoding: data, as: UTF8.self))
        }
        process.terminationHandler = { [weak connection] _ in
            connection?.handleExit()
        }
        do {
            try process.run()
        } catch {
            throw MCPClientError.launchFailed(error.localizedDescription)
        }
        return connection
    }

    // MARK: Handshake + calls

    /// The initialize handshake, then the tool list. Called once,
    /// right after launch, by the manager.
    func start() async throws -> [MCPRemoteTool] {
        let result = try await sendRequest(
            method: "initialize", params: MCPJSONRPC.initializeParams(),
            timeoutSeconds: 15, timeoutWhat: "starting up")
        _ = result
        sendNotification(method: "notifications/initialized")
        let listResult = try await sendRequest(
            method: "tools/list", params: nil,
            timeoutSeconds: 15, timeoutWhat: "listing its tools")
        let tools = MCPResultDecoding.tools(from: listResult)
        setRemoteTools(tools)
        return tools
    }

    /// Synchronous lock holder for `start()`: the assignment above
    /// runs in an `async` body, where direct `NSLock.lock()` /
    /// `unlock()` calls are unavailable in Swift 6, so the locked
    /// mutation lives in this non-async helper instead. (The other
    /// lock uses in this file are already in synchronous functions
    /// or synchronous continuation closures, so they are untouched.)
    private func setRemoteTools(_ tools: [MCPRemoteTool]) {
        lock.lock()
        remoteTools = tools
        lock.unlock()
    }

    /// One approved tools/call. The 30-second limit matches the
    /// shell tool's: a stuck server fails the plan item, it doesn't
    /// hang the plan.
    func callTool(name: String, argumentsJSON: String) async throws
        -> (text: String, isError: Bool) {
        let params: JSONValue = .object([
            "name": .string(name),
            "arguments": MCPArguments.object(fromCanonical: argumentsJSON),
        ])
        let result = try await sendRequest(
            method: "tools/call", params: params,
            timeoutSeconds: 30, timeoutWhat: "running “\(name)”")
        return MCPResultDecoding.callText(from: result)
    }

    // MARK: Shutdown

    /// Stops the process and fails anything still waiting on it.
    ///
    /// Audit B-48: this mirrors the shell runner's escalation —
    /// close stdin (a well-behaved stdio server exits on that
    /// alone), SIGTERM, then SIGKILL after a ~1-second grace if the
    /// process is still running. The old code sent one SIGTERM and
    /// ran the bookkeeping immediately: a server that ignores
    /// SIGTERM survived as an orphan while Settings reported it
    /// stopped. The bookkeeping (`handleExit`) still runs right
    /// away — pending requests fail promptly — and it stays
    /// idempotent for the real exit that follows (the termination
    /// handler calls it again and the `isDead` guard no-ops).
    func terminate() {
        lock.lock()
        let wasDead = isDead
        lock.unlock()
        guard !wasDead else { return }
        try? stdinHandle.close()
        if process.isRunning {
            process.terminate()
            let process = self.process
            DispatchQueue.global(qos: .utility).asyncAfter(
                deadline: .now() + 1.0) {
                    if process.isRunning {
                        kill(process.processIdentifier, SIGKILL)
                    }
                }
        }
        handleExit()
    }

    // MARK: Wire plumbing

    private func sendRequest(method: String, params: JSONValue?,
                             timeoutSeconds: Double,
                             timeoutWhat: String) async throws -> JSONValue {
        let id: Int = {
            lock.lock()
            defer { lock.unlock() }
            let id = nextID
            nextID += 1
            return id
        }()
        let line = MCPJSONRPC.encodeRequest(id: id, method: method,
                                            params: params) + "\n"
        let result: JSONValue = try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if isDead {
                lock.unlock()
                continuation.resume(throwing: MCPClientError.serverStopped)
                return
            }
            pending[id] = continuation
            // The timeout races the response: whichever resumes the
            // continuation first wins, and the loser finds the entry
            // already gone. Audit E-91: the task is STORED so the
            // winner can cancel it — every completion path below
            // (response, expiry, exit) removes and cancels it.
            timeoutTasks[id] = Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeoutSeconds))
                self?.expireRequest(id: id,
                                    error: MCPClientError.timeout(what: timeoutWhat))
            }
            lock.unlock()
            if !writeToStdin(Data(line.utf8)) {
                expireRequest(id: id, error: MCPClientError.serverStopped)
            }
        }
        return result
    }

    private func sendNotification(method: String) {
        let line = MCPJSONRPC.encodeNotification(method: method) + "\n"
        _ = writeToStdin(Data(line.utf8))
    }

    /// Audit B-55: EVERY write to the server's stdin goes through
    /// here, serialized under the class lock. Writes used to happen
    /// from three threads at once — `sendRequest`'s continuation
    /// executor, `sendNotification`'s caller, and the pipe-callback
    /// context answering server requests in `receive` — and two
    /// concurrent writes could interleave, corrupting both JSON
    /// lines (the symptom was a spurious 30-second timeout). The
    /// lock is never held across this call by any caller, so taking
    /// it here cannot deadlock.
    private func writeToStdin(_ data: Data) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        do {
            try stdinHandle.write(contentsOf: data)
            return true
        } catch {
            return false
        }
    }

    private func expireRequest(id: Int, error: Error) {
        lock.lock()
        let continuation = pending.removeValue(forKey: id)
        let timeoutTask = timeoutTasks.removeValue(forKey: id)
        lock.unlock()
        timeoutTask?.cancel()
        continuation?.resume(throwing: error)
    }

    private func receive(_ data: Data) {
        lock.lock()
        let messages = parser.feed(data)
        lock.unlock()
        for message in messages {
            switch message {
            case .response(let id, let result, let error):
                lock.lock()
                let continuation = pending.removeValue(forKey: id)
                // Audit E-91: the response won the race — cancel
                // the timeout task instead of letting it sleep out
                // its full timeout.
                let timeoutTask = timeoutTasks.removeValue(forKey: id)
                lock.unlock()
                timeoutTask?.cancel()
                if let error {
                    continuation?.resume(
                        throwing: MCPClientError.serverError(message: error))
                } else if let continuation {
                    continuation.resume(returning: result ?? .null)
                }
            case .serverRequest(let id, _):
                // The app answers no server-initiated requests this
                // phase; reply method-not-found so a well-behaved
                // server isn't left waiting on one.
                let reply = JSONValue.object([
                    "jsonrpc": .string("2.0"),
                    "id": .number(Double(id)),
                    "error": .object([
                        "code": .number(-32601),
                        "message": .string("This app doesn't answer server requests."),
                    ]),
                ]).canonicalText() + "\n"
                _ = writeToStdin(Data(reply.utf8))
            case .notification, .malformed:
                // Log/progress notes and stray prints are noted and
                // ignored — never fatal.
                break
            }
        }
    }

    private func appendStderr(_ text: String) {
        lock.lock()
        stderrTail += text
        if stderrTail.count > 2_000 {
            stderrTail = String(stderrTail.suffix(2_000))
        }
        lock.unlock()
    }

    /// The last of what the server printed to stderr — diagnostic
    /// detail for a failure message.
    var stderrSummary: String {
        lock.lock()
        defer { lock.unlock() }
        let trimmed = stderrTail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return String(trimmed.suffix(300))
    }

    private func handleExit() {
        lock.lock()
        if isDead {
            lock.unlock()
            return
        }
        isDead = true
        // A final unterminated line still counts.
        let leftovers = parser.finish()
        let waiting = pending
        pending = [:]
        // Audit E-91: every pending request is being answered (or
        // failed) right here — none of their timeout tasks should
        // outlive the connection.
        let timeouts = timeoutTasks
        timeoutTasks = [:]
        lock.unlock()
        for (_, task) in timeouts { task.cancel() }
        for message in leftovers {
            if case .response(let id, let result, let error) = message {
                if let continuation = waiting[id] {
                    if let error {
                        continuation.resume(
                            throwing: MCPClientError.serverError(message: error))
                    } else {
                        continuation.resume(returning: result ?? .null)
                    }
                }
            }
        }
        let answered = Set(leftovers.compactMap { message -> Int? in
            if case .response(let id, _, _) = message { return id }
            return nil
        })
        for (id, continuation) in waiting where !answered.contains(id) {
            continuation.resume(throwing: MCPClientError.serverStopped)
        }
        onUnexpectedExit?()
    }
}

// MARK: - The manager

/// Owns the running set: which servers are up, what they offer, and
/// what state Settings shows. Main-actor and observable — Settings
/// reads `statuses` directly; the engine reaches it through two
/// provider closures ContentView wires (tools for session building,
/// and the plan executor).
@MainActor
@Observable
final class MCPServerManager {

    private(set) var statuses: [UUID: MCPServerStatus] = [:]
    private var connections: [UUID: MCPServerConnection] = [:]
    /// What the last discovery found — feeds `toolSignature`, which
    /// retires sessions when the tool set changes.
    private(set) var discoveredTools: [MCPToolInfo] = []
    /// Configs as launched, per server — an edit (command, args,
    /// name) restarts that server rather than serving stale tools.
    private var launchedConfigs: [UUID: MCPServerConfig] = [:]
    /// The config as it stood when a server last failed to start —
    /// kept separately from `launchedConfigs` (which a failed launch
    /// clears) so reconciliation can tell "same broken config, don't
    /// retry" from "the user edited it — the new form deserves a try."
    private var failedConfigs: [UUID: MCPServerConfig] = [:]
    /// Audit B-40: one in-flight launch per server, joined by every
    /// concurrent caller. `availableTools()` suspends for the whole
    /// handshake, and two conversations sending at once used to
    /// interleave here — a second launch could overwrite
    /// `connections[config.id]`, and the exit-wiring identity guard
    /// then kept the overwritten process from EVER being cleaned
    /// up (orphaned for the app's life). Now only the launch task
    /// itself mutates `connections`/`statuses`/`launchedConfigs`/
    /// `failedConfigs` for its config; concurrent callers await the
    /// same task and read its result. The token identifies the
    /// entry so the task clears only its OWN slot on completion.
    private var launchTasks: [UUID: Task<[MCPToolInfo], Never>] = [:]
    private var launchTokens: [UUID: UUID] = [:]

    /// The saved servers, read fresh at each reconciliation —
    /// wired by ContentView to the store it owns.
    private var configProvider: () -> [MCPServerConfig] = { [] }

    init() {
        // Servers are children of this app: when it quits, they go
        // too. (A crashed app can still orphan one — true of every
        // stdio MCP host; the servers are the user's own programs
        // and exit on their stdin closing at process teardown.)
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.terminateAll()
                }
            }
    }

    func configure(configProvider: @escaping () -> [MCPServerConfig]) {
        self.configProvider = configProvider
    }

    // MARK: Discovery (session building)

    /// The signature of the currently discovered tool set, for the
    /// engine's session-reuse check: server slug + tool names.
    var toolSignature: String {
        discoveredTools
            .map { "\($0.serverSlug):\($0.toolName)" }
            .sorted()
            .joined(separator: ";")
    }

    /// Every tool of every enabled, running server — launching the
    /// ones that haven't started yet. A server that fails keeps its
    /// failed status and contributes nothing; it is NOT retried
    /// here (a chat send must never hang on a broken server twice),
    /// until `resetServer` or a config edit clears it.
    func availableTools() async -> [MCPToolInfo] {
        reconcile()
        let configs = configProvider().filter { $0.isEnabled }
        let slugs = MCPToolNaming.uniqueSlugs(for: configProvider())
        var tools: [MCPToolInfo] = []
        for config in configs {
            if let connection = connections[config.id],
               connection.isRunning {
                tools += toolInfos(for: config,
                                   slug: slugs[config.id] ?? config.slug,
                                   remote: connection.remoteTools)
                continue
            }
            if statuses[config.id]?.isFailed == true { continue }
            // Audit B-40: join the in-flight launch if there is
            // one; otherwise become it. Either way this caller only
            // READS the outcome — the launch task is the sole writer
            // of the per-server state (see `performLaunch`).
            if let inFlight = launchTasks[config.id] {
                tools += await inFlight.value
                continue
            }
            let slug = slugs[config.id] ?? config.slug
            let token = UUID()
            let task = Task { [weak self] () -> [MCPToolInfo] in
                guard let self else { return [] }
                let found = await self.performLaunch(config: config,
                                                     slug: slug)
                // Clear only our own slot: a newer launch for this
                // server (after a reset/edit) owns a different token.
                if self.launchTokens[config.id] == token {
                    self.launchTasks[config.id] = nil
                    self.launchTokens[config.id] = nil
                }
                return found
            }
            launchTasks[config.id] = task
            launchTokens[config.id] = token
            tools += await task.value
        }
        discoveredTools = tools
        return tools
    }

    /// Audit B-40: the ONE launch path for a server — process
    /// start, handshake, and every state write for that config
    /// happen here, inside the in-flight task `availableTools`
    /// stores and concurrent callers join. Never throws: a failed
    /// launch contributes no tools and latches its failed status,
    /// exactly as before.
    private func performLaunch(config: MCPServerConfig,
                               slug: String) async -> [MCPToolInfo] {
        statuses[config.id] = .starting
        do {
            let connection = try MCPServerConnection.launch(
                config: config, slug: slug)
            connections[config.id] = connection
            launchedConfigs[config.id] = config
            failedConfigs[config.id] = nil
            wireExit(connection)
            let remote = try await connection.start()
            // A stop/reset landed while the handshake was in
            // flight: don't resurrect a server the user just
            // stopped — shut the fresh process back down.
            if Task.isCancelled {
                connection.terminate()
                if connections[config.id] === connection {
                    connections[config.id] = nil
                    launchedConfigs[config.id] = nil
                }
                if statuses[config.id]?.isFailed != true {
                    statuses[config.id] = .notStarted
                }
                return []
            }
            statuses[config.id] = .ready(toolCount: remote.count)
            return toolInfos(for: config, slug: connection.slug,
                             remote: remote)
        } catch {
            let stderr = connections[config.id]?.stderrSummary ?? ""
            connections[config.id]?.terminate()
            connections[config.id] = nil
            launchedConfigs[config.id] = nil
            failedConfigs[config.id] = config
            let detail = (error as? MCPClientError)?.errorDescription
                ?? error.localizedDescription
            statuses[config.id] = .failed(
                message: stderr.isEmpty ? detail : detail + " " + stderr)
            return []
        }
    }

    // MARK: Execution (approved plan items)

    enum CallOutcome: Sendable {
        case success(text: String, isError: Bool)
        case failure(message: String)
    }

    /// Runs one approved call, checking the live world first: the
    /// server must still exist, still be enabled, and be running
    /// (or launchable). Whatever goes wrong comes back as a
    /// plain-English failure for that plan item — never a throw.
    func callTool(serverID: UUID, toolName: String,
                  argumentsJSON: String) async -> CallOutcome {
        guard let config = configProvider().first(where: { $0.id == serverID })
        else { return .failure(message: MCPClientError.notConfigured.errorDescription ?? "") }
        guard config.isEnabled else {
            return .failure(message: MCPClientError.disabled.errorDescription ?? "")
        }
        if connections[serverID]?.isRunning != true {
            // It stopped (or never started) since the proposal —
            // try once to bring it up, through the same path a
            // session build would take.
            _ = await availableTools()
        }
        guard let connection = connections[serverID], connection.isRunning
        else {
            if let status = statuses[serverID], case .failed(let message) = status {
                return .failure(message: "The “\(config.name)” server isn't running: \(message)")
            }
            return .failure(message: "The “\(config.name)” server isn't running.")
        }
        do {
            let result = try await connection.callTool(
                name: toolName, argumentsJSON: argumentsJSON)
            return .success(text: result.text, isError: result.isError)
        } catch {
            return .failure(
                message: (error as? MCPClientError)?.errorDescription
                    ?? error.localizedDescription)
        }
    }

    /// The engine's executor for one approved `.mcpCall` plan item:
    /// maps the call outcome onto the plan record's shape — a
    /// server-reported error is a FAILED item (the call ran and the
    /// server said no), with the server's own text kept as the
    /// item's detail so the model can explain it.
    func executeApprovedCall(_ action: PlannedAction) async -> ExecutedActionItem {
        guard let serverID = action.mcpServerID,
              let toolName = action.mcpToolName,
              let argumentsJSON = action.mcpArgumentsJSON else {
            let note = "The call was missing its server, tool, or arguments."
            return ExecutedActionItem(action: action,
                                      outcome: .failed(note),
                                      resultNote: note)
        }
        switch await callTool(serverID: serverID, toolName: toolName,
                              argumentsJSON: argumentsJSON) {
        case .success(let text, let isError):
            // Audit S-04: cap the server's text exactly like shell
            // output (`ShellOutput.forModel`) before it is persisted
            // in the plan record and quoted to the model — this was
            // the one output path with no size limit at all.
            let capped = ShellOutput.forModel(text)
            if isError {
                return ExecutedActionItem(
                    action: action, outcome: .failed(capped),
                    resultNote: "The server reported an error.",
                    modelDetail: capped)
            }
            return ExecutedActionItem(
                action: action, outcome: .done,
                resultNote: "\(action.mcpServerName ?? "The server") answered.",
                modelDetail: capped.isEmpty ? nil : capped)
        case .failure(let message):
            return ExecutedActionItem(action: action,
                                      outcome: .failed(message),
                                      resultNote: message)
        }
    }

    // MARK: Lifecycle from Settings

    /// "Try again" for a failed server: forget the failure (and any
    /// corpse) so the next session build or call retries the launch.
    func resetServer(id: UUID) {
        // Audit B-40: an in-flight launch for this server is
        // cancelled too — `performLaunch` checks for it after the
        // handshake and shuts the fresh process back down.
        launchTasks[id]?.cancel()
        launchTasks[id] = nil
        launchTokens[id] = nil
        connections[id]?.terminate()
        connections[id] = nil
        launchedConfigs[id] = nil
        failedConfigs[id] = nil
        statuses[id] = .notStarted
        discoveredTools.removeAll { $0.serverID == id }
    }

    /// Stops one server now (Settings' switch-off path reaches here
    /// via reconcile, but an explicit stop is immediate).
    func stopServer(id: UUID) {
        launchTasks[id]?.cancel()
        launchTasks[id] = nil
        launchTokens[id] = nil
        connections[id]?.terminate()
        connections[id] = nil
        launchedConfigs[id] = nil
        failedConfigs[id] = nil
        statuses[id] = .notStarted
        discoveredTools.removeAll { $0.serverID == id }
    }

    /// Review finding 8: how many times `terminateAll()` has run.
    /// The test seam for the Local Only / power-switch shutdown:
    /// unit tests can't spawn real server processes, but they can
    /// prove the toggle path reaches termination (and that it does
    /// NOT fire while power tools are actually available).
    private(set) var terminateAllCallCount = 0

    /// Review finding 8: the central shutdown rule for the privacy
    /// lock and the power-tools master switch. Callers (the app
    /// shell's settings observers) pass the CURRENT values of both
    /// switches; running servers are terminated whenever power
    /// tools are not actually available — the lock on, or the
    /// master switch off — because a launch gate alone leaves
    /// already-running servers alive to continue their own network
    /// activity. A no-op while both allow power tools, so toggling
    /// an unrelated setting never restarts a healthy server set.
    func stopServersWhenPowerUnavailable(localOnly: Bool,
                                         powerToolsEnabled: Bool) {
        guard localOnly || !powerToolsEnabled else { return }
        terminateAll()
    }

    func terminateAll() {
        terminateAllCallCount += 1
        for (_, task) in launchTasks {
            task.cancel()
        }
        launchTasks = [:]
        launchTokens = [:]
        for (_, connection) in connections {
            connection.terminate()
        }
        connections = [:]
        launchedConfigs = [:]
        failedConfigs = [:]
        statuses = [:]
        discoveredTools = []
    }

    func status(for id: UUID) -> MCPServerStatus {
        statuses[id] ?? .notStarted
    }

    // MARK: Reconciliation

    /// Brings the running set in line with the saved list: servers
    /// that were removed, disabled, or edited (command/arguments/
    /// name changed) are stopped; a stopped or edited server's
    /// failure record is cleared so its new form can start fresh.
    private func reconcile() {
        let configs = configProvider()
        let byID = Dictionary(uniqueKeysWithValues: configs.map { ($0.id, $0) })
        for (id, connection) in connections {
            guard let current = byID[id], current.isEnabled else {
                connection.terminate()
                connections[id] = nil
                launchedConfigs[id] = nil
                failedConfigs[id] = nil
                statuses[id] = .notStarted
                continue
            }
            if launchedConfigs[id] != current {
                connection.terminate()
                connections[id] = nil
                launchedConfigs[id] = nil
                failedConfigs[id] = nil
                statuses[id] = .notStarted
            }
        }
        // A config edit also clears a recorded failure for a server
        // that isn't currently running: its new form deserves a try.
        // (The failed config is remembered in `failedConfigs` —
        // `launchedConfigs` is already nil for a server that never
        // got as far as launching.)
        for config in configs where connections[config.id] == nil {
            if statuses[config.id]?.isFailed == true,
               failedConfigs[config.id] != nil,
               failedConfigs[config.id] != config {
                statuses[config.id] = .notStarted
                failedConfigs[config.id] = nil
            }
            if !config.isEnabled, statuses[config.id] != nil {
                statuses[config.id] = .notStarted
                failedConfigs[config.id] = nil
            }
        }
        if discoveredTools.contains(where: { connections[$0.serverID] == nil }) {
            discoveredTools.removeAll { connections[$0.serverID] == nil }
        }
    }

    private func wireExit(_ connection: MCPServerConnection) {
        let serverID = connection.config.id
        connection.onUnexpectedExit = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self,
                      self.connections[serverID] === connection,
                      !connection.isRunning else { return }
                self.connections[serverID] = nil
                self.launchedConfigs[serverID] = nil
                if self.configProvider().contains(where: { $0.id == serverID }),
                   self.statuses[serverID]?.isFailed != true {
                    self.failedConfigs[serverID] = connection.config
                    self.statuses[serverID] = .failed(
                        message: "The server quit unexpectedly.")
                }
                self.discoveredTools.removeAll { $0.serverID == serverID }
            }
        }
    }

    private func toolInfos(for config: MCPServerConfig, slug: String,
                           remote: [MCPRemoteTool]) -> [MCPToolInfo] {
        remote.map {
            MCPToolInfo(serverID: config.id, serverName: config.name,
                        serverSlug: slug, toolName: $0.name,
                        toolDescription: $0.description,
                        inputSchemaJSON: $0.inputSchemaJSON)
        }
    }
}
