import AppKit
import Foundation

/// Infrastructure adapter for the three process-wide protections.  The option
/// set intentionally omits `idleDisplaySleepDisabled`: display sleep remains
/// available while recording or filesystem work protects idle system sleep.
final class ProcessInfoLifecycleActivityAdapter: LifecycleActivityControlling, @unchecked Sendable {
    static let activityOptions: ProcessInfo.ActivityOptions = [
        .idleSystemSleepDisabled, .automaticTerminationDisabled, .suddenTerminationDisabled
    ]
    private let lock = NSLock()
    private var token: NSObjectProtocol?
    private let begin: @Sendable () -> NSObjectProtocol
    private let end: @Sendable (NSObjectProtocol) -> Void
    init(begin: @escaping @Sendable () -> NSObjectProtocol = {
        ProcessInfo.processInfo.beginActivity(options: activityOptions, reason: "Local recording safety work")
    }, end: @escaping @Sendable (NSObjectProtocol) -> Void = { ProcessInfo.processInfo.endActivity($0) }) {
        self.begin = begin; self.end = end
    }
    func setRelevantWorkActive(_ active: Bool) async { update(active) }
    func update(_ active: Bool) {
        lock.lock(); defer { lock.unlock() }
        if active, token == nil { token = begin() }
        else if !active, let token { end(token); self.token = nil }
    }
}

@MainActor
final class MacAutomaticTerminationGateway: LifecycleTerminationRequesting {
    var authority: LifecycleWorkAuthority?
    var isWindowReservationCurrent: () -> Bool = { false }
    var windowReservationGeneration: () -> UInt64 = { 0 }
    var terminate: () -> Void = { NSApplication.shared.terminate(nil) }
    @discardableResult
    func requestAutomaticTermination(isStillValid: @escaping @Sendable () async -> Bool) async -> Bool {
        let generation = authority?.state().generation
        let windows = windowReservationGeneration()
        guard await isStillValid(), windows == windowReservationGeneration(), isWindowReservationCurrent() else { return false }
        guard let authority, let generation else { return false }
        return authority.authorize(generation, action: terminate)
    }
}

/// A separate reply seam keeps an asynchronous AppKit termination request
/// testable without ever replying to, or terminating, the XCTest process.
@MainActor
protocol AppTerminationReplying: AnyObject {
    func replyToApplicationShouldTerminate(_ allowed: Bool)
}

/// Main-actor mirror of the last fresh lifecycle decision.  An unknown answer
/// is intentionally represented by `terminateLater`, so the AppKit callback
/// never blocks on an actor or guesses that it is safe to exit.
@MainActor
final class SynchronousTerminationReadiness: LifecycleTerminationReadinessUpdating {
    private var decision: AppTerminationDecision
    var authority: LifecycleWorkAuthority?
    private var generation: UInt64?

    init(initial: AppTerminationDecision = .terminateLater) { self.decision = initial }

    func updateSynchronousTerminationDecision(_ decision: AppTerminationDecision, generation: UInt64? = nil) {
        self.decision = decision
        self.generation = generation
    }

    func currentDecision() -> AppTerminationDecision {
        if let authority {
            let state = authority.state()
            if state.generation != generation || state.active { return .terminateLater }
        }
        return decision
    }
}

@MainActor
final class AppKitTerminationReplyGateway: AppTerminationReplying {
    func replyToApplicationShouldTerminate(_ allowed: Bool) {
        NSApplication.shared.reply(toApplicationShouldTerminate: allowed)
    }
}

@MainActor
protocol UserWindowClassifying: AnyObject {
    func visibleUserWindowCount() -> Int
}

@MainActor
final class AppKitUserWindowClassifier: UserWindowClassifying {
    func visibleUserWindowCount() -> Int {
        NSApplication.shared.windows.filter(isUserWindow(_:)).count
    }

    /// Main and Settings are titled `NSWindow`s.  Hidden framework windows,
    /// transient utilities, and all `NSPanel` subclasses are deliberately not
    /// part of the last-user-window reservation policy.
    func isUserWindow(_ window: NSWindow) -> Bool {
        window.isVisible && !(window is NSPanel) && window.styleMask.contains(.titled)
    }
}

@MainActor
protocol RecordingQuitPresenting: AnyObject {
    func chooseRecordingQuitAction() async -> AppTerminationChoice
}

