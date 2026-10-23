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
private final class ShellRunState: @unchecked Sendable {

    struct Outcome {
        let exitCode: Int32?
        let timedOut: Bool
        let output: String
        let seconds: Double
    }

    private let lock = NSLock()
    private var output = ""
    private var outputWasCapped = false
    private var continuation: CheckedContinuation<Outcome, Never>?
    private var finalOutcome: Outcome?
    private var timedOut = false
    private let started = Date()

    func appendOutput(_ text: String) {
        lock.lock()
        defer { lock.unlock() }
        guard finalOutcome == nil else { return }
        output += text
        if output.count > ShellOutput.retainedCharacterCap {
            output = ShellOutput.retainedPrefix(output)
            outputWasCapped = true
        }
    }

    func markTimedOut() {
        lock.lock()
        timedOut = true
        lock.unlock()
    }

    var isTimedOut: Bool {
        lock.lock()
        defer { lock.unlock() }
        return timedOut
    }

    func finish(exitCode: Int32?) {
        lock.lock()
        guard finalOutcome == nil else {
            lock.unlock()
            return
        }
        var finalOutput = output
        if outputWasCapped {
            finalOutput += "\n… (the command printed more than the app keeps — the middle was dropped)"
        }
        let outcome = Outcome(
            exitCode: timedOut ? nil : exitCode,
            timedOut: timedOut,
            output: finalOutput,
            seconds: Date().timeIntervalSince(started))
        finalOutcome = outcome
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: outcome)
    }

    /// Waits for the outcome — immediately returned when the
    /// command already finished (a fast command can beat the
    /// waiter to it; the outcome is stored, not lost).
    func awaitOutcome() async -> Outcome {
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
                handle.readabilityHandler = nil
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
            state.finish(exitCode: process.terminationStatus)
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
