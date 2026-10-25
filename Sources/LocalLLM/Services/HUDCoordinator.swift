import AppKit
import Carbon
import Observation
import SwiftData
import SwiftUI

/// Phase 7: the quick panel's coordinator — app delegate, hotkey
/// owner, panel owner.
///
/// This is the phase's AppKit surface, deliberately contained in one
/// file: a Carbon global hotkey (⌘⇧Space — `RegisterEventHotKey`,
/// which needs NO Accessibility permission, unlike event monitors),
/// one borderless floating `NSPanel` hosting the SwiftUI panel
/// content, the summon/dismiss lifecycle, and the context/session
/// bookkeeping the SwiftUI side reads.
///
/// How a summon flows:
///
/// 1. The hotkey fires (Carbon delivers on the main thread).
/// 2. Context is captured FIRST, while the user's other app is still
///    the frontmost one: `HUDContextCapture` reads the frontmost app
///    and the clipboard kind synchronously, and — only when the
///    Files source toggle is on — the Finder-selection probe starts
///    in the background and merges in when it lands.
/// 3. `HUDSessionPolicy` decides fresh-vs-continue against the last
///    HUD conversation; a fresh one is created in the store right
///    away (it appears in the sidebar immediately and the exchange
///    is never throwaway).
/// 4. The panel orders front WITHOUT activating the app
///    (`.nonactivatingPanel`), so the user's app stays frontmost and
///    a later summon still captures it truthfully. The panel is
///    key, so the text field takes typing normally.
///
/// Dismissal: Esc (from the SwiftUI side), the hotkey again (it
/// toggles), or the panel losing key status — the standard Spotlight
/// behaviors. Dismissing never interrupts a reply: streams live in
/// the engine, not the panel.
///
/// Approvals: the coordinator knows nothing about file actions —
/// that rule lives in the panel view, which shows pending plans but
/// offers no Approve button (see `HUDView`).
@MainActor
@Observable
final class HUDCoordinator: NSObject, NSApplicationDelegate {

    // MARK: - Observable state for the panel view

    /// The conversation the panel is currently talking to. Set at
    /// every summon (fresh or continued); the panel content rebinds
    /// to it.
    private(set) var currentConversation: Conversation?

    /// The context captured at the latest summon. The Finder paths
    /// merge in when the probe returns (same generation only).
    private(set) var contextSnapshot: HUDContextSnapshot = .empty

    /// Bumped at every summon — the panel view watches it to grab
    /// keyboard focus and scroll to the latest message.
    private(set) var summonGeneration = 0

    /// Audit B-58: true when the last ⌘⇧Space registration attempt
    /// failed (another app may hold the shortcut). Settings shows
    /// it in the Quick panel section so a dead hotkey is a visible
    /// state with a remedy, not a silent nothing. Cleared by the
    /// next successful registration.
    private(set) var hotkeyRegistrationFailed = false

    /// The Settings copy for the failed-registration state.
    static let hotkeyFailureText =
        "The ⌘⇧Space shortcut couldn't be registered — another app "
        + "may be using it right now. Blink keeps trying whenever "
        + "this setting is toggled or the app is reopened; free the "
        + "shortcut in the other app if it stays taken."

    // MARK: - Wiring (set once by ContentView)

    /// Read by the panel's root view to bind its content.
    private(set) var engine: ChatEngine?
    private var settings: AppSettings?
    private var container: ModelContainer?
    /// ContentView's "select this conversation in the sidebar".
    private var openConversationHandler: ((UUID) -> Void)?

    /// A conversation the user asked to open in the main window while
    /// no ContentView was alive to hear the handler — ContentView
    /// drains this on appear.
    private var pendingOpenConversationID: UUID?

    /// Called by ContentView when it appears: hands over the shared
    /// objects and makes sure the hotkey matches the Settings toggle.
    func configure(engine: ChatEngine,
                   settings: AppSettings,
                   container: ModelContainer,
                   onOpenConversation: @escaping (UUID) -> Void) {
        self.engine = engine
        self.settings = settings
        self.container = container
        self.openConversationHandler = onOpenConversation
        Self.current = self
        applyHotkeyRegistration()
        observeSettings()
        if let pending = consumePendingOpenConversationID() {
            onOpenConversation(pending)
        }
    }

    // MARK: - Session bookkeeping

    private var lastConversationID: UUID?
    private var lastDismissedAt: Date?
    private var lastMovedToMainWindow = false
    private var captureGeneration = 0
    /// True while a Finder probe for the current summon is running —
    /// the Automation permission prompt can steal key status, and
    /// the panel must not dismiss itself out from under it.
    private var finderProbeInFlight = false
    private var summonedAt: Date = .distantPast

    // MARK: - Hotkey (Carbon)

    private var hotKeyRef: EventHotKeyRef?
    private var hotKeyHandlerRef: EventHandlerRef?

    /// The coordinator the Carbon trampoline talks to. There is
    /// exactly one (the app delegate), set at configure time.
    private static weak var current: HUDCoordinator?