@MainActor
final class AppKitRecordingQuitPresenter: RecordingQuitPresenting {
    func chooseRecordingQuitAction() async -> AppTerminationChoice {
        let alert = NSAlert()
        alert.messageText = "녹음이 진행 중입니다"
        alert.informativeText = "복구 가능한 오디오를 안전하게 저장한 뒤 종료할 수 있습니다."
        alert.addButton(withTitle: "필수 저장 후 종료")
        alert.addButton(withTitle: "계속 사용")
        return alert.runModal() == .alertFirstButtonReturn ? .essentialSaveAndQuit : .continueUsing
    }
}

/// The only AppKit/NSWorkspace bridge.  Callbacks schedule semantic work and
/// never synchronously wait for media, filesystem, or recovery operations.
@MainActor
final class MacLifecycleDelegate: NSObject, NSApplicationDelegate {
    private var lifecycle: AppLifecycleCoordinator?
    private var windowTokens: [NSObjectProtocol] = []
    private var windowReservation = false
    private var windowGeneration: UInt64 = 0
    private var terminationTask: Task<Void, Never>?
    private var reopenPending = false
    private var sawVisibleUserWindow = false
    private let onWindowObservation: @MainActor (Int) -> Void
    private let beforeReply: @MainActor @Sendable () async -> Void
    private var replyGeneration: UInt64?
    private var authority: LifecycleWorkAuthority?
    private var workspaceTokens: [NSObjectProtocol] = []
    private var terminationInFlight = false
    private let activity: any LifecycleActivityControlling
    private let automaticTermination: any LifecycleTerminationRequesting
    private let presenter: any RecordingQuitPresenting
    private let terminationReply: any AppTerminationReplying
    private let windowClassifier: any UserWindowClassifying
    private let terminationReadiness: SynchronousTerminationReadiness

    override convenience init() {
        self.init(activity: ProcessInfoLifecycleActivityAdapter(),
                  automaticTermination: MacAutomaticTerminationGateway(),
                  presenter: AppKitRecordingQuitPresenter(),
                  terminationReply: AppKitTerminationReplyGateway(),
                  windowClassifier: AppKitUserWindowClassifier(),
                  terminationReadiness: SynchronousTerminationReadiness())
    }

    init(activity: any LifecycleActivityControlling,
         automaticTermination: any LifecycleTerminationRequesting,
         presenter: any RecordingQuitPresenting,
         terminationReply: any AppTerminationReplying,
         windowClassifier: any UserWindowClassifying,
         terminationReadiness: SynchronousTerminationReadiness = SynchronousTerminationReadiness(),
         beforeReply: @escaping @MainActor @Sendable () async -> Void = {},
         onWindowObservation: @escaping @MainActor (Int) -> Void = { _ in }) {
        self.onWindowObservation = onWindowObservation
        self.beforeReply = beforeReply
        self.activity = activity
        self.automaticTermination = automaticTermination
        self.presenter = presenter
        self.terminationReply = terminationReply
        self.windowClassifier = windowClassifier
        self.terminationReadiness = terminationReadiness
        super.init()
    }

