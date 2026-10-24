import Foundation

/// Phase 9: running an approved shell command — the one place a
/// command actually executes, called only from the engine's approve
/// path, never from a tool call.
///
/// The wrapper is deliberately thin, in the `FileActionService`
/// mold: the decision about WHAT may run (the exact text, the
/// scoped working folder, the dangerous-pattern marking) was made
/// purely, at proposal time and again as a pre-check at approval
/// time. What lives here is the Process mechanics:
///
///  - `/bin/zsh -c <command>` in the approved folder. Not a login
///    shell: the environment is the plain one from
///    `ShellCommandPolicy` (PATH + HOME, no profile files), so an
///    approved command does the same thing every time and a shell
///    profile can't add side effects the user never saw.
///  - A hard 30-second limit (see `ShellCommandPolicy`). Past it
///    the process is terminated (and force-killed if it ignores
///    that), and the item is recorded as timed out — not as a
///    success.
///  - stdout and stderr share one pipe, so the output reads in the
///    order it was printed. Retention is capped; the model sees
///    the tail (see `ShellOutput`).
///  - The item's record carries the verdict (exit code / timeout /
///    duration) as its note and the capped output as its detail —
///    which is also what the model's outcome note quotes.
///
/// A command runs with the user's own permissions — there is no
/// sandbox around it beyond the working-folder rule and the
/// approval itself. The README says this in so many words.
enum ShellCommandService {

    static func execute(_ action: PlannedAction) async -> ExecutedActionItem {
        guard let command = action.commandText, !command.isEmpty,
              let workingDirectory = action.workingDirectory else {
            return ExecutedActionItem(
                action: action, outcome: .failed("The command was missing its text or folder."),
                resultNote: "The command was missing its text or folder.")
        }
        let outcome = await ShellRunner.run(
            command: command, workingDirectory: workingDirectory)
        let note = ShellResultWording.note(
            exitCode: outcome.exitCode, timedOut: outcome.timedOut,
            seconds: outcome.seconds)
        let detail = ShellOutput.forModel(outcome.output)
        // A command "succeeds" for plan purposes when it ran and
        // exited 0; a nonzero exit is recorded as a failure with the
        // output attached, so the model can explain what happened
        // instead of the plan pretending it worked.
        if !outcome.timedOut, outcome.exitCode == 0 {
            return ExecutedActionItem(action: action, outcome: .done,
                                      resultNote: note,
                                      modelDetail: detail.isEmpty ? nil : detail)
        }
        return ExecutedActionItem(action: action,
                                  outcome: .failed(note),
                                  resultNote: note,
                                  modelDetail: detail.isEmpty ? nil : detail)
    }
}

/// The mutable state of one running command, guarded by a lock: the
/// output arrives on the pipe's queue, the timeout on a task, and
/// the exit on the process's own queue — three writers, one finish.
///
/// Audit B-49: the finish condition is process exit AND pipe EOF,
/// not exit alone. Output arrives asynchronously through the pipe's
/// readability callbacks; finishing on the termination handler
/// alone could snapshot the output before a final burst was read,
/// silently discarding the tail — exactly the part that matters.
/// The two events are therefore tracked separately and whichever
/// arrives second completes the run. A short drain grace after
/// exit (scheduled by the runner) still finishes the run if EOF
/// never arrives, so a grandchild holding the pipe open can't hang
/// the waiter forever.
///
/// Audit B-54: the waiter is cancellation-aware — cancelling the
/// awaiting task terminates the process and resumes the waiter
/// with a cancelled outcome instead of leaving both suspended
/// until exit or the 30-second timeout.
private final class ShellRunState: @unchecked Sendable {

    struct Outcome {
        let exitCode: Int32?
        let timedOut: Bool
        let output: String
        let seconds: Double
        /// The awaiting task was cancelled (audit B-54). The
        /// wording path treats this like any other no-exit-code
        /// ending; the flag exists so the outcome is honest in
        /// code, not only in prose.
        var cancelled: Bool = false
    }

    private let lock = NSLock()
    /// Audit E-13: captured output is kept as a list of chunks with
    /// an INCREMENTALLY tracked character count. The old shape —
    /// one growing String, `output.count` (a full grapheme walk)
    /// plus a 200k copy on EVERY chunk once near the cap — made a
    /// chatty command pay O(chunks × 200k). Now: appending a chunk
    /// is O(chunk); compaction is LAZY — only when the buffered
    /// total passes TWICE the retention cap are the chunks joined
    /// and cut back to the retained tail in one pass, so the
    /// O(cap) work happens once per cap's worth of output, not per
    /// chunk. Memory stays bounded (≈2× cap + one chunk) and the
    /// retention semantics are exactly B-49's: what survives is
    /// always the true TAIL of everything printed.
    private var outputChunks: [String] = []
    private var outputCharacterCount = 0
    private var outputWasCapped = false

    /// The retained output: the chunks joined and — if they ever
    /// crossed the cap — cut to the retained tail. Called once, at
    /// finish.
    private var output: String {
        let joined = outputChunks.joined()
        return outputWasCapped
            ? ShellOutput.retainedTail(joined) : joined
    }
    private var continuation: CheckedContinuation<Outcome, Never>?
    private var finalOutcome: Outcome?
    private var timedOut = false
    private var cancelled = false
    private var processExitCode: Int32?
    private var processHasExited = false
    private var pipeReachedEOF = false
    private let started = Date()
    /// Set by the runner before the waiter starts: how to stop the
    /// process when the waiter is cancelled (audit B-54).
    var cancellationHandler: (@Sendable () -> Void)?