    /// The C-callback target. Carbon delivers hotkey events on the
    /// application's main event loop, so assuming main-actor
    /// isolation here is sound.
    fileprivate static func hotKeyFired() {
        current?.togglePanel()
    }

    private func applyHotkeyRegistration() {
        let shouldRegister = settings?.hudEnabled ?? true
        if shouldRegister, hotKeyRef == nil {
            registerHotkey()
        } else if !shouldRegister, hotKeyRef != nil {
            unregisterHotkey()
            dismiss()
        }
    }

    private func registerHotkey() {
        // Install the handler once — a second install would deliver
        // every press twice (and the toggle would cancel itself).
        if hotKeyHandlerRef == nil {
            var eventType = EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyPressed))
            let installStatus = InstallEventHandler(
                GetApplicationEventTarget(),
                hudHotKeyEventHandler,
                1, &eventType, nil, &hotKeyHandlerRef)
            guard installStatus == noErr else { return }
        }
        // ⌘⇧Space. The four-character signature "LHUD" namespaces the
        // hotkey id within the app.
        let hotKeyID = EventHotKeyID(signature: OSType(0x4C48_5544),
                                     id: 1)
        let registerStatus = RegisterEventHotKey(
            UInt32(kVK_Space),
            UInt32(cmdKey | shiftKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef)
        if registerStatus != noErr {
            // Another app may already own ⌘⇧Space system-wide; the
            // panel simply stays unavailable by hotkey — the main
            // window is unaffected.
            //
            // Audit B-58: the failure may be TRANSIENT (the other
            // app later releases the shortcut), so (a) the event
            // handler stays INSTALLED — only the hotkey ref is
            // dropped, which is what `applyHotkeyRegistration`
            // needs to see to retry registration on the next
            // configure/toggle — and (b) the failure is surfaced
            // for Settings instead of vanishing silently. The old
            // code also removed the handler, and nothing ever
            // re-attempted, so a momentary conflict killed the
            // hotkey for the whole run with no signal anywhere.
            hotkeyRegistrationFailed = true
            hotKeyRef = nil
        } else {
            hotkeyRegistrationFailed = false
        }
    }

    private func unregisterHotkey() {
        hotkeyRegistrationFailed = false
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let hotKeyHandlerRef {
            RemoveEventHandler(hotKeyHandlerRef)
            self.hotKeyHandlerRef = nil
        }
    }

    /// Watches the Settings toggle so the hotkey (un)registers the
    /// moment it flips — no relaunch, no polling. Re-arms after each
    /// change because observation tracking is one-shot; the armed
    /// flag keeps repeated `configure` calls from stacking chains.
    private func observeSettings() {
        guard let settings, !settingsObservationArmed else { return }
        settingsObservationArmed = true
        withObservationTracking {
            _ = settings.hudEnabled
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.settingsObservationArmed = false
                self.applyHotkeyRegistration()
                self.observeSettings()
            }
        }
    }

    // MARK: - Panel

    private var panel: NSPanel?
    private var resignKeyObserver: NSObjectProtocol?
    private var settingsObservationArmed = false

    private func makePanelIfNeeded() {
        guard panel == nil, let container else { return }
        let panel = HUDPanel(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 540),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let rootView = HUDPanelRoot(coordinator: self)
            .modelContainer(container)
        panel.contentView = NSHostingView(rootView: rootView)
        // Losing key status (clicking another app, or this app's own
        // main window) dismisses the panel — Spotlight behavior. Two
        // guards in `panelDidResignKey`: the brief focus shuffle
        // right at summon, and a Finder probe in flight (its
        // Automation prompt is a system dialog that can take key
        // status legitimately).
        resignKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: panel,
            queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.panelDidResignKey()
                }
            }
        self.panel = panel
    }

    private func panelDidResignKey() {
        guard panel?.isVisible == true,
              !finderProbeInFlight,
              Date().timeIntervalSince(summonedAt) > 0.35 else { return }
        dismiss()
    }

    var isPanelVisible: Bool { panel?.isVisible ?? false }

    func togglePanel() {
        if isPanelVisible {
            dismiss()
        } else {
            summon()
        }
    }

    /// Shows the panel: capture context, pick the conversation,
    /// position on the active screen, order front.
    func summon() {
        guard let settings, let container else { return }
        makePanelIfNeeded()
        guard let panel else { return }

        // 1. Capture FIRST, before anything can change which app is
        // frontmost. (The panel is non-activating, so the user's app
        // stays frontmost — but the capture ordering costs nothing
        // and keeps the rule obvious.)
        captureGeneration += 1
        let generation = captureGeneration
        let filesEnabled = settings.isSourceEnabled(.files)
        contextSnapshot = HUDContextCapture.captureSync(
            includeClipboardText: settings.isSourceEnabled(.clipboard))
        if !filesEnabled {
            // No probe for this summon: the flag belongs to the
            // current generation, so clear any stale probe's claim
            // on it here (audit B-53's companion case).
            finderProbeInFlight = false
        }
        if filesEnabled {
            finderProbeInFlight = true
            // Review finding 21: the DETAILED probe, so a denied
            // Automation permission lands as its own chip instead
            // of an empty selection that looks like "nothing
            // selected". The generation and toggle guards below
            // are unchanged (audit B-53).
            HUDContextCapture.probeFinderSelectionDetailed { [weak self] outcome in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    // Audit B-53: only the CURRENT summon's probe
                    // may clear the in-flight flag. The old code
                    // cleared it unconditionally, before the
                    // generation check below — a stale probe from
                    // the previous summon could drop the flag while
                    // this summon's probe was still running, and
                    // `panelDidResignKey` would then dismiss the
                    // panel out from under the live probe's
                    // Automation prompt (the failure the flag
                    // exists to prevent).
                    if generation == self.captureGeneration {
                        self.finderProbeInFlight = false
                    }
                    // Only the current summon's probe may merge, and
                    // only while the Files toggle is still on.
                    guard generation == self.captureGeneration,
                          self.settings?.isSourceEnabled(.files) == true
                    else { return }
                    var snapshot = self.contextSnapshot
                    switch outcome {
                    case .selection(let paths):
                        snapshot.finderSelectionPaths = paths
                        snapshot.finderAutomationDenied = false
                    case .denied:
                        snapshot.finderSelectionPaths = []
                        snapshot.finderAutomationDenied = true
                    case .unavailable:
                        snapshot.finderSelectionPaths = []
                        snapshot.finderAutomationDenied = false
                    }
                    self.contextSnapshot = snapshot
                }
            }
        }

        // 2. Fresh or continue, per the session policy.
        let context = container.mainContext
        let previous: Conversation? = lastConversationID.flatMap { id in
            let descriptor = FetchDescriptor<Conversation>(
                predicate: #Predicate { $0.id == id })
            return try? context.fetch(descriptor).first
        }
        let shouldContinue = HUDSessionPolicy.shouldContinue(
            previousConversationID: lastConversationID,
            dismissedAt: lastDismissedAt,
            now: Date(),
            previousStillExists: previous != nil,
            movedToMainWindow: lastMovedToMainWindow)
        if shouldContinue, let previous {
            currentConversation = previous
        } else {
            let conversation = Conversation()
            context.insert(conversation)
            try? context.save()
            currentConversation = conversation
            lastConversationID = conversation.id
            lastMovedToMainWindow = false
        }

        // 3. Position: centered horizontally on the screen under the
        // mouse (the "active" screen for a summoned panel), top edge
        // a little below the top of its visible frame.
        if let screen = NSScreen.screens.first(where: {
            NSMouseInRect(NSEvent.mouseLocation, $0.frame, false)
        }) ?? NSScreen.main {
            let visible = screen.visibleFrame
            let size = panel.frame.size
            let x = visible.midX - size.width / 2
            let y = visible.maxY - size.height - 110
            panel.setFrameOrigin(NSPoint(x: x, y: max(visible.minY, y)))
        }

        // 4. Show, without activating the app.
        summonedAt = Date()
        summonGeneration += 1
        panel.orderFrontRegardless()
        panel.makeKey()
    }

    /// Hides the panel and stamps the dismissal for the session
    /// policy. A reply in flight keeps streaming in the engine.
    func dismiss() {
        guard let panel, panel.isVisible else { return }
        panel.orderOut(nil)
        lastDismissedAt = Date()
    }

    // MARK: - Open in the main window

    /// The user asked to continue this conversation in the main
    /// window (the panel's Open button or ⌘Return). Ends the HUD
    /// chain — the next summon starts fresh — hands the conversation
    /// to ContentView (now via the handler, which fronts the window
    /// with the scene's `openWindow`; or on its next appear via the
    /// pending slot), and dismisses the panel.
    func requestOpenInMainWindow() {
        guard let conversation = currentConversation else { return }
        lastMovedToMainWindow = true
        pendingOpenConversationID = conversation.id
        openConversationHandler?(conversation.id)
        dismiss()
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Takes the pending open-conversation id, if any (ContentView
    /// drains it on appear — the path that covers the main window
    /// having been closed when Open was pressed).
    func consumePendingOpenConversationID() -> UUID? {
        defer { pendingOpenConversationID = nil }
        return pendingOpenConversationID
    }
}

/// The panel itself: borderless panels refuse key status by
/// default, and a panel that can't become key can't take typing.
/// Overriding `canBecomeKey` is the whole subclass.
final class HUDPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// The Carbon hotkey callback. It must be a plain C function — no
/// captures — so it forwards to the coordinator through its static
/// slot. Carbon delivers it on the main thread (the application
/// event target), which is what makes the isolation assumption safe.
private func hudHotKeyEventHandler(
    _ callRef: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    MainActor.assumeIsolated {
        HUDCoordinator.hotKeyFired()
    }
    return noErr
}