    func configure(recording: any RecordingSessionCoordinating,
                   finalization: any LifecycleFinalizationCoordinating,
                   recovery: any LifecycleRecoveryCoordinating, authority: LifecycleWorkAuthority? = nil,
                   auxiliary: (any LifecycleAuxiliaryWorking)? = nil) {
        guard lifecycle == nil else { return }
        self.authority = authority
        terminationReadiness.authority = authority
        terminationReadiness.updateSynchronousTerminationDecision(.terminateLater)
        if let gateway = automaticTermination as? MacAutomaticTerminationGateway {
            gateway.authority = authority
            gateway.windowReservationGeneration = { [weak self] in self?.windowGeneration ?? 0 }
            gateway.isWindowReservationCurrent = { [weak self] in
                guard let self else { return false }
                return self.windowReservation && self.windowClassifier.visibleUserWindowCount() == 0
            }
        }
        lifecycle = AppLifecycleCoordinator(recording: recording, finalization: finalization, recovery: recovery,
                                            activity: activity, termination: automaticTermination,
                                            terminationReadiness: terminationReadiness, authority: authority, auxiliary: auxiliary)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let lifecycle else { return }
        observeWorkspace(lifecycle)
        observeWindows()
        Task {
            await lifecycle.start()
            if windowClassifier.visibleUserWindowCount() > 0 { userWindowsChanged() }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        userWindowsChanged(reserveIfEmpty: true)
        return false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        windowReservation = false
        reopenPending = true
        windowGeneration &+= 1
        if let lifecycle { Task { await lifecycle.applicationReopened(); await lifecycle.userWindowCountChanged(windowClassifier.visibleUserWindowCount()) } }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if terminationTask != nil && !terminationInFlight { return .terminateCancel }
        // This is the one safe synchronous path.  It creates no task, dialog,
        // disk operation, or later reply.  Every unknown/stale answer falls
        // through to the conservative asynchronous protocol below.
        if !terminationInFlight, terminationReadiness.currentDecision() == .terminateNow {
            return .terminateNow
        }
        // A fresh negative answer is equally synchronous: AppKit must keep
        // running and there is no owned `terminateLater` request to resolve.
        if !terminationInFlight, terminationReadiness.currentDecision() == .terminateCancel {
            return .terminateCancel
        }
        guard let lifecycle else { return .terminateCancel }
        // Repeated Cmd-Q/menu/Dock callbacks join the owned attempt instead of
        // cancelling it.  AppKit receives one completion reply for the one
        // terminate-later request represented by this delegate state.
        guard !terminationInFlight else { return .terminateLater }
        terminationInFlight = true
        replyGeneration = authority?.state().generation
        terminationTask = Task { @MainActor [self] in
            let decision = await lifecycle.terminationDecision()
            let allowed: Bool
            switch decision {
            case .terminateNow: allowed = true
            case .terminateCancel: allowed = false
            case .terminateLater: allowed = await lifecycle.resolveTermination(.essentialSaveAndQuit, admittedGeneration: replyGeneration)
            case .needsRecordingChoice:
                let choice = await presenter.chooseRecordingQuitAction()
                allowed = await lifecycle.resolveTermination(choice, admittedGeneration: replyGeneration)
            }
            await beforeReply()
            self.replyToTermination(allowed)
            self.terminationTask = nil

        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        // An adapter teardown after `.terminateLater` must not strand the
        // original AppKit request.  A successful path has already cleared the
        // flag before this callback, so this only conservatively cancels an
        // unresolved request.
        if terminationInFlight { replyToTermination(false) }
        workspaceTokens.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        workspaceTokens.removeAll()
        windowTokens.forEach { NotificationCenter.default.removeObserver($0) }
        windowTokens.removeAll()
    }

    func waitForPendingTermination() async { await terminationTask?.value }
    var installedObserverCount: Int { workspaceTokens.count + windowTokens.count }

    private func replyToTermination(_ allowed: Bool) {
        guard terminationInFlight else { return }
        terminationInFlight = false
        if allowed, let authority, let replyGeneration {
            if !authority.authorize(replyGeneration, action: { terminationReply.replyToApplicationShouldTerminate(true) }) {
                terminationReply.replyToApplicationShouldTerminate(false)
            }
        } else { terminationReply.replyToApplicationShouldTerminate(allowed) }
    }

    func userWindowsChanged(reserveIfEmpty: Bool = false) {
        let count = windowClassifier.visibleUserWindowCount()
        onWindowObservation(count)
        if count > 0 { windowReservation = false; reopenPending = false; sawVisibleUserWindow = true }
        else if !reopenPending && (sawVisibleUserWindow || reserveIfEmpty) { windowReservation = true }
        if count == 0 && !windowReservation { return }
        windowGeneration &+= 1
        let generation = windowGeneration
        if let lifecycle { Task {
            guard self.windowGeneration == generation else { return }
            await lifecycle.userWindowCountChanged(count)
        } }
    }

    private func observeWindows() {
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
                     NSWindow.willCloseNotification, NSWindow.didBecomeKeyNotification] {
            windowTokens.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.userWindowsChanged() }
            })
        }
    }

    private func observeWorkspace(_ lifecycle: AppLifecycleCoordinator) {
        let center = NSWorkspace.shared.notificationCenter
        workspaceTokens = [
            center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
                Task { await lifecycle.handlePowerEvent(.willSleep) }
            },
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
                Task { await lifecycle.handlePowerEvent(.didWake) }
            },
            center.addObserver(forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main) { _ in
                Task { await lifecycle.handlePowerEvent(.willPowerOff) }
            }
        ]
    }

}