    func appendOutput(_ text: String) {
        lock.lock()
        defer { lock.unlock() }
        guard finalOutcome == nil else { return }
        outputChunks.append(text)
        outputCharacterCount += text.count
        if outputCharacterCount > ShellOutput.retainedCharacterCap {
            // Past the cap: something will be dropped (B-49: the
            // BEGINNING — the retained text is the tail, and the
            // finish note says so).
            outputWasCapped = true
        }
        if outputCharacterCount > 2 * ShellOutput.retainedCharacterCap {
            // Lazy compaction (E-13): one join + suffix per cap's
            // worth of output, instead of per chunk.
            let tail = ShellOutput.retainedTail(
                outputChunks.joined())
            outputChunks = [tail]
            outputCharacterCount = tail.count
        }
    }

    func markTimedOut() {
        lock.lock()
        timedOut = true
        lock.unlock()
    }

    /// The process exited. Finishes the run only once the pipe has
    /// also reached EOF (audit B-49).
    func noteProcessExit(exitCode: Int32?) {
        lock.lock()
        processExitCode = exitCode
        processHasExited = true
        lock.unlock()
        finishIfComplete()
    }

    /// The pipe reached EOF (the readability handler's empty-data
    /// callback). Finishes the run only once the process has also
    /// exited (audit B-49).
    func notePipeEOF() {
        lock.lock()
        pipeReachedEOF = true
        lock.unlock()
        finishIfComplete()
    }

    /// The drain-grace fallback (audit B-49): the process exited
    /// but EOF never arrived within the grace period — finish with
    /// whatever output was captured rather than hanging.
    func finishAfterDrainGrace() {
        lock.lock()
        let exited = processHasExited
        lock.unlock()
        guard exited else { return }
        complete()
    }

    /// The awaiting task was cancelled (audit B-54): resume the
    /// waiter with a cancelled outcome (the runner's cancellation
    /// handler, invoked alongside, terminates the process).
    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
        complete()
    }

    private func finishIfComplete() {
        lock.lock()
        let ready = processHasExited && pipeReachedEOF
        lock.unlock()
        if ready { complete() }
    }

    private func complete() {
        lock.lock()
        guard finalOutcome == nil else {
            lock.unlock()
            return
        }
        var finalOutput = output
        if outputWasCapped {
            finalOutput += "\n… (the command printed more than the app keeps — the beginning was dropped)"
        }
        let outcome = Outcome(
            exitCode: timedOut ? nil : processExitCode,
            timedOut: timedOut,
            output: finalOutput,
            seconds: Date().timeIntervalSince(started),
            cancelled: cancelled)
        finalOutcome = outcome
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: outcome)
    }

    /// Waits for the outcome — immediately returned when the
    /// command already finished (a fast command can beat the
    /// waiter to it; the outcome is stored, not lost).
    ///
    /// Audit B-54: `withTaskCancellationHandler` — when the
    /// awaiting task is cancelled, the process is terminated (via
    /// the runner's handler) and the waiter resumes at once with
    /// the cancelled outcome, instead of `withCheckedContinuation`
    /// leaving it suspended until exit or timeout.
    func awaitOutcome() async -> Outcome {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                lock.lock()
                if let finalOutcome {
                    lock.unlock()
                    continuation.resume(returning: finalOutcome)
                } else {
                    self.continuation = continuation
                    lock.unlock()
                }
            }
        } onCancel: {
            cancellationHandler?()
            cancel()
        }
    }
}

private enum ShellRunner {

    static func run(command: String, workingDirectory: String) async
        -> ShellRunState.Outcome {
        let state = ShellRunState()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]
        process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
        process.environment = ShellCommandPolicy.plainEnvironment(
            home: NSHomeDirectory())

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        // Not interested in anything the command might ask: stdin
        // is /dev/null, so an interactive prompt reads EOF instead
        // of hanging until the timeout.
        process.standardInput = FileHandle.nullDevice

        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                // EOF: the pipe is fully drained. One half of the
                // finish condition (audit B-49).
                handle.readabilityHandler = nil
                state.notePipeEOF()
                return
            }
            if let text = String(data: data, encoding: .utf8) {
                state.appendOutput(text)
            } else {
                state.appendOutput(
                    String(decoding: data, as: UTF8.self))
            }
        }
        process.terminationHandler = { process in
            // The other half of the finish condition (audit B-49):
            // the run completes when the pipe also reaches EOF. If
            // EOF never comes (a spawned grandchild can hold the
            // pipe open), a short drain grace finishes the run with
            // what was captured rather than hanging the waiter.
            state.noteProcessExit(exitCode: process.terminationStatus)
            DispatchQueue.global(qos: .utility).asyncAfter(
                deadline: .now() + 0.5) {
                    state.finishAfterDrainGrace()
                }
        }
        // Audit B-54: if the awaiting task is cancelled, the state
        // calls this to stop the process (the waiter itself is
        // resumed by the state's cancellation path).
        state.cancellationHandler = {
            if process.isRunning {
                process.terminate()
            }
        }

        // The timeout: terminate first (SIGTERM — well-behaved
        // commands exit), then force-kill a second later if the
        // process is still alive.
        let timeoutTask = Task {
            try? await Task.sleep(
                for: .seconds(ShellCommandPolicy.timeoutSeconds))
            guard !Task.isCancelled, process.isRunning else { return }
            state.markTimedOut()
            process.terminate()
            try? await Task.sleep(for: .seconds(1))
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }
        defer { timeoutTask.cancel() }

        do {
            try process.run()
        } catch {
            timeoutTask.cancel()
            pipe.fileHandleForReading.readabilityHandler = nil
            return ShellRunState.Outcome(
                exitCode: nil, timedOut: false,
                output: "The command couldn't be started: \(error.localizedDescription)",
                seconds: 0)
        }
        return await state.awaitOutcome()
    }
}
